//! The frame loop: runs a frame's blocks through their streams (`stream.zig`), routes throws,
//! non-local returns and finally flows, and opens and closes the activations a call the stream
//! loop does not run in place needs. Also the scalar operations the stream ops and the
//! instruction arms compute with.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const bc = @import("../bc.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const BinOp = ir.BinOp;
const BlockId = ir.BlockId;
const ClassId = ir.ClassId;
const Func = ir.Func;
const Inst = ir.Inst;
const Module = ir.Module;
const Reg = ir.Reg;
const Terminator = ir.Terminator;


const envVarSet = ev_values.envVarSet;

const parent = @import("../eval.zig");
const ev_diag = @import("diag.zig");
const ev_enter = @import("enter.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_inst = @import("inst.zig");
const ev_activation = @import("activation.zig");
const ev_resolved = @import("resolved.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");
const ev_values = @import("values.zig");
const stream = @import("stream.zig");

const EvalError = ev_state.EvalError;
const EvalResult = ev_flow.EvalResult;
const EvalTls = ev_state.EvalTls;
const Activation = ev_flow.Activation;
const actFree = ev_activation.actFree;
const discardFlatReq = ev_activation.discardFlatReq;
const dumpFrameChainForDiag = ev_diag.dumpFrameChainForDiag;
const frameBoundary = ev_enter.frameBoundary;
const funcOwnedBy = ev_enter.funcOwnedBy;
const liveParkActivation = ev_activation.liveParkActivation;
const openActivation = ev_activation.openActivation;
const openStreamActivation = ev_activation.openStreamActivation;
const closeStreamActivation = ev_activation.closeStreamActivation;
const snapshotSuspendedFrame = ev_activation.snapshotSuspendedFrame;
const teardownActivation = ev_activation.teardownActivation;
const argRun = ev_frame.argRun;
const FlatCallSite = ev_flow.FlatCallSite;
const Frame = ev_frame.Frame;
const ParkPoint = ev_flow.ParkPoint;
const PendingFinallyState = ev_snapshot.PendingFinallyState;
const Step = ev_flow.Step;
const TryFrame = ev_snapshot.TryFrame;
const attachStackTrace = ev_diag.attachStackTrace;
const cmgTraceWant = ev_flow.cmgTraceWant;
const constToValue = ev_values.constToValue;
const currentFrameFunc = ev_state.currentFrameFunc;
const displayThrow = ev_state.displayThrow;
const divTruncI32 = ev_values.divTruncI32;
const divTruncI64 = ev_values.divTruncI64;
const dumpFnIfRequested = ev_enter.dumpFnIfRequested;
const dumpFrameChainForDiagAlways = ev_diag.dumpFrameChainForDiagAlways;
const errResult = ev_flow.errResult;
const execArmBinOp = ev_inst.execArmBinOp;
const execInst = ev_inst.execInst;
const lrTraceOn = ev_flow.lrTraceOn;
const nowMonotonicMs = ev_diag.nowMonotonicMs;
const ok = ev_flow.ok;
const remTruncI32 = ev_values.remTruncI32;
const remTruncI64 = ev_values.remTruncI64;
const spinDumpMaybe = ev_diag.spinDumpMaybe;
const unwindTerminal = ev_enter.unwindTerminal;
const valueTruthy = ev_values.valueTruthy;
const wallCapFire = ev_diag.wallCapFire;

/// The one interpreter loop: runs `root` from `cur_in` and every activation its calls open, switching
/// frames in place rather than returning to a driver. `resume_throw`: a continuation resumed with
/// `Result.failure(e)` routes the exception through the frame's restored try-stack instead of
/// delivering it as the suspending call's value, so a cancellation preempts a parked `delay`.
/// `resume_unwind` is the same for a non-local return from a resumed inner frame. `root_act` marks a
/// root frame that is itself a resumed live activation, which a suspension live-parks rather than
/// snapshots.
pub fn runFlatLoop(
    comptime H: type,
    allocator: Allocator,
    root: *Frame,
    root_ts: *std.ArrayList(TryFrame),
    cur_in: BlockId,
    resume_idx_in: usize,
    resume_throw_in: ?Value,
    resume_unwind_in: ?EvalError,
    root_act: ?*Activation,
    host: *H,
) Allocator.Error!EvalResult {
    // The reclaim flag is fixed for the run, so each setting gets a loop of its own: under the
    // tracing collector no stream op tests it or keeps an old value to release.
    if (runtime.reclaimEnabled())
        return runLoop(H, true, allocator, root, root_ts, cur_in, resume_idx_in, resume_throw_in, resume_unwind_in, root_act, host);
    return runLoop(H, false, allocator, root, root_ts, cur_in, resume_idx_in, resume_throw_in, resume_unwind_in, root_act, host);
}

fn runLoop(
    comptime H: type,
    comptime reclaim: bool,
    allocator: Allocator,
    root: *Frame,
    root_ts: *std.ArrayList(TryFrame),
    cur_in: BlockId,
    resume_idx_in: usize,
    resume_throw_in: ?Value,
    resume_unwind_in: ?EvalError,
    root_act: ?*Activation,
    host: *H,
) Allocator.Error!EvalResult {
    const ev: *EvalTls = ev_state.evtlsPtr();
    ev_state.refreshCallMode(ev);
    const S = stream.Stream(H, reclaim);
    // What the stream loop keeps besides its hot state; the open activations are its `top`.
    var c: S.Ctx = .{
        .allocator = allocator,
        .host = host,
        .ev = ev,
        .root = root,
        .root_ts = root_ts,
        .bs = undefined,
        .frame = root,
        .tlab = runtime.gc.tlabFor(allocator),
    };
    // On an allocation failure, unwind every open activation so no frame dangles on the GC chain.
    errdefer while (c.top) |act| {
        c.top = act.caller;
        ev.eval_depth -= 1;
        teardownActivation(allocator, act);
        actFree(ev, allocator, act);
    };
    // KLIO_FN_PROF: the caller's attribution is restored on exit, so samples are self-time.
    const fn_prof_prev: u32 = if (runtime.prof.fn_prof_active) fnProfEnter(root.func.id.int()) else 0;
    defer if (runtime.prof.fn_prof_active) fnProfLeave(fn_prof_prev);
    const ftls: *EvalTls = ev;
    var frame: *Frame = root;
    var try_stack: *std.ArrayList(TryFrame) = root_ts;
    var cur = cur_in;
    var resume_idx = resume_idx_in;
    var resume_throw = resume_throw_in;
    var resume_unwind = resume_unwind_in;
    frames: while (true) {
        // A suspended coroutine resumes on whatever thread the dispatcher hands it.
        if (frame.tls != ev) frame.tls = ev;
        if (parent.frame_count_on) parent.frame_count_total += 1;
        if (runtime.prof.fn_prof_active) _ = fnProfEnter(frame.func.id.int());
        var func: *const Func = frame.func;
        var flat_site: ?FlatCallSite = null;
        var park_point: ?ParkPoint = null;
        c.flat_out = &flat_site;
        c.park_out = &park_point;
        var res: EvalResult = blocks: {
            // Lazy IR: materialise a deferred function's blocks first.
            if (!frame.module.ensureFuncBody(@constCast(func))) {
                if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
                    std.debug.print("[empty-frame] fqn={s} params={d} caller={s}\n", .{
                        func.fqn, func.params.len,
                        if (currentFrameFunc()) |cf| cf.fqn else "<none>",
                    });
                    dumpFrameChainForDiagAlways();
                }
                break :blocks errResult(.{ .Type = "virtual method target is not executable" });
            }
            dumpFnIfRequested(func);
            // The function's code: a null table is an allocation that failed or an edge to no block.
            var bc_streams: *const bc.FuncStreams = bc.funcStreams(func, frame.module.consts.items) orelse return error.OutOfMemory;
            S.countEntry(bc_streams, frame.module);
            block_loop: while (true) {
                // A block entry is a safe point: no cell lock may be held across it.
                runtime.assertNoCellLock();
                // Daemon abandonment: a pool task at the run boundary stops at its next block, bypassing user catch/finally.
                if (runtime.shouldAbandon()) {
                    break :blocks errResult(.{ .Type = "daemon task abandoned at run boundary" });
                }
                // Spin diagnostic (KLIO_SPIN_TRACE): cheap counter gate, wall-clock check inside.
                ftls.spin_check_counter +%= 1;
                if (ftls.spin_check_counter & 0xFFFF == 0) {
                    spinDumpMaybe();
                    if (runtime.gc.gc_enabled) runtime.gc.idleProbeNow();
                    const wall_dl = parent.test_wall_deadline_ms.load(.monotonic);
                    if (wall_dl != 0 and nowMonotonicMs() > wall_dl) {
                        // Dump the live frame chain so a caught hang names where it looped.
                        break :blocks try wallCapFire(allocator);
                    }
                }
                // GC safe point: at an opcode boundary every live Value sits in a registered frame or
                // global; route a resumed throw/return payload first so it stays rooted.
                if (runtime.gc.gc_enabled and runtime.gc.pendingFlag() and
                    resume_throw == null and resume_unwind == null)
                {
                    // At the block's start, or where a resume goes on in it (its terminator
                    // for one past its instructions).
                    frame.at(cur, if (resume_idx == 0) ev_frame.block_start else @min(resume_idx, func.blocks[cur.int()].insts.len));
                    runtime.gc.safePoint();
                }
                const block = &func.blocks[cur.int()];
                // A function with known try frames keeps no try stack (`FuncStreams.try_ctx`).
                if (bc_streams.try_ctx == null) {
                    if (resume_idx == 0) {
                        try enterTryBlock(try_stack, block, cur);
                    } else if (block.h().catch_done_for) |body| {
                        // A resume into a catch-only try's join pops the body's frame, as an entry does.
                        if (rpositionByBody(try_stack.items, body)) |p| _ = try_stack.orderedRemove(p);
                    }
                }
                const insts: []const Inst = block.insts;
                const term = block.terminator;
                var thrown: ?Value = null;
                var unwound: ?EvalError = null;
                var start_idx = resume_idx;
                resume_idx = 0;
                if (resume_throw) |exc| {
                    resume_throw = null;
                    // Resumed with an exception: route it through the restored try-stack as a mid-block throw.
                    thrown = exc;
                    start_idx = insts.len;
                } else if (resume_unwind) |e| {
                    resume_unwind = null;
                    // Resume the caller as though its suspending call raised this non-local return.
                    unwound = e;
                    start_idx = insts.len;
                }
                // A stream exit that leaves only its block's terminator to the frame loop.
                // The block's stream: its ops run the instructions, every other one escapes to its
                // arm in `execInst`, and control flow funnels through `afterStep`. A mid-block resume
                // enters at the instruction's pc.
                bc_run: {
                    const bs = bc_streams;
                    // A resume carrying a throw/unwind runs no instruction of the block: an EMPTY
                    // block's `start_idx` is 0 too, and a terminator op must not run first.
                    if (thrown != null or unwound != null) break :bc_run;
                    // The one bounds check the stream ops rely on; every operand was validated at build.
                    if (frame.regs.len < func.n_locals) break :blocks errResult(.{ .Type = "a register window shorter than its function's registers" });
                    const bl = bs.blocks[cur.int()];
                    // Every block's ops end in an `end` op; a resume at the terminator starts on it.
                    const pc: usize = if (start_idx == 0)
                        bl.start
                    else if (start_idx >= insts.len)
                        bl.end
                    else
                        bl.idx_pc[start_idx];
                    c.frame = frame;
                    c.bs = bs;
                    c.thrown = null;
                    c.unwound = null;
                    c.ret_v = ok(.Unit);
                    const exit = S.run(&c, frame, bs.code.ptr, pc, cur.int());
                    // The stream may have gone on into other blocks and other frames.
                    frame = c.frame;
                    try_stack = if (c.top) |a| &a.try_stack else root_ts;
                    func = frame.func;
                    bc_streams = c.bs;
                    cur = @enumFromInt(c.blk);
                    thrown = c.thrown;
                    unwound = c.unwound;
                    switch (exit) {
                        .brk => {},
                        .ret => break :blocks c.ret_v,
                        .result => break :blocks c.result,
                        .block => {
                            resume_idx = c.resume_idx;
                            continue :block_loop;
                        },
                        .oom => return error.OutOfMemory,
                        .cont => unreachable,
                    }
                }
                // A throw or an unwind routes to a catch or a finally, which finds the span where
                // the frame stands.
                if (thrown != null or unwound != null) frame.leaveSpanFrom(cur.int());
                // What follows reads the try stack: with known try frames, the block's.
                if (bc_streams.try_ctx) |*tc| try tryStackOf(try_stack, func, tc, cur.int());
                if (unwound) |e| {
                    // Mid-block non-local return: route through the armed finally blocks only, never a
                    // catch.
                    frame.pfRelease(allocator);
                    var routed = false;
                    while (try_stack.pop()) |tf| {
                        if (tf.finally_entry) |fin| {
                            if (std.meta.eql(fin, cur)) continue;
                            const key = tf.finally_done orelse fin;
                            (try frame.pfMut()).unwind = .{ .key = key, .err = e, .depth = try_stack.items.len };
                            cur = fin;
                            routed = true;
                            break;
                        }
                    }
                    if (!routed) break :blocks unwindTerminal(frame, e);
                    continue;
                }
                if (thrown) |exc| {
                    // Mid-block throw: the same try-stack walk as Terminator.Throw.
                    const pending_depth = frame.pf().tryDepth();
                    var routed = false;
                    while (try_stack.pop()) |tf| {
                        // A throw raised inside this frame's own finally body must not route back into that
                        // finally or the frame's catches: control left the try region when the finally began.
                        if (tf.finally_entry) |fin0| {
                            if (std.meta.eql(fin0, cur)) continue;
                        }
                        if (findCatch(frame.module, &exc, tf.catches)) |h| {
                            // A catch belonging to a try nested inside the active finally handles the new throw
                            // without replacing the exception or return that caused the finally. Once the scan
                            // crosses the saved depth the throw is escaping, and Kotlin replaces the prior flow.
                            if (pending_depth) |depth| {
                                if (try_stack.items.len < depth) frame.pfRelease(allocator);
                            }
                            try frame.write(h.exception_reg, try caughtValue(H, host, allocator, exc));
                            cur = h.handler;
                            routed = true;
                            break;
                        } else if (tf.finally_entry) |fin| {
                            // An uncaught throw entering a nested finally supersedes the pending control flow.
                            frame.pfRelease(allocator);
                            const key = tf.finally_done orelse fin;
                            (try frame.pfMut()).rethrow = .{ .key = key, .exc = exc, .depth = try_stack.items.len };
                            cur = fin;
                            routed = true;
                            break;
                        }
                    }
                    if (!routed) {
                        frame.pfRelease(allocator);
                        break :blocks errResult(.{ .Throw = exc });
                    }
                    continue;
                }
                if (term == .Goto) {
                    if (frame.pf().tryDepth() == null) {
                        leaveTryBlock(try_stack, block, cur);
                    } else {
                        // With a flow pending, only an inline return's frames pop here.
                        popOnExit(try_stack, block);
                    }
                }
                // Finally exit with a pending return: replay through any outer finally, else complete it.
                // The pinned key is the done sentinel, so an `if` inside the finally resolves here.
                if (frame.pf().return_value) |pr| {
                    if (std.meta.eql(pr.key, cur) and term == .Goto) {
                        const v = pr.val;
                        (try frame.pfMut()).return_value = null;
                        var chosen: ?struct { i: usize, jump: BlockId, key: BlockId } = null;
                        var i: usize = try_stack.items.len;
                        while (i > 0) {
                            i -= 1;
                            if (try_stack.items[i].finally_entry) |fin2| {
                                const key = try_stack.items[i].finally_done orelse fin2;
                                chosen = .{ .i = i, .jump = fin2, .key = key };
                                break;
                            }
                        }
                        if (chosen) |ch| {
                            try_stack.shrinkRetainingCapacity(ch.i);
                            (try frame.pfMut()).return_value = .{ .key = ch.key, .val = v, .depth = try_stack.items.len };
                            cur = ch.jump;
                            continue;
                        }
                        break :blocks ok(v);
                    }
                    if (std.meta.eql(pr.key, cur) and isReturnLike(term)) {
                        pr.val.release(allocator);
                        (try frame.pfMut()).return_value = null;
                    }
                }
                // Finally re-throw: a plain Goto exit re-raises the saved exception through the enclosing stack.
                if (frame.pf().rethrow) |pr| {
                    if (std.meta.eql(pr.key, cur) and term == .Goto) {
                        const exc = pr.exc;
                        (try frame.pfMut()).rethrow = null;
                        // Drop try-frames the finally body pushed and did not pop, so they cannot intercept.
                        if (try_stack.items.len > pr.depth) try_stack.shrinkRetainingCapacity(pr.depth);
                        var routed = false;
                        while (try_stack.pop()) |tf| {
                            if (findCatch(frame.module, &exc, tf.catches)) |h| {
                            try frame.write(h.exception_reg, try caughtValue(H, host, allocator, exc));
                                cur = h.handler;
                                routed = true;
                                break;
                            } else if (tf.finally_entry) |fin2| {
                                const key = tf.finally_done orelse fin2;
                            (try frame.pfMut()).rethrow = .{ .key = key, .exc = exc, .depth = try_stack.items.len };
                                cur = fin2;
                                routed = true;
                                break;
                            }
                        }
                        if (!routed) {
                            break :blocks errResult(.{ .Throw = exc });
                        }
                        continue;
                    }
                    // A `return`/`throw` inside finally clears the pending re-throw: its exit replaces the original.
                    if (std.meta.eql(pr.key, cur) and isReturnLike(term)) {
                        pr.exc.release(allocator);
                        (try frame.pfMut()).rethrow = null;
                    }
                }
                // Finally exit with a pending non-local return: replay through an outer finally, else unwind.
                if (frame.pf().unwind) |pu| {
                    if (std.meta.eql(pu.key, cur) and term == .Goto) {
                        const e = pu.err;
                        (try frame.pfMut()).unwind = null;
                        if (try_stack.items.len > pu.depth) try_stack.shrinkRetainingCapacity(pu.depth);
                        var routed = false;
                        while (try_stack.pop()) |tf| {
                            if (tf.finally_entry) |fin2| {
                                const key = tf.finally_done orelse fin2;
                                (try frame.pfMut()).unwind = .{ .key = key, .err = e, .depth = try_stack.items.len };
                                cur = fin2;
                                routed = true;
                                break;
                            }
                        }
                        if (!routed) break :blocks unwindTerminal(frame, e);
                        continue;
                    }
                    // A `return`/`throw` inside the finally replaces the pending non-local return.
                    if (std.meta.eql(pu.key, cur) and isReturnLike(term)) {
                        if (PendingFinallyState.payloadOfError(pu.err)) |v| v.release(allocator);
                        (try frame.pfMut()).unwind = null;
                    }
                }
                // A return or throw inside a finally replaces the flow that entered it, sentinel or not.
                if (replacesPendingBeforeRouting(term)) frame.pfRelease(allocator);
                switch (term) {
                    .Goto => |next| cur = next,
                    .Branch => |br| {
                        const v = frame.read(br.cond);
                        switch (try valueTruthy(allocator, &v)) {
                            .ok => |b| cur = if (b) br.t else br.f,
                            .err => |e| break :blocks errResult(e),
                        }
                    },
                    .Return => |maybe_r| {
                        const v = if (maybe_r) |r| frame.read(r) else Value.Unit;
                        // The value escapes this frame; retain so teardown does not free it under the caller.
                        v.retain();
                        var chosen: ?struct { i: usize, jump: BlockId, key: BlockId } = null;
                        var i: usize = try_stack.items.len;
                        while (i > 0) {
                            i -= 1;
                            if (try_stack.items[i].finally_entry) |fin| {
                                // A return from inside this frame's own finally exits through OUTER finallys only.
                                if (std.meta.eql(fin, cur)) continue;
                                const key = try_stack.items[i].finally_done orelse fin;
                                chosen = .{ .i = i, .jump = fin, .key = key };
                                break;
                            }
                        }
                        if (chosen) |ch| {
                            try_stack.shrinkRetainingCapacity(ch.i);
                            (try frame.pfMut()).return_value = .{ .key = ch.key, .val = v, .depth = try_stack.items.len };
                            cur = ch.jump;
                            continue;
                        }
                        break :blocks ok(v);
                    },
                    .Throw => |r| {
                        var exc = frame.read(r);
                        exc.retain();
                        frame.at(cur, insts.len);
                        // Capture the call stack here, in the throwing frame, before it unwinds: the
                        // instruction-loop seam sees the value only once it surfaces into the caller.
                        try attachStackTrace(allocator, &exc);
                        if (envVarSet("KLIO_THROW_TRACE")) {
                            const s = displayThrow(allocator, &exc) catch "";
                            std.debug.print("[throw-trace] from fn {s} (fqn={s}): {s}\n", .{ frame.func.name, frame.func.fqn, s });
                            if (envVarSet("KLIO_THROW_STACK")) dumpFrameChainForDiagAlways();
                        }
                        const pending_depth = frame.pf().tryDepth();
                        var routed = false;
                        while (try_stack.pop()) |tf| {
                            // Same own-finally guard as the mid-block walk: a throw from inside the finally skips the frame.
                            if (tf.finally_entry) |fin0| {
                                if (std.meta.eql(fin0, cur)) continue;
                            }
                            if (findCatch(frame.module, &exc, tf.catches)) |h| {
                                if (pending_depth) |depth| {
                                    if (try_stack.items.len < depth) frame.pfRelease(allocator);
                                }
                            try frame.write(h.exception_reg, try caughtValue(H, host, allocator, exc));
                                cur = h.handler;
                                routed = true;
                                break;
                            } else if (tf.finally_entry) |fin| {
                                frame.pfRelease(allocator);
                                const key = tf.finally_done orelse fin;
                            (try frame.pfMut()).rethrow = .{ .key = key, .exc = exc, .depth = try_stack.items.len };
                                cur = fin;
                                routed = true;
                                break;
                            }
                        }
                        if (!routed) {
                            frame.pfRelease(allocator);
                            break :blocks errResult(.{ .Throw = exc });
                        }
                    },
                    .Unreachable => {
                        break :blocks errResult(.{ .Type = "reached Terminator.Unreachable" });
                    },
                }
            }
        };
        resume_throw = null;
        resume_unwind = null;
        if (flat_site) |site| {
            // The module the callee's body must be READ against: a request that names one is
            // authoritative, the caller's module only when it actually owns this `Func`.
            const callee_mod: *const Module = site.req.run_module orelse blk_cm: {
                if (funcOwnedBy(frame.module, site.req.func)) break :blk_cm frame.module;
                if (comptime @hasDecl(H, "ownerModuleForFunc")) {
                    if (host.ownerModuleForFunc(site.req.func)) |m| break :blk_cm m;
                }
                break :blk_cm frame.module;
            };
            cur = site.ret_block;
            resume_idx = site.ret_idx;
            // Same depth bound as the recursive path: unbounded recursion becomes a catchable StackOverflowError.
            if (ev.eval_depth >= ev_state.evalDepthCap(ev)) {
                dumpFrameChainForDiag();
                discardFlatReq(ev, site.req);
                // Kotlin code catches it as `java.lang.StackOverflowError`.
                if (try ev_resolved.stackOverflowError(H, allocator, frame.module, host)) |exc| {
                    resume_throw = exc;
                } else {
                    resume_unwind = .{ .StackOverflow = "Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)" };
                }
                continue :frames;
            }
            ev.eval_depth += 1;
            const act = openActivation(ev, allocator, callee_mod, site.req) catch |e| {
                ev.eval_depth -= 1;
                discardFlatReq(ev, site.req);
                return e;
            };
            act.ret_block = site.ret_block;
            act.ret_idx = @intCast(site.ret_idx);
            act.caller = c.top;
            c.top = act;
            frame = &act.frame;
            try_stack = &act.try_stack;
            cur = site.req.func.entry;
            resume_idx = 0;
            continue :frames;
        }
        // A suspension parks the current frame at its suspension point, then every outer activation
        // at its call-return point. Flat activations park LIVE by pointer; a native root snapshots.
        if (park_point) |pp| {
            const state = res.err.Suspended;
            var pb = pp.block;
            var pi = pp.inst_idx;
            var pd = pp.resume_reg;
            while (c.top) |a| {
                c.top = a.caller;
                ev.eval_depth -= 1;
                const rb = a.ret_block;
                const rix = a.ret_idx;
                const rd = a.ret_dst;
                try liveParkActivation(allocator, a, pb, pi, pd, state);
                pb = rb;
                pi = rix;
                pd = rd;
            }
            if (root_act) |ra| {
                try liveParkActivation(allocator, ra, pb, pi, pd, state);
            } else {
                try snapshotSuspendedFrame(allocator, root, root_ts, pb, pi, pd, state);
            }
            return res;
        }
        // The frame exited: deliver its result through each popped frame's boundary transforms.
        while (true) {
            const act = c.top orelse return res;
            c.top = act.caller;
            ev.eval_depth -= 1;
            if (act.frame.module.resolved == null) res = frameBoundary(act.frame.func, res);
            const rb = act.ret_block;
            const rix = act.ret_idx;
            const rd = act.ret_dst;
            teardownActivation(allocator, act);
            actFree(ev, allocator, act);
            frame = if (c.top) |a| &a.frame else root;
            try_stack = if (c.top) |a| &a.try_stack else root_ts;
            switch (res) {
                .ok => |v| try frame.write(rd, v),
                .err => |e| switch (e) {
                    .Throw => |v| resume_throw = v,
                    .NonLocalReturn, .LabeledReturn, .CalleeFailed, .StackOverflow => resume_unwind = e,
                    // Anything else exits the calling frame as-is; keep popping so each boundary applies.
                    else => continue,
                },
            }
            cur = rb;
            resume_idx = rix;
            continue :frames;
        }
    }
}

/// `KLIO_FN_PROF`'s attribution swap, out of line: `current_fn` is a threadlocal, and an
/// inline read is hoisted above the flag test into every frame entry.
pub noinline fn fnProfEnter(fid: u32) u32 {
    const prev = runtime.prof.current_fn;
    runtime.prof.current_fn = fid;
    return prev;
}

noinline fn fnProfLeave(prev: u32) void {
    runtime.prof.current_fn = prev;
}

fn isReturnLike(term: Terminator) bool {
    return switch (term) {
        .Return, .Throw => true,
        else => false,
    };
}

fn replacesPendingBeforeRouting(term: Terminator) bool {
    return term == .Return;
}

/// What entering block `cur` does to the try stack. Normal flow into a catch-only try's join
/// pops the body's frame (`Block.catch_done_for`). Entering a finally disarms its try frame:
/// the region's catches and the finally itself must not capture anything raised inside it, and
/// a frame still armed here is the normal-completion entry; keyed on block entry, since a
/// multi-block finally leaves the exit-side pop unreached while later blocks run. A block that
/// opens a try region pushes its frame.
pub fn enterTryBlock(try_stack: *std.ArrayList(TryFrame), block: *const ir.Block, cur: BlockId) Allocator.Error!void {
    const h = block.h();
    if (h.catch_done_for) |body| {
        if (rpositionByBody(try_stack.items, body)) |p| _ = try_stack.orderedRemove(p);
    }
    if (rpositionByFinallyEntry(try_stack.items, cur)) |p| _ = try_stack.orderedRemove(p);
    if (h.catches.len != 0 or h.finally != null) {
        try try_stack.append(ev_snapshot.try_alloc, .{
            .body = cur,
            .catches = h.catches,
            .finally_entry = h.finally,
            .finally_done = h.finally_done,
        });
    }
}

/// The try stack of a frame of `func` standing in block `cur`, from the function's known try
/// frames (`FuncStreams.try_ctx`), for a route through its handlers to read.
pub fn tryStackOf(try_stack: *std.ArrayList(TryFrame), func: *const ir.Func, tc: *const ir.trymap.TryContexts, cur: u32) Allocator.Error!void {
    try_stack.clearRetainingCapacity();
    for (tc.of(cur)) |body| {
        const h = func.blocks[body].h();
        try try_stack.append(ev_snapshot.try_alloc, .{ .body = .from(body), .catches = h.catches, .finally_entry = h.finally, .finally_done = h.finally_done });
    }
}

/// What a Goto out of block `cur` does to the try stack with no finally flow pending: normal
/// flow through a finally pops its frame, at the done sentinel or the finally's own entry, and
/// an inline `return` jumping to its join pops the frames it bypassed the sentinels of.
pub fn leaveTryBlock(try_stack: *std.ArrayList(TryFrame), block: *const ir.Block, cur: BlockId) void {
    const pos: ?usize = if (block.h().finally_done_for) |body|
        rpositionByBody(try_stack.items, body)
    else
        rpositionByFinallyEntry(try_stack.items, cur);
    if (pos) |p| _ = try_stack.orderedRemove(p);
    popOnExit(try_stack, block);
}

fn popOnExit(try_stack: *std.ArrayList(TryFrame), block: *const ir.Block) void {
    for (block.h().pop_on_exit) |body| {
        if (rpositionByBody(try_stack.items, body)) |p| _ = try_stack.orderedRemove(p);
    }
}

fn rpositionByBody(items: []const TryFrame, body: BlockId) ?usize {
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        if (std.meta.eql(items[i].body, body)) return i;
    }
    return null;
}

fn rpositionByFinallyEntry(items: []const TryFrame, cur: BlockId) ?usize {
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        if (items[i].finally_entry) |b| {
            if (std.meta.eql(b, cur)) return i;
        }
    }
    return null;
}

/// The first handler that takes `exc`. A handler lowered from sema names its
/// class and matches by the class tables; any other matches by type name.
/// The value a catch handler binds: what was thrown, or for a host
/// exception caught in code lowered from sema, the instance the host makes
/// of it, which that code reads like any other.
fn caughtValue(comptime H: type, host: *H, allocator: Allocator, exc: Value) Allocator.Error!Value {
    if (comptime @hasDecl(H, "caughtValue")) return host.caughtValue(allocator, exc);
    return exc;
}

fn findCatch(module: *const Module, exc: *const Value, catches: []const ir.CatchHandler) ?ir.CatchHandler {
    const r = module.resolved orelse return null;
    const have = ir.resolved.classOf(r, exc) orelse return null;
    for (catches) |h| {
        if (ir.resolved.isA(module, have, h.class)) return h;
    }
    return null;
}

/// `wideBinFast`'s operations: `floatScalarBin`'s, and the shifts of a
/// `Long` by a `Long` count, which shift by its low six bits.
pub fn wideScalarBin(op: BinOp, lv: Value, rv: Value) ?Value {
    return floatScalarBin(op, lv, rv) orelse longShift(op, lv, rv);
}

pub inline fn longShift(op: BinOp, lv: Value, rv: Value) ?Value {
    if (lv != .Long or rv != .Long) return null;
    const a = lv.Long;
    const n: u6 = @truncate(@as(u64, @bitCast(rv.Long)));
    return switch (op) {
        .Shl => .{ .Long = @bitCast(@as(u64, @bitCast(a)) << n) },
        .Shr => .{ .Long = a >> n },
        .UShr => .{ .Long = @bitCast(@as(u64, @bitCast(a)) >> n) },
        else => null,
    };
}

/// Floating-point operands as `applyBinop` computes them: same-type Double
/// and Float, and a Double against an integer, which widens for arithmetic
/// and ordering; null for the rest, the kind-keeping boxed equality and a
/// Double against a Float included (`scalarBin` answers that one).
pub inline fn floatScalarBin(op: BinOp, lv: Value, rv: Value) ?Value {
    if (lv == .Double and rv == .Double) return floatBin(f64, op, lv.Double, rv.Double);
    if (lv == .Float and rv == .Float) return floatBin(f32, op, lv.Float, rv.Float);
    const a: f64 = switch (lv) {
        .Double => |x| x,
        .Int => |x| @floatFromInt(x),
        .Long => |x| @floatFromInt(x),
        else => return null,
    };
    const b: f64 = switch (rv) {
        .Double => |x| x,
        .Int => |x| @floatFromInt(x),
        .Long => |x| @floatFromInt(x),
        else => return null,
    };
    if (lv != .Double and rv != .Double) return null;
    return switch (op) {
        .Eq, .NotEq, .BoxedEq, .BoxedNotEq => null,
        else => floatBin(f64, op, a, b),
    };
}

/// `floatBin` but for `%`, whose `@rem` is a call: what an op's fast path computes with no call
/// in it.
pub inline fn floatBinQuick(comptime F: type, op: BinOp, a: F, b: F) ?Value {
    const wrap = struct {
        inline fn v(x: F) Value {
            return if (F == f64) .{ .Double = x } else .{ .Float = x };
        }
    }.v;
    return switch (op) {
        .Add => wrap(a + b),
        .Sub => wrap(a - b),
        .Mul => wrap(a * b),
        .Div => wrap(a / b),
        .Less => .{ .Bool = a < b },
        .LessEq => .{ .Bool = a <= b },
        .Greater => .{ .Bool = a > b },
        .GreaterEq => .{ .Bool = a >= b },
        .Eq => .{ .Bool = a == b },
        .NotEq => .{ .Bool = a != b },
        else => null,
    };
}

pub fn floatBin(comptime F: type, op: BinOp, a: F, b: F) ?Value {
    const wrap = struct {
        fn v(x: F) Value {
            return if (F == f64) .{ .Double = x } else .{ .Float = x };
        }
    }.v;
    return switch (op) {
        .Add => wrap(a + b),
        .Sub => wrap(a - b),
        .Mul => wrap(a * b),
        .Div => wrap(a / b),
        .Mod => wrap(@rem(a, b)),
        .Less => .{ .Bool = a < b },
        .LessEq => .{ .Bool = a <= b },
        .Greater => .{ .Bool = a > b },
        .GreaterEq => .{ .Bool = a >= b },
        .Eq => .{ .Bool = a == b },
        .NotEq => .{ .Bool = a != b },
        else => null,
    };
}

/// `applyUnop`'s exact semantics for the scalar tags; null for everything else,
/// including the widening `Byte`/`Short` negations and the NaN sign rules the
/// arm spells out.
pub inline fn scalarUn(op: ir.UnOp, v: Value) ?Value {
    return switch (op) {
        .Inc => switch (v) {
            .Int => |i| .{ .Int = i +% 1 },
            .Long => |l| .{ .Long = l +% 1 },
            .Char => |c| .{ .Char = c +% 1 },
            .UInt => |x| .{ .UInt = x +% 1 },
            .ULong => |x| .{ .ULong = x +% 1 },
            else => null,
        },
        .Dec => switch (v) {
            .Int => |i| .{ .Int = i -% 1 },
            .Long => |l| .{ .Long = l -% 1 },
            .Char => |c| .{ .Char = c -% 1 },
            .UInt => |x| .{ .UInt = x -% 1 },
            .ULong => |x| .{ .ULong = x -% 1 },
            else => null,
        },
        .Neg => switch (v) {
            .Int => |i| .{ .Int = -%i },
            .Long => |l| .{ .Long = -%l },
            else => null,
        },
        .Plus => switch (v) {
            .Int, .Long, .Double, .Float => v,
            else => null,
        },
        // A conversion is the `conv` op's.
        else => null,
    };
}

/// The shared same-tag scalar BinOp core with `applyBinop`'s exact semantics. Null for
/// every shape the generic arm must handle (mixed non-integer tags, zero divisors,
/// boxed equality on mixed widths, Cells, ===).
pub inline fn scalarBin(op: BinOp, lv: Value, rv: Value) ?Value {
    return if (lv == .Int and rv == .Int) blk: {
        const a = lv.Int;
        const b = rv.Int;
        break :blk switch (op) {
            .Add => .{ .Int = a +% b },
            .Sub => .{ .Int = a -% b },
            .Mul => .{ .Int = a *% b },
            .Div => if (b == 0) break :blk null else .{ .Int = divTruncI32(a, b) },
            .Mod => if (b == 0) break :blk null else .{ .Int = remTruncI32(a, b) },
            .Less => .{ .Bool = a < b },
            .LessEq => .{ .Bool = a <= b },
            .Greater => .{ .Bool = a > b },
            .GreaterEq => .{ .Bool = a >= b },
            .Eq, .BoxedEq => .{ .Bool = a == b },
            .NotEq, .BoxedNotEq => .{ .Bool = a != b },
            .And => .{ .Int = a & b },
            .Or => .{ .Int = a | b },
            .Xor => .{ .Int = a ^ b },
            .Shl => .{ .Int = @as(i32, @bitCast(@as(u32, @bitCast(a)) << @as(u5, @intCast(@as(u32, @bitCast(b)) & 31)))) },
            .Shr => .{ .Int = a >> @as(u5, @intCast(@as(u32, @bitCast(b)) & 31)) },
            .UShr => .{ .Int = @as(i32, @bitCast(@as(u32, @bitCast(a)) >> @as(u5, @intCast(@as(u32, @bitCast(b)) & 31)))) },
            else => break :blk null,
        };
    } else if (lv == .Long and rv == .Long) blk: {
        const a = lv.Long;
        const b = rv.Long;
        break :blk switch (op) {
            .Add => .{ .Long = a +% b },
            .Sub => .{ .Long = a -% b },
            .Mul => .{ .Long = a *% b },
            .Div => if (b == 0) break :blk null else .{ .Long = divTruncI64(a, b) },
            .Mod => if (b == 0) break :blk null else .{ .Long = remTruncI64(a, b) },
            .Less => .{ .Bool = a < b },
            .LessEq => .{ .Bool = a <= b },
            .Greater => .{ .Bool = a > b },
            .GreaterEq => .{ .Bool = a >= b },
            .Eq, .BoxedEq => .{ .Bool = a == b },
            .NotEq, .BoxedNotEq => .{ .Bool = a != b },
            .And => .{ .Long = a & b },
            .Or => .{ .Long = a | b },
            .Xor => .{ .Long = a ^ b },
            else => break :blk null,
        };
    } else if (lv == .Bool and rv == .Bool) blk: {
        break :blk switch (op) {
            .And => .{ .Bool = lv.Bool and rv.Bool },
            .Or => .{ .Bool = lv.Bool or rv.Bool },
            .Xor => .{ .Bool = lv.Bool != rv.Bool },
            .Eq, .BoxedEq => .{ .Bool = lv.Bool == rv.Bool },
            .NotEq, .BoxedNotEq => .{ .Bool = lv.Bool != rv.Bool },
            else => break :blk null,
        };
    } else if ((lv == .Double and rv == .Float) or (lv == .Float and rv == .Double)) blk: {
        // A Double against a Float compares as Double under IEEE, so `0.0 != -0.0F` is false.
        // Boxed equality stays tag-sensitive and falls through.
        const a: f64 = if (lv == .Double) lv.Double else @floatCast(lv.Float);
        const b: f64 = if (rv == .Double) rv.Double else @floatCast(rv.Float);
        break :blk switch (op) {
            .Less => .{ .Bool = a < b },
            .LessEq => .{ .Bool = a <= b },
            .Greater => .{ .Bool = a > b },
            .GreaterEq => .{ .Bool = a >= b },
            .Eq => .{ .Bool = a == b },
            .NotEq => .{ .Bool = a != b },
            else => break :blk null,
        };
    } else if ((lv == .Int or lv == .Long) and (rv == .Int or rv == .Long)) blk: {
        // Mixed widths promote to Long, as `applyBinop` does. Boxed equality stays
        // tag-sensitive (`(1 as Any) != (1L as Any)`) and falls through.
        const a: i64 = if (lv == .Int) lv.Int else lv.Long;
        const b: i64 = if (rv == .Int) rv.Int else rv.Long;
        break :blk switch (op) {
            .Add => .{ .Long = a +% b },
            .Sub => .{ .Long = a -% b },
            .Mul => .{ .Long = a *% b },
            .Div => if (b == 0) break :blk null else .{ .Long = divTruncI64(a, b) },
            .Mod => if (b == 0) break :blk null else .{ .Long = remTruncI64(a, b) },
            .Less => .{ .Bool = a < b },
            .LessEq => .{ .Bool = a <= b },
            .Greater => .{ .Bool = a > b },
            .GreaterEq => .{ .Bool = a >= b },
            .Eq => .{ .Bool = a == b },
            .NotEq => .{ .Bool = a != b },
            // The logical trio lowers to a BinOp only when the static types agree, but a literal's
            // runtime tag can be narrower than its declared Long: compute wide.
            .And => .{ .Long = a & b },
            .Or => .{ .Long = a | b },
            .Xor => .{ .Long = a ^ b },
            // Long shifts take an Int count and use its low 6 bits, JVM-style.
            .Shl => if (lv == .Long) .{ .Long = @as(i64, @bitCast(@as(u64, @bitCast(a)) << @as(u6, @intCast(@as(u64, @bitCast(b)) & 63)))) } else break :blk null,
            .Shr => if (lv == .Long) .{ .Long = a >> @as(u6, @intCast(@as(u64, @bitCast(b)) & 63)) } else break :blk null,
            .UShr => if (lv == .Long) .{ .Long = @as(i64, @bitCast(@as(u64, @bitCast(a)) >> @as(u6, @intCast(@as(u64, @bitCast(b)) & 63)))) } else break :blk null,
            else => break :blk null,
        };
    } else null;
}

/// `x op k` for a register and the constant a `bin_k` or `cmp_br_k` carries,
/// with `applyBinop`'s semantics: `kw` is the op's kind word, `lo` and `hi`
/// the constant's bits. Null for a register of another type and every shape
/// the op's general path computes (a zero divisor, a mixed boxed equality).
pub inline fn binK(kw: u32, x: Value, lo: u32, hi: u32) ?Value {
    const op: BinOp = @enumFromInt(kw & 0xff);
    const bits = @as(u64, hi) << 32 | lo;
    return switch (@as(bc.KType, @enumFromInt((kw >> 8) & 0xff))) {
        .int => switch (x) {
            .Int, .Long => scalarBin(op, x, .{ .Int = @bitCast(lo) }),
            else => null,
        },
        .long => switch (x) {
            .Long => scalarBin(op, x, .{ .Long = @bitCast(bits) }) orelse longShift(op, x, .{ .Long = @bitCast(bits) }),
            .Int => scalarBin(op, x, .{ .Long = @bitCast(bits) }),
            else => null,
        },
        .float => if (x == .Float) floatBin(f32, op, x.Float, @bitCast(lo)) else null,
        .double => if (x == .Double) floatBin(f64, op, x.Double, @bitCast(bits)) else null,
        .ulong => if (x == .ULong) unsignedEq(op, x.ULong == bits) else null,
        .uint => if (x == .UInt) unsignedEq(op, x.UInt == lo) else null,
        .null => if (x == .Cell) null else nullEq(op, x == .Null),
    };
}

/// A comparison with `null`: `==`, its boxed form and `===` hold for a null value, the negated
/// forms for any other.
pub inline fn nullEq(op: BinOp, is_null: bool) ?Value {
    return switch (op) {
        .Eq, .BoxedEq, .IdentEq => .{ .Bool = is_null },
        .NotEq, .BoxedNotEq, .IdentNeq => .{ .Bool = !is_null },
        else => null,
    };
}

pub inline fn unsignedEq(op: BinOp, eq: bool) ?Value {
    return switch (op) {
        .Eq, .BoxedEq => .{ .Bool = eq },
        .NotEq, .BoxedNotEq => .{ .Bool = !eq },
        else => null,
    };
}

/// The constant a `bin_k` carries, as its Const loads it.
pub inline fn kValue(kw: u32, lo: u32, hi: u32) Value {
    const bits = @as(u64, hi) << 32 | lo;
    return switch (@as(bc.KType, @enumFromInt((kw >> 8) & 0xff))) {
        .int => .{ .Int = @bitCast(lo) },
        .long => .{ .Long = @bitCast(bits) },
        .float => .{ .Float = @bitCast(lo) },
        .double => .{ .Double = @bitCast(bits) },
        .ulong => .{ .ULong = bits },
        .uint => .{ .UInt = lo },
        .null => .Null,
    };
}

