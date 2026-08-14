//! Concurrency intrinsics: `synchronized`, `kotlin.concurrent.thread`,
//! `Thread.sleep`, `Thread.currentThread`.

const std = @import("std");
const runtime = @import("runtime");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const RuntimeError = runtime.RuntimeError;
const Value = runtime.Value;

/// Spin mutex for the monitor table and each monitor's state, shared
/// with the rest of the runtime (`runtime.objcell`). Zig 0.16's std has
/// no blocking `Thread.Mutex` (it moved behind the `Io` interface), so
/// synchronization follows the same atomic spin/yield discipline.
const SpinMutex = runtime.SpinMutex;

/// State of one reentrant monitor: which thread (if any) currently
/// owns it and how deep its nesting is.
const MonitorState = struct {
    owner: ?std.Thread.Id,
    depth: usize,
};

/// One reentrant monitor: a spin mutex guarding its ownership state.
/// A waiter that finds the monitor owned by another thread drops the
/// guard and yields, then re-checks — the spin equivalent of a
/// condition-variable wait.
const Monitor = struct {
    mutex: SpinMutex = .{},
    state: MonitorState = .{ .owner = null, .depth = 0 },
};

/// Process-wide monitor table keyed by the lock value's object
/// identity. Value-type locks (no identity) all share a single
/// monitor under the sentinel key `0`. The registry and its monitors
/// live for the whole process and are never freed.
const Registry = struct {
    var mutex: SpinMutex = .{};
    var map: ?std.AutoHashMap(usize, *Monitor) = null;

    /// Allocator backing the process-global registry; never freed.
    fn allocator() std.mem.Allocator {
        return std.heap.page_allocator;
    }
};

/// Fetch (creating on first use) the monitor for `key`.
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

/// Acquire (reentrant) the monitor for `key`: block until the monitor
/// is free or already owned by the calling thread, then take/deepen
/// ownership. The enter ordering is carried by the monitor's own
/// `SpinMutex` acquire.
/// Returns false when the wait was abandoned at a run boundary: the owner
/// may never release (it can itself have been abandoned while holding the
/// monitor), so a boundary drain must not wait it out. The caller must not
/// treat the monitor as held on a false return.
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
            // Held by another thread. The owner is running an arbitrary
            // interpreted `synchronized` body, so the wait is unbounded:
            // spin briefly for short sections, then yield, then park at a
            // millisecond cadence. A pure spin/yield loop here saturated
            // every core whenever many dispatcher workers contended on one
            // hot lock (the SnapshotStateMap concurrent tests drove the
            // whole machine to 100% doing no useful work). The sleep
            // brackets the GC blocking-safe region, so a parked waiter
            // never stalls a collection.
            mon.mutex.unlock();
            if (runtime.shouldAbandon()) return false;
            rounds +|= 1;
            if (rounds <= 512) {
                // A snapshot-write critical section runs a few microseconds
                // of interpreted code; 64 hints (~sub-µs) never bridged one,
                // so every contended handoff fell to the 100µs park — the
                // concurrent snapshot tests spent >90% of their wall in
                // exactly that dead time. ~512 hints spans the common
                // section; the sleep tail still guards long holds from
                // saturating cores.
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

/// Non-blocking monitor acquire for `key`. Returns true when the
/// calling thread now owns the monitor (a fresh take or a reentrant
/// deepen), false when another thread holds it.
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

/// Release one level of the monitor for `key`; clear ownership when
/// fully released so a waiter can acquire. Returns false when the
/// calling thread does not own the monitor (the caller decides whether
/// that is an error — JVM monitors throw IllegalMonitorStateException).
/// The exit ordering is carried by the monitor's `SpinMutex` release.
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

/// `synchronized(lock) { body }` / `synchronized(lock, { body })`.
///
/// A real reentrant monitor keyed by the `lock` argument's object
/// identity: distinct locks run concurrently, the same lock
/// serializes, and the same thread re-entering the same lock does
/// not self-deadlock (Kotlin/JVM monitors are reentrant). The body
/// runs with the monitor held; it is released (even on a thrown
/// exception) before returning. The monitor enter/exit ordering is
/// carried by the monitor's own `SpinMutex` acquire/release.
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

/// Monitor key for a lock-object receiver: its object identity, or the
/// shared sentinel `0` for identity-less values (mirrors
/// `concurrent_synchronized`).
fn receiverLockKey(ctx: *const CallCtx) usize {
    if (ctx.args.len > 0) {
        if (ctx.args[0].lockIdentity()) |k| return k;
    }
    return 0;
}

/// `ReentrantLock.lock()` (and the other bare lock-class acquires the
/// packs bind: `kotlinx.atomicfu.locks`, `io.ktor.utils.io.locks`).
/// Blocks until the receiver's monitor is owned; reentrant.
pub fn concurrent_lock_enter(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (!try monitorEnter(receiverLockKey(ctx))) return .{ .err = .{ .Type = "daemon task abandoned at run boundary" } };
    return .{ .ok = .Unit };
}

/// `ReentrantLock.tryLock()` — non-blocking acquire of the receiver's
/// monitor; reports whether the calling thread now owns it.
pub fn concurrent_lock_try_enter(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const got = try monitorTryEnter(receiverLockKey(ctx));
    return .{ .ok = .{ .Bool = got } };
}

/// `ReentrantLock.unlock()` — release one level of the receiver's
/// monitor. Unlocking a monitor the calling thread does not own is an
/// error (the JVM throws IllegalMonitorStateException here).
pub fn concurrent_lock_exit(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const released = try monitorExit(receiverLockKey(ctx));
    if (!released) {
        return .{ .err = .{ .Type = "unlock() called by a thread that does not hold the lock" } };
    }
    return .{ .ok = .Unit };
}

/// Whether a value is something we can invoke as a thread body.
fn isCallable(v: Value) bool {
    return switch (v) {
        .IrClosure, .Intrinsic, .BoundMethod => true,
        else => false,
    };
}

/// `kotlin.concurrent.thread(start, isDaemon, contextClassLoader,
/// name, priority) { block }`.
///
/// On a single serialized interpreter a started thread's body runs to
/// completion immediately on the calling stack: the body's every
/// action happens-before the call returns, which is exactly the
/// happens-before edge `Thread.start` would give, only stronger
/// (total order). The returned handle is a `Thread` sentinel whose
/// `join()` is a no-op (the body already completed, so its writes are
/// already visible — join-happens-before holds trivially), `isAlive`
/// is `false`, and `name` is a stable string. This is observably
/// correct for every race-free program, which is the only class
/// Kotlin defines behaviour for.
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
    // `thread(start = false) { … }` — leading boolean positional /
    // named arg of `false` means the caller will `.start()` it
    // explicitly. Without a real deferred-start handle we still spawn
    // (the body runs concurrently regardless); a later `.start()` is
    // a no-op. Defaulting to start=true matches the common case.
    // Thread start: happens-before is carried by Thread.spawn inside
    // spawnOsThread plus each shared cell's reader/writer lock.
    const spawned = try ctx.host.spawnOsThread(&body, ctx.out);
    const id: u64 = switch (spawned) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    // The OS thread id is carried as a Kotlin Long via a bit reinterpretation.
    const receiver = try Value.boxRef(ctx.allocator, .{ .Long = @bitCast(id) });
    return .{ .ok = try Value.newBoundMethod(ctx.allocator, .{
        .fqn = "kotlin.concurrent.Thread",
        .func = threadHandleStub,
        .receiver = receiver,
    }) };
}

/// `Thread.sleep(millis: Long)` / `Thread.sleep(millis: Int)`.
///
/// A real OS sleep: the calling thread blocks for the requested
/// duration. Combined with `kotlin.concurrent.thread`'s real thread
/// spawn, N threads each sleeping for D run in ~D wall time, not ~N·D —
/// genuine parallel suspension, not a busy spin.
pub fn concurrent_thread_sleep(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const millis: i64 = if (ctx.args.len > 0) switch (ctx.args[0]) {
        .Long => |v| v,
        .Int => |v| @as(i64, v),
        .Short => |v| @as(i64, v),
        .Byte => |v| @as(i64, v),
        else => return .{ .err = .{ .Type = "Thread.sleep expects a Long or Int millisecond argument" } },
    } else return .{ .err = .{ .Type = "Thread.sleep expects a Long or Int millisecond argument" } };
    if (millis > 0) {
        // A dispatched pool task entering a real wall sleep is not advancing
        // the cooperative virtual clock; tell the coroutine layer so a
        // top-level driver waiting on this task's virtual-clock "settle" does
        // not block out the whole wall sleep.
        runtime.notifyWallBlock();
        sleepMillis(@intCast(millis));
        // A daemon pool task asked to abandon itself at the run boundary
        // wakes from the sliced sleep early and aborts here, before the
        // body can run any further instruction (the block-level abandon
        // check in the evaluator only fires at the next block edge).
        if (runtime.shouldAbandon()) {
            return .{ .err = .{ .Type = "daemon task abandoned at run boundary" } };
        }
    }
    return .{ .ok = .Unit };
}

/// Block the calling thread for `millis` milliseconds.
fn sleepMillis(millis: u64) void {
    runtime.clockSleepMillis(@intCast(@min(millis, @as(u64, std.math.maxInt(i64)))));
}

/// `Thread.currentThread()` — a `Thread` sentinel for the calling OS
/// thread. Its `.name` is a stable per-thread string derived from the
/// OS thread id, so two calls on the same thread report the same name
/// and distinct threads report distinct names; `.isAlive` is `true`
/// (the calling thread is, by definition, running).
pub fn concurrent_thread_current(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const id: u64 = std.Thread.getCurrentId();
    // The thread id is carried as a Kotlin Long via a bit reinterpretation.
    const receiver = try Value.boxRef(ctx.allocator, .{ .Long = @bitCast(id) });
    return .{ .ok = try Value.newBoundMethod(ctx.allocator, .{
        .fqn = "kotlin.concurrent.Thread",
        .func = threadHandleStub,
        .receiver = receiver,
    }) };
}

/// Placeholder dispatch for a bare `Thread` sentinel value. Member
/// access (`join`, `name`, `isAlive`) is intercepted by the
/// interpreter before this is ever called; invoking the handle itself
/// is not a valid Kotlin operation.
fn threadHandleStub(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .err = .{ .Type = "Thread handle is not callable; use .join() / .name / .isAlive" } };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

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
    // Fully released: exit without ownership reports failure.
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
            // Unsynchronized read-modify-write; only the monitor makes
            // it exact across the workers.
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
    // Released by the holder: this thread can now take and release it.
    try testing.expect(try monitorTryEnter(key));
    try testing.expect(try monitorExit(key));
}

test "lock bindings acquire and release through the receiver identity" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    // Identity-less receiver falls back to the shared sentinel key; the
    // enter/exit pairing must still balance.
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
    // Over-unlock is the JVM's IllegalMonitorStateException shape.
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
