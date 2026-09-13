//! Concurrency intrinsics: `synchronized`, `kotlin.concurrent.thread`,
//! `Thread.sleep`, `Thread.currentThread`.

const std = @import("std");
const runtime = @import("runtime");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const RuntimeError = runtime.RuntimeError;
const Value = runtime.Value;

/// Spin mutex for the monitor table and each monitor's state. Zig 0.16's std has
/// no blocking `Thread.Mutex`, so synchronization is atomic spin and yield.
const SpinMutex = runtime.SpinMutex;

const MonitorState = struct {
    owner: ?std.Thread.Id,
    depth: usize,
};

const Monitor = struct {
    mutex: SpinMutex = .{},
    state: MonitorState = .{ .owner = null, .depth = 0 },
};

/// Process-wide monitor table keyed by the lock value's object identity;
/// identity-less value-type locks share the sentinel key 0. Never freed.
const Registry = struct {
    var mutex: SpinMutex = .{};
    var map: ?std.AutoHashMap(usize, *Monitor) = null;

    fn allocator() std.mem.Allocator {
        return std.heap.page_allocator;
    }
};

fn monitorFor(key: usize) std.mem.Allocator.Error!*Monitor {
    Registry.mutex.lock();
    defer Registry.mutex.unlock();
    if (Registry.map == null) {
        Registry.map = std.AutoHashMap(usize, *Monitor).init(Registry.allocator());
    }
    const gop = try Registry.map.?.getOrPut(key);
    if (!gop.found_existing) {
        const mon = try Registry.allocator().create(Monitor);
        mon.* = .{};
        gop.value_ptr.* = mon;
    }
    return gop.value_ptr.*;
}

/// Reentrant acquire of the monitor for `key`; the enter ordering rides on the
/// monitor's own `SpinMutex`. False when the wait was abandoned at a run
/// boundary, since the owner may itself have been abandoned while holding the
/// monitor; the caller must then not treat the monitor as held.
pub fn monitorEnter(key: usize) std.mem.Allocator.Error!bool {
    const mon = try monitorFor(key);
    const me = std.Thread.getCurrentId();
    var rounds: u32 = 0;
    while (true) {
        mon.mutex.lock();
        if (mon.state.owner) |o| {
            if (o == me) {
                mon.state.depth += 1;
                mon.mutex.unlock();
                return true;
            }
            // The owner runs an arbitrary interpreted body, so the wait is
            // unbounded: spin briefly, then yield, then park at a millisecond
            // cadence. A pure spin loop saturates every core under contention,
            // and the sleep brackets the GC blocking-safe region.
            mon.mutex.unlock();
            if (runtime.shouldAbandon()) return false;
            rounds +|= 1;
            if (rounds <= 512) {
                // A snapshot-write critical section runs a few microseconds of
                // interpreted code, which 64 hints never bridges, so ~512 spans
                // the common section before the park.
                std.atomic.spinLoopHint();
            } else if (rounds <= 4096) {
                std.Thread.yield() catch {};
            } else if (rounds <= 8192) {
                runtime.clockSleepMicros(100);
            } else {
                runtime.clockSleepMillis(1);
            }
        } else {
            mon.state.owner = me;
            mon.state.depth = 1;
            mon.mutex.unlock();
            return true;
        }
    }
}

pub fn monitorTryEnter(key: usize) std.mem.Allocator.Error!bool {
    const mon = try monitorFor(key);
    const me = std.Thread.getCurrentId();
    mon.mutex.lock();
    defer mon.mutex.unlock();
    if (mon.state.owner) |o| {
        if (o == me) {
            mon.state.depth += 1;
            return true;
        }
        return false;
    }
    mon.state.owner = me;
    mon.state.depth = 1;
    return true;
}

/// Release one level of the monitor for `key`. False when the calling thread
/// does not own it, which the JVM reports as IllegalMonitorStateException.
pub fn monitorExit(key: usize) std.mem.Allocator.Error!bool {
    const mon = try monitorFor(key);
    const me = std.Thread.getCurrentId();
    mon.mutex.lock();
    defer mon.mutex.unlock();
    const owner = mon.state.owner orelse return false;
    if (owner != me) return false;
    mon.state.depth -= 1;
    if (mon.state.depth == 0) {
        mon.state.owner = null;
    }
    return true;
}

/// A reentrant monitor keyed by the `lock` argument's object identity, so
/// distinct locks run concurrently and a thread re-entering its own does not
/// self-deadlock. The body runs with the monitor held, released even on a throw.
pub fn concurrent_synchronized(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const lock: Value = if (ctx.args.len > 0) ctx.args[0] else .Unit;
    const block: Value = if (ctx.args.len > 0)
        ctx.args[ctx.args.len - 1]
    else
        return .{ .err = .{ .Arity = "synchronized expects (lock, block)" } };
    const key = lock.lockIdentity() orelse 0;
    if (!try monitorEnter(key)) return .{ .err = .{ .Type = "daemon task abandoned at run boundary" } };
    const result = ctx.host.invokeCallable(&block, &.{}, ctx.out);
    _ = try monitorExit(key);
    return result;
}

pub fn concurrent_monitor_enter(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const key = if (ctx.args.len > 0) (ctx.args[0].lockIdentity() orelse 0) else 0;
    if (!try monitorEnter(key)) return .{ .err = .{ .Type = "daemon task abandoned at run boundary" } };
    return .{ .ok = .Unit };
}

pub fn concurrent_monitor_exit(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const key = if (ctx.args.len > 0) (ctx.args[0].lockIdentity() orelse 0) else 0;
    _ = try monitorExit(key);
    return .{ .ok = .Unit };
}

fn receiverLockKey(ctx: *const CallCtx) usize {
    if (ctx.args.len > 0) {
        if (ctx.args[0].lockIdentity()) |k| return k;
    }
    return 0;
}

pub fn concurrent_lock_enter(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (!try monitorEnter(receiverLockKey(ctx))) return .{ .err = .{ .Type = "daemon task abandoned at run boundary" } };
    return .{ .ok = .Unit };
}

pub fn concurrent_lock_try_enter(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const got = try monitorTryEnter(receiverLockKey(ctx));
    return .{ .ok = .{ .Bool = got } };
}

/// Unlocking a monitor the calling thread does not own is the JVM's
/// IllegalMonitorStateException.
pub fn concurrent_lock_exit(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const released = try monitorExit(receiverLockKey(ctx));
    if (!released) {
        return .{ .err = .{ .Type = "unlock() called by a thread that does not hold the lock" } };
    }
    return .{ .ok = .Unit };
}

fn isCallable(v: Value) bool {
    return switch (v) {
        .IrClosure, .Intrinsic, .BoundMethod => true,
        else => false,
    };
}

/// `kotlin.concurrent.thread(...) { block }`. A started body runs to completion
/// immediately on the calling stack, so every action in it happens-before the
/// call returns: the edge `Thread.start` gives, under a stronger total order.
/// The returned `Thread` sentinel has a no-op `join()`, `isAlive` false and a
/// stable `name`.
pub fn concurrent_thread(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    var block: ?Value = null;
    var i: usize = ctx.args.len;
    while (i > 0) {
        i -= 1;
        if (isCallable(ctx.args[i])) {
            block = ctx.args[i];
            break;
        }
    }
    const body = block orelse return .{ .err = .{ .Arity = "thread expects a block" } };
    // A leading positional or named `false` means the caller will `.start()` it
    // explicitly; with no deferred-start handle the body spawns anyway and the
    // later `.start()` is a no-op.
    const spawned = try ctx.host.spawnOsThread(&body, ctx.out);
    const id: u64 = switch (spawned) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const receiver = try Value.boxRef(ctx.allocator, .{ .Long = @bitCast(id) });
    return .{ .ok = try Value.newBoundMethod(ctx.allocator, .{
        .fqn = "kotlin.concurrent.Thread",
        .func = threadHandleStub,
        .receiver = receiver,
    }) };
}

/// A real OS sleep, so with `kotlin.concurrent.thread`'s real spawn, N threads
/// each sleeping for D take about D of wall time.
pub fn concurrent_thread_sleep(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const millis: i64 = if (ctx.args.len > 0) switch (ctx.args[0]) {
        .Long => |v| v,
        .Int => |v| @as(i64, v),
        .Short => |v| @as(i64, v),
        .Byte => |v| @as(i64, v),
        else => return .{ .err = .{ .Type = "Thread.sleep expects a Long or Int millisecond argument" } },
    } else return .{ .err = .{ .Type = "Thread.sleep expects a Long or Int millisecond argument" } };
    if (millis > 0) {
        // A dispatched pool task in a real wall sleep advances no cooperative
        // virtual clock, so the coroutine layer is told; otherwise a driver
        // waiting for it to settle blocks out the whole sleep.
        runtime.notifyWallBlock();
        sleepMillis(@intCast(millis));
        // A daemon pool task asked to abandon itself aborts here, the evaluator's
        // abandon check firing only at the next block edge.
        if (runtime.shouldAbandon()) {
            return .{ .err = .{ .Type = "daemon task abandoned at run boundary" } };
        }
    }
    return .{ .ok = .Unit };
}

fn sleepMillis(millis: u64) void {
    runtime.clockSleepMillis(@intCast(@min(millis, @as(u64, std.math.maxInt(i64)))));
}

/// A `Thread` sentinel for the calling OS thread, whose `.name` is a stable
/// per-thread string derived from the OS thread id.
pub fn concurrent_thread_current(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const id: u64 = std.Thread.getCurrentId();
    const receiver = try Value.boxRef(ctx.allocator, .{ .Long = @bitCast(id) });
    return .{ .ok = try Value.newBoundMethod(ctx.allocator, .{
        .fqn = "kotlin.concurrent.Thread",
        .func = threadHandleStub,
        .receiver = receiver,
    }) };
}

fn threadHandleStub(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
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

test "synchronized with no args is an arity error" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = makeCtx(h.host(), cap.output(), &.{});
    const r = try concurrent_synchronized(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Arity);
}

test "distinct value locks map to the sentinel monitor" {
    const m0 = try monitorFor(0);
    const m0_again = try monitorFor(0);
    try testing.expectEqual(m0, m0_again);
    const m1 = try monitorFor(1);
    try testing.expect(m0 != m1);
}

test "monitor enter is reentrant and exit releases by depth" {
    const key: usize = 0xC0FFEE;
    try testing.expect(try monitorEnter(key));
    try testing.expect(try monitorEnter(key)); // reentrant deepen, no self-deadlock
    try testing.expect(try monitorTryEnter(key)); // reentrant try also succeeds
    try testing.expect(try monitorExit(key));
    try testing.expect(try monitorExit(key));
    try testing.expect(try monitorExit(key));
    try testing.expect(!(try monitorExit(key)));
}

const MonitorWorker = struct {
    key: usize,
    counter: *i64,
    iters: usize,

    fn run(self: MonitorWorker) void {
        var i: usize = 0;
        while (i < self.iters) : (i += 1) {
            if (!(monitorEnter(self.key) catch unreachable)) return;
            self.counter.* += 1;
            _ = monitorExit(self.key) catch unreachable;
        }
    }
};

test "monitor excludes across real threads" {
    const key: usize = 0xBEEF01;
    const THREADS: usize = 8;
    const ITERS: usize = 2000;
    var counter: i64 = 0;
    var threads: [THREADS]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, MonitorWorker.run, .{
            MonitorWorker{ .key = key, .counter = &counter, .iters = ITERS },
        });
    }
    for (threads) |t| t.join();
    try testing.expectEqual(@as(i64, THREADS * ITERS), counter);
}

const TryEnterHolder = struct {
    key: usize,
    held: *std.atomic.Value(bool),
    release: *std.atomic.Value(bool),

    fn run(self: TryEnterHolder) void {
        if (!(monitorEnter(self.key) catch unreachable)) return;
        self.held.store(true, .release);
        while (!self.release.load(.acquire)) {
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
        _ = monitorExit(self.key) catch unreachable;
    }
};

test "tryEnter fails while another thread holds the monitor" {
    const key: usize = 0xBEEF02;
    var held = std.atomic.Value(bool).init(false);
    var release = std.atomic.Value(bool).init(false);
    const holder = try std.Thread.spawn(.{}, TryEnterHolder.run, .{
        TryEnterHolder{ .key = key, .held = &held, .release = &release },
    });
    while (!held.load(.acquire)) {
        std.atomic.spinLoopHint();
        std.Thread.yield() catch {};
    }
    try testing.expect(!(try monitorTryEnter(key)));
    release.store(true, .release);
    holder.join();
    try testing.expect(try monitorTryEnter(key));
    try testing.expect(try monitorExit(key));
}

test "lock bindings acquire and release through the receiver identity" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var args = [_]Value{.{ .Int = 1 }};
    var ctx = makeCtx(h.host(), cap.output(), &args);
    const l = try concurrent_lock_enter(&ctx);
    try testing.expect(l == .ok and l.ok == .Unit);
    const t = try concurrent_lock_try_enter(&ctx);
    try testing.expect(t == .ok and t.ok.Bool == true);
    const rel_a = try concurrent_lock_exit(&ctx);
    try testing.expect(rel_a == .ok);
    const rel_b = try concurrent_lock_exit(&ctx);
    try testing.expect(rel_b == .ok);
    const rel_c = try concurrent_lock_exit(&ctx);
    try testing.expect(rel_c == .err and rel_c.err == .Type);
}

test "Thread.sleep accepts integer types and returns Unit" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    inline for (.{
        Value{ .Long = 0 },
        Value{ .Int = 0 },
        Value{ .Short = 0 },
        Value{ .Byte = 0 },
    }) |arg| {
        var ctx = makeCtx(h.host(), cap.output(), &.{arg});
        const r = try concurrent_thread_sleep(&ctx);
        try testing.expect(r == .ok);
        try testing.expect(r.ok == .Unit);
    }
}

test "Thread.sleep rejects non-numeric arguments" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const arg = Value{ .Bool = true };
    var ctx = makeCtx(h.host(), cap.output(), &.{arg});
    const r = try concurrent_thread_sleep(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
}

test "thread without a callable block is an arity error" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const arg = Value{ .Bool = false };
    var ctx = makeCtx(h.host(), cap.output(), &.{arg});
    const r = try concurrent_thread(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Arity);
}

test "currentThread yields a Thread BoundMethod handle" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = makeCtx(h.host(), cap.output(), &.{});
    const r = try concurrent_thread_current(&ctx);
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .BoundMethod);
    try testing.expectEqualStrings("kotlin.concurrent.Thread", r.ok.BoundMethod.fqn);
    runtime.boundMethodRefOf(r.ok.BoundMethod).deinit();
}

test "thread handle is not callable" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = makeCtx(h.host(), cap.output(), &.{});
    const r = try threadHandleStub(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
}
