//! Layer 2 — the `kotlinx.coroutines` library.
//!
//! This module is a *client* of the Layer-1 core suspend engine
//! (`ir.eval`): the high-level API (Dispatchers, `CoroutineScope`,
//! Job, Channel, builders) lives in the Kotlin shim, and the few host
//! hooks here only translate library calls into Layer-1 suspension.
//! `delay`/`yield` raise a suspension carrying an opaque resume
//! directive; the default cooperative interceptor (in `interp_ir`)
//! decides when the parked activation resumes. The host never schedules
//! from here — that is the interceptor's sole responsibility — and the
//! core suspend engine never interprets the directive. A
//! cancellation-token registry is shared between Jobs and their bodies;
//! the Kotlin shim observes it through `__kxco_tokenIsCancelled`.

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

/// Layer-2 coroutine library state — one process-global context shared
/// by every interpreting thread. Channels rendezvous across OS threads
/// (a `Dispatchers.Default` worker sends while the `runBlocking` driver
/// receives, or a `kotlin.concurrent.thread` body writes into a channel
/// the driver reads), and a `Job` cancelled on one thread must be
/// observed by a body polling `isActive` on another, so the registry
/// cannot be thread-local: every access holds `coro_reg_mutex`, and the
/// host resume calls a channel operation triggers run strictly after
/// the lock is released (the `outcome` pattern in each binding).
const CoroutineRegistry = struct {
    /// Cancelled cancellation-token ids.
    cancelled_tokens: std.AutoHashMapUnmanaged(i64, void) = .empty,
    /// Monotonic cancellation-token id counter.
    next_token: i64 = 1,
    /// Opaque scheduler-handle FIFO.
    sched_queue: std.ArrayList(i64) = .empty,
};

var coro_reg_mutex: runtime.SpinMutex = .{};
var coro_reg: CoroutineRegistry = .{};

fn regAllocator() std.mem.Allocator {
    return std.heap.page_allocator;
}

/// Empty the registry at the run boundary. The registry spine is
/// page-allocator-backed, but the `Value`s buffered in channels (and the
/// iterator handles in waiter lists) reach into the run's value graph,
/// so entries must not survive into the next run's reset arena — and
/// channel instance identities restart per run, so a stale entry could
/// alias a fresh channel. Registered via `registerRunBoundaryHook` and
/// invoked after every worker thread has joined.
fn sweepRegistryAtRunBoundary() void {
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    coro_reg.cancelled_tokens.deinit(regAllocator());
    coro_reg.sched_queue.deinit(regAllocator());
    coro_reg = .{};
}

/// `Channel(capacity)` — klio-native factory. Bypasses upstream
/// `BufferedChannel`'s CAS-loop allocation (klio's `kotlinx.atomicfu`
/// shims don't implement real CAS, so the upstream impl spins). Returns
/// a synthesised `Value.Instance` whose `identity` keys a `ChannelState`
/// in this thread's registry; every channel member binding finds the
/// state by that key.
/// Channel capacity sentinels mirroring `Channel.Factory`.
const CAP_UNLIMITED: i64 = std.math.maxInt(i32); // Int.MAX_VALUE
const CAP_RENDEZVOUS: i64 = 0;
const CAP_CONFLATED: i64 = -1;
const CAP_BUFFERED: i64 = -2;
const DEFAULT_BUFFER_CAPACITY: usize = 64;

/// Whether a value can be invoked as a `(E) -> Unit` handler. The native
/// `Channel(...)` factory sees the arguments as written, so the
/// `onUndeliveredElement` lambda is identified by shape rather than by
/// position: a capacity is numeric and a `BufferOverflow` is an enum entry,
/// so a callable in any slot is the handler.
fn isCallableValue(v: *const Value) bool {
    return switch (v.*) {
        .IrClosure, .Intrinsic, .BoundMethod => true,
        else => false,
    };
}

/// The channel's `onUndeliveredElement` handler, retained for the caller.
fn undeliveredHandler(id: u64) Value {
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    const state = coro_reg.channels.getPtr(id) orelse return .Null;
    const h = state.on_undelivered;
    if (h != .Null and runtime.reclaimEnabled()) h.retain();
    return h;
}

/// Run the handler for one undelivered element. A handler that THROWS is
/// wrapped in `UndeliveredElementException` and handed back, exactly as
/// upstream's `callUndeliveredElementCatchingException` does; the caller
/// decides whether that surfaces at the call site (a drop, a cancel) or as
/// an unhandled coroutine exception (a cancelled park). Any other failure
/// (a suspension, a control-flow unwind) passes through untouched.
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

/// Report a handler failure the way upstream does when the PARK was
/// cancelled: not at the call site — that coroutine is already unwinding
/// with a `CancellationException` — but through `handleCoroutineException`,
/// which reaches the context's `CoroutineExceptionHandler` and, failing
/// that, the global one. Best effort: a program without the coroutines
/// pack loaded has neither a scope nor the reporter.
fn reportUndeliveredUnhandled(ctx: *CallCtx, err: RuntimeError, scope_in: Value) void {
    if (err != .Thrown) return;
    // The element belongs to the PARKED coroutine, not to whoever is doing
    // the cancelling, so the report goes through that coroutine's context.
    var scope = scope_in;
    if (scope == .Unit) scope = ctx.host.activeCoroScope() orelse return;
    const ctx_res = (ctx.host.getProperty(&scope, "coroutineContext", ctx.out) catch return) orelse return;
    const coro_ctx = switch (ctx_res) {
        .ok => |v| v,
        .err => return,
    };
    // The context's own `CoroutineExceptionHandler`, not the top-level
    // `handleCoroutineException`: its no-handler tail reaches the platform
    // uncaught reporter, which re-enters the runtime from inside a
    // cancellation unwind and wedges it.
    // `context[CoroutineExceptionHandler]` reads the interface's COMPANION,
    // which is the context key; the bare name resolves to the class value.
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

/// Internal-result sentinel handed to `trySelect` when a channel clause
/// resolves because the channel closed. The clause's `processResFunc`
/// re-polls the native channel; this marker just drives the rendezvous.
const CLOSED_MARKER: Value = .Null;

// -------------------------------------------------------------------------
// select { } native channel clauses
//
// The upstream `SelectImplementation` drives `select`: each channel clause
// registers via these intrinsics. `onReceive` / `onSend` poll the native
// channel during registration (taking a value / placing a send immediately
// when ready, completing the select in its registration phase). When not
// ready, the select instance is stored as a receive/send waiter on the
// native channel; a later send/receive/close offers the rendezvous to it by
// calling `SelectInstance.trySelect` (`offerValueToSelectReceivers` /
// `offerSendToSelectSenders`). On completion or cancellation the select
// removes itself via the corresponding remove intrinsic.
// -------------------------------------------------------------------------

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

/// `yield()` — cooperative reschedule: park with a zero-ms wakeup so
/// every other ready coroutine runs before this one continues.
///
/// NOT bound as `kotlinx.coroutines.yield` (see the registry below). That
/// reschedules on klio's own pump, which is not the coroutine's DISPATCHER: a
/// `yield()` inside `runTest` resumed straight from the pump without ever
/// draining the `TestCoroutineScheduler` queue, so the yielding body ran on
/// ahead of the tasks it was yielding TO. Upstream's `yield()` dispatches
/// through the `ContinuationInterceptor`, which is right for every dispatcher
/// including klio's own; it is the one that runs now. Kept for the suspension
/// shape it documents and the test below.
fn yieldNow(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .err = .{ .Suspend = 0 } };
}

/// `__kxco_rbPump(coroutine, block)` — the blocking pump behind the
/// shim's `runBlocking` actual. Drives `block` as the root of a fresh
/// cooperative pump on the calling OS thread; the block starts the
/// `BlockingCoroutine`'s body and parks until the coroutine's job
/// completes, so the pump blocks exactly while the job tree is alive —
/// upstream `runBlocking` semantics through the upstream Job machinery.
/// `coroutine` becomes the active scope so the suspend-implicit
/// `coroutineContext` resolves to the blocking coroutine's context.
fn rbPump(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) {
        return .{ .err = .{ .Type = "__kxco_rbPump: expected the pump block as the trailing arg" } };
    }
    const block = ctx.args[ctx.args.len - 1];
    const scope = if (ctx.args.len >= 2) ctx.args[0] else Value.Null;
    return ctx.host.runBlocking(&block, &scope, ctx.out);
}

/// `__kxco_reportUncaught(message)` — final-resort uncaught-exception
/// report for a root coroutine with no parent job and no handler
/// (`GlobalScope.launch { throw … }`). Upstream's JVM final resort hands
/// the exception to the thread's uncaught handler, which prints it and
/// lets the process continue; klio prints the same shape to stderr.
fn reportUncaught(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const msg: []const u8 = switch (if (ctx.args.len > 0) ctx.args[0] else Value.Null) {
        .String => |s| s.asPtr().bytes,
        else => "exception",
    };
    const name = runtime.threadName(ctx.allocator, std.Thread.getCurrentId()) orelse "main";
    std.debug.print("Exception in thread \"{s}\" {s}\n", .{ name, msg });
    return .{ .ok = .Unit };
}

/// `delay(ms)` — suspend the calling coroutine for `ms` of virtual time.
/// The cooperative driver parks the activation and resumes it once
/// virtual time advances past the wakeup; sibling coroutines run in the
/// meantime. No OS sleep.
fn delayMillis(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const ms: i64 = switch (if (ctx.args.len > 0) ctx.args[0] else Value.Null) {
        .Long => |l| l,
        .Int => |i| @as(i64, i),
        else => return .{ .err = .{ .Type = "kotlinx.coroutines.delay: argument must be Long" } },
    };
    return .{ .err = .{ .Suspend = @max(ms, 0) } };
}

/// Wall-clock time in milliseconds since the Unix epoch.
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

/// `kotlinx.coroutines.internal.__kxco_systemProp(name): String?` —
/// reads tuning out of the host environment so kxco honors the
/// `kotlinx.coroutines.*` knobs JVM callers spell via
/// `System.getProperty`. Probes the env for the exact property name
/// first, then a `.` → `_` alias.
fn kxcoSystemProp(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const key: []const u8 = switch (if (ctx.args.len > 0) ctx.args[0] else Value.Null) {
        .String => |s| s.asPtr().bytes,
        else => return .{ .ok = .Null },
    };
    if (lookupEnv(ctx.allocator, key)) |v| {
        return .{ .ok = .{ .String = try runtime.strInitOwned(ctx.allocator, v) } };
    }
    // `.` → `_` alias.
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

/// Read an environment variable into freshly allocated bytes, or null
/// when unset. The returned slice (when non-null) is owned by `allocator`.
/// Reads the process environment portably (see `runtime.procEnvGetVar`).
/// Any read failure is treated as "unset" (null).
fn lookupEnv(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return runtime.procEnvGetVar(allocator, name) catch null;
}

/// `kotlinx.coroutines.internal.synchronizedImpl(lock, block)` — klio's
/// platform actual for the kxco internal monitor primitive. Routes
/// through the same per-object monitor as `kotlin.synchronized` so
/// atomicfu locks, kxco internals (`LimitedDispatcher`, `ThreadSafeHeap`,
/// …), and any user `synchronized(lock) { … }` call that the resolver
/// lowered to kxco's `synchronized` inline body all share one mutex.
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

/// `__kxco_spawnTimeout { … }` — schedule a `withTimeout` cancellation gate.
/// Distinct from `__kxco_spawn` so the gate can be re-homed onto the pump of
/// the undispatched block it cancels, sharing that block's timer queue.
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

/// `__kxco_dispatch { … }` — post a `Dispatchers.Default` runnable onto
/// the shared dispatcher worker pool (the CPU-bounded view). The body,
/// its captures, and any value it returns cross threads; each shared
/// cell they reach mediates concurrent access through its own
/// reader/writer lock (mirrors the spawned-thread boundary).
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

/// `__kxco_dispatchIo { … }` — `Dispatchers.IO`: the elastic view over
/// the same worker pool as `__kxco_dispatch`.
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

/// `__kxco_joinDispatched(id)` — historical join for the one-thread-per-
/// dispatch model. Pool tasks complete through the coroutine protocol
/// (the runnable resumes its continuation), so there is nothing to join;
/// kept as a no-op for binding stability.
fn joinDispatched(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .ok = .Unit };
}

/// `__kxco_scheduleResume(cont)` — historically queued a continuation for
/// the interpreter to fire between rounds. The cooperative driver resumes
/// parked activations directly through the slot mailbox, so no resume
/// queue is drained and this is a no-op kept for binding stability.
fn scheduleResume(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) {
        return .{ .err = .{ .Type = "__kxco_scheduleResume: expected the continuation arg" } };
    }
    return .{ .ok = .Unit };
}

/// Process-global slot-id counter shared by every kxco rendezvous site.
/// Process-global so cross-thread routing (slot → owning driver mailbox)
/// cannot alias an id minted on another OS thread. Offset above the
/// `kotlin.coroutines` layer's range so the two suspension surfaces never
/// alias in the global slot-owner table.
var kxco_next_slot: std.atomic.Value(i64) = std.atomic.Value(i64).init(1 << 48);

fn allocKxcoSlot() i64 {
    return kxco_next_slot.fetchAdd(1, .monotonic);
}

/// `__kxco_newSlot()` — a fresh unique slot id. Slots back indefinite
/// parking: a coroutine parks on a slot and an explicit event resumes it
/// (job completion, channel handoff).
fn newSlot(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .ok = .{ .Long = allocKxcoSlot() } };
}

/// `__kxco_parkSlot(slot)` — record that the current coroutine is waiting
/// on `slot`, then suspend indefinitely. The active interceptor binds the
/// resulting parked token to the slot so a later `__kxco_resumeSlot(slot)`
/// can resume exactly this activation.
fn parkSlot(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const slot: i64 = switch (if (ctx.args.len > 0) ctx.args[0] else Value.Null) {
        .Long => |l| l,
        .Int => |i| @as(i64, i),
        else => return .{ .err = .{ .Type = "__kxco_parkSlot: argument must be Long" } },
    };
    ctx.host.coroutineArmSlot(slot);
    return .{ .err = .{ .Suspend = -1 } };
}

/// `__kxco_pushScope(scope)` / `__kxco_popScope()` — the dispatched-run
/// scope bracket: a dispatched continuation's segment executes with its
/// own coroutine as the active scope, exactly as `startBlock` brackets an
/// undispatched body. Without it, the segment runs under whatever scope
/// leaked from an earlier activation, and anything derived from the
/// ambient scope (channel-cancellation arming, `coroutineContext` reads)
/// binds to the WRONG coroutine.
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

/// `__kxco_armSlot(slot)` — bind the current coroutine's NEXT suspension
/// (including a timed `__kxco_delayMillis` park) to `slot` WITHOUT
/// suspending now, so `__kxco_resumeSlot(slot)` can preempt the timer. A
/// disposed `withTimeout` waiter must release its parked deadline this way,
/// or the pump (and the enclosing job tree) waits out the full real
/// duration of a timeout that already lost its race.
fn armSlot(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const slot: i64 = switch (if (ctx.args.len > 0) ctx.args[0] else Value.Null) {
        .Long => |l| l,
        .Int => |i| @as(i64, i),
        else => return .{ .err = .{ .Type = "__kxco_armSlot: argument must be Long" } },
    };
    ctx.host.coroutineArmSlot(slot);
    return .{ .ok = .Unit };
}

/// `__kxco_resumeSlot(slot)` — make the coroutine waiting on `slot` ready.
/// No-op if nothing is parked on it yet; the Kotlin waiter re-checks its
/// condition after each park so a missed resume just causes a re-park.
fn resumeSlot(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const slot: i64 = switch (if (ctx.args.len > 0) ctx.args[0] else Value.Null) {
        .Long => |l| l,
        .Int => |i| @as(i64, i),
        else => return .{ .err = .{ .Type = "__kxco_resumeSlot: argument must be Long" } },
    };
    ctx.host.coroutineResumeSlotValue(slot, .Unit);
    return .{ .ok = .Unit };
}

/// Drain the scheduler queue, returning its length as a Kotlin Int count.
fn schedulerDrainCount(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    const n: i32 = @intCast(coro_reg.sched_queue.items.len);
    coro_reg.sched_queue.clearRetainingCapacity();
    return .{ .ok = Value.newInt(@as(i64, n)) };
}

/// The `(fqn, fn)` binding table for the coroutines pack's host bindings.
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

/// Build a `HostBindings` registry mapping each kxco host symbol to its
/// Zig-native intrinsic. The caller owns the returned registry.
pub fn hostBindings(allocator: std.mem.Allocator) std.mem.Allocator.Error!HostBindings {
    // The channel/token registry is process-global but keyed into the
    // run's value graph; sweep it at every run boundary (idempotent
    // registration).
    runtime.registerRunBoundaryHook(sweepRegistryAtRunBoundary);
    var b = HostBindings.init(allocator);
    errdefer b.deinit();
    for (BINDINGS) |entry| {
        try b.register(entry.fqn, entry.f);
    }
    return b;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

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
    // Upstream's `Channel(...)` (BufferedChannel) serves every channel; no
    // native factory or channel member bindings exist.
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
    // Negative millis clamp to zero.
    {
        const args = [_]Value{.{ .Int = -5 }};
        var ctx = makeCtx(&host, &cap, &args);
        const r = try delayMillis(&ctx);
        try testing.expectEqual(@as(i64, 0), r.err.Suspend);
    }
    // Non-numeric argument is a type error.
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

    // Not cancelled yet.
    {
        const args = [_]Value{.{ .Long = id }};
        var c = makeCtx(&host, &cap, &args);
        const r = try tokenIsCancelled(&c);
        try testing.expect(!r.ok.Bool);
    }
    // Cancel it.
    {
        const args = [_]Value{.{ .Long = id }};
        var c = makeCtx(&host, &cap, &args);
        _ = try tokenCancel(&c);
    }
    // Now cancelled.
    {
        const args = [_]Value{.{ .Long = id }};
        var c = makeCtx(&host, &cap, &args);
        const r = try tokenIsCancelled(&c);
        try testing.expect(r.ok.Bool);
    }
    // Token id 0 is never cancelled.
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
    // Draining again yields zero.
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
