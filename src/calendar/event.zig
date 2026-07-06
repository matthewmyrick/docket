//! The calendar event model shared by every data source, plus the pure
//! logic that derives fields from raw data: video-link detection and the
//! canonical sort order. All strings on these structs are slices into the
//! owning snapshot's arena — nothing here is freed individually.

const std = @import("std");

pub const Rsvp = enum {
    accepted,
    declined,
    tentative,
    needs_action,
    unknown,

    /// Single-cell glyph for lists: your RSVP at a glance.
    pub fn glyph(self: Rsvp) []const u8 {
        return switch (self) {
            .accepted => "✓",
            .declined => "✗",
            .tentative => "?",
            .needs_action => "·",
            .unknown => " ",
        };
    }
};

pub const Attendee = struct {
    name: []const u8, // may be empty
    email: []const u8, // may be empty
    rsvp: Rsvp,
    is_organizer: bool,
    is_self: bool, // "you" — shown prominently; CLI source can't detect this
};

pub const Event = struct {
    id: []const u8, // stable identifier (eventIdentifier / ical id)
    calendar_name: []const u8,
    calendar_color: u24, // 0xRRGGBB; theme fallback applied at draw time
    title: []const u8,
    start: i64, // unix seconds, UTC
    end: i64,
    all_day: bool,
    location: []const u8,
    notes: []const u8,
    url: []const u8,
    video_link: []const u8, // derived — see detectVideoLink
    attendees: []Attendee,
    is_recurring: bool,
    /// Your own RSVP. Sources report it event-level (ical `self_status`,
    /// EventKit current-user participant), independent of the attendee list.
    self_rsvp: Rsvp,

    /// True if the event overlaps [from, to).
    pub fn overlaps(self: Event, from: i64, to: i64) bool {
        return self.start < to and self.end > from;
    }
};

/// Video-call providers we recognize, table-driven so adding one is a
/// one-line change (+ a test case, see CONTRIBUTING §5).
const VideoProvider = struct {
    pattern: []const u8,
    display: []const u8,
};

const video_providers = [_]VideoProvider{
    .{ .pattern = "zoom.us/j/", .display = "Zoom" },
    .{ .pattern = "meet.google.com/", .display = "Meet" },
    .{ .pattern = "teams.microsoft.com/l/meetup-join", .display = "Teams" },
    .{ .pattern = "whereby.com/", .display = "Whereby" },
    .{ .pattern = "webex.com/meet", .display = "Webex" },
};

/// First https:// URL of a known video provider found in any of `haystacks`
/// (checked in order — pass url, location, notes). Returns a slice of the
/// haystack it was found in; same lifetime as the input.
pub fn detectVideoLink(haystacks: []const []const u8) ?[]const u8 {
    for (haystacks) |text| {
        var search_from: usize = 0;
        while (std.mem.indexOfPos(u8, text, search_from, "https://")) |start| {
            const link = text[start..urlEnd(text, start)];
            for (video_providers) |provider| {
                if (std.mem.indexOf(u8, link, provider.pattern) != null) return link;
            }
            search_from = start + "https://".len;
        }
    }
    return null;
}

/// Human name of the provider behind a video link ("Zoom"), for
/// notification bodies. Null for links we don't recognize.
pub fn videoProviderName(link: []const u8) ?[]const u8 {
    for (video_providers) |provider| {
        if (std.mem.indexOf(u8, link, provider.pattern) != null) return provider.display;
    }
    return null;
}

/// End index of a URL starting at `start`: stop at whitespace or characters
/// that terminate URLs in prose/HTML.
fn urlEnd(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            ' ', '\t', '\n', '\r', '"', '\'', '<', '>', ')', ']', '}', ',', ';' => break,
            else => {},
        }
    }
    return i;
}

/// Canonical sort: all-day events first, then by start time, then title.
pub fn lessThan(_: void, a: Event, b: Event) bool {
    if (a.all_day != b.all_day) return a.all_day;
    if (a.start != b.start) return a.start < b.start;
    return std.mem.lessThan(u8, a.title, b.title);
}

test "video link detection: provider table" {
    const cases = [_]struct { text: []const u8, want: ?[]const u8 }{
        .{ .text = "https://zoom.us/j/91441122334", .want = "https://zoom.us/j/91441122334" },
        .{ .text = "join at https://meet.google.com/abc-defg-hij today", .want = "https://meet.google.com/abc-defg-hij" },
        .{ .text = "<https://teams.microsoft.com/l/meetup-join/xyz>", .want = "https://teams.microsoft.com/l/meetup-join/xyz" },
        .{ .text = "https://whereby.com/fake-room", .want = "https://whereby.com/fake-room" },
        .{ .text = "https://company.webex.com/meet/fake", .want = "https://company.webex.com/meet/fake" },
        .{ .text = "https://example.com/not-a-meeting", .want = null },
        .{ .text = "zoom.us/j/123 without scheme", .want = null },
        .{ .text = "", .want = null },
    };
    for (cases) |case| {
        const got = detectVideoLink(&.{case.text});
        if (case.want) |want| {
            try std.testing.expectEqualStrings(want, got orelse return error.TestExpectedLink);
        } else {
            try std.testing.expectEqual(@as(?[]const u8, null), got);
        }
    }
}

test "videoProviderName maps links to display names" {
    try std.testing.expectEqualStrings("Zoom", videoProviderName("https://zoom.us/j/123").?);
    try std.testing.expectEqualStrings("Meet", videoProviderName("https://meet.google.com/abc").?);
    try std.testing.expectEqual(@as(?[]const u8, null), videoProviderName("https://example.com"));
}

test "video link detection: searches url, then location, then notes" {
    const got = detectVideoLink(&.{
        "https://example.com/agenda",
        "Conference room 4",
        "dial in: https://zoom.us/j/5551234567 (passcode 42)",
    });
    try std.testing.expectEqualStrings("https://zoom.us/j/5551234567", got.?);

    // A non-video https:// URL earlier in the same field must not shadow a
    // video link later in that field.
    const shadowed = detectVideoLink(&.{"see https://example.com and https://zoom.us/j/1"});
    try std.testing.expectEqualStrings("https://zoom.us/j/1", shadowed.?);
}

test "sort order: all-day first, then start, then title" {
    const mk = struct {
        fn event(title: []const u8, start: i64, all_day: bool) Event {
            return .{
                .id = title,
                .calendar_name = "",
                .calendar_color = 0,
                .title = title,
                .start = start,
                .end = start + 1800,
                .all_day = all_day,
                .location = "",
                .notes = "",
                .url = "",
                .video_link = "",
                .attendees = &.{},
                .is_recurring = false,
                .self_rsvp = .unknown,
            };
        }
    };
    var events = [_]Event{
        mk.event("b-late", 2000, false),
        mk.event("planning week", 0, true),
        mk.event("a-early", 1000, false),
        mk.event("b-early", 1000, false),
    };
    std.mem.sort(Event, &events, {}, lessThan);
    try std.testing.expectEqualStrings("planning week", events[0].title);
    try std.testing.expectEqualStrings("a-early", events[1].title);
    try std.testing.expectEqualStrings("b-early", events[2].title);
    try std.testing.expectEqualStrings("b-late", events[3].title);
}
