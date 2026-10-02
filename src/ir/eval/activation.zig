//! Activations and the suspend/resume engine: parking a frame, resuming a
//! continuation, and routing the resumed result.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");

const callStatsBumpId = @import("diag.zig").callStatsBumpId;
const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const BlockId = ir.BlockId;
const FuncId = ir.FuncId;
const Module = ir.Module;
const Reg = ir.Reg;

const parent = @import("../eval.zig");
const ev_diag = @import("diag.zig");
const ev_enter = @import("enter.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");
const ev_resolved = @import("resolved.zig");

const Activation = ev_flow.Activation;
const EvalError = ev_state.EvalError;
const EvalResult = ev_flow.EvalResult;
const EvalTls = ev_state.EvalTls;
const FlatCallReq = ev_flow.FlatCallReq;
const Frame = ev_frame.Frame;
const FrameSnapshot = ev_snapshot.FrameSnapshot;
const ArgArea = ev_frame.ArgArea;
const ResumeFrames = ev_state.ResumeFrames;
const SuspendState = ev_snapshot.SuspendState;
const TailSeg = ev_snapshot.TailSeg;
const TryFrame = ev_snapshot.TryFrame;
const try_alloc = ev_snapshot.try_alloc;
const boolThisTrap = ev_enter.boolThisTrap;
const dumpFnIfRequested = ev_enter.dumpFnIfRequested;
const dumpFrameChainForDiag = ev_diag.dumpFrameChainForDiag;
const errResult = ev_flow.errResult;
const frameBoundary = ev_enter.frameBoundary;
const freeSnapshotBuffers = ev_snapshot.freeSnapshotBuffers;
const funcFirstLoc = ev_diag.funcFirstLoc;
const gcInstallFrameRoot = ev_state.gcInstallFrameRoot;
const gcPopFrame = ev_state.gcPopFrame;
const gcPushFrame = ev_state.gcPushFrame;
const noteSuspendSnapshot = ev_snapshot.noteSuspendSnapshot;
const ok = ev_flow.ok;
const resumeTraceOn = ev_flow.resumeTraceOn;
const retainSnapshotValues = ev_snapshot.retainSnapshotValues;
const runFlatLoop = @import("exec.zig").runFlatLoop;
const snapshotRegisters = ev_snapshot.snapshotRegisters;

pub fn takeInFlightSuspend(allocator: Allocator) ?*SuspendState {
    _ = allocator;
    const st = ev_state.evtlsPtr().in_flight_suspend;
    ev_state.evtlsPtr().in_flight_suspend = null;
    return st;
}

/// Resume a parked coroutine: `resume_value` lands in the innermost frame's resume register,
/// and each frame's return value then feeds the next-outer frame's resume register.
pub fn resumeContinuation(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    state: *SuspendState,
    resume_value: Value,
    host: *H,
) Allocator.Error!EvalResult {
    var carry = resume_value;
    // `frames` is innermost-first, so resume the innermost and feed its value to the next-outer.
    // A drained list continues through the inherited `tails` segments, promoted one at a time.
    var frames = state.frames;
    var tails: ?*TailSeg = state.tails;
    // Ownership of both moves into this resume; the state must not tear them down.
    state.tails = null;
    // The state is live again, so it no longer qualifies for the minor-mark quiescent skip.
    state.gc_quiesced = false;
    defer frames.deinit(allocator);
    defer {
        var seg = tails;
        while (seg) |t| {
            const next = t.next;
            t.frames.deinit(allocator);
            allocator.destroy(t);
            seg = next;
        }
    }
    var head: usize = 0;
    // Root the not-yet-rebuilt outer snapshots for the resume's duration: they are out of the park
    // registry and not yet on the frame chain, so an inner frame's collection would sweep them.
    var resume_node = ResumeFrames{ .prev = ev_state.evtlsPtr().resuming, .frames = &frames, .head = &head, .tails = &tails };
    if (runtime.gc.gc_enabled) gcInstallFrameRoot();
    ev_state.evtlsPtr().resuming = &resume_node;
    defer ev_state.evtlsPtr().resuming = resume_node.prev;
    // The host's value as the resumed code reads it. Asked only now: making it can run Kotlin,
    // and a collection then must see the parked frames.
    if (comptime @hasDecl(H, "resumeValue")) carry = try host.resumeValue(allocator, carry);
    var first = true;
    var pending_throw_from_inner: ?Value = null;
    var pending_unwind_from_inner: ?EvalError = null;
    _ = &parent.resume_route;
    while (true) {
        if (head >= frames.items.len) {
            const seg = tails orelse break;
            tails = seg.next;
            frames.deinit(allocator);
            frames = seg.frames;
            head = seg.head;
            allocator.destroy(seg);
            continue;
        }
        const snap = frames.items[head];
        head += 1;
        // A compiled continuation resumes by calling it; a re-suspension has already pushed its next continuation onto the in-flight state.
        if (snap.native) |nr| {
            const produced = runtime.fromC(nr.call(nr.frame, runtime.toC(carry)));
            if (produced == .CoroutineSuspended) return .{ .err = .{ .Suspended = takeInFlightSuspend(allocator) orelse state } };
            carry = produced;
            first = false;
            continue;
        }
        // A live-parked flat activation resumes by reinstalling the intact frame: no rebuild, no copies.
        if (snap.live) |act| {
            var resume_throw: ?Value = null;
            var resume_unwind: ?EvalError = null;
            if (pending_throw_from_inner) |exc| {
                pending_throw_from_inner = null;
                resume_throw = exc;
            } else if (pending_unwind_from_inner) |e| {
                pending_unwind_from_inner = null;
                resume_unwind = e;
            } else if (first) {
                if (carry == .Result and !carry.Result.ok) {
                    resume_throw = carry.Result.payload.asPtrConst().*;
                }
            }
            first = false;
            if (resumeTraceOn()) {
                std.debug.print("[resume-frame] {s}#{d} LIVE at={d}:{d} throw={} via={s}\n", .{
                    act.frame.func.name,
                    act.frame.func.id.int(),
                    snap.block.int(),
                    snap.inst_idx,
                    resume_throw != null,
                    parent.resume_route,
                });
            }
            const r = try resumeLiveActivation(H, allocator, act, carry, snap.block, snap.inst_idx, snap.resume_reg, resume_throw, resume_unwind, host);
            switch (try routeResumedResult(allocator, r, &frames, head, &tails, &carry, &pending_throw_from_inner, &pending_unwind_from_inner)) {
                .next => continue,
                .done => |out| return out,
            }
        }
        // Resolve the `FuncId` against the module the frame was lowered into, a per-method sub-module for a local or anonymous class.
        const snap_module = snap.module;
        const m: *const Module = snap_module orelse module;
        const func = m.funcById(snap.func).?;
        // KLIO_RESUME_TRACE: name every frame a resume drive re-runs, with the route tag for the delivery path.
        if (resumeTraceOn()) {
            const loc = funcFirstLoc(func);
            std.debug.print("[resume-frame] {s}#{d} ({s}:{d}) at={d}:{d} throw={} pending={}/{}/{} caps={d} via={s} id={x}\n", .{
                func.name,
                func.id.int(),
                loc.path,
                loc.line,
                snap.block.int(),
                snap.inst_idx,
                pending_throw_from_inner != null,
                snap.pending_finally.rethrow != null,
                snap.pending_finally.return_value != null,
                snap.pending_finally.unwind != null,
                snap.captures.len,
                parent.resume_route,
                snap.regs.ptrIdentity(),
            });
        }
        // The frame is rebuilt as an activation, as a call the loop runs opens one: its next
        // suspension parks it live, so a coroutine's frame is copied out once, not at every one.
        const ev = ev_state.evtlsPtr();
        const area = try ArgArea.push(ev, snap.params, snap.captures);
        const act = actAlloc(ev, allocator) catch |e| {
            ev.vstack.restore(area.mark);
            return e;
        };
        act.frame.enter(ev, allocator, m, func, area.vals[0..snap.params.len], area.vals[snap.params.len..], area.mark) catch |e| {
            ev.vstack.restore(area.mark);
            actFree(ev, allocator, act);
            return e;
        };
        act.frame.closure = snap.closure;
        act.frame.cur_span = snap.span;
        act.frame.module_arc = snap_module;
        // The frame adopts the references the snapshot retained on suspend; its teardown balances them.
        act.frame.owns_params_caps = true;
        act.ret_idx = 0;
        act.ret_streams = null;
        act.ret_pc = 0;
        act.ret_code = 0;
        rebuildFrom(act, snap) catch |e| {
            act.frame.deinitIn(ev);
            actFree(ev, allocator, act);
            return e;
        };
        // Kotlin `Continuation.resumeWith(Result.failure(e))` means resume by throwing `e` at the
        // suspension point, so only the innermost frame sees it, as a throw and not as a value.
        var resume_throw: ?Value = null;
        var resume_unwind: ?EvalError = null;
        if (pending_throw_from_inner) |exc| {
            pending_throw_from_inner = null;
            resume_throw = exc;
        } else if (pending_unwind_from_inner) |e| {
            pending_unwind_from_inner = null;
            resume_unwind = e;
        } else if (first) {
            if (carry == .Result and !carry.Result.ok) {
                resume_throw = carry.Result.payload.asPtrConst().*;
            }
        }
        first = false;
        // Every value moved into the frame; free the snapshot's slice buffers, not its values.
        freeSnapshotBuffers(snap, allocator);
        const r = try resumeLiveActivation(H, allocator, act, carry, snap.block, snap.inst_idx, snap.resume_reg, resume_throw, resume_unwind, host);
        switch (try routeResumedResult(allocator, r, &frames, head, &tails, &carry, &pending_throw_from_inner, &pending_unwind_from_inner)) {
            .next => {},
            .done => |out| return out,
        }
    }
    return ok(carry);
}

/// `resumeContinuation` for a `state` holding one live-parked activation and nothing
/// inherited, as a generator's is after its first suspension, resumed with a value that is
/// no `Result`: the activation runs on with no resume list to keep or route, its result is
/// written to `out`, and `state` keeps its frame list's buffer, empty, for its caller to
/// reuse. False, having done nothing, for any other state or value. The result goes through
/// `out` rather than an optional, which a hot caller would copy in pieces.
pub fn resumeSingleLive(comptime H: type, allocator: Allocator, state: *SuspendState, resume_value: Value, host: *H, out: *EvalResult) Allocator.Error!bool {
    if (state.tails != null or state.frames.items.len != 1) return false;
    if (resume_value == .Result or resume_value == .CoroutineSuspended) return false;
    const snap = state.frames.items[0];
    const act = snap.live orelse return false;
    state.frames.clearRetainingCapacity();
    state.gc_quiesced = false;
    out.* = try resumeLiveActivation(H, allocator, act, resume_value, snap.block, snap.inst_idx, snap.resume_reg, null, null, host);
    // A ran frame's escape is re-tagged as `routeResumedResult` re-tags it.
    if (out.* == .err and out.err == .Unimplemented) out.* = errResult(.{ .CalleeFailed = out.err.Unimplemented });
    return true;
}

/// A snapshot's paused finally flow, registers and try frames, restored into the rebuilt
/// activation `act`.
fn rebuildFrom(act: *Activation, snap: FrameSnapshot) Allocator.Error!void {
    const frame = &act.frame;
    try frame.pfSet(snap.pending_finally);
    switch (snap.regs) {
        .sparse => |entries| {
            // The sparse snapshot recorded only live registers over a Unit base, which a no-fill frame must materialize first.
            frame.materializeRegs();
            for (entries) |entry| {
                if (entry.id < frame.regs.len) frame.regs[entry.id] = entry.value;
            }
        },
        .dense => |values| {
            frame.materializeRegs();
            if (values.len > frame.regs.len) try frame.write(Reg.from(@intCast(values.len - 1)), .Unit);
            @memcpy(frame.regs[0..values.len], values);
            @memset(frame.regs[values.len..], .Unit);
        },
    }
    try act.try_stack.appendSlice(try_alloc, snap.try_stack);
}

const ResumeRoute = union(enum) { next, done: EvalResult };

/// Route one resumed frame's result: a value carries outward, a re-suspension links the pending
/// outer snapshots as an inherited segment in O(1), a throw or non-local return re-enters the
/// next-outer frame for its restored try-stack, and a ran frame's escape re-tags as `CalleeFailed`.
fn routeResumedResult(
    allocator: Allocator,
    r: EvalResult,
    frames: *std.ArrayList(FrameSnapshot),
    head: usize,
    tails: *?*TailSeg,
    carry: *Value,
    pending_throw_from_inner: *?Value,
    pending_unwind_from_inner: *?EvalError,
) Allocator.Error!ResumeRoute {
    switch (r) {
        .ok => |v| carry.* = v,
        .err => |e| switch (e) {
            .Suspended => |inner| {
                if (head < frames.items.len) {
                    const seg = try allocator.create(TailSeg);
                    seg.* = .{ .frames = frames.*, .head = head, .next = tails.* };
                    frames.* = .empty;
                    tails.* = null;
                    // Append to the END of inner's chain: inner's own inherited segments are inner-more than these.
                    var slot: *?*TailSeg = &inner.tails;
                    while (slot.*) |t| slot = &t.next;
                    slot.* = seg;
                } else if (tails.* != null) {
                    // This list is drained: hand the inherited chain through without wrapping an empty segment around it.
                    var slot: *?*TailSeg = &inner.tails;
                    while (slot.*) |t| slot = &t.next;
                    slot.* = tails.*;
                    tails.* = null;
                }
                return .{ .done = errResult(.{ .Suspended = inner }) };
            },
            .Throw => |exc| {
                if (head >= frames.items.len and tails.* == null) {
                    return .{ .done = errResult(.{ .Throw = exc }) };
                }
                pending_throw_from_inner.* = exc;
            },
            .NonLocalReturn, .LabeledReturn => {
                if (head >= frames.items.len and tails.* == null) {
                    return .{ .done = errResult(e) };
                }
                pending_unwind_from_inner.* = e;
            },
            .Unimplemented => |msg| return .{ .done = errResult(.{ .CalleeFailed = msg }) },
            else => return .{ .done = errResult(e) },
        },
    }
    return .next;
}

/// Run or resume one activation's block loop. `resume_idx` is the instruction index within `cur`: 0 for a fresh call.
pub fn runFrame(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    frame: *Frame,
    try_stack: *std.ArrayList(TryFrame),
    cur: BlockId,
    resume_idx: usize,
    host: *H,
) Allocator.Error!EvalResult {
    // A Kotlin call the host makes re-enters here on the native stack, so a
    // stack down to its reserve, like a depth past the cap, raises a
    // catchable `StackOverflowError` before the native stack faults.
    const depth_ev = ev_state.evtlsPtr();
    if (depth_ev.eval_depth >= ev_state.evalDepthCap(depth_ev) or runtime.stackLow()) {
        dumpFrameChainForDiag();
        // Kotlin code catches it as `java.lang.StackOverflowError`.
        if (try ev_resolved.stackOverflowError(H, allocator, module, host)) |exc| return errResult(.{ .Throw = exc });
        return errResult(.{ .StackOverflow = "Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)" });
    }
    if (depth_ev.eval_depth == 0) _ = parent.threads_in_eval.fetchAdd(1, .monotonic);
    depth_ev.eval_depth += 1;
    defer {
        depth_ev.eval_depth -= 1;
        if (depth_ev.eval_depth == 0) _ = parent.threads_in_eval.fetchSub(1, .monotonic);
    }
    return runFrameInner(H, allocator, module, frame, try_stack, cur, resume_idx, null, null, host);
}

/// Snapshot `frame` at `block`:`inst_idx` and append it to `state`. The pending-finally payload's
/// ownership moves into the snapshot, and the frame's own teardown must then run.
pub fn snapshotSuspendedFrame(
    allocator: Allocator,
    frame: *Frame,
    try_stack: *std.ArrayList(TryFrame),
    block: BlockId,
    inst_idx: usize,
    resume_reg: ?Reg,
    state: *SuspendState,
) Allocator.Error!void {
    // A dense snapshot copies the whole register file and the collector traces the copy, so
    // every register not live where the frame stands is set to a value first.
    frame.materializeRegs();
    var lbuf: [16]u64 = undefined;
    const saved_regs = try snapshotRegisters(
        allocator,
        frame.func,
        block,
        inst_idx,
        resume_reg,
        frame.regs,
        try_stack.items.len == 0,
        frame.liveAt(block.int(), @intCast(inst_idx), &lbuf),
    );
    noteSuspendSnapshot(
        saved_regs.isDense(),
        frame.regs.len,
        saved_regs.savedLen(),
        frame.params.len,
        frame.captures.len,
    );
    const snap: FrameSnapshot = .{
        .func = frame.func.id,
        .module = frame.module_arc,
        .block = block,
        .inst_idx = inst_idx,
        .span = frame.cur_span,
        .regs = saved_regs,
        .params = blk: {
            if (runtime.gc.gc_enabled and runtime.gc.external_accounting) runtime.gc.noteExternalBytes((frame.params.len + frame.captures.len) * @sizeOf(Value));
            break :blk try allocator.dupe(Value, frame.params);
        },
        .captures = try allocator.dupe(Value, frame.captures),
        .try_stack = try allocator.dupe(TryFrame, try_stack.items),
        .pending_finally = frame.pf(),
        .is_lambda = frame.func.is_lambda,
        .resume_reg = resume_reg,
        .closure = frame.closure,
    };
    if (resumeTraceOn()) {
        std.debug.print("[suspend-frame] {s}#{d} at={d}:{d} pending={}/{}/{} caps={d}\n", .{
            frame.func.name,
            frame.func.id.int(),
            block.int(),
            inst_idx,
            frame.pf().rethrow != null,
            frame.pf().return_value != null,
            frame.pf().unwind != null,
            frame.captures.len,
        });
    }
    // The snapshot now holds the only references surviving this frame's teardown and the unwind above it.
    retainSnapshotValues(snap);
    try state.frames.append(allocator, snap);
    // Ownership of the pending control-flow payload moved into `snap`; teardown must not release it.
    frame.pfForget();
}

/// Per-thread activation freelist, pooled only under the tracing GC. Entries are inert storage holding no Values.
pub const ACT_POOL_MAX = 128;

inline fn actPoolOn() bool {
    return !runtime.reclaimEnabled() and runtime.gc.gc_enabled;
}

/// An activation whose try stack is empty: a pooled one keeps its try stack's buffer, a fresh one
/// has none.
fn actAlloc(ev: *EvalTls, allocator: Allocator) Allocator.Error!*Activation {
    const act = if (actPoolOn()) blk: {
        if (ev.act_pool_len > 0) {
            ev.act_pool_len -= 1;
            return ev.act_pool[ev.act_pool_len];
        }
        const fresh = try std.heap.c_allocator.create(Activation);
        fresh.frame.heap = &.{};
        fresh.frame.pending = null;
        break :blk fresh;
    } else try allocator.create(Activation);
    act.try_stack = .empty;
    return act;
}

/// Back to the pool with its try stack emptied, its buffer kept; one the pool has no room for,
/// or any under the refcount backend, is destroyed with its try stack.
pub fn actFree(ev: *EvalTls, allocator: Allocator, act: *Activation) void {
    if (actPoolOn()) {
        if (ev.act_pool_len < ACT_POOL_MAX) {
            act.try_stack.clearRetainingCapacity();
            // A pooled frame is its pool's thread's (`Frame.enterPooledWindow`).
            act.frame.tls = ev;
            ev.act_pool[ev.act_pool_len] = act;
            ev.act_pool_len += 1;
            return;
        }
        act.try_stack.deinit(try_alloc);
        std.heap.c_allocator.destroy(act);
        return;
    }
    act.try_stack.deinit(try_alloc);
    allocator.destroy(act);
}

/// `openActivation` for a call the stream loop runs in a module lowered from sema, with the run's
/// reclaim flag known where it is compiled. Under the tracing collector the activation comes off
/// this thread's pool and nothing checks the flag.
pub inline fn openStreamActivation(
    ev: *EvalTls,
    allocator: Allocator,
    module: *const Module,
    func: *const ir.Func,
    params: []const Value,
    captures: []const Value,
    area: ?ev_state.VsMark,
    closure: ?runtime.IrClosureRef,
    owning: ?*const Module,
    dst: Reg,
    fill: ev_frame.Fill,
    comptime reclaim: bool,
) Allocator.Error!*Activation {
    if (reclaim or parent.call_hooks_on or !runtime.gc.gc_enabled) return openActivation(ev, allocator, module, .{
        .func = func,
        .run_module = module,
        .owning = owning,
        .params = params,
        .captures = captures,
        .area = area,
        .closure = closure,
        .dst = dst,
    });
    const act: *Activation = if (ev.act_pool_len > 0) blk: {
        ev.act_pool_len -= 1;
        break :blk ev.act_pool[ev.act_pool_len];
    } else blk: {
        const fresh = try std.heap.c_allocator.create(Activation);
        // A pooled frame's are always clear, the pool's openers rely on it, and an enter that
        // fails before setting them pools this one as it is.
        fresh.frame.heap = &.{};
        fresh.frame.pending = null;
        fresh.try_stack = .empty;
        break :blk fresh;
    };
    errdefer actFree(ev, allocator, act);
    try act.frame.enterStream(ev, allocator, module, func, params, captures, area, fill, false);
    act.frame.closure = closure;
    act.frame.module_arc = owning;
    act.try_stack.clearRetainingCapacity();
    act.ret_dst = dst;
    gcPushFrame(&act.frame);
    return act;
}

/// `teardownActivation` for an activation the stream loop closes on a return.
pub inline fn closeStreamActivation(ev: *EvalTls, allocator: Allocator, act: *Activation, comptime reclaim: bool) void {
    if (reclaim or parent.call_hooks_on or !runtime.gc.gc_enabled) {
        teardownActivation(allocator, act);
        actFree(ev, allocator, act);
        return;
    }
    gcPopFrame(&act.frame);
    act.frame.deinitStream(ev, false);
    if (ev.act_pool_len < ACT_POOL_MAX) {
        act.try_stack.clearRetainingCapacity();
        ev.act_pool[ev.act_pool_len] = act;
        ev.act_pool_len += 1;
    } else {
        act.try_stack.deinit(try_alloc);
        std.heap.c_allocator.destroy(act);
    }
}

/// Open a flat activation for a direct interpreted call: the entry sequence `evalClosure` performs recursively.
pub fn openActivation(ev: *EvalTls, allocator: Allocator, caller_module: *const Module, req: FlatCallReq) Allocator.Error!*Activation {
    const module = req.run_module orelse caller_module;
    // A module lowered from sema passes arguments as sema typed and
    // converted them.
    if (module.resolved == null) {
        boolThisTrap(req.func, req.params);
        dumpFnIfRequested(req.func);
    }
    if (parent.call_hooks_on) callStatsBumpId(req.func.fqn, req.func.id.int(), module);
    const act = try actAlloc(ev, allocator);
    errdefer actFree(ev, allocator, act);
    try act.frame.enter(ev, allocator, module, req.func, req.params, req.captures, req.area);
    act.frame.closure = req.closure;
    act.frame.module_arc = req.owning;
    act.ret_idx = 0;
    act.ret_dst = req.dst;
    act.ret_streams = null;
    act.ret_pc = 0;
    act.ret_code = 0;
    gcPushFrame(&act.frame);
    return act;
}

/// Tear down a flat activation: `evalClosure`'s exit defers in LIFO order. Its try stack goes with
/// the activation, in `actFree`.
pub fn teardownActivation(allocator: Allocator, act: *Activation) void {
    _ = allocator;
    gcPopFrame(&act.frame);
    // The activation just ran on this thread, so its frame's state is the running thread's.
    act.frame.deinitIn(act.frame.tls);
}

/// Park a flat activation live: take it off the frame chain and the value stack, then hand the
/// activation to the suspend state, which owns it until resume or drop.
pub fn liveParkActivation(
    allocator: Allocator,
    act: *Activation,
    block: BlockId,
    inst_idx: usize,
    resume_reg: ?Reg,
    state: *SuspendState,
) Allocator.Error!void {
    gcPopFrame(&act.frame);
    // The thread goes on using the stack slots the frame held, so what it keeps moves with it.
    try act.frame.leaveStack(act.frame.tls);
    if (resumeTraceOn()) {
        std.debug.print("[suspend-frame] {s}#{d} at={d}:{d} LIVE caps={d}\n", .{
            act.frame.func.name,
            act.frame.func.id.int(),
            block.int(),
            inst_idx,
            act.frame.captures.len,
        });
    }
    try state.frames.append(allocator, .{
        .live = act,
        .func = act.frame.func.id,
        .module = act.frame.module_arc,
        .block = block,
        .inst_idx = inst_idx,
        .regs = .{ .sparse = &.{} },
        .params = &.{},
        .captures = &.{},
        .try_stack = &.{},
        .pending_finally = .{},
        .is_lambda = act.frame.func.is_lambda,
        .resume_reg = resume_reg,
        .closure = act.frame.closure,
    });
}

/// Destroy a live-parked activation dropped without a resume. The frame owns its register references; params and captures are borrows.
pub fn destroyParkedActivation(allocator: Allocator, act: *Activation) void {
    act.frame.deinit();
    actFree(ev_state.evtlsPtr(), allocator, act);
}

/// Reinstall a live-parked activation and run it on. A suspension is re-parked by the driver; a completion is torn down here.
fn resumeLiveActivation(
    comptime H: type,
    allocator: Allocator,
    act: *Activation,
    carry: Value,
    block: BlockId,
    inst_idx: usize,
    resume_reg: ?Reg,
    resume_throw: ?Value,
    resume_unwind: ?EvalError,
    host: *H,
) Allocator.Error!EvalResult {
    // A live-parked activation may resume on a different worker thread than the one that parked it,
    // so rebind the frame to the resuming thread's eval TLS before the parked pointer is used.
    act.frame.tls = ev_state.evtlsPtr();
    gcPushFrame(&act.frame);
    if (resume_throw == null) {
        if (resume_reg) |r| try act.frame.write(r, carry);
    }
    const res = try runFlatLoop(H, allocator, &act.frame, &act.try_stack, block, inst_idx, resume_throw, resume_unwind, act, host);
    if (res == .err and res.err == .Suspended) return res;
    const out = frameBoundary(act.frame.func, res);
    teardownActivation(allocator, act);
    actFree(ev_state.evtlsPtr(), allocator, act);
    return out;
}

/// Discard a flat call request unrun: pop the argument area it pushed (its values are borrows).
pub fn discardFlatReq(ev: *EvalTls, req: FlatCallReq) void {
    if (req.area) |m| ev.vstack.restore(m);
}

/// The flat call driver: a direct interpreted call the executor surfaces becomes a new heap
/// activation in this same loop rather than a native recursion, with control flow routed
/// through the executor's resume machinery so semantics match the recursive path.
fn runFrameInner(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    frame: *Frame,
    try_stack: *std.ArrayList(TryFrame),
    cur_in: BlockId,
    resume_idx_in: usize,
    resume_throw_in: ?Value,
    resume_unwind_in: ?EvalError,
    host: *H,
) Allocator.Error!EvalResult {
    _ = module;
    return runFlatLoop(H, allocator, frame, try_stack, cur_in, resume_idx_in, resume_throw_in, resume_unwind_in, null, host);
}
