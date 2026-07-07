//! The event form: one overlay for creating (`a`) and editing (`e`) events.
//! Every field except title and when is optional — blank simply means
//! "default" or "unchanged". Submission becomes a non-interactive `ical
//! add`/`ical update`; the CLI owns date parsing and validation.

const std = @import("std");
const vaxis = @import("vaxis");
const theme = @import("theme.zig");

pub const max_field = 96;

pub const Mode = enum { add, edit };

pub const Field = enum {
    title,
    date,
    time,
    until,
    calendar,
    location,
    invite,

    pub fn label(self: Field) []const u8 {
        return switch (self) {
            .title => "title   ",
            .date => "date    ",
            .time => "time    ",
            .until => "until   ",
            .calendar => "calendar",
            .location => "location",
            .invite => "invite  ",
        };
    }

    /// Grayed hint shown while the field is empty and inactive; the time
    /// hint always shows so "blank = all-day" is discoverable.
    fn hint(self: Field, mode: Mode) []const u8 {
        return switch (self) {
            .title => "(required)",
            .date => "(required — \"friday\" and \"jul 20\" work too)",
            .time => "(e.g. 3pm or 15:00 · blank = all-day)",
            .until => if (mode == .add) "(4:30pm or 2h · blank = 1h)" else "(unchanged)",
            .calendar => if (mode == .add) "(default)" else "(unchanged)",
            .location => "",
            .invite => "(emails, comma-separated — sends invitations)",
        };
    }
};

pub const field_count = @typeInfo(Field).@"enum".fields.len;

/// Fields shown per mode: `ical update` can't add invitees, so edit hides
/// that field.
pub fn fields(mode: Mode) []const Field {
    const all = comptime std.enums.values(Field);
    return switch (mode) {
        .add => all,
        .edit => all[0 .. field_count - 1],
    };
}

pub const State = struct {
    mode: Mode,
    values: [field_count][]const u8,
    active_index: usize,
};

pub fn draw(win: vaxis.Window, scratch: std.mem.Allocator, state: State) void {
    const visible = fields(state.mode);
    const width: u16 = @min(72, win.width -| 4);
    const height: u16 = @as(u16, @intCast(visible.len)) + 4;
    if (win.width < width + 2 or win.height < height + 2) return;

    const box = win.child(.{
        .x_off = (win.width - width) / 2,
        .y_off = (win.height -| height) / 3,
        .width = width,
        .height = height,
        .border = .{ .where = .all, .style = theme.border },
    });
    box.fill(.{ .style = .{ .bg = theme.color(theme.mocha.mantle) } });

    printAt(box, 2, 0, switch (state.mode) {
        .add => "new event",
        .edit => "edit event",
    }, theme.title);

    for (visible, 0..) |field, i| {
        const row: u16 = 2 + @as(u16, @intCast(i));
        const is_active = i == state.active_index;
        const value = state.values[@intFromEnum(field)];
        const cursor: []const u8 = if (is_active) "▏" else "";
        // The time hint stays visible while typing there — it's how
        // "blank = all-day" gets discovered.
        const show_hint = value.len == 0 and (!is_active or field == .time);
        const hint: []const u8 = if (show_hint) field.hint(state.mode) else "";
        const line = std.fmt.allocPrint(scratch, "{s}  {s}{s} {s}", .{
            field.label(), value, cursor, hint,
        }) catch return;
        printAt(box, 2, row, line, if (is_active) theme.text else theme.subtle);
    }

    printAt(
        box,
        2,
        height - 2,
        "Enter/Tab next · ↑↓ move · Enter on last saves · Esc cancels",
        theme.dim,
    );
}

fn printAt(win: vaxis.Window, x: u16, y: u16, text: []const u8, style: vaxis.Style) void {
    if (y >= win.height or x >= win.width) return;
    var overlay_style = style;
    if (overlay_style.bg == .default) overlay_style.bg = theme.color(theme.mocha.mantle);
    const child = win.child(.{ .x_off = x, .y_off = y, .width = win.width - x, .height = 1 });
    _ = child.printSegment(.{ .text = text, .style = overlay_style }, .{});
}

/// "3pm" / "3:15pm" / "15:00" → minutes after midnight. Null when the text
/// isn't a recognizable clock time (the CLI's richer parser gets it then).
pub fn parseTimeOfDay(text: []const u8) ?u32 {
    var s = std.mem.trim(u8, text, " ");
    var pm = false;
    var has_meridiem = false;
    if (s.len >= 2) {
        const tail = s[s.len - 2 ..];
        if (std.ascii.eqlIgnoreCase(tail, "pm")) {
            pm = true;
            has_meridiem = true;
        } else if (std.ascii.eqlIgnoreCase(tail, "am")) {
            has_meridiem = true;
        }
        if (has_meridiem) s = std.mem.trim(u8, s[0 .. s.len - 2], " ");
    }
    if (s.len == 0) return null;

    var hour: u32 = undefined;
    var minute: u32 = 0;
    if (std.mem.indexOfScalar(u8, s, ':')) |colon| {
        hour = std.fmt.parseInt(u32, s[0..colon], 10) catch return null;
        if (s.len - colon - 1 != 2) return null;
        minute = std.fmt.parseInt(u32, s[colon + 1 ..], 10) catch return null;
    } else {
        hour = std.fmt.parseInt(u32, s, 10) catch return null;
    }
    if (minute > 59) return null;
    if (has_meridiem) {
        if (hour < 1 or hour > 12) return null;
        if (hour == 12) hour = 0;
        if (pm) hour += 12;
    } else {
        if (hour > 23) return null;
    }
    return hour * 60 + minute;
}

/// "2h" / "45m" / "1h30m" / "1h 30m" → minutes. Null unless the whole text
/// is number+unit pairs (a bare number is ambiguous, so null).
pub fn parseDuration(text: []const u8) ?u32 {
    const s = std.mem.trim(u8, text, " ");
    if (s.len == 0) return null;
    var total: u32 = 0;
    var i: usize = 0;
    var pairs: usize = 0;
    while (i < s.len) {
        while (i < s.len and s[i] == ' ') i += 1;
        if (i == s.len) break;
        const digits_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == digits_start or i == s.len) return null; // no digits / no unit
        const value = std.fmt.parseInt(u32, s[digits_start..i], 10) catch return null;
        switch (std.ascii.toLower(s[i])) {
            'h' => total += value * 60,
            'm' => total += value,
            else => return null,
        }
        i += 1;
        pairs += 1;
    }
    if (pairs == 0 or total == 0 or total > 7 * 24 * 60) return null;
    return total;
}

test "edit mode hides the invite field" {
    try std.testing.expectEqual(@as(usize, field_count), fields(.add).len);
    try std.testing.expectEqual(@as(usize, field_count - 1), fields(.edit).len);
    try std.testing.expectEqual(Field.location, fields(.edit)[fields(.edit).len - 1]);
}

test "parseTimeOfDay: 12h, 24h, meridiem edge cases" {
    try std.testing.expectEqual(@as(?u32, 15 * 60), parseTimeOfDay("3pm"));
    try std.testing.expectEqual(@as(?u32, 15 * 60 + 15), parseTimeOfDay("3:15pm"));
    try std.testing.expectEqual(@as(?u32, 15 * 60 + 15), parseTimeOfDay("3:15 PM"));
    try std.testing.expectEqual(@as(?u32, 15 * 60), parseTimeOfDay("15:00"));
    try std.testing.expectEqual(@as(?u32, 9 * 60 + 5), parseTimeOfDay("9:05am"));
    try std.testing.expectEqual(@as(?u32, 0), parseTimeOfDay("12am"));
    try std.testing.expectEqual(@as(?u32, 12 * 60), parseTimeOfDay("12pm"));
    try std.testing.expectEqual(@as(?u32, null), parseTimeOfDay("25:00"));
    try std.testing.expectEqual(@as(?u32, null), parseTimeOfDay("13pm"));
    try std.testing.expectEqual(@as(?u32, null), parseTimeOfDay("3:5pm"));
    try std.testing.expectEqual(@as(?u32, null), parseTimeOfDay("noonish"));
}

test "parseDuration: h/m combos, rejects ambiguity" {
    try std.testing.expectEqual(@as(?u32, 120), parseDuration("2h"));
    try std.testing.expectEqual(@as(?u32, 45), parseDuration("45m"));
    try std.testing.expectEqual(@as(?u32, 75), parseDuration("1h15m"));
    try std.testing.expectEqual(@as(?u32, 75), parseDuration("1h 15m"));
    try std.testing.expectEqual(@as(?u32, null), parseDuration("90")); // bare number: ambiguous
    try std.testing.expectEqual(@as(?u32, null), parseDuration("3pm")); // that's a time
    try std.testing.expectEqual(@as(?u32, null), parseDuration("0m"));
    try std.testing.expectEqual(@as(?u32, null), parseDuration(""));
}
