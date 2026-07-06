//! Configuration: ~/.config/ical-calendar-tui/config.zon, parsed with
//! std.zon (SPEC §11). Missing file = all defaults. Unknown keys are a hard
//! error naming the key — silent typos are how configs rot.

const std = @import("std");

pub const SourceChoice = enum { auto, eventkit, ical_cli };
pub const SinkChoice = enum { auto, herdr, terminal_notifier, osascript, none };
pub const WeekStart = enum { monday, sunday };

const min_poll_interval: u32 = 15;
const max_poll_interval: u32 = 3600;
const max_config_bytes = 64 * 1024;

pub const Config = struct {
    poll_interval_seconds: u32 = 60,
    source: SourceChoice = .auto,
    lead_times_minutes: []const u32 = &.{ 10, 1 },
    all_day_notify_at: ?[]const u8 = null,
    notify_sink: SinkChoice = .auto,
    week_start: WeekStart = .monday,
    calendars_exclude: []const []const u8 = &.{},
    show_declined: bool = false,

    /// `all_day_notify_at` as minutes after local midnight, validated at load.
    all_day_notify_minutes: ?u16 = null,
};

pub const LoadError = error{InvalidConfig} || std.mem.Allocator.Error;

/// Load config from `<config_dir>/config.zon`. All slices in the result are
/// owned by `arena` and live as long as it. On any config problem this
/// returns error.InvalidConfig after writing a human explanation to
/// `error_buffer` (see `errorMessage`).
pub fn load(
    arena: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    error_buffer: *[256]u8,
) LoadError!Config {
    const bytes = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        config_path,
        arena,
        .limited(max_config_bytes),
        .of(u8),
        0, // sentinel-terminated for the zon parser
    ) catch |err| switch (err) {
        error.FileNotFound => return .{}, // no file = all defaults
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            setMessage(error_buffer, "config unreadable at {s}: {t}", .{ config_path, err });
            return error.InvalidConfig;
        },
    };

    var diagnostics: std.zon.parse.Diagnostics = .{};
    defer diagnostics.deinit(arena);
    const parsed = std.zon.parse.fromSliceAlloc(Config, arena, bytes, &diagnostics, .{
        .free_on_error = false, // arena-backed; freed wholesale
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            setMessage(error_buffer, "config parse failed at {s}: {f}", .{ config_path, diagnostics });
            return error.InvalidConfig;
        },
    };
    return validate(parsed, error_buffer);
}

/// Range-checks and derives fields. Pure — table-tested below.
fn validate(config: Config, error_buffer: *[256]u8) LoadError!Config {
    var out = config;
    out.poll_interval_seconds = std.math.clamp(
        config.poll_interval_seconds,
        min_poll_interval,
        max_poll_interval,
    );
    if (config.lead_times_minutes.len > 16) {
        setMessage(error_buffer, "config: lead_times_minutes supports at most 16 entries", .{});
        return error.InvalidConfig;
    }
    for (config.lead_times_minutes) |lead| {
        if (lead == 0 or lead > 24 * 60) {
            setMessage(error_buffer, "config: lead_times_minutes entry {d} outside 1..1440", .{lead});
            return error.InvalidConfig;
        }
    }
    if (config.all_day_notify_at) |at| {
        out.all_day_notify_minutes = parseClockTime(at) orelse {
            setMessage(error_buffer, "config: all_day_notify_at \"{s}\" is not HH:MM", .{at});
            return error.InvalidConfig;
        };
    }
    return out;
}

/// "HH:MM" → minutes after midnight, or null.
fn parseClockTime(s: []const u8) ?u16 {
    if (s.len != 5 or s[2] != ':') return null;
    const hour = std.fmt.parseInt(u16, s[0..2], 10) catch return null;
    const minute = std.fmt.parseInt(u16, s[3..5], 10) catch return null;
    if (hour > 23 or minute > 59) return null;
    return hour * 60 + minute;
}

fn setMessage(buffer: *[256]u8, comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(buffer, fmt, args) catch {
        // Message truncated; keep what fits (buffer already holds the prefix).
        return;
    };
    // Zero-terminate the logical end by storing length in-band: callers use
    // errorMessage() to recover the slice.
    if (written.len < buffer.len) buffer[written.len] = 0;
}

/// The message written by a failed `load`, up to the first NUL.
pub fn errorMessage(buffer: *const [256]u8) []const u8 {
    return std.mem.sliceTo(buffer, 0);
}

test "defaults when file missing fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var error_buffer: [256]u8 = @splat(0);

    const parsed = try std.zon.parse.fromSliceAlloc(
        Config,
        arena_state.allocator(),
        ".{ .poll_interval_seconds = 120 }",
        null,
        .{ .free_on_error = false },
    );
    const config = try validate(parsed, &error_buffer);
    try std.testing.expectEqual(@as(u32, 120), config.poll_interval_seconds);
    try std.testing.expectEqual(SourceChoice.auto, config.source);
    try std.testing.expectEqualSlices(u32, &.{ 10, 1 }, config.lead_times_minutes);
    try std.testing.expectEqual(WeekStart.monday, config.week_start);
}

test "unknown keys are a hard error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostics: std.zon.parse.Diagnostics = .{};
    defer diagnostics.deinit(arena_state.allocator());

    const result = std.zon.parse.fromSliceAlloc(
        Config,
        arena_state.allocator(),
        ".{ .pol_interval_seconds = 120 }",
        &diagnostics,
        .{ .free_on_error = false },
    );
    try std.testing.expectError(error.ParseZon, result);
}

test "poll interval clamps; bad leads and clock times rejected" {
    var error_buffer: [256]u8 = @splat(0);

    const clamped = try validate(.{ .poll_interval_seconds = 1 }, &error_buffer);
    try std.testing.expectEqual(min_poll_interval, clamped.poll_interval_seconds);

    try std.testing.expectError(
        error.InvalidConfig,
        validate(.{ .lead_times_minutes = &.{0} }, &error_buffer),
    );

    const with_all_day = try validate(.{ .all_day_notify_at = "09:30" }, &error_buffer);
    try std.testing.expectEqual(@as(?u16, 9 * 60 + 30), with_all_day.all_day_notify_minutes);

    try std.testing.expectError(
        error.InvalidConfig,
        validate(.{ .all_day_notify_at = "9am" }, &error_buffer),
    );
    try std.testing.expectError(
        error.InvalidConfig,
        validate(.{ .all_day_notify_at = "25:00" }, &error_buffer),
    );
}
