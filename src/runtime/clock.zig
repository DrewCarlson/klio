//! Portable clock and sleep helpers. Zig 0.16 routes wall-clock, monotonic time
//! and sleeping through `Io`; these go straight to the host (`platform`)
//! because every idle worker and pump poll sleeps at a ~1 ms cadence and a
//! per-call `std.Io.Threaded` construction costs whole cores.

const std = @import("std");
const builtin = @import("builtin");
const threads_mod = @import("threads.zig");
const gc = @import("gc.zig");
const platform = @import("platform.zig");

pub fn wallMillis() i64 {
    if (platform.realtimeNs()) |ns| return @intCast(@divFloor(ns, std.time.ns_per_ms));
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Clock.real.now(io).toMilliseconds();
}

pub const WallTime = struct { secs: i64, nanos: u32 };

pub fn wallTime() WallTime {
    const ns: i128 = platform.realtimeNs() orelse blk: {
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        break :blk @intCast(std.Io.Clock.real.now(io).nanoseconds);
    };
    const secs = @divFloor(ns, std.time.ns_per_s);
    const nanos: u32 = @intCast(@mod(ns, std.time.ns_per_s));
    return .{ .secs = @intCast(secs), .nanos = nanos };
}

/// Only differences are meaningful. 0 on failure.
pub fn monotonicNanos() u64 {
    if (platform.monotonicNs()) |ns| return ns;
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const ns: i128 = @intCast(std.Io.Clock.awake.now(threaded.io()).nanoseconds);
    if (ns <= 0) return 0;
    return @intCast(@min(ns, @as(i128, std.math.maxInt(u64))));
}

/// Sleeps on the thread's own gate, which an abandonment request rings: an
/// abandonable thread, or any thread at the run boundary, wakes at once.
pub fn sleepMillis(ms: i64) void {
    if (ms <= 0) return;
    // A sleeping thread makes no progress and holds its live Values in its
    // registered per-thread roots, so it counts as parked for a collection's
    // rendezvous rather than blocking it.
    gc.enterBlockingSafe();
    defer gc.exitBlockingSafe();
    if (comptime !platform.has_os_sync) {
        // No condition variables: slices, so abandonment is still seen.
        var remaining = ms;
        while (remaining > 0) {
            if (threads_mod.shouldAbandon()) return;
            const slice = @min(remaining, 2);
            if (!platform.sleepNs(@as(u64, @intCast(slice)) * std.time.ns_per_ms)) {
                var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
                defer threaded.deinit();
                std.Io.sleep(threaded.io(), std.Io.Duration.fromMilliseconds(slice), .awake) catch {};
            }
            remaining -= slice;
        }
        return;
    }
    const deadline = monotonicNanos() +| @as(u64, @intCast(ms)) *| std.time.ns_per_ms;
    while (true) {
        const now = monotonicNanos();
        if (now >= deadline) return;
        const seen = sleep_gate.epochNow();
        if (!sleep_gate.parkFrom(seen, (deadline - now) / std.time.ns_per_us)) return;
    }
}

/// The gate a thread's sleeps park on; nothing but an abandonment request
/// rings it.
threadlocal var sleep_gate: EventGate = .{};

/// Cross-thread event gate: an epoch counter with an OS condition variable.
/// `waitFrom` parks only while the epoch still equals the `seen` snapshot the
/// caller took before its final emptiness check, which closes the
/// post-then-wait race.
pub const EventGate = struct {
    mutex: platform.Mutex = .{},
    cond: platform.Cond = .{},
    epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    // Threads parked on the gate, and its place among the parked gates an
    // abandonment request rings (under `parked_gates.mutex`).
    parked: u32 = 0,
    parked_prev: ?*EventGate = null,
    parked_next: ?*EventGate = null,

    /// A `waitFrom` timeout that never ends: the gate waits for a ring.
    pub const forever: u64 = std.math.maxInt(u64);

    pub fn epochNow(self: *EventGate) u64 {
        return self.epoch.load(.acquire);
    }

    pub fn ring(self: *EventGate) void {
        if (comptime !platform.has_os_sync) {
            _ = self.epoch.fetchAdd(1, .release);
            return;
        }
        self.mutex.lock();
        _ = self.epoch.fetchAdd(1, .release);
        self.cond.broadcast();
        self.mutex.unlock();
    }

    /// Parks until the gate rings or `timeout_us` (`forever` for no limit)
    /// passes; an abandonment request that concerns this thread wakes it.
    pub fn waitFrom(self: *EventGate, seen: u64, timeout_us: u64) void {
        if (comptime !platform.has_os_sync) {
            sleepMicros(@intCast(@min(timeout_us, 1_000)));
            return;
        }
        gc.enterBlockingSafe();
        defer gc.exitBlockingSafe();
        _ = self.parkFrom(seen, timeout_us);
    }

    /// `waitFrom` for a thread already GC-safe; false when abandonment,
    /// not the gate or the time, ended the wait.
    fn parkFrom(self: *EventGate, seen: u64, timeout_us: u64) bool {
        parked_gates.join(self);
        defer parked_gates.leave(self);
        // Read after joining: a request made before is seen here, one made
        // after rings this gate.
        if (threads_mod.shouldAbandon()) return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.epoch.load(.acquire) != seen) return true;
        if (timeout_us == forever) {
            self.cond.wait(&self.mutex);
        } else {
            self.cond.timedWait(&self.mutex, timeout_us *| std.time.ns_per_us);
        }
        return !threads_mod.shouldAbandon();
    }
};

/// The gates threads are parked on. An abandonment request rings every one,
/// so a parked thread sees it without waking to look.
const ParkedGates = struct {
    mutex: platform.Mutex = .{},
    head: ?*EventGate = null,

    fn join(self: *ParkedGates, g: *EventGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        g.parked += 1;
        if (g.parked > 1) return;
        g.parked_prev = null;
        g.parked_next = self.head;
        if (self.head) |h| h.parked_prev = g;
        self.head = g;
    }

    fn leave(self: *ParkedGates, g: *EventGate) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        g.parked -= 1;
        if (g.parked > 0) return;
        if (g.parked_prev) |p| p.parked_next = g.parked_next else self.head = g.parked_next;
        if (g.parked_next) |n| n.parked_prev = g.parked_prev;
        g.parked_prev = null;
        g.parked_next = null;
    }
};

var parked_gates: ParkedGates = .{};

/// Rings every gate a thread is parked on (an abandonment request).
pub fn ringParkedGates() void {
    if (comptime !platform.has_os_sync) return;
    parked_gates.mutex.lock();
    defer parked_gates.mutex.unlock();
    var it = parked_gates.head;
    while (it) |g| : (it = g.parked_next) g.ring();
}

/// No abandonment slicing: the callers' own loops re-check between slices.
pub fn sleepMicros(us: i64) void {
    if (us <= 0) return;
    gc.enterBlockingSafe();
    defer gc.exitBlockingSafe();
    if (platform.sleepNs(@as(u64, @intCast(us)) * 1_000)) return;
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    std.Io.sleep(io, std.Io.Duration.fromMicroseconds(@intCast(us)), .awake) catch {};
}

const testing = std.testing;

test "wallMillis is positive" {
    try testing.expect(wallMillis() > 0);
}

test "monotonicNanos is non-decreasing" {
    const a = monotonicNanos();
    const b = monotonicNanos();
    try testing.expect(b >= a);
}
