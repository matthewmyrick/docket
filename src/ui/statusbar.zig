//! The persistent bottom status bar: next-event countdown, refresh age,
//! fetch problems (ARCHITECTURE.md §7a, §8). Formatted text lives in the caller's
//! per-frame scratch (vaxis references it until render).

const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");
const poller_mod = @import("../poller.zig");
const snapshot_mod = @import("../snapshot.zig");

pub const State = struct {
    now: i64,
    /// 0 = healthy; 1+ shows the quiet warning; at
    /// poller.failure_banner_threshold it escalates to a banner.
    consecutive_failures: u32 = 0,
    /// Transient action result ("RSVP sent"), dismissed on next keypress.
    flash: ?[]const u8 = null,
    hint: []const u8 = "? help",
};

pub fn draw(
    win: vaxis.Window,
    scratch: std.mem.Allocator,
    snapshot: ?*const snapshot_mod.Snapshot,
    state: State,
) void {
    if (win.height < 2) return;
    const row = win.height - 1;
    var x: u16 = 1;

    if (state.consecutive_failures >= poller_mod.failure_banner_threshold) {
        const banner = std.fmt.allocPrint(
            scratch,
            " ⚠ calendar refresh has failed {d} times — showing cached data; check that `ical list` works ",
            .{state.consecutive_failures},
        ) catch return;
        _ = printAt(win, 0, row - 1, banner, theme.err);
    }

    if (state.consecutive_failures > 0) {
        x = printAt(win, x, row, "⚠ refresh failed (using cached)", theme.warning);
        x = printAt(win, x, row, "  ·  ", theme.dim);
    }

    if (state.flash) |flash| {
        x = printAt(win, x, row, flash, theme.accent);
        x = printAt(win, x, row, "  ·  ", theme.dim);
    }

    if (snapshot) |snap| {
        if (snap.nextUpcoming(state.now)) |next| {
            // Unsigned for {d:0>2}: zero-fill on signed ints prints "+48".
            const minutes: u64 = @intCast(@divFloor(next.start - state.now + 59, 60));
            const label = if (minutes >= 60)
                std.fmt.allocPrint(scratch, "next: {s} in {d}h {d:0>2}m", .{
                    next.title, minutes / 60, minutes % 60,
                }) catch return
            else
                std.fmt.allocPrint(scratch, "next: {s} in {d}m", .{ next.title, minutes }) catch return;
            x = printAt(win, x, row, label, theme.ok);
            x = printAt(win, x, row, "  ·  ", theme.dim);
        }

        const age = state.now - snap.fetched_at;
        const age_label = if (age < 120)
            std.fmt.allocPrint(scratch, "refreshed {d}s ago", .{@max(age, 0)}) catch return
        else
            std.fmt.allocPrint(scratch, "refreshed {d}m ago", .{@divFloor(age, 60)}) catch return;
        x = printAt(win, x, row, age_label, theme.subtle);
    } else {
        x = printAt(win, x, row, "no calendar data", theme.warning);
    }

    const hint_width: u16 = @intCast(state.hint.len);
    if (win.width > hint_width + 1) {
        _ = printAt(win, win.width - hint_width - 1, row, state.hint, theme.dim);
    }
}

/// Print and return the x position just past the text.
fn printAt(win: vaxis.Window, x: u16, y: u16, text: []const u8, style: vaxis.Style) u16 {
    if (y >= win.height or x >= win.width) return x;
    const child = win.child(.{ .x_off = x, .y_off = y, .width = win.width - x, .height = 1 });
    const result = child.printSegment(.{ .text = text, .style = style }, .{});
    return x + result.col;
}
