//! Portable clock and sleep helpers. Zig 0.16 routes wall-clock, monotonic time
//! and sleeping through `Io`; these go straight to the libc syscalls when libc
//! is linked, because every idle worker and pump poll sleeps at a ~1 ms cadence
//! and a per-call `std.Io.Threaded` construction costs whole cores.

const std = @import("std");
const builtin = @import("builtin");
const threads_mod = @import("threads.zig");
const gc = @import("gc.zig");

fn cNowNs(clk: std.c.clockid_t) ?i128 {
    if (comptime !builtin.link_libc) return null;
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(clk, &ts) != 0) return null;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn cSleepNs(ns: u64) bool {
    if (comptime !builtin.link_libc) return false;
    const ts = std.c.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    _ = std.c.nanosleep(&ts, null);
    return true;
}

pub fn wallMillis() i64 {
    if (cNowNs(.REALTIME)) |ns| return @intCast(@divFloor(ns, std.time.ns_per_ms));
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Clock.real.now(io).toMilliseconds();
}

pub const WallTime = struct { secs: i64, nanos: u32 };

pub fn wallTime() WallTime {
    const ns: i128 = cNowNs(.REALTIME) orelse blk: {
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
    const ns: i128 = cNowNs(.MONOTONIC) orelse blk: {
        var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        break :blk @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    };
    if (ns <= 0) return 0;
    return @intCast(@min(ns, @as(i128, std.math.maxInt(u64))));
}

/// On an abandonable thread the sleep is sliced, so a run-boundary abandon
/// request wakes the task promptly.
pub fn sleepMillis(ms: i64) void {
    if (ms <= 0) return;
    // A sleeping thread makes no progress and holds its live Values in its
    // registered per-thread roots, so it counts as parked for a collection's
    // rendezvous rather than blocking it.
    gc.enterBlockingSafe();
    defer gc.exitBlockingSafe();
    // A non-abandonable thread uses coarse slices, so a leaked sleeper no
    // longer holds the run's final join open.
    const slice_ms: i64 = if (threads_mod.isThreadAbandonable()) 2 else 50;
    if (comptime builtin.link_libc) {
        var remaining = ms;
        while (remaining > 0) {
            if (threads_mod.shouldAbandon()) return;
            const slice = @min(remaining, slice_ms);
            _ = cSleepNs(@as(u64, @intCast(slice)) * std.time.ns_per_ms);
            remaining -= slice;
        }
        return;
    }
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var remaining = ms;
    while (remaining > 0) {
        if (threads_mod.shouldAbandon()) return;
        const slice = @min(remaining, slice_ms);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(slice), .awake) catch {};
        remaining -= slice;
    }
}

/// Cross-thread event gate: an epoch counter with a libc condvar. `waitFrom`
/// parks only while the epoch still equals the `seen` snapshot the caller took
/// before its final emptiness check, which closes the post-then-wait race.
pub const EventGate = struct {
    mutex: std.c.pthread_mutex_t = .{},
    cond: std.c.pthread_cond_t = .{},
    epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn epochNow(self: *EventGate) u64 {
        return self.epoch.load(.acquire);
    }

    pub fn ring(self: *EventGate) void {
        if (comptime !builtin.link_libc) {
            _ = self.epoch.fetchAdd(1, .release);
            return;
        }
        _ = std.c.pthread_mutex_lock(&self.mutex);
        _ = self.epoch.fetchAdd(1, .release);
        _ = std.c.pthread_cond_broadcast(&self.cond);
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    pub fn waitFrom(self: *EventGate, seen: u64, timeout_us: u64) void {
        if (comptime !builtin.link_libc) {
            sleepMicros(@intCast(@min(timeout_us, 1_000)));
            return;
        }
        gc.enterBlockingSafe();
        defer gc.exitBlockingSafe();
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        if (self.epoch.load(.acquire) != seen) return;
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        const add_ns: i128 = @as(i128, ts.nsec) + @as(i128, timeout_us) * 1_000;
        ts.sec += @intCast(@divFloor(add_ns, 1_000_000_000));
        ts.nsec = @intCast(@mod(add_ns, 1_000_000_000));
        _ = std.c.pthread_cond_timedwait(&self.cond, &self.mutex, &ts);
    }
};

/// No abandonment slicing: the callers' own loops re-check between slices.
pub fn sleepMicros(us: i64) void {
    if (us <= 0) return;
    gc.enterBlockingSafe();
    defer gc.exitBlockingSafe();
    if (cSleepNs(@as(u64, @intCast(us)) * 1_000)) return;
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
