//! Host hooks for the `kotlinx.coroutines` library.
//!
//! A client of the core suspend engine (`ir.eval`): the high-level API lives in
//! the Kotlin shim and these hooks only translate library calls into core
//! suspension. `delay` and `yield` raise a suspension carrying an opaque resume
//! directive; scheduling is the cooperative interceptor's sole responsibility,
//! and the suspend engine never interprets the directive.

const std = @import("std");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const StringRef = runtime.StringRef;
const InstanceData = runtime.InstanceData;
const ObjRef = runtime.ObjRef;
const HostBindings = stdlib.HostBindings;

/// One process-global context shared by every interpreting thread: channels
/// rendezvous across OS threads and a `Job` cancelled on one thread must be seen
/// on another. Every access holds `coro_reg_mutex`, and the host resumes a
/// channel operation triggers run strictly after the lock is released.
const CoroutineRegistry = struct {
    cancelled_tokens: std.AutoHashMapUnmanaged(i64, void) = .empty,
    next_token: i64 = 1,
    sched_queue: std.ArrayList(i64) = .empty,
};

var coro_reg_mutex: runtime.SpinMutex = .{};
var coro_reg: CoroutineRegistry = .{};

fn regAllocator() std.mem.Allocator {
    return std.heap.page_allocator;
}

/// Empty the registry at the run boundary: buffered `Value`s and waiter handles
/// reach into the run's value graph, and channel identities restart per run, so
/// no entry may survive. Runs after every worker thread has joined.
fn sweepRegistryAtRunBoundary() void {
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    coro_reg.cancelled_tokens.deinit(regAllocator());
    coro_reg.sched_queue.deinit(regAllocator());
    coro_reg = .{};
}

/// Channel capacity sentinels mirroring `Channel.Factory`.
const CAP_UNLIMITED: i64 = std.math.maxInt(i32); // Int.MAX_VALUE
const CAP_RENDEZVOUS: i64 = 0;
const CAP_CONFLATED: i64 = -1;
const CAP_BUFFERED: i64 = -2;
const DEFAULT_BUFFER_CAPACITY: usize = 64;

/// Whether a value can be invoked as a `(E) -> Unit` handler. The factory sees
/// the arguments as written, so `onUndeliveredElement` is identified by shape: a
/// callable in any slot is the handler.
fn isCallableValue(v: *const Value) bool {
    return switch (v.*) {
        .IrClosure, .Intrinsic, .BoundMethod => true,
        else => false,
    };
}

fn undeliveredHandler(id: u64) Value {
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    const state = coro_reg.channels.getPtr(id) orelse return .Null;
    const h = state.on_undelivered;
    if (h != .Null and runtime.reclaimEnabled()) h.retain();
    return h;
}

/// Run the handler for one undelivered element. A throwing handler is wrapped in
/// `UndeliveredElementException` and handed back, as upstream does; any other
/// failure passes through untouched.
fn runUndelivered(ctx: *CallCtx, handler: Value, value: Value) std.mem.Allocator.Error!?RuntimeError {
    if (handler == .Null) return null;
    const r = try ctx.host.invokeCallable(&handler, &.{value}, ctx.out);
    switch (r) {
        .ok => return null,
        .err => |e| {
            if (e != .Thrown) return e;
            const rendered = value.display(ctx.allocator) catch null;
            defer if (rendered) |m| ctx.allocator.free(m);
            const message = try std.fmt.allocPrint(
                ctx.allocator,
                "Exception in undelivered element handler for {s}",
                .{rendered orelse "?"},
            );
            defer if (runtime.freeScratch()) ctx.allocator.free(message);
            e.Thrown.retain();
            return .{ .Thrown = try Value.newException(ctx.allocator, .{
                .fqn = try runtime.strInit(ctx.allocator, "kotlinx.coroutines.internal.UndeliveredElementException"),
                .message = .from(try runtime.strInit(ctx.allocator, message)),
                .cause = (try Value.boxRef(ctx.allocator, e.Thrown)).cell,
            }) };
        },
    }
}

/// Report a handler failure as upstream does when the park was cancelled:
/// through `handleCoroutineException` rather than at the call site, whose
/// coroutine is already unwinding. Best effort.
fn reportUndeliveredUnhandled(ctx: *CallCtx, err: RuntimeError, scope_in: Value) void {
    if (err != .Thrown) return;
    var scope = scope_in;
    if (scope == .Unit) scope = ctx.host.activeCoroScope() orelse return;
    const ctx_res = (ctx.host.getProperty(&scope, "coroutineContext", ctx.out) catch return) orelse return;
    const coro_ctx = switch (ctx_res) {
        .ok => |v| v,
        .err => return,
    };
    // The context's own `CoroutineExceptionHandler`, not the top-level
    // `handleCoroutineException`, whose no-handler tail re-enters the runtime
    // from inside a cancellation unwind. The context key is the interface's
    // companion.
    var key = ctx.host.lookupGlobal("CoroutineExceptionHandler") orelse return;
    if (key == .Class) {
        if (ctx.host.getProperty(&key, "Key", ctx.out) catch null) |r| {
            if (r == .ok and r.ok != .Null) key = r.ok;
        }
    }
    const got = (ctx.host.invokeMethod(&coro_ctx, "get", &.{key}, ctx.out) catch return) orelse return;
    const handler = switch (got) {
        .ok => |v| v,
        .err => return,
    };
    if (handler == .Null) return;
    _ = ctx.host.invokeMethod(&handler, "handleException", &.{ coro_ctx, err.Thrown }, ctx.out) catch return;
}

fn makeSuccessResult(allocator: std.mem.Allocator, payload: Value) std.mem.Allocator.Error!Value {
    return try Value.newResult(allocator, .{ .ok = true, .payload = try Value.boxRef(allocator, payload) });
}

fn cancellationExc(allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
    return try Value.newException(allocator, .{
        .fqn = try runtime.strInit(allocator, "kotlinx.coroutines.JobCancellationException"),
        .message = .from(try runtime.strInit(allocator, "Job was cancelled")),
        .cause = null,
    });
}

const CLOSED_MARKER: Value = .Null;

// Native channel clauses for `select { }`. Each channel clause registers through
// these intrinsics; `onReceive` and `onSend` poll the native channel during
// registration, completing the select there when ready. Otherwise the select
// instance is stored as a waiter and a later send, receive or close offers it
// the rendezvous through `SelectInstance.trySelect`.

fn closedReceiveExc(allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
    return try Value.newException(allocator, .{
        .fqn = try runtime.strInit(allocator, "kotlinx.coroutines.channels.ClosedReceiveChannelException"),
        .message = .from(try runtime.strInit(allocator, "Channel was closed")),
        .cause = null,
    });
}

fn closedSendExc(allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
    return try Value.newException(allocator, .{
        .fqn = try runtime.strInit(allocator, "kotlinx.coroutines.channels.ClosedSendChannelException"),
        .message = .from(try runtime.strInit(allocator, "Channel was closed")),
        .cause = null,
    });
}

/// A cooperative reschedule: park with a zero-ms wakeup so every other ready
/// coroutine runs first. Deliberately not bound as `kotlinx.coroutines.yield`,
/// which must dispatch through the `ContinuationInterceptor`: rescheduling on
/// klio's own pump would let a `yield()` inside `runTest` resume without
/// draining the `TestCoroutineScheduler` queue.
fn yieldNow(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .err = .{ .Suspend = 0 } };
}

/// The blocking pump behind the shim's `runBlocking` actual. The block starts
/// the `BlockingCoroutine`'s body and parks until its job completes, so the pump
/// blocks exactly while the job tree is alive. `coroutine` becomes the active
/// scope, so the suspend-implicit `coroutineContext` resolves to it.
fn rbPump(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) {
        return .{ .err = .{ .Type = "__kxco_rbPump: expected the pump block as the trailing arg" } };
    }
    const block = ctx.args[ctx.args.len - 1];
    const scope = if (ctx.args.len >= 2) ctx.args[0] else Value.Null;
    return ctx.host.runBlocking(&block, &scope, ctx.out);
}

/// Final-resort uncaught-exception report for a root coroutine with no parent
/// job and no handler, printing to stderr the shape the JVM's thread uncaught
/// handler would.
fn reportUncaught(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const msg: []const u8 = switch (if (ctx.args.len > 0) ctx.args[0] else Value.Null) {
        .String => |s| s.asPtr().bytes,
        else => "exception",
    };
    const name = runtime.threadName(ctx.allocator, std.Thread.getCurrentId()) orelse "main";
    std.debug.print("Exception in thread \"{s}\" {s}\n", .{ name, msg });
    return .{ .ok = .Unit };
}

/// Suspend for `ms` of virtual time: the driver parks the activation and resumes
/// it once virtual time passes the wakeup. No OS sleep.
fn delayMillis(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const ms: i64 = switch (if (ctx.args.len > 0) ctx.args[0] else Value.Null) {
        .Long => |l| l,
        .Int => |i| @as(i64, i),
        else => return .{ .err = .{ .Type = "kotlinx.coroutines.delay: argument must be Long" } },
    };
    return .{ .err = .{ .Suspend = @max(ms, 0) } };
}

fn currentTimeMillis(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .ok = .{ .Long = runtime.clockWallMillis() } };
}

fn tokenCreate(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    const id = coro_reg.next_token;
    coro_reg.next_token = coro_reg.next_token +% 1;
    return .{ .ok = .{ .Long = id } };
}

fn tokenCancel(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const id: i64 = switch (if (ctx.args.len > 0) ctx.args[0] else Value.Null) {
        .Long => |l| l,
        .Int => |i| @as(i64, i),
        else => return .{ .err = .{ .Type = "tokenCancel: argument must be Long" } },
    };
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    try coro_reg.cancelled_tokens.put(regAllocator(), id, {});
    return .{ .ok = .Unit };
}

fn tokenIsCancelled(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const id: i64 = switch (if (ctx.args.len > 0) ctx.args[0] else Value.Null) {
        .Long => |l| l,
        .Int => |i| @as(i64, i),
        else => return .{ .ok = .{ .Bool = false } },
    };
    if (id == 0) return .{ .ok = .{ .Bool = false } };
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    const is_cancelled = coro_reg.cancelled_tokens.contains(id);
    return .{ .ok = .{ .Bool = is_cancelled } };
}

fn schedulerEnqueue(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const h: i64 = switch (if (ctx.args.len > 0) ctx.args[0] else Value.Null) {
        .Long => |l| l,
        .Int => |i| @as(i64, i),
        else => return .{ .err = .{ .Type = "schedulerEnqueue: argument must be Long" } },
    };
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    try coro_reg.sched_queue.append(regAllocator(), h);
    return .{ .ok = .Unit };
}

/// Reads tuning out of the host environment, so kxco honors the
/// `kotlinx.coroutines.*` knobs JVM callers spell through `System.getProperty`.
/// Probes the exact property name first, then a `.` to `_` alias.
fn kxcoSystemProp(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const key: []const u8 = switch (if (ctx.args.len > 0) ctx.args[0] else Value.Null) {
        .String => |s| s.asPtr().bytes,
        else => return .{ .ok = .Null },
    };
    if (lookupEnv(ctx.allocator, key)) |v| {
        return .{ .ok = .{ .String = try runtime.strInitOwned(ctx.allocator, v) } };
    }
    var alias_buf = try ctx.allocator.alloc(u8, key.len);
    defer ctx.allocator.free(alias_buf);
    var differs = false;
    for (key, 0..) |c, i| {
        if (c == '.') {
            alias_buf[i] = '_';
            differs = true;
        } else {
            alias_buf[i] = c;
        }
    }
    if (differs) {
        if (lookupEnv(ctx.allocator, alias_buf)) |v| {
            return .{ .ok = .{ .String = try runtime.strInitOwned(ctx.allocator, v) } };
        }
    }
    return .{ .ok = .Null };
}

fn lookupEnv(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return runtime.procEnvGetVar(allocator, name) catch null;
}

/// The platform actual for the kxco internal monitor primitive, routing through
/// the same per-object monitor as `kotlin.synchronized` so atomicfu locks, kxco
/// internals and user `synchronized` blocks share one mutex.
fn synchronizedImpl(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return stdlib.implementations.concurrent_synchronized(ctx);
}

fn spawnLaunchBlock(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) {
        return .{ .err = .{ .Type = "__kxco_spawn: expected the launch block as the first arg" } };
    }
    const lam = ctx.args[0];
    const scope = ctx.host.lookupGlobal("GlobalScope") orelse Value.Null;
    if (try ctx.host.coroutineLaunch(&lam, &scope, ctx.out)) |e| {
        return .{ .err = e };
    }
    return .{ .ok = .Unit };
}

/// Schedules a `withTimeout` cancellation gate. Distinct from `__kxco_spawn` so
/// the gate can be re-homed onto the pump of the block it cancels, sharing that
/// block's timer queue.
fn spawnTimeoutBlock(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) {
        return .{ .err = .{ .Type = "__kxco_spawnTimeout: expected the timeout block as the first arg" } };
    }
    const lam = ctx.args[0];
    if (try ctx.host.coroutineSpawnTimeout(&lam, ctx.out)) |e| {
        return .{ .err = e };
    }
    return .{ .ok = .Unit };
}

/// Post a `Dispatchers.Default` runnable onto the shared worker pool. The body,
/// its captures and its result cross threads, each shared cell mediating access
/// through its own reader/writer lock.
fn dispatchCoroutine(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) {
        return .{ .err = .{ .Type = "__kxco_dispatch: expected the coroutine block as the first arg" } };
    }
    const block = ctx.args[0];
    if (try ctx.host.coroutineDispatchPooled(&block, false, ctx.out)) |e| {
        return .{ .err = e };
    }
    return .{ .ok = .{ .Long = 0 } };
}

fn dispatchCoroutineIo(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) {
        return .{ .err = .{ .Type = "__kxco_dispatchIo: expected the coroutine block as the first arg" } };
    }
    const block = ctx.args[0];
    if (try ctx.host.coroutineDispatchPooled(&block, true, ctx.out)) |e| {
        return .{ .err = e };
    }
    return .{ .ok = .{ .Long = 0 } };
}

fn joinDispatched(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .ok = .Unit };
}

/// A no-op kept for binding stability: the driver resumes parked activations
/// directly through the slot mailbox.
fn scheduleResume(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) {
        return .{ .err = .{ .Type = "__kxco_scheduleResume: expected the continuation arg" } };
    }
    return .{ .ok = .Unit };
}

/// Slot-id counter shared by every kxco rendezvous site. Process-global so
/// cross-thread routing cannot alias an id minted on another thread, and offset
/// above the `kotlin.coroutines` range so the two surfaces never collide.
var kxco_next_slot: std.atomic.Value(i64) = std.atomic.Value(i64).init(1 << 48);

fn allocKxcoSlot() i64 {
    return kxco_next_slot.fetchAdd(1, .monotonic);
}

/// A fresh slot id. Slots back indefinite parking: an explicit event, a job
/// completion or channel handoff, resumes the parked coroutine.
fn newSlot(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .ok = .{ .Long = allocKxcoSlot() } };
}

/// Record the current coroutine as waiting on `slot`, then suspend indefinitely.
/// The interceptor binds the parked token to the slot, so `__kxco_resumeSlot`
/// resumes exactly this activation.
fn parkSlot(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const slot: i64 = switch (if (ctx.args.len > 0) ctx.args[0] else Value.Null) {
        .Long => |l| l,
        .Int => |i| @as(i64, i),
        else => return .{ .err = .{ .Type = "__kxco_parkSlot: argument must be Long" } },
    };
    ctx.host.coroutineArmSlot(slot);
    return .{ .err = .{ .Suspend = -1 } };
}

/// Bracket a dispatched run so the segment executes with its own coroutine as
/// the active scope. Without it the segment runs under whatever scope an earlier
/// activation left behind, and anything ambient-scope derived binds wrongly.
fn kxcoPushScope(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len >= 1 and ctx.args[0] == .Instance) {
        ctx.host.coroutinePushScope(&ctx.args[0]);
    }
    return .{ .ok = .Unit };
}

fn kxcoPopScope(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    ctx.host.coroutinePopScope();
    return .{ .ok = .Unit };
}

/// Bind the current coroutine's next suspension, a timed park included, to
/// `slot` without suspending now, so `__kxco_resumeSlot` can preempt the timer.
/// A disposed `withTimeout` waiter releases its parked deadline this way.
fn armSlot(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const slot: i64 = switch (if (ctx.args.len > 0) ctx.args[0] else Value.Null) {
        .Long => |l| l,
        .Int => |i| @as(i64, i),
        else => return .{ .err = .{ .Type = "__kxco_armSlot: argument must be Long" } },
    };
    ctx.host.coroutineArmSlot(slot);
    return .{ .ok = .Unit };
}

fn resumeSlot(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const slot: i64 = switch (if (ctx.args.len > 0) ctx.args[0] else Value.Null) {
        .Long => |l| l,
        .Int => |i| @as(i64, i),
        else => return .{ .err = .{ .Type = "__kxco_resumeSlot: argument must be Long" } },
    };
    ctx.host.coroutineResumeSlotValue(slot, .Unit);
    return .{ .ok = .Unit };
}

fn schedulerDrainCount(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    const n: i32 = @intCast(coro_reg.sched_queue.items.len);
    coro_reg.sched_queue.clearRetainingCapacity();
    return .{ .ok = Value.newInt(@as(i64, n)) };
}

const BINDINGS = [_]struct { fqn: []const u8, f: runtime.StdlibFn }{
    .{ .fqn = "kotlinx.coroutines.__kxco_delayMillis", .f = delayMillis },
    .{ .fqn = "kotlinx.coroutines.__kxco_currentTimeMillis", .f = currentTimeMillis },
    .{ .fqn = "kotlinx.coroutines.__kxco_tokenCreate", .f = tokenCreate },
    .{ .fqn = "kotlinx.coroutines.__kxco_tokenCancel", .f = tokenCancel },
    .{ .fqn = "kotlinx.coroutines.__kxco_tokenIsCancelled", .f = tokenIsCancelled },
    .{ .fqn = "kotlinx.coroutines.__kxco_schedulerEnqueue", .f = schedulerEnqueue },
    .{ .fqn = "kotlinx.coroutines.__kxco_schedulerDrainCount", .f = schedulerDrainCount },
    .{ .fqn = "kotlinx.coroutines.__kxco_spawn", .f = spawnLaunchBlock },
    .{ .fqn = "kotlinx.coroutines.__kxco_spawnTimeout", .f = spawnTimeoutBlock },
    .{ .fqn = "kotlinx.coroutines.__kxco_dispatch", .f = dispatchCoroutine },
    .{ .fqn = "kotlinx.coroutines.internal.synchronizedImpl", .f = synchronizedImpl },
    .{ .fqn = "kotlinx.coroutines.internal.__kxco_systemProp", .f = kxcoSystemProp },
    .{ .fqn = "kotlinx.coroutines.__kxco_dispatchIo", .f = dispatchCoroutineIo },
    .{ .fqn = "kotlinx.coroutines.__kxco_joinDispatched", .f = joinDispatched },
    .{ .fqn = "kotlinx.coroutines.__kxco_scheduleResume", .f = scheduleResume },
    .{ .fqn = "kotlinx.coroutines.__kxco_newSlot", .f = newSlot },
    .{ .fqn = "kotlinx.coroutines.__kxco_parkSlot", .f = parkSlot },
    .{ .fqn = "kotlinx.coroutines.__kxco_armSlot", .f = armSlot },
    .{ .fqn = "kotlinx.coroutines.__kxco_pushScope", .f = kxcoPushScope },
    .{ .fqn = "kotlinx.coroutines.__kxco_popScope", .f = kxcoPopScope },
    .{ .fqn = "kotlinx.coroutines.__kxco_systemProperty", .f = kxcoSystemProp },
    .{ .fqn = "kotlinx.coroutines.__kxco_resumeSlot", .f = resumeSlot },
    .{ .fqn = "kotlinx.coroutines.__kxco_rbPump", .f = rbPump },
    .{ .fqn = "kotlinx.coroutines.internal.__kxco_reportUncaught", .f = reportUncaught },
};

pub fn hostBindings(allocator: std.mem.Allocator) std.mem.Allocator.Error!HostBindings {
    runtime.registerRunBoundaryHook(sweepRegistryAtRunBoundary);
    var b = HostBindings.init(allocator);
    errdefer b.deinit();
    for (BINDINGS) |entry| {
        try b.register(entry.fqn, entry.f);
    }
    return b;
}

const testing = std.testing;
const NoopHost = runtime.NoopHost;
const CaptureOutput = runtime.CaptureOutput;

fn resetRegistry() void {
    sweepRegistryAtRunBoundary();
}

fn makeCtx(host: *NoopHost, cap: *CaptureOutput, args: []const Value) CallCtx {
    return .{
        .args = args,
        .out = cap.output(),
        .host = host.host(),
        .allocator = testing.allocator,
    };
}

test "host bindings registry populated" {
    var b = try hostBindings(testing.allocator);
    defer b.deinit();
    try testing.expectEqual(@as(usize, BINDINGS.len), b.len());
    try testing.expect(b.resolve("kotlinx.coroutines.__kxco_delayMillis") != null);
    try testing.expect(b.resolve("kotlinx.coroutines.channels.Channel") == null);
    try testing.expect(b.resolve("kotlinx.coroutines.channels.KlioBufferedChannel.send") == null);
    try testing.expect(b.resolve("kotlinx.coroutines.__kxco_rbPump") != null);
    try testing.expect(b.resolve("not.a.symbol") == null);
}

test "delay suspends for the requested millis" {
    var host = NoopHost.init(testing.allocator);
    defer host.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    {
        const args = [_]Value{.{ .Long = 250 }};
        var ctx = makeCtx(&host, &cap, &args);
        const r = try delayMillis(&ctx);
        try testing.expect(r == .err);
        try testing.expectEqual(@as(i64, 250), r.err.Suspend);
    }
    {
        const args = [_]Value{.{ .Int = -5 }};
        var ctx = makeCtx(&host, &cap, &args);
        const r = try delayMillis(&ctx);
        try testing.expectEqual(@as(i64, 0), r.err.Suspend);
    }
    {
        const args = [_]Value{.Unit};
        var ctx = makeCtx(&host, &cap, &args);
        const r = try delayMillis(&ctx);
        try testing.expect(r == .err and r.err == .Type);
    }
}

test "yield suspends with zero wakeup" {
    var host = NoopHost.init(testing.allocator);
    defer host.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = makeCtx(&host, &cap, &.{});
    const r = try yieldNow(&ctx);
    try testing.expect(r == .err);
    try testing.expectEqual(@as(i64, 0), r.err.Suspend);
}

test "cancellation token lifecycle" {
    defer resetRegistry();
    var host = NoopHost.init(testing.allocator);
    defer host.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var ctx = makeCtx(&host, &cap, &.{});
    const created = try tokenCreate(&ctx);
    const id = created.ok.Long;
    try testing.expect(id >= 1);

    {
        const args = [_]Value{.{ .Long = id }};
        var c = makeCtx(&host, &cap, &args);
        const r = try tokenIsCancelled(&c);
        try testing.expect(!r.ok.Bool);
    }
    {
        const args = [_]Value{.{ .Long = id }};
        var c = makeCtx(&host, &cap, &args);
        _ = try tokenCancel(&c);
    }
    {
        const args = [_]Value{.{ .Long = id }};
        var c = makeCtx(&host, &cap, &args);
        const r = try tokenIsCancelled(&c);
        try testing.expect(r.ok.Bool);
    }
    {
        const args = [_]Value{.{ .Long = 0 }};
        var c = makeCtx(&host, &cap, &args);
        const r = try tokenIsCancelled(&c);
        try testing.expect(!r.ok.Bool);
    }
}

test "scheduler enqueue and drain count" {
    defer resetRegistry();
    var host = NoopHost.init(testing.allocator);
    defer host.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    inline for ([_]i64{ 10, 20, 30 }) |h| {
        const args = [_]Value{.{ .Long = h }};
        var c = makeCtx(&host, &cap, &args);
        _ = try schedulerEnqueue(&c);
    }
    var c = makeCtx(&host, &cap, &.{});
    const r = try schedulerDrainCount(&c);
    try testing.expectEqual(@as(i32, 3), r.ok.Int);
    const r2 = try schedulerDrainCount(&c);
    try testing.expectEqual(@as(i32, 0), r2.ok.Int);
}

test "new slot ids are unique and offset" {
    var host = NoopHost.init(testing.allocator);
    defer host.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = makeCtx(&host, &cap, &.{});
    const a = (try newSlot(&ctx)).ok.Long;
    const b = (try newSlot(&ctx)).ok.Long;
    try testing.expect(a >= (1 << 48));
    try testing.expect(b == a + 1);
}

test "current time millis returns a long" {
    var host = NoopHost.init(testing.allocator);
    defer host.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = makeCtx(&host, &cap, &.{});
    const r = try currentTimeMillis(&ctx);
    try testing.expect(r.ok == .Long);
    try testing.expect(r.ok.Long > 0);
}

const ast = @import("ast");
const span = @import("span");
const Env = runtime.Env;
const ClassDef = runtime.ClassDef;


test {
    std.testing.refAllDecls(@This());
}
