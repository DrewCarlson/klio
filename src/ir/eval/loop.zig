//! The flat-call loop and its trampoline: the driver that runs a chain of
//! activations without native recursion.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const span = @import("span");

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
const ev_resolved = @import("resolved.zig");

const Activation = ev_flow.Activation;
const EvalError = ev_state.EvalError;
const EvalResult = ev_flow.EvalResult;
const EvalTls = ev_state.EvalTls;
const FlatCallSite = ev_flow.FlatCallSite;
const Frame = ev_frame.Frame;
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

/// The driver core. `root_act` marks a root frame that is itself a resumed live activation, which a suspension live-parks rather than snapshots.
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
    const ev: *EvalTls = ev_state.evtlsPtr();
    var stack: std.ArrayList(*Activation) = .empty;
    defer stack.deinit(allocator);
    // On an allocation failure, unwind every open activation so no frame dangles on the GC chain.
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
            // The module the callee's body must be READ against: a request that names one is
            // authoritative, the caller's module only when it actually owns this `Func`.
            const callee_mod: *const Module = site.req.run_module orelse blk_cm: {
                if (funcOwnedBy(f.module, site.req.func)) break :blk_cm f.module;
                if (comptime @hasDecl(H, "ownerModuleForFunc")) {
                    if (host.ownerModuleForFunc(site.req.func)) |m| break :blk_cm m;
                }
                break :blk_cm f.module;
            };
            // A module lowered from sema calls by its tables alone: the seam,
            // the host routes and the leaf tier serve the name-resolving
            // lowering only.
            const resolved_mod = f.module.resolved != null;
            // A host-served compose helper answers before any activation opens; `discardFlatReq` undoes the request.
            if (!resolved_mod and site.req.captures.items.len == 0 and site.req.closure_id == null and
                site.req.type_args.len == 0 and !site.req.composer_pushed)
            {
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
                // Completable bodies only; a partial run pays the tier's entry and then
                // opens the frame it was meant to avoid. See the seam in `enter.zig`.
                const fr = (try fusedExecOpt(H, allocator, callee_mod2, site.req.func, site.req.args.items, host, false)) orelse break :fused;
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
                        // The flat protocol: a throw re-enters the caller through `rthrow` so its catches dispatch.
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
            if (!resolved_mod and leafReqServable(site.req)) {
                // A leaf-expression callee needs no activation: serve it straight into the caller's register.
                if (try leafExprServe(H, allocator, callee_mod, site.req.func, site.req.args.items)) |lr| {
                    const dst = site.req.dst;
                    discardFlatReq(H, allocator, site.req, host);
                    try f.write(dst, lr.ok);
                    cur = site.ret_block;
                    ridx = site.ret_idx;
                    continue;
                }
            }
            // Same depth bound as the recursive path: unbounded recursion becomes a catchable StackOverflowError.
            if (ev.eval_depth >= maxEvalDepth()) {
                dumpFrameChainForDiag();
                discardFlatReq(H, allocator, site.req, host);
                // Kotlin code catches it as `java.lang.StackOverflowError`.
                if (try ev_resolved.stackOverflowError(H, allocator, f.module, host)) |exc| {
                    rthrow = exc;
                } else {
                    runwind = .{ .StackOverflow = "Stack overflow: evaluation recursion exceeded the configured depth (raise KLIO_MAX_EVAL_DEPTH if intentional)" };
                }
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
            continue;
        }
        // A suspension parks the current frame at its suspension point, then every outer activation
        // at its call-return point. Flat activations park LIVE by pointer; a native root snapshots.
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
                    // No-driver root: park the root into its own pump and drain that pump to quiescence.
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
                    // The undispatched-start boundary: the parked segment belongs to the enclosing pump,
                    // the CALLER continues with COROUTINE_SUSPENDED, and `state` moves to the pump.
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
        // The current frame exited: deliver its result through each popped frame's boundary transforms.
        deliver: while (true) {
            if (stack.items.len == 0) return res;
            const act = stack.pop().?;
            ev.eval_depth -= 1;
            if (act.frame.module.resolved == null) res = frameBoundary(act.frame.func, res);
            // A no-driver root's completion drains its pump (launched children, timers) first.
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
                    // Anything else exits the calling frame as-is; keep popping so each boundary applies.
                    else => {},
                },
            }
        }
    }
}

pub fn typeRefName(name: []const u8) TypeRef {
    return .{ .name = name, .nullable = false, .args = &.{} };
}
