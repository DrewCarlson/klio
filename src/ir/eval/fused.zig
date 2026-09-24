//! The fused tier: straight-line functions executed off a register bank
//! with no frame, no try stack, and no activation.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const span = @import("span");

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
const ownReceiverEntry = exec_call.ownReceiverEntry;
const sameReceiver = exec_call.sameReceiver;

const parent = @import("../eval.zig");
const ev_activation = @import("activation.zig");
const ev_chain = @import("chain.zig");
const ev_enter = @import("enter.zig");
const ev_exec = @import("exec.zig");
const ev_diag = @import("diag.zig");
const ev_flow = @import("flow.zig");
const ev_frame = @import("frame.zig");
const ev_inst = @import("inst.zig");
const ev_leaf = @import("leaf.zig");
const ev_loop = @import("loop.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");
const ev_values = @import("values.zig");
const ev_resolved = @import("resolved.zig");

const EnclosingEntry = ev_state.EnclosingEntry;
const EvalError = ev_state.EvalError;
const EvalResult = ev_flow.EvalResult;
const EvalTls = ev_state.EvalTls;
const Frame = ev_frame.Frame;
const FusedMark = ev_state.FusedMark;
const LEAF_BANK_DEPTH = ev_leaf.LEAF_BANK_DEPTH;
const TryFrame = ev_snapshot.TryFrame;
const binopValue = ev_inst.binopValue;
const chainAllocator = ev_chain.chainAllocator;
const coerceGenericIntPeersToLong = ev_enter.coerceGenericIntPeersToLong;
const coerceIntArgsToLong = ev_enter.coerceIntArgsToLong;
const coercePlanFor = ev_enter.coercePlanFor;
const constToValue = ev_values.constToValue;
const evalWithCapturesChained = ev_enter.evalWithCapturesChained;
const frameBoundary = ev_enter.frameBoundary;
const gcInstallFrameRoot = ev_state.gcInstallFrameRoot;
const gcPopFrame = ev_state.gcPopFrame;
const gcPushFrame = ev_state.gcPushFrame;
const lateinitThrow = ev_flow.lateinitThrow;
const ok = ev_flow.ok;
const popEnclosing = ev_chain.popEnclosing;
const pushEnclosingAccess = ev_chain.pushEnclosingAccess;
const pushEnclosingSubject = ev_chain.pushEnclosingSubject;
const runFrame = ev_activation.runFrame;
const scalarBin = ev_exec.scalarBin;
const valueTruthy = ev_values.valueTruthy;

pub const FUSED_MAX_REGS: usize = 128;

pub const FUSED_BANK_DEPTH: usize = 24;

/// `KLIO_FUSE_MAX_BLOCKS` overrides, so the cap can be priced rather than
/// assumed: it is a bound on classification work, not a storage limit, and
/// it was the only one of the three that rejected anything.
const FUSED_MAX_BLOCKS_DEFAULT: usize = 64;
var fused_max_blocks_cached: usize = 0;
fn fusedMaxBlocks() usize {
    if (fused_max_blocks_cached == 0) {
        fused_max_blocks_cached = FUSED_MAX_BLOCKS_DEFAULT;
        if (runtime.envOnce("KLIO_FUSE_MAX_BLOCKS")) |v| {
            fused_max_blocks_cached = std.fmt.parseInt(usize, v, 10) catch FUSED_MAX_BLOCKS_DEFAULT;
        }
    }
    return fused_max_blocks_cached;
}

const FUSED_MAX_INSTS: usize = 256;

/// All per-thread walker state in one threadlocal, so the base resolves once per activation.
const FusedTls = struct {
    bank: [FUSED_BANK_DEPTH][FUSED_MAX_REGS]Value = undefined,
    chain: [FUSED_BANK_DEPTH]std.ArrayList(EnclosingEntry) = @splat(.empty),
    marks: [FUSED_BANK_DEPTH]FusedMark = undefined,
    depth: usize = 0,
};

/// One copy per thread; see `runtime.tls_fast.PerThread`.
const fused_tls = runtime.tls_fast.PerThread(FusedTls);

pub inline fn fusedTls() *FusedTls {
    return fused_tls.get();
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

/// Why `fusedClassify` refused a body. `classify` is 4 960 of a compose
/// program's 5 406 fused declines and had no breakdown, so which of its
/// dozen conditions actually costs the frames could not be read.
pub const ClassifyReject = enum(u8) {
    suspend_or_lambda,
    block_count,
    register_count,
    vararg_or_default_param,
    handler_block,
    inst_count,
    terminator,
    type_var_cast,
    type_var_instanceof,
    suspend_resume_point,
    unsupported_inst,
    /// An instruction lowered from sema, which only the frame interpreter runs.
    resolved_inst,
    heavy_entry_prefix,
};
pub var classify_rejects: [@typeInfo(ClassifyReject).@"enum".fields.len]std.atomic.Value(usize) =
    @splat(std.atomic.Value(usize).init(0));

fn reject(r: ClassifyReject) u8 {
    _ = classify_rejects[@intFromEnum(r)].fetchAdd(1, .monotonic);
    return 2;
}

pub fn classifyRejectDump() void {
    if (runtime.envOnce("KLIO_FUSE_CLASSIFY") == null) return;
    inline for (@typeInfo(ClassifyReject).@"enum".fields) |f| {
        const n = classify_rejects[f.value].load(.monotonic);
        if (n != 0) std.debug.print("[fuse-classify] {d:>8}  {s}\n", .{ n, f.name });
    }
}

/// `KLIO_FUSE_HEAVY=1`: what makes a body heavy, which is what the entry
/// declines when it may not materialize. Resolution is supposed to have
/// made the dispatch cases tractable, so they are counted apart by whether
/// the site names its target.
pub var heavy_reasons: [7]std.atomic.Value(usize) = @splat(std.atomic.Value(usize).init(0));
var heavy_probe_state: u8 = 0;

pub fn heavyProbeOn() bool {
    if (heavy_probe_state == 0)
        heavy_probe_state = if (runtime.envOnce("KLIO_FUSE_HEAVY") != null) 2 else 1;
    return heavy_probe_state == 2;
}

pub fn heavyReasonDump() void {
    if (!heavyProbeOn()) return;
    const names = [_][]const u8{
        "call_virtual_slot",  "call_member_resolved", "call_member_by_name",
        "call_named_or_typeargs", "call_no_callee", "call_arity", "call_callee_not_fusable",
    };
    for (names, 0..) |n, i| {
        const v = heavy_reasons[i].load(.monotonic);
        if (v != 0) std.debug.print("[fuse-heavy] {d:>8}  {s}\n", .{ v, n });
    }
}

fn fusedClassify(comptime H: type, host: *H, module: *const Module, func: *const Func) u8 {
    if (func.is_suspend or func.is_lambda) return reject(.suspend_or_lambda);
    // A generic signature is not itself a reason to decline. What the walker cannot
    // serve is `as T` / `is T`, which consults the frame's reified context, and the
    // Cast and InstanceOf ops are guarded for exactly that below. The argument side
    // is covered too: `fusedRun` applies the same `coercePlanFor` widening the framed
    // entry does, including the type-variable peer rule.

    if (func.blocks.len == 0 or func.blocks.len > fusedMaxBlocks()) return reject(.block_count);
    if (func.n_locals > FUSED_MAX_REGS) return reject(.register_count);
    for (func.params) |*p| {
        if (p.is_vararg or p.default != null) return reject(.vararg_or_default_param);
    }
    var heavy = false;
    var total: usize = 0;
    // Fusable instructions the ENTRY block runs before its first heavy op.
    var entry_prefix: usize = 0;
    var entry_heavy = false;
    for (func.blocks, 0..) |*b, bi| {
        if (b.h().catches.len != 0 or b.h().finally != null) return reject(.handler_block);
        total += b.insts.len;
        if (total > FUSED_MAX_INSTS) return reject(.inst_count);
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
                .Trace, .Const, .Move, .LoadParam, .BinOp, .Not, .NotNullAssert, .LateinitCheck, .MakeCell, .CellGet, .CellSet => {},
                // A static call lowered from sema: its target is its id,
                // run fused when it fuses, or its native.
                .CallStatic => |cs| blk: {
                    const callee = module.funcById(cs.func) orelse {
                        heavy = true;
                        break :blk;
                    };
                    // A suspending native parks its caller, which only a
                    // frame can do.
                    if (staticNative(module, cs.func) != null) {
                        if (callee.is_suspend) heavy = true;
                        break :blk;
                    }
                    _ = module.ensureFuncBody(@constCast(callee));
                    if (callee.params.len != cs.n_args or fusedVerdict(H, host, module, callee) != 1) heavy = true;
                },
                // Lowered from sema: only the frame interpreter runs these.
                .RCallVirtual,
                .CallInterface,
                .CallNative,
                .RCallValue,
                .RNewInstance,
                .GetFieldSlot,
                .SetFieldSlot,
                .LoadStatic,
                .StoreStatic,
                .LoadObject,
                .MakeClosure,
                .FunctionRef,
                .RPropertyRef,
                .ClassLiteral,
                .ClassOf,
                .RInstanceOf,
                .RCast,
                .InstanceOfDyn,
                .CastDyn,
                .ArrayGet,
                .ArraySet,
                .NewArray,
                => return reject(.resolved_inst),
                else => heavy = true,
            }
        }
    }
    if (heavy and entry_heavy and entry_prefix < fused_min_prefix) return reject(.heavy_entry_prefix);
    return if (heavy) 4 else 1;
}

fn isCallInst(inst: *const ir.Inst) bool {
    return inst.* == .CallStatic;
}

/// The native a static call lowered from sema runs, if its target is one.
fn staticNative(module: *const Module, func: ir.FuncId) ?ir.NativeId {
    const r = module.resolved orelse return null;
    if (func.int() >= r.func_native.len) return null;
    const nid = r.func_native[func.int()];
    return if (nid == .none) null else nid;
}

/// A heavy body whose fusable entry prefix is shorter than this runs framed outright.
const fused_min_prefix: usize = 24;

const FusedFail = error{ Raise, Materialize } || Allocator.Error;

threadlocal var fused_err: EvalError = undefined;

inline fn fusedRaise(e: EvalError) FusedFail {
    fused_err = e;
    return error.Raise;
}

/// `KLIO_FUSE_DECLINE=1`: one line per activation the frameless tier turned
/// away, naming the gate and the function, so the declines can be counted by
/// weight rather than by distinct function.
var fuse_decline_state: u8 = 0;

fn fusedDecline(reason: []const u8, func: *const Func) void {
    if (fuse_decline_state == 0) {
        fuse_decline_state = if (runtime.envOnce("KLIO_FUSE_DECLINE") != null) 2 else 1;
    }
    if (fuse_decline_state != 2) return;
    std.debug.print("[fuse-decline] {s} {s}\n", .{ reason, if (func.fqn.len != 0) func.fqn else func.name });
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
    if (verdict == 2) {
        fusedDecline("classify", func);
        return null;
    }
    if (verdict == 4 and !allow_materialize) {
        fusedDecline("partial-no-materialize", func);
        return null;
    }
    if (args.len != func.params.len) {
        fusedDecline("arity", func);
        return null;
    }
    // An inner-class member's bare reads reach the enclosing instance, which the walker does
    // not model, so a receiver carrying an outer declines.
    if (args.len > 0 and args[0] == .Instance) {
        const g = args[0].Instance.borrow();
        const has_outer = g.get().outer != null;
        g.deinit();
        if (has_outer) {
            fusedDecline("receiver-has-outer", func);
            return null;
        }
    }
    if (fusedTls().depth >= FUSED_BANK_DEPTH) {
        fusedDecline("bank-depth", func);
        return null;
    }
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
    const ev: *EvalTls = ev_state.evtlsPtr();
    const ka = runtime.keepaliveHandle();
    const reclaim = runtime.reclaimEnabled();
    var eff_args = args_in;
    {
        const plan = coercePlanFor(module, func);
        if (plan & 6 != 0 and args_in.len <= ir.LEAF_MAX_REGS) {
            const coerce_buf: []Value = ev_leaf.leafBanks().coerce[ft.depth % LEAF_BANK_DEPTH][0..args_in.len];
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
    // KLIO_FN_PROF: the fused body is the executing function, not its last framed caller.
    const fn_prof_prev = runtime.prof.current_fn;
    if (runtime.prof.fn_prof_active) runtime.prof.current_fn = func.id.int();
    defer if (runtime.prof.fn_prof_active) {
        runtime.prof.current_fn = fn_prof_prev;
    };

    var cur: BlockId = func.entry;
    walk: while (true) {
        // Once per block, UNCONDITIONAL: `pending()` never sees another thread's stop flag, so
        // gating on it lets a fused spin loop skip the rendezvous. The pinned bank keeps it root-exact.
        if (runtime.gc.gc_enabled) runtime.gc.safePoint();
        const blk = &func.blocks[cur.int()];
        const blk_id = cur.int();
        for (blk.insts, 0..) |*inst, idx| {
            fusedInst(H, allocator, module, eff_args, host, inst, regs, reclaim, mark) catch |e| switch (e) {
                // Code lowered from sema throws the base's exception classes,
                // which the framed arms build: an instruction's own failure
                // runs there. A call's failure is its callee's throwable.
                error.Raise => if (module.resolved == null or isCallInst(inst)) return .{ .err = fused_err } else {
                    return try fusedMaterializeAndRun(H, allocator, module, func, args_in, regs, cur, idx, host);
                },
                // A heavy op: build the real Frame from the bank and run the remainder framed, starting AT
                // this instruction, no side effect of which has run. The frame owns any suspension beneath it.
                error.Materialize => {
                    return try fusedMaterializeAndRun(H, allocator, module, func, args_in, regs, cur, idx, host);
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
        }
        // A back edge takes the framed loop's edge guards, so a fused spin
        // loop meets the wall cap and abandonment like any other.
        if (cur.int() <= blk_id) {
            if (ev_exec.fusedEdgeGuard(allocator, ev)) |er| return er;
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
    host: *H,
) Allocator.Error!EvalResult {
    const ev: *EvalTls = ev_state.evtlsPtr();
    if (runtime.envOnce("KLIO_FUSED_TRACE") != null) {
        std.debug.print("[fused-mat] {s} at b{d}:{d}\n", .{ if (func.fqn.len != 0) func.fqn else func.name, cur.int(), idx });
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
    args: []const Value,
    host: *H,
    inst: *const Inst,
    regs: []Value,
    reclaim: bool,
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
        .CallStatic => |cs| {
            var argv: [FUSED_MAX_REGS]Value = undefined;
            if (cs.n_args > FUSED_MAX_REGS) return error.Materialize;
            // A callee's file not yet initialized: the framed arm runs its
            // init unit first.
            if (cs.init != ir.NO_UNIT) {
                if (comptime !@hasDecl(H, "resolvedState")) return error.Materialize;
                if (ev_resolved.unitPending(H, host, cs.init)) return error.Materialize;
            }
            var i: u32 = 0;
            while (i < cs.n_args) : (i += 1) argv[i] = fusedRead(regs, Reg.from(cs.args.int() + i));
            const r = if (staticNative(module, cs.func)) |nid| blk: {
                if (comptime !@hasDecl(H, "callNative")) return error.Materialize;
                // As `ev_resolved.runFunc` calls it: a receiver's override answers.
                if (comptime @hasDecl(H, "callNativeSite")) break :blk try host.callNativeSite(allocator, nid, argv[0..cs.n_args]);
                break :blk try host.callNative(allocator, nid, argv[0..cs.n_args]);
            } else blk: {
                const callee = module.funcById(cs.func) orelse return error.Materialize;
                if (callee.params.len != cs.n_args) return error.Materialize;
                if (try fusedExec(H, allocator, module, callee, argv[0..cs.n_args], host)) |res| break :blk res;
                // A runtime gate declined what the classifier admitted: the
                // callee runs framed, still without suspending.
                if (fusedVerdict(H, host, module, callee) != 1) return error.Materialize;
                var arg_list: std.ArrayList(Value) = .empty;
                try arg_list.appendSlice(allocator, argv[0..cs.n_args]);
                if (runtime.reclaimEnabled()) for (arg_list.items) |v| v.retain();
                break :blk try evalWithCapturesChained(H, allocator, module, null, callee, arg_list, .empty, &.{}, null, host);
            };
            switch (r) {
                .ok => |v| fusedWrite(allocator, regs, cs.dst, v, reclaim, false),
                .err => |e| return fusedRaise(e),
            }
        },
        else => return error.Materialize,
    }
}
