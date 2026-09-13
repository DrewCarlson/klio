//! The leaf tier: whole small functions served off a register bank without
//! opening a frame.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const bc = @import("../bc.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const BinOp = ir.BinOp;
const Const = ir.Const;
const Func = ir.Func;
const Inst = ir.Inst;
const Module = ir.Module;
const Reg = ir.Reg;

const exec_call = @import("../exec_call.zig");

const constStr = exec_call.constStr;
const fastIndexGet = exec_call.fastIndexGet;
const primitiveMemberOp = exec_call.primitiveMemberOp;

const ev_diag = @import("diag.zig");
const ev_enter = @import("enter.zig");
const ev_exec = @import("exec.zig");
const ev_flow = @import("flow.zig");
const ev_state = @import("state.zig");
const ev_values = @import("values.zig");

const EvalResult = ev_flow.EvalResult;
const EvalTls = ev_state.EvalTls;
const FlatCallReq = ev_flow.FlatCallReq;
const applyBinop = ev_values.applyBinop;
const coerceGenericIntPeersToLong = ev_enter.coerceGenericIntPeersToLong;
const coerceIntArgsToLong = ev_enter.coerceIntArgsToLong;
const coercePlanFor = ev_enter.coercePlanFor;
const constToValue = ev_values.constToValue;
const leafPrimitive = ev_enter.leafPrimitive;
const ok = ev_flow.ok;
const scalarBin = ev_exec.scalarBin;
const serveOuterSlotRoute = ev_diag.serveOuterSlotRoute;

/// Per-thread bank of leaf register files, one per nesting level. A stack
/// array would be `undefined`-filled on entry under the safety builds (and
/// zeroed under any build), which for a two-instruction accessor costs more
/// than the frame the serve replaces; the bank is initialised once per
/// thread and each level owns its slice for the serve's duration.
pub const LEAF_BANK_DEPTH: usize = 8;

threadlocal var leaf_bank: [LEAF_BANK_DEPTH][ir.LEAF_MAX_REGS]Value = undefined;

/// Scratch for the leaf serve's literal-typing coercion, per nesting level.
/// A per-call `[LEAF_MAX_REGS]Value = undefined` stack array paid a 2.5KB
/// safety-mode 0xAA fill on EVERY serve — 15% of the compose slot-table
/// benchmark's whole profile; the threadlocal bank is initialized once per
/// thread and reused.
pub threadlocal var coerce_bank: [LEAF_BANK_DEPTH][ir.LEAF_MAX_REGS]Value = undefined;

/// How far a leaf serve chains into other leaf callees. A gap-buffer read is
/// typically three levels (`groupSize` -> `groupIndexToAddress` -> the array
/// index helper); the bound keeps the native recursion trivially finite.
pub const LEAF_MAX_DEPTH: u8 = 8;

/// Raised by the walk when an instruction needs the frame path. Caught at the
/// serve boundary, where it becomes a plain "declined".
const LeafAbandon = error{LeafAbandon};

pub fn leafReqServable(req: FlatCallReq) bool {
    return req.captures.items.len == 0 and
        req.chain.len == 0 and
        req.closure_id == null and
        req.type_args.len == 0 and
        req.keepalive == null and
        req.typed_saved == null and
        req.ctx_mark_override == null and
        req.pop_enclosing_n == 0 and
        req.scope_guard_ident == 0 and
        !req.composer_pushed and
        !req.suspend_barrier and
        !req.root_pump and
        req.owning == null and
        req.func.leafExprBody();
}

pub fn leafExprServeAt(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
    depth: u8,
) Allocator.Error!?EvalResult {
    if (comptime !@hasDecl(H, "fieldSiteRoute")) return null;
    const trace = leafTraceWant(func);
    if (!func.leafExprBody()) {
        if (trace) std.debug.print("[leaf] {s}: not a leaf body\n", .{func.name});
        return null;
    }
    if (func.leaf_hopeless != 0) return null;
    if (args.len != func.params.len) {
        if (trace) std.debug.print("[leaf] {s}: arity {d} vs {d}\n", .{ func.name, args.len, func.params.len });
        return null;
    }
    // The literal-typing coercions a real frame push applies
    // (Frame.newWithCaptures) apply on this serve too: a bare Int flowing
    // into a declared Long param, or into a shared type-variable slot
    // beside a Long peer, is a Long-typed literal — `eq(0, 0L)` must
    // compare two Longs here exactly as on the framed path.
    const reclaim = runtime.reclaimEnabled();
    const ev: *EvalTls = &ev_state.evtls;
    if (ev.leaf_depth >= LEAF_BANK_DEPTH) return null;
    var eff_args = args;
    {
        const plan = coercePlanFor(module, func);
        if (plan & 6 != 0 and args.len <= ir.LEAF_MAX_REGS) {
            const coerce_buf: []Value = coerce_bank[ev.leaf_depth][0..args.len];
            @memcpy(coerce_buf, args);
            if (plan & 2 != 0) coerceIntArgsToLong(func, coerce_buf);
            if (plan & 4 != 0) coerceGenericIntPeersToLong(module, func, coerce_buf);
            eff_args = coerce_buf;
        }
    }
    // Only the body's own locals are live, and they come from the per-thread
    // bank rather than a fresh stack array.
    const nlive: usize = @min(@as(usize, func.n_locals), ir.LEAF_MAX_REGS);
    const regs: []Value = leaf_bank[ev.leaf_depth][0..nlive];
    ev.leaf_depth += 1;
    defer ev.leaf_depth -= 1;
    // A def-before-use-proven body never reads a stale slot, so the bank
    // keeps whatever the previous serve left; the fill stays for reclaim
    // builds (each write releases the slot's prior value, which must be
    // live) and unproven bodies. `wmask` tracks which slots the serve has
    // written so a lazy pin can zero the rest first (the keepalive pins the
    // whole slice, and a stale slot must not reach the collector).
    var wmask: u64 = 0;
    if (reclaim) {
        for (regs) |*v| v.* = .Unit;
        wmask = ~@as(u64, 0);
    }
    defer if (reclaim) {
        for (regs) |*v| v.release(allocator);
    };
    // The register file is a native local, invisible to the collector's frame
    // walk, so an instruction that can allocate must pin it first or a
    // collection could sweep an intermediate. Pinning is deferred to the
    // first such instruction: a plain field-and-arithmetic accessor — the
    // shape this exists for — reaches no safe point and pays nothing.
    var pin: ?usize = null;
    defer if (pin) |m| runtime.keepaliveRestore(m);
    const fs: ?*const bc.FuncStreams = if (bc.enabled())
        bc.funcStreams(func, !func.bc_jit_owned, module.consts.items)
    else
        null;
    const out = (if (fs) |f|
        leafWalkStream(H, allocator, module, func, eff_args, host, depth, regs, reclaim, trace, &pin, &wmask, f)
    else
        leafWalk(H, allocator, module, func, eff_args, host, depth, regs, reclaim, trace, &pin, &wmask)) catch |e| switch (e) {
        error.LeafAbandon => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    // The register file is released on the way out; the caller owns one
    // reference to the result, exactly as a returning frame would hand over.
    out.retain();
    return EvalResult{ .ok = out };
}

/// The leaf walk over the function's DENSE bytecode stream: the same op
/// set the framed flat loop runs, over the leaf bank. The Inst-union
/// re-walk this replaces was the single largest cost of call-dense
/// interpreted code (~35% of a 3M-call benchmark); simple ops decode from
/// packed u32s here, and only the complex ops (`escape`) touch the union,
/// through the same `leafRunOne` the fallback walker uses. Any structure
/// the stream cannot express abandons to the framed path exactly as the
/// union walker would.
fn leafWalkStream(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
    depth: u8,
    regs: []Value,
    reclaim: bool,
    trace: bool,
    pin: *?usize,
    wmask: *u64,
    fs: *const bc.FuncStreams,
) (Allocator.Error || LeafAbandon)!Value {
    var block: usize = 0;
    var steps: usize = 0;
    outer: while (true) {
        if (block >= func.blocks.len) return error.LeafAbandon;
        const st = (if (block < fs.streams.len) fs.streams[block] else null) orelse return error.LeafAbandon;
        const code = st.code;
        var pc: usize = 0;
        while (pc < code.len) {
            steps += 1;
            if (steps > ir.LEAF_MAX_STEPS) return error.LeafAbandon;
            const op: bc.Op = @enumFromInt(code[pc]);
            switch (op) {
                .trace => pc += 4,
                .const_int => {
                    if (!leafWrite(allocator, regs, @enumFromInt(code[pc + 1]), .{ .Int = @bitCast(code[pc + 2]) }, reclaim, false, wmask)) return error.LeafAbandon;
                    pc += 3;
                },
                .const_load => {
                    const cid = code[pc + 2];
                    if (cid >= module.consts.items.len) return error.LeafAbandon;
                    if (module.consts.items[cid] == .String) leafPin(pin, regs, wmask);
                    const v = try constToValue(allocator, &module.consts.items[cid]);
                    if (!leafWrite(allocator, regs, @enumFromInt(code[pc + 1]), v, reclaim, false, wmask)) return error.LeafAbandon;
                    pc += 3;
                },
                .move => {
                    const v = leafRead(regs, wmask.*, @enumFromInt(code[pc + 2])) orelse return error.LeafAbandon;
                    if (!leafWrite(allocator, regs, @enumFromInt(code[pc + 1]), v, reclaim, true, wmask)) return error.LeafAbandon;
                    pc += 3;
                },
                .load_param => {
                    const pi = code[pc + 2];
                    if (pi >= args.len) return error.LeafAbandon;
                    if (!leafWrite(allocator, regs, @enumFromInt(code[pc + 1]), args[pi], reclaim, true, wmask)) return error.LeafAbandon;
                    pc += 3;
                },
                .cell_get => return error.LeafAbandon,
                .bin => {
                    const kind: ir.BinOp = @enumFromInt(code[pc + 2]);
                    const l = leafRead(regs, wmask.*, @enumFromInt(code[pc + 4])) orelse return error.LeafAbandon;
                    const r = leafRead(regs, wmask.*, @enumFromInt(code[pc + 5])) orelse return error.LeafAbandon;
                    if (scalarBin(kind, l, r)) |v| {
                        if (!leafWrite(allocator, regs, @enumFromInt(code[pc + 3]), v, reclaim, false, wmask)) return error.LeafAbandon;
                    } else {
                        if (!leafPrimitive(&l) or !leafPrimitive(&r)) return error.LeafAbandon;
                        const res = try applyBinop(allocator, kind, &l, &r);
                        if (res != .ok) return error.LeafAbandon;
                        if (!leafWrite(allocator, regs, @enumFromInt(code[pc + 3]), res.ok, reclaim, false, wmask)) return error.LeafAbandon;
                    }
                    pc += 6;
                },
                .escape => {
                    const inst_idx = code[pc + 1];
                    const b = &func.blocks[block];
                    if (inst_idx >= b.insts.len) return error.LeafAbandon;
                    try leafRunOne(H, allocator, module, func, args, host, depth, &b.insts[inst_idx], regs, reclaim, trace, pin, wmask);
                    pc += 2;
                },
                .jump => {
                    block = code[pc + 1];
                    continue :outer;
                },
                .br => {
                    const c = leafRead(regs, wmask.*, @enumFromInt(code[pc + 1])) orelse return error.LeafAbandon;
                    if (c != .Bool) return error.LeafAbandon;
                    block = if (c.Bool) code[pc + 2] else code[pc + 3];
                    continue :outer;
                },
                .ret => {
                    if (code[pc + 1] == 0) return .Unit;
                    return leafRead(regs, wmask.*, @enumFromInt(code[pc + 2])) orelse error.LeafAbandon;
                },
                .term_exit => break,
                .cmp_br => {
                    const kind: ir.BinOp = @enumFromInt(code[pc + 2]);
                    const l = leafRead(regs, wmask.*, @enumFromInt(code[pc + 4])) orelse return error.LeafAbandon;
                    const r = leafRead(regs, wmask.*, @enumFromInt(code[pc + 5])) orelse return error.LeafAbandon;
                    const v = scalarBin(kind, l, r) orelse return error.LeafAbandon;
                    if (!leafWrite(allocator, regs, @enumFromInt(code[pc + 3]), v, reclaim, false, wmask)) return error.LeafAbandon;
                    if (v != .Bool) return error.LeafAbandon;
                    block = if (v.Bool) code[pc + 6] else code[pc + 7];
                    continue :outer;
                },
            }
        }
        // Off the stream's end (or `term_exit`): the block's REAL
        // terminator decides, exactly as the union walker's loop does.
        switch (func.blocks[block].terminator) {
            .Return => |r| {
                const rr = r orelse return .Unit;
                return leafRead(regs, wmask.*, rr) orelse return error.LeafAbandon;
            },
            .Goto => |g| block = g.int(),
            .Branch => |br| {
                const c = leafRead(regs, wmask.*, br.cond) orelse return error.LeafAbandon;
                if (c != .Bool) return error.LeafAbandon;
                block = if (c.Bool) br.t.int() else br.f.int();
            },
            else => return error.LeafAbandon,
        }
    }
}

/// Walk the body's blocks until one returns. `Goto`/`Branch` are followed;
/// everything else about the body was admitted structurally, and any
/// individual instruction the serve cannot execute abandons here.
fn leafWalk(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
    depth: u8,
    regs: []Value,
    reclaim: bool,
    trace: bool,
    pin: *?usize,
    wmask: *u64,
) (Allocator.Error || LeafAbandon)!Value {
    var block_idx: usize = 0;
    var steps: usize = 0;
    while (true) {
        if (block_idx >= func.blocks.len) return error.LeafAbandon;
        const b = &func.blocks[block_idx];
        steps += b.insts.len + 1;
        if (steps > ir.LEAF_MAX_STEPS) return error.LeafAbandon;
        try leafRunInsts(H, allocator, module, func, args, host, depth, b, regs, reclaim, trace, pin, wmask);
        switch (b.terminator) {
            .Return => |r| {
                const rr = r orelse return .Unit;
                return leafRead(regs, wmask.*, rr) orelse return error.LeafAbandon;
            },
            .Goto => |g| block_idx = g.int(),
            .Branch => |br| {
                const c = leafRead(regs, wmask.*, br.cond) orelse return error.LeafAbandon;
                if (c != .Bool) {
                    if (trace) std.debug.print("[leaf] {s}: branch on {s}\n", .{ func.name, @tagName(c) });
                    return error.LeafAbandon;
                }
                block_idx = if (c.Bool) br.t.int() else br.f.int();
            },
            // A guard's throwing arm is admitted structurally but never
            // executed here: raising needs the frame path's unwind machinery.
            // `leafExprBody` admits no other terminator.
            else => return error.LeafAbandon,
        }
    }
}

fn leafRunInsts(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
    depth: u8,
    b: *const ir.Block,
    regs: []Value,
    reclaim: bool,
    trace: bool,
    pin: *?usize,
    wmask: *u64,
) (Allocator.Error || LeafAbandon)!void {
    for (b.insts) |*inst| {
        try leafRunOne(H, allocator, module, func, args, host, depth, inst, regs, reclaim, trace, pin, wmask);
    }
}

/// One leaf-body instruction — shared by the Inst-union walker above and
/// the dense-stream walker (`leafWalkStream`), whose `escape` ops land
/// here.
fn leafRunOne(
    comptime H: type,
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    host: *H,
    depth: u8,
    inst: *const Inst,
    regs: []Value,
    reclaim: bool,
    trace: bool,
    pin: *?usize,
    wmask: *u64,
) (Allocator.Error || LeafAbandon)!void {
    {
        switch (inst.*) {
            .Trace => {},
            .LoadParam => |lp| {
                if (lp.idx >= args.len) return error.LeafAbandon;
                if (!leafWrite(allocator, regs, lp.dst, args[lp.idx], reclaim, true, wmask)) return error.LeafAbandon;
            },
            .Const => |c| {
                if (c.value.int() >= module.consts.items.len) return error.LeafAbandon;
                if (module.consts.items[c.value.int()] == .String) leafPin(pin, regs, wmask);
                const v = try constToValue(allocator, &module.consts.items[c.value.int()]);
                if (!leafWrite(allocator, regs, c.dst, v, reclaim, false, wmask)) return error.LeafAbandon;
            },
            .Move => |mv| {
                const v = leafRead(regs, wmask.*, mv.src) orelse return error.LeafAbandon;
                if (!leafWrite(allocator, regs, mv.dst, v, reclaim, true, wmask)) return error.LeafAbandon;
            },
            .Not => |n| {
                const v = leafRead(regs, wmask.*, n.src) orelse return error.LeafAbandon;
                if (v != .Bool) return error.LeafAbandon;
                if (!leafWrite(allocator, regs, n.dst, .{ .Bool = !v.Bool }, reclaim, false, wmask)) return error.LeafAbandon;
            },
            .BinOp => |bo| {
                const l = leafRead(regs, wmask.*, bo.lhs) orelse return error.LeafAbandon;
                const r = leafRead(regs, wmask.*, bo.rhs) orelse return error.LeafAbandon;
                if (scalarBin(bo.op, l, r)) |v| {
                    if (!leafWrite(allocator, regs, bo.dst, v, reclaim, false, wmask)) return error.LeafAbandon;
                    return;
                }
                if (!leafPrimitive(&l) or !leafPrimitive(&r)) return error.LeafAbandon;
                const res = try applyBinop(allocator, bo.op, &l, &r);
                if (res != .ok) return error.LeafAbandon;
                if (!leafWrite(allocator, regs, bo.dst, res.ok, reclaim, false, wmask)) return error.LeafAbandon;
            },
            .GetField => |gf| {
                const recv = leafRead(regs, wmask.*, gf.receiver) orelse return error.LeafAbandon;
                if (gf.field.int() >= module.consts.items.len) return error.LeafAbandon;
                const fname: []const u8 = switch (module.consts.items[gf.field.int()]) {
                    .String => |s| s,
                    else => return error.LeafAbandon,
                };
                if (try builtinFieldFast(H, host, allocator, &recv, fname)) |bv| {
                    if (!leafWrite(allocator, regs, gf.dst, bv, reclaim, false, wmask)) return error.LeafAbandon;
                    return;
                }
                if (recv != .Instance) {
                    if (trace) std.debug.print("[leaf] {s}: field receiver is {s}\n", .{ func.name, @tagName(recv) });
                    return error.LeafAbandon;
                }
                const v = try leafStoredField(H, allocator, host, &inst.GetField, &recv, fname, pin, regs, wmask) orelse {
                    if (trace) std.debug.print("[leaf] {s}: no stored-slot route for {s}\n", .{ func.name, fname });
                    return error.LeafAbandon;
                };
                if (!leafWrite(allocator, regs, gf.dst, v, reclaim, false, wmask)) return error.LeafAbandon;
            },
            .CallMember => |cm| {
                // The value-level fast serves only: a primitive bit/conversion
                // member is a pure function of its receiver and argument, so
                // the frameless walk can run it. The gap-buffer and trie
                // helpers this exists for (`indexSegment`, the mask/shift
                // predicates) are otherwise a full activation per bit twiddle.
                if (cm.arg_names.len != 0 or cm.n_args > 1) return error.LeafAbandon;
                const recv = leafRead(regs, wmask.*, cm.receiver) orelse return error.LeafAbandon;
                const nm = constStr(module, cm.name) orelse return error.LeafAbandon;
                const marg: ?Value = if (cm.n_args == 1)
                    (leafRead(regs, wmask.*, Reg.from(cm.args.int())) orelse return error.LeafAbandon)
                else
                    null;
                const mv = primitiveMemberOp(&recv, nm, marg) orelse blk: {
                    // `data[idx]` on a container lowers as a `get` member
                    // call in accessor bodies; serve it exactly as the
                    // `.Index` arm below does (a bounds miss abandons to
                    // the framed path, which raises properly).
                    if (marg) |ia| {
                        if (std.mem.eql(u8, nm, "get")) {
                            if (fastIndexGet(&recv, &ia)) |v| break :blk v;
                        }
                    }
                    if (trace) std.debug.print("[leaf] {s}: member {s} is not a primitive op\n", .{ func.name, nm });
                    return error.LeafAbandon;
                };
                if (!leafWrite(allocator, regs, cm.dst, mv, reclaim, false, wmask)) return error.LeafAbandon;
            },
            .Index => |ix| {
                const recv = leafRead(regs, wmask.*, ix.receiver) orelse return error.LeafAbandon;
                const idx = leafRead(regs, wmask.*, ix.index) orelse return error.LeafAbandon;
                const v = fastIndexGet(&recv, &idx) orelse {
                    if (trace) std.debug.print("[leaf] {s}: index needs the slow get\n", .{func.name});
                    return error.LeafAbandon;
                };
                if (!leafWrite(allocator, regs, ix.dst, v, reclaim, false, wmask)) return error.LeafAbandon;
            },
            .LoadGlobal => |lg| {
                // Only a plain-name scalar read is servable: an identity-
                // resolved binding is a function/class value, and anything
                // non-scalar may need the singleton/init/delegate machinery.
                if (comptime !@hasDecl(H, "leafGlobalGet")) return error.LeafAbandon;
                if (lg.func != null or lg.class != null or lg.ctor_ref) return error.LeafAbandon;
                const gname = constStr(module, lg.name) orelse return error.LeafAbandon;
                const v = host.leafGlobalGet(gname) orelse {
                    if (trace) std.debug.print("[leaf] {s}: global {s} not servable\n", .{ func.name, gname });
                    return error.LeafAbandon;
                };
                if (!leafWrite(allocator, regs, lg.dst, v, reclaim, false, wmask)) return error.LeafAbandon;
            },
            .Call => |c| {
                if (depth == 0) return error.LeafAbandon;
                if (comptime !@hasDecl(H, "funcRunsItsBody")) return error.LeafAbandon;
                if (c.arg_names.len != 0 or c.type_args.len != 0) return error.LeafAbandon;
                const callee = module.funcById(c.func) orelse return error.LeafAbandon;
                _ = module.ensureFuncBody(@constCast(callee));
                if (!callee.leafExprBody()) {
                    if (trace) {
                        var ninsts: usize = 0;
                        for (callee.blocks) |*cb| ninsts += cb.insts.len;
                        var why: []const u8 = "?";
                        var pflag = false;
                        for (callee.params) |*cp| {
                            if (cp.is_vararg or cp.default != null) pflag = true;
                        }
                        if (pflag) why = "param-default-or-vararg";
                        for (callee.blocks) |*cb| {
                            if (cb.catches.len != 0 or cb.finally != null or cb.lr_absorb != null) why = "try-region";
                            switch (cb.terminator) {
                                .Return, .Goto, .Branch, .Throw, .Unreachable => {},
                                else => |t| {
                                    if (std.mem.eql(u8, why, "?")) why = @tagName(t);
                                },
                            }
                        }
                        std.debug.print("[leaf] {s}: callee {s}#{d} is not a leaf why={s} (blocks={d} locals={d} insts={d} lambda={} suspend={} hopeless={d} state={d})\n", .{
                            func.name, callee.name, callee.id.int(), why, callee.blocks.len, callee.n_locals, ninsts, callee.is_lambda, callee.is_suspend, callee.leaf_hopeless, callee.leaf_state,
                        });
                    }
                    return error.LeafAbandon;
                }
                // A symbol the link step settled onto a native binding, or one
                // that redirects to a sibling declaration, does not run this
                // body at all.
                if (!host.funcRunsItsBody(c.func)) {
                    if (trace) std.debug.print("[leaf] {s}: callee {s} resolves elsewhere\n", .{ func.name, callee.name });
                    return error.LeafAbandon;
                }
                const base = c.args.int();
                if (base + c.n_args > regs.len) return error.LeafAbandon;
                // The arg slice reads raw slots: settle any not-yet-written
                // one to the fill value first (the lazy-fill invariant every
                // masked read enforces individually).
                var ai: usize = base;
                while (ai < base + c.n_args) : (ai += 1) {
                    if (ai < 64 and (wmask.* >> @as(u6, @intCast(ai))) & 1 == 0) {
                        regs[ai] = .{ .Unit = {} };
                        wmask.* |= @as(u64, 1) << @as(u6, @intCast(ai));
                    }
                }
                leafPin(pin, regs, wmask);
                const r = try leafExprServeAt(H, allocator, module, callee, regs[base .. base + c.n_args], host, depth - 1) orelse
                    return error.LeafAbandon;
                if (r != .ok) return error.LeafAbandon;
                if (!leafWrite(allocator, regs, c.dst, r.ok, reclaim, false, wmask)) return error.LeafAbandon;
            },
            else => |other| {
                if (trace) std.debug.print("[leaf] {s}: unsupported {s}\n", .{ func.name, @tagName(other) });
                // Structural: this instruction can never serve, so no
                // future attempt on this body can succeed.
                @constCast(func).leaf_hopeless = 1;
                return error.LeafAbandon;
            },
        }
    }
}

/// `KLIO_LEAF_TRACE=<name>` — report why the frameless leaf serve declined
/// for a matching function.
var leaf_trace_state: u8 = 0;

var leaf_trace_want: []const u8 = "";

fn leafTraceWant(func: *const Func) bool {
    if (leaf_trace_state == 0) {
        leaf_trace_want = runtime.envOnce("KLIO_LEAF_TRACE") orelse "";
        leaf_trace_state = 1;
    }
    if (leaf_trace_want.len == 0) return false;
    if (leaf_trace_want.len == 1 and leaf_trace_want[0] == '*') return true;
    return std.mem.find(u8, func.name, leaf_trace_want) != null;
}

/// The declared members of a builtin receiver that no user declaration can
/// shadow and that the field ladder reaches only after some sixty name
/// comparisons. Array length reads dominate the slow-ladder field census on a
/// composition workload, so answer them without entering the ladder.
pub fn builtinFieldFast(comptime H: type, host: *H, allocator: Allocator, recv: *const Value, name: []const u8) Allocator.Error!?Value {
    // `indices` / `lastIndex` over any host container with a direct
    // length: the same answers the host field arm computes, minus the
    // ladder. The map CAS loop's `fastForEach` read `List.indices`
    // through the slow ladder 220k times in one run. Both names are
    // SHADOWABLE stdlib extension properties, so the serve is gated on
    // the host's program-wide verdict that no user declaration shadows
    // them (a user `List.indices` must win through the ladder).
    if (std.mem.eql(u8, name, "indices") or std.mem.eql(u8, name, "lastIndex")) {
        const servable = if (comptime @hasDecl(H, "builtinIndexPropsServable")) host.builtinIndexPropsServable() else false;
        if (!servable) return null;
        const len: ?i64 = switch (recv.*) {
            .Array => |a| @intCast(a.len()),
            .List => |l| if (l.backing == null) blk: {
                const g = l.items.borrow();
                defer g.deinit();
                break :blk @intCast(g.get().items.len);
            } else null,
            .Set => |st| if (st.backing == null) blk: {
                const g = st.items.borrow();
                defer g.deinit();
                break :blk @intCast(g.get().items.len);
            } else null,
            else => null,
        };
        if (len) |n| {
            if (name.len == 9) return Value.newInt(@intCast(n - 1));
            return try Value.newRange(allocator, .{ .start = 0, .end = n - 1, .step = 1, .kind = .Int });
        }
    }
    switch (recv.*) {
        .Array => |a| if (std.mem.eql(u8, name, "size")) {
            return Value.newInt(@intCast(a.len()));
        },
        .String => |s| if (std.mem.eql(u8, name, "length")) {
            const g = s.borrow();
            defer g.deinit();
            return Value.newInt(@intCast(g.get().u16_len));
        },
        // Plain container sizes: `backing != null` marks a live VIEW
        // (`subList`, a map's `values`), whose length the view machinery
        // computes — only backing-free containers read their own item
        // list here. `Stack.size` -> `backing.size` otherwise paid the
        // slow field ladder on every read (678k in one recompose test).
        .List => |l| if (l.backing == null and std.mem.eql(u8, name, "size")) {
            const g = l.items.borrow();
            defer g.deinit();
            return Value.newInt(@intCast(g.get().items.len));
        },
        .Set => |st| if (st.backing == null and std.mem.eql(u8, name, "size")) {
            const g = st.items.borrow();
            defer g.deinit();
            return Value.newInt(@intCast(g.get().items.len));
        },
        // Progression `first`/`last`/`step` property reads on a host range
        // value, exactly the host field arm's answers (stored bounds even
        // when empty; `step` in the progression's width). The map CAS
        // loop's `indices` iteration read these through the slow ladder
        // 440k times in one run.
        .Range => |r| {
            if (std.mem.eql(u8, name, "step")) {
                return switch (r.kind) {
                    .Long, .ULong => .{ .Long = r.step },
                    .Int, .Char, .UInt => Value.newInt(@truncate(r.step)),
                };
            }
            const is_first = std.mem.eql(u8, name, "first");
            if (is_first or std.mem.eql(u8, name, "last")) {
                const v: i64 = if (is_first) r.start else r.end;
                return switch (r.kind) {
                    .Int => Value.newInt(@truncate(v)),
                    .Long => .{ .Long = v },
                    .Char => .{ .Char = @truncate(@as(u64, @bitCast(v))) },
                    .UInt => .{ .UInt = @truncate(@as(u64, @bitCast(v))) },
                    .ULong => .{ .ULong = @bitCast(v) },
                };
            }
        },
        else => {},
    }
    return null;
}

/// Pin the leaf register file as a collector root, once per serve. Called
/// immediately before the first instruction that can reach a safe point.
fn leafPin(pin: *?usize, regs: []Value, wmask: *u64) void {
    if (pin.* != null) return;
    // The keepalive pins the SLICE (the collector reads its current
    // contents), so every slot must hold a valid value before the pin: a
    // no-fill serve zeroes the not-yet-written slots here, paying the fill
    // only on the (rare) pinning path.
    for (regs, 0..) |*v, i| {
        if (i < 64 and wmask.* & (@as(u64, 1) << @intCast(i)) == 0) v.* = .Unit;
    }
    wmask.* = ~@as(u64, 0);
    pin.* = runtime.keepaliveMark();
    runtime.keepalivePushSlice(regs);
}

fn leafRead(regs: []const Value, wmask: u64, r: Reg) ?Value {
    const i = r.int();
    if (i >= regs.len) return null;
    // A slot this serve has not written yet reads as the fill value. The
    // eager whole-bank fill was 15% of the compose slot-table benchmark's
    // profile (millions of serves x n_locals Unit stores); reads are far
    // rarer than slots, so the zero moved here. Reclaim builds keep the
    // eager fill (their teardown releases every slot, so all slots must
    // hold owned values) and pass an all-ones mask.
    if ((wmask >> @as(u6, @truncate(i))) & 1 == 0) return .{ .Unit = {} };
    return regs[i];
}

/// Store into the leaf register file with the same ownership rule a frame
/// uses: the register owns one reference, the previous occupant loses one.
/// `borrowed` marks a value the leaf does not yet own a reference to.
fn leafWrite(allocator: Allocator, regs: []Value, r: Reg, v: Value, reclaim: bool, borrowed: bool, wmask: *u64) bool {
    const i = r.int();
    if (i >= regs.len) return false;
    if (i < 64) wmask.* |= @as(u64, 1) << @intCast(i);
    if (reclaim) {
        if (borrowed) v.retain();
        const old = regs[i];
        regs[i] = v;
        old.release(allocator);
    } else {
        regs[i] = v;
    }
    return true;
}

/// The stored-slot read of one `GetField` in a leaf body, using the
/// instruction's own claimed (class, slot) route — the same single-fill site
/// memo the framed `GetField` arm fills and re-verifies by name. Null for a
/// getter-routed, unclaimed, lateinit or delegated field, which the leaf
/// cannot serve.
fn leafStoredField(comptime H: type, allocator: Allocator, host: *H, gf: anytype, recv: *const Value, fname: []const u8, pin: *?usize, regs: []Value, wmask: *u64) Allocator.Error!?Value {
    const claimed = @atomicLoad(u64, @constCast(&gf.site_cls), .acquire);
    const cls: u64 = blk: {
        const g = recv.Instance.borrow();
        defer g.deinit();
        break :blk @intCast(g.get().class.identity());
    };
    if (claimed == 0) {
        // First execution claims the site for this class when the shared
        // (class, name) memo already routes the read to a stored slot or to
        // a getter that is itself a leaf. For a stored route the layout id
        // is bound to the verified index under one borrow, so a replay
        // matching BOTH class and shape skips the per-hit verify.
        if (host.fieldSiteRoute(recv, fname)) |route| {
            const usable = switch (route.route & 3) {
                1, 3 => true,
                2 => host.fieldGetterIsLeaf(@enumFromInt(route.route >> 2)),
                else => false,
            };
            const shp: u64 = blk2: {
                const g = recv.Instance.borrow();
                defer g.deinit();
                const b = g.get();
                if (route.route & 3 != 1) break :blk2 0;
                const idx2: usize = @intCast(route.route >> 2);
                if (idx2 >= b.fields.items.len) break :blk2 0;
                const f2 = &b.fields.items[idx2];
                if (!std.mem.eql(u8, f2.name, fname) and !leafSgetterMatches(fname, f2.name)) break :blk2 0;
                const sp = b.shapeOf();
                break :blk2 if (sp > 1) sp else 0;
            };
            if (usable and
                @cmpxchgStrong(u64, @constCast(&gf.site_cls), 0, route.cls, .acq_rel, .monotonic) == null)
            {
                if (shp != 0) @atomicStore(u64, @constCast(&gf.site_shape), shp, .monotonic);
                @atomicStore(u64, @constCast(&gf.site_route), route.route, .release);
            }
        }
        return null;
    }
    // A POLYMORPHIC site (`op.ints` inside `Operations.pushOp`, where `op` is
    // any of the changelist's ~40 Operation subclasses) claims one class and
    // then sees another on nearly every call. Declining there sent the whole
    // body — one of the hottest in a recomposition — to the frame path
    // forever. The per-site claim is only a fast path: on a miss, ask the
    // shared (class, name) memo, which answers from its own cache — its
    // index is NOT shape-checked, so that path keeps the name verify.
    var route = @atomicLoad(u64, @constCast(&gf.site_route), .acquire);
    var mono_claim = true;
    if (claimed != cls) {
        const alt = host.fieldSiteRoute(recv, fname) orelse return null;
        if (alt.cls != cls) return null;
        route = alt.route;
        mono_claim = false;
    }
    // A property whose backing is another leaf property chains through it:
    // the callee is pure by construction, so re-running it if this serve is
    // later abandoned observes nothing.
    if (route & 3 == 2) {
        if (!host.fieldGetterIsLeaf(@enumFromInt(route >> 2))) return null;
        leafPin(pin, regs, wmask);
        return switch (try host.runFieldGetter(allocator, @enumFromInt(route >> 2), recv.*)) {
            .ok => |v| v,
            .err => null,
        };
    }
    if (route & 3 == 3) return serveOuterSlotRoute(recv, fname, route);
    if (route & 3 != 1) return null;
    const idx: usize = @intCast(route >> 2);
    const g = recv.Instance.borrow();
    defer g.deinit();
    const b = g.get();
    const fields = b.fields.items;
    if (idx >= fields.len) return null;
    const f = &fields[idx];
    // A mono claim whose recorded LAYOUT matches the live receiver proves
    // the index; anything else pays the name verify.
    const shape_ok = mono_claim and
        @atomicLoad(u64, @constCast(&gf.site_shape), .monotonic) == b.shapeOf();
    if (!shape_ok and !std.mem.eql(u8, f.name, fname) and !leafSgetterMatches(fname, f.name)) return null;
    const v = f.value;
    if (v == .Null or v == .Delegate) return null;
    // Owned on the way out, matching the getter branch above: the register
    // file this lands in releases what it holds.
    v.retain();
    return v;
}

/// A scoped `$sgetter$<owner>\u{1f}<prop>` site stores its slot under the
/// bare property name; match the separator-guarded suffix so the drift guard
/// stays exact.
fn leafSgetterMatches(name: []const u8, field_name: []const u8) bool {
    return std.mem.startsWith(u8, name, "$sgetter$") and
        name.len > field_name.len and
        std.mem.endsWith(u8, name, field_name) and
        name[name.len - field_name.len - 1] == '\u{1f}';
}
