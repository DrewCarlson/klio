//! The bytecode tier: dense per-block `u32` op streams replacing the
//! tree-walker's per-instruction union dispatch for the hot simple ops,
//! with an ESCAPE op executing everything else through the walker's own
//! `execInst` — total coverage, shared semantics (see the frozen v1 spec
//! in plans/bytecode-vm-plan.md). Gated by `KLIO_BC=1`.

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
    /// inst_idx — span bookkeeping (reads the original Trace inst).
    trace,
    /// inst_idx — arithmetic/compare, routed to the walker's BinOp arm
    /// directly (skips the union dispatch, keeps every semantic).
    bin,
    /// inst_idx — every other instruction, via `execInst`.
    escape,
};

pub const Stream = struct {
    code: []const u32,
    /// `idx_pc[i]` = the pc where instruction `i`'s encoding begins, so the
    /// resume machinery's (block, idx) coordinates enter mid-stream.
    idx_pc: []const u32,
};

var gate_checked: bool = false;
var gate_on: bool = false;

pub fn enabled() bool {
    if (!gate_checked) {
        gate_checked = true;
        if (std.c.getenv("KLIO_BC")) |v| {
            gate_on = std.mem.eql(u8, std.mem.span(v), "1");
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
};

var cache_mutex: runtime.SpinMutex = .{};
var cache: ?std.AutoHashMap(usize, *const FuncStreams) = null;

pub fn funcStreams(func: *const ir.Func) ?*const FuncStreams {
    if (func.blocks.len == 0) return null;
    const key = @intFromPtr(func.blocks.ptr);
    cache_mutex.lock();
    defer cache_mutex.unlock();
    if (cache == null) {
        cache = std.AutoHashMap(usize, *const FuncStreams).init(std.heap.smp_allocator);
    }
    if (cache.?.get(key)) |fs| return fs;
    const a = std.heap.smp_allocator;
    const streams = a.alloc(?*const Stream, func.blocks.len) catch return null;
    for (func.blocks, streams) |*blk, *slot| {
        slot.* = if (blk.insts.len == 0) null else build(blk.insts);
    }
    const fs = a.create(FuncStreams) catch return null;
    fs.* = .{ .streams = streams };
    cache.?.put(key, fs) catch return fs;
    return fs;
}

fn build(insts: []const ir.Inst) ?*const Stream {
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
            .Trace => {
                code.appendSlice(a, &.{ @intFromEnum(Op.trace), @intCast(i) }) catch return null;
            },
            .BinOp => {
                code.appendSlice(a, &.{ @intFromEnum(Op.bin), @intCast(i) }) catch return null;
            },
            else => {
                code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
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
