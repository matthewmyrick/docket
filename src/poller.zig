//! The poller thread: fetch → build snapshot → swap under the mutex →
//! notify-scan → sleep (ARCHITECTURE.md §4, §8). This is the only place snapshots are
//! created or destroyed while the app runs. The program's complete
//! concurrency design: this one mutex plus one wake event.
//!
//! Snapshot ownership: the UI thread holds `mutex` for the duration of a
//! draw (draws are sub-millisecond), so after `swap` returns, no reader can
//! still hold the retired pointer and it is freed immediately.

const std = @import("std");
const snapshot_mod = @import("snapshot.zig");
const source_mod = @import("calendar/source.zig");
const time_mod = @import("calendar/time.zig");
const notifier_mod = @import("notify/notifier.zig");

const Snapshot = snapshot_mod.Snapshot;

/// Consecutive failures before the UI escalates from a status-bar warning
/// to a prominent banner (ARCHITECTURE.md §8).
pub const failure_banner_threshold: u32 = 5;

/// Default fetch window relative to now (ARCHITECTURE.md §5): covers the month grid
/// plus the notification horizon.
const default_back_days: i64 = 8;
const default_forward_days: i64 = 62;

pub const Poller = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    source: *source_mod.CalendarSource,
    notifier: *notifier_mod.Notifier,
    zone: time_mod.Zone,
    poll_interval_seconds: u32,
    filter: snapshot_mod.Filter,

    /// THE mutex: guards `snapshot`, `consecutive_failures`, and
    /// `requested_*` below. Nothing else in the program is shared-mutable.
    mutex: std.Io.Mutex = .init,
    snapshot: ?*Snapshot = null,
    consecutive_failures: u32 = 0,
    /// UI-requested fetch window (navigation outside the loaded range).
    requested_from: ?i64 = null,
    requested_to: ?i64 = null,

    /// Set to wake the poller early (manual refresh, window request, stop).
    wake_event: std.Io.Event = .unset,
    stop_requested: bool = false, // written once by the UI thread before final wake

    /// Called (from the poller thread) after every completed cycle so the
    /// UI can repaint. Null in daemon mode.
    on_cycle: ?*const fn (context: *anyopaque) void = null,
    on_cycle_context: *anyopaque = undefined,

    /// Thread body. Runs until `stop` is called; frees the last snapshot on
    /// the way out.
    pub fn run(self: *Poller) void {
        while (true) {
            self.cycle();
            // .real clock: after a laptop sleep the deadline has passed, so
            // the poller fires immediately on wake and catches up.
            self.wake_event.waitTimeout(self.io, .{ .duration = .{
                .raw = .fromSeconds(self.poll_interval_seconds),
                .clock = .real,
            } }) catch {}; // Timeout is the normal poll tick
            self.wake_event.reset();
            if (@atomicLoad(bool, &self.stop_requested, .acquire)) break;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.snapshot) |snapshot| snapshot.deinit();
        self.snapshot = null;
    }

    /// One poll: fetch, swap, notify. Failures keep the previous snapshot
    /// and bump the failure counter (ARCHITECTURE.md §8 failure policy).
    fn cycle(self: *Poller) void {
        const now = nowUnix(self.io);

        self.mutex.lockUncancelable(self.io);
        const from = self.requested_from orelse defaultFrom(now, self.zone);
        const to = self.requested_to orelse defaultTo(now, self.zone);
        self.mutex.unlock(self.io);

        const fresh = Snapshot.build(self.gpa, self.source, from, to, now, self.filter) catch |err| {
            self.mutex.lockUncancelable(self.io);
            self.consecutive_failures += 1;
            const failures = self.consecutive_failures;
            self.mutex.unlock(self.io);
            std.log.debug("poll failed ({t}), {d} consecutive; keeping cached snapshot", .{ err, failures });
            self.notifyUi();
            return;
        };

        self.mutex.lockUncancelable(self.io);
        const retired = self.snapshot;
        self.snapshot = fresh;
        self.consecutive_failures = 0;
        self.mutex.unlock(self.io);
        // Safe outside the lock: readers hold the mutex while using the
        // pointer, so nobody can still reference `retired` here.
        if (retired) |old| old.deinit();

        std.log.debug("poll ok: {d} events in window", .{fresh.events.len});
        self.notifyUi();
        self.notifier.scan(fresh.events, now, self.zone);
    }

    fn notifyUi(self: *Poller) void {
        if (self.on_cycle) |callback| callback(self.on_cycle_context);
    }

    /// Manual refresh (the `r` key): wake the poller; never fetch on the UI
    /// thread.
    pub fn wake(self: *Poller) void {
        self.wake_event.set(self.io);
    }

    /// Ask the next fetches to cover [from, to] (UI navigated outside the
    /// window), and refresh now.
    pub fn requestWindow(self: *Poller, from: i64, to: i64) void {
        self.mutex.lockUncancelable(self.io);
        self.requested_from = from;
        self.requested_to = to;
        self.mutex.unlock(self.io);
        self.wake();
    }

    /// Begin shutdown; pair with awaiting the thread future, then nothing
    /// else may touch the poller.
    pub fn stop(self: *Poller) void {
        @atomicStore(bool, &self.stop_requested, true, .release);
        self.wake();
    }

    fn defaultFrom(now: i64, zone: time_mod.Zone) i64 {
        const today = time_mod.localDate(now, zone);
        return time_mod.dayBounds(time_mod.addDays(today, -default_back_days), zone).start;
    }

    fn defaultTo(now: i64, zone: time_mod.Zone) i64 {
        const today = time_mod.localDate(now, zone);
        return time_mod.dayBounds(time_mod.addDays(today, default_forward_days), zone).end;
    }
};

pub fn nowUnix(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}
