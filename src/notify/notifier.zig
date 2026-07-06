//! Notification decisions and the persistent dedup log (SPEC §9). The
//! decision logic (`pendingKey`) is pure and table-tested; the I/O edge is
//! the append-only, flock-coordinated log that lets the TUI and daemon run
//! simultaneously without double-firing.

const std = @import("std");
const event_mod = @import("../calendar/event.zig");
const time_mod = @import("../calendar/time.zig");
const sink_mod = @import("sink.zig");

const Event = event_mod.Event;

/// Dedup entries older than this are pruned at startup.
const prune_after_seconds: i64 = 7 * 24 * 3600;
/// Hard cap on in-memory dedup entries (bounded everything).
const max_entries = 8192;
/// An all-day reminder that couldn't fire within this window of its
/// scheduled time (laptop asleep) is dropped, not fired hours late.
const all_day_slack_seconds: i64 = 3600;
/// Key: "<lead>|<occurrence-start>|<event-id>", bounded.
const max_key_bytes = 320;
/// Notification titles are prefixed so a toast is recognizably ours at a
/// glance (macOS Calendar's own alerts stay unprefixed).
const title_prefix = "📅 ";

pub const Notifier = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Owns the fired-key strings; freed wholesale at deinit.
    arena: std.heap.ArenaAllocator,
    fired: std.StringHashMapUnmanaged(void),
    log_path: []const u8, // arena-owned
    /// Bytes of the log already ingested; the tail is re-read each scan to
    /// pick up entries a concurrently running TUI/daemon appended.
    log_offset: u64,
    sink: sink_mod.Sink,
    lead_times_minutes: []const u32, // config-owned
    all_day_notify_minutes: ?u16,

    /// `cache_dir` is created if missing. Reads the existing log and prunes
    /// entries older than 7 days. Result owns memory from `gpa`.
    pub fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        cache_dir: []const u8,
        sink: sink_mod.Sink,
        lead_times_minutes: []const u32,
        all_day_notify_minutes: ?u16,
        now: i64,
    ) !Notifier {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        std.Io.Dir.cwd().createDirPath(io, cache_dir) catch {}; // best-effort; log becomes memory-only
        const log_path = try std.fmt.allocPrint(arena.allocator(), "{s}/notified.log", .{cache_dir});

        var self: Notifier = .{
            .gpa = gpa,
            .io = io,
            .arena = arena,
            .fired = .empty,
            .log_path = log_path,
            .log_offset = 0,
            .sink = sink,
            .lead_times_minutes = lead_times_minutes,
            .all_day_notify_minutes = all_day_notify_minutes,
        };
        self.loadAndPrune(now) catch {}; // unreadable log = start fresh
        return self;
    }

    pub fn deinit(self: *Notifier) void {
        self.fired.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Scan a snapshot for events entering a notification window and fire
    /// each at most once program-wide (dedup log). Runs on the poller thread.
    pub fn scan(self: *Notifier, events: []const Event, now: i64, zone: time_mod.Zone) void {
        self.ingestNewEntries() catch {}; // another process may have fired

        for (events) |event| {
            if (event.self_rsvp == .declined) continue;
            if (event.all_day) {
                self.scanAllDay(event, now, zone);
                continue;
            }
            if (event.start <= now) continue; // already started
            for (self.lead_times_minutes) |lead| {
                if (!withinLeadWindow(event.start, lead, now)) continue;
                self.fire(event, lead, now, zone);
            }
        }
    }

    fn scanAllDay(self: *Notifier, event: Event, now: i64, zone: time_mod.Zone) void {
        const at_minutes = self.all_day_notify_minutes orelse return;
        const notify_at = allDayNotifyTime(event, at_minutes, zone);
        if (now < notify_at or now >= notify_at + all_day_slack_seconds) return;
        self.fire(event, 0, now, zone);
    }

    fn fire(self: *Notifier, event: Event, lead_minutes: u32, now: i64, zone: time_mod.Zone) void {
        var key_buffer: [max_key_bytes]u8 = undefined;
        const key = dedupKey(&key_buffer, event, lead_minutes) orelse return; // oversized id: skip
        if (self.fired.contains(key)) return;
        if (self.fired.count() >= max_entries) return; // cap reached: no unbounded growth

        // Record before firing: a duplicate toast is worse than a missed one
        // (macOS Calendar's own alerts still exist as backstop).
        self.recordFired(key, now) catch {};

        var body_buffer: [256]u8 = undefined;
        const body = notificationBody(&body_buffer, event, lead_minutes, zone) orelse return;
        var title_buffer: [256]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buffer, title_prefix ++ "{s}", .{event.title}) catch
            title_prefix ++ "event"; // pathological title length: keep the brand
        sink_mod.send(self.gpa, self.io, self.sink, title, body, event.video_link);
    }

    /// Append to the flocked log and remember in-memory.
    fn recordFired(self: *Notifier, key: []const u8, now: i64) !void {
        const owned_key = try self.arena.allocator().dupe(u8, key);
        try self.fired.put(self.gpa, owned_key, {});

        const file = std.Io.Dir.cwd().createFile(self.io, self.log_path, .{
            .truncate = false,
            .lock = .exclusive,
        }) catch return;
        defer file.close(self.io);
        const size = file.length(self.io) catch return;
        var line_buffer: [max_key_bytes + 32]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buffer, "{d} {s}\n", .{ now, key }) catch return;
        file.writePositionalAll(self.io, line, size) catch return;
        self.log_offset = size + line.len;
    }

    /// Read entries appended by a concurrent process since our last offset.
    fn ingestNewEntries(self: *Notifier) !void {
        const file = std.Io.Dir.cwd().openFile(self.io, self.log_path, .{}) catch return;
        defer file.close(self.io);
        const size = try file.length(self.io);
        if (size <= self.log_offset) return;
        const len: usize = @intCast(@min(size - self.log_offset, 1024 * 1024));
        const bytes = try self.gpa.alloc(u8, len);
        defer self.gpa.free(bytes);
        _ = try file.readPositionalAll(self.io, bytes, self.log_offset);
        self.log_offset = size;
        self.ingestLines(bytes, null);
    }

    /// Load the whole log, keep only fresh entries, rewrite the file.
    fn loadAndPrune(self: *Notifier, now: i64) !void {
        const file = std.Io.Dir.cwd().createFile(self.io, self.log_path, .{
            .truncate = false,
            .read = true,
            .lock = .exclusive,
        }) catch return;
        defer file.close(self.io);
        const size = try file.length(self.io);
        const len: usize = @intCast(@min(size, 4 * 1024 * 1024));
        const bytes = try self.gpa.alloc(u8, len);
        defer self.gpa.free(bytes);
        _ = try file.readPositionalAll(self.io, bytes, 0);

        self.ingestLines(bytes, now - prune_after_seconds);

        // Rewrite with only what we kept.
        var rewrite = std.array_list.Managed(u8).init(self.gpa);
        defer rewrite.deinit();
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const parsed = parseLine(line) orelse continue;
            if (parsed.fired_at < now - prune_after_seconds) continue;
            try rewrite.appendSlice(line);
            try rewrite.append('\n');
        }
        file.writePositionalAll(self.io, rewrite.items, 0) catch return;
        file.setLength(self.io, rewrite.items.len) catch {}; // best-effort
        self.log_offset = rewrite.items.len;
    }

    /// Parse `<ts> <key>` lines into the fired set. Entries older than
    /// `cutoff` (when non-null) are skipped.
    fn ingestLines(self: *Notifier, bytes: []const u8, cutoff: ?i64) void {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const parsed = parseLine(line) orelse continue;
            if (cutoff) |c| if (parsed.fired_at < c) continue;
            if (self.fired.count() >= max_entries) return;
            if (self.fired.contains(parsed.key)) continue;
            const owned = self.arena.allocator().dupe(u8, parsed.key) catch return;
            self.fired.put(self.gpa, owned, {}) catch return;
        }
    }
};

const LogLine = struct { fired_at: i64, key: []const u8 };

fn parseLine(line: []const u8) ?LogLine {
    const trimmed = std.mem.trim(u8, line, " \r");
    if (trimmed.len == 0) return null;
    const space = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return null;
    const fired_at = std.fmt.parseInt(i64, trimmed[0..space], 10) catch return null;
    const key = trimmed[space + 1 ..];
    if (key.len == 0 or key.len > max_key_bytes) return null;
    return .{ .fired_at = fired_at, .key = key };
}

/// One notification per (lead, occurrence start, event id).
fn dedupKey(buffer: *[max_key_bytes]u8, event: Event, lead_minutes: u32) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "{d}|{d}|{s}", .{
        lead_minutes, event.start, event.id,
    }) catch null;
}

/// Fire window for a timed event: [start - lead, start). Computed from
/// absolute event times so wall-clock jumps (sleep/wake) can't repeat or
/// skip based on tick counting (SPEC §8).
fn withinLeadWindow(start: i64, lead_minutes: u32, now: i64) bool {
    const lead_seconds = @as(i64, lead_minutes) * 60;
    return now >= start - lead_seconds and now < start;
}

/// Local HH:MM on the (local) day the all-day event starts.
fn allDayNotifyTime(event: Event, at_minutes: u16, zone: time_mod.Zone) i64 {
    const day = time_mod.localDate(event.start, zone);
    return time_mod.dayBounds(day, zone).start + @as(i64, at_minutes) * 60;
}

/// "in 10m · 09:00–09:30 · Zoom" — lead, local time range, then location or
/// video provider. One line; may render as a herdr toast.
fn notificationBody(
    buffer: []u8,
    event: Event,
    lead_minutes: u32,
    zone: time_mod.Zone,
) ?[]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    if (event.all_day) {
        writer.writeAll("today · all-day") catch return null;
    } else {
        const start = time_mod.civilFromUnix(event.start, zone);
        const end = time_mod.civilFromUnix(event.end, zone);
        writer.print("in {d}m · {d:0>2}:{d:0>2}–{d:0>2}:{d:0>2}", .{
            lead_minutes,
            start.time.hour,
            start.time.minute,
            end.time.hour,
            end.time.minute,
        }) catch return null;
    }
    const place = if (event.video_link.len > 0)
        event_mod.videoProviderName(event.video_link) orelse event.location
    else
        event.location;
    if (place.len > 0) writer.print(" · {s}", .{place}) catch return null;
    return writer.buffered();
}

fn testEvent(id: []const u8, start: i64, all_day: bool) Event {
    return .{
        .id = id,
        .calendar_name = "Work",
        .calendar_color = 0,
        .title = "Standup",
        .start = start,
        .end = start + 1800,
        .all_day = all_day,
        .location = "",
        .notes = "",
        .url = "",
        .video_link = "",
        .attendees = &.{},
        .is_recurring = false,
        .self_rsvp = .accepted,
    };
}

test "withinLeadWindow: fires inside [start-lead, start) only" {
    const start: i64 = 10_000;
    try std.testing.expect(!withinLeadWindow(start, 10, start - 601)); // too early
    try std.testing.expect(withinLeadWindow(start, 10, start - 600)); // window opens
    try std.testing.expect(withinLeadWindow(start, 10, start - 1)); // last second
    try std.testing.expect(!withinLeadWindow(start, 10, start)); // started
}

test "dedupKey distinguishes lead, occurrence, and id" {
    var a: [max_key_bytes]u8 = undefined;
    var b: [max_key_bytes]u8 = undefined;
    const event = testEvent("abc", 5000, false);
    try std.testing.expectEqualStrings("10|5000|abc", dedupKey(&a, event, 10).?);
    try std.testing.expect(!std.mem.eql(u8, dedupKey(&a, event, 10).?, dedupKey(&b, event, 1).?));
    const other = testEvent("abc", 9000, false);
    try std.testing.expect(!std.mem.eql(u8, dedupKey(&a, event, 10).?, dedupKey(&b, other, 10).?));
}

test "notificationBody formats lead, range, and provider" {
    var buffer: [256]u8 = undefined;
    var event = testEvent("abc", 9 * 3600, false); // 09:00–09:30 UTC
    event.video_link = "https://zoom.us/j/123";
    const body = notificationBody(&buffer, event, 10, .utc).?;
    try std.testing.expectEqualStrings("in 10m · 09:00–09:30 · Zoom", body);

    var plain = testEvent("abc", 9 * 3600, false);
    plain.location = "Cafe";
    const plain_body = notificationBody(&buffer, plain, 1, .utc).?;
    try std.testing.expectEqualStrings("in 1m · 09:00–09:30 · Cafe", plain_body);
}

test "parseLine round-trips and rejects garbage" {
    const parsed = parseLine("1783526400 10|5000|abc").?;
    try std.testing.expectEqual(@as(i64, 1783526400), parsed.fired_at);
    try std.testing.expectEqualStrings("10|5000|abc", parsed.key);
    try std.testing.expectEqual(@as(?LogLine, null), parseLine(""));
    try std.testing.expectEqual(@as(?LogLine, null), parseLine("notanumber key"));
}

test "allDayNotifyTime is HH:MM local on the start day" {
    // All-day event starting 2026-07-06 00:00 UTC; notify at 09:00.
    const start = time_mod.daysFromCivil(.{ .year = 2026, .month = 7, .day = 6 }) * 86400;
    const notify_at = allDayNotifyTime(testEvent("x", start, true), 9 * 60, .utc);
    try std.testing.expectEqual(start + 9 * 3600, notify_at);
}
