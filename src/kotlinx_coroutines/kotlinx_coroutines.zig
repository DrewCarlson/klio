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

/// State for a klio-native Channel: a bounded FIFO with optional
/// suspend-waiters. Stored per-instance keyed on the synthesised
/// `Instance.identity` so the Zig intrinsic seam can find it from any
/// binding entry-point. `closed` short-circuits future receives to
/// throw `ClosedReceiveChannelException` after the buffer drains.
const ChannelState = struct {
    buffer: Deque(Value),
    capacity: usize,
    /// Buffer-overflow policy. `suspend` parks a sender when the buffer is
    /// full; `drop_oldest`/`drop_latest` never park, dropping an element
    /// instead. A conflated channel is capacity-1 `drop_oldest`.
    overflow: Overflow,
    /// A rendezvous channel (`Channel<T>()` / capacity 0) has no buffer at
    /// all: `send` always parks until a receiver takes the element.
    rendezvous: bool,
    closed: bool,
    /// Cause supplied to the first successful `close`/`cancel`, retained so
    /// a handler registered after closure observes the same value.
    close_cause: Value,
    /// Kotlin permits exactly one `invokeOnClose` registration, including
    /// after the channel has already closed.
    close_handler_registered: bool,
    /// `receive()` / `receiveCatching()` callers currently parked because
    /// the buffer was empty. The next `send` resumes the head waiter. A
    /// `catching` waiter is resumed with a `ChannelResult.success(value)`
    /// (its caller is `receiveCatching`); a plain waiter with the value.
    receive_waiters: Deque(RecvWaiter),
    /// Iterator-style waiters: a parked `for (v in ch)` `hasNext()`
    /// caller plus a handle to its iterator instance, so the next
    /// send can stash the value in `__pending__` on the iterator
    /// and resume hasNext with `Bool(true)` (instead of the value).
    receive_iter_waiters: Deque(IterWaiter),
    /// Slot ids of `send(v)` callers parked because the buffer was
    /// full. The next `receive()` resumes the head and admits its
    /// pending value into the buffer.
    send_waiters: Deque(SendWaiter),
    /// `select { … }` operations registered to *receive* from this channel
    /// (an `onReceive` / `onReceiveCatching` clause). When a value becomes
    /// available the channel offers it to each registered select via
    /// `SelectInstance.trySelect`; the first that accepts takes the value.
    /// A select removes itself once it commits to any clause.
    select_recv_waiters: Deque(ObjRef(InstanceData)),
    /// `select { … }` operations registered to *send* to this channel (an
    /// `onSend` clause). When a buffer slot frees, the channel offers the
    /// send to each registered select via `trySelect`.
    select_send_waiters: Deque(ObjRef(InstanceData)),
    /// `SendChannel.invokeOnClose` handlers — each a `(cause: Throwable?) ->
    /// Unit`. Invoked once, in registration order, when the channel closes
    /// (with the close cause, or null for a normal close). Registering on an
    /// already-closed channel invokes immediately.
    close_handlers: Deque(Value),

    /// Every waiter records the coroutine scope that parked (`scope`), so a
    /// later delivery can resume it the way its own interceptor would: a
    /// waiter whose context carries a dispatcher that needs dispatch (a
    /// `TestDispatcher`, any custom dispatcher) gets its resume DISPATCHED
    /// through that dispatcher's queue, keeping it ordered with every other
    /// task on it — exactly what resuming the intercepted continuation does
    /// upstream. `Unit` when no scope was active at park time.
    const IterWaiter = struct { slot: i64, iter: ObjRef(InstanceData), scope: Value = .Unit };
    const SendWaiter = struct { slot: i64, value: Value, scope: Value = .Unit };
    const RecvWaiter = struct { slot: i64, catching: bool, scope: Value = .Unit };
    const Overflow = enum { suspend_, drop_oldest, drop_latest };

    fn init(capacity: usize, overflow: Overflow, rendezvous: bool) ChannelState {
        return .{
            .buffer = Deque(Value).empty,
            .capacity = capacity,
            .overflow = overflow,
            .rendezvous = rendezvous,
            .closed = false,
            .close_cause = .Null,
            .close_handler_registered = false,
            .receive_waiters = Deque(RecvWaiter).empty,
            .receive_iter_waiters = Deque(IterWaiter).empty,
            .send_waiters = Deque(SendWaiter).empty,
            .select_recv_waiters = Deque(ObjRef(InstanceData)).empty,
            .select_send_waiters = Deque(ObjRef(InstanceData)).empty,
            .close_handlers = Deque(Value).empty,
        };
    }

    fn deinit(self: *ChannelState, allocator: std.mem.Allocator) void {
        if (runtime.reclaimEnabled()) {
            self.close_cause.release(allocator);
            for (self.close_handlers.items.items) |h| h.release(allocator);
        }
        self.buffer.deinit(allocator);
        self.receive_waiters.deinit(allocator);
        self.receive_iter_waiters.deinit(allocator);
        self.send_waiters.deinit(allocator);
        self.select_recv_waiters.deinit(allocator);
        self.select_send_waiters.deinit(allocator);
        self.close_handlers.deinit(allocator);
    }

    fn removeSelectInst(deque: *Deque(ObjRef(InstanceData)), sel: ObjRef(InstanceData)) void {
        var i: usize = 0;
        while (i < deque.items.items.len) {
            if (ObjRef(InstanceData).ptrEq(deque.items.items[i], sel)) {
                _ = deque.items.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }
};

/// Minimal FIFO deque over an `ArrayList`. `pushBack` appends; `popFront`
/// removes from the head. Mirrors the subset of `VecDeque` the channel
/// state uses (push_back / pop_front / drain / len / is_empty).
fn Deque(comptime T: type) type {
    return struct {
        const Self = @This();
        items: std.ArrayList(T) = .empty,

        pub const empty: Self = .{ .items = .empty };

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.items.deinit(allocator);
        }

        fn pushBack(self: *Self, allocator: std.mem.Allocator, v: T) std.mem.Allocator.Error!void {
            try self.items.append(allocator, v);
        }

        fn popFront(self: *Self) ?T {
            if (self.items.items.len == 0) return null;
            return self.items.orderedRemove(0);
        }

        fn len(self: *const Self) usize {
            return self.items.items.len;
        }

        fn isEmpty(self: *const Self) bool {
            return self.items.items.len == 0;
        }

        /// Drain every element into an owned slice (FIFO order), leaving
        /// the deque empty. Caller frees the returned slice.
        fn drain(self: *Self, allocator: std.mem.Allocator) std.mem.Allocator.Error![]T {
            const out = try self.items.toOwnedSlice(allocator);
            self.items = .empty;
            return out;
        }
    };
}

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
    /// klio-native channel registry keyed on the synthesised channel
    /// `Instance.identity`. Lets the channel send/receive bindings find
    /// their state from any entry-point without threading a host handle
    /// through the call stack.
    channels: std.AutoHashMapUnmanaged(u64, ChannelState) = .empty,
    /// Cancellation watchers for parked channel waiters, keyed by the
    /// waiter's park slot. Each value is the `CancellableContinuation` of a
    /// child coroutine launched by `__kxco_chanArmCancel` that awaits
    /// cancellation; a normal value delivery resumes it (so the parking
    /// coroutine's Job completes) and a cancellation fires its
    /// `invokeOnCancellation` to wake the parked waiter with the cause.
    chan_watchers: std.AutoHashMapUnmanaged(i64, Value) = .empty,
    /// Slots whose waiter was delivered/woken before the watcher child got
    /// a chance to bind its continuation (a value handed off in the same
    /// pump turn the waiter parked). The watcher, when it finally binds,
    /// completes immediately instead of parking — so it never outlives the
    /// suspension it guards.
    chan_delivered: std.AutoHashMapUnmanaged(i64, void) = .empty,
    /// Resume values for channel deliveries routed through the waiter's own
    /// Kotlin dispatcher (`__kxco_chanResumeRoute`): stashed here while the
    /// dispatched runnable is in flight, consumed by `__kxco_chanResumeNow`
    /// when the dispatcher runs it.
    chan_pending_resume: std.AutoHashMapUnmanaged(i64, Value) = .empty,
};

var coro_reg_mutex: runtime.SpinMutex = .{};
var coro_reg: CoroutineRegistry = .{};

fn regAllocator() std.mem.Allocator {
    return std.heap.page_allocator;
}

// GC root: the channel registry is a process-global with no Vm linkage, so the
// Values buffered in channels and parked in waiter lists are reachable only
// here. Registered once on first channel creation; the collector marks them
// under the registry mutex (never held across a safe point, so STW-safe).
var coro_reg_root_registered = std.atomic.Value(bool).init(false);

fn ensureCoroRegRoot() void {
    if (!runtime.gc.gc_enabled) return;
    if (!coro_reg_root_registered.swap(true, .monotonic))
        runtime.gc.registerRoot(gcMarkCoroReg);
}

fn gcMarkCoroReg(m: *runtime.gc.Marker) void {
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    var it = coro_reg.channels.valueIterator();
    while (it.next()) |st| {
        for (st.buffer.items.items) |v| v.gcMark(m);
        for (st.send_waiters.items.items) |w| {
            w.value.gcMark(m);
            w.scope.gcMark(m);
        }
        for (st.receive_waiters.items.items) |w| w.scope.gcMark(m);
        for (st.receive_iter_waiters.items.items) |w| {
            m.shade(&w.iter.cell.hdr);
            w.scope.gcMark(m);
        }
        for (st.select_recv_waiters.items.items) |sel| m.shade(&sel.cell.hdr);
        for (st.select_send_waiters.items.items) |sel| m.shade(&sel.cell.hdr);
        st.close_cause.gcMark(m);
        for (st.close_handlers.items.items) |h| h.gcMark(m);
    }
    var wit = coro_reg.chan_watchers.valueIterator();
    while (wit.next()) |w| w.gcMark(m);
    var pit = coro_reg.chan_pending_resume.valueIterator();
    while (pit.next()) |v| v.gcMark(m);
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
    var it = coro_reg.channels.valueIterator();
    while (it.next()) |state| state.deinit(regAllocator());
    coro_reg.channels.deinit(regAllocator());
    var wit = coro_reg.chan_watchers.valueIterator();
    while (wit.next()) |w| w.release(regAllocator());
    coro_reg.chan_watchers.deinit(regAllocator());
    coro_reg.chan_delivered.deinit(regAllocator());
    coro_reg.chan_pending_resume.deinit(regAllocator());
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
const BUFFERED_CHANNEL_FQN = "kotlinx.coroutines.channels.KlioBufferedChannel";
const CONFLATED_CHANNEL_FQN = "kotlinx.coroutines.channels.KlioConflatedBufferedChannel";

fn channelIllegalArgument(ctx: *CallCtx, message: []const u8) std.mem.Allocator.Error!EvalResult {
    return .{ .err = .{ .Thrown = .{ .Exception = .{
        .fqn = try runtime.strInit(ctx.allocator, "kotlin.IllegalArgumentException"),
        .message = .from(try runtime.strInit(ctx.allocator, message)),
        .cause = null,
    } } } };
}

fn channelIllegalState(ctx: *CallCtx, message: []const u8) std.mem.Allocator.Error!EvalResult {
    return .{ .err = .{ .Thrown = .{ .Exception = .{
        .fqn = try runtime.strInit(ctx.allocator, "kotlin.IllegalStateException"),
        .message = .from(try runtime.strInit(ctx.allocator, message)),
        .cause = null,
    } } } };
}

fn channelCreate(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    // arg0 is the capacity (Int / Long); arg1, when present, is the
    // `BufferOverflow` policy enum entry. `Channel(...)` is shadowed by
    // this native factory, so these arrive exactly as the user spelled
    // them (the upstream `when(capacity)` lowering does not run).
    const cap_arg: Value = if (ctx.args.len > 0) ctx.args[0] else Value.newInt(CAP_RENDEZVOUS);
    const capacity: i64 = switch (cap_arg) {
        .Int => |n| @as(i64, n),
        .Long => |n| n,
        else => CAP_RENDEZVOUS,
    };
    const overflow_arg: Value = if (ctx.args.len > 1) ctx.args[1] else Value.Null;
    const overflow = overflowOf(&overflow_arg);

    var rendezvous = false;
    var effective_cap: usize = undefined;
    var eff_overflow = overflow;
    var class_fqn: []const u8 = BUFFERED_CHANNEL_FQN;
    if (capacity == CAP_CONFLATED) {
        if (overflow != .suspend_) {
            return channelIllegalArgument(ctx, "CONFLATED capacity cannot be used with non-default onBufferOverflow");
        }
        // A conflated channel keeps only the latest value: capacity-1
        // drop-oldest, regardless of the requested overflow policy.
        effective_cap = 1;
        eff_overflow = .drop_oldest;
        class_fqn = CONFLATED_CHANNEL_FQN;
    } else if (capacity == CAP_UNLIMITED) {
        effective_cap = std.math.maxInt(usize);
    } else if (capacity == CAP_BUFFERED) {
        if (overflow == .suspend_) {
            effective_cap = DEFAULT_BUFFER_CAPACITY;
        } else {
            effective_cap = 1;
            class_fqn = CONFLATED_CHANNEL_FQN;
        }
    } else if (capacity == CAP_RENDEZVOUS) {
        if (overflow == .suspend_) {
            // A true rendezvous: no buffer, `send` parks until received.
            rendezvous = true;
            effective_cap = 0;
        } else {
            // RENDEZVOUS with a non-default overflow degrades to a
            // capacity-1 buffered channel (upstream `ConflatedBufferedChannel`).
            effective_cap = 1;
            class_fqn = CONFLATED_CHANNEL_FQN;
        }
    } else {
        if (capacity < 0) {
            const message = try std.fmt.allocPrint(ctx.allocator, "Invalid channel capacity: {d}, should be >=0", .{capacity});
            defer if (runtime.freeScratch()) ctx.allocator.free(message);
            return channelIllegalArgument(ctx, message);
        }
        effective_cap = @intCast(capacity);
        if (overflow != .suspend_) class_fqn = CONFLATED_CHANNEL_FQN;
    }

    const id = ctx.host.allocInstanceId();
    ensureCoroRegRoot();
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        try coro_reg.channels.put(regAllocator(), id, ChannelState.init(effective_cap, eff_overflow, rendezvous));
    }
    const inst = try ctx.host.newSynthInstance(class_fqn, id, &.{});
    return .{ .ok = inst };
}

/// Read a `BufferOverflow` enum entry's policy from its `ordinal` field
/// (SUSPEND=0, DROP_OLDEST=1, DROP_LATEST=2). Defaults to `suspend`.
fn overflowOf(v: *const Value) ChannelState.Overflow {
    if (v.* == .Instance) {
        if (v.Instance.asPtr().get("ordinal")) |ord| {
            const n: i64 = switch (ord) {
                .Int => |i| @as(i64, i),
                .Long => |l| l,
                else => 0,
            };
            return switch (n) {
                1 => .drop_oldest,
                2 => .drop_latest,
                else => .suspend_,
            };
        }
    }
    return .suspend_;
}

/// Build a `ChannelResult<T>` by calling the Kotlin companion factory
/// (`ChannelResult.success/failure/closed`) so the value-class semantics
/// (`isSuccess`/`getOrNull`/`isClosed`) are the upstream ones. Falls back
/// to the raw value when the companion cannot be resolved.
fn channelResult(ctx: *CallCtx, comptime kind: enum { success, failure, closed }, payload: Value) std.mem.Allocator.Error!Value {
    const cls = ctx.host.lookupGlobal("ChannelResult") orelse return payload;
    const name = switch (kind) {
        .success => "success",
        .failure => "failure",
        .closed => "closed",
    };
    const args: []const Value = switch (kind) {
        .success => &.{payload},
        .failure => &.{},
        .closed => &.{payload},
    };
    const r = (try ctx.host.invokeMethod(&cls, name, args, ctx.out)) orelse return payload;
    return switch (r) {
        .ok => |val| val,
        .err => payload,
    };
}

fn channelId(arg0: *const Value) ?u64 {
    return switch (arg0.*) {
        .Instance => |i| i.asPtr().identity,
        else => null,
    };
}

/// `select`'s `SelectInstance.trySelect(clauseObject, internalResult)`,
/// called on a Kotlin select instance to make a rendezvous with a now-ready
/// channel clause. Returns `true` when this select committed to the clause
/// (so the offered value/slot is consumed by it). Invoked outside the
/// registry lock: `trySelect` resumes the select's parked continuation
/// inline through the cooperative driver, which must not run under the lock.
fn selectTrySelect(ctx: *CallCtx, sel: ObjRef(InstanceData), clause_obj: Value, internal: Value) bool {
    var recv = Value{ .Instance = sel };
    const args = [_]Value{ clause_obj, internal };
    const r = ctx.host.invokeMethod(&recv, "trySelect", &args, ctx.out) catch return false;
    const res = r orelse {
        if (runtime.envOnce("KLIO_SELDBG") != null) std.debug.print("[seldbg] trySelect: no result\n", .{});
        return false;
    };
    if (runtime.envOnce("KLIO_SELDBG") != null) {
        switch (res) {
            .ok => |v| std.debug.print("[seldbg] trySelect ok tag={s} val={}\n", .{ @tagName(std.meta.activeTag(v)), v == .Bool and v.Bool }),
            .err => |e| std.debug.print("[seldbg] trySelect ERR {s}\n", .{@tagName(std.meta.activeTag(e))}),
        }
    }
    return switch (res) {
        .ok => |v| (v == .Bool and v.Bool),
        .err => false,
    };
}

/// Register cancellation interest for a coroutine about to park on a
/// channel `send`/`receive`/iterator slot. A native channel park bypasses
/// `suspendCancellableCoroutine`, so without this a `Job.cancel` (or
/// `withTimeout` expiry) could never reach the parked waiter and
/// `cancelAndJoin`/`join` would hang. The Kotlin helper `__kxco_chanArmCancel`
/// launches, on the parking coroutine's own scope, a child that parks in a
/// `suspendCancellableCoroutine`; when the Job is cancelled the child is
/// cancelled with it (structured concurrency), firing the continuation's
/// `invokeOnCancellation`, which calls `__kxco_chanCancelWaiter(channel, slot,
/// cause)` to remove the waiter and resume its slot with `Result.failure` — a
/// throw at the suspension point, so the user's `finally` runs and the join
/// completes. A normal value delivery resumes the watcher (see
/// `resumeWaiterNormal`) so the child does not outlive the suspension. This
/// reuses the proven `suspendCancellableCoroutine` cancellation path.
fn armChannelCancel(ctx: *CallCtx, chan: Value, slot: i64) void {
    const scope = ctx.host.activeCoroScope() orelse {
        if (runtime.envOnce("KLIO_CHAN_DIAG") != null)
            std.debug.print("[chan] arm slot={d}: NO ACTIVE SCOPE\n", .{slot});
        return;
    };
    if (runtime.envOnce("KLIO_CHAN_DIAG") != null) {
        const cls: []const u8 = if (scope == .Instance) blk: {
            const g = scope.Instance.borrow();
            defer g.deinit();
            const cg = g.get().class.borrow();
            defer cg.deinit();
            break :blk cg.get().name;
        } else scope.typeFqn();
        std.debug.print("[chan] arm slot={d} scope={s} id={x}\n", .{ slot, cls, if (scope == .Instance) scope.Instance.identity() else 0 });
    }
    if (scope != .Instance) return;
    const helper = ctx.host.lookupGlobalFunc("__kxco_chanArmCancel") orelse return;
    const args = [_]Value{ scope, chan, .{ .Long = slot } };
    _ = ctx.host.invokeCallable(&helper, &args, ctx.out) catch return;
}

/// `__kxco_chanBindHandle(slot, handle)` — store the DisposableHandle of the
/// cancelling handler armed for the waiter parked on `slot`. A normal delivery
/// disposes it (`dropWatcher`), so no handler is left on the coroutine's Job for
/// a waiter that no longer exists. A handle bound AFTER the value was already
/// delivered is disposed immediately.
fn channelBindHandle(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 2) return .{ .ok = .Unit };
    const slot: i64 = switch (ctx.args[0]) {
        .Long => |l| l,
        .Int => |i| @as(i64, i),
        else => return .{ .ok = .Unit },
    };
    const handle = ctx.args[1];
    const already_delivered = blk: {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        if (coro_reg.chan_delivered.fetchRemove(slot) != null) break :blk true;
        handle.retain();
        if (coro_reg.chan_watchers.fetchPut(regAllocator(), slot, handle) catch null) |old| {
            old.value.release(regAllocator());
        }
        break :blk false;
    };
    if (already_delivered) {
        var recv = handle;
        _ = ctx.host.invokeMethod(&recv, "dispose", &.{}, ctx.out) catch {};
    }
    return .{ .ok = .Unit };
}

/// `__kxco_chanBindWatcher(slot, cont)` — store the cancellation-watcher
/// continuation for the waiter parked on `slot`, so a normal value delivery
/// can resume (complete) the watcher child. If the waiter was ALREADY
/// delivered before the watcher bound (a same-turn handoff), complete the
/// watcher immediately so it never parks.
fn channelBindWatcher(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 2) return .{ .ok = .Unit };
    const slot: i64 = switch (ctx.args[0]) {
        .Long => |l| l,
        .Int => |i| @as(i64, i),
        else => return .{ .ok = .Unit },
    };
    const cont = ctx.args[1];
    const already_delivered = blk: {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        if (runtime.envOnce("KLIO_CHAN_DIAG") != null)
            std.debug.print("[chan] bindWatcher slot={d}\n", .{slot});
        if (coro_reg.chan_delivered.fetchRemove(slot) != null) break :blk true;
        cont.retain();
        if (coro_reg.chan_watchers.fetchPut(regAllocator(), slot, cont) catch null) |old| {
            old.value.release(regAllocator());
        }
        break :blk false;
    };
    if (already_delivered) {
        // The waiter already received its value; complete the watcher now.
        var recv = cont;
        const ok_unit = try makeSuccessResult(ctx.allocator, .Unit);
        _ = ctx.host.invokeMethod(&recv, "resumeWith", &.{ok_unit}, ctx.out) catch {};
    }
    return .{ .ok = .Unit };
}

/// Complete and drop the cancellation-watcher child bound to `slot` (a
/// normal value delivery / close woke the real waiter, so the watcher must
/// finish too). Resumes the watcher's `suspendCancellableCoroutine` with
/// `Unit`. If the watcher has not bound yet (it is still queued to start),
/// record the slot as delivered so it completes immediately on bind. Runs
/// outside `coro_reg_mutex` (the resume drives Kotlin).
fn dropWatcher(ctx: *CallCtx, slot: i64) void {
    if (runtime.envOnce("KLIO_CHAN_DIAG") != null)
        std.debug.print("[chan] dropWatcher slot={d}\n", .{slot});
    const cont: ?Value = blk: {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        if (coro_reg.chan_watchers.fetchRemove(slot)) |kv| break :blk kv.value;
        // No watcher bound yet: mark delivered so a later bind self-completes.
        coro_reg.chan_delivered.put(regAllocator(), slot, {}) catch {};
        break :blk null;
    };
    if (cont) |c| {
        defer c.release(regAllocator());
        var recv = c;
        // The entry is the cancelling handler's DisposableHandle: the waiter got
        // its value, so the handler has nothing left to cancel.
        _ = ctx.host.invokeMethod(&recv, "dispose", &.{}, ctx.out) catch {};
    }
}

/// Take the stashed dispatched-resume value for `slot`, if the dispatched
/// runnable has not consumed it yet.
fn takePendingResume(slot: i64) ?Value {
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    if (coro_reg.chan_pending_resume.fetchRemove(slot)) |kv| return kv.value;
    return null;
}

/// Resume a parked channel waiter with a normally-delivered value, then
/// complete its cancellation watcher so the watcher child does not keep the
/// parking coroutine's Job alive.
///
/// `scope` is the coroutine that parked (captured at park time). Upstream, a
/// channel waiter is an intercepted continuation: its resume goes through its
/// own dispatcher, keeping it ordered with everything else on that
/// dispatcher's queue. klio's native park has no Kotlin continuation, so the
/// routing decision is re-created here via `__kxco_chanResumeRoute`:
///   1 — the waiter's dispatcher accepted a runnable; the delivery happens
///       when it runs (`__kxco_chanResumeNow` picks the value up from the
///       pending stash). A `runTest` body's waiter thereby resumes on the
///       virtual scheduler IN ORDER with the tasks around it, instead of on
///       the starved pump after the body finished.
///   2 — the dispatcher needs no dispatch (`Unconfined`): run the waiter now,
///       on this stack, exactly as `executeUnconfined` would.
///   3 — a pump-backed klio dispatcher accepted a runnable. It shares the
///       owning pump but must stay in the dispatch FIFO with `yield()` tasks.
///   0 — no dispatcher / a worker dispatcher whose pump mailbox is already
///       the dispatch queue.
fn resumeWaiterNormal(ctx: *CallCtx, slot: i64, value: Value, scope: Value) void {
    route: {
        if (scope != .Instance) break :route;
        const helper = ctx.host.lookupGlobalFunc("__kxco_chanResumeRoute") orelse break :route;
        {
            coro_reg_mutex.lock();
            defer coro_reg_mutex.unlock();
            coro_reg.chan_pending_resume.put(regAllocator(), slot, value) catch break :route;
        }
        const args = [_]Value{ scope, .{ .Long = slot } };
        const res = ctx.host.invokeCallable(&helper, &args, ctx.out) catch {
            _ = takePendingResume(slot);
            break :route;
        };
        const code: i64 = switch (res) {
            .ok => |v| switch (v) {
                .Int => |i| @as(i64, i),
                .Long => |l| l,
                else => 0,
            },
            .err => 0,
        };
        if (runtime.envOnce("KLIO_CHAN_DIAG") != null)
            std.debug.print("[chan] resumeRoute slot={d} code={d}\n", .{ slot, code });
        switch (code) {
            1 => {
                // Dispatched; the runnable delivers (it may already have, if
                // the dispatcher ran it synchronously). The watcher completes
                // now: the waiter irrevocably owns the value.
                //
                // The waiter's dispatcher (a `runTest` `TestCoroutineScheduler`)
                // orders this resume on ITS queue, not the pump's ready queue,
                // so mark the owning pump: its dispatched resumes (a `yield`)
                // must keep the inline shortcut rather than defer to `drv.ready`.
                ctx.host.markSlotOwnerSchedulerBacked(slot);
                dropWatcher(ctx, slot);
                return;
            },
            3 => {
                // The runnable is ordered with every other KlioDispatcher
                // task on the pump. Unlike an external scheduler, it does not
                // change how the pump's own ready queue is drained.
                dropWatcher(ctx, slot);
                return;
            },
            2 => {
                const v = takePendingResume(slot) orelse {
                    dropWatcher(ctx, slot);
                    return;
                };
                ctx.host.coroutineResumeContinuation(slot, v, ctx.out);
                dropWatcher(ctx, slot);
                return;
            },
            else => {
                _ = takePendingResume(slot);
            },
        }
    }
    ctx.host.coroutineResumeSlotValue(slot, value);
    dropWatcher(ctx, slot);
}

/// `__kxco_chanResumeNow(slot)` — the dispatched channel delivery: the
/// waiter's own dispatcher decided this is the moment its coroutine runs, so
/// the resume happens exactly like a Kotlin `Continuation.resumeWith` on the
/// caller's stack (inline when a pump on this thread holds the slot, the
/// external route otherwise). A missing stash means the delivery already
/// happened (an idempotent re-run); nothing to do.
fn chanResumeNow(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .ok = .Unit };
    const slot: i64 = switch (ctx.args[0]) {
        .Long => |l| l,
        .Int => |i| @as(i64, i),
        else => return .{ .ok = .Unit },
    };
    const v = takePendingResume(slot) orelse return .{ .ok = .Unit };
    ctx.host.coroutineResumeContinuation(slot, v, ctx.out);
    return .{ .ok = .Unit };
}

fn makeSuccessResult(allocator: std.mem.Allocator, payload: Value) std.mem.Allocator.Error!Value {
    return .{ .Result = .{ .ok = true, .payload = try Value.boxRef(allocator, payload) } };
}

/// `__kxco_chanCancelWaiter(channel, slot, cause)` — invoked from the
/// Kotlin cancellation handler installed by `armChannelCancel`. Removes the
/// waiter parked on `slot` from the channel's send/receive/iterator queues
/// and, if it was still parked, resumes its slot with `Result.failure(cause)`
/// so the parked `send`/`receive` throws the cancellation at its suspension
/// point. Idempotent: a slot already handed a value (delivered before the
/// cancel landed) is no longer in any queue, so the resume is skipped — no
/// double-resume.
fn channelCancelWaiter(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 2) return .{ .ok = .Unit };
    if (runtime.envOnce("KLIO_CHAN_DIAG") != null) {
        const sl: i64 = switch (ctx.args[1]) {
            .Long => |l| l,
            .Int => |i| @as(i64, i),
            else => -1,
        };
        std.debug.print("[chan] cancelWaiter slot={d}\n", .{sl});
    }
    const recv = ctx.args[0];
    const slot: i64 = switch (ctx.args[1]) {
        .Long => |l| l,
        .Int => |i| @as(i64, i),
        else => return .{ .ok = .Unit },
    };
    const cause: Value = if (ctx.args.len > 2) ctx.args[2] else Value.Null;
    const id = channelId(&recv) orelse return .{ .ok = .Unit };

    // The watcher firing means the parking coroutine is being cancelled; drop
    // its watcher entry (it is completing) so it is not resumed again, and
    // any stale "delivered" marker for this slot.
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        if (coro_reg.chan_watchers.fetchRemove(slot)) |kv| kv.value.release(regAllocator());
        _ = coro_reg.chan_delivered.remove(slot);
    }

    var found = false;
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        if (coro_reg.channels.getPtr(id)) |state| {
            found = removeWaiterBySlot(state, slot);
        }
    }
    if (!found) return .{ .ok = .Unit };

    // A throw at the suspension point: `Result.failure(cause)` routed by
    // the resume engine as `pending_throw_from_inner` (see ir/eval.zig).
    const cancellation: Value = if (cause == .Null) try cancellationExc(ctx.allocator) else cause;
    const failure = Value{ .Result = .{ .ok = false, .payload = try Value.boxRef(ctx.allocator, cancellation) } };
    ctx.host.coroutineResumeExternal(slot, failure, ctx.out);
    return .{ .ok = .Unit };
}

/// Drop the channel waiter (send/receive/iterator) whose park slot equals
/// `slot`. Returns whether one was removed.
fn removeWaiterBySlot(state: *ChannelState, slot: i64) bool {
    {
        var i: usize = 0;
        while (i < state.receive_waiters.items.items.len) : (i += 1) {
            if (state.receive_waiters.items.items[i].slot == slot) {
                _ = state.receive_waiters.items.orderedRemove(i);
                return true;
            }
        }
    }
    {
        var i: usize = 0;
        while (i < state.send_waiters.items.items.len) : (i += 1) {
            if (state.send_waiters.items.items[i].slot == slot) {
                _ = state.send_waiters.items.orderedRemove(i);
                return true;
            }
        }
    }
    {
        var i: usize = 0;
        while (i < state.receive_iter_waiters.items.items.len) : (i += 1) {
            if (state.receive_iter_waiters.items.items[i].slot == slot) {
                _ = state.receive_iter_waiters.items.orderedRemove(i);
                return true;
            }
        }
    }
    return false;
}

fn cancellationExc(allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
    return .{ .Exception = .{
        .fqn = try runtime.strInit(allocator, "kotlinx.coroutines.JobCancellationException"),
        .message = .from(try runtime.strInit(allocator, "Job was cancelled")),
        .cause = null,
    } };
}

/// Offer `value` (a value the channel can deliver now) to the registered
/// `onReceive` selects in FIFO order. The first select whose `trySelect`
/// accepts takes the value; rejected (already-completed) selects are
/// dropped. Returns `true` when a select took the value. The channel
/// instance (`chan`) is the clause object the select registered with.
/// Pops one waiter at a time under the lock, offers it lock-free, and
/// stops at the first acceptor — matching a single rendezvous.
fn offerValueToSelectReceivers(ctx: *CallCtx, id: u64, chan: Value, value: Value) bool {
    while (true) {
        var sel: ?ObjRef(InstanceData) = null;
        {
            coro_reg_mutex.lock();
            defer coro_reg_mutex.unlock();
            if (coro_reg.channels.getPtr(id)) |state| {
                sel = state.select_recv_waiters.popFront();
            }
        }
        const s = sel orelse return false;
        if (selectTrySelect(ctx, s, chan, value)) return true;
        // Rejected: that select committed elsewhere or was cancelled; it is
        // already removed from this list (popped above). Try the next.
    }
}

/// Notify the registered `onSend` selects that the channel can now accept a
/// send (a buffer slot freed or a receiver parked). Each accepting select
/// performs its own send through its clause block, so the internal result
/// passed is `Unit`. Stops at the first acceptor. Returns `true` when a
/// select took the send opportunity.
fn offerSendToSelectSenders(ctx: *CallCtx, id: u64, chan: Value) bool {
    while (true) {
        var sel: ?ObjRef(InstanceData) = null;
        {
            coro_reg_mutex.lock();
            defer coro_reg_mutex.unlock();
            if (coro_reg.channels.getPtr(id)) |state| {
                sel = state.select_send_waiters.popFront();
            }
        }
        const s = sel orelse return false;
        // A non-`Unit` internal result signals `klioProcessSend` to place the
        // value now (it skips placement on `Unit`, which marks a value already
        // sent during registration). Without this a woken `onSend` select
        // completes without ever handing its value to the waiting receiver.
        if (selectTrySelect(ctx, s, chan, .{ .Bool = true })) return true;
    }
}

const ChannelSendOutcome = union(enum) {
    HandToReceiver: struct { slot: i64, value: Value, catching: bool, scope: Value },
    HandToIter: struct { slot: i64, scope: Value },
    Buffered,
    ParkOnSlot: i64,
    Closed: Value,
};

fn channelSend(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "Channel.send expects a receiver" } };
    const recv = ctx.args[0];
    const value: Value = if (ctx.args.len > 1) ctx.args[1] else .Unit;
    const id = channelId(&recv) orelse return .{ .err = .{ .Type = "Channel.send: bad receiver" } };
    const park_scope = ctx.host.activeCoroScope() orelse Value.Unit;
    // If a receiver is parked, hand the value straight to it without
    // buffering. Otherwise the channel's capacity / overflow policy
    // decides: a rendezvous channel always parks the sender; a buffered
    // channel pushes while it has room; a full buffer either parks
    // (SUSPEND) or drops an element (DROP_OLDEST / DROP_LATEST). The whole
    // check-and-transition is one atomic section under the registry lock;
    // the host resume runs after release.
    var outcome: ChannelSendOutcome = undefined;
    var offer_to_selects = false;
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        const state = coro_reg.channels.getPtr(id) orelse return .{ .err = .{ .Type = "Channel.send: missing state" } };
        if (runtime.envOnce("KLIO_SELDBG") != null) {
            std.debug.print("[seldbg] send id={d} sel_recv={d} recv_waiters={d} rendezvous={}\n", .{ id, state.select_recv_waiters.len(), state.receive_waiters.len(), state.rendezvous });
        }
        if (state.closed) {
            outcome = .{ .Closed = state.close_cause };
        } else if (state.receive_iter_waiters.popFront()) |w| {
            // Iterator waiters take priority — write the value into the iter's
            // `__pending__` field and resume with Bool(true).
            try w.iter.asPtr().define(regAllocator(), "__pending__", value);
            try setIteratorNextState(w.iter, .value_ready);
            outcome = .{ .HandToIter = .{ .slot = w.slot, .scope = w.scope } };
        } else if (state.receive_waiters.popFront()) |w| {
            outcome = .{ .HandToReceiver = .{ .slot = w.slot, .value = value, .catching = w.catching, .scope = w.scope } };
        } else if (state.select_recv_waiters.len() > 0) {
            // A registered `onReceive` select may take this value directly.
            // Offering calls `trySelect` (Kotlin), so it must run outside the
            // lock; defer to after release.
            offer_to_selects = true;
            outcome = .Buffered; // tentative; reconsidered below
        } else if (state.rendezvous) {
            const slot = allocKxcoSlot();
            try state.send_waiters.pushBack(regAllocator(), .{ .slot = slot, .value = value, .scope = park_scope });
            outcome = .{ .ParkOnSlot = slot };
        } else if (state.buffer.len() < state.capacity) {
            try state.buffer.pushBack(regAllocator(), value);
            outcome = .Buffered;
        } else switch (state.overflow) {
            .suspend_ => {
                const slot = allocKxcoSlot();
                try state.send_waiters.pushBack(regAllocator(), .{ .slot = slot, .value = value, .scope = park_scope });
                outcome = .{ .ParkOnSlot = slot };
            },
            .drop_oldest => {
                _ = state.buffer.popFront();
                try state.buffer.pushBack(regAllocator(), value);
                outcome = .Buffered;
            },
            .drop_latest => outcome = .Buffered,
        }
    }

    if (offer_to_selects) {
        if (offerValueToSelectReceivers(ctx, id, recv, value)) {
            return .{ .ok = .Unit };
        }
        // No select took it — fall back to the buffer-or-park decision.
        var fallback: ChannelSendOutcome = undefined;
        {
            coro_reg_mutex.lock();
            defer coro_reg_mutex.unlock();
            const state = coro_reg.channels.getPtr(id) orelse return .{ .err = .{ .Type = "Channel.send: missing state" } };
            if (state.closed) {
                fallback = .{ .Closed = state.close_cause };
            } else if (state.receive_waiters.popFront()) |w| {
                fallback = .{ .HandToReceiver = .{ .slot = w.slot, .value = value, .catching = w.catching, .scope = w.scope } };
            } else if (state.rendezvous) {
                const slot = allocKxcoSlot();
                try state.send_waiters.pushBack(regAllocator(), .{ .slot = slot, .value = value, .scope = park_scope });
                fallback = .{ .ParkOnSlot = slot };
            } else if (state.buffer.len() < state.capacity) {
                try state.buffer.pushBack(regAllocator(), value);
                fallback = .Buffered;
            } else switch (state.overflow) {
                .suspend_ => {
                    const slot = allocKxcoSlot();
                    try state.send_waiters.pushBack(regAllocator(), .{ .slot = slot, .value = value, .scope = park_scope });
                    fallback = .{ .ParkOnSlot = slot };
                },
                .drop_oldest => {
                    _ = state.buffer.popFront();
                    try state.buffer.pushBack(regAllocator(), value);
                    fallback = .Buffered;
                },
                .drop_latest => fallback = .Buffered,
            }
        }
        outcome = fallback;
    }

    switch (outcome) {
        .HandToReceiver => |h| {
            const resume_val = if (h.catching) try channelResult(ctx, .success, h.value) else h.value;
            resumeWaiterNormal(ctx, h.slot, resume_val, h.scope);
            return .{ .ok = .Unit };
        },
        .HandToIter => |h| {
            resumeWaiterNormal(ctx, h.slot, .{ .Bool = true }, h.scope);
            return .{ .ok = .Unit };
        },
        .Buffered => return .{ .ok = .Unit },
        .ParkOnSlot => |slot| {
            ctx.host.coroutineArmSlot(slot);
            armChannelCancel(ctx, recv, slot);
            return .{ .err = .{ .Suspend = -1 } };
        },
        .Closed => |cause| return .{ .err = .{ .Thrown = try channelCloseException(ctx.allocator, cause, false) } },
    }
}

const ChannelTrySendOutcome = union(enum) {
    HandToReceiver: struct { slot: i64, value: Value, catching: bool, scope: Value },
    Success,
    Full,
    Closed: Value,
};

fn channelTrySend(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "Channel.trySend expects a receiver" } };
    const recv = ctx.args[0];
    const value: Value = if (ctx.args.len > 1) ctx.args[1] else .Unit;
    const id = channelId(&recv) orelse return .{ .err = .{ .Type = "Channel.trySend: bad receiver" } };

    var outcome: ChannelTrySendOutcome = undefined;
    var offer_to_selects = false;
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        const state = coro_reg.channels.getPtr(id) orelse return .{ .err = .{ .Type = "Channel.trySend: missing state" } };
        if (state.closed) {
            outcome = .{ .Closed = state.close_cause };
        } else if (state.receive_iter_waiters.popFront()) |w| {
            try w.iter.asPtr().define(regAllocator(), "__pending__", value);
            try setIteratorNextState(w.iter, .value_ready);
            outcome = .{ .HandToReceiver = .{ .slot = w.slot, .value = .{ .Bool = true }, .catching = false, .scope = w.scope } };
        } else if (state.receive_waiters.popFront()) |w| {
            outcome = .{ .HandToReceiver = .{ .slot = w.slot, .value = value, .catching = w.catching, .scope = w.scope } };
        } else if (state.select_recv_waiters.len() > 0) {
            offer_to_selects = true;
            outcome = .Success; // tentative; reconsidered below
        } else if (state.rendezvous) {
            // No buffer and no parked receiver: a rendezvous `trySend`
            // cannot complete synchronously.
            outcome = .Full;
        } else if (state.buffer.len() < state.capacity) {
            try state.buffer.pushBack(regAllocator(), value);
            outcome = .Success;
        } else switch (state.overflow) {
            .suspend_ => outcome = .Full,
            .drop_oldest => {
                _ = state.buffer.popFront();
                try state.buffer.pushBack(regAllocator(), value);
                outcome = .Success;
            },
            .drop_latest => outcome = .Success,
        }
    }

    if (offer_to_selects) {
        if (offerValueToSelectReceivers(ctx, id, recv, value)) {
            return .{ .ok = try channelResult(ctx, .success, .Unit) };
        }
        // No select took it — re-decide buffer vs full under the lock,
        // resuming any receiver after release.
        var fb: ChannelTrySendOutcome = undefined;
        {
            coro_reg_mutex.lock();
            defer coro_reg_mutex.unlock();
            const state = coro_reg.channels.getPtr(id) orelse return .{ .ok = try channelResult(ctx, .failure, .Unit) };
            if (state.closed) {
                fb = .{ .Closed = state.close_cause };
            } else if (state.receive_waiters.popFront()) |w| {
                fb = .{ .HandToReceiver = .{ .slot = w.slot, .value = value, .catching = w.catching, .scope = w.scope } };
            } else if (state.rendezvous) {
                fb = .Full;
            } else if (state.buffer.len() < state.capacity) {
                try state.buffer.pushBack(regAllocator(), value);
                fb = .Success;
            } else switch (state.overflow) {
                .suspend_ => fb = .Full,
                .drop_oldest => {
                    _ = state.buffer.popFront();
                    try state.buffer.pushBack(regAllocator(), value);
                    fb = .Success;
                },
                .drop_latest => fb = .Success,
            }
        }
        switch (fb) {
            .HandToReceiver => |h| {
                const resume_val = if (h.catching) try channelResult(ctx, .success, h.value) else h.value;
                resumeWaiterNormal(ctx, h.slot, resume_val, h.scope);
                return .{ .ok = try channelResult(ctx, .success, .Unit) };
            },
            .Success => return .{ .ok = try channelResult(ctx, .success, .Unit) },
            .Full => return .{ .ok = try channelResult(ctx, .failure, .Unit) },
            .Closed => |cause| {
                const exc = try channelCloseException(ctx.allocator, cause, false);
                defer if (runtime.reclaimEnabled()) exc.release(ctx.allocator);
                return .{ .ok = try channelResult(ctx, .closed, exc) };
            },
        }
    }

    const result: Value = switch (outcome) {
        .HandToReceiver => |h| blk: {
            const resume_val = if (h.catching) try channelResult(ctx, .success, h.value) else h.value;
            resumeWaiterNormal(ctx, h.slot, resume_val, h.scope);
            break :blk try channelResult(ctx, .success, .Unit);
        },
        .Success => try channelResult(ctx, .success, .Unit),
        .Full => try channelResult(ctx, .failure, .Unit),
        .Closed => |cause| blk: {
            const exc = try channelCloseException(ctx.allocator, cause, false);
            defer if (runtime.reclaimEnabled()) exc.release(ctx.allocator);
            break :blk try channelResult(ctx, .closed, exc);
        },
    };
    return .{ .ok = result };
}

const ChannelReceiveOutcome = union(enum) {
    Got: struct { value: Value, resumed: ?i64, resumed_scope: Value = .Unit },
    Closed: Value,
    ParkOnSlot: i64,
};

fn channelReceive(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return channelReceiveImpl(ctx, false);
}

/// `receiveCatching()` — like `receive`, but a closed channel yields a
/// `ChannelResult.closed(...)` instead of throwing, and a delivered value
/// is wrapped in `ChannelResult.success(...)`.
fn channelReceiveCatching(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return channelReceiveImpl(ctx, true);
}

fn channelReceiveImpl(ctx: *CallCtx, catching: bool) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "Channel.receive expects a receiver" } };
    const recv = ctx.args[0];
    const id = channelId(&recv) orelse return .{ .err = .{ .Type = "Channel.receive: bad receiver" } };
    const park_scope = ctx.host.activeCoroScope() orelse Value.Unit;

    var outcome: ChannelReceiveOutcome = undefined;
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        const state = coro_reg.channels.getPtr(id) orelse return .{ .err = .{ .Type = "Channel.receive: missing state" } };
        if (state.buffer.popFront()) |v| {
            const resumed_sender = state.send_waiters.popFront();
            if (resumed_sender) |sw| {
                try state.buffer.pushBack(regAllocator(), sw.value);
            }
            outcome = .{ .Got = .{
                .value = v,
                .resumed = if (resumed_sender) |sw| sw.slot else null,
                .resumed_scope = if (resumed_sender) |sw| sw.scope else .Unit,
            } };
        } else if (state.send_waiters.popFront()) |sw| {
            // A rendezvous channel never buffers: a parked sender's value
            // is handed directly to this receiver and the sender resumes.
            outcome = .{ .Got = .{ .value = sw.value, .resumed = sw.slot, .resumed_scope = sw.scope } };
        } else if (state.closed) {
            outcome = .{ .Closed = state.close_cause };
        } else {
            const slot = allocKxcoSlot();
            try state.receive_waiters.pushBack(regAllocator(), .{ .slot = slot, .catching = catching, .scope = park_scope });
            outcome = .{ .ParkOnSlot = slot };
        }
    }

    switch (outcome) {
        .Got => |g| {
            if (g.resumed) |slot| resumeWaiterNormal(ctx, slot, .Unit, g.resumed_scope);
            // Freeing a buffer slot lets a registered `onSend` select proceed.
            _ = offerSendToSelectSenders(ctx, id, recv);
            if (catching) return .{ .ok = try channelResult(ctx, .success, g.value) };
            return .{ .ok = g.value };
        },
        .Closed => |cause| {
            if (catching) return .{ .ok = try channelResult(ctx, .closed, cause) };
            return .{ .err = .{ .Thrown = try channelCloseException(ctx.allocator, cause, true) } };
        },
        .ParkOnSlot => |slot| {
            ctx.host.coroutineArmSlot(slot);
            armChannelCancel(ctx, recv, slot);
            // This receiver is now parked in `receive_waiters`; a registered
            // `onSend` select can hand its value straight to it (the mirror of
            // a send offering a parked `onReceive` select). Without this an
            // `onSend` select that parked before any receiver arrived would
            // never be woken by a later plain `receive`.
            _ = offerSendToSelectSenders(ctx, id, recv);
            return .{ .err = .{ .Suspend = -1 } };
        },
    }
}

const ChannelTryReceiveOutcome = union(enum) {
    Got: Value,
    Empty,
    Closed: Value,
};

fn channelTryReceive(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "Channel.tryReceive expects a receiver" } };
    const recv = ctx.args[0];
    const id = channelId(&recv) orelse return .{ .err = .{ .Type = "Channel.tryReceive: bad receiver" } };

    var outcome: ChannelTryReceiveOutcome = .{ .Closed = .Null };
    var resumed_slot: ?i64 = null;
    var resumed_scope: Value = .Unit;
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        if (coro_reg.channels.getPtr(id)) |state| {
            if (state.buffer.popFront()) |v| {
                const resumed_sender = state.send_waiters.popFront();
                if (resumed_sender) |sw| {
                    try state.buffer.pushBack(regAllocator(), sw.value);
                    resumed_slot = sw.slot;
                    resumed_scope = sw.scope;
                }
                outcome = .{ .Got = v };
            } else if (state.send_waiters.popFront()) |sw| {
                // A rendezvous channel buffers nothing; a parked sender's
                // value is the element a `tryReceive` retrieves.
                resumed_slot = sw.slot;
                resumed_scope = sw.scope;
                outcome = .{ .Got = sw.value };
            } else if (state.closed) {
                outcome = .{ .Closed = state.close_cause };
            } else {
                outcome = .Empty;
            }
        }
    }
    if (resumed_slot) |slot| resumeWaiterNormal(ctx, slot, .Unit, resumed_scope);
    // A retrieved element frees a buffer slot, letting a registered `onSend`
    // select proceed.
    if (outcome == .Got) _ = offerSendToSelectSenders(ctx, id, recv);
    const result: Value = switch (outcome) {
        .Got => |v| try channelResult(ctx, .success, v),
        .Empty => try channelResult(ctx, .failure, .Unit),
        .Closed => |cause| try channelResult(ctx, .closed, cause),
    };
    return .{ .ok = result };
}

fn channelClose(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return channelCloseImpl(ctx, false);
}

fn channelCloseImpl(ctx: *CallCtx, cancel_pending_sends: bool) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "Channel.close expects a receiver" } };
    const recv = ctx.args[0];
    const close_cause: Value = if (ctx.args.len > 1) ctx.args[1] else .Null;
    const id = channelId(&recv) orelse return .{ .err = .{ .Type = "Channel.close: bad receiver" } };

    var recvs: []ChannelState.RecvWaiter = &.{};
    var iters: []ChannelState.IterWaiter = &.{};
    var sends: []ChannelState.SendWaiter = &.{};
    var discarded: []Value = &.{};
    var did_close = false;
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        const state = coro_reg.channels.getPtr(id) orelse
            return .{ .err = .{ .Type = "Channel.close: missing state" } };
        if (!state.closed) {
            state.closed = true;
            state.close_cause = close_cause;
            if (runtime.reclaimEnabled()) close_cause.retain();
            did_close = true;
            recvs = try state.receive_waiters.drain(regAllocator());
            iters = try state.receive_iter_waiters.drain(regAllocator());
            if (cancel_pending_sends) {
                sends = try state.send_waiters.drain(regAllocator());
                discarded = try state.buffer.drain(regAllocator());
            }
        }
    }
    if (!did_close) return .{ .ok = .{ .Bool = false } };
    defer regAllocator().free(recvs);
    defer regAllocator().free(iters);
    defer regAllocator().free(sends);
    defer regAllocator().free(discarded);
    if (runtime.reclaimEnabled()) for (discarded) |v| v.release(regAllocator());

    const exc = try closedReceiveExc(ctx.allocator);
    defer exc.release(ctx.allocator);
    for (recvs) |w| {
        // A parked `receiveCatching()` resumes with a closed result; a
        // parked `receive()` resumes with a `Result` failure that rethrows
        // the close cause at the suspension point.
        if (w.catching) {
            resumeWaiterNormal(ctx, w.slot, try channelResult(ctx, .closed, close_cause), w.scope);
        } else {
            const receive_exc = if (close_cause == .Null) exc else close_cause;
            receive_exc.retain();
            const failure = Value{ .Result = .{ .ok = false, .payload = try Value.boxRef(ctx.allocator, receive_exc) } };
            resumeWaiterNormal(ctx, w.slot, failure, w.scope);
        }
    }
    // A normal close makes iterator `hasNext()` return false. A failed close
    // throws its exact cause at the suspended `hasNext()` call.
    for (iters) |w| {
        if (close_cause == .Null) {
            try setIteratorNextState(w.iter, .closed_ready);
            resumeWaiterNormal(ctx, w.slot, .{ .Bool = false }, w.scope);
        } else {
            close_cause.retain();
            const failure = Value{ .Result = .{ .ok = false, .payload = try Value.boxRef(ctx.allocator, close_cause) } };
            resumeWaiterNormal(ctx, w.slot, failure, w.scope);
        }
    }
    for (sends) |sw| {
        const send_exc = try channelCloseException(ctx.allocator, close_cause, false);
        const failure = Value{ .Result = .{ .ok = false, .payload = try Value.boxRef(ctx.allocator, send_exc) } };
        resumeWaiterNormal(ctx, sw.slot, failure, sw.scope);
    }
    // A close makes every registered receive/send clause resolvable
    // (a closed result for `onReceiveCatching`, a failure otherwise). Offer
    // the closed state to each registered select; its clause re-polls the
    // channel and observes the close.
    var sel_recvs: []ObjRef(InstanceData) = &.{};
    var sel_sends: []ObjRef(InstanceData) = &.{};
    var handlers: []Value = &.{};
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        if (coro_reg.channels.getPtr(id)) |state| {
            sel_recvs = state.select_recv_waiters.drain(regAllocator()) catch &.{};
            sel_sends = state.select_send_waiters.drain(regAllocator()) catch &.{};
            handlers = state.close_handlers.drain(regAllocator()) catch &.{};
        }
    }
    defer regAllocator().free(sel_recvs);
    defer regAllocator().free(sel_sends);
    defer regAllocator().free(handlers);
    for (sel_recvs) |sel| _ = selectTrySelect(ctx, sel, recv, CLOSED_MARKER);
    for (sel_sends) |sel| _ = selectTrySelect(ctx, sel, recv, CLOSED_MARKER);
    // The sole `invokeOnClose` handler observes the exact close cause. Its
    // exception propagates from `close` after the channel has transitioned to
    // closed, matching the library contract.
    for (handlers) |h| {
        const result = try ctx.host.invokeCallable(&h, &.{close_cause}, ctx.out);
        if (runtime.reclaimEnabled()) h.release(ctx.allocator);
        if (result == .err) return .{ .err = result.err };
    }
    return .{ .ok = .{ .Bool = true } };
}

/// `ReceiveChannel.cancel(null)` closes with a synthesized cancellation
/// exception, unlike `SendChannel.close(null)`, whose close cause is null.
fn channelCancel(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "Channel.cancel expects a receiver" } };
    if (ctx.args.len > 1 and ctx.args[1] != .Null) return channelCloseImpl(ctx, true);

    const cause = Value{ .Exception = .{
        .fqn = try runtime.strInit(ctx.allocator, "kotlinx.coroutines.CancellationException"),
        .message = .from(try runtime.strInit(ctx.allocator, "Channel was cancelled")),
        .cause = null,
    } };
    defer if (runtime.reclaimEnabled()) cause.release(ctx.allocator);
    const args = [_]Value{ ctx.args[0], cause };
    var forwarded = ctx.*;
    forwarded.args = &args;
    return channelCloseImpl(&forwarded, true);
}

/// Exact cause retained by a closed native channel, or null after a normal
/// close. The select shim uses it to build the same closed result or thrown
/// exception as direct receive/send operations.
fn channelCloseCause(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .ok = .Null };
    const id = channelId(&ctx.args[0]) orelse return .{ .ok = .Null };
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    const cause = if (coro_reg.channels.getPtr(id)) |state| state.close_cause else Value.Null;
    cause.retain();
    return .{ .ok = cause };
}

/// `SendChannel.invokeOnClose(handler)` — register a `(cause: Throwable?) ->
/// Unit` invoked once when the channel closes. On an already-closed channel
/// the handler runs immediately with the channel's retained close cause.
fn channelInvokeOnClose(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 2) return .{ .err = .{ .Arity = "Channel.invokeOnClose expects (receiver, handler)" } };
    const recv = ctx.args[0];
    const handler = ctx.args[1];
    const id = channelId(&recv) orelse return .{ .err = .{ .Type = "Channel.invokeOnClose: bad receiver" } };
    var run_now = false;
    var duplicate = false;
    var cause: Value = .Null;
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        const state = coro_reg.channels.getPtr(id) orelse return .{ .err = .{ .Type = "Channel.invokeOnClose: missing state" } };
        if (state.close_handler_registered) {
            duplicate = true;
        } else {
            state.close_handler_registered = true;
            if (state.closed) {
                run_now = true;
                cause = state.close_cause;
                if (runtime.reclaimEnabled()) cause.retain();
            } else {
                if (runtime.reclaimEnabled()) handler.retain();
                try state.close_handlers.pushBack(regAllocator(), handler);
            }
        }
    }
    if (duplicate) {
        return channelIllegalState(ctx, "Another handler was already registered and successfully invoked");
    }
    if (run_now) {
        defer if (runtime.reclaimEnabled()) cause.release(ctx.allocator);
        const result = try ctx.host.invokeCallable(&handler, &.{cause}, ctx.out);
        if (result == .err) return .{ .err = result.err };
    }
    return .{ .ok = .Unit };
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

/// `__kxco_chanSelectAddReceiver(channel, select)` — store `select` as an
/// `onReceive` waiter on `channel`. A later send/close offers it a value via
/// `trySelect`.
fn channelSelectAddReceiver(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 2) return .{ .err = .{ .Arity = "selectAddReceiver expects (channel, select)" } };
    const id = channelId(&ctx.args[0]) orelse return .{ .err = .{ .Type = "selectAddReceiver: bad channel" } };
    const sel: ObjRef(InstanceData) = switch (ctx.args[1]) {
        .Instance => |i| i,
        else => return .{ .err = .{ .Type = "selectAddReceiver: bad select" } },
    };
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    if (coro_reg.channels.getPtr(id)) |state| try state.select_recv_waiters.pushBack(regAllocator(), sel);
    return .{ .ok = .Unit };
}

/// `__kxco_chanSelectRemoveReceiver(channel, select)` — drop `select` from
/// the `onReceive` waiters (commit/cancel cleanup).
fn channelSelectRemoveReceiver(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 2) return .{ .err = .{ .Arity = "selectRemoveReceiver expects (channel, select)" } };
    const id = channelId(&ctx.args[0]) orelse return .{ .err = .{ .Type = "selectRemoveReceiver: bad channel" } };
    const sel: ObjRef(InstanceData) = switch (ctx.args[1]) {
        .Instance => |i| i,
        else => return .{ .err = .{ .Type = "selectRemoveReceiver: bad select" } },
    };
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    if (coro_reg.channels.getPtr(id)) |state| ChannelState.removeSelectInst(&state.select_recv_waiters, sel);
    return .{ .ok = .Unit };
}

/// `__kxco_chanSelectAddSender(channel, select)` — store `select` as an
/// `onSend` waiter on `channel`.
fn channelSelectAddSender(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 2) return .{ .err = .{ .Arity = "selectAddSender expects (channel, select)" } };
    const id = channelId(&ctx.args[0]) orelse return .{ .err = .{ .Type = "selectAddSender: bad channel" } };
    const sel: ObjRef(InstanceData) = switch (ctx.args[1]) {
        .Instance => |i| i,
        else => return .{ .err = .{ .Type = "selectAddSender: bad select" } },
    };
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    if (coro_reg.channels.getPtr(id)) |state| try state.select_send_waiters.pushBack(regAllocator(), sel);
    return .{ .ok = .Unit };
}

/// `__kxco_chanSelectRemoveSender(channel, select)` — drop `select` from the
/// `onSend` waiters.
fn channelSelectRemoveSender(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 2) return .{ .err = .{ .Arity = "selectRemoveSender expects (channel, select)" } };
    const id = channelId(&ctx.args[0]) orelse return .{ .err = .{ .Type = "selectRemoveSender: bad channel" } };
    const sel: ObjRef(InstanceData) = switch (ctx.args[1]) {
        .Instance => |i| i,
        else => return .{ .err = .{ .Type = "selectRemoveSender: bad select" } },
    };
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    if (coro_reg.channels.getPtr(id)) |state| ChannelState.removeSelectInst(&state.select_send_waiters, sel);
    return .{ .ok = .Unit };
}

/// `__kxco_chanSelectPollReceive(channel, holder): Int` — atomically take a
/// value if one is available. Returns `0` and writes the received value into
/// `holder.value` when a value is taken (admitting a parked sender),
/// `1` when the channel is closed-and-drained (the receive clause fails or
/// yields a closed result), or `2` when no value is ready right now. A taken
/// value frees a buffer slot, so any parked sender is admitted and a
/// registered `onSend` select is offered the freed slot.
fn channelSelectPollReceive(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 2) return .{ .err = .{ .Arity = "selectPollReceive expects (channel, holder)" } };
    const id = channelId(&ctx.args[0]) orelse return .{ .err = .{ .Type = "selectPollReceive: bad channel" } };
    const holder: ObjRef(InstanceData) = switch (ctx.args[1]) {
        .Instance => |i| i,
        else => return .{ .err = .{ .Type = "selectPollReceive: bad holder" } },
    };

    const Outcome = union(enum) {
        Got: struct { value: Value, resumed: ?i64, resumed_scope: Value = .Unit },
        Closed,
        NotReady,
    };
    var outcome: Outcome = undefined;
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        const state = coro_reg.channels.getPtr(id) orelse return .{ .ok = Value.newInt(2) };
        if (state.buffer.popFront()) |v| {
            const resumed_sender = state.send_waiters.popFront();
            var resumed: ?i64 = null;
            var resumed_scope: Value = .Unit;
            if (resumed_sender) |sw| {
                try state.buffer.pushBack(regAllocator(), sw.value);
                resumed = sw.slot;
                resumed_scope = sw.scope;
            }
            outcome = .{ .Got = .{ .value = v, .resumed = resumed, .resumed_scope = resumed_scope } };
        } else if (state.send_waiters.popFront()) |sw| {
            // Empty buffer (or rendezvous) but a sender is parked: take its
            // value directly and admit the sender, exactly as a plain
            // `receive` rendezvous does. Without this an `onReceive` select
            // would miss a parked sender and park forever.
            outcome = .{ .Got = .{ .value = sw.value, .resumed = sw.slot, .resumed_scope = sw.scope } };
        } else if (state.closed) {
            outcome = .Closed;
        } else {
            outcome = .NotReady;
        }
    }
    switch (outcome) {
        .Got => |g| {
            try holder.asPtr().define(regAllocator(), "value", g.value);
            if (g.resumed) |slot| resumeWaiterNormal(ctx, slot, .Unit, g.resumed_scope);
            _ = offerSendToSelectSenders(ctx, id, ctx.args[0]);
            return .{ .ok = Value.newInt(0) };
        },
        .Closed => return .{ .ok = Value.newInt(1) },
        .NotReady => return .{ .ok = Value.newInt(2) },
    }
}

/// `__kxco_chanSelectPollSend(channel, value): Int` — atomically place
/// `value` if the channel can accept it now. Returns `0` when the value was
/// handed to a parked receiver / a registered `onReceive` select / buffered,
/// `1` when the channel is closed (the send clause fails), or `2` when the
/// channel is full.
fn channelSelectPollSend(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 2) return .{ .err = .{ .Arity = "selectPollSend expects (channel, value)" } };
    const id = channelId(&ctx.args[0]) orelse return .{ .err = .{ .Type = "selectPollSend: bad channel" } };
    const value = ctx.args[1];

    const Outcome = union(enum) {
        HandToIter: struct { slot: i64, scope: Value },
        HandToReceiver: struct { slot: i64, value: Value, catching: bool, scope: Value },
        OfferSelects,
        Buffered,
        Closed,
        Full,
    };
    var outcome: Outcome = undefined;
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        const state = coro_reg.channels.getPtr(id) orelse return .{ .ok = Value.newInt(2) };
        if (state.closed) {
            outcome = .Closed;
        } else if (state.receive_iter_waiters.popFront()) |w| {
            try w.iter.asPtr().define(regAllocator(), "__pending__", value);
            try setIteratorNextState(w.iter, .value_ready);
            outcome = .{ .HandToIter = .{ .slot = w.slot, .scope = w.scope } };
        } else if (state.receive_waiters.popFront()) |w| {
            outcome = .{ .HandToReceiver = .{ .slot = w.slot, .value = value, .catching = w.catching, .scope = w.scope } };
        } else if (state.select_recv_waiters.len() > 0) {
            outcome = .OfferSelects;
        } else if (state.buffer.len() < state.capacity) {
            try state.buffer.pushBack(regAllocator(), value);
            outcome = .Buffered;
        } else {
            outcome = .Full;
        }
    }
    switch (outcome) {
        .HandToIter => |h| {
            resumeWaiterNormal(ctx, h.slot, .{ .Bool = true }, h.scope);
            return .{ .ok = Value.newInt(0) };
        },
        .HandToReceiver => |h| {
            const resume_val = if (h.catching) try channelResult(ctx, .success, h.value) else h.value;
            resumeWaiterNormal(ctx, h.slot, resume_val, h.scope);
            return .{ .ok = Value.newInt(0) };
        },
        .OfferSelects => {
            if (offerValueToSelectReceivers(ctx, id, ctx.args[0], value)) return .{ .ok = Value.newInt(0) };
            // No select took it — buffer or report full.
            coro_reg_mutex.lock();
            defer coro_reg_mutex.unlock();
            const state = coro_reg.channels.getPtr(id) orelse return .{ .ok = Value.newInt(2) };
            if (state.closed) return .{ .ok = Value.newInt(1) };
            if (state.buffer.len() < state.capacity) {
                try state.buffer.pushBack(regAllocator(), value);
                return .{ .ok = Value.newInt(0) };
            }
            return .{ .ok = Value.newInt(2) };
        },
        .Buffered => return .{ .ok = Value.newInt(0) },
        .Closed => return .{ .ok = Value.newInt(1) },
        .Full => return .{ .ok = Value.newInt(2) },
    }
}

fn channelIsClosedForSend(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "isClosedForSend expects a receiver" } };
    const recv = ctx.args[0];
    const id = channelId(&recv) orelse return .{ .err = .{ .Type = "isClosedForSend: bad receiver" } };
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    const closed = if (coro_reg.channels.getPtr(id)) |s| s.closed else true;
    return .{ .ok = .{ .Bool = closed } };
}

fn channelIsClosedForReceive(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "isClosedForReceive expects a receiver" } };
    const recv = ctx.args[0];
    const id = channelId(&recv) orelse return .{ .err = .{ .Type = "isClosedForReceive: bad receiver" } };
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    const drained_closed = if (coro_reg.channels.getPtr(id)) |s|
        (s.closed and s.buffer.isEmpty() and s.send_waiters.isEmpty())
    else
        true;
    return .{ .ok = .{ .Bool = drained_closed } };
}

fn channelIterator(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "Channel.iterator expects a receiver" } };
    const recv = ctx.args[0];
    const ch_id = channelId(&recv) orelse return .{ .err = .{ .Type = "Channel.iterator: bad receiver" } };
    const id = ctx.host.allocInstanceId();
    // The channel id is an opaque u64 stored bit-for-bit in a Long slot.
    const fields = [_]InstanceData.Field{
        .{ .name = "__channel_id__", .value = .{ .Long = @bitCast(ch_id) } },
        // Keep the channel handle so a parked `hasNext` can offer itself to a
        // registered `onSend` select (the offer needs the clause object).
        .{ .name = "__channel__", .value = recv },
        .{ .name = "__pending__", .value = .Null },
        .{ .name = "__next_state__", .value = Value.newInt(@intFromEnum(IteratorNextState.needs_has_next)) },
    };
    const inst = try ctx.host.newSynthInstance("kotlinx.coroutines.channels.KlioChannelIterator", id, &fields);
    return .{ .ok = inst };
}

const IteratorNextState = enum(i32) {
    needs_has_next = 0,
    value_ready = 1,
    closed_ready = 2,
};

fn setIteratorNextState(iter: ObjRef(InstanceData), state: IteratorNextState) std.mem.Allocator.Error!void {
    try iter.asPtr().define(regAllocator(), "__next_state__", Value.newInt(@intFromEnum(state)));
}

fn iteratorNextState(iter: ObjRef(InstanceData)) IteratorNextState {
    const value = iter.asPtr().get("__next_state__") orelse return .needs_has_next;
    const raw: i32 = switch (value) {
        .Int => |n| n,
        .Long => |n| @intCast(n),
        else => return .needs_has_next,
    };
    return std.enums.fromInt(IteratorNextState, raw) orelse .needs_has_next;
}

fn channelIterHasNext(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "hasNext expects a receiver" } };
    const recv = ctx.args[0];
    const iter_inst: ObjRef(InstanceData), const ch_id: u64 = switch (recv) {
        .Instance => |i| blk: {
            // The channel id was stored bit-for-bit; recover the opaque u64.
            const cid: u64 = if (i.asPtr().get("__channel_id__")) |v| switch (v) {
                .Long => |n| @bitCast(n),
                .Int => |n| @as(u64, @bitCast(@as(i64, n))),
                else => return .{ .err = .{ .Type = "hasNext: missing channel id" } },
            } else return .{ .err = .{ .Type = "hasNext: missing channel id" } };
            break :blk .{ i, cid };
        },
        else => return .{ .err = .{ .Type = "hasNext: bad receiver" } },
    };
    // Already have a cached pending value? Report true without touching
    // the channel.
    if (iter_inst.asPtr().get("__pending__")) |c| {
        if (c != .Null) {
            try setIteratorNextState(iter_inst, .value_ready);
            return .{ .ok = .{ .Bool = true } };
        }
    }
    // Try a synchronous pull. If the buffer holds a value, cache it and
    // return true; if the channel is drained-and-closed, return false;
    // otherwise queue an iterator-style waiter and suspend. The pull and
    // the waiter enqueue are ONE atomic section: a send arriving between
    // a failed pull and the enqueue would buffer its value past a waiter
    // it never sees, parking this iterator forever.
    const Outcome = union(enum) {
        Got: struct { value: Value, resumed: ?i64, resumed_scope: Value = .Unit },
        Closed: Value,
        NoState,
        ParkOnSlot: i64,
    };
    const park_scope = ctx.host.activeCoroScope() orelse Value.Unit;
    var outcome: Outcome = undefined;
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        if (coro_reg.channels.getPtr(ch_id)) |state| {
            if (state.buffer.popFront()) |v| {
                const resumed_sender = state.send_waiters.popFront();
                var resumed: ?i64 = null;
                var resumed_scope: Value = .Unit;
                if (resumed_sender) |sw| {
                    try state.buffer.pushBack(regAllocator(), sw.value);
                    resumed = sw.slot;
                    resumed_scope = sw.scope;
                }
                outcome = .{ .Got = .{ .value = v, .resumed = resumed, .resumed_scope = resumed_scope } };
            } else if (state.send_waiters.popFront()) |sw| {
                // Rendezvous: hand the parked sender's value to the iterator.
                outcome = .{ .Got = .{ .value = sw.value, .resumed = sw.slot, .resumed_scope = sw.scope } };
            } else if (state.closed) {
                outcome = .{ .Closed = state.close_cause };
            } else {
                const slot = allocKxcoSlot();
                try state.receive_iter_waiters.pushBack(regAllocator(), .{ .slot = slot, .iter = iter_inst, .scope = park_scope });
                outcome = .{ .ParkOnSlot = slot };
            }
        } else {
            outcome = .NoState;
        }
    }
    switch (outcome) {
        .Got => |g| {
            if (g.resumed) |slot| resumeWaiterNormal(ctx, slot, .Unit, g.resumed_scope);
            try iter_inst.asPtr().define(regAllocator(), "__pending__", g.value);
            try setIteratorNextState(iter_inst, .value_ready);
            return .{ .ok = .{ .Bool = true } };
        },
        .Closed => |cause| {
            if (cause != .Null) {
                return .{ .err = .{ .Thrown = try channelCloseException(ctx.allocator, cause, true) } };
            }
            try setIteratorNextState(iter_inst, .closed_ready);
            return .{ .ok = .{ .Bool = false } };
        },
        .NoState => {
            try setIteratorNextState(iter_inst, .closed_ready);
            return .{ .ok = .{ .Bool = false } };
        },
        .ParkOnSlot => |slot| {
            ctx.host.coroutineArmSlot(slot);
            if (iter_inst.asPtr().get("__channel__")) |chan| {
                armChannelCancel(ctx, chan, slot);
                // This iterator is now parked in `receive_iter_waiters`; a
                // registered `onSend` select can hand its value straight to it,
                // exactly as a plain parking `receive` offers to `onSend` selects.
                _ = offerSendToSelectSenders(ctx, ch_id, chan);
            }
            return .{ .err = .{ .Suspend = -1 } };
        },
    }
}

fn channelIterNext(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "next expects a receiver" } };
    const recv = ctx.args[0];
    const inst: ObjRef(InstanceData) = switch (recv) {
        .Instance => |i| i,
        else => return .{ .err = .{ .Type = "next: bad receiver" } },
    };
    switch (iteratorNextState(inst)) {
        .needs_has_next => return channelIllegalState(ctx, "`hasNext()` has not been invoked"),
        .value_ready => {
            const value = inst.asPtr().get("__pending__") orelse
                return channelIllegalState(ctx, "`hasNext()` has not produced an element");
            if (value == .Null) {
                return channelIllegalState(ctx, "`hasNext()` has not produced an element");
            }
            try inst.asPtr().define(regAllocator(), "__pending__", .Null);
            try setIteratorNextState(inst, .needs_has_next);
            return .{ .ok = value };
        },
        .closed_ready => try setIteratorNextState(inst, .needs_has_next),
    }
    return .{ .err = .{ .Thrown = .{ .Exception = .{
        .fqn = try runtime.strInit(ctx.allocator, "kotlin.NoSuchElementException"),
        .message = .from(try runtime.strInit(ctx.allocator, "ChannelIterator.next called before hasNext")),
        .cause = null,
    } } } };
}

fn channelIsEmpty(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "isEmpty expects a receiver" } };
    const recv = ctx.args[0];
    const id = channelId(&recv) orelse return .{ .err = .{ .Type = "isEmpty: bad receiver" } };
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    const empty = if (coro_reg.channels.getPtr(id)) |s|
        (!s.closed and s.buffer.isEmpty() and s.send_waiters.isEmpty())
    else
        false;
    return .{ .ok = .{ .Bool = empty } };
}

fn closedReceiveExc(allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
    return .{ .Exception = .{
        .fqn = try runtime.strInit(allocator, "kotlinx.coroutines.channels.ClosedReceiveChannelException"),
        .message = .from(try runtime.strInit(allocator, "Channel was closed")),
        .cause = null,
    } };
}

fn closedSendExc(allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
    return .{ .Exception = .{
        .fqn = try runtime.strInit(allocator, "kotlinx.coroutines.channels.ClosedSendChannelException"),
        .message = .from(try runtime.strInit(allocator, "Channel was closed")),
        .cause = null,
    } };
}

fn channelCloseException(allocator: std.mem.Allocator, cause: Value, receive: bool) std.mem.Allocator.Error!Value {
    if (cause != .Null) {
        cause.retain();
        return cause;
    }
    return if (receive) closedReceiveExc(allocator) else closedSendExc(allocator);
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

/// `__kxco_chanDiag(slot, cancelled)` — KLIO_CHAN_DIAG print from the
/// Kotlin arm handler: proves the handler ran and with what cause.
fn chanDiag(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (runtime.envOnce("KLIO_CHAN_DIAG") != null and ctx.args.len >= 2) {
        const slot: i64 = switch (ctx.args[0]) {
            .Long => |l| l,
            .Int => |i| @as(i64, i),
            else => -1,
        };
        const cancelled = ctx.args[1] == .Bool and ctx.args[1].Bool;
        std.debug.print("[chan] handler-invoked slot={d} cancelled={}\n", .{ slot, cancelled });
    }
    return .{ .ok = .Unit };
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

const CHANNEL_CLASS_FQNS = [_][]const u8{
    "kotlinx.coroutines.channels.KlioChannel",
    BUFFERED_CHANNEL_FQN,
    CONFLATED_CHANNEL_FQN,
};

const CHANNEL_MEMBER_BINDINGS = [_]struct { name: []const u8, f: runtime.StdlibFn }{
    .{ .name = "cancel", .f = channelCancel },
    .{ .name = "send", .f = channelSend },
    .{ .name = "trySend", .f = channelTrySend },
    .{ .name = "receive", .f = channelReceive },
    .{ .name = "receiveCatching", .f = channelReceiveCatching },
    .{ .name = "tryReceive", .f = channelTryReceive },
    .{ .name = "close", .f = channelClose },
    .{ .name = "isClosedForSend", .f = channelIsClosedForSend },
    .{ .name = "isClosedForReceive", .f = channelIsClosedForReceive },
    .{ .name = "isEmpty", .f = channelIsEmpty },
    .{ .name = "invokeOnClose", .f = channelInvokeOnClose },
    .{ .name = "iterator", .f = channelIterator },
};

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
    .{ .fqn = "kotlinx.coroutines.__kxco_chanDiag", .f = chanDiag },
    .{ .fqn = "kotlinx.coroutines.__kxco_systemProperty", .f = kxcoSystemProp },
    .{ .fqn = "kotlinx.coroutines.__kxco_resumeSlot", .f = resumeSlot },
    .{ .fqn = "kotlinx.coroutines.__kxco_chanCancelWaiter", .f = channelCancelWaiter },
    .{ .fqn = "kotlinx.coroutines.__kxco_chanBindWatcher", .f = channelBindWatcher },
    .{ .fqn = "kotlinx.coroutines.__kxco_chanBindHandle", .f = channelBindHandle },
    .{ .fqn = "kotlinx.coroutines.__kxco_chanResumeNow", .f = chanResumeNow },
    .{ .fqn = "kotlinx.coroutines.selects.__kxco_chanSelectAddReceiver", .f = channelSelectAddReceiver },
    .{ .fqn = "kotlinx.coroutines.selects.__kxco_chanSelectRemoveReceiver", .f = channelSelectRemoveReceiver },
    .{ .fqn = "kotlinx.coroutines.selects.__kxco_chanSelectAddSender", .f = channelSelectAddSender },
    .{ .fqn = "kotlinx.coroutines.selects.__kxco_chanSelectRemoveSender", .f = channelSelectRemoveSender },
    .{ .fqn = "kotlinx.coroutines.selects.__kxco_chanSelectPollReceive", .f = channelSelectPollReceive },
    .{ .fqn = "kotlinx.coroutines.selects.__kxco_chanSelectPollSend", .f = channelSelectPollSend },
    .{ .fqn = "kotlinx.coroutines.selects.__kxco_chanCloseCause", .f = channelCloseCause },
    .{ .fqn = "kotlinx.coroutines.__kxco_rbPump", .f = rbPump },
    .{ .fqn = "kotlinx.coroutines.internal.__kxco_reportUncaught", .f = reportUncaught },
    .{ .fqn = "kotlinx.coroutines.channels.Channel", .f = channelCreate },
    .{ .fqn = "kotlinx.coroutines.channels.KlioChannelIterator.hasNext", .f = channelIterHasNext },
    .{ .fqn = "kotlinx.coroutines.channels.KlioChannelIterator.next", .f = channelIterNext },
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
    inline for (CHANNEL_CLASS_FQNS) |class_fqn| {
        inline for (CHANNEL_MEMBER_BINDINGS) |entry| {
            try b.register(class_fqn ++ "." ++ entry.name, entry.f);
        }
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
    try testing.expectEqual(@as(usize, BINDINGS.len + CHANNEL_CLASS_FQNS.len * CHANNEL_MEMBER_BINDINGS.len), b.len());
    try testing.expect(b.resolve("kotlinx.coroutines.__kxco_delayMillis") != null);
    try testing.expect(b.resolve("kotlinx.coroutines.channels.Channel") != null);
    try testing.expect(b.resolve("kotlinx.coroutines.channels.KlioBufferedChannel.send") != null);
    try testing.expect(b.resolve("kotlinx.coroutines.channels.KlioConflatedBufferedChannel.receive") != null);
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

test "channel iterator next distinguishes unchecked, ready, and closed states" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var host = NoopHost.init(testing.allocator);
    defer host.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    // A new iterator rejects next() until hasNext establishes a result.
    const cls = try makeClassDef(a, "kotlinx.coroutines.channels.KlioChannelIterator");
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    try fields.append(a, .{ .name = "__pending__", .value = .Null });
    try fields.append(a, .{ .name = "__next_state__", .value = Value.newInt(@intFromEnum(IteratorNextState.needs_has_next)) });
    const inst = try ObjRef(InstanceData).init(a, .{
        .class = cls,
        .fields = fields,
        .outer = null,
        .identity = 7,
        .native_state = null,
    });
    const args = [_]Value{.{ .Instance = inst }};
    var ctx: CallCtx = .{ .args = &args, .out = cap.output(), .host = host.host(), .allocator = a };
    const unchecked = try channelIterNext(&ctx);
    try testing.expect(unchecked == .err and unchecked.err == .Thrown);
    try testing.expectEqualStrings("kotlin.IllegalStateException", unchecked.err.Thrown.Exception.fqn.asPtr().bytes);

    try inst.asPtr().define(a, "__pending__", Value.newInt(42));
    try setIteratorNextState(inst, .value_ready);
    const ready = try channelIterNext(&ctx);
    try testing.expect(ready == .ok and ready.ok.Int == 42);

    try setIteratorNextState(inst, .closed_ready);
    const closed = try channelIterNext(&ctx);
    try testing.expect(closed == .err and closed.err == .Thrown);
    try testing.expectEqualStrings("kotlin.NoSuchElementException", closed.err.Thrown.Exception.fqn.asPtr().bytes);
    const consumed = try channelIterNext(&ctx);
    try testing.expect(consumed == .err and consumed.err == .Thrown);
    try testing.expectEqualStrings("kotlin.IllegalStateException", consumed.err.Thrown.Exception.fqn.asPtr().bytes);
}

/// Build a `KlioChannel` Instance keyed on `id` and register a channel
/// state for it in the registry. The caller resets the registry.
fn makeChannel(a: std.mem.Allocator, id: u64, state: ChannelState) !Value {
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        try coro_reg.channels.put(regAllocator(), id, state);
    }
    const cls = try makeClassDef(a, "kotlinx.coroutines.channels.KlioChannel");
    const fields: std.ArrayList(InstanceData.Field) = .empty;
    const inst = try ObjRef(InstanceData).init(a, .{
        .class = cls,
        .fields = fields,
        .outer = null,
        .identity = id,
        .native_state = null,
    });
    return .{ .Instance = inst };
}

test "overflowOf reads the BufferOverflow ordinal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (.{
        .{ @as(i64, 0), ChannelState.Overflow.suspend_ },
        .{ @as(i64, 1), ChannelState.Overflow.drop_oldest },
        .{ @as(i64, 2), ChannelState.Overflow.drop_latest },
    }) |pair| {
        const cls = try makeClassDef(a, "kotlinx.coroutines.channels.BufferOverflow");
        var fields: std.ArrayList(InstanceData.Field) = .empty;
        try fields.append(a, .{ .name = "ordinal", .value = Value.newInt(pair[0]) });
        const inst = try ObjRef(InstanceData).init(a, .{
            .class = cls,
            .fields = fields,
            .outer = null,
            .identity = 1,
            .native_state = null,
        });
        const v = Value{ .Instance = inst };
        try testing.expectEqual(pair[1], overflowOf(&v));
    }
    // A non-instance argument defaults to suspend.
    const nil: Value = .Null;
    try testing.expectEqual(ChannelState.Overflow.suspend_, overflowOf(&nil));
}

test "channel factory rejects invalid capacity combinations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host = NoopHost.init(testing.allocator);
    defer host.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    {
        const args = [_]Value{Value.newInt(-3)};
        var ctx = makeCtx(&host, &cap, &args);
        const result = try channelCreate(&ctx);
        defer result.err.Thrown.release(testing.allocator);
        try testing.expect(result == .err and result.err == .Thrown);
        const fqn = result.err.Thrown.Exception.fqn.borrow();
        defer fqn.deinit();
        try testing.expectEqualStrings("kotlin.IllegalArgumentException", fqn.get().bytes);
    }

    const cls = try makeClassDef(a, "kotlinx.coroutines.channels.BufferOverflow");
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    try fields.append(a, .{ .name = "ordinal", .value = Value.newInt(1) });
    const drop_oldest = Value{ .Instance = try ObjRef(InstanceData).init(a, .{
        .class = cls,
        .fields = fields,
        .outer = null,
        .identity = 1,
        .native_state = null,
    }) };
    const args = [_]Value{ Value.newInt(CAP_CONFLATED), drop_oldest };
    var ctx = makeCtx(&host, &cap, &args);
    const result = try channelCreate(&ctx);
    defer result.err.Thrown.release(testing.allocator);
    try testing.expect(result == .err and result.err == .Thrown);
}

test "conflated channel keeps only the latest value" {
    defer resetRegistry();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host = NoopHost.init(testing.allocator);
    defer host.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    // Capacity-1 drop-oldest mirrors `Channel(CONFLATED)`.
    const recv = try makeChannel(a, 4242, ChannelState.init(1, .drop_oldest, false));
    inline for (.{ @as(i32, 10), @as(i32, 20), @as(i32, 30) }) |n| {
        const args = [_]Value{ recv, Value.newInt(n) };
        var ctx = makeCtx(&host, &cap, &args);
        const r = try channelTrySend(&ctx);
        try testing.expect(r == .ok);
    }
    // tryReceive returns 30 (NoopHost makes `channelResult` return the raw
    // payload, so the success value surfaces directly).
    {
        const args = [_]Value{recv};
        var ctx = makeCtx(&host, &cap, &args);
        const r = try channelTryReceive(&ctx);
        try testing.expectEqual(@as(i32, 30), r.ok.Int);
    }
    // Buffer now empty: tryReceive yields the failure payload (Unit here).
    {
        const args = [_]Value{recv};
        var ctx = makeCtx(&host, &cap, &args);
        const r = try channelTryReceive(&ctx);
        try testing.expect(r.ok == .Unit);
    }
}

test "buffered channel trySend fails when full; rendezvous trySend fails without a receiver" {
    defer resetRegistry();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host = NoopHost.init(testing.allocator);
    defer host.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    // Capacity-1 SUSPEND buffer: first trySend buffers, second is full.
    const buf = try makeChannel(a, 5151, ChannelState.init(1, .suspend_, false));
    {
        const args = [_]Value{ buf, Value.newInt(1) };
        var ctx = makeCtx(&host, &cap, &args);
        try testing.expect((try channelTrySend(&ctx)).ok == .Unit); // success payload
    }
    {
        const args = [_]Value{ buf, Value.newInt(2) };
        var ctx = makeCtx(&host, &cap, &args);
        // Full SUSPEND: failure payload (Unit under NoopHost).
        try testing.expect((try channelTrySend(&ctx)).ok == .Unit);
        // The buffer still holds exactly the first element.
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        try testing.expectEqual(@as(usize, 1), coro_reg.channels.getPtr(5151).?.buffer.len());
    }

    // Rendezvous: no buffer, no parked receiver -> trySend cannot complete.
    const rv = try makeChannel(a, 6262, ChannelState.init(0, .suspend_, true));
    {
        const args = [_]Value{ rv, Value.newInt(9) };
        var ctx = makeCtx(&host, &cap, &args);
        try testing.expect((try channelTrySend(&ctx)).ok == .Unit); // failure payload
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        try testing.expectEqual(@as(usize, 0), coro_reg.channels.getPtr(6262).?.buffer.len());
    }
}

test "native channel close preserves a queued send until receive" {
    defer resetRegistry();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host = NoopHost.init(testing.allocator);
    defer host.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    const recv = try makeChannel(a, 6363, ChannelState.init(0, .suspend_, true));
    {
        const args = [_]Value{ recv, Value.newInt(42) };
        var ctx = makeCtx(&host, &cap, &args);
        const sent = try channelSend(&ctx);
        try testing.expect(sent == .err and sent.err == .Suspend);
    }
    {
        const args = [_]Value{recv};
        var ctx = makeCtx(&host, &cap, &args);
        const closed = try channelClose(&ctx);
        try testing.expect(closed == .ok and closed.ok.Bool);
        try testing.expect(!(try channelIsClosedForReceive(&ctx)).ok.Bool);
        try testing.expect(!(try channelIsEmpty(&ctx)).ok.Bool);

        const received = try channelReceive(&ctx);
        try testing.expect(received == .ok and received.ok.Int == 42);
        try testing.expect((try channelIsClosedForReceive(&ctx)).ok.Bool);
        try testing.expect(!(try channelIsEmpty(&ctx)).ok.Bool);
    }
}

test "native channel cancellation discards buffered values and preserves its cause" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    defer resetRegistry();
    const a = arena.allocator();
    var host = NoopHost.init(testing.allocator);
    defer host.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    const recv = try makeChannel(a, 6464, ChannelState.init(1, .suspend_, false));
    {
        const args = [_]Value{ recv, Value.newInt(42) };
        var ctx = makeCtx(&host, &cap, &args);
        try testing.expect((try channelSend(&ctx)) == .ok);
    }
    const cause = Value{ .Exception = .{
        .fqn = try runtime.strInit(a, "test.Cancellation"),
        .message = .{},
        .cause = null,
    } };
    {
        const args = [_]Value{ recv, cause };
        var ctx = makeCtx(&host, &cap, &args);
        try testing.expect((try channelCancel(&ctx)) == .ok);
    }
    {
        const args = [_]Value{recv};
        var ctx = makeCtx(&host, &cap, &args);
        const received = try channelReceive(&ctx);
        try testing.expect(received == .err and received.err == .Thrown);
        defer if (runtime.reclaimEnabled()) received.err.Thrown.release(a);
        try testing.expectEqualStrings("test.Cancellation", received.err.Thrown.Exception.fqn.asPtr().bytes);
        try testing.expect(!(try channelIsEmpty(&ctx)).ok.Bool);
    }
}

test "native channel close is idempotent and accepts one close handler" {
    defer resetRegistry();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host = NoopHost.init(testing.allocator);
    defer host.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    const recv = try makeChannel(a, 7373, ChannelState.init(1, .suspend_, false));
    const handler: Value = .Unit;
    {
        const args = [_]Value{ recv, handler };
        var ctx = makeCtx(&host, &cap, &args);
        try testing.expect((try channelInvokeOnClose(&ctx)) == .ok);
    }
    {
        const args = [_]Value{ recv, handler };
        var ctx = makeCtx(&host, &cap, &args);
        const duplicate = try channelInvokeOnClose(&ctx);
        defer duplicate.err.Thrown.release(testing.allocator);
        try testing.expect(duplicate == .err and duplicate.err == .Thrown);
        try testing.expectEqualStrings(
            "kotlin.IllegalStateException",
            duplicate.err.Thrown.Exception.fqn.asPtr().bytes,
        );
    }

    // Remove the placeholder handler so NoopHost is not asked to invoke it;
    // the close result itself is the behavior under test here.
    coro_reg_mutex.lock();
    _ = coro_reg.channels.getPtr(7373).?.close_handlers.popFront();
    coro_reg_mutex.unlock();
    {
        const args = [_]Value{recv};
        var ctx = makeCtx(&host, &cap, &args);
        const first = try channelClose(&ctx);
        try testing.expect(first == .ok and first.ok == .Bool and first.ok.Bool);
        const second = try channelClose(&ctx);
        try testing.expect(second == .ok and second.ok == .Bool and !second.ok.Bool);
    }


    const cancelled = try makeChannel(a, 7474, ChannelState.init(1, .suspend_, false));
    {
        const args = [_]Value{cancelled};
        var ctx = makeCtx(&host, &cap, &args);
        const result = try channelCancel(&ctx);
        try testing.expect(result == .ok and result.ok.Bool);
    }
    coro_reg_mutex.lock();
    const cancel_cause = coro_reg.channels.getPtr(7474).?.close_cause;
    coro_reg_mutex.unlock();
    try testing.expect(cancel_cause == .Exception);
    try testing.expectEqualStrings(
        "kotlinx.coroutines.CancellationException",
        cancel_cause.Exception.fqn.asPtr().bytes,
    );
}

test "bad receiver arities and types" {
    var host = NoopHost.init(testing.allocator);
    defer host.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    // Missing receiver -> Arity.
    {
        var ctx = makeCtx(&host, &cap, &.{});
        const r = try channelSend(&ctx);
        try testing.expect(r == .err and r.err == .Arity);
    }
    // Non-instance receiver -> Type.
    {
        const args = [_]Value{.{ .Int = 1 }};
        var ctx = makeCtx(&host, &cap, &args);
        const r = try channelSend(&ctx);
        try testing.expect(r == .err and r.err == .Type);
    }
}

const ast = @import("ast");
const span = @import("span");
const Env = runtime.Env;
const ClassDef = runtime.ClassDef;

fn makeClassDef(allocator: std.mem.Allocator, name: []const u8) !ObjRef(ClassDef) {
    const cd: ClassDef = .{
        .name = name,
        .fqn = name,
        .annotation_names = &.{},
        .primary_params = &.{},
        .methods = &.{},
        .body_properties = &.{},
        .init_blocks = &.{},
        .init_block_property_positions = &.{},
        .is_data = false,
        .is_value = false,
        .is_object = false,
        .is_enum = false,
        .is_sealed = false,
        .supertype_names = &.{},
        .parent = null,
        .interfaces = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .parent_ctor_args = &.{},
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .is_anonymous = false,
        .secondary_ctors = &.{},
        .enum_entries = &.{},
        .companion = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
        .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(allocator, null),
        .nested_classes = &.{},
        .captured_env = try ObjRef(Env).init(allocator, Env.init(allocator)),
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(allocator, null),
    };
    return ObjRef(ClassDef).init(allocator, cd);
}

test {
    std.testing.refAllDecls(@This());
}
