//! The fused tier: straight-line functions executed off a register bank
//! with no frame, no try stack, and no activation.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const span = @import("span");
const jit_loop = @import("../jit_loop.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;

const BinOp = ir.BinOp;
const BlockId = ir.BlockId;
const Const = ir.Const;
const Func = ir.Func;
const Inst = ir.Inst;
const Module = ir.Module;
const Reg = ir.Reg;

const exec_call = @import("../exec_call.zig");

const constStr = exec_call.constStr;
const fastIndexGet = exec_call.fastIndexGet;
const freeArgNames = exec_call.freeArgNames;
const ownReceiverEntry = exec_call.ownReceiverEntry;
const resolveArgNames = exec_call.resolveArgNames;
const sameReceiver = exec_call.sameReceiver;

const parent = @import("../eval.zig");
const ev_activation = @import("activation.zig");
const ev_chain = @import("chain.zig");
const ev_enter = @import("enter.zig");
const ev_exec = @import("exec.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_inst = @import("inst.zig");
const ev_leaf = @import("leaf.zig");
const ev_loop = @import("loop.zig");
const ev_native = @import("native.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");
const ev_values = @import("values.zig");

const EnclosingEntry = ev_state.EnclosingEntry;
const EvalError = ev_state.EvalError;
const EvalResult = ev_flow.EvalResult;
const EvalTls = ev_state.EvalTls;
const Frame = ev_frame.Frame;
const FusedMark = ev_state.FusedMark;
const LEAF_BANK_DEPTH = ev_leaf.LEAF_BANK_DEPTH;
const LoopTramp = ev_loop.LoopTramp;
const TryFrame = ev_snapshot.TryFrame;
const binopValue = ev_inst.binopValue;
const builtinFieldFast = ev_leaf.builtinFieldFast;
const chainAllocator = ev_chain.chainAllocator;
const coerceGenericIntPeersToLong = ev_enter.coerceGenericIntPeersToLong;
const coerceIntArgsToLong = ev_enter.coerceIntArgsToLong;
const coercePlanFor = ev_enter.coercePlanFor;
const constMatches = ev_values.constMatches;
const constToValue = ev_values.constToValue;
const evalWithCapturesChained = ev_enter.evalWithCapturesChained;
const frameBoundary = ev_enter.frameBoundary;
const gcInstallFrameRoot = ev_state.gcInstallFrameRoot;
const gcPopFrame = ev_state.gcPopFrame;
const gcPushFrame = ev_state.gcPushFrame;
const lateinitThrow = ev_flow.lateinitThrow;
const loadGlobalValue = ev_inst.loadGlobalValue;
const ok = ev_flow.ok;
const popEnclosing = ev_chain.popEnclosing;
const pushEnclosingAccess = ev_chain.pushEnclosingAccess;
const pushEnclosingSubject = ev_chain.pushEnclosingSubject;
const runFrame = ev_activation.runFrame;
const scalarBin = ev_exec.scalarBin;
const tryLeafValues = ev_native.tryLeafValues;
const valueTruthy = ev_values.valueTruthy;

pub const FUSED_MAX_REGS: usize = 128;

pub const FUSED_BANK_DEPTH: usize = 24;

const FUSED_MAX_BLOCKS: usize = 64;

const FUSED_MAX_INSTS: usize = 256;

/// All per-thread walker state in one threadlocal, so the base resolves once per activation.
const FusedTls = struct {
    bank: [FUSED_BANK_DEPTH][FUSED_MAX_REGS]Value = undefined,
    chain: [FUSED_BANK_DEPTH]std.ArrayList(EnclosingEntry) = @splat(.empty),
    marks: [FUSED_BANK_DEPTH]FusedMark = undefined,
    depth: usize = 0,
};

/// The owner thread reads this copy, every other thread `fused_tls_other`; see `runtime.tls_fast`.
var fused_tls_owner: FusedTls = .{};

threadlocal var fused_tls_other: FusedTls = .{};

pub inline fn fusedTls() *FusedTls {
    return if (runtime.tls_fast.isOwner()) &fused_tls_owner else &fused_tls_other;
}

var fused_enabled_state: u8 = 0;

var fused_enabled_val: bool = true;

var fused_sel: ?[]const u8 = null;

/// `KLIO_FUSED=0` disables the tier; a comma list fuses ONLY those simple names, and a
/// leading `!` fuses all but those.
pub fn fusedEnabled() bool {
    if (fused_enabled_state == 0) {
        const raw = runtime.envOnce("KLIO_FUSED") orelse "1";
        if (std.mem.eql(u8, raw, "0")) {
            fused_enabled_val = false;
        } else {
            fused_enabled_val = true;
            if (!std.mem.eql(u8, raw, "1")) fused_sel = raw;
        }
        fused_enabled_state = 1;
    }
    return fused_enabled_val;
}

fn fusedNameSelected(name: []const u8) bool {
    const sel = fused_sel orelse return true;
    const inverted = std.mem.startsWith(u8, sel, "!");
    var it = std.mem.splitScalar(u8, if (inverted) sel[1..] else sel, ',');
    while (it.next()) |tok| {
        if (tok.len != 0 and std.mem.eql(u8, tok, name)) return !inverted;
    }
    return inverted;
}

/// Transitive closed-world verdict, memoized on the Func as `fuse_state`: 0 unasked, 1 full
/// (every op fusable, callees transitively full), 2 no, 3 in progress (reads eligible, so a
/// recursion cycle settles with the root's verdict), 4 partial (fused prefix, then materializes
/// a frame). A host-owned callee forces 2: the resume bridge assumes a framed caller.
fn fusedEligible(comptime H: type, host: *H, module: *const Module, func: *const Func) bool {
    return fusedVerdict(H, host, module, func) == 1;
}

/// Funcs THIS thread is classifying, so a self-recursive call site reads eligible. Another
/// thread's in-progress marker declines instead: its blocks may not be decoded yet.
threadlocal var classify_stack: [128]u32 = undefined;

threadlocal var classify_depth: usize = 0;

fn classifyingHere(fid: u32) bool {
    for (classify_stack[0..classify_depth]) |f| {
        if (f == fid) return true;
    }
    return false;
}

fn fusedVerdict(comptime H: type, host: *H, module: *const Module, func: *const Func) u8 {
    switch (func.fuse_state) {
        1, 2, 4 => return func.fuse_state,
        3 => return if (classifyingHere(func.id.int())) 1 else 2,
        else => {},
    }
    if (comptime @hasDecl(H, "funcRunsItsBody")) {
        if (!host.funcRunsItsBody(func.id)) {
            @constCast(func).fuse_state = 2;
            return 2;
        }
    }
    if (classify_depth >= classify_stack.len) return 2; // depth guard: decline, no memo
    @constCast(func).fuse_state = 3;
    classify_stack[classify_depth] = func.id.int();
    classify_depth += 1;
    const verdict = fusedClassify(H, host, module, func);
    classify_depth -= 1;
    @constCast(func).fuse_state = verdict;
    return verdict;
}

fn bareTypeVarHead(name: []const u8) bool {
    const head = std.mem.trimEnd(u8, name, "?");
    return head.len > 0 and head.len <= 2 and std.ascii.isUpper(head[0]);
}

fn fusedClassify(comptime H: type, host: *H, module: *const Module, func: *const Func) u8 {
    if (func.is_suspend or func.is_lambda) return 2;
    // A bare type variable marks a generic body, whose `as T` / `is T` consults the frame's
    // reified context; the walker carries none. The Cast and InstanceOf ops are guarded below.
    if (bareTypeVarHead(func.return_ty.name)) return 2;
    for (func.params) |*p| {
        if (bareTypeVarHead(p.ty.name)) return 2;
    }
    if (func.blocks.len == 0 or func.blocks.len > FUSED_MAX_BLOCKS) return 2;
    if (func.n_locals > FUSED_MAX_REGS) return 2;
    for (func.params) |*p| {
        if (p.is_vararg or p.default != null) return 2;
    }
    var heavy = false;
    var total: usize = 0;
    // Fusable instructions the ENTRY block runs before its first heavy op.
    var entry_prefix: usize = 0;
    var entry_heavy = false;
    for (func.blocks, 0..) |*b, bi| {
        if (b.catches.len != 0 or b.finally != null or b.lr_absorb != null) return 2;
        total += b.insts.len;
        if (total > FUSED_MAX_INSTS) return 2;
        switch (b.terminator) {
            .Return, .Goto, .Branch, .Switch, .Throw, .Unreachable => {},
            else => return 2,
        }
        const is_entry = bi == func.entry.int();
        for (b.insts) |*inst| {
            const was_heavy = heavy;
            _ = was_heavy;
            const heavy_before = heavy;
            defer if (is_entry and !entry_heavy) {
                if (heavy != heavy_before) {
                    entry_heavy = true;
                } else switch (inst.*) {
                    .Trace => {},
                    else => entry_prefix += 1,
                }
            };
            switch (inst.*) {
                .Trace, .Const, .Move, .LoadParam, .BinOp, .Not, .GetField, .SetField,
                .Index, .IndexSet, .NotNullAssert, .LateinitCheck, .MakeCell,
                .CellGet, .CellSet, .EnclosingPush, .EnclosingPop => {},
                .Cast => |ct| if (bareTypeVarHead(ct.ty.name)) return 2,
                .InstanceOf => |io| if (bareTypeVarHead(io.ty.name)) return 2,
                // Open-world but non-suspending, so nothing beneath needs materialization.
                .LoadGlobal => {},
                // Dynamic dispatch stays framed: fused-first execution never stamps the site memos.
                .CallVirtual, .CallMember => heavy = true,
                .NewInstance => |ni| {
                    if (ni.arg_names.len != 0) {
                        for (ni.arg_names) |an| {
                            if (an != null) heavy = true;
                        }
                    }
                },
                .Call => |c| blk: {
                    if (c.arg_names.len != 0 or c.type_args.len != 0) {
                        heavy = true;
                        break :blk;
                    }
                    const callee = module.funcById(c.func) orelse {
                        heavy = true;
                        break :blk;
                    };
                    _ = module.ensureFuncBody(@constCast(callee));
                    if (callee.params.len != c.n_args) {
                        heavy = true;
                        break :blk;
                    }
                    if (fusedVerdict(H, host, module, callee) != 1) heavy = true;
                },
                // A resumable body: never fused, never materialized mid-flight.
                .SuspendResumePoint => return 2,
                else => heavy = true,
            }
        }
    }
    if (heavy and entry_heavy and entry_prefix < fused_min_prefix) return 2;
    return if (heavy) 4 else 1;
}

/// A heavy body whose fusable entry prefix is shorter than this runs framed outright.
const fused_min_prefix: usize = 24;

const FusedFail = error{ Raise, Materialize } || Allocator.Error;

threadlocal var fused_err: EvalError = undefined;

inline fn fusedRaise(e: EvalError) FusedFail {
    fused_err = e;
    return error.Raise;
}

/// The tier's entry: null when the body is ineligible and the caller must take the framed
/// path, else an `.ok` or a genuinely raised `.err`, never an abandon.
pub fn fusedExec(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
) Allocator.Error!?EvalResult {
    return fusedExecOpt(H, allocator, module, func, args, host, false);
}

/// `allow_materialize`: a partial body runs its fused prefix and continues framed. Only the
/// recursive seam may allow it, since a flat caller cannot adopt the remainder's suspension.
pub fn fusedExecOpt(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
    allow_materialize: bool,
) Allocator.Error!?EvalResult {
    if (comptime !@hasDecl(H, "fieldSiteRoute")) return null;
    if (!fusedEnabled()) return null;
    if (!fusedNameSelected(if (func.fqn.len != 0) func.fqn else func.name)) return null;
    const verdict = fusedVerdict(H, host, module, func);
    if (verdict == 2) return null;
    if (verdict == 4 and !allow_materialize) return null;
    if (args.len != func.params.len) return null;
    // An inner-class member's bare reads reach the enclosing instance, which the walker does
    // not model, so a receiver carrying an outer declines.
    if (args.len > 0 and args[0] == .Instance) {
        const g = args[0].Instance.borrow();
        const has_outer = g.get().outer != null;
        g.deinit();
        if (has_outer) return null;
    }
    if (fusedTls().depth >= FUSED_BANK_DEPTH) return null;
    // A hot fully-fusable body yields so the function JIT can count it; a fused body opens no frame.
    if (jit_loop.fusedShouldYieldToFuncTier(func)) return null;
    // A memoized verdict reaches this thread without ordering against the body's lazy decode;
    // re-ensure (idempotent) so the walker never indexes an empty block table.
    if (func.blocks.len == 0 and !module.ensureFuncBody(@constCast(func))) return null;
    if (parent.frame_count_on) parent.frame_count_total += 1;
    if (runtime.envOnce("KLIO_FUSED_TRACE") != null) {
        std.debug.print("[fused] {s}\n", .{if (func.fqn.len != 0) func.fqn else func.name});
    }
    return try fusedRun(H, allocator, module, func, args, host);
}

fn fusedRun(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args_in: []const Value,
    host: *H,
) Allocator.Error!EvalResult {
    const ft = fusedTls();
    const ev: *EvalTls = &ev_state.evtls;
    const ka = runtime.keepaliveHandle();
    const reclaim = runtime.reclaimEnabled();
    var eff_args = args_in;
    {
        const plan = coercePlanFor(module, func);
        if (plan & 6 != 0 and args_in.len <= ir.LEAF_MAX_REGS) {
            const coerce_buf: []Value = ev_leaf.coerce_bank[ft.depth % LEAF_BANK_DEPTH][0..args_in.len];
            @memcpy(coerce_buf, args_in);
            if (plan & 2 != 0) coerceIntArgsToLong(func, coerce_buf);
            if (plan & 4 != 0) coerceGenericIntPeersToLong(module, func, coerce_buf);
            eff_args = coerce_buf;
        }
    }
    const nlive: usize = @min(@as(usize, func.n_locals), FUSED_MAX_REGS);
    const regs: []Value = ft.bank[ft.depth][0..nlive];
    ft.depth += 1;
    defer ft.depth -= 1;
    // No def-before-use proof here, unlike the leaf bank: fill the bank so the register file is
    // always well-formed, and keep it pinned for the collector for the whole run.
    for (regs) |*v| v.* = .Unit;
    const mark: *FusedMark = &ft.marks[ft.depth - 1];
    mark.* = .{
        .func = func,
        .mod = module,
        .head = ev.frame_chain,
        .recv = if (func.has_receiver_param and eff_args.len > 0 and eff_args[0] == .Instance) eff_args[0] else null,
    };
    if (runtime.gc.gc_enabled) gcInstallFrameRoot();
    const pin_mark = ka.mark();
    ka.pushSlice(regs);
    // The args slice is not otherwise a root: a dispatch that assembled it in a scratch buffer
    // may hold the only reference, and the fused body crosses safe points off that buffer.
    ka.pushSlice(eff_args);
    defer ka.restore(pin_mark);
    defer if (reclaim) {
        for (regs) |*v| v.release(allocator);
    };
    // The fused body owns an enclosing chain exactly as a frame does, seeded from the caller's
    // in-flight pushes plus its own receiver, then activated.
    const chain = &ft.chain[ft.depth - 1];
    chain.clearRetainingCapacity();
    if (ev.active_chain) |caller| {
        const base = @min(ev.active_chain_base, caller.items.len);
        for (caller.items[base..]) |e| {
            if (e.kind == .access) continue;
            try chain.append(chainAllocator(), e);
        }
    }
    if (exec_call.ownReceiverEntry(func, eff_args)) |own| {
        const dup = chain.items.len > 0 and sameReceiver(chain.items[chain.items.len - 1].v, own.v);
        if (!dup) try chain.append(chainAllocator(), own);
    }
    const prev_chain = ev.active_chain;
    const prev_chain_base = ev.active_chain_base;
    ev.active_chain = chain;
    ev.active_chain_base = chain.items.len;
    defer {
        ev.active_chain = prev_chain;
        ev.active_chain_base = prev_chain_base;
    }
    var pushed_enclosing: usize = 0;
    defer while (pushed_enclosing > 0) : (pushed_enclosing -= 1) popEnclosing();

    // KLIO_FN_PROF: the fused body is the executing function, not its last framed caller.
    const fn_prof_prev = runtime.prof.current_fn;
    if (runtime.prof.fn_prof_active) runtime.prof.current_fn = func.id.int();
    defer if (runtime.prof.fn_prof_active) {
        runtime.prof.current_fn = fn_prof_prev;
    };

    var cur: BlockId = func.entry;
    // The loop JIT counts block entries in the framed loop and never sees a fused body's own
    // back edges: count them here and materialize at the loop header, before it runs.
    const jit_yield_on = jit_loop.enabled();
    var back_edges: u32 = 0;
    walk: while (true) {
        // Once per block, UNCONDITIONAL: `pending()` never sees another thread's stop flag, so
        // gating on it lets a fused spin loop skip the rendezvous. The pinned bank keeps it root-exact.
        if (runtime.gc.gc_enabled) runtime.gc.safePoint();
        const blk = &func.blocks[cur.int()];
        const blk_id = cur.int();
        for (blk.insts, 0..) |*inst, idx| {
            fusedInst(H, allocator, module, func, eff_args, host, inst, regs, reclaim, &pushed_enclosing, mark) catch |e| switch (e) {
                error.Raise => return .{ .err = fused_err },
                // A heavy op: build the real Frame from the bank and run the remainder framed, starting AT
                // this instruction, no side effect of which has run. The frame owns any suspension beneath it.
                error.Materialize => {
                    const moved_pushes = pushed_enclosing;
                    pushed_enclosing = 0;
                    return try fusedMaterializeAndRun(
                        H,
                        allocator,
                        module,
                        func,
                        args_in,
                        regs,
                        cur,
                        idx,
                        moved_pushes,
                        host,
                    );
                },
                else => |oe| return oe,
            };
        }
        switch (blk.terminator) {
            .Goto => |next| cur = next,
            .Branch => |br| {
                const v = fusedRead(regs, br.cond);
                switch (try valueTruthy(allocator, &v)) {
                    .ok => |b| cur = if (b) br.t else br.f,
                    .err => |e| return .{ .err = e },
                }
            },
            .Switch => |sw| {
                const v = fusedRead(regs, sw.reg);
                var next = sw.default;
                for (sw.arms) |arm| {
                    if (constMatches(module, arm.key, &v)) {
                        next = arm.target;
                        break;
                    }
                }
                cur = next;
            },
            .Return => |maybe_r| {
                const v = if (maybe_r) |r| fusedRead(regs, r) else Value.Unit;
                v.retain();
                return ok(v);
            },
            .Throw => |r| {
                const exc = fusedRead(regs, r);
                exc.retain();
                return .{ .err = .{ .Throw = exc } };
            },
            .Unreachable => return .{ .err = .{ .Type = "unreachable block executed" } },
            else => unreachable,
        }
        if (jit_yield_on and cur.int() <= blk_id) {
            back_edges +|= 1;
            if (back_edges >= jit_loop.FUSED_YIELD_BACK_EDGES) {
                if (jit_loop.loopDeclined(func, cur.int())) {
                    // Already refused: stay fused rather than pay a materialization to be refused again.
                    back_edges = 0;
                    continue :walk;
                }
                // Leaving the bank for a frame is one-way, so commit only to compiled code: compile first
                // and stay on the walk when the tier refuses. The compile-time resolvers need no frame.
                var rctx: LoopTramp(H).ResolveCtx = .{ .host = host, .allocator = allocator };
                const pre_member: ?jit_loop.MemberResolver =
                    if (comptime @hasDecl(H, "resolveMemberFuncId")) &LoopTramp(H).preMember else null;
                const pre_virtual: ?jit_loop.VirtResolver =
                    if (comptime @hasDecl(H, "resolveVirtualFuncId")) &LoopTramp(H).preVirtual else null;
                const pre_field: ?jit_loop.FieldResolver =
                    if (comptime @hasDecl(H, "plainStoredFieldIndex")) &LoopTramp(H).preField else null;
                const pre_field_nn: ?jit_loop.FieldResolver =
                    if (comptime @hasDecl(H, "plainStoredScalarFieldNN")) &LoopTramp(H).preFieldNN else null;
                if (!jit_loop.compileHotLoopFor(module, func, cur, regs, pre_member, pre_virtual, pre_field, pre_field_nn, @ptrCast(&rctx))) {
                    back_edges = 0;
                    continue :walk;
                }
                if (jit_loop.debugEnabled())
                    std.debug.print("[jit]   fused body {s} yields its hot loop at b{d}\n", .{ func.name, cur.int() });
                const moved_pushes = pushed_enclosing;
                pushed_enclosing = 0;
                return try fusedMaterializeAndRun(
                    H,
                    allocator,
                    module,
                    func,
                    args_in,
                    regs,
                    cur,
                    0,
                    moved_pushes,
                    host,
                );
            }
        }
        continue :walk;
    }
}

/// Build the real Frame from the bank at (cur, idx) and run the remainder through the framed
/// engine, resumed mid-body.
fn fusedMaterializeAndRun(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args_in: []const Value,
    regs: []Value,
    cur: BlockId,
    idx: usize,
    pushed_enclosing: usize,
    host: *H,
) Allocator.Error!EvalResult {
    const ev: *EvalTls = &ev_state.evtls;
    if (runtime.envOnce("KLIO_FUSED_TRACE") != null) {
        std.debug.print("[fused-mat] {s} at b{d}:{d} pushes={d}\n", .{
            if (func.fqn.len != 0) func.fqn else func.name, cur.int(), idx, pushed_enclosing,
        });
    }
    var arg_list: std.ArrayList(Value) = .empty;
    try arg_list.appendSlice(allocator, args_in);
    if (runtime.reclaimEnabled()) for (arg_list.items) |v| v.retain();
    var try_stack: std.ArrayList(TryFrame) = .empty;
    defer try_stack.deinit(allocator);
    var frame = try Frame.newWithCaptures(ev, allocator, module, func, arg_list, .empty);
    defer frame.deinit();
    gcPushFrame(&frame);
    defer gcPopFrame(&frame);
    // The frame inherits the walker's chain window WHOLE: the window IS what activateChain would
    // build here, and re-deriving drops the seeded portion that sits below the window's base.
    const wbase = ev.active_chain_base;
    if (ev.active_chain) |wchain| {
        try frame.enclosing_this.appendSlice(chainAllocator(), wchain.items);
        // The frame owns the entries now; the window is a thread root and would keep rooting them.
        wchain.clearRetainingCapacity();
    }
    frame.activateAs();
    ev.active_chain_base = @min(wbase, frame.enclosing_this.items.len);
    defer frame.deactivateChain();
    const ctx_mark: usize = if (comptime @hasDecl(H, "ctxStackLen")) host.ctxStackLen() else 0;
    if (comptime @hasDecl(H, "ctxPush")) {
        if (module.has_context_decls) {
            if (comptime @hasDecl(H, "ctxActivate")) host.ctxActivate(true);
            if (func.has_receiver_param and frame.params.items.len > 0) {
                host.ctxPush(frame.params.items[0]) catch {};
            }
        }
    }
    defer if (comptime @hasDecl(H, "ctxStackTruncate")) host.ctxStackTruncate(ctx_mark);
    // Bank slots MOVE into the frame with no retain: the walker never resumes after a
    // materialization, and the pinned bank is zeroed behind it so it stops rooting them.
    const n = @min(regs.len, frame.regs.items.len);
    for (regs[0..n], 0..) |v, i| {
        if (runtime.reclaimEnabled()) frame.regs.items[i].release(allocator);
        frame.regs.items[i] = v;
        frame.wmask.set(i);
    }
    for (regs) |*v| v.* = .Unit;
    const result = try runFrame(H, allocator, module, &frame, &try_stack, cur, idx, host);
    return frameBoundary(func, result);
}

inline fn fusedRead(regs: []const Value, r: Reg) Value {
    const i = r.int();
    if (i >= regs.len) return .Unit;
    return regs[i];
}

inline fn fusedWrite(allocator: Allocator, regs: []Value, dst: Reg, v: Value, reclaim: bool, retain_src: bool) void {
    const i = dst.int();
    if (i >= regs.len) {
        if (reclaim and !retain_src) v.release(allocator);
        return;
    }
    if (reclaim) {
        if (retain_src) v.retain();
        const old = regs[i];
        regs[i] = v;
        old.release(allocator);
    } else {
        regs[i] = v;
    }
}

fn fusedInst(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
    inst: *const Inst,
    regs: []Value,
    reclaim: bool,
    pushed_enclosing: *usize,
    mark: *FusedMark,
) FusedFail!void {
    switch (inst.*) {
        // The walker's cur_span, so span-derived context sees the executing call site.
        .Trace => |t| mark.span = t.span,
        .LoadParam => |lp| {
            const v = if (lp.idx < args.len) args[lp.idx] else Value.Unit;
            fusedWrite(allocator, regs, lp.dst, v, reclaim, true);
        },
        .Const => |c| {
            if (c.value.int() >= module.consts.items.len)
                return fusedRaise(.{ .Type = "fused: const id out of range" });
            const v = try constToValue(allocator, &module.consts.items[c.value.int()]);
            fusedWrite(allocator, regs, c.dst, v, reclaim, false);
        },
        .Move => |mv| fusedWrite(allocator, regs, mv.dst, fusedRead(regs, mv.src), reclaim, true),
        .Not => |n| {
            const v = fusedRead(regs, n.src);
            if (v == .Instance) {
                switch (try host.callMember(allocator, &v, "not", &.{})) {
                    .ok => |rv| fusedWrite(allocator, regs, n.dst, rv, reclaim, false),
                    .err => |e| return fusedRaise(e),
                }
                return;
            }
            const b = switch (v) {
                .Bool => |bv| !bv,
                else => return fusedRaise(.{ .Type = "Not on non-bool" }),
            };
            fusedWrite(allocator, regs, n.dst, .{ .Bool = b }, reclaim, false);
        },
        .BinOp => |bo| {
            const l = fusedRead(regs, bo.lhs);
            const r = fusedRead(regs, bo.rhs);
            if (scalarBin(bo.op, l, r)) |v| {
                fusedWrite(allocator, regs, bo.dst, v, reclaim, false);
                return;
            }
            switch (try binopValue(H, allocator, l, r, @TypeOf(bo), bo, host)) {
                .ok => |v| fusedWrite(allocator, regs, bo.dst, v, reclaim, false),
                .err => |e| return fusedRaise(e),
            }
        },
        .GetField => |gf| {
            const recv = fusedRead(regs, gf.receiver);
            const fname = constStr(module, gf.field) orelse
                return fusedRaise(.{ .Type = "GetField: name not a string const" });
            if (try builtinFieldFast(H, host, allocator, &recv, fname)) |bv| {
                fusedWrite(allocator, regs, gf.dst, bv, reclaim, false);
                return;
            }
            // Framed parity: the executing body's receiver stays reachable as an enclosing `this` while
            // the field resolves, so a member-extension property on another receiver finds its owner.
            var pushed_access = false;
            if (func.has_receiver_param and args.len > 0 and args[0] == .Instance) {
                const same = recv == .Instance and ObjRef(InstanceData).ptrEq(args[0].Instance, recv.Instance);
                if (!same) {
                    pushEnclosingAccess(&args[0]);
                    pushed_access = true;
                }
            }
            defer if (pushed_access) popEnclosing();
            switch (try host.getField(allocator, &recv, fname)) {
                .ok => |v| {
                    if (runtime.envOnce("KLIO_FUSED_GF_TRACE")) |w| {
                        if (std.mem.eql(u8, w, fname)) {
                            std.debug.print("[fused-gf] {s} recv={s} -> {s}", .{ fname, @tagName(std.meta.activeTag(recv)), @tagName(std.meta.activeTag(v)) });
                            switch (v) {
                                .Long => |l| std.debug.print(" L{d}", .{l}),
                                .Int => |iv| std.debug.print(" I{d}", .{iv}),
                                .Double => |d| std.debug.print(" D{d}", .{d}),
                                else => {},
                            }
                            switch (recv) {
                                .Long => |l| std.debug.print(" recvL{d}", .{l}),
                                else => {},
                            }
                            std.debug.print("\n", .{});
                        }
                    }
                    fusedWrite(allocator, regs, gf.dst, v, reclaim, true);
                },
                .err => |e| return fusedRaise(e),
            }
        },
        .SetField => |sf| {
            const recv = fusedRead(regs, sf.receiver);
            const v = fusedRead(regs, sf.value);
            const fname = constStr(module, sf.field) orelse
                return fusedRaise(.{ .Type = "SetField: name not a string const" });
            const super_owner: ?[]const u8 = if (sf.super_owner) |c| constStr(module, c) else null;
            switch (try host.setFieldFrom(allocator, &recv, fname, v, super_owner)) {
                .ok => {},
                .err => |e| return fusedRaise(e),
            }
        },
        .Index => |ix| {
            const recv = fusedRead(regs, ix.receiver);
            const idx = fusedRead(regs, ix.index);
            if (fastIndexGet(&recv, &idx)) |v| {
                v.retain();
                fusedWrite(allocator, regs, ix.dst, v, reclaim, false);
                return;
            }
            switch (try host.callMember(allocator, &recv, "get", &.{idx})) {
                .ok => |v| fusedWrite(allocator, regs, ix.dst, v, reclaim, false),
                .err => |e| return fusedRaise(e),
            }
        },
        .IndexSet => |ixs| {
            const recv = fusedRead(regs, ixs.receiver);
            const idx = fusedRead(regs, ixs.index);
            const v = fusedRead(regs, ixs.value);
            if (exec_call.fastIndexSet(allocator, &recv, &idx, v)) |expr_val| {
                if (reclaim) expr_val.release(allocator);
                return;
            }
            switch (try host.callMember(allocator, &recv, "set", &.{ idx, v })) {
                .ok => {},
                .err => |e| return fusedRaise(e),
            }
        },
        .InstanceOf => |io| {
            const v = fusedRead(regs, io.src);
            fusedWrite(allocator, regs, io.dst, .{ .Bool = host.instanceOf(&v, io.ty) }, reclaim, false);
        },
        .Cast => |cast| {
            const v = fusedRead(regs, cast.src);
            if (host.instanceOf(&v, cast.ty)) {
                fusedWrite(allocator, regs, cast.dst, v, reclaim, true);
            } else if (exec_call.typeParamCastPassesIn(H, module, func, cast.ty, host)) {
                fusedWrite(allocator, regs, cast.dst, v, reclaim, true);
            } else if (cast.safe) {
                fusedWrite(allocator, regs, cast.dst, .Null, reclaim, false);
            } else {
                if (runtime.envOnce("KLIO_THROW_TRACE") != null) {
                    std.debug.print("[throw-trace] from fused fn {s}: ClassCastException cast to {s} (value tag {s})\n", .{ func.name, cast.ty.name, @tagName(std.meta.activeTag(v)) });
                }
                const msg = try std.fmt.allocPrint(allocator, "cast to `{s}` failed", .{cast.ty.name});
                const exc = try Value.newException(allocator, .{
                    .fqn = try runtime.strInit(allocator, "kotlin.ClassCastException"),
                    .message = .from(try runtime.strInitOwned(allocator, msg)),
                    .cause = null,
                });
                return fusedRaise(.{ .Throw = exc });
            }
        },
        .NotNullAssert => |nn| {
            const v = fusedRead(regs, nn.src);
            if (v == .Null) {
                const exc = try Value.newException(allocator, .{
                    .fqn = try runtime.strInit(allocator, "kotlin.NullPointerException"),
                    .message = .{},
                    .cause = null,
                });
                return fusedRaise(.{ .Throw = exc });
            }
            fusedWrite(allocator, regs, nn.dst, v, reclaim, true);
        },
        .LateinitCheck => |lc| {
            const v = fusedRead(regs, lc.src);
            if (v == .Null) {
                return fusedRaise(try lateinitThrow(allocator, constStr(module, lc.name) orelse "?"));
            }
            fusedWrite(allocator, regs, lc.dst, v, reclaim, true);
        },
        .MakeCell => |mc| {
            const v = fusedRead(regs, mc.src);
            v.retain();
            fusedWrite(allocator, regs, mc.dst, try Value.newCell(allocator, v), reclaim, false);
        },
        .CellGet => |cg| {
            const v = switch (fusedRead(regs, cg.cell)) {
                .Cell => |c| blk: {
                    const g = c.borrow();
                    defer g.deinit();
                    break :blk g.get().*;
                },
                else => |other| other,
            };
            fusedWrite(allocator, regs, cg.dst, v, reclaim, true);
        },
        .CellSet => |cs| {
            const cell_v = fusedRead(regs, cs.cell);
            const v = fusedRead(regs, cs.value);
            switch (cell_v) {
                .Cell => |c| {
                    v.retain();
                    const g = c.borrowMut();
                    defer g.deinit();
                    const old = g.get().*;
                    g.get().* = v;
                    if (reclaim) old.release(allocator);
                },
                else => return fusedRaise(.{ .Type = "CellSet on non-cell" }),
            }
        },
        .LoadGlobal => |lg| {
            switch (try loadGlobalValue(H, allocator, module, lg, host)) {
                .ok => |v| fusedWrite(allocator, regs, lg.dst, v, reclaim, false),
                .err => |e| return fusedRaise(e),
            }
        },
        .NewInstance => |ni| {
            var argv: [FUSED_MAX_REGS]Value = undefined;
            if (ni.n_args > FUSED_MAX_REGS)
                return fusedRaise(.{ .Type = "fused: too many ctor args" });
            var i: u32 = 0;
            while (i < ni.n_args) : (i += 1) {
                argv[i] = fusedRead(regs, Reg.from(ni.args.int() + i));
            }
            const names = try exec_call.resolveArgNames(allocator, module, ni.arg_names);
            defer exec_call.freeArgNames(allocator, names);
            const static_heads = try exec_call.resolveArgNames(allocator, module, ni.arg_static_heads);
            defer exec_call.freeArgNames(allocator, static_heads);
            if (comptime @hasDecl(H, "setCtorArgStaticHeads")) {
                host.setCtorArgStaticHeads(static_heads);
            }
            // A bare `Inner(args)` inside a member is `this@Outer.Inner`: `this` is the outer hint.
            var outer_hint: ?Value = null;
            if (args.len > 0 and func.params.len > 0 and
                std.mem.eql(u8, func.params[0].name, "this")) outer_hint = args[0];
            const hint_ptr: ?*const Value = if (outer_hint) |*h| h else null;
            const result = switch (try host.newInstanceNamed(allocator, ni.class, argv[0..ni.n_args], names, hint_ptr)) {
                .ok => |v| v,
                .err => |e| return fusedRaise(e),
            };
            if (result == .Instance) {
                const inst_ref = result.Instance;
                const needs_outer = blk: {
                    const g = inst_ref.borrow();
                    defer g.deinit();
                    const cg = g.get().class.borrow();
                    defer cg.deinit();
                    break :blk cg.get().is_inner and g.get().outer == null;
                };
                if (needs_outer and outer_hint != null) {
                    outer_hint.?.retain();
                    const g = inst_ref.borrowMut();
                    defer g.deinit();
                    g.get().outer = outer_hint.?;
                }
            }
            fusedWrite(allocator, regs, ni.dst, result, reclaim, false);
        },
        .EnclosingPush => |x| {
            const v = fusedRead(regs, x.src);
            pushEnclosingSubject(&v);
            pushed_enclosing.* += 1;
        },
        .EnclosingPop => {
            popEnclosing();
            if (pushed_enclosing.* > 0) pushed_enclosing.* -= 1;
        },
        .Call => |c| {
            const callee = module.funcById(c.func) orelse
                return error.Materialize;
            // Same-name same-arity peers: the baked direct id is the target only when THIS site's scope
            // binds it, so ask as the framed fast path does and hand an ambiguous site to the frame.
            if (comptime @hasDecl(H, "callFuncFast")) {
                var plan = callee.fast_call;
                if (plan == 0) {
                    plan = host.fastCallPlan(module, c.func);
                    @constCast(callee).fast_call = plan;
                }
                if (plan & ir.FAST_CALL_AMBIG_FLAG != 0) {
                    var verdict = @atomicLoad(u8, @constCast(&c.fuse_site), .acquire);
                    if (verdict == 0) {
                        const cfile: ?ir.FileId = if (mark.span) |sp| sp.file else null;
                        verdict = if (host.fuseSiteBinds(module, c.func, func.package, cfile)) 2 else 1;
                        @atomicStore(u8, @constCast(&c.fuse_site), verdict, .release);
                    }
                    if (verdict != 2) return error.Materialize;
                }
            }
            var argv: [FUSED_MAX_REGS]Value = undefined;
            if (c.n_args > FUSED_MAX_REGS)
                return fusedRaise(.{ .Type = "fused: too many call args" });
            var i: u32 = 0;
            while (i < c.n_args) : (i += 1) {
                argv[i] = fusedRead(regs, Reg.from(c.args.int() + i));
            }
            if (c.arg_names.len != 0 or c.type_args.len != 0 or callee.params.len != c.n_args)
                return error.Materialize;
            // A registered pure callee runs as direct C; a bail falls through and re-runs the body exactly.
            const leaf_served: ?Value = if (try tryLeafValues(H, allocator, module, callee, argv[0..c.n_args], host, null)) |lo| switch (lo) {
                .val => |v| v,
                .raise => |e| return fusedRaise(e),
            } else null;
            if (leaf_served) |lv| {
                fusedWrite(allocator, regs, c.dst, lv, reclaim, false);
                return;
            }
            const direct = try fusedExec(H, allocator, module, callee, argv[0..c.n_args], host);
            const r = direct orelse blk: {
                // A runtime gate (bank depth, a host-owned or partial callee) can decline what the classifier
                // admitted. A full callee run framed stays non-suspending, so the seam fallback is sound.
                if (fusedVerdict(H, host, module, callee) != 1) return error.Materialize;
                var arg_list: std.ArrayList(Value) = .empty;
                try arg_list.appendSlice(allocator, argv[0..c.n_args]);
                if (runtime.reclaimEnabled()) for (arg_list.items) |v| v.retain();
                break :blk try evalWithCapturesChained(H, allocator, module, null, callee, arg_list, .empty, &.{}, null, host);
            };
            switch (r) {
                .ok => |v| {
                    if (runtime.envOnce("KLIO_FUSED_CALL_TRACE")) |w| {
                        if (std.mem.find(u8, callee.name, w) != null) {
                            std.debug.print("[fused-call] {s} in {s} -> {s}", .{ callee.name, func.name, @tagName(std.meta.activeTag(v)) });
                            switch (v) {
                                .Long => |l| std.debug.print(" L{d}", .{l}),
                                .Int => |iv| std.debug.print(" I{d}", .{iv}),
                                .Double => |d| std.debug.print(" D{d}", .{d}),
                                else => {},
                            }
                            std.debug.print(" direct={}\n", .{direct != null});
                        }
                    }
                    fusedWrite(allocator, regs, c.dst, v, reclaim, false);
                },
                .err => |e| return fusedRaise(e),
            }
        },
        else => return error.Materialize,
    }
}
