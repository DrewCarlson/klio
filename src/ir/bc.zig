//! Dense `u32` op code, one array per function holding every block's ops one
//! block after another: the interpreter's one representation. Ops cover the
//! hot instructions; an `escape` op runs any other through its arm in
//! `execInst`.
//!
//! Every block's ops end in its terminator op (`jump`, `br`, `cmp_br`, `ret`
//! or `term_exit`), so flow stays inside the loop. A block reference in an op
//! is two words, the block and the pc its ops are entered at, so an edge moves
//! the pc and nothing else. What a try region does at a block's entry and at
//! its Goto (a try frame pushed or popped) is a `block_entry` op and a
//! `goto_try` op; a finally's pending flow (a return, a throw or a non-local
//! return passing through it) runs in the frame loop.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("ir.zig");

pub const Op = enum(u32) {
    /// dst, const_id: a constant the module's table does not hold, made by the loop.
    const_load,
    /// dst, slot: a scalar constant, one of the function's `values`.
    const_val,
    /// dst, payload: a small Int constant embedded in the stream.
    const_int,
    /// dst, src: copy with retain.
    move,
    /// dst, idx.
    load_param,
    /// dst, cell.
    cell_get,
    /// inst_idx, kind, dst, lhs, rhs. The generic fallback reaches the
    /// original inst through inst_idx.
    bin,
    /// `bin`'s words for an Add: two Ints or two Longs add in place; any
    /// other pair runs as `bin`.
    add,
    /// `bin`'s words for a Sub, as `add`.
    sub,
    /// `bin`'s words for a compare, whose kind word carries the order mask
    /// above its low byte: two Ints or two Longs answer from the mask; any
    /// other pair runs as `bin`.
    cmp,
    /// inst_idx: every other instruction, via `execInst`.
    escape,
    /// target (block, pc), exit span: the block's Goto.
    jump,
    /// cond_reg, t (block, pc), f (block, pc), exit span: the block's Branch on a Bool
    /// register. A non-Bool condition exits to the frame loop's terminator path.
    br,
    /// has_val, reg: the block's Return.
    ret,
    /// `ret`'s words, in a function with a try region: a return inside one,
    /// or with a finally's flow pending, runs the frame loop's routing.
    ret_try,
    /// exit span: run the block's real terminator in the frame loop.
    term_exit,
    /// inst_idx, kind, dst, operand: a unary operator, with the scalar tags
    /// served inline and every other shape falling to the instruction's arm.
    un,
    /// inst_idx, kind, dst, lhs, rhs, t (block, pc), f (block, pc), exit span:
    /// the block's last instruction is a BinOp whose dst is the Branch condition.
    /// The compare still writes dst, so register state matches the unfused
    /// form; non-scalar operands fall back to the generic arm and branch on dst.
    /// A compare's kind word carries its order mask, as `cmp`'s does.
    cmp_br,
    /// inst_idx, func, args, n_args, dst, site, init: a static call. The loop
    /// runs an interpreted callee without leaving the stream; any other
    /// callee runs through the instruction's arm. `site` indexes the
    /// function's `callees`, where a run leaves the callee's streams for the
    /// next once `init`, the unit the call must see run (`NONE` for none),
    /// has run.
    call,
    /// exit span: the end of a block's ops, after its terminator op if it
    /// has one. Each op dispatches the next, and this one leaves.
    end,
    /// inst_idx, dst, obj, slot: an instance's field read in place; any other
    /// receiver runs through the instruction's arm.
    get_field,
    /// inst_idx, obj, slot, value: an instance's field write in place.
    set_field,
    /// inst_idx, slot, args, n_args, dst: a virtual or interface call. An
    /// instance receiver whose class implements the slot with an interpreted
    /// body runs it in the stream, as `call` does.
    vcall,
    /// inst_idx, class, ctor, args, n_args, dst, site: a constructor call.
    /// A class whose constructor is an interpreted body gets its instance
    /// made here and the constructor run in the stream; `site` is a `callees`
    /// entry, as a `call`'s is.
    new,
    /// inst_idx, callee, args, n_args, dst: a function value's invoke. A
    /// lambda made from sema runs its body in the stream over a copy of its
    /// captures.
    callv,
    /// inst_idx, dst, src: `!` on a Boolean; anything else takes the arm.
    not,
    /// inst_idx, native, args, n_args, dst, direct: a host call over the
    /// argument run, read in place. Not `direct` (a `super` call), an
    /// instance receiver's own override of the member answers instead.
    native,
    /// inst_idx, dst, array, index: an array's (or a string's) element read
    /// in place; a null, a bad index or anything else takes the arm.
    array_get,
    /// inst_idx, array, index, value: an array's element write in place.
    array_set,
    /// inst_idx, dst, class: an object's singleton once built; the arm builds it.
    load_object,
    /// dst, idx: a capture of the running closure, as `load_param` reads a parameter.
    load_capture,
    /// The first op of a block whose entry pushes, pops or disarms a try
    /// frame, which it does before the block's next op.
    block_entry,
    /// target (block, pc), exit span: a Goto whose leaving pops try frames,
    /// done here; with a finally's flow pending, the frame loop routes it.
    goto_try,
    /// dst, src: a capture cell made over a register.
    make_cell,
    /// inst_idx, cell, value: a store through a capture cell; a register
    /// holding no cell runs the arm, which writes the register.
    cell_set,
    /// inst_idx, static, value: a static store once its init unit has run;
    /// the arm runs the unit first.
    store_static,
    /// inst_idx: a closure over its captures, made by the instruction's arm.
    make_closure,
    /// inst_idx: an array over its argument run, made by the instruction's arm.
    new_array,
    /// inst_idx, dst, static: a static read in place once its init unit has
    /// run; the arm runs the unit first.
    load_static,
    /// inst_idx, dst, src, class, nullable: `is` on a value the tables
    /// classify; a function value runs the arm.
    is,
    /// inst_idx, dst, src, class, flags (1 nullable, 2 safe): `as` and `as?`
    /// on a value the tables classify that passes, and `as?` on one that
    /// fails; a failing `as` and a function value run the arm.
    cast,
    /// dst, const_id, slot: a String constant. The site makes its string
    /// once, in the permanent generation, and keeps it in the function's
    /// `strings`; a Kotlin string is immutable, and the JVM interns its
    /// literals.
    const_str,
};

/// A block's exit span: the span of its last `Trace`, three words (file,
/// start, end), with file `NO_SPAN` when the block has none. `Trace` runs no
/// op: the frame loop records where a frame stands at every instruction that
/// can observe a span (an escape, a call, a throw), finds the statement's
/// span from the block's instructions, and a block's exit leaves its last
/// span on the frame for the blocks after it.
pub const NO_SPAN: u32 = std.math.maxInt(u32);

fn exitSpan(blk: *const ir.Block) [3]u32 {
    var i = blk.insts.len;
    while (i > 0) {
        i -= 1;
        switch (blk.insts[i]) {
            .Trace => |t| return .{ t.span.file.int(), t.span.start, t.span.end },
            else => {},
        }
    }
    return .{ NO_SPAN, 0, 0 };
}

/// A block's place in its function's code.
pub const BlockCode = struct {
    /// The pc an edge to the block enters at: its `block_entry` op when it
    /// has one, else `start`.
    enter: u32,
    /// The pc of the block's first op after `block_entry`.
    start: u32,
    /// The pc of the block's `end` op.
    end: u32,
    /// `idx_pc[i]` = the pc where instruction `i`'s encoding begins, so the
    /// resume machinery's (block, idx) coordinates enter mid-block.
    idx_pc: []const u32,
};

/// A function's code and where each block sits in it, indexed by BlockId.
/// Process-lifetime cache data: built once, never freed; a lazily-decoded
/// body gets a fresh table.
pub const FuncStreams = struct {
    func: *const ir.Func,
    /// Every block's ops, each block closed by its `end` op.
    code: []const u32,
    blocks: []const BlockCode,
    /// The pc a call enters the function at.
    entry_pc: u32,
    /// Per `call` site, the callee's streams once a call has resolved them.
    callees: []std.atomic.Value(?*const FuncStreams),
    /// Per `const_str` site, the cell of its string once a load has made it (0 before).
    strings: []std.atomic.Value(usize),
    /// The scalar constants the function's `const_val` ops load, made when its code is built.
    values: []const runtime.Value,
    /// A frame of the function may start with its registers unfilled (`Func.frameDefBeforeUse`).
    no_fill: bool,
    /// What a call runs in place of a frame when the body is only field traffic (`leafOf`).
    leaf: Leaf = .none,
};

/// A body that only moves fields of its first parameter, which a call runs
/// without a frame of its own.
pub const Leaf = union(enum) {
    none,
    /// Returns field `slot` of parameter 0: a default getter.
    get_field: u32,
    /// Stores each parameter in its field of parameter 0, in order, and
    /// returns parameter 0: a constructor that only takes its properties.
    set_fields: []const FieldStore,
};

pub const FieldStore = struct { slot: u32, param: u16 };

/// The `Leaf` of `func`: one block, no handlers, reading parameters and
/// either returning a field of parameter 0 or storing parameters in its
/// fields and returning it.
fn leafOf(a: std.mem.Allocator, func: *const ir.Func) Leaf {
    if (func.entry.int() != 0) return .none;
    return leafOfBlocks(a, func.blocks);
}

fn leafOfBlocks(a: std.mem.Allocator, blocks: []const ir.Block) Leaf {
    if (blocks.len != 1) return .none;
    const b = &blocks[0];
    if (b.handlers != null) return .none;
    const ret: ?ir.Reg = switch (b.terminator) {
        .Return => |r| r,
        else => return .none,
    };
    const Param = struct { reg: ir.Reg, idx: u16 };
    var params: [16]Param = undefined;
    var n_params: usize = 0;
    var stores: [16]FieldStore = undefined;
    var n_stores: usize = 0;
    const paramOf = struct {
        fn f(ps: []const Param, r: ir.Reg) ?u16 {
            var i = ps.len;
            while (i > 0) {
                i -= 1;
                if (ps[i].reg == r) return ps[i].idx;
            }
            return null;
        }
    }.f;
    for (b.insts, 0..) |inst, i| switch (inst) {
        .LoadParam => |lp| {
            if (n_params == params.len) return .none;
            params[n_params] = .{ .reg = lp.dst, .idx = lp.idx };
            n_params += 1;
        },
        .GetFieldSlot => |g| {
            if (i + 1 != b.insts.len or n_stores != 0) return .none;
            if ((paramOf(params[0..n_params], g.obj) orelse return .none) != 0) return .none;
            if (ret == null or ret.? != g.dst) return .none;
            return .{ .get_field = g.slot };
        },
        .SetFieldSlot => |st| {
            if ((paramOf(params[0..n_params], st.obj) orelse return .none) != 0) return .none;
            const from = paramOf(params[0..n_params], st.value) orelse return .none;
            if (from == 0 or n_stores == stores.len) return .none;
            stores[n_stores] = .{ .slot = st.slot, .param = from };
            n_stores += 1;
        },
        else => return .none,
    };
    if (n_stores == 0) return .none;
    const r = ret orelse return .none;
    if ((paramOf(params[0..n_params], r) orelse return .none) != 0) return .none;
    return .{ .set_fields = a.dupe(FieldStore, stores[0..n_stores]) catch return .none };
}

var cache_mutex: runtime.SpinMutex = .{};
/// Keyed per function: a table names the `Func` it was built for, and a call
/// runs that `Func`'s blocks. The address alone is not an identity: a function
/// freed and another built at the same address would serve the first one's
/// streams, so the key carries its blocks and a shape signature of them, and a
/// run clears the cache (`resetCacheForTest`).
const CacheKey = struct { func: usize, blocks: usize, sig: u64 };

fn blocksSignature(blocks: []const ir.Block) u64 {
    var h = std.hash.Wyhash.init(blocks.len);
    for (blocks) |*b| {
        h.update(std.mem.asBytes(&@as(u32, @intCast(b.insts.len))));
        h.update(std.mem.asBytes(&@as(u8, @intFromEnum(b.terminator))));
        if (b.insts.len != 0) {
            h.update(std.mem.asBytes(&@as(u8, @intFromEnum(b.insts[0]))));
            h.update(std.mem.asBytes(&@as(u8, @intFromEnum(b.insts[b.insts.len - 1]))));
        }
    }
    return h.final();
}
var cache: ?std.AutoHashMap(CacheKey, *const FuncStreams) = null;

/// Generation for the per-Func `bc_memo` fast path: `resetCacheForTest` frees
/// every cached FuncStreams, so a Func surviving the reset must not serve its
/// memoized pointer into freed memory.
var stream_gen = std.atomic.Value(u32).init(1);

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
        for (fs.blocks) |b| a.free(b.idx_pc);
        a.free(fs.blocks);
        a.free(fs.code);
        a.free(fs.values);
        a.free(fs.callees);
        a.free(fs.strings);
        if (fs.leaf == .set_fields) a.free(fs.leaf.set_fields);
        a.destroy(fs);
    }
    c.clearRetainingCapacity();
}

/// The streams of `func`'s blocks; `consts` is the owning module's table, for
/// embedded payloads. The memo on the `Func` answers inline; the shared cache
/// behind it takes a global mutex and a hash probe.
pub inline fn funcStreams(func: *const ir.Func, consts: []const ir.Const) ?*const FuncStreams {
    const m = func.bc_memo.load(.acquire);
    if (m != 0 and func.bc_memo_gen == stream_gen.load(.monotonic)) {
        return if (m == 1) null else @ptrFromInt(m);
    }
    return funcStreamsSlow(func, consts);
}

fn funcStreamsSlow(func: *const ir.Func, consts: []const ir.Const) ?*const FuncStreams {
    if (func.blocks.len == 0) return null;
    const gen = stream_gen.load(.monotonic);
    const key: CacheKey = .{ .func = @intFromPtr(func), .blocks = @intFromPtr(func.blocks.ptr), .sig = blocksSignature(func.blocks) };
    cache_mutex.lock();
    defer cache_mutex.unlock();
    if (cache == null) {
        cache = std.AutoHashMap(CacheKey, *const FuncStreams).init(std.heap.smp_allocator);
    }
    if (cache.?.get(key)) |fs| {
        @constCast(func).bc_memo_gen = gen;
        @constCast(func).bc_memo.store(@intFromPtr(fs), .release);
        return fs;
    }
    const a = std.heap.smp_allocator;
    var sites: Sites = .{};
    const laid = buildBlocks(func.blocks, consts, func.n_locals, &sites) orelse return null;
    const callees = a.alloc(std.atomic.Value(?*const FuncStreams), sites.calls) catch return null;
    for (callees) |*c| c.* = .init(null);
    const strings = a.alloc(std.atomic.Value(usize), sites.strings) catch return null;
    for (strings) |*c| c.* = .init(0);
    const fs = a.create(FuncStreams) catch return null;
    fs.* = .{
        .func = func,
        .code = laid.code,
        .blocks = laid.blocks,
        .entry_pc = laid.blocks[func.entry.int()].enter,
        .callees = callees,
        .strings = strings,
        .values = laid.values,
        .no_fill = func.frameDefBeforeUse(),
        .leaf = leafOf(a, func),
    };
    cache.?.put(key, fs) catch return fs;
    @constCast(func).bc_memo_gen = gen;
    @constCast(func).bc_memo.store(@intFromPtr(fs), .release);
    return fs;
}

/// What the try machinery does around a block, which the frame loop runs: at its entry (a try
/// frame pushed, a catch-only try's frame popped at its join, a finally's frame disarmed as the
/// finally begins) and at its Goto (a finally's frame popped, a pending flow a finally's end
/// completes or replays, an inline return's frames popped). A Branch does none of it, and a
/// Return checks for it where it runs.
const BlockFx = struct { entry: bool = false, goto: bool = false, try_ret: bool = false };

/// Whether any block opens a try region, so a return may have finallys to run.
fn hasTry(blocks: []const ir.Block) bool {
    for (blocks) |*b| {
        if (b.h().catches.len != 0 or b.h().finally != null) return true;
    }
    return false;
}

fn blockEffects(blocks: []const ir.Block) ?[]BlockFx {
    const fx = std.heap.smp_allocator.alloc(BlockFx, blocks.len) catch return null;
    @memset(fx, .{});
    const try_ret = hasTry(blocks);
    for (blocks, fx) |*b, *f| {
        const h = b.h();
        f.try_ret = try_ret;
        if (h.catches.len != 0 or h.finally != null or h.catch_done_for != null) f.entry = true;
        if (h.finally_done_for != null or h.pop_on_exit.len != 0) f.goto = true;
    }
    // A finally's entry disarms its frame, and a finally or its done sentinel keys a pending flow.
    for (blocks) |*b| {
        const h = b.h();
        if (h.finally) |fin| if (fin.int() < fx.len) {
            fx[fin.int()].entry = true;
            fx[fin.int()].goto = true;
        };
        if (h.finally_done) |d| if (d.int() < fx.len) {
            fx[d.int()].goto = true;
        };
    }
    return fx;
}

/// Build-time bound on every register operand a dedicated op emits. With the
/// frame loop's `regs.len >= n_locals` entry check this proves stream register
/// accesses in bounds, so the hot helpers index unchecked. Out of range
/// demotes the instruction to an escape.
fn regOk(n_locals: u32, r: u32) bool {
    return r < n_locals;
}

/// The outcomes of comparing two Ints or two Longs that a compare holds for, one bit each: bit 0
/// less, bit 1 equal, bit 2 greater. Zero for any other operator.
pub fn orderMask(op: ir.BinOp) u32 {
    return switch (op) {
        .Less => 0b001,
        .LessEq => 0b011,
        .Eq, .BoxedEq => 0b010,
        .NotEq, .BoxedNotEq => 0b101,
        .Greater => 0b100,
        .GreaterEq => 0b110,
        else => 0,
    };
}

/// A binary op's kind word: the operator in the low byte, its order mask above.
pub fn kindWord(op: ir.BinOp) u32 {
    return @intFromEnum(op) | orderMask(op) << 8;
}

/// A constant other than a String, as the value a load makes of it.
fn scalarValue(c: ir.Const) runtime.Value {
    return switch (c) {
        .Unit => .Unit,
        .Int => |v| .{ .Int = v },
        .Long => |v| .{ .Long = v },
        .UInt => |v| .{ .UInt = v },
        .ULong => |v| .{ .ULong = v },
        .UShort => |v| .{ .UShort = v },
        .UByte => |v| .{ .UByte = v },
        .Short => |v| .{ .Short = v },
        .Byte => |v| .{ .Byte = v },
        .Double => |v| .{ .Double = v },
        .Float => |v| .{ .Float = v },
        .Bool => |v| .{ .Bool = v },
        .Char => |v| .{ .Char = v },
        .Null => .Null,
        .String => unreachable,
    };
}

/// The per-function site counters a stream build numbers its call and string sites with.
const Sites = struct { calls: u32 = 0, strings: u32 = 0 };

/// A block reference's pc word, filled in once every block's start is known.
const Fixup = struct { pos: u32, block: u32 };

/// One function's code under construction.
const Emit = struct {
    code: std.ArrayList(u32) = .empty,
    fixups: std.ArrayList(Fixup) = .empty,
    values: std.ArrayList(runtime.Value) = .empty,

    /// A block reference: the block, then the pc its ops start at.
    fn blockRef(e: *Emit, b: ir.BlockId) bool {
        const a = std.heap.smp_allocator;
        e.code.append(a, b.int()) catch return false;
        e.fixups.append(a, .{ .pos = @intCast(e.code.items.len), .block = b.int() }) catch return false;
        e.code.append(a, 0) catch return false;
        return true;
    }
};

const Laid = struct { code: []const u32, blocks: []const BlockCode, values: []const runtime.Value };

/// `blocks` laid out in one code array with every block reference's pc filled in. Null when an
/// allocation fails or an edge names no block.
fn buildBlocks(blocks: []const ir.Block, consts: []const ir.Const, n_locals: u32, sites: *Sites) ?Laid {
    const a = std.heap.smp_allocator;
    var e: Emit = .{};
    defer e.fixups.deinit(a);
    const fx = blockEffects(blocks) orelse return null;
    defer a.free(fx);
    const out = a.alloc(BlockCode, blocks.len) catch return null;
    for (blocks, out, fx) |*blk, *slot, f| slot.* = build(blk, f, consts, n_locals, sites, &e) orelse return null;
    for (e.fixups.items) |f| {
        if (f.block >= out.len) return null;
        e.code.items[f.pos] = out[f.block].enter;
    }
    return .{
        .code = e.code.toOwnedSlice(a) catch return null,
        .blocks = out,
        .values = e.values.toOwnedSlice(a) catch return null,
    };
}

fn build(blk: *const ir.Block, fx: BlockFx, consts: []const ir.Const, n_locals: u32, sites: *Sites, e: *Emit) ?BlockCode {
    const insts = blk.insts;
    var fuse_cmp_idx: ?usize = null;
    if (insts.len != 0) {
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
    const code = &e.code;
    const enter: u32 = @intCast(code.items.len);
    if (fx.entry) code.append(a, @intFromEnum(Op.block_entry)) catch return null;
    const start: u32 = @intCast(code.items.len);
    var idx_pc = a.alloc(u32, insts.len) catch return null;
    for (insts, 0..) |*inst, i| {
        idx_pc[i] = @intCast(code.items.len);
        if (fuse_cmp_idx == i and regOk(n_locals, insts[i].BinOp.dst.int()) and
            regOk(n_locals, insts[i].BinOp.lhs.int()) and regOk(n_locals, insts[i].BinOp.rhs.int()))
        {
            const bo = insts[i].BinOp;
            const br = blk.terminator.Branch;
            const cx = exitSpan(blk);
            code.appendSlice(a, &.{
                @intFromEnum(Op.cmp_br),
                @intCast(i),
                kindWord(bo.op),
                bo.dst.int(),
                bo.lhs.int(),
                bo.rhs.int(),
            }) catch return null;
            if (!e.blockRef(br.t) or !e.blockRef(br.f)) return null;
            code.appendSlice(a, &cx) catch return null;
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
                if (cid < consts.len and consts[cid] == .String) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.const_str), c.dst.int(), cid, sites.strings }) catch return null;
                    sites.strings += 1;
                    continue;
                }
                if (cid < consts.len) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.const_val), c.dst.int(), @intCast(e.values.items.len) }) catch return null;
                    e.values.append(a, scalarValue(consts[cid])) catch return null;
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
            .Trace => {},
            .UnOp => |u| {
                if (!regOk(n_locals, u.dst.int()) or !regOk(n_locals, u.operand.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{
                    @intFromEnum(Op.un),
                    @intCast(i),
                    @intFromEnum(u.op),
                    u.dst.int(),
                    u.operand.int(),
                }) catch return null;
            },
            .GetFieldSlot => |g| {
                if (!regOk(n_locals, g.dst.int()) or !regOk(n_locals, g.obj.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.get_field), @intCast(i), g.dst.int(), g.obj.int(), g.slot }) catch return null;
            },
            .SetFieldSlot => |sf| {
                if (!regOk(n_locals, sf.obj.int()) or !regOk(n_locals, sf.value.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.set_field), @intCast(i), sf.obj.int(), sf.slot, sf.value.int() }) catch return null;
            },
            .RCallVirtual, .CallInterface => {
                const slot, const args, const n_args, const dst = switch (inst.*) {
                    .RCallVirtual => |v| .{ v.slot, v.args, v.n_args, v.dst },
                    .CallInterface => |v| .{ v.slot, v.args, v.n_args, v.dst },
                    else => unreachable,
                };
                const run_ok = n_args != 0 and regOk(n_locals, args.int() + n_args - 1);
                if (!run_ok or !regOk(n_locals, dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.vcall), @intCast(i), slot.int(), args.int(), n_args, dst.int() }) catch return null;
            },
            .RNewInstance => |ni| {
                const run_ok = ni.n_args == 0 or regOk(n_locals, ni.args.int() + ni.n_args - 1);
                if (!run_ok or !regOk(n_locals, ni.dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.new), @intCast(i), ni.class.int(), ni.ctor.int(), ni.args.int(), ni.n_args, ni.dst.int(), sites.calls }) catch return null;
                sites.calls += 1;
            },
            .RCallValue => |cv| {
                const run_ok = cv.n_args == 0 or regOk(n_locals, cv.args.int() + cv.n_args - 1);
                if (!run_ok or !regOk(n_locals, cv.dst.int()) or !regOk(n_locals, cv.callee.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.callv), @intCast(i), cv.callee.int(), cv.args.int(), cv.n_args, cv.dst.int() }) catch return null;
            },
            .CallNative => |cn| {
                const run_ok = cn.n_args == 0 or regOk(n_locals, cn.args.int() + cn.n_args - 1);
                if (!run_ok or !regOk(n_locals, cn.dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.native), @intCast(i), cn.native.int(), cn.args.int(), cn.n_args, cn.dst.int(), @intFromBool(cn.direct) }) catch return null;
            },
            .LoadCapture => |lc| {
                if (!regOk(n_locals, lc.dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.load_capture), lc.dst.int(), @intCast(lc.idx) }) catch return null;
            },
            .LoadStatic => |ls| {
                if (!regOk(n_locals, ls.dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.load_static), @intCast(i), ls.dst.int(), ls.static.int() }) catch return null;
            },
            .RInstanceOf => |t| {
                if (!regOk(n_locals, t.dst.int()) or !regOk(n_locals, t.src.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.is), @intCast(i), t.dst.int(), t.src.int(), t.class.int(), @intFromBool(t.nullable) }) catch return null;
            },
            .RCast => |t| {
                if (!regOk(n_locals, t.dst.int()) or !regOk(n_locals, t.src.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                const flags = @as(u32, @intFromBool(t.nullable)) | @as(u32, @intFromBool(t.safe)) << 1;
                code.appendSlice(a, &.{ @intFromEnum(Op.cast), @intCast(i), t.dst.int(), t.src.int(), t.class.int(), flags }) catch return null;
            },
            .MakeCell => |mc| {
                if (!regOk(n_locals, mc.dst.int()) or !regOk(n_locals, mc.src.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.make_cell), mc.dst.int(), mc.src.int() }) catch return null;
            },
            .CellSet => |cs| {
                if (!regOk(n_locals, cs.cell.int()) or !regOk(n_locals, cs.value.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.cell_set), @intCast(i), cs.cell.int(), cs.value.int() }) catch return null;
            },
            .StoreStatic => |ss| {
                if (!regOk(n_locals, ss.value.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.store_static), @intCast(i), ss.static.int(), ss.value.int() }) catch return null;
            },
            .MakeClosure => code.appendSlice(a, &.{ @intFromEnum(Op.make_closure), @intCast(i) }) catch return null,
            .NewArray => code.appendSlice(a, &.{ @intFromEnum(Op.new_array), @intCast(i) }) catch return null,
            .ArrayGet => |ag| {
                if (!regOk(n_locals, ag.dst.int()) or !regOk(n_locals, ag.array.int()) or !regOk(n_locals, ag.index.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.array_get), @intCast(i), ag.dst.int(), ag.array.int(), ag.index.int() }) catch return null;
            },
            .ArraySet => |as| {
                if (!regOk(n_locals, as.array.int()) or !regOk(n_locals, as.index.int()) or !regOk(n_locals, as.value.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.array_set), @intCast(i), as.array.int(), as.index.int(), as.value.int() }) catch return null;
            },
            .LoadObject => |lo| {
                if (!regOk(n_locals, lo.dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.load_object), @intCast(i), lo.dst.int(), lo.class.int() }) catch return null;
            },
            .Not => |n| {
                if (!regOk(n_locals, n.dst.int()) or !regOk(n_locals, n.src.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{ @intFromEnum(Op.not), @intCast(i), n.dst.int(), n.src.int() }) catch return null;
            },
            .CallStatic => |cs| {
                const run_ok = cs.n_args == 0 or regOk(n_locals, cs.args.int() + cs.n_args - 1);
                if (!run_ok or !regOk(n_locals, cs.dst.int())) {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                code.appendSlice(a, &.{
                    @intFromEnum(Op.call),
                    @intCast(i),
                    cs.func.int(),
                    cs.args.int(),
                    cs.n_args,
                    cs.dst.int(),
                    sites.calls,
                    cs.init,
                }) catch return null;
                sites.calls += 1;
            },
            .BinOp => |bo| {
                if (!regOk(n_locals, bo.dst.int()) or !regOk(n_locals, bo.lhs.int()) or
                    !regOk(n_locals, bo.rhs.int()))
                {
                    code.appendSlice(a, &.{ @intFromEnum(Op.escape), @intCast(i) }) catch return null;
                    continue;
                }
                const op: Op = switch (bo.op) {
                    .Add => .add,
                    .Sub => .sub,
                    else => if (orderMask(bo.op) != 0) .cmp else .bin,
                };
                code.appendSlice(a, &.{
                    @intFromEnum(op),
                    @intCast(i),
                    kindWord(bo.op),
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
    const xs = exitSpan(blk);
    {
        switch (blk.terminator) {
            .Goto => |g| {
                code.append(a, @intFromEnum(if (fx.goto) Op.goto_try else Op.jump)) catch return null;
                if (!e.blockRef(g)) return null;
                code.appendSlice(a, &xs) catch return null;
            },
            .Branch => |br| {
                // A cmp_br already carries the branch.
                if (fuse_cmp_idx == null) {
                    if (regOk(n_locals, br.cond.int())) {
                        code.appendSlice(a, &.{ @intFromEnum(Op.br), br.cond.int() }) catch return null;
                        if (!e.blockRef(br.t) or !e.blockRef(br.f)) return null;
                    } else {
                        code.append(a, @intFromEnum(Op.term_exit)) catch return null;
                    }
                    code.appendSlice(a, &xs) catch return null;
                }
            },
            .Return => |maybe_r| {
                if (maybe_r != null and !regOk(n_locals, maybe_r.?.int())) {
                    code.append(a, @intFromEnum(Op.term_exit)) catch return null;
                    code.appendSlice(a, &xs) catch return null;
                } else {
                    code.appendSlice(a, &.{
                        @intFromEnum(if (fx.try_ret) Op.ret_try else Op.ret),
                        @intFromBool(maybe_r != null),
                        if (maybe_r) |r| r.int() else 0,
                    }) catch return null;
                }
            },
            else => {
                code.append(a, @intFromEnum(Op.term_exit)) catch return null;
                code.appendSlice(a, &xs) catch return null;
            },
        }
    }
    const end: u32 = @intCast(code.items.len);
    code.append(a, @intFromEnum(Op.end)) catch return null;
    code.appendSlice(a, &xs) catch return null;
    return .{ .enter = enter, .start = start, .end = end, .idx_pc = idx_pc };
}

test {
    std.testing.refAllDecls(@This());
}

/// The site counters the encoding tests hand `build`.
var test_sites: Sites = .{};

/// The pc a lone block's references name: `TEST_PC` plus the block.
const TEST_PC: u32 = 1000;

/// One block built alone at pc 0, as the encoding tests read it.
fn buildOne(blk: *const ir.Block, consts: []const ir.Const, n_locals: u32, sites: *Sites) ?struct { code: []const u32, idx_pc: []const u32, values: []const runtime.Value } {
    var e: Emit = .{};
    const b = build(blk, .{}, consts, n_locals, sites, &e) orelse return null;
    for (e.fixups.items) |f| e.code.items[f.pos] = TEST_PC + f.block;
    return .{ .code = e.code.items, .idx_pc = b.idx_pc, .values = e.values.items };
}

test "stream encoding: dedicated ops, operand words, idx_pc, escape" {
    var insts = [_]ir.Inst{
        .{ .Const = .{ .dst = ir.Reg.from(1), .value = ir.ConstId.from(7) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(2), .op = .Add, .lhs = ir.Reg.from(1), .rhs = ir.Reg.from(0), .compound = false } },
        .{ .Move = .{ .dst = ir.Reg.from(3), .src = ir.Reg.from(2) } },
        .{ .ClassOf = .{ .dst = ir.Reg.from(4), .src = ir.Reg.from(3) } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &insts,
        .terminator = .{ .Goto = ir.BlockId.from(2) },
    };
    const st = buildOne(&blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    const want = [_]u32{
        @intFromEnum(Op.const_load), 1, 7,
        @intFromEnum(Op.add),        1, @intFromEnum(ir.BinOp.Add), 2, 1, 0,
        @intFromEnum(Op.move),       3, 2,
        @intFromEnum(Op.escape),     3,
        @intFromEnum(Op.jump),       2, 1002, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),        NO_SPAN, 0, 0,
    };
    try std.testing.expectEqualSlices(u32, &want, st.code);
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 9, 12 }, st.idx_pc);

    const consts = [_]ir.Const{ .{ .Int = -42 }, .{ .String = "s" }, .{ .Long = 9 } };
    // Constant 7 is past this table: the op loads it by id.
    const st2 = buildOne(&blk, &consts, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@intFromEnum(Op.const_load), st2.code[0]);
    var sconst = [_]ir.Inst{
        .{ .Const = .{ .dst = ir.Reg.from(1), .value = ir.ConstId.from(1) } },
        .{ .Const = .{ .dst = ir.Reg.from(2), .value = ir.ConstId.from(2) } },
        .{ .Const = .{ .dst = ir.Reg.from(3), .value = ir.ConstId.from(1) } },
    };
    var sblk = blk;
    sblk.insts = &sconst;
    var ssites: Sites = .{};
    const st4 = buildOne(&sblk, &consts, 8, &ssites) orelse return error.TestUnexpectedResult;
    // Each string load site keeps a string of its own.
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.const_str),  1, 1, 0,
        @intFromEnum(Op.const_val),  2, 0,
        @intFromEnum(Op.const_str),  3, 1, 1,
        @intFromEnum(Op.jump),       2, 1002, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),        NO_SPAN, 0, 0,
    }, st4.code);
    try std.testing.expectEqual(@as(u32, 2), ssites.strings);
    // A scalar constant is a value the code carries.
    try std.testing.expectEqualSlices(runtime.Value, &.{.{ .Long = 9 }}, st4.values);
    var iblk = blk;
    var iconst = [_]ir.Inst{
        .{ .Const = .{ .dst = ir.Reg.from(1), .value = ir.ConstId.from(0) } },
    };
    iblk.insts = &iconst;
    const st3 = buildOne(&iblk, &consts, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.const_int), 1, @as(u32, @bitCast(@as(i32, -42))),
        @intFromEnum(Op.jump),      2, 1002, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),       NO_SPAN, 0, 0,
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
    const gs = buildOne(&goto_blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.move), 1, 0,
        @intFromEnum(Op.jump), 3, 1003, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),  NO_SPAN, 0, 0,
    }, gs.code);

    var none = [_]ir.Inst{};
    const ret_blk: ir.Block = .{
        .id = ir.BlockId.from(1),
        .insts = &none,
        .terminator = .{ .Return = ir.Reg.from(5) },
    };
    const rs = buildOne(&ret_blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{ @intFromEnum(Op.ret), 1, 5, @intFromEnum(Op.end), NO_SPAN, 0, 0 }, rs.code);

    const br_blk: ir.Block = .{
        .id = ir.BlockId.from(2),
        .insts = &none,
        .terminator = .{ .Branch = .{ .cond = ir.Reg.from(2), .t = ir.BlockId.from(1), .f = ir.BlockId.from(4) } },
    };
    const bs = buildOne(&br_blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{ @intFromEnum(Op.br), 2, 1, 1001, 4, 1004, NO_SPAN, 0, 0, @intFromEnum(Op.end), NO_SPAN, 0, 0 }, bs.code);
}

test "stream encoding: adds, subtracts and compares are ops of their own, a compare with its order mask" {
    var insts = [_]ir.Inst{
        .{ .BinOp = .{ .dst = ir.Reg.from(2), .op = .Sub, .lhs = ir.Reg.from(1), .rhs = ir.Reg.from(0) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(3), .op = .LessEq, .lhs = ir.Reg.from(1), .rhs = ir.Reg.from(0) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(4), .op = .Mul, .lhs = ir.Reg.from(1), .rhs = ir.Reg.from(0) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(5), .op = .IdentEq, .lhs = ir.Reg.from(1), .rhs = ir.Reg.from(0) } },
        .{ .BinOp = .{ .dst = ir.Reg.from(6), .op = .NotEq, .lhs = ir.Reg.from(1), .rhs = ir.Reg.from(0) } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(1),
        .insts = &insts,
        .terminator = .{ .Branch = .{ .cond = ir.Reg.from(6), .t = ir.BlockId.from(1), .f = ir.BlockId.from(2) } },
    };
    const st = buildOne(&blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    const le = kindWord(.LessEq);
    const ne = kindWord(.NotEq);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ir.BinOp.LessEq)) | 0b011 << 8, le);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ir.BinOp.NotEq)) | 0b101 << 8, ne);
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.sub),    0, @intFromEnum(ir.BinOp.Sub),     2, 1, 0,
        @intFromEnum(Op.cmp),    1, le,                             3, 1, 0,
        @intFromEnum(Op.bin),    2, @intFromEnum(ir.BinOp.Mul),     4, 1, 0,
        @intFromEnum(Op.bin),    3, @intFromEnum(ir.BinOp.IdentEq), 5, 1, 0,
        @intFromEnum(Op.cmp_br), 4, ne,                             6, 1, 0, 1, 1001, 2, 1002, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),    NO_SPAN, 0, 0,
    }, st.code);
}

test "stream encoding: a static call is a call op carrying its init unit" {
    var calls = [_]ir.Inst{
        .{ .CallStatic = .{ .dst = ir.Reg.from(3), .func = ir.FuncId.from(9), .args = ir.Reg.from(1), .n_args = 2 } },
        .{ .CallStatic = .{ .dst = ir.Reg.from(4), .func = ir.FuncId.from(9), .args = ir.Reg.from(1), .n_args = 2, .init = 5 } },
        .{ .CallStatic = .{ .dst = ir.Reg.from(4), .func = ir.FuncId.from(9), .args = ir.Reg.from(7), .n_args = 2 } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &calls,
        .terminator = .{ .Goto = ir.BlockId.from(1) },
    };
    const st = buildOne(&blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.call),   0, 9, 1, 2, 3, 0, ir.NO_UNIT,
        @intFromEnum(Op.call),   1, 9, 1, 2, 4, 1, 5,
        @intFromEnum(Op.escape), 2,
        @intFromEnum(Op.jump),   1, 1001, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),    NO_SPAN, 0, 0,
    }, st.code);
}

test "stream encoding: field slots and virtual calls are ops of their own" {
    var insts = [_]ir.Inst{
        .{ .GetFieldSlot = .{ .dst = ir.Reg.from(2), .obj = ir.Reg.from(1), .slot = 3 } },
        .{ .SetFieldSlot = .{ .obj = ir.Reg.from(1), .slot = 4, .value = ir.Reg.from(2) } },
        .{ .RCallVirtual = .{ .dst = ir.Reg.from(5), .slot = ir.MethodSlotId.from(7), .args = ir.Reg.from(1), .n_args = 2 } },
        .{ .CallInterface = .{ .dst = ir.Reg.from(6), .iface = ir.ClassId.from(0), .slot = ir.MethodSlotId.from(8), .args = ir.Reg.from(1), .n_args = 1 } },
        .{ .GetFieldSlot = .{ .dst = ir.Reg.from(9), .obj = ir.Reg.from(1), .slot = 3 } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &insts,
        .terminator = .{ .Goto = ir.BlockId.from(1) },
    };
    const st = buildOne(&blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.get_field), 0, 2, 1, 3,
        @intFromEnum(Op.set_field), 1, 1, 4, 2,
        @intFromEnum(Op.vcall),     2, 7, 1, 2, 5,
        @intFromEnum(Op.vcall),     3, 8, 1, 1, 6,
        @intFromEnum(Op.escape),    4,
        @intFromEnum(Op.jump),      1, 1001, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),       NO_SPAN, 0, 0,
    }, st.code);
}

test "stream encoding: a trace runs no op, and a block's exit carries its last span" {
    const sp = @import("span");
    var insts = [_]ir.Inst{
        .{ .Trace = .{ .span = .{ .file = sp.FileId.from(4), .start = 10, .end = 20 } } },
        .{ .Move = .{ .dst = ir.Reg.from(1), .src = ir.Reg.from(0) } },
        .{ .Trace = .{ .span = .{ .file = sp.FileId.from(4), .start = 30, .end = 40 } } },
        .{ .Move = .{ .dst = ir.Reg.from(2), .src = ir.Reg.from(1) } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &insts,
        .terminator = .{ .Goto = ir.BlockId.from(1) },
    };
    const st = buildOne(&blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.move), 1, 0,
        @intFromEnum(Op.move), 2, 1,
        @intFromEnum(Op.jump), 1, 1001, 4, 30, 40,
        @intFromEnum(Op.end),  4, 30, 40,
    }, st.code);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 3, 3 }, st.idx_pc);
}

test "stream encoding: constructors, function values, host calls and Not are ops of their own" {
    var insts = [_]ir.Inst{
        .{ .RNewInstance = .{ .dst = ir.Reg.from(4), .class = ir.ClassId.from(3), .ctor = ir.FuncId.from(11), .args = ir.Reg.from(1), .n_args = 2 } },
        .{ .RCallValue = .{ .dst = ir.Reg.from(5), .callee = ir.Reg.from(0), .args = ir.Reg.from(1), .n_args = 1 } },
        .{ .Not = .{ .dst = ir.Reg.from(6), .src = ir.Reg.from(2) } },
        .{ .CallNative = .{ .dst = ir.Reg.from(7), .native = ir.NativeId.from(40), .args = ir.Reg.from(1), .n_args = 2, .direct = true } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &insts,
        .terminator = .{ .Goto = ir.BlockId.from(1) },
    };
    var sites: Sites = .{};
    const st = buildOne(&blk, &.{}, 8, &sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.new),    0, 3, 11, 1, 2, 4, 0,
        @intFromEnum(Op.callv),  1, 0, 1, 1, 5,
        @intFromEnum(Op.not),    2, 6, 2,
        @intFromEnum(Op.native), 3, 40, 1, 2, 7, 1,
        @intFromEnum(Op.jump),   1, 1001, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),    NO_SPAN, 0, 0,
    }, st.code);
    try std.testing.expectEqual(@as(u32, 1), sites.calls);
}

test "stream encoding: a function's blocks share one code array, and an edge names its target's pc" {
    var mv = [_]ir.Inst{
        .{ .Move = .{ .dst = ir.Reg.from(1), .src = ir.Reg.from(0) } },
    };
    var none = [_]ir.Inst{};
    const blocks = [_]ir.Block{
        .{ .id = ir.BlockId.from(0), .insts = &mv, .terminator = .{ .Goto = ir.BlockId.from(2) } },
        .{ .id = ir.BlockId.from(1), .insts = &none, .terminator = .{ .Return = ir.Reg.from(1) } },
        .{ .id = ir.BlockId.from(2), .insts = &none, .terminator = .{ .Branch = .{ .cond = ir.Reg.from(1), .t = ir.BlockId.from(1), .f = ir.BlockId.from(0) } } },
    };
    var sites: Sites = .{};
    const laid = buildBlocks(&blocks, &.{}, 8, &sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.move), 1, 0,
        @intFromEnum(Op.jump), 2, 20, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),  NO_SPAN, 0, 0,
        @intFromEnum(Op.ret),  1, 1,
        @intFromEnum(Op.end),  NO_SPAN, 0, 0,
        @intFromEnum(Op.br),   1, 1, 13, 0, 0, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),  NO_SPAN, 0, 0,
    }, laid.code);
    try std.testing.expectEqual(@as(u32, 0), laid.blocks[0].start);
    try std.testing.expectEqual(@as(u32, 0), laid.blocks[0].enter);
    try std.testing.expectEqual(@as(u32, 9), laid.blocks[0].end);
    try std.testing.expectEqual(@as(u32, 13), laid.blocks[1].start);
    try std.testing.expectEqual(@as(u32, 16), laid.blocks[1].end);
    try std.testing.expectEqual(@as(u32, 20), laid.blocks[2].start);
    try std.testing.expectEqual(@as(u32, 29), laid.blocks[2].end);
    try std.testing.expectEqualSlices(u32, &.{0}, laid.blocks[0].idx_pc);

    // An edge to a block the function does not have builds nothing.
    const bad = [_]ir.Block{
        .{ .id = ir.BlockId.from(0), .insts = &none, .terminator = .{ .Goto = ir.BlockId.from(5) } },
    };
    try std.testing.expect(buildBlocks(&bad, &.{}, 8, &sites) == null);
}

test "stream encoding: captures, statics and class tests are ops of their own" {
    var insts = [_]ir.Inst{
        .{ .LoadCapture = .{ .dst = ir.Reg.from(1), .idx = 2 } },
        .{ .LoadStatic = .{ .dst = ir.Reg.from(2), .static = ir.StaticId.from(6) } },
        .{ .RInstanceOf = .{ .dst = ir.Reg.from(3), .src = ir.Reg.from(1), .class = ir.ClassId.from(4), .nullable = true } },
        .{ .RCast = .{ .dst = ir.Reg.from(4), .src = ir.Reg.from(1), .class = ir.ClassId.from(4), .nullable = false, .safe = true } },
        .{ .RCast = .{ .dst = ir.Reg.from(9), .src = ir.Reg.from(1), .class = ir.ClassId.from(4), .nullable = false, .safe = false } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &insts,
        .terminator = .{ .Goto = ir.BlockId.from(1) },
    };
    const st = buildOne(&blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.load_capture), 1, 2,
        @intFromEnum(Op.load_static),  1, 2, 6,
        @intFromEnum(Op.is),           2, 3, 1, 4, 1,
        @intFromEnum(Op.cast),         3, 4, 1, 4, 2,
        @intFromEnum(Op.escape),       4,
        @intFromEnum(Op.jump),         1, 1001, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),          NO_SPAN, 0, 0,
    }, st.code);
}

test "stream encoding: a try region's blocks start with block_entry, and its bookkeeping Gotos are goto_try" {
    var none = [_]ir.Inst{};
    var mv = [_]ir.Inst{
        .{ .Move = .{ .dst = ir.Reg.from(1), .src = ir.Reg.from(0) } },
    };
    var body_h: ir.BlockHandlers = .{ .finally = ir.BlockId.from(2), .finally_done = ir.BlockId.from(3) };
    var done_h: ir.BlockHandlers = .{ .finally_done_for = ir.BlockId.from(1) };
    const blocks = [_]ir.Block{
        .{ .id = ir.BlockId.from(0), .insts = &none, .terminator = .{ .Goto = ir.BlockId.from(1) } },
        .{ .id = ir.BlockId.from(1), .insts = &mv, .terminator = .{ .Goto = ir.BlockId.from(2) }, .handlers = &body_h },
        .{ .id = ir.BlockId.from(2), .insts = &none, .terminator = .{ .Goto = ir.BlockId.from(3) } },
        .{ .id = ir.BlockId.from(3), .insts = &none, .terminator = .{ .Return = null }, .handlers = &done_h },
    };
    var sites: Sites = .{};
    const laid = buildBlocks(&blocks, &.{}, 8, &sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        // b0: a plain Goto into the try body, which is entered through the frame loop.
        @intFromEnum(Op.jump),        1, 10, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),         NO_SPAN, 0, 0,
        // b1: pushes its try frame at entry; its Goto into the finally is plain.
        @intFromEnum(Op.block_entry),
        @intFromEnum(Op.move),        1, 0,
        @intFromEnum(Op.jump),        2, 24, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),         NO_SPAN, 0, 0,
        // b2: the finally disarms its frame at entry and keys a pending flow at its Goto.
        @intFromEnum(Op.block_entry),
        @intFromEnum(Op.goto_try),    3, 35, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),         NO_SPAN, 0, 0,
        // b3: the done sentinel keys a pending flow and returns through any finally left.
        @intFromEnum(Op.ret_try),     0, 0,
        @intFromEnum(Op.end),         NO_SPAN, 0, 0,
    }, laid.code);
    try std.testing.expectEqual(@as(u32, 10), laid.blocks[1].enter);
    try std.testing.expectEqual(@as(u32, 11), laid.blocks[1].start);
    try std.testing.expectEqualSlices(u32, &.{11}, laid.blocks[1].idx_pc);
}

test "stream encoding: cells, static stores, closures and arrays are ops of their own" {
    var caps = [_]ir.Reg{ir.Reg.from(1)};
    var insts = [_]ir.Inst{
        .{ .MakeCell = .{ .dst = ir.Reg.from(2), .src = ir.Reg.from(1) } },
        .{ .CellSet = .{ .cell = ir.Reg.from(2), .value = ir.Reg.from(3) } },
        .{ .StoreStatic = .{ .static = ir.StaticId.from(5), .value = ir.Reg.from(3) } },
        .{ .MakeClosure = .{ .dst = ir.Reg.from(4), .func = ir.FuncId.from(7), .captures = &caps } },
        .{ .NewArray = .{ .dst = ir.Reg.from(5), .class = ir.ClassId.from(2), .args = ir.Reg.from(1), .n_args = 2 } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &insts,
        .terminator = .{ .Goto = ir.BlockId.from(1) },
    };
    const st = buildOne(&blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.make_cell),    2, 1,
        @intFromEnum(Op.cell_set),     1, 2, 3,
        @intFromEnum(Op.store_static), 2, 5, 3,
        @intFromEnum(Op.make_closure), 3,
        @intFromEnum(Op.new_array),    4,
        @intFromEnum(Op.jump),         1, 1001, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),          NO_SPAN, 0, 0,
    }, st.code);
}

test "stream encoding: a block of escapes has a stream of its own" {
    var mc = [_]ir.Inst{
        .{ .ClassOf = .{ .dst = ir.Reg.from(1), .src = ir.Reg.from(0) } },
    };
    const blk: ir.Block = .{
        .id = ir.BlockId.from(0),
        .insts = &mc,
        .terminator = .{ .Goto = ir.BlockId.from(0) },
    };
    const st = buildOne(&blk, &.{}, 8, &test_sites) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{
        @intFromEnum(Op.escape), 0,
        @intFromEnum(Op.jump),   0, 1000, NO_SPAN, 0, 0,
        @intFromEnum(Op.end),    NO_SPAN, 0, 0,
    }, st.code);
}

/// Human-readable decode of block `b`'s ops.
pub fn dumpBlock(w: anytype, fs: *const FuncStreams, b: usize) !void {
    var pc: usize = fs.blocks[b].enter;
    const code = fs.code;
    while (pc <= fs.blocks[b].end) {
        const op: Op = @enumFromInt(code[pc]);
        switch (op) {
            .const_load => {
                try w.print("  {d:>4}: const_load r{d} <- const#{d}\n", .{ pc, code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .const_val => {
                try w.print("  {d:>4}: const_val  r{d} <- value{d}\n", .{ pc, code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .un => {
                try w.print("  {d:>4}: un         r{d} <- op{d} r{d}\n", .{ pc, code[pc + 3], code[pc + 2], code[pc + 4] });
                pc += 5;
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
            .bin, .add, .sub, .cmp => |o| {
                try w.print("  {d:>4}: {s:<10} i{d} kind={d} r{d} <- r{d} op r{d}\n", .{ pc, @tagName(o), code[pc + 1], code[pc + 2] & 0xff, code[pc + 3], code[pc + 4], code[pc + 5] });
                pc += 6;
            },
            .escape => {
                try w.print("  {d:>4}: escape     i{d}\n", .{ pc, code[pc + 1] });
                pc += 2;
            },
            .jump, .goto_try => |o| {
                try w.print("  {d:>4}: {s:<10} b{d} @{d}\n", .{ pc, @tagName(o), code[pc + 1], code[pc + 2] });
                pc += 6;
            },
            .br => {
                try w.print("  {d:>4}: br         r{d} ? b{d} @{d} : b{d} @{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5] });
                pc += 9;
            },
            .ret, .ret_try => |o| {
                try w.print("  {d:>4}: {s:<10} has_val={d} r{d}\n", .{ pc, @tagName(o), code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .term_exit => {
                try w.print("  {d:>4}: term_exit\n", .{pc});
                pc += 4;
            },
            .cmp_br => {
                try w.print("  {d:>4}: cmp_br     i{d} kind={d} r{d} <- r{d} op r{d} ? b{d} @{d} : b{d} @{d}\n", .{ pc, code[pc + 1], code[pc + 2] & 0xff, code[pc + 3], code[pc + 4], code[pc + 5], code[pc + 6], code[pc + 7], code[pc + 8], code[pc + 9] });
                pc += 13;
            },
            .call => {
                try w.print("  {d:>4}: call       i{d} f{d} r{d}..+{d} -> r{d} site{d} init{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5], code[pc + 6], code[pc + 7] });
                pc += 8;
            },
            .end => {
                try w.print("  {d:>4}: end\n", .{pc});
                pc += 4;
            },
            .block_entry => {
                try w.print("  {d:>4}: block_entry\n", .{pc});
                pc += 1;
            },
            .get_field => {
                try w.print("  {d:>4}: get_field  i{d} r{d} <- r{d}.#{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4] });
                pc += 5;
            },
            .set_field => {
                try w.print("  {d:>4}: set_field  i{d} r{d}.#{d} <- r{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4] });
                pc += 5;
            },
            .vcall => {
                try w.print("  {d:>4}: vcall      i{d} slot{d} r{d}..+{d} -> r{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5] });
                pc += 6;
            },
            .new => {
                try w.print("  {d:>4}: new        i{d} class{d} ctor f{d} r{d}..+{d} -> r{d} site{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5], code[pc + 6], code[pc + 7] });
                pc += 8;
            },
            .callv => {
                try w.print("  {d:>4}: callv      i{d} r{d}(r{d}..+{d}) -> r{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5] });
                pc += 6;
            },
            .not => {
                try w.print("  {d:>4}: not        i{d} r{d} <- !r{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
            .const_str => {
                try w.print("  {d:>4}: const_str  r{d} <- const#{d} string{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
            .make_cell => {
                try w.print("  {d:>4}: make_cell  r{d} <- r{d}\n", .{ pc, code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .cell_set => {
                try w.print("  {d:>4}: cell_set   i{d} *r{d} <- r{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
            .store_static => {
                try w.print("  {d:>4}: store_static i{d} static{d} <- r{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
            .make_closure, .new_array => |o| {
                try w.print("  {d:>4}: {s:<10} i{d}\n", .{ pc, @tagName(o), code[pc + 1] });
                pc += 2;
            },
            .load_capture => {
                try w.print("  {d:>4}: load_capture r{d} <- c{d}\n", .{ pc, code[pc + 1], code[pc + 2] });
                pc += 3;
            },
            .load_static => {
                try w.print("  {d:>4}: load_static i{d} r{d} <- static{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
            .is, .cast => |o| {
                try w.print("  {d:>4}: {s:<10} i{d} r{d} <- r{d} class{d} flags={d}\n", .{ pc, @tagName(o), code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5] });
                pc += 6;
            },
            .native => {
                try w.print("  {d:>4}: native     i{d} n{d} r{d}..+{d} -> r{d} direct={d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4], code[pc + 5], code[pc + 6] });
                pc += 7;
            },
            .array_get => {
                try w.print("  {d:>4}: array_get  i{d} r{d} <- r{d}[r{d}]\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4] });
                pc += 5;
            },
            .array_set => {
                try w.print("  {d:>4}: array_set  i{d} r{d}[r{d}] <- r{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3], code[pc + 4] });
                pc += 5;
            },
            .load_object => {
                try w.print("  {d:>4}: load_object i{d} r{d} <- class{d}\n", .{ pc, code[pc + 1], code[pc + 2], code[pc + 3] });
                pc += 4;
            },
        }
    }
}

test "a body that only reads a field of its receiver, or only stores its parameters, is a leaf" {
    const a = std.testing.allocator;
    const r = ir.Reg.from;
    var getter = [_]ir.Inst{
        .{ .LoadParam = .{ .dst = r(0), .idx = 0 } },
        .{ .GetFieldSlot = .{ .dst = r(1), .obj = r(0), .slot = 3 } },
    };
    var blk: ir.Block = .{ .id = ir.BlockId.from(0), .insts = &getter, .terminator = .{ .Return = r(1) } };
    try std.testing.expectEqual(Leaf{ .get_field = 3 }, leafOfBlocks(a, (&blk)[0..1]));
    // A field of another parameter, or a result other than the field read, is not.
    getter[0].LoadParam.idx = 1;
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&blk)[0..1]));
    getter[0].LoadParam.idx = 0;
    blk.terminator = .{ .Return = r(0) };
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&blk)[0..1]));

    var ctor = [_]ir.Inst{
        .{ .LoadParam = .{ .dst = r(0), .idx = 0 } },
        .{ .LoadParam = .{ .dst = r(1), .idx = 1 } },
        .{ .LoadParam = .{ .dst = r(2), .idx = 2 } },
        .{ .SetFieldSlot = .{ .obj = r(0), .slot = 1, .value = r(2) } },
        .{ .SetFieldSlot = .{ .obj = r(0), .slot = 0, .value = r(1) } },
    };
    var cblk: ir.Block = .{ .id = ir.BlockId.from(0), .insts = &ctor, .terminator = .{ .Return = r(0) } };
    const leaf = leafOfBlocks(a, (&cblk)[0..1]);
    defer if (leaf == .set_fields) a.free(leaf.set_fields);
    try std.testing.expectEqualSlices(FieldStore, &.{ .{ .slot = 1, .param = 2 }, .{ .slot = 0, .param = 1 } }, leaf.set_fields);
    // Storing the receiver itself, into another object, or returning nothing is not.
    ctor[4].SetFieldSlot.value = r(0);
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&cblk)[0..1]));
    ctor[4].SetFieldSlot.value = r(1);
    ctor[3].SetFieldSlot.obj = r(1);
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&cblk)[0..1]));
    ctor[3].SetFieldSlot.obj = r(0);
    cblk.terminator = .{ .Return = null };
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&cblk)[0..1]));
    // Any other instruction, or a second block, makes a frame necessary.
    var other = [_]ir.Inst{
        .{ .LoadParam = .{ .dst = r(0), .idx = 0 } },
        .{ .Move = .{ .dst = r(1), .src = r(0) } },
    };
    const oblk: ir.Block = .{ .id = ir.BlockId.from(0), .insts = &other, .terminator = .{ .Return = r(1) } };
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, (&oblk)[0..1]));
    const two = [_]ir.Block{ blk, blk };
    try std.testing.expectEqual(Leaf.none, leafOfBlocks(a, &two));
}

