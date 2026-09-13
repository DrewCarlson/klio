//! Time intrinsics: wall-clock millis and monotonic nanos.

const std = @import("std");
const runtime = @import("runtime");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const RuntimeError = runtime.RuntimeError;
const Value = runtime.Value;

/// Wall-clock milliseconds since the Unix epoch, backing the `Clock.System` and
/// `Instant` actuals.
pub fn time_system_millis(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .ok = .{ .Long = runtime.clockWallMillis() } };
}

/// Process-global monotonic origin in nanoseconds, fixed on first read: only
/// differences between readings are meaningful. The sentinel 0 means unset, and
/// a single compare-exchange installs the first reading.
const MonotonicOrigin = struct {
    var origin_nanos: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

    fn readNanos() u64 {
        return runtime.clockMonotonicNanos();
    }

    fn elapsed() u64 {
        const now = readNanos();
        const stamp = if (now == 0) 1 else now;
        const prior = origin_nanos.cmpxchgStrong(0, stamp, .acq_rel, .acquire) orelse stamp;
        return now -% prior;
    }
};

/// A monotonically non-decreasing nanosecond reading, backing
/// `TimeSource.Monotonic`. Only differences between readings are meaningful.
pub fn time_monotonic_nanos(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    const nanos = MonotonicOrigin.elapsed();
    const out: i64 = if (nanos <= std.math.maxInt(i64)) @intCast(nanos) else std.math.maxInt(i64);
    return .{ .ok = .{ .Long = out } };
}

/// Placeholder dispatch for a bare `Thread` sentinel. The interpreter intercepts
/// `join`, `name` and `isAlive`, and invoking the handle is not valid Kotlin.
pub fn thread_handle_stub(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .err = .{ .Type = "Thread handle is not callable; use .join() / .name / .isAlive" } };
}

const testing = std.testing;

fn makeCtx(host: runtime.IntrinsicHost, out: runtime.Output, args: []const Value) CallCtx {
    return .{
        .args = args,
        .out = out,
        .host = host,
        .allocator = testing.allocator,
    };
}

test "system millis is a positive Long" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = makeCtx(h.host(), cap.output(), &.{});
    const r = try time_system_millis(&ctx);
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .Long);
    try testing.expect(r.ok.Long > 0);
}

test "monotonic nanos is non-decreasing" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = makeCtx(h.host(), cap.output(), &.{});

    const first = try time_monotonic_nanos(&ctx);
    try testing.expect(first == .ok);
    try testing.expect(first.ok == .Long);
    try testing.expect(first.ok.Long >= 0);

    const second = try time_monotonic_nanos(&ctx);
    try testing.expect(second == .ok);
    try testing.expect(second.ok.Long >= first.ok.Long);
}

test "thread handle is not callable" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = makeCtx(h.host(), cap.output(), &.{});
    const r = try thread_handle_stub(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
    try testing.expectEqualStrings(
        "Thread handle is not callable; use .join() / .name / .isAlive",
        r.err.Type,
    );
}
