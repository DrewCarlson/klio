//! The bytecode tier: dense per-block `u32` op streams replacing the
//! tree-walker's per-instruction union dispatch for the hot simple ops,
//! with an ESCAPE op executing everything else through the walker's own
//! `execInst` — total coverage, shared semantics (see the frozen v1 spec
//! in plans/bytecode-vm-plan.md). On by default; `KLIO_BC=0` restores
//! the pure walker.
//!
//! FUSED terminators: a function with no try/catch/finally metadata
//! anywhere gets `jump`/`br`/`ret`/`term_exit` ops appended to each
//! block's stream, so Goto/Branch/Return flow block-to-block inside the
//! bytecode loop without surfacing to the frame loop's per-block
//! bookkeeping. Fusion is only built when the loop JIT is off for the
//! process — the JIT's compile trigger lives at the frame loop's block
//! entry, and fused edges would starve it.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("ir.zig");

pub const Op = enum(u32) {
    /// dst, const_id — load a constant.
    const_load,
    /// dst, payload — load a small Int constant embedded in the stream
    /// (no consts-table lookup, no conversion dispatch).
    const_int,
    /// dst, src — copy with retain.
    move,
    /// dst, idx — parameter load.
    load_param,
    /// dst, cell — cell read (plain value passthrough included).
    cell_get,
    /// file, start, end — span bookkeeping, embedded (no Inst load).
    trace,
    /// inst_idx, kind, dst, lhs, rhs — arithmetic/compare. The operands
    /// ride in the stream so the hot path never touches the Inst union;
    /// the generic fallback reaches the original inst via inst_idx.
    bin,
    /// inst_idx — every other instruction, via `execInst`.
    escape,
    /// target_block — fused Goto: continue in the target block's stream.
    jump,
    /// cond_reg, t_block, f_block — fused Branch on a Bool register; a
    /// non-Bool condition exits to the frame loop's terminator path.
    br,
    /// has_val, reg — fused Return (no finally can intercept it in a
    /// fusible function).
    ret,
    /// (no operands) — run this block's real terminator in the frame
    /// loop (Throw, TailJump, suspension forms, ...).
    term_exit,
    /// inst_idx, kind, dst, lhs, rhs, t_block, f_block — a fused
    /// compare-and-branch: the block's LAST instruction is a BinOp
    /// whose dst is exactly the Branch condition. The compare's result
    /// is still written to dst (so semantics and register state match
    /// the unfused form); non-scalar operands fall back to the generic
    /// arm and then branch on dst.
    cmp_br,
};

pub const Stream = struct {
    code: []const u32,
    /// `idx_pc[i]` = the pc where instruction `i`'s encoding begins, so the
    /// resume machinery's (block, idx) coordinates enter mid-stream.
    idx_pc: []const u32,
};

var gate_checked: bool = false;
var gate_on: bool = true;

/// The tier is ON by default; `KLIO_BC=0` restores the pure walker
/// for bisection.
pub fn enabled() bool {
    if (!gate_checked) {
        gate_checked = true;
        if (std.c.getenv("KLIO_BC")) |v| {
            gate_on = !std.mem.eql(u8, std.mem.span(v), "0");
        }
    }
    return gate_on;
}

/// Per-FUNCTION stream tables (one entry per block, indexed by BlockId),
/// so the frame loop pays one lookup per ACTIVATION and a plain array
/// index per block entry. Process-lifetime code-cache data: built once,
/// never freed. Keyed by the function's blocks pointer (stable once
/// materialised; a lazily-decoded body gets a fresh table for its final
/// blocks slice).
pub const FuncStreams = struct {
    streams: []const ?*const Stream,
    /// Whether these streams carry fused terminator ops.
    fused: bool,
};

var cache_mutex: runtime.SpinMutex = .{};
var cache: ?std.AutoHashMap(usize, *const FuncStreams) = null;

/// `allow_fuse` is process-constant (the loop JIT's enablement); the
/// first call decides what the cache holds. `consts` is the owning
/// module's constant table (for embedding small Int payloads).
pub fn funcStreams(func: *const ir.Func, allow_fuse: bool, consts: []const ir.Const) ?*const FuncStreams {
    if (func.blocks.len == 0) return null;
    const key = @intFromPtr(func.blocks.ptr);
    cache_mutex.lock();
    defer cache_mutex.unlock();
    if (cache == null) {
        cache = std.AutoHashMap(usize, *const FuncStreams).init(std.heap.smp_allocator);
    }
    if (cache.?.get(key)) |fs| return fs;
    const a = std.heap.smp_allocator;
    const fuse = allow_fuse and fusible(func);
    const streams = a.alloc(?*const Stream, func.blocks.len) catch return null;
    for (func.blocks, streams) |*blk, *slot| {
        slot.* = build(blk, fuse, consts, func.n_locals);
    }
    const fs = a.create(FuncStreams) catch return null;
    fs.* = .{ .streams = streams, .fused = fuse };
    cache.?.put(key, fs) catch return fs;
    return fs;
}

/// A function is fusible when NO block carries try machinery: with the
/// try-stack provably empty and no pending-finally state possible, the
/// frame loop's Goto/Branch/Return handling reduces to exactly what the
/// fused ops do.
fn fusible(func: *const ir.Func) bool {
    for (func.blocks) |*blk| {
        if (blk.catches.len != 0 or blk.finally != null or
            blk.finally_done != null or blk.finally_done_for != null or
            blk.catch_done_for != null or blk.pop_on_exit.len != 0)
        {
            return false;
        }
    }
    return true;
}

/// Every register operand a dedicated op emits is validated `< n_locals`
/// at build time; together with the frame loop's one entry check
/// (`regs.len >= n_locals`, the frame-construction invariant) this
/// PROVES the stream ops' register accesses in bounds, so the hot
/// helpers index uncheck. An out-of-range operand demotes the
/// instruction to an escape (the walker's checked path).
fn regOk(n_locals: u32, r: u32) bool {
    return r < n_locals;
}

fn build(blk: *const ir.Block, fuse: bool, consts: []const ir.Const, n_locals: u32) ?*const Stream {
    const insts = blk.insts;
    // A block with no dedicated ops gains nothing from the stream —
    // running it as escapes would only add fetch+dispatch on top of
    // the walker's own loop. Leave it to the walker. (A fused function
    // keeps every block in-stream so jumps always land on a stream.)
    if (!fuse) {
        const dedicated = for (insts) |*inst| {
            switch (inst.*) {
                .Const, .Move, .LoadParam, .CellGet, .BinOp => break true,
                else => {},
            }
        } else false;
        if (!dedicated) return null;
    }
    // Fused compare-and-branch: the block's LAST inst is a BinOp whose
    // dst is exactly the Branch condition register.
    var fuse_cmp_idx: ?usize = null;
    if (fuse and insts.len != 0) {
        switch (blk.terminator) {
            .Branch => |br| switch (insts[insts.len - 1]) {
                .BinOp => |bo| {
                    if (bo.dst.int() == br.cond.int()) fuse_cmp_idx = insts.len - 1;
                },
                else => {},
            },
            else => {},
        }
    }
    const a = std.heap.smp_allocator;
    var code: std.ArrayList(u32) = .empty;
    var idx_pc = a.alloc(u32, insts.len) catch return null;
    for (insts, 0..) |*inst, i| {
        idx_pc[i] = @intCast(code.items.len);
        if (fuse_cmp_idx == i and regOk(n_locals, insts[i].BinOp.dst.int()) and
            regOk(n_locals, insts[i].BinOp.lhs.int()) and regOk(n_locals, insts[i].BinOp.rhs.int()))
        {
            const bo = insts[i].BinOp;
            const br = blk.terminator.Branch;
            code.appendSlice(a, &.{
                @intFromEnum(Op.cmp_br),
                @intCast(i),
                @intFromEnum(bo.op),
                bo.dst.int(),
                bo.lhs.int(),
                bo.rhs.int(),
                br.t.int(),
                br.f.int(),
            }) catch return null;
            continue;
        }
        switch (inst.*) {
            .Const => |c| {
                if (!regOk(n_locals, c.dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                const cid = c.value.int();
                if (cid < consts.len and consts[cid] == .Int) {
                    code.appendSlice(a, &.{
                        @intFromEnum(Op.const_int),
                        c.dst.int(),
                        @bitCast(consts[cid].Int),
                    }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.const_load), c.dst.int(), c.value.int() }) catch return null;
            },
            .Move => |mv| {
                if (!regOk(n_locals, mv.dst.int()) or !regOk(n_locals, mv.src.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.move), mv.dst.int(), mv.src.int() }) catch return null;
            },
            .LoadParam => |lp| {
                if (!regOk(n_locals, lp.dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.load_param), lp.dst.int(), @intCast(lp.idx) }) catch return null;
            },
            .CellGet => |cg| {
                if (!regOk(n_locals, cg.dst.int()) or !regOk(n_locals, cg.cell.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.cell_get), cg.dst.int(), cg.cell.int() }) catch return null;
            },
            .Trace => |t| {
                code.appendSlice(a, &.{ @intFromEnum(Op.trace), t.span.file.int(), t.span.start, t.span.end }) catch return null;
            },
            .BinOp => |bo| {
                if (!regOk(n_locals, bo.dst.int()) or !regOk(n_locals, bo.lhs.int()) or
                    !regOk(n_locals, bo.rhs.int()))
                {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{
                    @intFromEnum(Op.bin),
                    @intCast(i),
                    @intFromEnum(bo.op),
                    bo.dst.int(),
                    bo.lhs.int(),
                    bo.rhs.int(),
                }) catch return null;
            },
            else => {
                code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
            },
        }
    }
    if (fuse) {
        switch (blk.terminator) {
            .Goto => |g| {
                code.appendSlice(a, &.{ @intFromEnum(Op.jump), g.int() }) catch return null;
            },
            .Branch => |br| {
                // A cmp_br already carries the branch.
                if (fuse_cmp_idx == null) {
                    if (regOk(n_locals, br.cond.int())) {
                        code.appendSlice(a, &.{ @intFromEnum(Op.br), br.cond.int(), br.t.int(), br.f.int() }) catch return null;
                    } else {
                        code.append(a, @intFromEnum(Op.term_exit)) catch return null;
                    }
                }
            },
            .Return => |maybe_r| {
                if (maybe_r != null and !regOk(n_locals, maybe_r.?.int())) {
                    code.append(a, @intFromEnum(Op.term_exit)) catch return null;
                } else {
                    code.appendSlice(a, &.{
                        @intFromEnum(Op.ret),
                        @intFromBool(maybe_r != null),
                        if (maybe_r) |r| r.int() else 0,
                    }) catch return null;
                }
            },
            else => {
                code.append(a, @intFromEnum(Op.term_exit)) catch return null;
            },
        }
    }
    const st = a.create(Stream) catch return null;
    st.* = .{
        .code = code.toOwnedSlice(a) catch return null,
        .idx_pc = idx_pc,
    };
    return st;
}

test {
    std.testing.refAllDecls(@This());
}

test "stream encoding: dedicated ops, operand words, idx_pc, escape" {
    var insts = [_]ir.Inst{
        .{ .Const = .{ .dst = ir.Reg.from(1), .value = ir.ConstId.from(7) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(2), .op = .Add, .lhs = ir.Reg.from(1), .rhs = ir.Reg.from(0), .compound = false } },
        .{ .Move = .{ .dst = ir.Reg.from(3), .src = ir.Reg.from(2) } },
        .{ .MakeCell = .{ .dst = ir.Reg.from(4), .src = ir.Reg.from(3) } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &insts,
        .terminator = .{ .Goto = ir.BlockId.from(2) },
    };
    const st = build(&blk, false, &.{}, 8) orelse return error.TestUnexpectedResult;
    const want = [_]u32{
        @intFromEnum(Op.const_load), 1, 7,
        @intFromEnum(Op.bin),        1, @intFromEnum(ir.BinOp.Add), 2, 1, 0,
        @intFromEnum(Op.move),       3, 2,
        @intFromEnum(Op.escape),     3,
    };
    try std.testing.expectEqualSlices(u32, &want, st.code);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 9, 12 }, st.idx_pc);

    // An Int constant embeds its payload.
    const consts = [_]ir.Const{ .{ .Int = -42 }, .{ .String = "s" } };
    const st2 = build(&blk, false, &consts, 8) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromEnum(Op.const_load), st2.code[0]);
    var iblk = blk;
    var iconst = [_]ir.Inst{
        .{ .Const = .{ .dst = ir.Reg.from(1), .value = ir.ConstId.from(0) } },
    };
    iblk.insts = &iconst;
    const st3 = build(&iblk, false, &consts, 8) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.const_int), 1, @as(u32, @bitCast(@as(i32, -42))),
    }, st3.code);
}

test "stream encoding: fused terminators" {
    var mv = [_]ir.Inst{
        .{ .Move = .{ .dst = ir.Reg.from(1), .src = ir.Reg.from(0) } },
    };
    const goto_blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &mv,
        .terminator = .{ .Goto = ir.BlockId.from(3) },
    };
    const gs = build(&goto_blk, true, &.{}, 8) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.move), 1, 0,
        @intFromEnum(Op.jump), 3,
    }, gs.code);

    var none = [_]ir.Inst{};
    const ret_blk: ir.Block = .{
        .id = ir.BlockId.from(1),
        .insts = &none,
        .terminator = .{ .Return = ir.Reg.from(5) },
    };
    const rs = build(&ret_blk, true, &.{}, 8) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{ @intFromEnum(Op.ret), 1, 5 }, rs.code);

    const br_blk: ir.Block = .{
        .id = ir.BlockId.from(2),
        .insts = &none,
        .terminator = .{ .Branch = .{ .cond = ir.Reg.from(2), .t = ir.BlockId.from(1), .f = ir.BlockId.from(4) } },
    };
    const bs = build(&br_blk, true, &.{}, 8) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{ @intFromEnum(Op.br), 2, 1, 4 }, bs.code);
}

test "stream encoding: an all-escape block builds no stream unfused" {
    var mc = [_]ir.Inst{
        .{ .MakeCell = .{ .dst = ir.Reg.from(1), .src = ir.Reg.from(0) } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &mc,
        .terminator = .{ .Goto = ir.BlockId.from(0) },
    };
    try std.testing.expect(build(&blk, false, &.{}, 8) == null);
    try std.testing.expect(build(&blk, true, &.{}, 8) != null);
}
