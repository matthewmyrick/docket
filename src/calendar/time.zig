//! All timezone and civil-calendar math for the app. Timestamps are i64 unix
//! seconds UTC everywhere else; this module is the only place that converts
//! them to/from local calendar dates (CODING_STANDARDS §11).

const std = @import("std");

/// A calendar date in some (implied) timezone. Field ranges are the human
/// ones: month 1–12, day 1–31.
pub const CivilDate = struct {
    year: i32,
    month: u8,
    day: u8,

    pub fn eql(a: CivilDate, b: CivilDate) bool {
        return a.year == b.year and a.month == b.month and a.day == b.day;
    }
};

/// A wall-clock time of day.
pub const CivilTime = struct {
    hour: u8,
    minute: u8,
    second: u8,
};

pub const CivilDateTime = struct {
    date: CivilDate,
    time: CivilTime,
};

/// Days of the week, ISO order (Monday first).
pub const Weekday = enum(u3) {
    monday,
    tuesday,
    wednesday,
    thursday,
    friday,
    saturday,
    sunday,
};

/// Days since 1970-01-01 for a civil date (proleptic Gregorian).
/// Howard Hinnant's `days_from_civil` algorithm.
pub fn daysFromCivil(date: CivilDate) i64 {
    const y: i64 = if (date.month <= 2) date.year - 1 else date.year;
    const m: i64 = date.month;
    const d: i64 = date.day;
    const era: i64 = @divFloor(y, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const mp: i64 = @mod(m + 9, 12); // March = 0
    const doy: i64 = @divFloor(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Civil date for a count of days since 1970-01-01.
/// Howard Hinnant's `civil_from_days` algorithm.
pub fn civilFromDays(days: i64) CivilDate {
    const z: i64 = days + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097; // [0, 146096]
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp: i64 = @divFloor(5 * doy + 2, 153); // March = 0
    const d: i64 = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const m: i64 = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    return .{
        .year = @intCast(if (m <= 2) y + 1 else y), // year fits i32 for any sane date
        .month = @intCast(m), // [1, 12] fits u8
        .day = @intCast(d), // [1, 31] fits u8
    };
}

pub fn weekdayFromDays(days: i64) Weekday {
    // 1970-01-01 was a Thursday (ISO index 3).
    return @enumFromInt(@mod(days + 3, 7));
}

pub fn weekday(date: CivilDate) Weekday {
    return weekdayFromDays(daysFromCivil(date));
}

pub fn isLeapYear(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

pub fn daysInMonth(year: i32, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => unreachable, // months are validated at parse time
    };
}

/// The same date shifted by whole days (positive or negative).
pub fn addDays(date: CivilDate, delta: i64) CivilDate {
    return civilFromDays(daysFromCivil(date) + delta);
}

/// First day of the month `delta` months away, keeping nothing but year/month.
pub fn addMonths(date: CivilDate, delta: i32) CivilDate {
    const total: i32 = (date.year * 12) + (@as(i32, date.month) - 1) + delta;
    const y: i32 = @divFloor(total, 12);
    const m: i32 = @mod(total, 12) + 1;
    return .{ .year = y, .month = @intCast(m), .day = 1 };
}

/// Clamp a day-of-month into the target month (for month navigation that
/// keeps the selected day: Jul 31 -> Jun 30).
pub fn clampedDay(year: i32, month: u8, day: u8) u8 {
    return @min(day, daysInMonth(year, month));
}

/// A local timezone loaded from a TZif file, falling back to UTC when
/// unavailable. Owns the parsed transition table for the process lifetime.
pub const Zone = struct {
    tz: ?std.tz.Tz,

    pub const utc: Zone = .{ .tz = null };

    /// Load the system timezone from /etc/localtime. Result owns memory from
    /// `gpa`; free with `deinit`. Falls back to UTC (never errors) — a wrong
    /// clock display is better than refusing to start.
    pub fn loadLocal(gpa: std.mem.Allocator, io: std.Io) Zone {
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            io,
            "/etc/localtime",
            gpa,
            .limited(1024 * 1024),
        ) catch return .utc;
        defer gpa.free(bytes);
        var reader: std.Io.Reader = .fixed(bytes);
        const tz = std.tz.Tz.parse(gpa, &reader) catch return .utc;
        return .{ .tz = tz };
    }

    pub fn deinit(self: *Zone) void {
        if (self.tz) |*tz| tz.deinit();
        self.tz = null;
    }

    /// UTC offset in seconds in effect at the given instant.
    pub fn utcOffsetAt(self: Zone, unix: i64) i32 {
        const tz = self.tz orelse return 0;
        if (tz.transitions.len == 0) {
            if (tz.timetypes.len > 0) return tz.timetypes[0].offset;
            return 0;
        }
        // Binary search: last transition with ts <= unix.
        var lo: usize = 0;
        var hi: usize = tz.transitions.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (tz.transitions[mid].ts <= unix) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return tz.timetypes[0].offset;
        return tz.transitions[lo - 1].timetype.offset;
    }
};

/// Local civil date+time for a UTC instant.
pub fn civilFromUnix(unix: i64, zone: Zone) CivilDateTime {
    const local = unix + zone.utcOffsetAt(unix);
    const days = @divFloor(local, 86400);
    const secs = @mod(local, 86400);
    return .{
        .date = civilFromDays(days),
        .time = .{
            .hour = @intCast(@divFloor(secs, 3600)), // [0, 23] fits u8
            .minute = @intCast(@mod(@divFloor(secs, 60), 60)),
            .second = @intCast(@mod(secs, 60)),
        },
    };
}

pub fn localDate(unix: i64, zone: Zone) CivilDate {
    return civilFromUnix(unix, zone).date;
}

/// UTC instant for a local civil date+time. Around DST transitions a local
/// time can be ambiguous or nonexistent; this returns a best-effort instant
/// (the post-transition interpretation), which is fine for day boundaries.
pub fn unixFromCivil(date: CivilDate, time: CivilTime, zone: Zone) i64 {
    const local: i64 = daysFromCivil(date) * 86400 +
        @as(i64, time.hour) * 3600 + @as(i64, time.minute) * 60 + time.second;
    // Guess using the offset at the local instant interpreted as UTC, then
    // refine once — converges for every real-world timezone.
    var guess = local - zone.utcOffsetAt(local);
    guess = local - zone.utcOffsetAt(guess);
    return guess;
}

/// Unix range [start, end) covering one local calendar day.
pub fn dayBounds(date: CivilDate, zone: Zone) struct { start: i64, end: i64 } {
    const start = unixFromCivil(date, .{ .hour = 0, .minute = 0, .second = 0 }, zone);
    const end = unixFromCivil(addDays(date, 1), .{ .hour = 0, .minute = 0, .second = 0 }, zone);
    return .{ .start = start, .end = end };
}

pub const ParseError = error{InvalidTimestamp};

/// Parse an RFC 3339 / ISO 8601 timestamp ("2026-07-07T16:00:00Z",
/// fractional seconds and ±HH:MM offsets accepted) into unix seconds UTC.
pub fn parseRfc3339(s: []const u8) ParseError!i64 {
    if (s.len < 19) return error.InvalidTimestamp;
    const year = parseDigits(i32, s[0..4]) orelse return error.InvalidTimestamp;
    if (s[4] != '-') return error.InvalidTimestamp;
    const month = parseDigits(u8, s[5..7]) orelse return error.InvalidTimestamp;
    if (s[7] != '-') return error.InvalidTimestamp;
    const day = parseDigits(u8, s[8..10]) orelse return error.InvalidTimestamp;
    if (s[10] != 'T' and s[10] != 't' and s[10] != ' ') return error.InvalidTimestamp;
    const hour = parseDigits(u8, s[11..13]) orelse return error.InvalidTimestamp;
    if (s[13] != ':') return error.InvalidTimestamp;
    const minute = parseDigits(u8, s[14..16]) orelse return error.InvalidTimestamp;
    if (s[16] != ':') return error.InvalidTimestamp;
    const second = parseDigits(u8, s[17..19]) orelse return error.InvalidTimestamp;
    if (month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 60)
        return error.InvalidTimestamp;
    if (day > daysInMonth(year, month)) return error.InvalidTimestamp;

    var i: usize = 19;
    // Skip fractional seconds; whole-second precision is plenty for a calendar.
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    if (i >= s.len) return error.InvalidTimestamp;

    var offset: i64 = 0;
    switch (s[i]) {
        'Z', 'z' => {
            if (i + 1 != s.len) return error.InvalidTimestamp;
        },
        '+', '-' => {
            if (i + 6 != s.len or s[i + 3] != ':') return error.InvalidTimestamp;
            const oh = parseDigits(u8, s[i + 1 .. i + 3]) orelse return error.InvalidTimestamp;
            const om = parseDigits(u8, s[i + 4 .. i + 6]) orelse return error.InvalidTimestamp;
            if (oh > 23 or om > 59) return error.InvalidTimestamp;
            offset = @as(i64, oh) * 3600 + @as(i64, om) * 60;
            if (s[i] == '-') offset = -offset;
        },
        else => return error.InvalidTimestamp,
    }

    const days = daysFromCivil(.{ .year = year, .month = month, .day = day });
    const secs: i64 = @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @min(second, 59);
    return days * 86400 + secs - offset;
}

fn parseDigits(comptime T: type, s: []const u8) ?T {
    var value: T = 0;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return null;
        value = std.math.mul(T, value, 10) catch return null;
        value = std.math.add(T, value, @intCast(c - '0')) catch return null;
    }
    return value;
}

pub const month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

pub const weekday_names_short = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
pub const weekday_names_long = [_][]const u8{
    "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
};

test "civil <-> days round trip and known anchors" {
    // 1970-01-01 is day 0, a Thursday.
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(.{ .year = 1970, .month = 1, .day = 1 }));
    try std.testing.expectEqual(Weekday.thursday, weekday(.{ .year = 1970, .month = 1, .day = 1 }));
    // 2026-07-06 (spec-writing day) is a Monday.
    try std.testing.expectEqual(Weekday.monday, weekday(.{ .year = 2026, .month = 7, .day = 6 }));

    var day: i64 = -1000;
    while (day < 100_000) : (day += 997) {
        const date = civilFromDays(day);
        try std.testing.expectEqual(day, daysFromCivil(date));
    }
}

test "leap years and month lengths" {
    try std.testing.expect(isLeapYear(2024));
    try std.testing.expect(!isLeapYear(2100));
    try std.testing.expect(isLeapYear(2000));
    try std.testing.expectEqual(@as(u8, 29), daysInMonth(2024, 2));
    try std.testing.expectEqual(@as(u8, 28), daysInMonth(2026, 2));
    try std.testing.expectEqual(@as(u8, 30), daysInMonth(2026, 6));
}

test "addMonths crosses year boundaries" {
    const jan = CivilDate{ .year = 2026, .month = 1, .day = 15 };
    try std.testing.expectEqual(CivilDate{ .year = 2025, .month = 12, .day = 1 }, addMonths(jan, -1));
    try std.testing.expectEqual(CivilDate{ .year = 2027, .month = 1, .day = 1 }, addMonths(jan, 12));
}

test "parseRfc3339 UTC, offset, and fractional forms" {
    // 2026-07-07T16:00:00Z == 1783526400
    const base = try parseRfc3339("2026-07-07T16:00:00Z");
    try std.testing.expectEqual(
        daysFromCivil(.{ .year = 2026, .month = 7, .day = 7 }) * 86400 + 16 * 3600,
        base,
    );
    try std.testing.expectEqual(base, try parseRfc3339("2026-07-07T16:00:00.123Z"));
    // Same instant expressed at +05:30.
    try std.testing.expectEqual(base, try parseRfc3339("2026-07-07T21:30:00+05:30"));
    try std.testing.expectEqual(base, try parseRfc3339("2026-07-07T11:00:00-05:00"));

    try std.testing.expectError(error.InvalidTimestamp, parseRfc3339("2026-07-07"));
    try std.testing.expectError(error.InvalidTimestamp, parseRfc3339("2026-13-07T00:00:00Z"));
    try std.testing.expectError(error.InvalidTimestamp, parseRfc3339("2026-02-30T00:00:00Z"));
    try std.testing.expectError(error.InvalidTimestamp, parseRfc3339("2026-07-07T16:00:00"));
}

test "UTC zone conversions" {
    const zone: Zone = .utc;
    const ts = try parseRfc3339("2026-07-07T16:30:45Z");
    const civil = civilFromUnix(ts, zone);
    try std.testing.expectEqual(CivilDate{ .year = 2026, .month = 7, .day = 7 }, civil.date);
    try std.testing.expectEqual(@as(u8, 16), civil.time.hour);
    try std.testing.expectEqual(@as(u8, 30), civil.time.minute);
    try std.testing.expectEqual(@as(u8, 45), civil.time.second);
    try std.testing.expectEqual(ts, unixFromCivil(civil.date, civil.time, zone));
}

test "dayBounds covers exactly one day in UTC" {
    const bounds = dayBounds(.{ .year = 2026, .month = 7, .day = 7 }, .utc);
    try std.testing.expectEqual(@as(i64, 86400), bounds.end - bounds.start);
}

test "DST transition: offsets flip and the day is 23h long" {
    // US Eastern, spring forward 2026-03-08 07:00 UTC (02:00 EST -> 03:00 EDT).
    const spring_forward: i64 = try parseRfc3339("2026-03-08T07:00:00Z");
    var timetypes = [_]std.tz.Timetype{
        .{ .offset = -18000, .flags = 0, .name_data = nameData("EST") },
        .{ .offset = -14400, .flags = 1, .name_data = nameData("EDT") },
    };
    var transitions = [_]std.tz.Transition{
        .{ .ts = spring_forward, .timetype = &timetypes[1] },
    };
    const zone: Zone = .{
        .tz = .{
            .allocator = std.testing.allocator, // never deinited; slices are stack-owned
            .transitions = &transitions,
            .timetypes = &timetypes,
            .leapseconds = &.{},
            .footer = null,
        },
    };

    try std.testing.expectEqual(@as(i32, -18000), zone.utcOffsetAt(spring_forward - 1));
    try std.testing.expectEqual(@as(i32, -14400), zone.utcOffsetAt(spring_forward));

    const bounds = dayBounds(.{ .year = 2026, .month = 3, .day = 8 }, zone);
    try std.testing.expectEqual(@as(i64, 23 * 3600), bounds.end - bounds.start);

    // Local wall clock just before/after the jump maps back to the right side.
    const before = civilFromUnix(spring_forward - 60, zone);
    try std.testing.expectEqual(@as(u8, 1), before.time.hour);
    const after = civilFromUnix(spring_forward + 60, zone);
    try std.testing.expectEqual(@as(u8, 3), after.time.hour);
}

fn nameData(comptime name: []const u8) [6:0]u8 {
    var out: [6:0]u8 = @splat(0);
    @memcpy(out[0..name.len], name);
    return out;
}
