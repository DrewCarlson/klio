//! Activations and the suspend/resume engine: parking a frame, resuming a
//! continuation, and routing the resumed result.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const jit_loop = @import("../jit_loop.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const BlockId = ir.BlockId;
const FuncId = ir.FuncId;
const Module = ir.Module;
const Reg = ir.Reg;

const parent = @import("../eval.zig");
const ev_chain = @import("chain.zig");
const ev_diag = @import("diag.zig");
const ev_enter = @import("enter.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_loop = @import("loop.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");

const Activation = ev_flow.Activation;
const EnclosingEntry = ev_state.EnclosingEntry;
const EvalError = ev_state.EvalError;
const EvalResult = ev_flow.EvalResult;
const EvalTls = ev_state.EvalTls;
const FlatCallReq = ev_flow.FlatCallReq;
const Frame = ev_frame.Frame;
const FrameSnapshot = ev_snapshot.FrameSnapshot;
const ResumeFrames = ev_state.ResumeFrames;
const SuspendState = ev_snapshot.SuspendState;
const TailSeg = ev_snapshot.TailSeg;
const TryFrame = ev_snapshot.TryFrame;
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
const maxEvalDepth = ev_chain.maxEvalDepth;
const noteSuspendSnapshot = ev_snapshot.noteSuspendSnapshot;
const ok = ev_flow.ok;
const popEnclosing = ev_chain.popEnclosing;
const regsAlloc = ev_state.regsAlloc;
const resumeTraceOn = ev_flow.resumeTraceOn;
const retainSnapshotValues = ev_snapshot.retainSnapshotValues;
const runFlatLoop = ev_loop.runFlatLoop;
const snapshotRegisters = ev_snapshot.snapshotRegisters;
const traceEnclosingEntries = ev_chain.traceEnclosingEntries;

/// Resume a parked coroutine. `resume_value` is written into the
/// innermost frame's resume register, then that frame runs to
/// completion (or re-suspends). When it returns, its value feeds the
/// next-outer frame's resume register, and so on up the stack.
/// Start or extend the suspension a compiled body is building. Called by the
/// native runtime as each emitted frame unwinds, innermost first, which is the
/// order the driver replays them in.
pub fn pushNativePark(
    allocator: Allocator,
    call: *const fn (?*anyopaque, runtime.CValue) callconv(.c) runtime.CValue,
    frame: ?*anyopaque,
    wake_in_millis: i64,
) Allocator.Error!void {
    const state = ev_state.evtls.in_flight_suspend orelse blk: {
        const st = try allocator.create(SuspendState);
        st.* = .{ .token = 0, .frames = .empty, .wake_in_millis = wake_in_millis, .pending_resume_reg = null };
        ev_state.evtls.in_flight_suspend = st;
        break :blk st;
    };
    if (wake_in_millis != 0) state.wake_in_millis = wake_in_millis;
    try state.frames.append(allocator, .{
        .func = FuncId.from(0),
        .module = null,
        .block = BlockId.from(0),
        .inst_idx = 0,
        .regs = .{ .dense = &.{} },
        .params = &.{},
        .captures = &.{},
        .enclosing_this = &.{},
        .try_stack = &.{},
        .is_lambda = false,
        .resume_reg = null,
        .native = .{ .call = call, .frame = frame },
    });
}

/// Take the suspension a compiled body left behind, if any.
pub fn takeInFlightSuspend(allocator: Allocator) ?*SuspendState {
    _ = allocator;
    const st = ev_state.evtls.in_flight_suspend;
    ev_state.evtls.in_flight_suspend = null;
    return st;
}

/// Replay a suspension whose frames are ALL compiled continuations. It needs no
/// host: there is no frame to rebuild, no module to resolve a FuncId against,
/// and no interpreted body to re-enter — each entry is a call. A compiled
/// program's suspensions are only ever this shape, so it drives the shared
/// scheduler without instantiating the evaluator against a stub host.
pub fn resumeNativeContinuation(
    allocator: Allocator,
    state: *SuspendState,
    resume_value: Value,
) Allocator.Error!EvalResult {
    var carry = resume_value;
    var frames = state.frames;
    state.frames = .empty;
    defer frames.deinit(allocator);
    state.gc_quiesced = false;
    for (frames.items, 0..) |snap, i| {
        const nr = snap.native orelse return errResult(.{ .Type = "interpreted frame in a compiled suspension" });
        const produced = runtime.fromC(nr.call(nr.frame, runtime.toC(carry)));
        if (produced == .CoroutineSuspended) {
            const st = takeInFlightSuspend(allocator) orelse
                return errResult(.{ .Type = "compiled body suspended without a continuation" });
            // The frames OUTSIDE this one have not run yet: they are still
            // waiting on the value it will eventually produce, so they belong
            // to the new suspension, outermost last. Dropping them stranded
            // every caller of a function that suspends twice.
            for (frames.items[i + 1 ..]) |outer| try st.frames.append(allocator, outer);
            return errResult(.{ .Suspended = st });
        }
        carry = produced;
    }
    return ok(carry);
}

pub fn resumeContinuation(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    state: *SuspendState,
    resume_value: Value,
    host: *H,
) Allocator.Error!EvalResult {
    var carry = resume_value;
    // The replay activates and deactivates a rebuilt frame per snapshot;
    // the per-frame prev-chain captures are only coherent while the replay
    // runs, and a deactivation cascade could leave the thread's active
    // chain pointing at a rebuilt frame's list AFTER that frame was torn
    // down — the next fresh call on this thread then merged its enclosing
    // chain from freed memory (the cross-thread yield GPF). Pin the
    // pre-replay chain and restore it on every exit.
    const saved_chain = ev_state.evtls.active_chain;
    const saved_chain_base = ev_state.evtls.active_chain_base;
    defer {
        ev_state.evtls.active_chain = saved_chain;
        ev_state.evtls.active_chain_base = saved_chain_base;
    }
    // `frames` is innermost-first (the deepest activation snapshots
    // itself first as `Suspended` unwinds). Resume the innermost, then
    // feed its return value to the next-outer frame, and so on. When the
    // fresh list is drained, consumption continues through the inherited
    // `tails` segments (see `TailSeg`) — one segment at a time, promoting
    // each into `frames`/`head` so the loop and the GC root see one shape.
    var frames = state.frames;
    var tails: ?*TailSeg = state.tails;
    // Ownership of both moves into this resume; the state must not tear
    // them down (or double-free segments a re-suspend hands to the inner
    // continuation).
    state.tails = null;
    // The state is live again: resume writes carry values into its frames,
    // so it no longer qualifies for the minor-mark quiescent skip.
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
    // Root the not-yet-rebuilt outer snapshots (`frames.items[head..]` and
    // the unconsumed tail segments) for the duration of the resume: they are
    // out of the park registry and not yet on the frame chain, so an inner
    // frame's collection would otherwise sweep them.
    var resume_node = ResumeFrames{ .prev = ev_state.evtls.resuming, .frames = &frames, .head = &head, .tails = &tails };
    if (runtime.gc.gc_enabled) {
        gcInstallFrameRoot();
        ev_state.evtls.resuming = &resume_node;
    }
    defer if (runtime.gc.gc_enabled) {
        ev_state.evtls.resuming = resume_node.prev;
    };
    var first = true;
    var pending_throw_from_inner: ?Value = null;
    var pending_unwind_from_inner: ?EvalError = null;
    _ = &parent.resume_route;
    while (true) {
        if (head >= frames.items.len) {
            // Promote the next inherited segment.
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
        // A COMPILED continuation resumes by calling it: there is no frame to
        // rebuild, because the emitted body keeps its own on the heap. It
        // answers with the result, or suspends again — in which case it has
        // already pushed its next continuation onto the in-flight state, which
        // the caller parks exactly as it parks an interpreted one.
        if (snap.native) |nr| {
            const produced = runtime.fromC(nr.call(nr.frame, runtime.toC(carry)));
            if (produced == .CoroutineSuspended) return .{ .err = .{ .Suspended = takeInFlightSuspend(allocator) orelse state } };
            carry = produced;
            first = false;
            continue;
        }
        // A live-parked flat activation resumes by reinstalling the intact
        // frame — no rebuild, no copies. Its result routes exactly like a
        // rebuilt frame's.
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
                    resume_throw = carry.Result.payload.asPtr().*;
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
        // Resolve the frame's `FuncId` against the module it was lowered
        // into — a per-method sub-module for an anon-object / local /
        // nested class, the passed-in (main) module otherwise.
        const snap_module = snap.module;
        const m: *const Module = snap_module orelse module;
        const func = m.funcById(snap.func).?;
        // KLIO_RESUME_TRACE: name every frame a resume drive re-runs — the
        // instrument that finds a tail executing twice in one unwind. The
        // route tag says which delivery path drove it (set by the host's
        // resumeRaw call sites).
        if (resumeTraceOn()) {
            const loc = funcFirstLoc(func);
            std.debug.print("[resume-frame] {s}#{d} ({s}:{d}) at={d}:{d} throw={} pending={}/{}/{} caps={d} enc={d} via={s} id={x}\n", .{
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
                snap.enclosing_this.len,
                parent.resume_route,
                snap.regs.ptrIdentity(),
            });
            traceEnclosingEntries("resume-enclosing", snap.enclosing_this);
        }
        var params: std.ArrayList(Value) = .empty;
        try params.appendSlice(allocator, snap.params);
        var caps: std.ArrayList(Value) = .empty;
        try caps.appendSlice(allocator, snap.captures);
        var frame = try Frame.newWithCaptures(&ev_state.evtls, allocator, m, func, params, caps);
        frame.closure_id = snap.closure_id;
        frame.pending_finally = snap.pending_finally;
        defer frame.deinit();
        gcPushFrame(&frame);
        defer gcPopFrame(&frame);
        frame.module_arc = snap_module;
        // This frame adopts the references the snapshot retained on suspend:
        // its params/captures (and regs, always owned) are released by its
        // teardown, balancing the suspend-time retain.
        frame.owns_params_caps = true;
        // Restore the frame's enclosing-`this` chain verbatim so implicit
        // receivers resolved before the park resolve identically after it.
        try frame.activateChainFrom(snap.enclosing_this);
        defer frame.deactivateChain();
        switch (snap.regs) {
            .sparse => |entries| {
                // The sparse snapshot recorded only live registers over a
                // Unit base; a no-fill frame must materialize that base
                // before the entries land on it.
                frame.materializeRegs();
                for (entries) |entry| {
                    if (entry.id < frame.regs.items.len) frame.regs.items[entry.id] = entry.value;
                }
            },
            .dense => |values| {
                frame.regs.clearRetainingCapacity();
                try frame.regs.appendSlice(regsAlloc(allocator), values);
                frame.wmask.setAll();
            },
        }
        // Kotlin `Continuation.resumeWith(Result.failure(e))` means
        // "resume by throwing `e` at the suspension point". Only the
        // innermost (suspending) frame sees the raw failure Result;
        // route it as a throw there instead of delivering it as the
        // suspending call's value, so a cancellation preempts a parked
        // `delay`/acquire rather than letting it complete.
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
                resume_throw = carry.Result.payload.asPtr().*;
            }
        }
        first = false;
        if (resume_throw == null) {
            if (snap.resume_reg) |r| {
                try frame.write(r, carry);
            }
        }
        var try_stack: std.ArrayList(TryFrame) = .empty;
        defer try_stack.deinit(allocator);
        try try_stack.appendSlice(allocator, snap.try_stack);
        // Everything the snapshot held is now copied into frame-owned buffers
        // (regs/params/captures/chain/try-stack); the frame owns the value
        // references (released by its teardown). Free the snapshot's own slice
        // buffers — but not its values, which moved into the frame.
        freeSnapshotBuffers(snap, allocator);
        const r = try runFrameInner(
            H,
            allocator,
            m,
            &frame,
            &try_stack,
            snap.block,
            snap.inst_idx,
            resume_throw,
            resume_unwind,
            host,
        );
        switch (try routeResumedResult(allocator, r, &frames, head, &tails, &carry, &pending_throw_from_inner, &pending_unwind_from_inner)) {
            .next => {},
            .done => |out| return out,
        }
    }
    return ok(carry);
}

const ResumeRoute = union(enum) { next, done: EvalResult };

/// Route one resumed frame's result within `resumeContinuation`'s drive
/// loop: a value carries outward; a re-suspension links the still-pending
/// outer snapshots as an inherited segment in O(1) (copying them made deep
/// recursion quadratic in the parked depth); a throw / non-local return
/// re-enters the next-outer frame so its restored try-stack (and label
/// match) can take it; a resolution-class failure of a RAN frame re-tags as
/// `CalleeFailed` so no walker retries it.
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
                    // Append to the END of inner's (short) existing chain:
                    // inner's own inherited segments are deeper (inner-more)
                    // than ours.
                    var slot: *?*TailSeg = &inner.tails;
                    while (slot.*) |t| slot = &t.next;
                    slot.* = seg;
                } else if (tails.* != null) {
                    // This list is drained: hand the inherited chain through
                    // WITHOUT wrapping an empty segment around it — every
                    // park/resume cycle of a suspending loop otherwise grew
                    // the parked state's chain by one dead segment, forever.
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

/// Run (or resume) a single activation's block loop. `resume_idx` is the
/// instruction index to begin at within `cur` (0 for a fresh call, the
/// post-suspension index on resume).
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
    // Every nested Kotlin call re-enters here (the host invokes a callable by
    // calling back into the evaluator). Bounding this depth converts an
    // unbounded recursion into a catchable `StackOverflowError` before the
    // native stack faults.
    if (ev_state.evtls.eval_depth >= maxEvalDepth()) {
        dumpFrameChainForDiag();
        return errResult(.{ .StackOverflow = "Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)" });
    }
    if (ev_state.evtls.eval_depth == 0) _ = parent.threads_in_eval.fetchAdd(1, .monotonic);
    ev_state.evtls.eval_depth += 1;
    defer {
        ev_state.evtls.eval_depth -= 1;
        // Safe point: back at the outermost activation, no native JIT frame is on
        // the stack, so the JIT cache can be trimmed if it has grown past its cap.
        if (ev_state.evtls.eval_depth == 0) {
            _ = parent.threads_in_eval.fetchSub(1, .monotonic);
            jit_loop.evictIfOverBudget();
        }
    }
    return runFrameInner(H, allocator, module, frame, try_stack, cur, resume_idx, null, null, host);
}

/// Snapshot `frame` (evtls.resuming at `block`:`inst_idx`, resume value delivered
/// into `resume_reg`) and append it to `state`'s frame list. Ownership of the
/// frame's pending-finally payload moves into the snapshot; the frame's own
/// teardown must then run (it releases regs the snapshot has retained).
pub fn snapshotSuspendedFrame(
    allocator: Allocator,
    frame: *Frame,
    try_stack: *std.ArrayList(TryFrame),
    block: BlockId,
    inst_idx: usize,
    resume_reg: ?Reg,
    state: *SuspendState,
) Allocator.Error!void {
    // The snapshot copies (and under reclaim retains) the whole file, and
    // the collector traces the copy; give it a fully-defined file.
    frame.materializeRegs();
    const saved_regs = try snapshotRegisters(
        allocator,
        frame.func,
        block,
        inst_idx,
        resume_reg,
        frame.regs.items,
        try_stack.items.len == 0,
    );
    noteSuspendSnapshot(
        saved_regs.isDense(),
        frame.regs.items.len,
        saved_regs.savedLen(),
        frame.params.items.len,
        frame.captures.items.len,
        frame.enclosing_this.items.len,
    );
    const snap: FrameSnapshot = .{
        .func = frame.func.id,
        .module = frame.module_arc,
        .block = block,
        .inst_idx = inst_idx,
        .regs = saved_regs,
        .params = blk: {
            if (runtime.gc.gc_enabled and runtime.gc.external_accounting) runtime.gc.noteExternalBytes((frame.params.items.len + frame.captures.items.len) * @sizeOf(Value));
            break :blk try allocator.dupe(Value, frame.params.items);
        },
        .captures = try allocator.dupe(Value, frame.captures.items),
        .enclosing_this = try allocator.dupe(EnclosingEntry, frame.enclosing_this.items),
        .try_stack = try allocator.dupe(TryFrame, try_stack.items),
        .pending_finally = frame.pending_finally,
        .is_lambda = frame.func.is_lambda,
        .resume_reg = resume_reg,
        .closure_id = frame.closure_id,
    };
    if (resumeTraceOn()) {
        std.debug.print("[suspend-frame] {s}#{d} at={d}:{d} pending={}/{}/{} caps={d} enc={d}\n", .{
            frame.func.name,
            frame.func.id.int(),
            block.int(),
            inst_idx,
            frame.pending_finally.rethrow != null,
            frame.pending_finally.return_value != null,
            frame.pending_finally.unwind != null,
            frame.captures.items.len,
            frame.enclosing_this.items.len,
        });
        traceEnclosingEntries("suspend-enclosing", frame.enclosing_this.items);
    }
    // The snapshot now holds the only references that will survive this
    // frame's teardown (its regs are released as the stack unwinds; its
    // params/captures alias caller regs / closure captures the unwind also
    // releases).
    retainSnapshotValues(snap);
    try state.frames.append(allocator, snap);
    // Ownership of the pending control-flow payload moved into `snap`;
    // frame teardown must not release it.
    frame.pending_finally = .{};
}

/// Per-thread activation freelist. Direct interpreted calls open one
/// activation each; without the pool every call paid an allocator
/// create/destroy for a ~300-byte struct. Pooled only under the tracing GC
/// (whose stable `c_allocator` backing the regs pool also uses); the
/// refcounting/arena backends keep plain create/destroy. Entries are inert
/// storage — no Values, nothing the GC must see.
pub const ACT_POOL_MAX = 128;

inline fn actPoolOn() bool {
    return !runtime.reclaimEnabled() and runtime.gc.gc_enabled;
}

fn actAlloc(ev: *EvalTls, allocator: Allocator) Allocator.Error!*Activation {
    if (actPoolOn()) {
        if (ev.act_pool_len > 0) {
            ev.act_pool_len -= 1;
            return ev.act_pool[ev.act_pool_len];
        }
        return std.heap.c_allocator.create(Activation);
    }
    return allocator.create(Activation);
}

pub fn actFree(ev: *EvalTls, allocator: Allocator, act: *Activation) void {
    if (actPoolOn()) {
        if (ev.act_pool_len < ACT_POOL_MAX) {
            ev.act_pool[ev.act_pool_len] = act;
            ev.act_pool_len += 1;
            return;
        }
        std.heap.c_allocator.destroy(act);
        return;
    }
    allocator.destroy(act);
}

/// Open a flat activation for a direct interpreted call: the same entry
/// sequence `evalWithCapturesChained` performs for a recursive call (frame
/// construction with the arg buffer transferred as params, GC chain push,
/// lexical receiver-chain activation, context-parameter seeding).
pub fn openActivation(comptime H: type, allocator: Allocator, caller_module: *const Module, req: FlatCallReq, host: *H) Allocator.Error!*Activation {
    const ev: *EvalTls = &ev_state.evtls;
    boolThisTrap(req.func, req.args.items);
    const module = req.run_module orelse caller_module;
    dumpFnIfRequested(module, req.func);
    // SAM conversion at the call boundary, as `evalWithCapturesChained` does
    // for the recursive path — the flat activation is the other way in.
    if (comptime @hasDecl(H, "samConvertActivationArgs")) {
        try host.samConvertActivationArgs(allocator, req.func, req.args.items);
    }
    const act = try actAlloc(ev, allocator);
    errdefer actFree(ev, allocator, act);
    act.* = .{
        .frame = try Frame.newWithCaptures(ev, allocator, module, req.func, req.args, req.captures),
        .try_stack = .empty,
        .ctx_mark = 0,
        .ctx_armed = true,
        .composer_pushed = req.composer_pushed,
        .pop_enclosing_n = req.pop_enclosing_n,
        .keepalive = req.keepalive,
        .suspend_barrier = req.suspend_barrier,
        .barrier_scope_base = req.barrier_scope_base,
        .scope_guard_ident = req.scope_guard_ident,
        .root_pump = req.root_pump,
        .typed_saved = req.typed_saved,
        .type_args = req.type_args,
        .ret_block = undefined,
        .ret_idx = 0,
        .ret_dst = req.dst,
    };
    act.frame.closure_id = req.closure_id;
    gcPushFrame(&act.frame);
    act.frame.module_arc = req.owning;
    try act.frame.activateChain(req.chain);
    act.ctx_mark = req.ctx_mark_override orelse
        (if (comptime @hasDecl(H, "ctxStackLen")) host.ctxStackLen() else 0);
    if (comptime @hasDecl(H, "ctxPush")) {
        if (module.has_context_decls) {
            if (comptime @hasDecl(H, "ctxActivate")) host.ctxActivate(true);
            if (req.func.has_receiver_param and act.frame.params.items.len > 0) {
                host.ctxPush(act.frame.params.items[0]) catch {};
            }
        }
    }
    return act;
}

/// Tear down a flat activation: the exact exit sequence of
/// `evalWithCapturesChained`'s defers, in their LIFO order, then the host's
/// post-call unwinds (ambient composer pop) that wrapped the recursive call.
/// A previously-parked activation carries no live host-entry effects (its
/// flags were cleared at park), so only the frame itself unwinds.
pub fn teardownActivation(comptime H: type, allocator: Allocator, act: *Activation, host: *H) void {
    if (act.ctx_armed) {
        if (comptime @hasDecl(H, "ctxStackTruncate")) host.ctxStackTruncate(act.ctx_mark);
        act.ctx_armed = false;
    }
    act.frame.deactivateChain();
    gcPopFrame(&act.frame);
    act.frame.deinit();
    act.try_stack.deinit(allocator);
    if (act.composer_pushed) {
        if (comptime @hasDecl(H, "flatCallClosed")) host.flatCallClosed();
        act.composer_pushed = false;
    }
    while (act.pop_enclosing_n > 0) : (act.pop_enclosing_n -= 1) popEnclosing();
    if (act.keepalive) |ka| {
        if (runtime.reclaimEnabled()) ka.release(allocator);
        act.keepalive = null;
    }
    if (act.scope_guard_ident != 0) {
        if (comptime @hasDecl(H, "undispatchedScopeLeave")) host.undispatchedScopeLeave(act.scope_guard_ident);
        act.scope_guard_ident = 0;
    }
    if (act.typed_saved) |ts| {
        if (comptime @hasDecl(H, "typedBindingsRestore")) host.typedBindingsRestore(allocator, ts);
        act.typed_saved = null;
    }
    if (act.type_args.len > 0) {
        allocator.free(act.type_args);
        act.type_args = &.{};
    }
}

/// Park a flat activation live: unwind its host-entry effects and thread
/// links, then hand the intact activation (frame, registers, try-stack,
/// receiver chain — no copies, no retains) to the suspend state. Ownership
/// moves to the state; `resumeLiveActivation` reinstalls it, and
/// `SuspendState.deinit` destroys it if the coroutine is dropped unresumed.
pub fn liveParkActivation(
    comptime H: type,
    allocator: Allocator,
    act: *Activation,
    block: BlockId,
    inst_idx: usize,
    resume_reg: ?Reg,
    state: *SuspendState,
    host: *H,
) Allocator.Error!void {
    if (act.ctx_armed) {
        if (comptime @hasDecl(H, "ctxStackTruncate")) host.ctxStackTruncate(act.ctx_mark);
        act.ctx_armed = false;
    }
    if (act.composer_pushed) {
        if (comptime @hasDecl(H, "flatCallClosed")) host.flatCallClosed();
        act.composer_pushed = false;
    }
    act.frame.deactivateChain();
    gcPopFrame(&act.frame);
    while (act.pop_enclosing_n > 0) : (act.pop_enclosing_n -= 1) popEnclosing();
    // The park's scope-delta capture owns the guard entry from here on.
    act.scope_guard_ident = 0;
    // Reified bindings restore across a suspension exactly as the
    // recursive path's unconditional restore loop did; the resumed body
    // reads no type-name globals (its reified reads were lowering-bound).
    if (act.typed_saved) |ts| {
        if (comptime @hasDecl(H, "typedBindingsRestore")) host.typedBindingsRestore(allocator, ts);
        act.typed_saved = null;
    }
    if (resumeTraceOn()) {
        std.debug.print("[suspend-frame] {s}#{d} at={d}:{d} LIVE caps={d} enc={d}\n", .{
            act.frame.func.name,
            act.frame.func.id.int(),
            block.int(),
            inst_idx,
            act.frame.captures.items.len,
            act.frame.enclosing_this.items.len,
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
        .enclosing_this = &.{},
        .try_stack = &.{},
        .pending_finally = .{},
        .is_lambda = act.frame.func.is_lambda,
        .resume_reg = resume_reg,
        .closure_id = act.frame.closure_id,
    });
}

/// Destroy a live-parked activation that is being dropped without a resume
/// (a cancelled or abandoned coroutine). The frame owns its register
/// references; params/captures are borrows, exactly as during execution.
pub fn destroyParkedActivation(allocator: Allocator, act: *Activation) void {
    act.frame.deinit();
    act.try_stack.deinit(allocator);
    if (act.keepalive) |ka| {
        if (runtime.reclaimEnabled()) ka.release(allocator);
    }
    if (act.type_args.len > 0) allocator.free(act.type_args);
    actFree(&ev_state.evtls, allocator, act);
}

/// Reinstall a live-parked activation and run it to its next completion or
/// suspension. `block`/`inst_idx`/`resume_reg` come from the park entry.
/// On suspension the driver has already re-parked the activation into the
/// new state (ownership moved); on completion the activation is torn down
/// here and the boundary-transformed result returned.
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
    // A live-parked activation may resume on a DIFFERENT worker thread than
    // the one that parked it (the pool rotates, and the parker may already
    // have exited — the daemon-abandon teardown races exactly this way).
    // Rebind the frame to the RESUMING thread's eval TLS first; the parked
    // pointer otherwise dereferences a dead thread's storage.
    act.frame.tls = &ev_state.evtls;
    gcPushFrame(&act.frame);
    act.frame.activateAs();
    if (resume_throw == null) {
        if (resume_reg) |r| try act.frame.write(r, carry);
    }
    const res = try runFlatLoop(H, allocator, &act.frame, &act.try_stack, block, inst_idx, resume_throw, resume_unwind, act, host);
    if (res == .err and res.err == .Suspended) return res;
    const out = frameBoundary(act.frame.func, res);
    teardownActivation(H, allocator, act, host);
    actFree(&ev_state.evtls, allocator, act);
    return out;
}

/// Discard a flat call request without running it (depth-cap rejection):
/// free the transferred buffers (values are borrows) and unwind any host
/// side effect the prepare step applied.
pub fn discardFlatReq(comptime H: type, allocator: Allocator, req: FlatCallReq, host: *H) void {
    var args = req.args;
    args.deinit(allocator);
    var caps = req.captures;
    caps.deinit(allocator);
    if (req.composer_pushed) {
        if (comptime @hasDecl(H, "flatCallClosed")) host.flatCallClosed();
    }
    var n = req.pop_enclosing_n;
    while (n > 0) : (n -= 1) popEnclosing();
    if (req.keepalive) |ka| {
        if (runtime.reclaimEnabled()) ka.release(allocator);
    }
    if (req.scope_guard_ident != 0) {
        if (comptime @hasDecl(H, "undispatchedScopeLeave")) host.undispatchedScopeLeave(req.scope_guard_ident);
    }
    if (req.typed_saved) |ts| {
        if (comptime @hasDecl(H, "typedBindingsRestore")) host.typedBindingsRestore(allocator, ts);
    }
    if (req.type_args.len > 0) allocator.free(req.type_args);
}

/// The flat call driver. Runs `frame` through `runFrameExec`; when the
/// executor surfaces a direct interpreted call, pushes the callee as a new
/// heap activation and continues in the same loop instead of recursing
/// natively. Results, throws, non-local returns and suspensions re-enter the
/// calling frame through the executor's resume machinery — the same routes a
/// coroutine resume uses — so control-flow semantics are identical to the
/// recursive path.
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
