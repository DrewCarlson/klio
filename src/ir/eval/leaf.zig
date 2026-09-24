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

/// Per-thread bank of leaf register files, one per nesting level. Each level owns its slice
/// for the duration of its serve; the bank is initialised once per thread.
pub const LEAF_BANK_DEPTH: usize = 8;

/// The banks live off the thread-local block for the same reason the evaluator's
/// state does: a leaf serve is the cheapest call shape there is, and resolving a
/// Darwin `threadlocal` costs more than the serve it feeds.
const LeafBanks = struct {
    regs: [LEAF_BANK_DEPTH][ir.LEAF_MAX_REGS]Value = undefined,
    /// Scratch for the leaf serve's literal-typing coercion, one buffer per level.
    coerce: [LEAF_BANK_DEPTH][ir.LEAF_MAX_REGS]Value = undefined,
};

const leaf_banks = runtime.tls_fast.PerThread(LeafBanks);

pub inline fn leafBanks() *LeafBanks {
    return leaf_banks.get();
}

/// How far a leaf serve chains into other leaf callees, bounding the native recursion.

/// Raised when an instruction needs the frame path; the serve boundary turns it into a decline.
const LeafAbandon = error{LeafAbandon};

pub fn leafReqServable(req: FlatCallReq) bool {
    return req.captures.items.len == 0 and
        req.chain.len == 0 and
        req.closure_id == null and
        req.type_args.len == 0 and
        req.keepalive == null and
        req.typed_saved == null and
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
    // The literal-typing coercions a frame push applies hold here too: a bare Int flowing into a
    // declared Long param, or into a shared type-variable slot beside a Long peer, is a Long literal.
    const reclaim = runtime.reclaimEnabled();
    const ev: *EvalTls = ev_state.evtlsPtr();
    if (ev.leaf_depth >= LEAF_BANK_DEPTH) return null;
    var eff_args = args;
    {
        const plan = coercePlanFor(module, func);
        if (plan & 6 != 0 and args.len <= ir.LEAF_MAX_REGS) {
            const coerce_buf: []Value = leafBanks().coerce[ev.leaf_depth][0..args.len];
            @memcpy(coerce_buf, args);
            if (plan & 2 != 0) coerceIntArgsToLong(func, coerce_buf);
            if (plan & 4 != 0) coerceGenericIntPeersToLong(module, func, coerce_buf);
            eff_args = coerce_buf;
        }
    }
    const nlive: usize = @min(@as(usize, func.n_locals), ir.LEAF_MAX_REGS);
    const regs: []Value = leafBanks().regs[ev.leaf_depth][0..nlive];
    ev.leaf_depth += 1;
    defer ev.leaf_depth -= 1;
    // `wmask` marks the slots this serve has written; an unwritten slot reads as the fill value.
    // Reclaim builds fill eagerly instead, since every write releases the slot's prior value.
    var wmask: u64 = 0;
    if (reclaim) {
        for (regs) |*v| v.* = .Unit;
        wmask = ~@as(u64, 0);
    }
    defer if (reclaim) {
        for (regs) |*v| v.release(allocator);
    };
    // The register file is a native local, invisible to the collector's frame walk, so an instruction
    // that can allocate pins it first. The pin is deferred to the first such instruction.
    var pin: ?usize = null;
    defer if (pin) |m| runtime.keepaliveRestore(m);
    const fs: ?*const bc.FuncStreams = if (bc.enabled())
        bc.funcStreams(func, true, module.consts.items)
    else
        null;
    const out = (if (fs) |f|
        leafWalkStream(allocator, module, func, eff_args, regs, reclaim, trace, &pin, &wmask, f)
    else
        leafWalk(allocator, module, func, eff_args, regs, reclaim, trace, &pin, &wmask)) catch |e| switch (e) {
        error.LeafAbandon => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    // The caller owns one reference to the result, exactly as a returning frame hands it over.
    out.retain();
    return EvalResult{ .ok = out };
}

/// The leaf walk over the function's DENSE bytecode stream: the same op set the framed flat loop
/// runs, over the leaf bank. Complex ops reach `leafRunOne`; what the stream cannot express abandons.
fn leafWalkStream(
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
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
                .escape, .un => {
                    const inst_idx = code[pc + 1];
                    const b = &func.blocks[block];
                    if (inst_idx >= b.insts.len) return error.LeafAbandon;
                    try leafRunOne(allocator, module, func, args, &b.insts[inst_idx], regs, reclaim, trace, pin, wmask);
                    pc += switch (op) {
                        .un => 5,
                        else => 2,
                    };
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
        // Off the stream's end (or `term_exit`): the block's real terminator decides.
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

/// Walk the body's blocks until one returns; an instruction the serve cannot execute abandons here.
fn leafWalk(
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
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
        try leafRunInsts(allocator, module, func, args, b, regs, reclaim, trace, pin, wmask);
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
            // A guard's throwing arm never executes here: raising needs the frame path's unwind machinery.
            else => return error.LeafAbandon,
        }
    }
}

fn leafRunInsts(
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
    b: *const ir.Block,
    regs: []Value,
    reclaim: bool,
    trace: bool,
    pin: *?usize,
    wmask: *u64,
) (Allocator.Error || LeafAbandon)!void {
    for (b.insts) |*inst| {
        try leafRunOne(allocator, module, func, args, inst, regs, reclaim, trace, pin, wmask);
    }
}

/// One leaf-body instruction, shared by the union walker and the dense stream's `escape` ops.
fn leafRunOne(
    allocator: Allocator,
    module: *const Module,
    func: *const Func,
    args: []const Value,
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
            else => |other| {
                if (trace) std.debug.print("[leaf] {s}: unsupported {s}\n", .{ func.name, @tagName(other) });
                // Structural: no future attempt on this body can succeed.
                @constCast(func).leaf_hopeless = 1;
                return error.LeafAbandon;
            },
        }
    }
}

/// `KLIO_LEAF_TRACE=<name>`: report why the frameless leaf serve declined for a matching function.
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

/// Pin the leaf register file as a collector root, once per serve, immediately before the first
/// instruction that can reach a safe point.
fn leafPin(pin: *?usize, regs: []Value, wmask: *u64) void {
    if (pin.* != null) return;
    // The keepalive pins the slice, so every slot must hold a valid value before the pin.
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
    // An unwritten slot reads as the fill value; reclaim builds fill eagerly and pass all ones.
    if ((wmask >> @as(u6, @truncate(i))) & 1 == 0) return .{ .Unit = {} };
    return regs[i];
}

/// Store into the leaf register file with a frame's ownership rule: the register owns one reference,
/// the previous occupant loses one. `borrowed` marks a value the leaf does not yet own.
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
