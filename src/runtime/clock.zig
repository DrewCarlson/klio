//! Portable clock and sleep helpers.
//!
//! Zig 0.16 routes wall-clock, monotonic time, and sleeping through the
//! `Io` interface; these helpers instead go straight to the libc syscalls
//! when libc is linked. The original per-call `std.Io.Threaded` ceremony
//! (allocator setup, a syscall-helper thread hop, teardown) profiled as
//! the TOP consumer of a whole commontest run: every idle pool worker,
//! monitor waiter, and pump poll sleeps at a ~1 ms cadence, and paying a
//! runtime construction per tick multiplied into whole cores of overhead
//! (and its allocation churn drove GC collections while idle). The `Io`
//! path remains as the no-libc fallback.

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

/// Wall-clock time in milliseconds since the Unix epoch.
pub fn wallMillis() i64 {
    if (cNowNs(.REALTIME)) |ns| return @intCast(@divFloor(ns, std.time.ns_per_ms));
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Clock.real.now(io).toMilliseconds();
}

/// Wall-clock seconds and the nanosecond remainder since the Unix epoch.
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

/// Monotonic clock reading in nanoseconds (since some unspecified epoch).
/// Only differences between readings are meaningful. Returns 0 on failure.
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

/// Sleep for `ms` milliseconds. A non-positive value returns immediately.
/// On an abandonable thread (a dispatcher pool worker running a daemon
/// task) the sleep is sliced so a run-boundary abandon request wakes the
/// task promptly instead of waiting out the full duration.
pub fn sleepMillis(ms: i64) void {
    if (ms <= 0) return;
    // A sleeping thread makes no progress and holds its live Values in its
    // registered per-thread roots, so it counts as parked for a concurrent
    // collection's stop-the-world rendezvous rather than blocking it.
    gc.enterBlockingSafe();
    defer gc.exitBlockingSafe();
    if (comptime builtin.link_libc) {
        if (!threads_mod.isThreadAbandonable()) {
            _ = cSleepNs(@as(u64, @intCast(ms)) * std.time.ns_per_ms);
            return;
        }
        var remaining = ms;
        while (remaining > 0) {
            if (threads_mod.shouldAbandon()) return;
            const slice = @min(remaining, @as(i64, 2));
            _ = cSleepNs(@as(u64, @intCast(slice)) * std.time.ns_per_ms);
            remaining -= slice;
        }
        return;
    }
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    if (!threads_mod.isThreadAbandonable()) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(ms), .awake) catch {};
        return;
    }
    var remaining = ms;
    while (remaining > 0) {
        if (threads_mod.shouldAbandon()) return;
        const slice = @min(remaining, @as(i64, 2));
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(slice), .awake) catch {};
        remaining -= slice;
    }
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
