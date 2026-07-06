//! Month view: the calendar grid with event dots, plus the selected-day peek
//! (SPEC §7a). Formatted strings go into the caller's per-frame scratch
//! allocator — vaxis keeps references to printed text until render, so the
//! bytes must outlive this call (see App.scratch_buffer). No heap allocation.

const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");
const time_mod = @import("../calendar/time.zig");
const event_mod = @import("../calendar/event.zig");
const snapshot_mod = @import("../snapshot.zig");

const CivilDate = time_mod.CivilDate;

const cell_width: u16 = 6;
const grid_left: u16 = 1;
/// Event dots shown per day cell before collapsing to +N.
const max_dots = 3;
/// Peek lines under the grid for the selected day's events.
const max_peek = 3;

pub const State = struct {
    selected: CivilDate,
    today: CivilDate,
    zone: time_mod.Zone,
    source_name: []const u8,
};

pub fn draw(
    win: vaxis.Window,
    scratch: std.mem.Allocator,
    snapshot: ?*const snapshot_mod.Snapshot,
    state: State,
) void {
    drawHeader(win, scratch, state);
    drawWeekdayHeader(win);
    const grid_rows = drawGrid(win, scratch, snapshot, state);
    drawPeek(win, scratch, snapshot, state, 3 + grid_rows * 2 + 1);
}

fn drawHeader(win: vaxis.Window, scratch: std.mem.Allocator, state: State) void {
    const title = std.fmt.allocPrint(scratch, "{s} {d}", .{
        time_mod.month_names[state.selected.month - 1],
        @as(u32, @intCast(state.selected.year)),
    }) catch return;
    printAt(win, grid_left, 0, title, theme.title);

    const source_label = std.fmt.allocPrint(scratch, "source: {s}", .{state.source_name}) catch return;
    const width: u16 = @intCast(source_label.len); // ASCII
    if (win.width > width + 1) {
        printAt(win, win.width - width - 1, 0, source_label, theme.dim);
    }
}

fn drawWeekdayHeader(win: vaxis.Window) void {
    for (time_mod.weekday_names_short, 0..) |name, i| {
        printAt(win, grid_left + @as(u16, @intCast(i)) * cell_width + 1, 2, name, theme.subtle);
    }
}

/// Draws the day grid starting at row 3; returns the number of week rows.
fn drawGrid(
    win: vaxis.Window,
    scratch: std.mem.Allocator,
    snapshot: ?*const snapshot_mod.Snapshot,
    state: State,
) u16 {
    const year = state.selected.year;
    const month = state.selected.month;
    const first = CivilDate{ .year = year, .month = month, .day = 1 };
    // Week starts Monday until config lands (M3); ISO weekday index 0 = Monday.
    const lead: u16 = @intFromEnum(time_mod.weekday(first));
    const days_in_month: u16 = time_mod.daysInMonth(year, month);
    const weeks: u16 = (lead + days_in_month + 6) / 7;

    var week: u16 = 0;
    while (week < weeks) : (week += 1) {
        var column: u16 = 0;
        while (column < 7) : (column += 1) {
            const slot: i64 = @as(i64, week) * 7 + column - lead;
            const date = time_mod.addDays(first, slot);
            const in_month = date.month == month;
            const row = 3 + week * 2;
            const x = grid_left + column * cell_width;
            drawDayCell(win, scratch, x, row, date, in_month, snapshot, state);
        }
    }
    return weeks;
}

fn drawDayCell(
    win: vaxis.Window,
    scratch: std.mem.Allocator,
    x: u16,
    row: u16,
    date: CivilDate,
    in_month: bool,
    snapshot: ?*const snapshot_mod.Snapshot,
    state: State,
) void {
    const is_selected = date.eql(state.selected);
    const is_today = date.eql(state.today);

    const label = std.fmt.allocPrint(scratch, "{d: >3} ", .{date.day}) catch return;
    const style = if (is_selected)
        theme.selected
    else if (is_today)
        theme.today
    else if (in_month)
        theme.text
    else
        theme.dim;
    printAt(win, x, row, label, style);

    const snap = snapshot orelse return;
    const count = snap.countOnDay(date, state.zone);
    if (count == 0) return;

    var events_buffer: [max_dots]event_mod.Event = undefined;
    const events = snap.eventsOnDay(&events_buffer, date, state.zone);
    var dot_x = x + 1;
    for (events) |event| {
        win.writeCell(dot_x, row + 1, .{
            .char = .{ .grapheme = "●", .width = 1 },
            .style = .{ .fg = theme.calendarColor(event.calendar_color) },
        });
        dot_x += 1;
    }
    if (count > max_dots) {
        const more = std.fmt.allocPrint(scratch, "+{d}", .{count - max_dots}) catch return;
        printAt(win, dot_x, row + 1, more, theme.dim);
    }
}

fn drawPeek(
    win: vaxis.Window,
    scratch: std.mem.Allocator,
    snapshot: ?*const snapshot_mod.Snapshot,
    state: State,
    row: u16,
) void {
    if (row + 1 >= win.height) return;
    const snap = snapshot orelse return;

    const total = snap.countOnDay(state.selected, state.zone);
    const weekday_name = time_mod.weekday_names_short[@intFromEnum(time_mod.weekday(state.selected))];
    const header = std.fmt.allocPrint(scratch, "{s} {s} {d} — {d} event{s}", .{
        weekday_name,
        time_mod.month_names[state.selected.month - 1][0..3],
        state.selected.day,
        total,
        if (total == 1) "" else "s",
    }) catch return;
    printAt(win, grid_left, row, header, theme.accent);

    var events_buffer: [max_peek]event_mod.Event = undefined;
    const events = snap.eventsOnDay(&events_buffer, state.selected, state.zone);
    for (events, 0..) |event, i| {
        const line_row = row + 1 + @as(u16, @intCast(i));
        if (line_row + 1 >= win.height) return;
        drawPeekLine(win, scratch, line_row, event, state);
    }
    if (total > events.len) {
        const line_row = row + 1 + @as(u16, @intCast(events.len));
        if (line_row + 1 >= win.height) return;
        const more = std.fmt.allocPrint(scratch, "  +{d} more", .{total - events.len}) catch return;
        printAt(win, grid_left, line_row, more, theme.dim);
    }
}

fn drawPeekLine(
    win: vaxis.Window,
    scratch: std.mem.Allocator,
    row: u16,
    event: event_mod.Event,
    state: State,
) void {
    const when = if (event.all_day)
        "all-day"
    else blk: {
        const start = time_mod.civilFromUnix(event.start, state.zone);
        break :blk std.fmt.allocPrint(scratch, "{d:0>2}:{d:0>2}", .{
            start.time.hour,
            start.time.minute,
        }) catch return;
    };
    printAt(win, grid_left + 1, row, when, theme.subtle);

    const title_x = grid_left + 1 + 8;
    const title_win = win.child(.{
        .x_off = title_x,
        .y_off = row,
        .width = win.width -| title_x,
        .height = 1,
    });
    _ = title_win.printSegment(.{ .text = event.title, .style = .{
        .fg = theme.calendarColor(event.calendar_color),
    } }, .{});
}

fn printAt(win: vaxis.Window, x: u16, y: u16, text: []const u8, style: vaxis.Style) void {
    if (y >= win.height or x >= win.width) return;
    const child = win.child(.{ .x_off = x, .y_off = y, .width = win.width - x, .height = 1 });
    _ = child.printSegment(.{ .text = text, .style = style }, .{});
}
