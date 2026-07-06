//! Diagnostics routing (CODING_STANDARDS §11): code logs through std.log;
//! this wrapper decides where it goes. TUI mode is silent (stderr belongs
//! to vaxis); --daemon/--agenda write to stderr. std.debug.print never
//! ships.

const std = @import("std");

pub const Mode = enum { silent, stderr };

/// Set once in main before any logging; never changed after threads start.
pub var mode: Mode = .silent;
/// Daemon cycle lines are .debug — visible only when ICAL_TUI_DEBUG is set
/// (ARCHITECTURE.md §10: "debug level, silent otherwise").
pub var min_level: std.log.Level = .info;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (mode == .silent) return;
    if (@intFromEnum(level) > @intFromEnum(min_level)) return;
    std.log.defaultLog(level, scope, format, args);
}
