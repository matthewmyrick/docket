//! Immutable snapshot of calendar data plus the arena that owns every byte
//! of it. Built fresh per fetch, published by pointer swap, freed wholesale
//! (SPEC §4, §12). Nothing inside a snapshot is ever freed individually.

const std = @import("std");
const event_mod = @import("calendar/event.zig");
const source_mod = @import("calendar/source.zig");
const time_mod = @import("calendar/time.zig");

const Event = event_mod.Event;

/// Snapshot-build-time filtering (SPEC §11): sources always fetch
/// everything; exclusions apply here so both sources stay simple.
pub const Filter = struct {
    calendars_exclude: []const []const u8 = &.{},
    show_declined: bool = false,

    pub fn keeps(self: Filter, event: Event) bool {
        if (!self.show_declined and event.self_rsvp == .declined) return false;
        for (self.calendars_exclude) |excluded| {
            if (std.mem.eql(u8, event.calendar_name, excluded)) return false;
        }
        return true;
    }
};

pub const Snapshot = struct {
    /// Owns all events, attendees, and strings below. The struct itself is
    /// allocated inside its own arena, so deinit() frees everything at once.
    arena: std.heap.ArenaAllocator,
    /// Sorted by event_mod.lessThan (all-day first, start, title).
    events: []Event,
    /// Fetch window this snapshot covers (unix seconds UTC).
    window_from: i64,
    window_to: i64,
    /// When the fetch completed (unix seconds UTC).
    fetched_at: i64,

    /// Fetch [from, to] from `source` into a brand-new snapshot. The returned
    /// pointer lives inside its own arena — release with `deinit()`, never
    /// free pieces of it. `gpa` only backs the arena itself.
    pub fn build(
        gpa: std.mem.Allocator,
        source: *source_mod.CalendarSource,
        from: i64,
        to: i64,
        now: i64,
        filter: Filter,
    ) (source_mod.FetchError || std.mem.Allocator.Error)!*Snapshot {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();

        const self = try arena.allocator().create(Snapshot);
        const fetched = try source.fetch(arena.allocator(), from, to);
        var kept: usize = 0;
        for (fetched) |event| {
            if (filter.keeps(event)) {
                fetched[kept] = event;
                kept += 1;
            }
        }
        self.* = .{
            .arena = arena,
            .events = fetched[0..kept],
            .window_from = from,
            .window_to = to,
            .fetched_at = now,
        };
        return self;
    }

    /// Free the whole snapshot. The pointer (and every slice handed out from
    /// this snapshot) is invalid afterwards.
    pub fn deinit(self: *Snapshot) void {
        // Move the arena out first: it owns the memory `self` lives in.
        var arena = self.arena;
        arena.deinit();
    }

    /// Events overlapping the local day `date`, appended to `out` in sorted
    /// order. Returns the filled slice. Bounded by out.len — a day showing
    /// more events than fits the UI simply truncates.
    pub fn eventsOnDay(
        self: *const Snapshot,
        out: []Event,
        date: time_mod.CivilDate,
        zone: time_mod.Zone,
    ) []Event {
        const bounds = time_mod.dayBounds(date, zone);
        var count: usize = 0;
        for (self.events) |event| {
            if (count == out.len) break;
            if (event.overlaps(bounds.start, bounds.end)) {
                out[count] = event;
                count += 1;
            }
        }
        return out[0..count];
    }

    /// Number of events overlapping the local day `date`.
    pub fn countOnDay(self: *const Snapshot, date: time_mod.CivilDate, zone: time_mod.Zone) usize {
        const bounds = time_mod.dayBounds(date, zone);
        var count: usize = 0;
        for (self.events) |event| {
            if (event.overlaps(bounds.start, bounds.end)) count += 1;
        }
        return count;
    }

    /// The next event that hasn't started yet (all-day events excluded —
    /// a countdown to midnight is noise). Events are sorted, but all-day
    /// entries sort first, so scan.
    pub fn nextUpcoming(self: *const Snapshot, now: i64) ?Event {
        var best: ?Event = null;
        for (self.events) |event| {
            if (event.all_day or event.start <= now) continue;
            if (best == null or event.start < best.?.start) best = event;
        }
        return best;
    }
};

const ical_cli = @import("calendar/ical_cli.zig");

fn testSnapshot(gpa: std.mem.Allocator) !*Snapshot {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const self = try arena.allocator().create(Snapshot);
    const events = try ical_cli.parse(
        arena.allocator(),
        @embedFile("ical-list-sample.json"),
        @embedFile("ical-calendars-sample.json"),
    );
    self.* = .{
        .arena = arena,
        .events = events,
        .window_from = 0,
        .window_to = std.math.maxInt(i64),
        .fetched_at = 0,
    };
    return self;
}

test "eventsOnDay and countOnDay slice by local day" {
    const snapshot = try testSnapshot(std.testing.allocator);
    defer snapshot.deinit();

    // Jul 7 2026 UTC: standup, lunch, 1:1, plus the Planning Week all-day span.
    var buffer: [16]Event = undefined;
    const jul7 = snapshot.eventsOnDay(&buffer, .{ .year = 2026, .month = 7, .day = 7 }, .utc);
    try std.testing.expectEqual(@as(usize, 4), jul7.len);
    try std.testing.expectEqualStrings("Q3 Planning Week", jul7[0].title);

    try std.testing.expectEqual(@as(usize, 1), snapshot.countOnDay(.{ .year = 2026, .month = 7, .day = 4 }, .utc));
    try std.testing.expectEqual(@as(usize, 0), snapshot.countOnDay(.{ .year = 2026, .month = 7, .day = 20 }, .utc));
}

test "nextUpcoming skips all-day and started events" {
    const snapshot = try testSnapshot(std.testing.allocator);
    defer snapshot.deinit();

    const noon_jul7 = try time_mod.parseRfc3339("2026-07-07T17:00:00Z");
    const next = snapshot.nextUpcoming(noon_jul7) orelse return error.TestExpectedEvent;
    try std.testing.expectEqualStrings("Lunch w/ Sam", next.title);

    const late = try time_mod.parseRfc3339("2026-07-08T00:00:00Z");
    try std.testing.expectEqual(@as(?Event, null), snapshot.nextUpcoming(late));
}

test "Filter: calendar exclusion and declined events" {
    const declined: Event = .{
        .id = "x",
        .calendar_name = "Work",
        .calendar_color = 0,
        .title = "t",
        .start = 0,
        .end = 1,
        .all_day = false,
        .location = "",
        .notes = "",
        .url = "",
        .video_link = "",
        .attendees = &.{},
        .is_recurring = false,
        .self_rsvp = .declined,
    };
    var accepted = declined;
    accepted.self_rsvp = .accepted;

    const default_filter: Filter = .{};
    try std.testing.expect(!default_filter.keeps(declined));
    try std.testing.expect(default_filter.keeps(accepted));

    const show_declined: Filter = .{ .show_declined = true };
    try std.testing.expect(show_declined.keeps(declined));

    const excluded: Filter = .{ .calendars_exclude = &.{ "Birthdays", "Work" } };
    try std.testing.expect(!excluded.keeps(accepted));
}
