//! What a function's frame is known by from where it stands. A frame records its position
//! (a block and the instruction it is at, or the block's start) wherever the collector, a
//! stack capture or a suspension can observe it; the registers live there, the registers
//! written on every path there, and the registers a frame fills as it opens all follow from
//! the function's code. The code is its instructions as its streams run them (`Effect`),
//! not as they stand: a parameter load the entry block runs first, a constant the op that
//! reads it carries.

const std = @import("std");
const core_ids = @import("ids.zig");
const core_inst = @import("inst.zig");
const core_func = @import("func.zig");

const Allocator = std.mem.Allocator;
const Block = core_func.Block;
const BlockId = core_ids.BlockId;
const CatchHandler = core_inst.CatchHandler;
const Inst = core_inst.Inst;
const Reg = core_ids.Reg;
const Terminator = core_inst.Terminator;
const visitInstRegs = core_inst.visitInstRegs;
const visitTerminatorRegs = core_inst.visitTerminatorRegs;

/// How a function's code runs an instruction where it does not run it as it stands.
pub const Effect = struct {
    /// The instruction, with the blocks' instructions laid end to end.
    at: u32,
    kind: Kind,
    /// For `unread`, the register the instruction's op does not read.
    reg: u32 = 0,

    pub const Kind = enum(u8) {
        /// Runs as its block begins, before any other instruction of it: a parameter load
        /// the entry block's `load_params` takes.
        hoisted = 1,
        /// Does nothing: a constant the op that reads it carries.
        skipped = 2,
        /// Its op carries `reg`'s constant and reads no register for it.
        unread = 3,
    };
};

/// The position at a block's start, before anything in it has run, its hoisted
/// instructions included: where a frame stands as it opens and as an edge into the block
/// polls.
pub const block_start: u32 = std.math.maxInt(u32);

/// One instruction as its code runs it: 0 as it stands, else an `Effect.Kind`.
const Run = struct { kind: u8 = 0, reg: u32 = 0 };

pub const FrameMap = struct {
    n: u32,
    words: usize,
    /// Per block, its first instruction's index with the blocks' laid end to end.
    base: []u32,
    run: []Run,
    live_in: []u64,
    live_out: []u64,
    /// Registers a catch or a finally reads as it starts, which a throw reaches it with.
    handled: []u64,
    /// Whether the function has a catch or a finally.
    handlers: bool,
    /// Per block, the registers every path to its start has written (all of them at a block
    /// no path reaches, whose positions nothing observes).
    must_in: []u64,
    /// Per block, the registers its hoisted instructions write as it begins.
    pre: []u64,
    /// Registers a read can find unwritten on some path to it; a frame writes `Unit` to each
    /// as it opens. Empty for almost every function.
    fill: []u32,
    fill_set: []u64,

    /// Null when a register is `n` or past it, a block names a block past the end, an
    /// effect names an instruction past the end, or `entry` is not a block.
    pub fn init(a: Allocator, blocks: []const Block, entry: u32, n: u32, effects: []const Effect) Allocator.Error!?FrameMap {
        const nb = blocks.len;
        if (entry >= nb) return null;
        if (!inRange(blocks, n)) return null;
        const w: usize = (n + 63) / 64;
        var self: FrameMap = .{
            .n = n,
            .words = w,
            .base = &.{},
            .run = &.{},
            .live_in = &.{},
            .live_out = &.{},
            .handled = &.{},
            .handlers = false,
            .must_in = &.{},
            .pre = &.{},
            .fill = &.{},
            .fill_set = &.{},
        };
        errdefer self.deinit(a);
        const sh = (try Shape.init(a, blocks, n, effects)) orelse return null;
        self.base = sh.base;
        self.run = sh.run;
        self.pre = sh.pre;
        self.live_in = try a.alloc(u64, nb * w);
        self.live_out = try a.alloc(u64, nb * w);
        self.handled = try a.alloc(u64, w);
        @memset(self.live_in, 0);
        @memset(self.live_out, 0);
        @memset(self.handled, 0);
        for (blocks) |*b| {
            if (b.h().catches.len != 0 or b.h().finally != null) self.handlers = true;
        }
        const use = try a.alloc(u64, nb * w);
        defer a.free(use);
        const def = try a.alloc(u64, nb * w);
        defer a.free(def);
        @memset(use, 0);
        @memset(def, 0);
        // A catch's exception register is written by the throw that reaches it, before its
        // block starts: live there, where the handler's block-entry safe point observes it.
        for (blocks, 0..) |*b, bi| {
            const u = row(use, w, bi);
            const d = row(def, w, bi);
            for (d, row(self.pre, w, bi)) |*x, p| x.* |= p;
            for (b.insts, 0..) |*inst, i| {
                const r = self.runAt(bi, i);
                if (r.kind == @intFromEnum(Effect.Kind.hoisted) or r.kind == @intFromEnum(Effect.Kind.skipped)) continue;
                // An instruction reads its operands before it writes its result.
                each(inst, .use, unreadOf(r), AddUnless{ .set = u, .unless = d });
                each(inst, .def, null, AddTo{ .set = d });
            }
            eachTerm(&b.terminator, AddUnless{ .set = u, .unless = d });
        }
        var changed = true;
        while (changed) {
            changed = false;
            var bi = nb;
            while (bi > 0) {
                bi -= 1;
                const out = row(self.live_out, w, bi);
                for (successors(&blocks[bi].terminator)) |s| {
                    const t = s orelse continue;
                    for (out, row(self.live_in, w, t)) |*o, x| o.* |= x;
                }
                for (row(self.live_in, w, bi), out, row(use, w, bi), row(def, w, bi)) |*i, o, u, d| {
                    const v = u | (o & ~d);
                    if (v != i.*) {
                        i.* = v;
                        changed = true;
                    }
                }
            }
        }
        for (blocks) |*b| {
            for (b.h().catches) |c| for (self.handled, row(self.live_in, w, c.handler.int())) |*x, l| {
                x.* |= l;
            };
            if (b.h().finally) |f| for (self.handled, row(self.live_in, w, f.int())) |*x, l| {
                x.* |= l;
            };
        }
        const m = try mustWritten(a, blocks, entry, sh);
        self.must_in = m.in;
        self.fill = m.fill;
        self.fill_set = m.fill_set;
        return self;
    }

    pub fn deinit(self: *FrameMap, a: Allocator) void {
        a.free(self.base);
        a.free(self.run);
        a.free(self.live_in);
        a.free(self.live_out);
        a.free(self.handled);
        a.free(self.must_in);
        a.free(self.pre);
        a.free(self.fill);
        a.free(self.fill_set);
        self.* = undefined;
    }

    fn runAt(self: *const FrameMap, block: usize, i: usize) Run {
        return self.run[self.base[block] + i];
    }

    /// Fills `out` (`words` long) with the registers live before instruction `pos` of block
    /// `block` runs, `pos` at the block's length being its terminator, or at the block's
    /// start (`block_start`). In a function with a catch or a finally, a register one of them
    /// reads is live wherever it holds a value (every path has written it, or the frame
    /// filled it): a throw there may reach the handler, and a throw where it holds none
    /// cannot reach one that reads it, or the read would find it unwritten and the fill set
    /// would have it. `scratch` is `words` long.
    pub fn liveBefore(self: *const FrameMap, blocks: []const Block, block: u32, pos: u32, out: []u64, scratch: []u64) void {
        const w = self.words;
        if (pos == block_start) {
            @memcpy(out, row(self.live_in, w, block));
        } else {
            @memcpy(out, row(self.live_out, w, block));
            const blk = &blocks[block];
            eachTerm(&blk.terminator, AddTo{ .set = out });
            var i = blk.insts.len;
            const stop = @min(pos, blk.insts.len);
            while (i > stop) {
                i -= 1;
                const r = self.runAt(block, i);
                // A hoisted instruction ran as the block began, before any position in it; a
                // skipped one does nothing.
                if (r.kind == @intFromEnum(Effect.Kind.hoisted) or r.kind == @intFromEnum(Effect.Kind.skipped)) continue;
                each(&blk.insts[i], .def, null, RemoveFrom{ .set = out });
                each(&blk.insts[i], .use, unreadOf(r), AddTo{ .set = out });
            }
        }
        if (!self.handlers) return;
        self.writtenBefore(blocks, block, pos, scratch);
        for (out, self.handled, scratch, self.fill_set) |*o, h, wr, f| o.* |= h & (wr | f);
    }

    /// Fills `out` (`words` long) with the registers every path has written before
    /// instruction `pos` of block `block` (or at its start).
    pub fn writtenBefore(self: *const FrameMap, blocks: []const Block, block: u32, pos: u32, out: []u64) void {
        const w = self.words;
        @memcpy(out, row(self.must_in, w, block));
        if (pos == block_start) return;
        for (out, row(self.pre, w, block)) |*o, p| o.* |= p;
        const blk = &blocks[block];
        for (blk.insts[0..@min(pos, blk.insts.len)], 0..) |*x, i| {
            const r = self.runAt(block, i);
            if (r.kind == @intFromEnum(Effect.Kind.hoisted) or r.kind == @intFromEnum(Effect.Kind.skipped)) continue;
            each(x, .def, null, AddTo{ .set = out });
        }
    }

    pub fn isFilled(self: *const FrameMap, r: u32) bool {
        return r < self.n and has(self.fill_set, r);
    }
};

/// A function's code as its streams run it: per block, its first instruction's index with
/// the blocks' laid end to end; per instruction, how it runs; per block, the registers its
/// hoisted instructions write as it begins.
const Shape = struct {
    n: u32,
    words: usize,
    base: []u32,
    run: []Run,
    pre: []u64,

    /// Null when an effect names an instruction past the end or a register past `n`.
    fn init(a: Allocator, blocks: []const Block, n: u32, effects: []const Effect) Allocator.Error!?Shape {
        const w: usize = (n + 63) / 64;
        const base = try a.alloc(u32, blocks.len);
        errdefer a.free(base);
        var total: u32 = 0;
        for (blocks, base) |*b, *x| {
            x.* = total;
            total += @intCast(b.insts.len);
        }
        const run = try a.alloc(Run, total);
        errdefer a.free(run);
        @memset(run, .{});
        for (effects) |e| {
            if (e.at >= total or (e.kind == .unread and e.reg >= n)) {
                a.free(run);
                a.free(base);
                return null;
            }
            run[e.at] = .{ .kind = @intFromEnum(e.kind), .reg = e.reg };
        }
        const pre = try a.alloc(u64, blocks.len * w);
        @memset(pre, 0);
        for (blocks, 0..) |*b, bi| {
            for (b.insts, 0..) |*inst, i| {
                if (run[base[bi] + i].kind == @intFromEnum(Effect.Kind.hoisted)) each(inst, .def, null, AddTo{ .set = row(pre, w, bi) });
            }
        }
        return .{ .n = n, .words = w, .base = base, .run = run, .pre = pre };
    }

    fn deinit(self: Shape, a: Allocator) void {
        a.free(self.base);
        a.free(self.run);
        a.free(self.pre);
    }

    fn runAt(self: Shape, block: usize, i: usize) Run {
        return self.run[self.base[block] + i];
    }
};

/// The registers a read in `blocks` can find unwritten on some path from `entry`, as the
/// function's code runs them (`effects`): those a frame writes `Unit` to as it opens so that
/// every register live anywhere holds a value there. Null where a frame map would be.
pub fn fillSet(a: Allocator, blocks: []const Block, entry: u32, n: u32, effects: []const Effect) Allocator.Error!?[]u32 {
    if (entry >= blocks.len or !inRange(blocks, n)) return null;
    const sh = (try Shape.init(a, blocks, n, effects)) orelse return null;
    defer sh.deinit(a);
    const m = try mustWritten(a, blocks, entry, sh);
    a.free(m.in);
    a.free(m.fill_set);
    return m.fill;
}

const Must = struct { in: []u64, fill: []u32, fill_set: []u64 };

/// The forward must-written dataflow: per block, the registers every path to its start has
/// written; a catch or a finally starts with what was written where its region began (and
/// what that block's hoisted instructions wrote), a catch with its exception register too.
/// Then the fill set: every register a read can find unwritten on some path to it. A block
/// no path reaches keeps everything written and reads nothing.
fn mustWritten(a: Allocator, blocks: []const Block, entry: u32, sh: Shape) Allocator.Error!Must {
    const nb = blocks.len;
    const w = sh.words;
    const gen = try a.alloc(u64, nb * w);
    defer a.free(gen);
    const exposed = try a.alloc(u64, nb * w);
    defer a.free(exposed);
    @memset(exposed, 0);
    for (blocks, 0..) |*b, bi| {
        const g = row(gen, w, bi);
        @memcpy(g, row(sh.pre, w, bi));
        const e = row(exposed, w, bi);
        for (b.insts, 0..) |*inst, i| {
            const r = sh.runAt(bi, i);
            if (r.kind == @intFromEnum(Effect.Kind.hoisted) or r.kind == @intFromEnum(Effect.Kind.skipped)) continue;
            each(inst, .use, unreadOf(r), AddUnless{ .set = e, .unless = g });
            each(inst, .def, null, AddTo{ .set = g });
        }
        eachTerm(&b.terminator, AddUnless{ .set = e, .unless = g });
    }
    const in = try a.alloc(u64, nb * w);
    errdefer a.free(in);
    @memset(in, ~@as(u64, 0));
    @memset(row(in, w, entry), 0);
    const reached = try a.alloc(bool, nb);
    defer a.free(reached);
    @memset(reached, false);
    reached[entry] = true;
    const out = try a.alloc(u64, w);
    defer a.free(out);
    const at = try a.alloc(u64, w);
    defer a.free(at);
    var changed = true;
    while (changed) {
        changed = false;
        for (blocks, 0..) |*b, bi| {
            if (!reached[bi]) continue;
            for (out, row(in, w, bi), row(gen, w, bi)) |*o, i, g| o.* = i | g;
            for (successors(&b.terminator)) |s| {
                const t = s orelse continue;
                if (meetInto(row(in, w, t), out, t == entry)) changed = true;
                if (!reached[t]) {
                    reached[t] = true;
                    changed = true;
                }
            }
            // What the region had written as it began.
            for (at, row(in, w, bi), row(sh.pre, w, bi)) |*x, i, p| x.* = i | p;
            for (b.h().catches) |c| {
                const t = c.handler.int();
                const ex = c.exception_reg.int();
                const had = has(at, ex);
                add(at, ex);
                if (meetInto(row(in, w, t), at, t == entry)) changed = true;
                if (!had) remove(at, ex);
                if (!reached[t]) {
                    reached[t] = true;
                    changed = true;
                }
            }
            if (b.h().finally) |f| {
                const t = f.int();
                if (meetInto(row(in, w, t), at, t == entry)) changed = true;
                if (!reached[t]) {
                    reached[t] = true;
                    changed = true;
                }
            }
        }
    }
    const fill_set = try a.alloc(u64, w);
    errdefer a.free(fill_set);
    @memset(fill_set, 0);
    for (0..nb) |bi| {
        if (!reached[bi]) continue;
        for (fill_set, row(exposed, w, bi), row(in, w, bi)) |*f, e, i| f.* |= e & ~i;
    }
    var list: std.ArrayList(u32) = .empty;
    errdefer list.deinit(a);
    for (0..sh.n) |r| {
        if (has(fill_set, @intCast(r))) try list.append(a, @intCast(r));
    }
    return .{ .in = in, .fill = try list.toOwnedSlice(a), .fill_set = fill_set };
}

/// Whether every register `blocks` name is below `n`, and every block they name is one of
/// them.
fn inRange(blocks: []const Block, n: u32) bool {
    const Check = struct {
        n: u32,
        ok: *bool,
        fn cb(c: @This(), r: Reg, _: bool) void {
            if (r.int() >= c.n) c.ok.* = false;
        }
    };
    var ok = true;
    const ck: Check = .{ .n = n, .ok = &ok };
    for (blocks) |*b| {
        for (b.insts) |*inst| visitInstRegs(inst, ck, Check.cb);
        visitTerminatorRegs(&b.terminator, ck, Check.cb);
        for (successors(&b.terminator)) |s| if (s) |t| if (t >= blocks.len) {
            ok = false;
        };
        for (b.h().catches) |c| {
            if (c.handler.int() >= blocks.len or c.exception_reg.int() >= n) ok = false;
        }
        if (b.h().finally) |f| if (f.int() >= blocks.len) {
            ok = false;
        };
    }
    return ok;
}

inline fn unreadOf(r: Run) ?u32 {
    return if (r.kind == @intFromEnum(Effect.Kind.unread)) r.reg else null;
}

const Side = enum { use, def };

/// Calls `ctx.f(r)` for each register `inst` reads (`.use`, but `unread`) or writes (`.def`).
fn each(inst: *const Inst, comptime side: Side, unread: ?u32, ctx: anytype) void {
    const W = struct {
        ctx: @TypeOf(ctx),
        unread: ?u32,
        fn cb(x: @This(), r: Reg, is_def: bool) void {
            if (is_def != (side == .def)) return;
            if (x.unread) |u| if (r.int() == u) return;
            x.ctx.f(r.int());
        }
    };
    visitInstRegs(inst, W{ .ctx = ctx, .unread = unread }, W.cb);
}

/// Calls `ctx.f(r)` for each register terminator `t` reads.
fn eachTerm(t: *const Terminator, ctx: anytype) void {
    const W = struct {
        ctx: @TypeOf(ctx),
        fn cb(x: @This(), r: Reg, is_def: bool) void {
            if (!is_def) x.ctx.f(r.int());
        }
    };
    visitTerminatorRegs(t, W{ .ctx = ctx }, W.cb);
}

const AddTo = struct {
    set: []u64,
    fn f(c: @This(), r: u32) void {
        add(c.set, r);
    }
};

const RemoveFrom = struct {
    set: []u64,
    fn f(c: @This(), r: u32) void {
        remove(c.set, r);
    }
};

const AddUnless = struct {
    set: []u64,
    unless: []const u64,
    fn f(c: @This(), r: u32) void {
        if (!has(c.unless, r)) add(c.set, r);
    }
};

/// `dst` = `dst` & `x`, whether it changed; the entry keeps nothing written.
fn meetInto(dst: []u64, x: []const u64, is_entry: bool) bool {
    if (is_entry) return false;
    var changed = false;
    for (dst, x) |*d, v| {
        const nv = d.* & v;
        if (nv != d.*) {
            d.* = nv;
            changed = true;
        }
    }
    return changed;
}

inline fn has(set: []const u64, r: u32) bool {
    return set[r >> 6] & (@as(u64, 1) << @as(u6, @truncate(r))) != 0;
}

inline fn add(set: []u64, r: u32) void {
    set[r >> 6] |= @as(u64, 1) << @as(u6, @truncate(r));
}

inline fn remove(set: []u64, r: u32) void {
    set[r >> 6] &= ~(@as(u64, 1) << @as(u6, @truncate(r)));
}

fn row(set: anytype, w: usize, i: usize) @TypeOf(set[0..w]) {
    return set[i * w ..][0..w];
}

fn successors(t: *const Terminator) [2]?u32 {
    return switch (t.*) {
        .Goto => |x| .{ x.int(), null },
        .Branch => |br| .{ br.t.int(), br.f.int() },
        else => .{ null, null },
    };
}

const testing = std.testing;

fn testBlocks(comptime n: usize, insts: [n][]Inst, terms: [n]Terminator) [n]Block {
    var out: [n]Block = undefined;
    for (&out, insts, terms, 0..) |*b, i, t, k| b.* = .{ .id = BlockId.from(@intCast(k)), .insts = i, .terminator = t };
    return out;
}

test "a frame map answers the registers live before each instruction, and a catch's reads where they are written" {
    const r = Reg.from;
    const k = core_ids.ConstId.from(0);
    var entry = [_]Inst{
        .{ .Const = .{ .dst = r(0), .value = k } },
        .{ .Const = .{ .dst = r(5), .value = k } },
        .{ .BinOp = .{ .dst = r(1), .op = .Add, .lhs = r(0), .rhs = r(0) } },
    };
    var body = [_]Inst{.{ .BinOp = .{ .dst = r(2), .op = .Add, .lhs = r(1), .rhs = r(1) } }};
    var handler = [_]Inst{.{ .BinOp = .{ .dst = r(3), .op = .Add, .lhs = r(5), .rhs = r(4) } }};
    var catches = [_]CatchHandler{.{ .class = core_ids.ClassId.from(0), .handler = BlockId.from(2), .exception_reg = r(4) }};
    var hs: core_func.BlockHandlers = .{ .catches = &catches };
    var blocks = testBlocks(3, .{ &entry, &body, &handler }, .{ .{ .Goto = BlockId.from(1) }, .{ .Return = r(2) }, .{ .Return = r(3) } });
    var set: [1]u64 = undefined;
    var scratch: [1]u64 = undefined;
    // With no handler: nothing is live before the first constant, r0 before the sum, r1 after it.
    {
        var plain = testBlocks(2, .{ &entry, &body }, .{ .{ .Goto = BlockId.from(1) }, .{ .Return = r(2) } });
        var fm = (try FrameMap.init(testing.allocator, &plain, 0, 6, &.{})).?;
        defer fm.deinit(testing.allocator);
        try testing.expect(!fm.handlers);
        fm.liveBefore(&plain, 0, 0, &set, &scratch);
        try testing.expectEqual(@as(u64, 0), set[0]);
        fm.liveBefore(&plain, 0, 2, &set, &scratch);
        try testing.expectEqual(@as(u64, 1 << 0), set[0]);
        fm.liveBefore(&plain, 0, 3, &set, &scratch);
        try testing.expectEqual(@as(u64, 1 << 1), set[0]);
        fm.liveBefore(&plain, 1, 1, &set, &scratch);
        try testing.expectEqual(@as(u64, 1 << 2), set[0]);
        fm.liveBefore(&plain, 1, block_start, &set, &scratch);
        try testing.expectEqual(@as(u64, 1 << 1), set[0]);
    }
    // The catch in block 1 reads r5, live wherever it is written: in the region, and after
    // the entry block writes it, but not before. Its exception register, which the throw
    // writes, is live as the handler's block starts.
    blocks[1].handlers = &hs;
    var fm = (try FrameMap.init(testing.allocator, &blocks, 0, 6, &.{})).?;
    defer fm.deinit(testing.allocator);
    try testing.expect(fm.handlers);
    fm.liveBefore(&blocks, 1, 1, &set, &scratch);
    try testing.expectEqual(@as(u64, 1 << 2 | 1 << 5), set[0]);
    fm.liveBefore(&blocks, 0, 2, &set, &scratch);
    try testing.expectEqual(@as(u64, 1 << 0 | 1 << 5), set[0]);
    fm.liveBefore(&blocks, 0, 1, &set, &scratch);
    try testing.expectEqual(@as(u64, 1 << 0), set[0]);
    fm.liveBefore(&blocks, 0, 0, &set, &scratch);
    try testing.expectEqual(@as(u64, 0), set[0]);
    fm.liveBefore(&blocks, 2, block_start, &set, &scratch);
    try testing.expectEqual(@as(u64, 1 << 4 | 1 << 5), set[0]);
    try testing.expectEqual(@as(usize, 0), fm.fill.len);
}

test "an entry block's hoisted parameter loads write their registers before its first position" {
    const r = Reg.from;
    // As `close` runs: its two loads go into the entry's `load_params`, so r4, which the
    // block's own order writes only after the `new`, is live and written at the `new`.
    var entry = [_]Inst{
        .{ .LoadParam = .{ .dst = r(0), .idx = 1 } },
        .{ .RNewInstance = .{ .dst = r(5), .class = core_ids.ClassId.from(0), .ctor = core_ids.FuncId.from(0), .args = r(0), .n_args = 1 } },
        .{ .LoadParam = .{ .dst = r(4), .idx = 0 } },
        .{ .CallStatic = .{ .dst = r(7), .func = core_ids.FuncId.from(0), .args = r(4), .n_args = 2 } },
    };
    var blocks = testBlocks(1, .{&entry}, .{.{ .Return = r(7) }});
    var set: [1]u64 = undefined;
    var scratch: [1]u64 = undefined;
    const effects = [_]Effect{ .{ .at = 0, .kind = .hoisted }, .{ .at = 2, .kind = .hoisted } };
    var fm = (try FrameMap.init(testing.allocator, &blocks, 0, 8, &effects)).?;
    defer fm.deinit(testing.allocator);
    fm.liveBefore(&blocks, 0, 1, &set, &scratch);
    try testing.expectEqual(@as(u64, 1 << 0 | 1 << 4), set[0]);
    fm.writtenBefore(&blocks, 0, 1, &set);
    try testing.expectEqual(@as(u64, 1 << 0 | 1 << 4), set[0]);
    try testing.expectEqual(@as(usize, 0), fm.fill.len);
    // Before the loads run, at the block's start, neither is live or written.
    fm.liveBefore(&blocks, 0, block_start, &set, &scratch);
    try testing.expectEqual(@as(u64, 0), set[0]);
    fm.writtenBefore(&blocks, 0, block_start, &set);
    try testing.expectEqual(@as(u64, 0), set[0]);
    // Read in their own order, the loads leave r4 dead at the `new`.
    var plain = (try FrameMap.init(testing.allocator, &blocks, 0, 8, &.{})).?;
    defer plain.deinit(testing.allocator);
    plain.liveBefore(&blocks, 0, 1, &set, &scratch);
    try testing.expectEqual(@as(u64, 1 << 0), set[0]);
}

test "a constant its op carries is neither written nor read, so it is not live in between" {
    const r = Reg.from;
    const k = core_ids.ConstId.from(0);
    // `1 + deep(n - 1)`: the 1 goes into the add, whose code carries it.
    var entry = [_]Inst{
        .{ .LoadParam = .{ .dst = r(0), .idx = 0 } },
        .{ .Const = .{ .dst = r(5), .value = k } },
        .{ .CallStatic = .{ .dst = r(9), .func = core_ids.FuncId.from(0), .args = r(0), .n_args = 1 } },
        .{ .BinOp = .{ .dst = r(3), .op = .Add, .lhs = r(5), .rhs = r(9) } },
    };
    var blocks = testBlocks(1, .{&entry}, .{.{ .Return = r(3) }});
    var set: [1]u64 = undefined;
    var scratch: [1]u64 = undefined;
    const effects = [_]Effect{ .{ .at = 1, .kind = .skipped }, .{ .at = 3, .kind = .unread, .reg = 5 } };
    var fm = (try FrameMap.init(testing.allocator, &blocks, 0, 10, &effects)).?;
    defer fm.deinit(testing.allocator);
    fm.liveBefore(&blocks, 0, 2, &set, &scratch);
    try testing.expectEqual(@as(u64, 1 << 0), set[0]);
    fm.writtenBefore(&blocks, 0, 2, &set);
    try testing.expectEqual(@as(u64, 1 << 0), set[0]);
    try testing.expectEqual(@as(usize, 0), fm.fill.len);
    // As the instructions stand, r5 is live and written across the call.
    var plain = (try FrameMap.init(testing.allocator, &blocks, 0, 10, &.{})).?;
    defer plain.deinit(testing.allocator);
    plain.liveBefore(&blocks, 0, 2, &set, &scratch);
    try testing.expectEqual(@as(u64, 1 << 0 | 1 << 5), set[0]);
}

test "a register one branch writes and the join reads is filled as the frame opens, and one both write is not" {
    const r = Reg.from;
    const k = core_ids.ConstId.from(0);
    var entry = [_]Inst{.{ .Const = .{ .dst = r(0), .value = k } }};
    var then = [_]Inst{
        .{ .Const = .{ .dst = r(1), .value = k } },
        .{ .Const = .{ .dst = r(2), .value = k } },
    };
    var els = [_]Inst{.{ .Const = .{ .dst = r(2), .value = k } }};
    var join = [_]Inst{
        .{ .Move = .{ .dst = r(3), .src = r(1) } },
        .{ .Move = .{ .dst = r(4), .src = r(2) } },
    };
    var blocks = testBlocks(4, .{ &entry, &then, &els, &join }, .{
        .{ .Branch = .{ .cond = r(0), .t = BlockId.from(1), .f = BlockId.from(2) } },
        .{ .Goto = BlockId.from(3) },
        .{ .Goto = BlockId.from(3) },
        .{ .Return = r(4) },
    });
    var fm = (try FrameMap.init(testing.allocator, &blocks, 0, 5, &.{})).?;
    defer fm.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{1}, fm.fill);
    try testing.expect(fm.isFilled(1) and !fm.isFilled(2));
    // An unreachable block's reads fill nothing; an entry past the blocks, a register past
    // the count or an effect past the instructions has no map.
    var dead = [_]Inst{.{ .Move = .{ .dst = r(3), .src = r(4) } }};
    var with_dead = testBlocks(2, .{ &entry, &dead }, .{ .{ .Return = r(0) }, .{ .Return = r(3) } });
    var fd = (try FrameMap.init(testing.allocator, &with_dead, 0, 5, &.{})).?;
    defer fd.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), fd.fill.len);
    try testing.expectEqual(@as(?FrameMap, null), try FrameMap.init(testing.allocator, &with_dead, 7, 5, &.{}));
    try testing.expectEqual(@as(?FrameMap, null), try FrameMap.init(testing.allocator, &with_dead, 0, 4, &.{}));
    try testing.expectEqual(@as(?FrameMap, null), try FrameMap.init(testing.allocator, &with_dead, 0, 5, &.{.{ .at = 9, .kind = .skipped }}));
}

test "a catch or finally starts with what was written where its try region began" {
    const r = Reg.from;
    const k = core_ids.ConstId.from(0);
    // Block 0 writes r0 and enters the try at block 1, which writes r1 and returns; block 2
    // catches into r3 and block 3 is the finally.
    var before = [_]Inst{.{ .Const = .{ .dst = r(0), .value = k } }};
    var body = [_]Inst{.{ .Const = .{ .dst = r(1), .value = k } }};
    var catch_insts = [_]Inst{.{ .Move = .{ .dst = r(2), .src = r(0) } }};
    var fin_insts = [_]Inst{.{ .Move = .{ .dst = r(4), .src = r(0) } }};
    var catches = [_]CatchHandler{.{ .class = core_ids.ClassId.from(0), .handler = BlockId.from(2), .exception_reg = r(3) }};
    var try_handlers: core_func.BlockHandlers = .{ .catches = &catches, .finally = BlockId.from(3) };
    var blocks = [_]Block{
        .{ .id = BlockId.from(0), .insts = &before, .terminator = .{ .Goto = BlockId.from(1) } },
        .{ .id = BlockId.from(1), .insts = &body, .terminator = .{ .Return = r(1) }, .handlers = &try_handlers },
        .{ .id = BlockId.from(2), .insts = &catch_insts, .terminator = .{ .Return = r(2) } },
        .{ .id = BlockId.from(3), .insts = &fin_insts, .terminator = .{ .Return = r(4) } },
    };
    const T = struct {
        fn fill(bl: []const Block) ![]u32 {
            return (try fillSet(testing.allocator, bl, 0, 5, &.{})).?;
        }
    };
    var f = try T.fill(&blocks);
    try testing.expectEqualSlices(u32, &.{}, f);
    testing.allocator.free(f);
    // The catch reads its exception.
    catch_insts[0] = .{ .Move = .{ .dst = r(2), .src = r(3) } };
    f = try T.fill(&blocks);
    try testing.expectEqualSlices(u32, &.{}, f);
    testing.allocator.free(f);
    // A register only the try body writes may not be written yet when it throws.
    catch_insts[0] = .{ .Move = .{ .dst = r(2), .src = r(1) } };
    f = try T.fill(&blocks);
    try testing.expectEqualSlices(u32, &.{1}, f);
    testing.allocator.free(f);
    catch_insts[0] = .{ .Move = .{ .dst = r(2), .src = r(0) } };
    fin_insts[0] = .{ .Move = .{ .dst = r(4), .src = r(1) } };
    f = try T.fill(&blocks);
    try testing.expectEqualSlices(u32, &.{1}, f);
    testing.allocator.free(f);
    // Nor is another catch's exception register written.
    fin_insts[0] = .{ .Move = .{ .dst = r(4), .src = r(3) } };
    f = try T.fill(&blocks);
    try testing.expectEqualSlices(u32, &.{3}, f);
    testing.allocator.free(f);
}
