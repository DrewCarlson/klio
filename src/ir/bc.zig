//! Dense per-block `u32` op streams for the hot simple instructions, with an
//! `escape` op running everything else through the walker's `execInst`.
//!
//! Fused terminators: a function carrying no try/catch/finally metadata gets
//! `jump`/`br`/`ret`/`term_exit` appended to each block's stream so flow stays
//! inside the bytecode loop. Built only when the loop JIT is off for the
//! process: the JIT's compile trigger sits at the frame loop's block entry,
//! which fused edges would starve.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("ir.zig");

pub const Op = enum(u32) {
    /// dst, const_id.
    const_load,
    /// dst, payload: a small Int constant embedded in the stream.
    const_int,
    /// dst, src: copy with retain.
    move,
    /// dst, idx.
    load_param,
    /// dst, cell.
    cell_get,
    /// file, start, end.
    trace,
    /// inst_idx, kind, dst, lhs, rhs. The generic fallback reaches the
    /// original inst through inst_idx.
    bin,
    /// inst_idx: every other instruction, via `execInst`.
    escape,
    /// target_block: fused Goto.
    jump,
    /// cond_reg, t_block, f_block: fused Branch on a Bool register. A non-Bool
    /// condition exits to the frame loop's terminator path.
    br,
    /// has_val, reg: fused Return.
    ret,
    /// No operands: run the block's real terminator in the frame loop.
    term_exit,
    /// inst_idx, kind, dst, lhs, rhs, t_block, f_block: the block's last
    /// instruction is a BinOp whose dst is the Branch condition. The compare
    /// still writes dst, so register state matches the unfused form;
    /// non-scalar operands fall back to the generic arm and branch on dst.
    cmp_br,
};

pub const Stream = struct {
    code: []const u32,
    /// `idx_pc[i]` = the pc where instruction `i`'s encoding begins, so the
    /// resume machinery's (block, idx) coordinates enter mid-stream.
    idx_pc: []const u32,
};


pub fn enabled() bool {
    return true;
}

/// One stream slot per block, indexed by BlockId. Process-lifetime cache data:
/// built once, never freed; a lazily-decoded body gets a fresh table.
pub const FuncStreams = struct {
    streams: []const ?*const Stream,
    fused: bool,
};

var cache_mutex: runtime.SpinMutex = .{};
/// Keyed per (function, fuse variant): the loop JIT takes single functions off
/// fusion, so both variants can be live in one process.
const CacheKey = struct { blocks: usize, fuse: bool };
var cache: ?std.AutoHashMap(CacheKey, *const FuncStreams) = null;

/// Generation for the per-Func `bc_memo` fast path: `resetCacheForTest` frees
/// every cached FuncStreams, so a Func surviving the reset must not serve its
/// memoized pointer into freed memory.
var stream_gen = std.atomic.Value(u32).init(1);
pub fn streamGen() u32 {
    return stream_gen.load(.monotonic);
}

/// Drop every cached stream table, freeing the streams. Keys are blocks
/// pointers, stable only for one program's life: an in-process driver reuses
/// those addresses and a stale hit would run the wrong stream.
pub fn resetCacheForTest() void {
    cache_mutex.lock();
    defer cache_mutex.unlock();
    _ = stream_gen.fetchAdd(1, .monotonic);
    const c = if (cache) |*cc| cc else return;
    const a = std.heap.smp_allocator;
    var it = c.valueIterator();
    while (it.next()) |fs_p| {
        const fs = fs_p.*;
        for (fs.streams) |slot| {
            if (slot) |st| {
                a.free(st.code);
                a.free(st.idx_pc);
                a.destroy(st);
            }
        }
        a.free(fs.streams);
        a.destroy(fs);
    }
    c.clearRetainingCapacity();
}

/// `allow_fuse` is process-constant, so the first call decides what the cache
/// holds. `consts` is the owning module's table, for embedded Int payloads.
pub fn funcStreams(func: *const ir.Func, allow_fuse: bool, consts: []const ir.Const) ?*const FuncStreams {
    if (func.blocks.len == 0) return null;
    // The shared cache below takes a global mutex and a hash probe on every
    // activation. The memo holds one fuse variant; the other keeps that path.
    const want_fuse: u8 = if (allow_fuse) 2 else 1;
    const gen = stream_gen.load(.monotonic);
    {
        const m = func.bc_memo.load(.acquire);
        if (m != 0 and func.bc_memo_fuse == want_fuse and func.bc_memo_gen == gen) {
            return if (m == 1) null else @ptrFromInt(m);
        }
    }
    const key: CacheKey = .{ .blocks = @intFromPtr(func.blocks.ptr), .fuse = allow_fuse };
    cache_mutex.lock();
    defer cache_mutex.unlock();
    if (cache == null) {
        cache = std.AutoHashMap(CacheKey, *const FuncStreams).init(std.heap.smp_allocator);
    }
    if (cache.?.get(key)) |fs| {
        @constCast(func).bc_memo_fuse = want_fuse;
        @constCast(func).bc_memo_gen = gen;
        @constCast(func).bc_memo.store(@intFromPtr(fs), .release);
        return fs;
    }
    const a = std.heap.smp_allocator;
    const fuse = allow_fuse and fusible(func);
    const streams = a.alloc(?*const Stream, func.blocks.len) catch return null;
    for (func.blocks, streams) |*blk, *slot| {
        slot.* = build(blk, fuse, consts, func.n_locals);
    }
    const fs = a.create(FuncStreams) catch return null;
    fs.* = .{ .streams = streams, .fused = fuse };
    cache.?.put(key, fs) catch return fs;
    @constCast(func).bc_memo_fuse = want_fuse;
    @constCast(func).bc_memo_gen = gen;
    @constCast(func).bc_memo.store(@intFromPtr(fs), .release);
    return fs;
}

/// Fusible when no block carries try machinery: with the try-stack provably
/// empty, the frame loop's Goto/Branch/Return handling reduces to the fused ops.
fn fusible(func: *const ir.Func) bool {
    for (func.blocks) |*blk| {
        if (blk.catches.len != 0 or blk.finally != null or
            blk.finally_done != null or blk.finally_done_for != null or
            blk.catch_done_for != null or blk.pop_on_exit.len != 0 or
            blk.lr_absorb != null)
        {
            return false;
        }
    }
    return true;
}

/// Build-time bound on every register operand a dedicated op emits. With the
/// frame loop's `regs.len >= n_locals` entry check this proves stream register
/// accesses in bounds, so the hot helpers index unchecked. Out of range
/// demotes the instruction to an escape.
fn regOk(n_locals: u32, r: u32) bool {
    return r < n_locals;
}

fn build(blk: *const ir.Block, fuse: bool, consts: []const ir.Const, n_locals: u32) ?*const Stream {
    const insts = blk.insts;
    // A block of pure escapes gains nothing over the walker's own loop. A
    // fused function keeps every block in-stream so jumps always land on one.
    if (!fuse) {
        const dedicated = for (insts) |*inst| {
            switch (inst.*) {
                .Const, .Move, .LoadParam, .CellGet, .BinOp => break true,
                else => {},
            }
        } else false;
        if (!dedicated) return null;
    }
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

/// Human-readable decode of one block's stream.
pub fn dumpStream(w: anytype, s: *const Stream) !void {
    var pc: usize = 0;
    const code = s.code;
    while (pc < code.len) {
        const op: Op = @enumFromInt(code[pc]);
        switch (op) {
            .const_load => {
                try w.print("  {d:>4}: const_load r{d} <- const#{d}\n", .{ pc, code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .const_int => {
                try w.print("  {d:>4}: const_int  r{d} <- {d}\n", .{ pc, code[pc + 1], @as(i32, @bitCast(code[pc + 2])) });
                pc += 3;
            },
            .move => {
                try w.print("  {d:>4}: move       r{d} <- r{d}\n", .{ pc, code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .load_param => {
                try w.print("  {d:>4}: load_param r{d} <- p{d}\n", .{ pc, code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .cell_get => {
                try w.print("  {d:>4}: cell_get   r{d} <- cell r{d}\n", .{ pc, code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .trace => {
                try w.print("  {d:>4}: trace      f{d}:{d}..{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
            .bin => {
                try w.print("  {d:>4}: bin        i{d} kind={d} r{d} <- r{d} op r{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5] });
                pc += 6;
            },
            .escape => {
                try w.print("  {d:>4}: escape     i{d}\n", .{ pc, code[pc + 1] });
                pc += 2;
            },
            .jump => {
                try w.print("  {d:>4}: jump       b{d}\n", .{ pc, code[pc + 1] });
                pc += 2;
            },
            .br => {
                try w.print("  {d:>4}: br         r{d} ? b{d} : b{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
            .ret => {
                try w.print("  {d:>4}: ret        has_val={d} r{d}\n", .{ pc, code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .term_exit => {
                try w.print("  {d:>4}: term_exit\n", .{pc});
                pc += 1;
            },
            .cmp_br => {
                try w.print("  {d:>4}: cmp_br     i{d} kind={d} r{d} <- r{d} op r{d} ? b{d} : b{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5], code[pc + 6], code[pc + 7] });
                pc += 8;
            },
        }
    }
}
