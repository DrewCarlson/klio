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

    const IterWaiter = struct { slot: i64, iter: ObjRef(InstanceData) };
    const SendWaiter = struct { slot: i64, value: Value };
    const RecvWaiter = struct { slot: i64, catching: bool };
    const Overflow = enum { suspend_, drop_oldest, drop_latest };

    fn init(capacity: usize, overflow: Overflow, rendezvous: bool) ChannelState {
        return .{
            .buffer = Deque(Value).empty,
            .capacity = capacity,
            .overflow = overflow,
            .rendezvous = rendezvous,
            .closed = false,
            .receive_waiters = Deque(RecvWaiter).empty,
            .receive_iter_waiters = Deque(IterWaiter).empty,
            .send_waiters = Deque(SendWaiter).empty,
        };
    }

    fn deinit(self: *ChannelState, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        self.receive_waiters.deinit(allocator);
        self.receive_iter_waiters.deinit(allocator);
        self.send_waiters.deinit(allocator);
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
        for (st.send_waiters.items.items) |w| w.value.gcMark(m);
        for (st.receive_iter_waiters.items.items) |w| m.shade(&w.iter.cell.hdr);
    }
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
    if (capacity == CAP_CONFLATED) {
        // A conflated channel keeps only the latest value: capacity-1
        // drop-oldest, regardless of the requested overflow policy.
        effective_cap = 1;
        eff_overflow = .drop_oldest;
    } else if (capacity == CAP_UNLIMITED) {
        effective_cap = std.math.maxInt(usize);
    } else if (capacity == CAP_BUFFERED) {
        effective_cap = DEFAULT_BUFFER_CAPACITY;
    } else if (capacity == CAP_RENDEZVOUS) {
        if (overflow == .suspend_) {
            // A true rendezvous: no buffer, `send` parks until received.
            rendezvous = true;
            effective_cap = 0;
        } else {
            // RENDEZVOUS with a non-default overflow degrades to a
            // capacity-1 buffered channel (upstream `ConflatedBufferedChannel`).
            effective_cap = 1;
        }
    } else {
        effective_cap = @intCast(capacity);
    }

    const id = ctx.host.allocInstanceId();
    ensureCoroRegRoot();
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        try coro_reg.channels.put(regAllocator(), id, ChannelState.init(effective_cap, eff_overflow, rendezvous));
    }
    const inst = try ctx.host.newSynthInstance("kotlinx.coroutines.channels.KlioChannel", id, &.{});
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
        .closed => &.{Value.Null},
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

const ChannelSendOutcome = union(enum) {
    HandToReceiver: struct { slot: i64, value: Value, catching: bool },
    HandToIter: i64,
    Buffered,
    ParkOnSlot: i64,
};

fn channelSend(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "Channel.send expects a receiver" } };
    const recv = ctx.args[0];
    const value: Value = if (ctx.args.len > 1) ctx.args[1] else .Unit;
    const id = channelId(&recv) orelse return .{ .err = .{ .Type = "Channel.send: bad receiver" } };
    // If a receiver is parked, hand the value straight to it without
    // buffering. Otherwise the channel's capacity / overflow policy
    // decides: a rendezvous channel always parks the sender; a buffered
    // channel pushes while it has room; a full buffer either parks
    // (SUSPEND) or drops an element (DROP_OLDEST / DROP_LATEST). The whole
    // check-and-transition is one atomic section under the registry lock;
    // the host resume runs after release.
    var outcome: ChannelSendOutcome = undefined;
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        const state = coro_reg.channels.getPtr(id) orelse return .{ .err = .{ .Type = "Channel.send: missing state" } };
        if (state.closed) return .{ .err = .{ .Thrown = try closedSendExc(ctx.allocator) } };

        // Iterator waiters take priority — write the value into the iter's
        // `__pending__` field and resume with Bool(true).
        if (state.receive_iter_waiters.popFront()) |w| {
            try w.iter.asPtr().define(regAllocator(), "__pending__", value);
            outcome = .{ .HandToIter = w.slot };
        } else if (state.receive_waiters.popFront()) |w| {
            outcome = .{ .HandToReceiver = .{ .slot = w.slot, .value = value, .catching = w.catching } };
        } else if (state.rendezvous) {
            const slot = allocKxcoSlot();
            try state.send_waiters.pushBack(regAllocator(), .{ .slot = slot, .value = value });
            outcome = .{ .ParkOnSlot = slot };
        } else if (state.buffer.len() < state.capacity) {
            try state.buffer.pushBack(regAllocator(), value);
            outcome = .Buffered;
        } else switch (state.overflow) {
            .suspend_ => {
                const slot = allocKxcoSlot();
                try state.send_waiters.pushBack(regAllocator(), .{ .slot = slot, .value = value });
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

    switch (outcome) {
        .HandToReceiver => |h| {
            const resume_val = if (h.catching) try channelResult(ctx, .success, h.value) else h.value;
            ctx.host.coroutineResumeSlotValue(h.slot, resume_val);
            return .{ .ok = .Unit };
        },
        .HandToIter => |slot| {
            ctx.host.coroutineResumeSlotValue(slot, .{ .Bool = true });
            return .{ .ok = .Unit };
        },
        .Buffered => return .{ .ok = .Unit },
        .ParkOnSlot => |slot| {
            ctx.host.coroutineArmSlot(slot);
            return .{ .err = .{ .Suspend = -1 } };
        },
    }
}

const ChannelTrySendOutcome = union(enum) {
    HandToReceiver: struct { slot: i64, value: Value, catching: bool },
    Success,
    Full,
    Closed,
};

fn channelTrySend(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "Channel.trySend expects a receiver" } };
    const recv = ctx.args[0];
    const value: Value = if (ctx.args.len > 1) ctx.args[1] else .Unit;
    const id = channelId(&recv) orelse return .{ .err = .{ .Type = "Channel.trySend: bad receiver" } };

    var outcome: ChannelTrySendOutcome = undefined;
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        const state = coro_reg.channels.getPtr(id) orelse return .{ .err = .{ .Type = "Channel.trySend: missing state" } };
        if (state.closed) {
            outcome = .Closed;
        } else if (state.receive_iter_waiters.popFront()) |w| {
            try w.iter.asPtr().define(regAllocator(), "__pending__", value);
            outcome = .{ .HandToReceiver = .{ .slot = w.slot, .value = .{ .Bool = true }, .catching = false } };
        } else if (state.receive_waiters.popFront()) |w| {
            outcome = .{ .HandToReceiver = .{ .slot = w.slot, .value = value, .catching = w.catching } };
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

    const result: Value = switch (outcome) {
        .HandToReceiver => |h| blk: {
            const resume_val = if (h.catching) try channelResult(ctx, .success, h.value) else h.value;
            ctx.host.coroutineResumeSlotValue(h.slot, resume_val);
            break :blk try channelResult(ctx, .success, .Unit);
        },
        .Success => try channelResult(ctx, .success, .Unit),
        .Full => try channelResult(ctx, .failure, .Unit),
        .Closed => try channelResult(ctx, .closed, .Unit),
    };
    return .{ .ok = result };
}

const ChannelReceiveOutcome = union(enum) {
    Got: struct { value: Value, resumed: ?i64 },
    Closed,
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
            outcome = .{ .Got = .{ .value = v, .resumed = if (resumed_sender) |sw| sw.slot else null } };
        } else if (state.send_waiters.popFront()) |sw| {
            // A rendezvous channel never buffers: a parked sender's value
            // is handed directly to this receiver and the sender resumes.
            outcome = .{ .Got = .{ .value = sw.value, .resumed = sw.slot } };
        } else if (state.closed) {
            outcome = .Closed;
        } else {
            const slot = allocKxcoSlot();
            try state.receive_waiters.pushBack(regAllocator(), .{ .slot = slot, .catching = catching });
            outcome = .{ .ParkOnSlot = slot };
        }
    }

    switch (outcome) {
        .Got => |g| {
            if (g.resumed) |slot| ctx.host.coroutineResumeSlotValue(slot, .Unit);
            if (catching) return .{ .ok = try channelResult(ctx, .success, g.value) };
            return .{ .ok = g.value };
        },
        .Closed => {
            if (catching) return .{ .ok = try channelResult(ctx, .closed, .Unit) };
            return .{ .err = .{ .Thrown = try closedReceiveExc(ctx.allocator) } };
        },
        .ParkOnSlot => |slot| {
            ctx.host.coroutineArmSlot(slot);
            return .{ .err = .{ .Suspend = -1 } };
        },
    }
}

const ChannelTryReceiveOutcome = union(enum) {
    Got: Value,
    Empty,
    Closed,
};

fn channelTryReceive(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "Channel.tryReceive expects a receiver" } };
    const recv = ctx.args[0];
    const id = channelId(&recv) orelse return .{ .err = .{ .Type = "Channel.tryReceive: bad receiver" } };

    var outcome: ChannelTryReceiveOutcome = .Closed;
    var resumed_slot: ?i64 = null;
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        if (coro_reg.channels.getPtr(id)) |state| {
            if (state.buffer.popFront()) |v| {
                const resumed_sender = state.send_waiters.popFront();
                if (resumed_sender) |sw| {
                    try state.buffer.pushBack(regAllocator(), sw.value);
                    resumed_slot = sw.slot;
                }
                outcome = .{ .Got = v };
            } else if (state.send_waiters.popFront()) |sw| {
                // A rendezvous channel buffers nothing; a parked sender's
                // value is the element a `tryReceive` retrieves.
                resumed_slot = sw.slot;
                outcome = .{ .Got = sw.value };
            } else if (state.closed) {
                outcome = .Closed;
            } else {
                outcome = .Empty;
            }
        }
    }
    if (resumed_slot) |slot| ctx.host.coroutineResumeSlotValue(slot, .Unit);
    const result: Value = switch (outcome) {
        .Got => |v| try channelResult(ctx, .success, v),
        .Empty => try channelResult(ctx, .failure, .Unit),
        .Closed => try channelResult(ctx, .closed, .Unit),
    };
    return .{ .ok = result };
}

fn channelClose(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "Channel.close expects a receiver" } };
    const recv = ctx.args[0];
    const id = channelId(&recv) orelse return .{ .err = .{ .Type = "Channel.close: bad receiver" } };

    var recvs: []ChannelState.RecvWaiter = &.{};
    var iters: []ChannelState.IterWaiter = &.{};
    var sends: []ChannelState.SendWaiter = &.{};
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        if (coro_reg.channels.getPtr(id)) |state| {
            state.closed = true;
            recvs = try state.receive_waiters.drain(regAllocator());
            iters = try state.receive_iter_waiters.drain(regAllocator());
            sends = try state.send_waiters.drain(regAllocator());
        }
    }
    defer regAllocator().free(recvs);
    defer regAllocator().free(iters);
    defer regAllocator().free(sends);

    const exc = try closedReceiveExc(ctx.allocator);
    defer exc.release(ctx.allocator);
    for (recvs) |w| {
        // A parked `receiveCatching()` resumes with a closed result; a
        // parked `receive()` resumes with a `Result` failure that rethrows
        // the close cause at the suspension point.
        if (w.catching) {
            ctx.host.coroutineResumeSlotValue(w.slot, try channelResult(ctx, .closed, .Unit));
        } else {
            exc.retain();
            const failure = Value{ .Result = .{ .ok = false, .payload = try Value.boxRef(ctx.allocator, exc) } };
            ctx.host.coroutineResumeSlotValue(w.slot, failure);
        }
    }
    // Iterator-style waiters resume with `Bool(false)` so the
    // for-loop hasNext() returns false and the loop exits.
    for (iters) |w| {
        ctx.host.coroutineResumeSlotValue(w.slot, .{ .Bool = false });
    }
    const send_exc = try closedSendExc(ctx.allocator);
    defer send_exc.release(ctx.allocator);
    for (sends) |sw| {
        send_exc.retain();
        const failure = Value{ .Result = .{ .ok = false, .payload = try Value.boxRef(ctx.allocator, send_exc) } };
        ctx.host.coroutineResumeSlotValue(sw.slot, failure);
    }
    return .{ .ok = .{ .Bool = true } };
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
    const drained_closed = if (coro_reg.channels.getPtr(id)) |s| (s.closed and s.buffer.isEmpty()) else true;
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
        .{ .name = "__pending__", .value = .Null },
    };
    const inst = try ctx.host.newSynthInstance("kotlinx.coroutines.channels.KlioChannelIterator", id, &fields);
    return .{ .ok = inst };
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
        if (c != .Null) return .{ .ok = .{ .Bool = true } };
    }
    // Try a synchronous pull. If the buffer holds a value, cache it and
    // return true; if the channel is drained-and-closed, return false;
    // otherwise queue an iterator-style waiter and suspend. The pull and
    // the waiter enqueue are ONE atomic section: a send arriving between
    // a failed pull and the enqueue would buffer its value past a waiter
    // it never sees, parking this iterator forever.
    const Outcome = union(enum) {
        Got: struct { value: Value, resumed: ?i64 },
        Closed,
        NoState,
        ParkOnSlot: i64,
    };
    var outcome: Outcome = undefined;
    {
        coro_reg_mutex.lock();
        defer coro_reg_mutex.unlock();
        if (coro_reg.channels.getPtr(ch_id)) |state| {
            if (state.buffer.popFront()) |v| {
                const resumed_sender = state.send_waiters.popFront();
                var resumed: ?i64 = null;
                if (resumed_sender) |sw| {
                    try state.buffer.pushBack(regAllocator(), sw.value);
                    resumed = sw.slot;
                }
                outcome = .{ .Got = .{ .value = v, .resumed = resumed } };
            } else if (state.send_waiters.popFront()) |sw| {
                // Rendezvous: hand the parked sender's value to the iterator.
                outcome = .{ .Got = .{ .value = sw.value, .resumed = sw.slot } };
            } else if (state.closed) {
                outcome = .Closed;
            } else {
                const slot = allocKxcoSlot();
                try state.receive_iter_waiters.pushBack(regAllocator(), .{ .slot = slot, .iter = iter_inst });
                outcome = .{ .ParkOnSlot = slot };
            }
        } else {
            outcome = .NoState;
        }
    }
    switch (outcome) {
        .Got => |g| {
            if (g.resumed) |slot| ctx.host.coroutineResumeSlotValue(slot, .Unit);
            try iter_inst.asPtr().define(regAllocator(), "__pending__", g.value);
            return .{ .ok = .{ .Bool = true } };
        },
        .Closed, .NoState => return .{ .ok = .{ .Bool = false } },
        .ParkOnSlot => |slot| {
            ctx.host.coroutineArmSlot(slot);
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
    if (inst.asPtr().get("__pending__")) |v| {
        if (v != .Null) {
            try inst.asPtr().define(regAllocator(), "__pending__", .Null);
            return .{ .ok = v };
        }
    }
    return .{ .err = .{ .Thrown = .{ .Exception = .{
        .fqn = try runtime.strInit(ctx.allocator, "kotlin.NoSuchElementException"),
        .message = try runtime.strInit(ctx.allocator, "ChannelIterator.next called before hasNext"),
        .cause = null,
    } } } };
}

fn channelIsEmpty(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) return .{ .err = .{ .Arity = "isEmpty expects a receiver" } };
    const recv = ctx.args[0];
    const id = channelId(&recv) orelse return .{ .err = .{ .Type = "isEmpty: bad receiver" } };
    coro_reg_mutex.lock();
    defer coro_reg_mutex.unlock();
    const empty = if (coro_reg.channels.getPtr(id)) |s| s.buffer.isEmpty() else true;
    return .{ .ok = .{ .Bool = empty } };
}

fn closedReceiveExc(allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
    return .{ .Exception = .{
        .fqn = try runtime.strInit(allocator, "kotlinx.coroutines.channels.ClosedReceiveChannelException"),
        .message = try runtime.strInit(allocator, "Channel was closed"),
        .cause = null,
    } };
}

fn closedSendExc(allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
    return .{ .Exception = .{
        .fqn = try runtime.strInit(allocator, "kotlinx.coroutines.channels.ClosedSendChannelException"),
        .message = try runtime.strInit(allocator, "Channel was closed"),
        .cause = null,
    } };
}

/// `yield()` — cooperative reschedule: park with a zero-ms wakeup so
/// every other ready coroutine runs before this one continues.
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

/// The `(fqn, fn)` binding table — the faithful translation of the Rust
/// `host_bindings!` invocation.
const BINDINGS = [_]struct { fqn: []const u8, f: runtime.StdlibFn }{
    .{ .fqn = "kotlinx.coroutines.__kxco_delayMillis", .f = delayMillis },
    .{ .fqn = "kotlinx.coroutines.__kxco_currentTimeMillis", .f = currentTimeMillis },
    .{ .fqn = "kotlinx.coroutines.__kxco_tokenCreate", .f = tokenCreate },
    .{ .fqn = "kotlinx.coroutines.__kxco_tokenCancel", .f = tokenCancel },
    .{ .fqn = "kotlinx.coroutines.__kxco_tokenIsCancelled", .f = tokenIsCancelled },
    .{ .fqn = "kotlinx.coroutines.__kxco_schedulerEnqueue", .f = schedulerEnqueue },
    .{ .fqn = "kotlinx.coroutines.__kxco_schedulerDrainCount", .f = schedulerDrainCount },
    .{ .fqn = "kotlinx.coroutines.__kxco_spawn", .f = spawnLaunchBlock },
    .{ .fqn = "kotlinx.coroutines.__kxco_dispatch", .f = dispatchCoroutine },
    .{ .fqn = "kotlinx.coroutines.internal.synchronizedImpl", .f = synchronizedImpl },
    .{ .fqn = "kotlinx.coroutines.internal.__kxco_systemProp", .f = kxcoSystemProp },
    .{ .fqn = "kotlinx.coroutines.__kxco_dispatchIo", .f = dispatchCoroutineIo },
    .{ .fqn = "kotlinx.coroutines.__kxco_joinDispatched", .f = joinDispatched },
    .{ .fqn = "kotlinx.coroutines.__kxco_scheduleResume", .f = scheduleResume },
    .{ .fqn = "kotlinx.coroutines.__kxco_newSlot", .f = newSlot },
    .{ .fqn = "kotlinx.coroutines.__kxco_parkSlot", .f = parkSlot },
    .{ .fqn = "kotlinx.coroutines.__kxco_resumeSlot", .f = resumeSlot },
    .{ .fqn = "kotlinx.coroutines.__kxco_rbPump", .f = rbPump },
    .{ .fqn = "kotlinx.coroutines.internal.__kxco_reportUncaught", .f = reportUncaught },
    .{ .fqn = "kotlinx.coroutines.yield", .f = yieldNow },
    .{ .fqn = "kotlinx.coroutines.channels.KlioChannel.cancel", .f = channelClose },
    .{ .fqn = "kotlinx.coroutines.channels.Channel", .f = channelCreate },
    .{ .fqn = "kotlinx.coroutines.channels.KlioChannel.send", .f = channelSend },
    .{ .fqn = "kotlinx.coroutines.channels.KlioChannel.trySend", .f = channelTrySend },
    .{ .fqn = "kotlinx.coroutines.channels.KlioChannel.receive", .f = channelReceive },
    .{ .fqn = "kotlinx.coroutines.channels.KlioChannel.receiveCatching", .f = channelReceiveCatching },
    .{ .fqn = "kotlinx.coroutines.channels.KlioChannel.tryReceive", .f = channelTryReceive },
    .{ .fqn = "kotlinx.coroutines.channels.KlioChannel.close", .f = channelClose },
    .{ .fqn = "kotlinx.coroutines.channels.KlioChannel.isClosedForSend", .f = channelIsClosedForSend },
    .{ .fqn = "kotlinx.coroutines.channels.KlioChannel.isClosedForReceive", .f = channelIsClosedForReceive },
    .{ .fqn = "kotlinx.coroutines.channels.KlioChannel.isEmpty", .f = channelIsEmpty },
    .{ .fqn = "kotlinx.coroutines.channels.KlioChannel.iterator", .f = channelIterator },
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
    try testing.expectEqual(@as(usize, BINDINGS.len), b.len());
    try testing.expect(b.resolve("kotlinx.coroutines.__kxco_delayMillis") != null);
    try testing.expect(b.resolve("kotlinx.coroutines.channels.Channel") != null);
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

test "channel iter next without pending throws NoSuchElementException" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var host = NoopHost.init(testing.allocator);
    defer host.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    // A bare iterator instance with `__pending__` == Null.
    const cls = try makeClassDef(a, "kotlinx.coroutines.channels.KlioChannelIterator");
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    try fields.append(a, .{ .name = "__pending__", .value = .Null });
    const inst = try ObjRef(InstanceData).init(a, .{
        .class = cls,
        .fields = fields,
        .outer = null,
        .identity = 7,
        .native_state = null,
    });
    const args = [_]Value{.{ .Instance = inst }};
    var ctx: CallCtx = .{ .args = &args, .out = cap.output(), .host = host.host(), .allocator = a };
    const r = try channelIterNext(&ctx);
    try testing.expect(r == .err and r.err == .Thrown);
    try testing.expectEqualStrings("kotlin.NoSuchElementException", r.err.Thrown.Exception.fqn.asPtr().bytes);
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
