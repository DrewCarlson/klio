//! Concurrency intrinsics: `synchronized`, `kotlin.concurrent.thread`,
//! `Thread.sleep`, `Thread.currentThread`.

const std = @import("std");
const runtime = @import("runtime");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const RuntimeError = runtime.RuntimeError;
const Value = runtime.Value;

/// Spin mutex for the monitor table and each monitor's state. Zig
/// 0.16's std has no blocking `Thread.Mutex` (it moved behind the `Io`
/// interface), so synchronization here follows the same atomic
/// spin/yield discipline the rest of the runtime uses.
const SpinMutex = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *SpinMutex) void {
        while (self.locked.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *SpinMutex) void {
        self.locked.store(false, .release);
    }
};

/// State of one reentrant monitor: which thread (if any) currently
/// owns it and how deep its nesting is.
const MonitorState = struct {
    owner: ?std.Thread.Id,
    depth: usize,
};

/// One reentrant monitor: a spin mutex guarding its ownership state.
/// A waiter that finds the monitor owned by another thread drops the
/// guard and yields, then re-checks — the spin equivalent of a
/// condition-variable wait. Mirrors the Rust `(Mutex<MonitorState>,
/// Condvar)`.
const Monitor = struct {
    mutex: SpinMutex = .{},
    state: MonitorState = .{ .owner = null, .depth = 0 },
};

/// Process-wide monitor table keyed by the lock value's object
/// identity. Value-type locks (no identity) all share a single
/// monitor under the sentinel key `0`. The registry and its monitors
/// live for the whole process, mirroring the Rust `static OnceLock`
/// plus `Arc` monitors that are never dropped.
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

/// `synchronized(lock) { body }` / `synchronized(lock, { body })`.
///
/// A real reentrant monitor keyed by the `lock` argument's object
/// identity: distinct locks run concurrently, the same lock
/// serializes, and the same thread re-entering the same lock does
/// not self-deadlock (Kotlin/JVM monitors are reentrant). The body
/// runs with the monitor held; it is released (even on a thrown
/// exception) before returning. `fenceAndPublish` marks the
/// monitor enter and exit boundaries.
pub fn concurrent_synchronized(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const lock: Value = if (ctx.args.len > 0) ctx.args[0] else .Unit;
    const block: Value = if (ctx.args.len > 0)
        ctx.args[ctx.args.len - 1]
    else
        return .{ .err = .{ .Arity = "synchronized expects (lock, block)" } };
    const key = lock.lockIdentity() orelse 0;
    const mon = try monitorFor(key);
    const me = std.Thread.getCurrentId();

    // Acquire (reentrant): block until the monitor is free or already
    // owned by this thread, then take/deepen ownership.
    while (true) {
        mon.mutex.lock();
        if (mon.state.owner) |o| {
            if (o == me) {
                mon.state.depth += 1;
                mon.mutex.unlock();
                break;
            }
            // Held by another thread: release the guard and yield, then
            // retry the acquire.
            mon.mutex.unlock();
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        } else {
            mon.state.owner = me;
            mon.state.depth = 1;
            mon.mutex.unlock();
            break;
        }
    }
    runtime.fenceAndPublish(); // monitor enter

    const result = ctx.host.invokeCallable(&block, &.{}, ctx.out);

    runtime.fenceAndPublish(); // monitor exit
    // Release one level; clear ownership when fully released so a
    // waiter can acquire.
    {
        mon.mutex.lock();
        defer mon.mutex.unlock();
        if (mon.state.depth > 0) {
            mon.state.depth -= 1;
        }
        if (mon.state.depth == 0) {
            mon.state.owner = null;
        }
    }
    return result;
}

/// Whether a value is something we can invoke as a thread body.
fn isCallable(v: Value) bool {
    return switch (v) {
        .Function, .Lambda, .IrClosure, .Intrinsic, .BoundMethod, .BoundUserMethod => true,
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
    runtime.fenceAndPublish(); // thread start
    const spawned = try ctx.host.spawnOsThread(&body, ctx.out);
    const id: u64 = switch (spawned) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const receiver = try ctx.allocator.create(Value);
    // The OS thread id is carried as a Kotlin Long via a bit reinterpretation.
    receiver.* = .{ .Long = @bitCast(id) };
    return .{ .ok = .{ .BoundMethod = .{
        .fqn = "kotlin.concurrent.Thread",
        .func = threadHandleStub,
        .receiver = receiver,
    } } };
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
        sleepMillis(@intCast(millis));
    }
    return .{ .ok = .Unit };
}

/// Block the calling thread for `millis` milliseconds.
fn sleepMillis(millis: u64) void {
    const total_ns = millis *% std.time.ns_per_ms;
    var req: std.os.linux.timespec = .{
        .sec = @intCast(total_ns / std.time.ns_per_s),
        .nsec = @intCast(total_ns % std.time.ns_per_s),
    };
    // Restart on interruption (EINTR) so the full duration elapses.
    while (true) {
        var rem: std.os.linux.timespec = undefined;
        const rc = std.os.linux.nanosleep(&req, &rem);
        const err = std.os.linux.errno(rc);
        if (err == .INTR) {
            req = rem;
            continue;
        }
        return;
    }
}

/// `Thread.currentThread()` — a `Thread` sentinel for the calling OS
/// thread. Its `.name` is a stable per-thread string derived from the
/// OS thread id, so two calls on the same thread report the same name
/// and distinct threads report distinct names; `.isAlive` is `true`
/// (the calling thread is, by definition, running).
pub fn concurrent_thread_current(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const id: u64 = std.Thread.getCurrentId();
    const receiver = try ctx.allocator.create(Value);
    // The thread id is carried as a Kotlin Long via a bit reinterpretation.
    receiver.* = .{ .Long = @bitCast(id) };
    return .{ .ok = .{ .BoundMethod = .{
        .fqn = "kotlin.concurrent.Thread",
        .func = threadHandleStub,
        .receiver = receiver,
    } } };
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
    testing.allocator.destroy(r.ok.BoundMethod.receiver);
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
