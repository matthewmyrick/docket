//! Notification sinks: herdr → terminal-notifier → osascript, auto-detected
//! in that priority order (SPEC §9). A failing sink falls through to the
//! next; delivery is best-effort and never takes the app down.

const std = @import("std");
const config_mod = @import("../config.zig");

pub const Sink = enum {
    herdr,
    terminal_notifier,
    osascript,
    none,
};

/// Pick the best available sink. Detection shells out to `which` once at
/// startup — not a hot path. `.auto` walks the priority order; a forced
/// choice is honored even if undetectable (send will then fall through).
pub fn detect(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    choice: config_mod.SinkChoice,
) Sink {
    switch (choice) {
        .herdr => return .herdr,
        .terminal_notifier => return .terminal_notifier,
        .osascript => return .osascript,
        .none => return .none,
        .auto => {},
    }
    if (environ_map.get("HERDR_SOCKET_PATH") != null or commandExists(gpa, io, "herdr"))
        return .herdr;
    if (commandExists(gpa, io, "terminal-notifier"))
        return .terminal_notifier;
    return .osascript; // always present on macOS
}

/// Deliver one notification. Tries `sink` first, then falls through the
/// remaining priority order (SPEC §9 / CONTRIBUTING §5). Failures are
/// swallowed — the caller has already dedup-logged, and a missed toast must
/// not crash a calendar.
pub fn send(
    gpa: std.mem.Allocator,
    io: std.Io,
    sink: Sink,
    title: []const u8,
    body: []const u8,
    url: []const u8,
) void {
    const chain = [_]Sink{ .herdr, .terminal_notifier, .osascript };
    var trying = false;
    for (chain) |candidate| {
        if (candidate == sink) trying = true;
        if (!trying) continue;
        if (sendOne(gpa, io, candidate, title, body, url)) return;
    }
}

/// True on confirmed delivery (exit 0).
fn sendOne(
    gpa: std.mem.Allocator,
    io: std.Io,
    sink: Sink,
    title: []const u8,
    body: []const u8,
    url: []const u8,
) bool {
    var script_buffer: [1024]u8 = undefined;
    const argv: []const []const u8 = switch (sink) {
        // Verified syntax (herdr >= 0.7): positional title, --body flag.
        .herdr => &.{ "herdr", "notification", "show", title, "--body", body },
        .terminal_notifier => if (url.len > 0)
            &.{ "terminal-notifier", "-title", title, "-message", body, "-open", url }
        else
            &.{ "terminal-notifier", "-title", title, "-message", body },
        .osascript => &.{
            "osascript",                                                       "-e",
            osascriptDisplay(&script_buffer, title, body) orelse return false,
        },
        .none => return true, // configured off: swallow silently, don't fall through
    };
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Build `display notification "body" with title "title" sound name "Glass"`
/// with quotes/backslashes escaped. Null if it can't fit the buffer.
fn osascriptDisplay(buffer: []u8, title: []const u8, body: []const u8) ?[]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    writer.writeAll("display notification \"") catch return null;
    writeEscaped(&writer, body) catch return null;
    writer.writeAll("\" with title \"") catch return null;
    writeEscaped(&writer, title) catch return null;
    writer.writeAll("\" sound name \"Glass\"") catch return null;
    return writer.buffered();
}

fn writeEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '"', '\\' => {
                try writer.writeByte('\\');
                try writer.writeByte(byte);
            },
            else => try writer.writeByte(byte),
        }
    }
}

fn commandExists(gpa: std.mem.Allocator, io: std.Io, name: []const u8) bool {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "which", name },
    }) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "osascript escaping of quotes and backslashes" {
    var buffer: [256]u8 = undefined;
    const script = osascriptDisplay(&buffer, "He said \"hi\"", "back\\slash").?;
    try std.testing.expectEqualStrings(
        "display notification \"back\\\\slash\" with title \"He said \\\"hi\\\"\" sound name \"Glass\"",
        script,
    );
}

test "osascript script too long returns null" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        osascriptDisplay(&buffer, "a long title", "a long body"),
    );
}
