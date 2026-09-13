//! The flat-call loop and its trampoline: the driver that runs a chain of
//! activations without native recursion.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const span = @import("span");
const jit_loop = @import("../jit_loop.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;

const BlockId = ir.BlockId;
const FuncId = ir.FuncId;
const Module = ir.Module;
const Reg = ir.Reg;
const TypeRef = ir.TypeRef;

const exec_call = @import("../exec_call.zig");

const ev_activation = @import("activation.zig");
const ev_chain = @import("chain.zig");
const ev_diag = @import("diag.zig");
const ev_enter = @import("enter.zig");
const ev_exec = @import("exec.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_fused = @import("fused.zig");
const ev_inst = @import("inst.zig");
const ev_leaf = @import("leaf.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");

const Activation = ev_flow.Activation;
const EvalError = ev_state.EvalError;
const EvalResult = ev_flow.EvalResult;
const EvalTls = ev_state.EvalTls;
const FlatCallSite = ev_flow.FlatCallSite;
const Frame = ev_frame.Frame;
const NATIVE_SLOT_BANK_DEPTH = ev_state.NATIVE_SLOT_BANK_DEPTH;
const ParkPoint = ev_flow.ParkPoint;
const TryFrame = ev_snapshot.TryFrame;
const actFree = ev_activation.actFree;
const discardFlatReq = ev_activation.discardFlatReq;
const dumpFrameChainForDiag = ev_diag.dumpFrameChainForDiag;
const execInst = ev_inst.execInst;
const frameBoundary = ev_enter.frameBoundary;
const funcOwnedBy = ev_enter.funcOwnedBy;
const fusedExecOpt = ev_fused.fusedExecOpt;
const leafExprServe = ev_enter.leafExprServe;
const leafReqServable = ev_leaf.leafReqServable;
const liveParkActivation = ev_activation.liveParkActivation;
const maxEvalDepth = ev_chain.maxEvalDepth;
const ok = ev_flow.ok;
const openActivation = ev_activation.openActivation;
const popEnclosing = ev_chain.popEnclosing;
const pushEnclosingAccess = ev_chain.pushEnclosingAccess;
const runFrameExec = ev_exec.runFrameExec;
const snapshotSuspendedFrame = ev_activation.snapshotSuspendedFrame;
const teardownActivation = ev_activation.teardownActivation;

/// The driver core. `root_act` is set when the root frame is itself a
/// resumed live activation — a suspension then live-parks the root too
/// instead of snapshotting it (the caller relinquished ownership).
pub fn runFlatLoop(
    comptime H: type,
    allocator: Allocator,
    frame: *Frame,
    try_stack: *std.ArrayList(TryFrame),
    cur_in: BlockId,
    resume_idx_in: usize,
    resume_throw_in: ?Value,
    resume_unwind_in: ?EvalError,
    root_act: ?*Activation,
    host: *H,
) Allocator.Error!EvalResult {
    const ev: *EvalTls = &ev_state.evtls;
    var stack: std.ArrayList(*Activation) = .empty;
    defer stack.deinit(allocator);
    // On an allocation failure, unwind every open activation so no frame is
    // left dangling on the GC chain.
    errdefer while (stack.pop()) |act| {
        ev.eval_depth -= 1;
        teardownActivation(H, allocator, act, host);
        actFree(ev, allocator, act);
    };
    var cur = cur_in;
    var ridx = resume_idx_in;
    var rthrow = resume_throw_in;
    var runwind = resume_unwind_in;
    while (true) {
        const f: *Frame = if (stack.items.len > 0) &stack.items[stack.items.len - 1].frame else frame;
        const ts: *std.ArrayList(TryFrame) = if (stack.items.len > 0) &stack.items[stack.items.len - 1].try_stack else try_stack;
        var flat_site: ?FlatCallSite = null;
        var park_out: ?ParkPoint = null;
        var res = try runFrameExec(H, allocator, f.module, f, ts, cur, ridx, rthrow, runwind, &flat_site, &park_out, host);
        rthrow = null;
        runwind = null;
        if (flat_site) |site| {
            // A leaf-expression callee needs none of the activation: serve it
            // here and deliver its value straight into the caller's register.
            // This is the seam every direct call passes through, so it covers
            // plain calls the member and getter entries never see.
            // The module the callee's body must be READ against. A request
            // that names one is authoritative; otherwise the caller's module
            // is right only when it actually owns this `Func`. An anonymous
            // object's runtime module delegates base funcs through the shared
            // lazy header section but carries only its own const pool, so a
            // callee reached from there would read const ids outside it.
            const callee_mod: *const Module = site.req.run_module orelse blk_cm: {
                if (funcOwnedBy(f.module, site.req.func)) break :blk_cm f.module;
                if (comptime @hasDecl(H, "ownerModuleForFunc")) {
                    if (host.ownerModuleForFunc(site.req.func)) |m| break :blk_cm m;
                }
                break :blk_cm f.module;
            };
            // A host-served compose helper answers before any activation
            // opens, on the flat path as well as the recursive seam: the
            // composer's stacks are reached through both. A pending
            // enclosing pop or chain seed is fine — `discardFlatReq` undoes
            // everything the request set up.
            if (site.req.captures.items.len == 0 and site.req.closure_id == null and
                site.req.type_args.len == 0 and !site.req.composer_pushed)
            {
                // The seam method tier on the flat path: a deopt-free
                // compiled method body serves the request natively (RETURN
                // is its only outcome). Counting/compiling stays on the
                // recursive seam; this arm only RUNS an already-compiled one.
                if (comptime @hasDecl(H, "plainStoredFieldIndex")) run: {
                    const cl = jit_loop.methodSeamPeek(site.req.func) orelse break :run;
                    if (site.req.args.items.len < site.req.func.params.len or
                        ev_state.evtls.jit_native_depth >= NATIVE_SLOT_BANK_DEPTH or cl.n_slots > 192) break :run;
                    const fslots: []i64 = &ev_state.native_slot_bank[ev_state.evtls.jit_native_depth];
                    const ftags: []u8 = &ev_state.native_tag_bank[ev_state.evtls.jit_native_depth];
                    ev_state.evtls.jit_native_depth += 1;
                    const fo = jit_loop.runFunc(cl, &.{}, site.req.args.items, fslots[0..cl.n_slots], ftags[0..cl.n_regs], null, null);
                    ev_state.evtls.jit_native_depth -= 1;
                    if (fo) |o| {
                        if (o.code.inst == jit_loop.RETURN_INST) {
                            const dst = site.req.dst;
                            discardFlatReq(H, allocator, site.req, host);
                            try f.write(dst, o.value);
                            cur = site.ret_block;
                            ridx = site.ret_idx;
                            continue;
                        }
                    }
                }
                if (exec_call.hostRouteServe(H, allocator, site.req.func, site.req.args.items, host)) |served| {
                    const dst = site.req.dst;
                    discardFlatReq(H, allocator, site.req, host);
                    try f.write(dst, served);
                    cur = site.ret_block;
                    ridx = site.ret_idx;
                    continue;
                }
                if (try exec_call.hostRouteServeThrowing(H, allocator, callee_mod, site.req.func, site.req.args.items, host)) |r| {
                    const dst = site.req.dst;
                    discardFlatReq(H, allocator, site.req, host);
                    switch (r) {
                        .ok => |v| {
                            try f.write(dst, v);
                            cur = site.ret_block;
                            ridx = site.ret_idx;
                            continue;
                        },
                        .err => |e| switch (e) {
                            .Throw => |v| {
                                rthrow = v;
                                cur = site.ret_block;
                                ridx = site.ret_idx;
                                continue;
                            },
                            else => {
                                runwind = e;
                                cur = site.ret_block;
                                ridx = site.ret_idx;
                                continue;
                            },
                        },
                    }
                }
            }
            if (site.req.captures.items.len == 0 and site.req.closure_id == null and
                site.req.type_args.len == 0 and !site.req.composer_pushed and
                site.req.chain.len == 0)
            fused: {
                const callee_mod2 = blk_cm2: {
                    if (funcOwnedBy(f.module, site.req.func)) break :blk_cm2 f.module;
                    if (comptime @hasDecl(H, "ownerModuleForFunc")) {
                        if (host.ownerModuleForFunc(site.req.func)) |m| break :blk_cm2 m;
                    }
                    break :blk_cm2 f.module;
                };
                const fr = (try fusedExecOpt(H, allocator, callee_mod2, site.req.func, site.req.args.items, host, true)) orelse break :fused;
                const dst = site.req.dst;
                discardFlatReq(H, allocator, site.req, host);
                switch (fr) {
                    .ok => |v| {
                        try f.write(dst, v);
                        cur = site.ret_block;
                        ridx = site.ret_idx;
                        continue;
                    },
                    .err => |e| switch (e) {
                        // The flat protocol: a throw re-enters the caller
                        // through `rthrow` so its catch handlers dispatch;
                        // only the non-catchable unwinds ride `runwind`.
                        .Throw => |v| {
                            rthrow = v;
                            cur = site.ret_block;
                            ridx = site.ret_idx;
                            continue;
                        },
                        else => {
                            runwind = e;
                            cur = site.ret_block;
                            ridx = site.ret_idx;
                            continue;
                        },
                    },
                }
            }
            if (leafReqServable(site.req)) {
                // A flat request carries the callee's `Func` directly, but the
                // module its body must be READ against is only known when the
                // request names one. Falling back to the caller's module is
                // wrong whenever the callee was resolved in a different one:
                // its const and func ids index that module's tables, and an
                // anonymous object's one-function runtime module has neither
                // (`androidx.compose.runtime.report`, id 15036, served against
                // a module of 1 func and 6 consts, read const 9028).
                if (try leafExprServe(H, allocator, callee_mod, site.req.func, site.req.args.items, host)) |lr| {
                    const dst = site.req.dst;
                    discardFlatReq(H, allocator, site.req, host);
                    try f.write(dst, lr.ok);
                    cur = site.ret_block;
                    ridx = site.ret_idx;
                    continue;
                }
            }
            // Same depth bound as the recursive path: an unbounded interpreted
            // recursion becomes a catchable StackOverflowError at the caller.
            if (ev.eval_depth >= maxEvalDepth()) {
                dumpFrameChainForDiag();
                discardFlatReq(H, allocator, site.req, host);
                runwind = .{ .StackOverflow = "Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)" };
                cur = site.ret_block;
                ridx = site.ret_idx;
                continue;
            }
            ev.eval_depth += 1;
            const act = openActivation(H, allocator, callee_mod, site.req, host) catch |e| {
                ev.eval_depth -= 1;
                return e;
            };
            act.ret_block = site.ret_block;
            act.ret_idx = site.ret_idx;
            stack.append(allocator, act) catch |e| {
                ev.eval_depth -= 1;
                teardownActivation(H, allocator, act, host);
                actFree(ev, allocator, act);
                return e;
            };
            cur = site.req.func.entry;
            ridx = 0;
            // Function-tier attempt for the fresh activation: the framed
            // entry hook lives only in runFrameExec's generic loop, and the
            // flat driver is the path member- and bc-driven calls actually
            // take. Function-mode bodies are suspension-free by
            // construction, so the outcomes are exactly RETURN (deliver as
            // the driver's own completion), a real throw, or a deopt that
            // resumes interpretation at the outcome point in this frame.
            if (comptime @hasDecl(H, "callFunc")) hook: {
                if (!jit_loop.funcEnabled()) break :hook;
                if (runtime.envOnce("KLIO_FJ_FLATHOOK")) |v| {
                    if (v.len != 0 and v[0] == '0') break :hook;
                }
                var hctx: LoopTramp(H).Ctx = .{ .host = host, .allocator = allocator, .module = act.frame.module, .frame = &act.frame };
                const mres: ?jit_loop.MemberResolver = if (comptime @hasDecl(H, "resolveMemberFuncId")) &LoopTramp(H).resolveMember else null;
                const vres: ?jit_loop.VirtResolver = if (comptime @hasDecl(H, "resolveVirtualFuncId")) &LoopTramp(H).resolveVirtual else null;
                const fres: ?jit_loop.FieldResolver = if (comptime @hasDecl(H, "plainStoredFieldIndex")) &LoopTramp(H).resolveField else null;
                const fnres: ?jit_loop.FieldResolver = if (comptime @hasDecl(H, "plainStoredScalarFieldNN")) &LoopTramp(H).resolveFieldNN else null;
                const fo = jit_loop.maybeRunHotFunc(act.frame.module, site.req.func, &act.frame.regs, act.frame.params.items, act.frame.captures.items, allocator, &LoopTramp(H).call, @ptrCast(&hctx), mres, vres, fres, fnres) orelse break :hook;
                if (fo.code.inst == jit_loop.RETURN_INST) {
                    var res2: EvalResult = ok(fo.value);
                    const act2 = stack.pop().?;
                    ev.eval_depth -= 1;
                    res2 = frameBoundary(act2.frame.func, res2);
                    if (act2.root_pump) {
                        if (comptime @hasDecl(H, "rootPumpFlatComplete")) {
                            res2 = try host.rootPumpFlatComplete(allocator, res2, act2.keepalive orelse .Unit, act2.barrier_scope_base);
                        }
                    }
                    if (act2.type_args.len > 0) {
                        if (comptime @hasDecl(H, "typedCallBoundary")) host.typedCallBoundary(act2.frame.module, act2.frame.func, act2.type_args, &res2);
                    }
                    const rb2 = act2.ret_block;
                    const rix2 = act2.ret_idx;
                    const rd2 = act2.ret_dst;
                    teardownActivation(H, allocator, act2, host);
                    actFree(ev, allocator, act2);
                    const pf2: *Frame = if (stack.items.len > 0) &stack.items[stack.items.len - 1].frame else frame;
                    switch (res2) {
                        .ok => |v| {
                            try pf2.write(rd2, v);
                            cur = rb2;
                            ridx = rix2;
                        },
                        .err => |e2| switch (e2) {
                            .Throw => |v| {
                                rthrow = v;
                                cur = rb2;
                                ridx = rix2;
                            },
                            else => {
                                runwind = e2;
                                cur = rb2;
                                ridx = rix2;
                            },
                        },
                    }
                    continue;
                }
                if (fo.code.inst == jit_loop.THROW_INST) {
                    if (runtime.envOnce("KLIO_JIT_DEBUG") != null) std.debug.print("[jit-dbg] flat THROW {s}\n", .{site.req.func.fqn});
                    const e2 = hctx.pending.?;
                    hctx.pending = null;
                    switch (e2) {
                        .Throw => |exc| {
                            rthrow = exc;
                            cur = fo.code.block;
                            ridx = 0;
                        },
                        else => {
                            runwind = e2;
                            cur = fo.code.block;
                            ridx = 0;
                        },
                    }
                    continue;
                }
                // Deopt: resume interpretation at the outcome point (the
                // frame's written scalar registers were reboxed by runFunc).
                // A handler-issued deopt carries the sentinel and records the
                // resume instruction on the context; a native one (div by
                // zero) encodes the instruction directly.
                if (runtime.envOnce("KLIO_JIT_DEBUG") != null) std.debug.print("[jit-dbg] flat DEOPT {s} b={d} i={d}\n", .{ site.req.func.fqn, fo.code.block, fo.code.inst });
                cur = fo.code.block;
                ridx = if (fo.code.inst == jit_loop.DEOPT_INST) hctx.pending_deopt_inst else fo.code.inst;
            }
            continue;
        }
        // A suspension: park the current frame at its own suspension point,
        // then every outer activation at its recorded call-return point,
        // preserving the innermost-first order of the recursive path. Flat
        // activations park LIVE — the intact frame moves into the state by
        // pointer, no copies — and only a native root frame snapshots.
        if (park_out) |pp| {
            const state = res.err.Suspended;
            var pb = pp.block;
            var pi = pp.inst_idx;
            var pd = pp.resume_reg;
            var barrier_hit = false;
            while (stack.pop()) |a| {
                ev.eval_depth -= 1;
                const is_barrier = a.suspend_barrier;
                const is_root_pump = a.root_pump;
                const scope_base = a.barrier_scope_base;
                const scope_keep: Value = a.keepalive orelse .Unit;
                const rb = a.ret_block;
                const rix = a.ret_idx;
                const rd = a.ret_dst;
                try liveParkActivation(H, allocator, a, pb, pi, pd, state, host);
                if (is_root_pump) {
                    // No-driver root: park the root into ITS OWN pump,
                    // drain the pump to quiescence (persisting an
                    // unresumed root), and continue the caller with the
                    // resumed value or COROUTINE_SUSPENDED.
                    if (comptime @hasDecl(H, "rootPumpBarrierPark")) {
                        const r = try host.rootPumpBarrierPark(allocator, state, scope_keep, scope_base);
                        const pf2: *Frame = if (stack.items.len > 0) &stack.items[stack.items.len - 1].frame else frame;
                        switch (r) {
                            .ok => |v| try pf2.write(rd, v),
                            .err => |e| switch (e) {
                                .Throw => |v| rthrow = v,
                                else => runwind = e,
                            },
                        }
                        cur = rb;
                        ridx = rix;
                        barrier_hit = true;
                        break;
                    }
                }
                if (is_barrier) {
                    // The undispatched-start boundary: the parked segment
                    // belongs to the enclosing pump, and the CALLER
                    // continues with the hook's value (COROUTINE_SUSPENDED)
                    // — the defining startCoroutineUninterceptedOrReturn
                    // split. Ownership of `state` moves to the pump.
                    const v: Value = if (comptime @hasDecl(H, "undispatchedBarrierPark"))
                        try host.undispatchedBarrierPark(allocator, state, scope_base)
                    else
                        Value.CoroutineSuspended;
                    const pf2: *Frame = if (stack.items.len > 0) &stack.items[stack.items.len - 1].frame else frame;
                    try pf2.write(rd, v);
                    cur = rb;
                    ridx = rix;
                    barrier_hit = true;
                    break;
                }
                pb = rb;
                pi = rix;
                pd = rd;
            }
            if (barrier_hit) continue;
            if (root_act) |ra| {
                try liveParkActivation(H, allocator, ra, pb, pi, pd, state, host);
            } else {
                try snapshotSuspendedFrame(allocator, frame, try_stack, pb, pi, pd, state);
            }
            return res;
        }
        // The current frame exited; deliver its result to the calling
        // activation, applying the callee-boundary transforms each popped
        // frame's result crosses.
        deliver: while (true) {
            if (stack.items.len == 0) return res;
            const act = stack.pop().?;
            ev.eval_depth -= 1;
            res = frameBoundary(act.frame.func, res);
            // A no-driver root's completion runs its pump to quiescence
            // (launched children, timers) before the caller sees the
            // result — the recursive branch's tail, guard still pushed.
            if (act.root_pump) {
                if (comptime @hasDecl(H, "rootPumpFlatComplete")) {
                    res = try host.rootPumpFlatComplete(allocator, res, act.keepalive orelse .Unit, act.barrier_scope_base);
                }
            }
            if (act.type_args.len > 0) {
                if (comptime @hasDecl(H, "typedCallBoundary")) host.typedCallBoundary(act.frame.module, act.frame.func, act.type_args, &res);
            }
            const rb = act.ret_block;
            const rix = act.ret_idx;
            const rd = act.ret_dst;
            teardownActivation(H, allocator, act, host);
            actFree(ev, allocator, act);
            const pf: *Frame = if (stack.items.len > 0) &stack.items[stack.items.len - 1].frame else frame;
            switch (res) {
                .ok => |v| {
                    try pf.write(rd, v);
                    cur = rb;
                    ridx = rix;
                    break :deliver;
                },
                .err => |e| switch (e) {
                    .Throw => |v| {
                        rthrow = v;
                        cur = rb;
                        ridx = rix;
                        break :deliver;
                    },
                    .NonLocalReturn, .LabeledReturn, .CalleeFailed, .StackOverflow => {
                        runwind = e;
                        cur = rb;
                        ridx = rix;
                        break :deliver;
                    },
                    // Anything else exits the calling frame as-is (matching
                    // the recursive raised-switch's default arm); keep
                    // popping so each crossed frame's boundary applies.
                    else => {},
                },
            }
        }
    }
}

pub fn typeRefName(name: []const u8) TypeRef {
    return .{ .name = name, .nullable = false, .args = &.{} };
}

/// The loop JIT's call trampoline, specialized per host. A compiled loop's native
/// call site invokes `call` with the loop's `TrampCtx` and a site index; it reboxes
/// the scalar args from the slot file, runs the callee through `host.callFunc`, and
/// reboxes a scalar result back into the dst slot. Returns 0 to continue the native
/// loop, or `THROW_INST`'s resume code with the error stashed in `Ctx.pending` for
/// the interpreter to re-raise (a throw routes through the try-stack; any other
/// error propagates out of the frame, matching the interpreted call exactly).
pub fn LoopTramp(comptime H: type) type {
    return struct {
        pub const Ctx = struct {
            host: *H,
            allocator: Allocator,
            module: *const Module,
            frame: *Frame,
            pending: ?EvalError = null,
            pending_deopt_inst: u32 = 0,
            /// Set alongside `pending` when a trampolined callee SUSPENDED:
            /// the call site's instruction index and result register, so the
            /// interpreter can park this frame at the call exactly as the
            /// interpreted path would (block, inst+1, resume reg). Without
            /// it the suspension propagated as a plain error and the loop
            /// frame fell out of the continuation — a JITted `for` sending
            /// into a channel silently lost every element after the tier-up.
            pending_suspend_inst: u32 = 0,
            pending_suspend_dst: ?Reg = null,
        };

        fn stashErr(lc: *Ctx, e: EvalError, inst: u32, dst: ?Reg) void {
            lc.pending = e;
            if (e == .Suspended) {
                lc.pending_suspend_inst = inst;
                lc.pending_suspend_dst = dst;
            }
        }

        /// The trampoline's BULKY non-call sites (field write, subscript, value call,
        /// map get/set). Zig does not reclaim block-scoped stack allocations
        /// (ziglang/zig#23475), so their locals sat in `call`'s frame — and `call` is
        /// the frame held LIVE across the interpreter's recursion (once a function is
        /// JIT'd the recursive call runs native code -> this trampoline -> `callFunc`,
        /// so `runFrameInner` is not even on the path). Outlining them lifted the
        /// recursion ceiling ~13%.
        ///
        /// The three TINY hot sites (object move, null test, field read) deliberately
        /// stay inline in `call`: they fire once per JIT'd loop iteration, and
        /// outlining them too cost ~3% throughput for no extra depth.
        /// ESCAPE: run the interpreter's own arm for one instruction against
        /// the live frame. Full scalar sync both ways — before: every
        /// scalar-typed register's slot reboxes into the frame; after: each
        /// reboxes back (a kind change deopts AT THE NEXT instruction — the
        /// arm's effects are real and the frame is already correct).
        noinline fn execEscapeSite(tctx: *jit_loop.TrampCtx, lc: *Ctx, cl: anytype, site: anytype) ?u64 {
            const n = cl.n_regs;
            var r: u32 = 0;
            while (r < n) : (r += 1) {
                switch (cl.reg_types[r]) {
                    .i32, .i64, .f64, .f32, .boolean => {
                        if (r < lc.frame.regs.items.len)
                            lc.frame.regs.items[r] = jit_loop.valueFromSlotTagged(cl.reg_types[r], tctx.tags[r], tctx.slots[r]);
                    },
                    else => {},
                }
            }
            if (site.span) |sp| lc.frame.cur_span = sp;
            const step = execInst(H, lc.allocator, lc.frame, site.exec_inst.?, lc.host) catch {
                lc.pending = .{ .Type = "out of memory in JIT escape" };
                return jit_loop.throwCode(site.block);
            };
            switch (step) {
                .cont => {},
                .raised => {
                    const e = lc.frame.step_err.?;
                    lc.frame.step_err = null;
                    stashErr(lc, e, site.inst, null);
                    return jit_loop.throwCode(site.block);
                },
                .flat_call => {
                    // The arm prepared a flat request but ran nothing:
                    // discard it and deopt AT this instruction so the
                    // interpreter re-runs it with its own flat machinery.
                    const req = lc.frame.flat_call.?;
                    lc.frame.flat_call = null;
                    discardFlatReq(H, lc.allocator, req, lc.host);
                    lc.pending_deopt_inst = site.inst;
                    return jit_loop.deoptCode(site.block);
                },
            }
            r = 0;
            while (r < n) : (r += 1) {
                switch (cl.reg_types[r]) {
                    .i32, .i64, .f64, .f32, .boolean => {
                        if (r >= lc.frame.regs.items.len) continue;
                        const v = lc.frame.regs.items[r];
                        const sv = jit_loop.cellSlotIn(cl.reg_types[r], v) orelse {
                            lc.pending_deopt_inst = site.inst + 1;
                            return jit_loop.deoptCode(site.block);
                        };
                        tctx.slots[r] = sv;
                        if (cl.reg_types[r] == .i32) tctx.tags[r] = @intFromEnum(std.meta.activeTag(v));
                    },
                    else => {},
                }
            }
            return 0;
        }

        noinline fn bulkySite(tctx: *jit_loop.TrampCtx, lc: *Ctx, cl: anytype, site: anytype) ?u64 {
            if (site.is_field_set) {
                const recv = lc.frame.regs.items[site.recv_reg];
                if (recv != .Instance or (site.recv_varies and jit_loop.instanceClassIdentity(recv) != site.recv_class)) {
                    lc.pending_deopt_inst = site.inst;
                    return jit_loop.deoptCode(site.block);
                }
                const v = switch (cl.reg_types[site.src_reg]) {
                    .object => lc.frame.regs.items[site.src_reg],
                    .null_ => Value.Null,
                    else => jit_loop.valueFromSlotTagged(cl.reg_types[site.src_reg], tctx.tags[site.src_reg], tctx.slots[site.src_reg]),
                };
                const g = recv.Instance.borrowMut();
                if (site.field_idx < g.get().fields.items.len) {
                    const old = g.get().fields.items[site.field_idx].value;
                    g.get().fields.items[site.field_idx].value = v;
                    g.deinit();
                    old.release(lc.allocator);
                } else {
                    g.deinit();
                    lc.pending_deopt_inst = site.inst;
                    return jit_loop.deoptCode(site.block);
                }
                return 0;
            }
            // Object collection subscript: read element `recv[idx]` directly (no
            // `get` dispatch) and write it into the register. Out-of-range or an
            // unsupported container deopts; the interpreter re-runs the subscript
            // (a side-effect-free read) and raises the proper exception on OOB.
            if (site.is_obj_index) {
                const recv = lc.frame.regs.items[site.recv_reg];
                const idx_v = jit_loop.valueFromSlotTagged(cl.reg_types[site.args_reg], tctx.tags[site.args_reg], tctx.slots[site.args_reg]);
                const idx: i64 = switch (idx_v) {
                    .Int => |x| x,
                    .Long => |x| x,
                    else => {
                        lc.pending_deopt_inst = site.inst;
                        return jit_loop.deoptCode(site.block);
                    },
                };
                if (jit_loop.liveElementAt(recv, idx)) |v| {
                    v.retain();
                    lc.frame.write(Reg.from(site.dst_reg), v) catch {
                        lc.pending = .{ .Type = "out of memory in JIT subscript" };
                        return jit_loop.throwCode(site.block);
                    };
                    return 0;
                }
                lc.pending_deopt_inst = site.inst;
                return jit_loop.deoptCode(site.block);
            }
            // Invoke a loop-invariant callable value; the result is discarded.
            if (site.is_call_value) {
                if (comptime !@hasDecl(H, "callValue")) return jit_loop.deoptCode(site.block);
                if (site.span) |sp| lc.frame.cur_span = sp;
                const callee = lc.frame.regs.items[site.recv_reg];
                var argbuf2: [6]Value = undefined;
                var k2: usize = 0;
                while (k2 < site.n_args) : (k2 += 1) {
                    const ar = @as(usize, site.args_reg) + k2;
                    const tr2: usize = if (k2 < 3 and site.arg_tag_regs[k2] != 0) site.arg_tag_regs[k2] else ar;
                    argbuf2[k2] = switch (cl.reg_types[ar]) {
                        .object => lc.frame.regs.items[ar],
                        .null_ => .Null,
                        else => jit_loop.valueFromSlotTagged(cl.reg_types[ar], tctx.tags[tr2], tctx.slots[ar]),
                    };
                }
                // Plain exact-arity closure: skip the value-dispatch preamble
                // and run the resolved body directly; a declined shape falls
                // through to the full route below.
                if (comptime @hasDecl(H, "callClosureFast")) {
                    if (callee == .IrClosure) {
                        const fr = lc.host.callClosureFast(lc.allocator, &callee, argbuf2[0..site.n_args]) catch {
                            lc.pending = .{ .Type = "out of memory in JIT value call" };
                            return jit_loop.throwCode(site.block);
                        };
                        if (fr) |r2| switch (r2) {
                            .ok => return 0,
                            .err => |e| {
                                stashErr(lc, e, site.inst, Reg.from(site.dst_reg));
                                return jit_loop.throwCode(site.block);
                            },
                        };
                    }
                }
                const r = lc.host.callValue(lc.allocator, &callee, argbuf2[0..site.n_args]) catch {
                    lc.pending = .{ .Type = "out of memory in JIT value call" };
                    return jit_loop.throwCode(site.block);
                };
                switch (r) {
                    .ok => return 0,
                    .err => |e| {
                        stashErr(lc, e, site.inst, Reg.from(site.dst_reg));
                        return jit_loop.throwCode(site.block);
                    },
                }
            }
            // Map store `map[key] = value`; result discarded.
            if (site.is_map_set) {
                if (comptime !@hasDecl(H, "callMemberNamed")) return jit_loop.deoptCode(site.block);
                if (site.span) |sp| lc.frame.cur_span = sp;
                const m = lc.frame.regs.items[site.recv_reg];
                const key = jit_loop.valueFromSlotTagged(cl.reg_types[site.args_reg], tctx.tags[site.args_reg], tctx.slots[site.args_reg]);
                const val = jit_loop.valueFromSlotTagged(cl.reg_types[site.src_reg], tctx.tags[site.src_reg], tctx.slots[site.src_reg]);
                var names: [2]?[]const u8 = .{ null, null };
                const r = lc.host.callMemberNamed(lc.allocator, &m, "set", &.{ key, val }, names[0..2]) catch {
                    lc.pending = .{ .Type = "out of memory in JIT map store" };
                    return jit_loop.throwCode(site.block);
                };
                switch (r) {
                    .ok => return 0,
                    .err => |e| {
                        stashErr(lc, e, site.inst, null);
                        return jit_loop.throwCode(site.block);
                    },
                }
            }
            // Map load `map[key]` -> nullable scalar (value slot + flag slot).
            if (site.is_map_get) {
                if (comptime !@hasDecl(H, "callMemberNamed")) return jit_loop.deoptCode(site.block);
                if (site.span) |sp| lc.frame.cur_span = sp;
                const m = lc.frame.regs.items[site.recv_reg];
                const key = jit_loop.valueFromSlotTagged(cl.reg_types[site.args_reg], tctx.tags[site.args_reg], tctx.slots[site.args_reg]);
                var names: [1]?[]const u8 = .{null};
                const r = lc.host.callMemberNamed(lc.allocator, &m, "get", &.{key}, names[0..1]) catch {
                    lc.pending = .{ .Type = "out of memory in JIT map load" };
                    return jit_loop.throwCode(site.block);
                };
                switch (r) {
                    .ok => |v| {
                        if (v == .Null) {
                            tctx.slots[site.dst_reg] = 0;
                            tctx.slots[site.map_flag_slot] = 1;
                        } else if (jit_loop.cellSlotIn(cl.reg_types[site.dst_reg], v)) |sv| {
                            tctx.slots[site.dst_reg] = sv;
                            tctx.slots[site.map_flag_slot] = 0;
                        } else {
                            // Value is not the cached scalar kind: deopt and re-read.
                            lc.pending_deopt_inst = site.inst;
                            return jit_loop.deoptCode(site.block);
                        }
                        return 0;
                    },
                    .err => |e| {
                        stashErr(lc, e, site.inst, Reg.from(site.dst_reg));
                        return jit_loop.throwCode(site.block);
                    },
                }
            }
            return null;
        }

        /// A compiled loop's native call site. The site's own work runs in
        /// `callSite`; on the way back the loop's array caches are refreshed,
        /// because the callee may have grown a backing store (moving the buffer)
        /// or rebound the receiver register, and the native code indexes the
        /// cache directly. A receiver that is no longer the array the loop was
        /// compiled for deopts to the instruction AFTER the call, whose effects
        /// have already happened.
        pub fn call(ctx_opaque: *anyopaque, site_idx: u64) callconv(.c) u64 {
            const code = callSite(ctx_opaque, site_idx);
            if (code != 0) return code;
            const tctx: *jit_loop.TrampCtx = @ptrCast(@alignCast(ctx_opaque));
            const cl = tctx.compiled;
            if (cl.arrays.len == 0) return 0;
            const lc: *Ctx = @ptrCast(@alignCast(tctx.user));
            if (jit_loop.reseedArrays(cl, lc.frame.regs.items, tctx.slots[0..cl.n_slots])) return 0;
            const site = cl.call_sites[@intCast(site_idx)];
            lc.pending_deopt_inst = site.inst + 1;
            return jit_loop.deoptCode(site.block);
        }

        fn callSite(ctx_opaque: *anyopaque, site_idx: u64) u64 {
            const tctx: *jit_loop.TrampCtx = @ptrCast(@alignCast(ctx_opaque));
            const lc: *Ctx = @ptrCast(@alignCast(tctx.user));
            const cl = tctx.compiled;
            const site = cl.call_sites[@intCast(site_idx)];
            if (site.is_exec) {
                if (execEscapeSite(tctx, lc, cl, site)) |code| return code;
                return 0;
            }
            // Object move: copy one boxed register into another (both in `regs`).
            // A `.null_`-typed source is the null literal, not a live register, so
            // write `.Null` directly (its slot-backed register is not maintained
            // during the native run).
            if (site.is_obj_move) {
                const v = if (cl.reg_types[site.src_reg] == .null_) Value.Null else lc.frame.regs.items[site.src_reg];
                v.retain();
                lc.frame.write(Reg.from(site.dst_reg), v) catch {
                    lc.pending = .{ .Type = "out of memory in JIT object move" };
                    return jit_loop.throwCode(site.block);
                };
                return 0;
            }
            if (site.is_load_global) {
                if (site.span) |sp| lc.frame.cur_span = sp;
                const loaded = lc.host.lookupGlobalThrowing(lc.allocator, site.name) catch {
                    lc.pending = .{ .Type = "out of memory in JIT global read" };
                    return jit_loop.throwCode(site.block);
                };
                switch (loaded) {
                    .ok => |maybe| if (maybe) |v| {
                        v.retain();
                        lc.frame.write(Reg.from(site.dst_reg), v) catch {
                            lc.pending = .{ .Type = "out of memory in JIT global read" };
                            return jit_loop.throwCode(site.block);
                        };
                        return 0;
                    },
                    .err => |e| {
                        stashErr(lc, e, site.inst, Reg.from(site.dst_reg));
                        return jit_loop.throwCode(site.block);
                    },
                }
                lc.pending_deopt_inst = site.inst;
                return jit_loop.deoptCode(site.block);
            }
            // Boxed structural/reference comparison: write a boolean to the
            // scalar destination while both values remain GC-rooted in regs.
            if (site.is_null_check) {
                const lhs = if (cl.reg_types[site.recv_reg] == .null_) Value.Null else lc.frame.regs.items[site.recv_reg];
                const rhs = if (cl.reg_types[site.src_reg] == .null_) Value.Null else lc.frame.regs.items[site.src_reg];
                const equal = if (site.identity) Value.referenceEq(&lhs, &rhs) else Value.structuralEq(&lhs, &rhs);
                const r = if (site.neg) !equal else equal;
                tctx.slots[site.dst_reg] = if (r) 1 else 0;
                return 0;
            }
            // A field read is a direct stored-field load — no host call, no side
            // effect, so a deopt is safe (the interpreter re-reads).
            if (site.is_field) {
                const recv = lc.frame.regs.items[site.recv_reg];
                // A by-name site resolves the stored index on the live
                // receiver per call (a getter property or missing member
                // deopts — the read is pure, the interpreter re-runs it).
                // A fixed-index site's varying boxed receiver may be a
                // different class this iteration (or null after a `?.` chain
                // step); deopt unless it matches.
                if (recv != .Instance or (!site.field_named and site.recv_varies and jit_loop.instanceClassIdentity(recv) != site.recv_class)) {
                    lc.pending_deopt_inst = site.inst;
                    return jit_loop.deoptCode(site.block);
                }
                const fidx: u32 = if (site.field_named) blk_fn: {
                    if (comptime !@hasDecl(H, "plainStoredFieldIndex")) {
                        lc.pending_deopt_inst = site.inst;
                        return jit_loop.deoptCode(site.block);
                    }
                    break :blk_fn lc.host.plainStoredFieldIndex(lc.allocator, &recv, site.name) orelse {
                        lc.pending_deopt_inst = site.inst;
                        return jit_loop.deoptCode(site.block);
                    };
                } else site.field_idx;
                const g = recv.Instance.borrow();
                const fv: ?Value = if (fidx < g.get().fields.items.len) g.get().fields.items[fidx].value else null;
                g.deinit();
                if (cl.reg_types[site.dst_reg] == .object) {
                    // Object field: write the boxed value straight into the frame.
                    const v = fv orelse .Null;
                    v.retain();
                    lc.frame.write(Reg.from(site.dst_reg), v) catch {
                        lc.pending = .{ .Type = "out of memory in JIT field read" };
                        return jit_loop.throwCode(site.block);
                    };
                    return 0;
                }
                const s = if (fv) |v| jit_loop.cellSlotIn(cl.reg_types[site.dst_reg], v) else null;
                if (s) |sv| {
                    tctx.slots[site.dst_reg] = sv;
                    if (cl.reg_types[site.dst_reg] == .i32) {
                        tctx.tags[site.dst_reg] = @intFromEnum(std.meta.activeTag(fv.?));
                    }
                    return 0;
                }
                // Field no longer the cached scalar (e.g. a nullable field went
                // null): deopt and let the interpreter re-read it.
                lc.pending_deopt_inst = site.inst;
                return jit_loop.deoptCode(site.block);
            }
            // Scalar field store: write the value directly into the boxed receiver's
            // stored field (a plain stored property — no custom setter).
            // Gate on the tag before CALLING the outlined helper: a member/func site
            // must not pay a call just to be told the site is not one of these.
            if (site.is_field_set or site.is_obj_index or site.is_call_value or
                site.is_map_set or site.is_map_get)
            {
                if (bulkySite(tctx, lc, cl, site)) |code| return code;
            }
            // The native loop does not run `.Trace`; refresh the calling frame's
            // position so a throw from the callee reports this call's line.
            if (site.span) |sp| lc.frame.cur_span = sp;
            var argbuf: [6]Value = undefined;
            var k: usize = 0;
            while (k < site.n_args) : (k += 1) {
                const ar = @as(usize, site.args_reg) + k;
                // The LIVE tag comes through the move chain's source: the
                // native code copies arg SLOTS without updating the tag
                // array (see CallSite.arg_tag_regs).
                const tr: usize = if (k < 3 and site.arg_tag_regs[k] != 0) site.arg_tag_regs[k] else ar;
                argbuf[k] = switch (cl.reg_types[ar]) {
                    .object => lc.frame.regs.items[ar],
                    .null_ => .Null,
                    else => jit_loop.valueFromSlotTagged(cl.reg_types[ar], tctx.tags[tr], tctx.slots[ar]),
                };
            }
            // Native recursion: a compiled body calling a compiled (scalar)
            // callee runs its body directly — no interpreter frame, no dispatch.
            // The callee is pure (scalar in, scalar out), so a deopt/throw can
            // safely fall back to the frame-based path by re-running it below.
            if (!site.is_member and !site.is_virtual and !runtime.shouldAbandon()) {
                if (lc.module.funcById(site.func)) |callee| {
                    // A callee only ever called from compiled code is never
                    // probed by the interpreter, so it stayed uncompiled and this
                    // site trampolined every iteration. The call is hot by
                    // construction; offer the body to the tier once.
                    const compiled_callee = jit_loop.compiledFunc(callee) orelse
                        jit_loop.compileCalleeForCall(lc.module, callee, argbuf[0..site.n_args], &resolveMember, &resolveVirtual, &resolveField, &resolveFieldNN, ctx_opaque);
                    if (compiled_callee) |callee_cl| {
                        if (!callee_cl.no_native_recurse and
                            ev_state.evtls.jit_native_depth < NATIVE_SLOT_BANK_DEPTH and callee_cl.n_slots <= 192)
                        {
                            // Per-depth rows from the thread's static bank: a
                            // stack `undefined` array here is 0xaa-filled per
                            // CALL under the safe build — it was 70% of a
                            // native fib's wall.
                            const fslots: []i64 = &ev_state.native_slot_bank[ev_state.evtls.jit_native_depth];
                            const ftags: []u8 = &ev_state.native_tag_bank[ev_state.evtls.jit_native_depth];
                            ev_state.evtls.jit_native_depth += 1;
                            const fo = jit_loop.runFunc(callee_cl, &.{}, argbuf[0..site.n_args], fslots[0..callee_cl.n_slots], ftags[0..callee_cl.n_regs], &call, tctx.user);
                            ev_state.evtls.jit_native_depth -= 1;
                            if (fo) |o| {
                                if (o.code.inst == jit_loop.RETURN_INST) {
                                    if (site.has_result) {
                                        tctx.slots[site.dst_reg] = jit_loop.cellSlotIn(cl.reg_types[site.dst_reg], o.value) orelse {
                                            lc.pending = .{ .Type = "JIT function returned a non-scalar result" };
                                            return jit_loop.throwCode(site.block);
                                        };
                                    }
                                    return 0;
                                }
                                // A deeper call threw: `lc.pending` is already set —
                                // propagate it out (do NOT re-run; the callee may have
                                // had effects), unwinding this native frame too.
                                if (o.code.inst == jit_loop.THROW_INST) return jit_loop.throwCode(site.block);
                            }
                            // Not run (param-kind mismatch / depth / oversized): the
                            // callee never executed, so the frame path runs it once.
                        }
                    }
                }
            }
            const res = if (site.is_virtual) virt: {
                if (comptime !@hasDecl(H, "invokeVirtualMember")) {
                    break :virt EvalResult{ .err = .{
                        .Type = "host cannot dispatch virtual calls",
                    } };
                }
                var recv = switch (cl.reg_types[site.recv_reg]) {
                    .object, .unknown => lc.frame.regs.items[site.recv_reg],
                    .null_ => Value.Null,
                    else => jit_loop.valueFromSlotTagged(cl.reg_types[site.recv_reg], tctx.tags[site.recv_reg], tctx.slots[site.recv_reg]),
                };
                recv.retain();
                defer recv.release(lc.allocator);
                var names: [6]?[]const u8 = .{ null, null, null, null, null, null };
                break :virt lc.host.invokeVirtualMember(
                    lc.allocator,
                    &recv,
                    ir.MethodSlotId.from(site.virt_slot),
                    argbuf[0..site.n_args],
                    names[0..site.n_args],
                    null,
                    null,
                ) catch {
                    lc.pending = .{ .Type = "out of memory in JIT-compiled call" };
                    return jit_loop.throwCode(site.block);
                };
            } else if (site.is_member) member: {
                const recv_tag_src: usize = if (site.recv_tag_reg != 0) site.recv_tag_reg else site.recv_reg;
                var recv = switch (cl.reg_types[site.recv_reg]) {
                    .object, .unknown => lc.frame.regs.items[site.recv_reg],
                    .null_ => Value.Null,
                    else => jit_loop.valueFromSlotTagged(cl.reg_types[site.recv_reg], tctx.tags[recv_tag_src], tctx.slots[site.recv_reg]),
                };
                // A varying boxed receiver may be a different class this iteration;
                // deopt unless it matches the class the return type was resolved for.
                if (site.recv_class != 0 and site.recv_varies and (recv != .Instance or jit_loop.instanceClassIdentity(recv) != site.recv_class)) {
                    lc.pending_deopt_inst = site.inst;
                    return jit_loop.deoptCode(site.block);
                }
                recv.retain();
                defer recv.release(lc.allocator);
                if (site.resolved_member) |fid| {
                    if (comptime !@hasDecl(H, "invokeResolvedMember")) {
                        break :member EvalResult{ .err = .{
                            .Type = "host cannot invoke resolved member calls",
                        } };
                    }
                    var dispatch: ?Value = if (site.dispatch_recv_reg) |reg|
                        switch (cl.reg_types[reg]) {
                            .object, .unknown => lc.frame.regs.items[reg],
                            .null_ => Value.Null,
                            else => jit_loop.valueFromSlotTagged(cl.reg_types[reg], tctx.tags[reg], tctx.slots[reg]),
                        }
                    else
                        null;
                    if (dispatch) |value| value.retain();
                    defer if (dispatch) |value| value.release(lc.allocator);
                    const dispatch_ptr: ?*const Value = if (dispatch) |*value|
                        value
                    else
                        null;
                    break :member lc.host.invokeResolvedMember(
                        lc.allocator,
                        dispatch_ptr,
                        &recv,
                        fid,
                        argbuf[0..site.n_args],
                        &.{},
                    ) catch {
                        lc.pending = .{ .Type = "out of memory in JIT-compiled call" };
                        return jit_loop.throwCode(site.block);
                    };
                }
                // Inline cache: lowering could not name this site's target, so
                // the interpreter re-ran FULL by-name dispatch (candidate scan +
                // overload ranking) on every call from compiled code. Resolve
                // once per (receiver class, argument shape) and call the target
                // directly while the shape holds.
                if (comptime @hasDecl(H, "resolveMemberFuncId") and @hasDecl(H, "invokeResolvedMember")) {
                    if (site.dispatch_recv_reg == null and site.declared_name.len == 0 and
                        @as(usize, @intCast(site_idx)) < cl.member_ics.len)
                    {
                        const ic = &cl.member_ics[@intCast(site_idx)];
                        const key = jit_loop.memberICKey(&recv, argbuf[0..site.n_args]);
                        if (key != 0) {
                            if (!(ic.valid and ic.key == key)) {
                                if (lc.host.resolveMemberFuncId(lc.allocator, &recv, site.name, argbuf[0..site.n_args])) |fid| {
                                    ic.* = .{ .key = key, .target = fid, .valid = true };
                                } else {
                                    // Unresolvable at this shape: leave the entry
                                    // invalid so the next call retries rather than
                                    // caching a miss forever.
                                    ic.valid = false;
                                }
                            }
                            if (ic.valid and ic.key == key) {
                                break :member lc.host.invokeResolvedMember(
                                    lc.allocator,
                                    null,
                                    &recv,
                                    ic.target,
                                    argbuf[0..site.n_args],
                                    &.{},
                                ) catch {
                                    lc.pending = .{ .Type = "out of memory in JIT-compiled call" };
                                    return jit_loop.throwCode(site.block);
                                };
                            }
                        }
                    }
                }
                if (comptime !@hasDecl(H, "callMemberNamed")) {
                    break :member EvalResult{ .err = .{
                        .Type = "host cannot dispatch member calls",
                    } };
                }
                // Keep the caller's instance `this` reachable for member-extension
                // visibility, exactly as the interpreted CallMember path does.
                var pushed = false;
                if (lc.frame.params.items.len > 0 and lc.frame.params.items[0] == .Instance) {
                    const pi = lc.frame.params.items[0].Instance;
                    const same = recv == .Instance and ObjRef(InstanceData).ptrEq(pi, recv.Instance);
                    if (!same) {
                        pushEnclosingAccess(&lc.frame.params.items[0]);
                        pushed = true;
                    }
                }
                var names: [6]?[]const u8 = .{ null, null, null, null, null, null };
                const r = (if (site.declared_name.len != 0)
                    lc.host.callMemberNamedDeclared(lc.allocator, &recv, site.name, argbuf[0..site.n_args], names[0..site.n_args], site.declared_name)
                else
                    lc.host.callMemberNamed(lc.allocator, &recv, site.name, argbuf[0..site.n_args], names[0..site.n_args])) catch {
                    if (pushed) popEnclosing();
                    lc.pending = .{ .Type = "out of memory in JIT-compiled call" };
                    return jit_loop.throwCode(site.block);
                };
                if (pushed) popEnclosing();
                if (r == .err and r.err == .Unimplemented and runtime.envOnce("KLIO_JIT_DEBUG") != null) {
                    std.debug.print("[jit-dbg] member miss: body={s} name={s} declared={s} recv_reg={d} n_params={d}\n", .{ lc.frame.func.fqn, site.name, site.declared_name, site.recv_reg, lc.frame.params.items.len });
                }
                break :member r;
            } else lc.host.callFunc(lc.allocator, lc.module, site.func, argbuf[0..site.n_args]) catch {
                lc.pending = .{ .Type = "out of memory in JIT-compiled call" };
                return jit_loop.throwCode(site.block);
            };
            switch (res) {
                .ok => |v| {
                    if (site.has_result) {
                        if (cl.reg_types[site.dst_reg] == .object) {
                            v.retain();
                            lc.frame.write(Reg.from(site.dst_reg), v) catch {
                                lc.pending = .{ .Type = "out of memory in JIT-compiled call" };
                                return jit_loop.throwCode(site.block);
                            };
                        } else {
                            const s = jit_loop.cellSlotIn(cl.reg_types[site.dst_reg], v) orelse {
                                // The call ALREADY RAN — a deopt that re-runs
                                // the instruction would double its effects.
                                // Deliver the boxed result into the frame
                                // register (the rebox pass skips it) and
                                // resume interpretation AFTER the site.
                                v.retain();
                                lc.frame.write(Reg.from(site.dst_reg), v) catch {
                                    lc.pending = .{ .Type = "out of memory in JIT-compiled call" };
                                    return jit_loop.throwCode(site.block);
                                };
                                tctx.deopt_skip_reg = site.dst_reg;
                                lc.pending_deopt_inst = site.inst + 1;
                                return jit_loop.deoptCode(site.block);
                            };
                            tctx.slots[site.dst_reg] = s;
                            // The call's ACTUAL result kind governs how this
                            // register reboxes (an intrinsic `toChar` has no
                            // static return to read).
                            if (cl.reg_types[site.dst_reg] == .i32) {
                                tctx.tags[site.dst_reg] = @intFromEnum(std.meta.activeTag(v));
                            }
                        }
                    }
                    return 0;
                },
                .err => |e| {
                    stashErr(lc, e, site.inst, Reg.from(site.dst_reg));
                    return jit_loop.throwCode(site.block);
                },
            }
        }

        /// Compile-time member resolver: resolve `receiver.name(args)` to the
        /// method `FuncId` so the loop JIT can learn its return type. Run time
        /// still dispatches through `callMemberNamed`, so this never alters
        /// behavior — it only informs the slot's static type.
        pub fn resolveMember(user: *anyopaque, receiver: *const Value, name: []const u8, args: []const Value) ?FuncId {
            if (comptime !@hasDecl(H, "resolveMemberFuncId")) return null;
            const lc: *Ctx = @ptrCast(@alignCast(user));
            return lc.host.resolveMemberFuncId(lc.allocator, receiver, name, args);
        }

        /// Compile-time virtual-slot resolver: the FuncId the slot dispatches
        /// to on the receiver's class, so a loop-invariant virtual call can
        /// inline its monomorphic target. Null keeps the site a trampoline.
        pub fn resolveVirtual(user: *anyopaque, receiver: *const Value, slot: u32) ?FuncId {
            if (comptime !@hasDecl(H, "resolveVirtualFuncId")) return null;
            const lc: *Ctx = @ptrCast(@alignCast(user));
            return lc.host.resolveVirtualFuncId(receiver, ir.MethodSlotId.from(slot));
        }

        /// Compile-time field resolver: the stored-field index of `name` on the
        /// receiver, or null if it is not a plain stored property (so the read
        /// stays interpreted).
        pub fn resolveField(user: *anyopaque, receiver: *const Value, name: []const u8) ?u32 {
            if (comptime !@hasDecl(H, "plainStoredFieldIndex")) return null;
            const lc: *Ctx = @ptrCast(@alignCast(user));
            return lc.host.plainStoredFieldIndex(lc.allocator, receiver, name);
        }

        /// Like `resolveField`, but only for a non-nullable scalar stored field —
        /// the index where a member-inlined field read can never observe null (so
        /// the loop can inline a method that also writes a field).
        pub fn resolveFieldNN(user: *anyopaque, receiver: *const Value, name: []const u8) ?u32 {
            if (comptime !@hasDecl(H, "plainStoredScalarFieldNN")) return null;
            const lc: *Ctx = @ptrCast(@alignCast(user));
            return lc.host.plainStoredScalarFieldNN(lc.allocator, receiver, name);
        }

        /// What the four compile-time resolvers above actually read: the host and
        /// the allocator, never the frame. The fused walker has no frame until it
        /// materializes one, and it has to know whether the loop compiles BEFORE
        /// paying for that, so it answers with this instead of a `Ctx`.
        pub const ResolveCtx = struct {
            host: *H,
            allocator: Allocator,
        };

        pub fn preMember(user: *anyopaque, receiver: *const Value, name: []const u8, args: []const Value) ?FuncId {
            if (comptime !@hasDecl(H, "resolveMemberFuncId")) return null;
            const rc: *ResolveCtx = @ptrCast(@alignCast(user));
            return rc.host.resolveMemberFuncId(rc.allocator, receiver, name, args);
        }

        pub fn preVirtual(user: *anyopaque, receiver: *const Value, slot: u32) ?FuncId {
            if (comptime !@hasDecl(H, "resolveVirtualFuncId")) return null;
            const rc: *ResolveCtx = @ptrCast(@alignCast(user));
            return rc.host.resolveVirtualFuncId(receiver, ir.MethodSlotId.from(slot));
        }

        pub fn preField(user: *anyopaque, receiver: *const Value, name: []const u8) ?u32 {
            if (comptime !@hasDecl(H, "plainStoredFieldIndex")) return null;
            const rc: *ResolveCtx = @ptrCast(@alignCast(user));
            return rc.host.plainStoredFieldIndex(rc.allocator, receiver, name);
        }

        pub fn preFieldNN(user: *anyopaque, receiver: *const Value, name: []const u8) ?u32 {
            if (comptime !@hasDecl(H, "plainStoredScalarFieldNN")) return null;
            const rc: *ResolveCtx = @ptrCast(@alignCast(user));
            return rc.host.plainStoredScalarFieldNN(rc.allocator, receiver, name);
        }
    };
}
