//! Concurrency intrinsics: `synchronized`, `kotlin.concurrent.thread`,
//! `Thread.sleep`, `Thread.currentThread`.

const std = @import("std");
const runtime = @import("runtime");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const RuntimeError = runtime.RuntimeError;
const Value = runtime.Value;

/// Spin mutex for the monitor table. Zig 0.16's std has no blocking
/// `Thread.Mutex`, so synchronization is atomic spin and yield.
const SpinMutex = runtime.SpinMutex;

const Monitor = struct {
    /// Owning thread, 0 when free. An uncontended enter is one CAS: no table lock,
    /// no second mutex, which is what a `synchronized` block costs in the common
    /// single-owner case the snapshot system takes on every state write.
    owner: std.atomic.Value(u64) = .init(0),
    /// Re-entry count, written only by the owning thread.
    depth: usize = 0,
};

/// The calling thread's id, resolved once. `getCurrentId` is a libsystem call on
/// macOS, and a monitor enter and exit would otherwise pay it twice.
threadlocal var cached_tid: u64 = 0;

inline fn currentTid() u64 {
    if (cached_tid == 0) {
        const raw: u64 = @intCast(std.Thread.getCurrentId());
        cached_tid = if (raw == 0) 1 else raw;
    }
    return cached_tid;
}

/// Process-wide monitor table keyed by the lock value's object identity;
/// identity-less value-type locks share the sentinel key 0. Never freed.
const Registry = struct {
    var mutex: SpinMutex = .{};
    var map: ?std.AutoHashMap(usize, *Monitor) = null;

    fn allocator() std.mem.Allocator {
        // One monitor per lock OBJECT, and a continuation mints a new one per
        // suspension, so the table grows through the run: a page per entry is both
        // an mmap and 16 KB of address space.
        return std.heap.smp_allocator;
    }
};

/// Last monitor this thread resolved. Monitors are never freed and the registry is
/// never cleared, so the pointer stays valid for the life of the process; a lock taken
/// repeatedly then costs no registry lock and no hash lookup.
threadlocal var cached_key: usize = 0;
threadlocal var cached_monitor: ?*Monitor = null;

fn monitorFor(key: usize) std.mem.Allocator.Error!*Monitor {
    if (cached_monitor) |m| {
        if (cached_key == key) return m;
    }
    const mon = try monitorForSlow(key);
    cached_key = key;
    cached_monitor = mon;
    return mon;
}

fn monitorForSlow(key: usize) std.mem.Allocator.Error!*Monitor {
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
/// owner CAS. False when the wait was abandoned at a run boundary, since the owner
/// may itself have been abandoned while holding the monitor; the caller must then
/// not treat the monitor as held.
pub fn monitorEnter(key: usize) std.mem.Allocator.Error!bool {
    return monitorEnterMon(try monitorFor(key));
}

fn monitorEnterMon(mon: *Monitor) bool {
    const me = currentTid();
    // Only this thread can read its own id here, so the re-entry test needs no lock.
    if (mon.owner.load(.monotonic) == me) {
        mon.depth += 1;
        return true;
    }
    if (mon.owner.cmpxchgWeak(0, me, .acquire, .monotonic) == null) {
        mon.depth = 1;
        return true;
    }
    // Contended. The wait touches only the monitor, never the heap, so the
    // thread counts as parked for a collection throughout: the owner may be
    // collecting inside its critical section, and a waiter that spun or
    // yielded outside the bracket held that collection's rendezvous open
    // until the owner came back, which a stopped owner never does. Leaving
    // the bracket waits out a collection in progress.
    runtime.gc.enterBlockingSafe();
    defer runtime.gc.exitBlockingSafe();
    var rounds: u32 = 0;
    while (true) {
        if (mon.owner.cmpxchgWeak(0, me, .acquire, .monotonic) == null) {
            mon.depth = 1;
            return true;
        }
        // The owner runs an arbitrary interpreted body, so the wait is
        // unbounded: spin briefly, then yield, then park at a millisecond
        // cadence. A pure spin loop saturates every core under contention.
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
    }
}

pub fn monitorTryEnter(key: usize) std.mem.Allocator.Error!bool {
    const mon = try monitorFor(key);
    const me = currentTid();
    if (mon.owner.load(.monotonic) == me) {
        mon.depth += 1;
        return true;
    }
    if (mon.owner.cmpxchgStrong(0, me, .acquire, .monotonic) == null) {
        mon.depth = 1;
        return true;
    }
    return false;
}

/// Release one level of the monitor for `key`. False when the calling thread
/// does not own it, which the JVM reports as IllegalMonitorStateException.
pub fn monitorExit(key: usize) std.mem.Allocator.Error!bool {
    return monitorExitMon(try monitorFor(key));
}

fn monitorExitMon(mon: *Monitor) bool {
    if (mon.owner.load(.monotonic) != currentTid()) return false;
    if (mon.depth > 1) {
        mon.depth -= 1;
        return true;
    }
    mon.depth = 0;
    mon.owner.store(0, .release);
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
    // One resolve for both halves: the body may take other locks and displace the
    // thread's cache entry, which would otherwise make the exit pay a lookup.
    const mon = try monitorFor(key);
    if (!monitorEnterMon(mon)) return .{ .err = .{ .Type = "daemon task abandoned at run boundary" } };
    const result = ctx.host.invokeCallable(&block, &.{}, ctx.out);
    _ = monitorExitMon(mon);
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
    // `thread(start, isDaemon, contextClassLoader, name, priority, block)`: the
    // JVM numbers the thread before a given name replaces "Thread-N".
    const number = runtime.nextThreadNumber();
    const name: []const u8 = if (ctx.args.len > 3 and ctx.args[3] == .String)
        try ctx.allocator.dupe(u8, ctx.args[3].String.asPtrConst().bytes)
    else
        try std.fmt.allocPrint(ctx.allocator, "Thread-{d}", .{number});
    // A leading positional or named `false` means the caller will `.start()` it
    // explicitly; with no deferred-start handle the body spawns anyway and the
    // later `.start()` is a no-op.
    const spawned = try ctx.host.spawnOsThread(&body, name, ctx.out);
    const id: u64 = switch (spawned) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const receiver = try Value.boxRef(ctx.allocator, .{ .Long = @bitCast(id) });
    return .{ .ok = try Value.newBoundMethod(ctx.allocator, .{
        .fqn = "klio.Thread",
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
        // A sleeping thread advances no cooperative virtual clock, so the
        // coroutine layer is told; otherwise a pump waiting for it to settle
        // blocks out the whole sleep.
        runtime.notifyWallBlock();
        sleepMillis(@intCast(millis));
        runtime.notifyWallUnblock();
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
        .fqn = "klio.Thread",
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

test "a thread waiting on a contended monitor counts as parked throughout the wait" {
    const gc = runtime.gc;
    const was_enabled = gc.gc_enabled;
    gc.gc_enabled = true;
    defer gc.gc_enabled = was_enabled;
    const key: usize = 0xBEEF03;
    try testing.expect(try monitorEnter(key));
    const base = gc.parkedCount();

    const Waiter = struct {
        fn run(k: usize, waiting: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) void {
            gc.enterMutator();
            defer gc.exitMutator();
            waiting.store(true, .release);
            if (monitorEnter(k) catch false) _ = monitorExit(k) catch {};
            done.store(true, .release);
        }
    };
    var waiting = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);
    const t = try std.Thread.spawn(.{}, Waiter.run, .{ key, &waiting, &done });
    while (!waiting.load(.acquire)) std.Thread.yield() catch {};
    // Counted once the waiter finds the monitor held, and then without a
    // gap: a waiter spinning or yielding outside the bracket would hold a
    // collection's rendezvous open while the owner collects.
    var spins: usize = 0;
    while (gc.parkedCount() == base) : (spins += 1) {
        try testing.expect(spins < 10_000_000);
        std.atomic.spinLoopHint();
    }
    var i: usize = 0;
    while (i < 200_000) : (i += 1) try testing.expectEqual(base + 1, gc.parkedCount());
    try testing.expect(!done.load(.acquire));
    try testing.expect(try monitorExit(key));
    t.join();
    try testing.expect(done.load(.acquire));
    try testing.expectEqual(base, gc.parkedCount());
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
    try testing.expectEqualStrings("klio.Thread", r.ok.BoundMethod.fqn);
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
