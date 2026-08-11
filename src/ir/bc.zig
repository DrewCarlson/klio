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
/// first call decides what the cache holds.
pub fn funcStreams(func: *const ir.Func, allow_fuse: bool) ?*const FuncStreams {
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
        slot.* = build(blk, fuse);
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

fn build(blk: *const ir.Block, fuse: bool) ?*const Stream {
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
    const a = std.heap.smp_allocator;
    var code: std.ArrayList(u32) = .empty;
    var idx_pc = a.alloc(u32, insts.len) catch return null;
    for (insts, 0..) |*inst, i| {
        idx_pc[i] = @intCast(code.items.len);
        switch (inst.*) {
            .Const => |c| {
                code.appendSlice(a, &.{ @intFromEnum(Op.const_load), c.dst.int(), c.value.int() }) catch return null;
            },
            .Move => |mv| {
                code.appendSlice(a, &.{ @intFromEnum(Op.move), mv.dst.int(), mv.src.int() }) catch return null;
            },
            .LoadParam => |lp| {
                code.appendSlice(a, &.{ @intFromEnum(Op.load_param), lp.dst.int(), @intCast(lp.idx) }) catch return null;
            },
            .CellGet => |cg| {
                code.appendSlice(a, &.{ @intFromEnum(Op.cell_get), cg.dst.int(), cg.cell.int() }) catch return null;
            },
            .Trace => |t| {
                code.appendSlice(a, &.{ @intFromEnum(Op.trace), t.span.file.int(), t.span.start, t.span.end }) catch return null;
            },
            .BinOp => |bo| {
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
                code.appendSlice(a, &.{ @intFromEnum(Op.br), br.cond.int(), br.t.int(), br.f.int() }) catch return null;
            },
            .Return => |maybe_r| {
                code.appendSlice(a, &.{
                    @intFromEnum(Op.ret),
                    @intFromBool(maybe_r != null),
                    if (maybe_r) |r| r.int() else 0,
                }) catch return null;
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
    const st = build(&blk, false) orelse return error.TestUnexpectedResult;
    const want = [_]u32{
        @intFromEnum(Op.const_load), 1, 7,
        @intFromEnum(Op.bin),        1, @intFromEnum(ir.BinOp.Add), 2, 1, 0,
        @intFromEnum(Op.move),       3, 2,
        @intFromEnum(Op.escape),     3,
    };
    try std.testing.expectEqualSlices(u32, &want, st.code);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 9, 12 }, st.idx_pc);
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
    const gs = build(&goto_blk, true) orelse return error.TestUnexpectedResult;
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
    const rs = build(&ret_blk, true) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{ @intFromEnum(Op.ret), 1, 5 }, rs.code);

    const br_blk: ir.Block = .{
        .id = ir.BlockId.from(2),
        .insts = &none,
        .terminator = .{ .Branch = .{ .cond = ir.Reg.from(2), .t = ir.BlockId.from(1), .f = ir.BlockId.from(4) } },
    };
    const bs = build(&br_blk, true) orelse return error.TestUnexpectedResult;
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
    try std.testing.expect(build(&blk, false) == null);
    try std.testing.expect(build(&blk, true) != null);
}
