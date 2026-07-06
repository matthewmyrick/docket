//! Quick-add overlay: three fields (title, start, optional end) that become
//! an `ical add` invocation. The heavy lifting — natural-language date
//! parsing, calendar defaults, validation — stays in the `ical` CLI; this
//! is just a form. Overlay pattern follows search.zig.

const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");

pub const max_field = 96;

pub const Field = enum {
    title,
    start,
    end,

    pub fn label(self: Field) []const u8 {
        return switch (self) {
            .title => "title",
            .start => "when ", // natural language ok: "tomorrow 2pm"
            .end => "until", // optional; blank = 1 hour
        };
    }

    pub fn next(self: Field) ?Field {
        return switch (self) {
            .title => .start,
            .start => .end,
            .end => null,
        };
    }

    pub fn previous(self: Field) ?Field {
        return switch (self) {
            .title => null,
            .start => .title,
            .end => .start,
        };
    }
};

pub const State = struct {
    title: []const u8,
    start: []const u8,
    end: []const u8,
    active_field: Field,
};

pub fn draw(win: vaxis.Window, scratch: std.mem.Allocator, state: State) void {
    const width: u16 = @min(64, win.width -| 4);
    const height: u16 = 7;
    if (win.width < width + 2 or win.height < height + 2) return;

    const box = win.child(.{
        .x_off = (win.width - width) / 2,
        .y_off = (win.height -| height) / 3,
        .width = width,
        .height = height,
        .border = .{ .where = .all, .style = theme.border },
    });
    box.fill(.{ .style = .{ .bg = theme.color(theme.mocha.mantle) } });

    printAt(box, 2, 0, "new event", theme.title);

    drawField(box, scratch, 2, .title, state.title, state.active_field);
    drawField(box, scratch, 3, .start, state.start, state.active_field);
    drawField(box, scratch, 4, .end, state.end, state.active_field);

    printAt(box, 2, 6, "Tab/Enter next · Enter on last creates · Esc cancels", theme.dim);
}

fn drawField(
    box: vaxis.Window,
    scratch: std.mem.Allocator,
    row: u16,
    field: Field,
    value: []const u8,
    active: Field,
) void {
    const is_active = field == active;
    const cursor: []const u8 = if (is_active) "▏" else "";
    const hint: []const u8 = if (field == .end and value.len == 0 and !is_active) "(1h)" else "";
    const line = std.fmt.allocPrint(scratch, "{s}  {s}{s}{s}", .{
        field.label(), value, cursor, hint,
    }) catch return;
    printAt(box, 2, row, line, if (is_active) theme.text else theme.subtle);
}

fn printAt(win: vaxis.Window, x: u16, y: u16, text: []const u8, style: vaxis.Style) void {
    if (y >= win.height or x >= win.width) return;
    var overlay_style = style;
    if (overlay_style.bg == .default) overlay_style.bg = theme.color(theme.mocha.mantle);
    const child = win.child(.{ .x_off = x, .y_off = y, .width = win.width - x, .height = 1 });
    _ = child.printSegment(.{ .text = text, .style = overlay_style }, .{});
}
