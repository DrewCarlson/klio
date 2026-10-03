//! Register liveness over a function's blocks, and the renumbering that lets
//! two registers whose values are never needed at once share one, as a JVM
//! method's locals share slots.

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

inline fn has(set: []const u64, r: u32) bool {
    return set[r >> 6] & (@as(u64, 1) << @as(u6, @truncate(r))) != 0;
}

inline fn add(set: []u64, r: u32) void {
    set[r >> 6] |= @as(u64, 1) << @as(u6, @truncate(r));
}

inline fn remove(set: []u64, r: u32) void {
    set[r >> 6] &= ~(@as(u64, 1) << @as(u6, @truncate(r)));
}

/// Which registers hold a value some later read needs, at the start and the end of each
/// block, over the blocks' edges; and which are live where a catch or a finally starts, which
/// a throw reaches from anywhere in its try region. A catch's exception register is written
/// as its handler starts.
pub const Live = struct {
    n: u32,
    words: usize,
    in: []u64,
    out: []u64,
    handled: []u64,

    /// Null when a register is out of range or a block names a block past the end.
    pub fn init(a: Allocator, blocks: []const Block, n: u32) Allocator.Error!?Live {
        const w: usize = (n + 63) / 64;
        const nb = blocks.len;
        const use = try a.alloc(u64, nb * w);
        defer a.free(use);
        const def = try a.alloc(u64, nb * w);
        defer a.free(def);
        @memset(use, 0);
        @memset(def, 0);
        var self: Live = .{ .n = n, .words = w, .in = try a.alloc(u64, nb * w), .out = &.{}, .handled = &.{} };
        errdefer a.free(self.in);
        self.out = try a.alloc(u64, nb * w);
        errdefer a.free(self.out);
        self.handled = try a.alloc(u64, w);
        errdefer a.free(self.handled);
        @memset(self.in, 0);
        @memset(self.out, 0);
        @memset(self.handled, 0);
        var ok = true;
        for (blocks) |*blk| {
            for (successors(&blk.terminator)) |s| {
                if (s) |t| if (t >= nb) {
                    ok = false;
                };
            }
            for (blk.h().catches) |c| {
                if (c.handler.int() >= nb or c.exception_reg.int() >= n) {
                    ok = false;
                    continue;
                }
                add(row(def, w, c.handler.int()), c.exception_reg.int());
            }
            if (blk.h().finally) |f| if (f.int() >= nb) {
                ok = false;
            };
        }
        const Sum = struct {
            use: []u64,
            def: []u64,
            n: u32,
            ok: *bool,
            fn uses(c: @This(), r: Reg, is_def: bool) void {
                if (is_def) return;
                if (r.int() >= c.n) return c.bad();
                if (!has(c.def, r.int())) add(c.use, r.int());
            }
            fn defs(c: @This(), r: Reg, is_def: bool) void {
                if (!is_def) return;
                if (r.int() >= c.n) return c.bad();
                add(c.def, r.int());
            }
            fn bad(c: @This()) void {
                c.ok.* = false;
            }
        };
        for (blocks, 0..) |*blk, bi| {
            const sum: Sum = .{ .use = row(use, w, bi), .def = row(def, w, bi), .n = n, .ok = &ok };
            for (blk.insts) |*inst| {
                // An instruction reads its operands before it writes its result.
                visitInstRegs(inst, sum, Sum.uses);
                visitInstRegs(inst, sum, Sum.defs);
            }
            visitTerminatorRegs(&blk.terminator, sum, Sum.uses);
        }
        if (!ok) {
            self.deinit(a);
            return null;
        }
        var changed = true;
        while (changed) {
            changed = false;
            var bi = nb;
            while (bi > 0) {
                bi -= 1;
                const out = row(self.out, w, bi);
                for (successors(&blocks[bi].terminator)) |s| {
                    const t = s orelse continue;
                    for (out, row(self.in, w, t)) |*o, x| o.* |= x;
                }
                for (row(self.in, w, bi), out, row(use, w, bi), row(def, w, bi)) |*i, o, u, d| {
                    const v = u | (o & ~d);
                    if (v != i.*) {
                        i.* = v;
                        changed = true;
                    }
                }
            }
        }
        for (blocks) |*blk| {
            for (blk.h().catches) |c| for (self.handled, row(self.in, w, c.handler.int())) |*x, l| {
                x.* |= l;
            };
            if (blk.h().finally) |f| for (self.handled, row(self.in, w, f.int())) |*x, l| {
                x.* |= l;
            };
        }
        return self;
    }

    pub fn deinit(self: *Live, a: Allocator) void {
        a.free(self.in);
        a.free(self.out);
        a.free(self.handled);
    }

    pub fn liveIn(self: *const Live, block: usize) []const u64 {
        return row(self.in, self.words, block);
    }

    pub fn liveOut(self: *const Live, block: usize) []const u64 {
        return row(self.out, self.words, block);
    }

    /// Whether a catch or a finally may read `r` as it holds it when the region throws.
    pub fn isHandled(self: *const Live, r: u32) bool {
        return r < self.n and has(self.handled, r);
    }

    pub fn isLiveOut(self: *const Live, block: usize, r: u32) bool {
        return r < self.n and has(self.liveOut(block), r);
    }
};

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

/// A body with at most this many registers, which is most bodies, keeps its numbering: the
/// pass pays for itself on the wide frames that inlining makes.
pub const COMPACT_MIN_REGS: u32 = 64;

/// A body with more registers than this keeps its numbering too: which pairs may not share
/// is a square table of bits.
pub const COMPACT_MAX_REGS: u32 = 4096;

/// Renumbers the registers of `blocks`, `n` of them, so that two share one when neither is
/// written where the other is live, and returns how many the body has after (`n` when it
/// keeps its numbering). An argument run keeps its registers consecutive; a register a catch
/// or a finally reads shares with none; an instruction's result shares with none of its
/// operands, since a constructor writes its instance before it reads its arguments; a copy's
/// destination may share with its source, and a copy that then copies a register into itself
/// is dropped. What the renamed blocks hold is allocated from `a`.
pub fn compact(a: Allocator, blocks: []Block, n: u32) Allocator.Error!u32 {
    if (n <= COMPACT_MIN_REGS) return n;
    return compactAny(a, blocks, n);
}

fn compactAny(a: Allocator, blocks: []Block, n: u32) Allocator.Error!u32 {
    if (n > COMPACT_MAX_REGS) return n;
    const sa = std.heap.smp_allocator;
    var lv = (try Live.init(sa, blocks, n)) orelse return n;
    defer lv.deinit(sa);
    const w = lv.words;
    // By register: the first register of its unit, the consecutive registers argument runs
    // keep together. Units are intervals: a run links each of its registers to the next.
    const lo = try sa.alloc(u32, n);
    defer sa.free(lo);
    for (lo, 0..) |*x, i| x.* = @intCast(i);
    for (blocks) |*blk| for (blk.insts) |*inst| {
        const run = runOf(inst) orelse continue;
        if (run.n < 2) continue;
        if (run.first + run.n > n) return n;
        var k: u32 = 1;
        while (k < run.n) : (k += 1) link(lo, run.first + k - 1, run.first + k);
    };
    const clash = try sa.alloc(u64, @as(usize, n) * w);
    defer sa.free(clash);
    @memset(clash, 0);
    try interfere(sa, blocks, &lv, clash);
    const to = try sa.alloc(u32, n);
    defer sa.free(to);
    @memset(to, NONE);
    const m = try place(sa, blocks, n, w, lo, clash, to);
    if (m >= n) return n;
    for (blocks) |*blk| try rename(a, blk, to);
    return m;
}

const NONE = std.math.maxInt(u32);

/// The argument run `inst` reads, if it reads one.
fn runOf(inst: *const Inst) ?struct { first: u32, n: u32 } {
    switch (inst.*) {
        inline else => |*p| {
            const P = @TypeOf(p.*);
            if (comptime @hasField(P, "args") and @hasField(P, "n_args")) {
                if (comptime @FieldType(P, "args") == Reg) return .{ .first = p.args.int(), .n = p.n_args };
            }
            return null;
        },
    }
}

/// Puts `y`, which is `x + 1`, in `x`'s unit, with the rest of the unit `y` heads.
fn link(lo: []u32, x: u32, y: u32) void {
    const head = lo[x];
    const old = lo[y];
    if (old == head) return;
    var r = y;
    while (r < lo.len and lo[r] == old) : (r += 1) lo[r] = head;
}

/// Fills `clash`, by register, with the registers it may not share with.
fn interfere(sa: Allocator, blocks: []const Block, lv: *const Live, clash: []u64) Allocator.Error!void {
    const w = lv.words;
    const n = lv.n;
    const live_now = try sa.alloc(u64, w);
    defer sa.free(live_now);
    const Walk = struct {
        clash: []u64,
        w: usize,
        live: []u64,
        inst: *const Inst,
        fn def(c: @This(), r: Reg, is_def: bool) void {
            if (!is_def) return;
            const d = row(c.clash, c.w, r.int());
            const src: ?u32 = switch (c.inst.*) {
                .Move => |m| m.src.int(),
                else => null,
            };
            // A copy's source is left out of what this write adds, not taken from what the
            // register's other writes found.
            for (d, c.live, 0..) |*x, l, wi| {
                const keep: u64 = if (src) |s| (if (s >> 6 == wi) ~(@as(u64, 1) << @as(u6, @truncate(s))) else ~@as(u64, 0)) else ~@as(u64, 0);
                x.* |= l & keep;
            }
            const Ops = struct {
                d: []u64,
                src: ?u32,
                fn cb(o: @This(), x: Reg, x_def: bool) void {
                    if (!x_def and (o.src == null or x.int() != o.src.?)) add(o.d, x.int());
                }
            };
            visitInstRegs(c.inst, Ops{ .d = d, .src = src }, Ops.cb);
        }
        fn kill(c: @This(), r: Reg, is_def: bool) void {
            if (is_def) remove(c.live, r.int());
        }
        fn gen(c: @This(), r: Reg, is_def: bool) void {
            if (!is_def) add(c.live, r.int());
        }
    };
    for (blocks, 0..) |*blk, bi| {
        @memcpy(live_now, lv.liveOut(bi));
        visitTerminatorRegs(&blk.terminator, Walk{ .clash = clash, .w = w, .live = live_now, .inst = undefined }, Walk.gen);
        var i = blk.insts.len;
        while (i > 0) {
            i -= 1;
            const walk: Walk = .{ .clash = clash, .w = w, .live = live_now, .inst = &blk.insts[i] };
            visitInstRegs(walk.inst, walk, Walk.def);
            visitInstRegs(walk.inst, walk, Walk.kill);
            visitInstRegs(walk.inst, walk, Walk.gen);
        }
        // A catch's exception register is written as its handler starts.
        for (blk.h().catches) |c| {
            const d = row(clash, w, c.exception_reg.int());
            for (d, lv.liveIn(c.handler.int())) |*x, l| x.* |= l;
        }
    }
    var r: u32 = 0;
    while (r < n) : (r += 1) {
        if (lv.isHandled(r)) @memset(row(clash, w, r), ~@as(u64, 0));
    }
    // Symmetric, and no register clashes with itself.
    r = 0;
    while (r < n) : (r += 1) {
        for (row(clash, w, r), 0..) |word, wi| {
            var bits = word;
            while (bits != 0) {
                const x: u32 = @intCast(wi * 64 + @ctz(bits));
                bits &= bits - 1;
                if (x < n) add(row(clash, w, x), r);
            }
        }
    }
    r = 0;
    while (r < n) : (r += 1) remove(row(clash, w, r), r);
}

/// Places each unit, in the order the body first names them, at the lowest register where
/// none of its members clashes with a register already placed; returns how many registers
/// the body then has.
fn place(sa: Allocator, blocks: []const Block, n: u32, w: usize, lo: []const u32, clash: []const u64, to: []u32) Allocator.Error!u32 {
    var order: std.ArrayList(u32) = .empty;
    defer order.deinit(sa);
    const named = try sa.alloc(bool, n);
    defer sa.free(named);
    @memset(named, false);
    const Order = struct {
        lo: []const u32,
        named: []bool,
        order: *std.ArrayList(u32),
        sa: Allocator,
        failed: *bool,
        fn cb(c: @This(), r: Reg, _: bool) void {
            const head = c.lo[r.int()];
            if (c.named[head]) return;
            c.named[head] = true;
            c.order.append(c.sa, head) catch {
                c.failed.* = true;
            };
        }
    };
    var failed = false;
    const o: Order = .{ .lo = lo, .named = named, .order = &order, .sa = sa, .failed = &failed };
    for (blocks) |*blk| {
        for (blk.h().catches) |c| Order.cb(o, c.exception_reg, true);
        for (blk.insts) |*inst| visitInstRegs(inst, o, Order.cb);
        visitTerminatorRegs(&blk.terminator, o, Order.cb);
    }
    if (failed) return error.OutOfMemory;
    // By candidate first register: taken by a clash of the unit being placed, which marks
    // it with its stamp. Every register placed so far is below `top`, so a unit may always
    // start at `top`, and only bases below it are marked.
    const taken = try sa.alloc(u32, @as(usize, n) + 1);
    defer sa.free(taken);
    @memset(taken, 0);
    var stamp: u32 = 0;
    var top: u32 = 0;
    for (order.items) |head| {
        var size: u32 = 1;
        while (head + size < n and lo[head + size] == head) size += 1;
        stamp += 1;
        var k: u32 = 0;
        while (k < size) : (k += 1) {
            for (row(clash, w, head + k), 0..) |word, wi| {
                var bits = word;
                while (bits != 0) {
                    const x: u32 = @intCast(wi * 64 + @ctz(bits));
                    bits &= bits - 1;
                    if (x >= n) continue;
                    const at = to[x];
                    if (at == NONE or at < k) continue;
                    if (at - k < top) taken[at - k] = stamp;
                }
            }
        }
        var base: u32 = 0;
        while (base < top and taken[base] == stamp) base += 1;
        k = 0;
        while (k < size) : (k += 1) to[head + k] = base + k;
        top = @max(top, base + size);
    }
    return top;
}

/// `blk`'s registers renamed by `to`; a copy of a register into itself is dropped.
fn rename(a: Allocator, blk: *Block, to: []const u32) Allocator.Error!void {
    var kept: usize = 0;
    for (blk.insts) |x| {
        const y = try mapValue(Inst, a, to, x);
        if (y == .Move and y.Move.dst == y.Move.src) continue;
        blk.insts[kept] = y;
        kept += 1;
    }
    if (kept != blk.insts.len) blk.insts = try a.dupe(Inst, blk.insts[0..kept]);
    blk.terminator = try mapValue(Terminator, a, to, blk.terminator);
    if (blk.handlers) |h| if (h.catches.len != 0) {
        const cs = try a.alloc(CatchHandler, h.catches.len);
        for (h.catches, cs) |c, *x| x.* = .{ .class = c.class, .handler = c.handler, .exception_reg = mapReg(to, c.exception_reg) };
        h.catches = cs;
    };
}

fn mapReg(to: []const u32, r: Reg) Reg {
    return Reg.from(to[r.int()]);
}

/// A payload with its registers renamed. An argument run's first register names the run;
/// an empty run names register 0.
fn mapValue(comptime T: type, a: Allocator, to: []const u32, v: T) Allocator.Error!T {
    if (T == Reg) return mapReg(to, v);
    switch (@typeInfo(T)) {
        .@"union" => switch (v) {
            inline else => |payload, tag| return @unionInit(T, @tagName(tag), try mapValue(@TypeOf(payload), a, to, payload)),
        },
        .@"struct" => |st| {
            var out = v;
            inline for (st.fields) |fld| {
                if (fld.is_comptime) continue;
                if (comptime std.mem.eql(u8, fld.name, "args") and @hasField(T, "n_args") and fld.type == Reg) {
                    out.args = if (v.n_args == 0) Reg.from(0) else mapReg(to, v.args);
                    continue;
                }
                @field(out, fld.name) = try mapValue(fld.type, a, to, @field(v, fld.name));
            }
            return out;
        },
        .optional => |opt| {
            const x = v orelse return null;
            return try mapValue(opt.child, a, to, x);
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (comptime p.child != Reg) return v;
                const out = try a.alloc(Reg, v.len);
                for (v, out) |e, *x| x.* = mapReg(to, e);
                return out;
            },
            else => @compileError("a boxed payload"),
        },
        else => return v,
    }
}

const testing = std.testing;

fn testBlocks(comptime n: usize, insts: [n][]Inst, terms: [n]Terminator) [n]Block {
    var out: [n]Block = undefined;
    for (&out, insts, terms, 0..) |*b, i, t, k| b.* = .{ .id = BlockId.from(@intCast(k)), .insts = i, .terminator = t };
    return out;
}

test "registers whose values are never needed at once share one" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = Reg.from;
    const k = core_ids.ConstId.from(0);
    var insts = [_]Inst{
        .{ .Const = .{ .dst = r(10), .value = k } },
        .{ .BinOp = .{ .dst = r(20), .op = .Add, .lhs = r(10), .rhs = r(10) } },
        .{ .Const = .{ .dst = r(30), .value = k } },
        .{ .BinOp = .{ .dst = r(40), .op = .Add, .lhs = r(30), .rhs = r(20) } },
    };
    var blocks = testBlocks(1, .{&insts}, .{.{ .Return = r(40) }});
    try testing.expectEqual(@as(u32, 3), try compactAny(arena.allocator(), &blocks, 41));
    const got = blocks[0].insts;
    // The second constant takes the first's register, dead by then; the sum clashes with both
    // of its operands.
    try testing.expectEqual(r(0), got[0].Const.dst);
    try testing.expectEqual(r(1), got[1].BinOp.dst);
    try testing.expectEqual(r(0), got[2].Const.dst);
    try testing.expectEqual(r(2), got[3].BinOp.dst);
    try testing.expectEqual(r(2), blocks[0].terminator.Return.?);
}

test "a copy shares its source's register and goes, and an argument run stays consecutive" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = Reg.from;
    const k = core_ids.ConstId.from(0);
    var insts = [_]Inst{
        .{ .Const = .{ .dst = r(3), .value = k } },
        .{ .Move = .{ .dst = r(50), .src = r(3) } },
        .{ .Const = .{ .dst = r(51), .value = k } },
        .{ .CallStatic = .{ .dst = r(60), .func = core_ids.FuncId.from(0), .args = r(50), .n_args = 2 } },
    };
    var blocks = testBlocks(1, .{&insts}, .{.{ .Return = r(60) }});
    try testing.expectEqual(@as(u32, 3), try compactAny(arena.allocator(), &blocks, 61));
    const got = blocks[0].insts;
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqual(r(0), got[0].Const.dst);
    try testing.expectEqual(r(1), got[1].Const.dst);
    try testing.expectEqual(r(0), got[2].CallStatic.args);
    // The call's result clashes with its arguments.
    try testing.expectEqual(r(2), got[2].CallStatic.dst);
}

test "a register a catch reads, and a constructor's instance, share with nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = Reg.from;
    const k = core_ids.ConstId.from(0);
    // Block 0 writes r5 and enters the try at block 1, whose temporary r7 is dead before r8
    // is written; the catch at block 2 reads r5 and its exception r9.
    var before = [_]Inst{.{ .Const = .{ .dst = r(5), .value = k } }};
    var body = [_]Inst{
        .{ .Const = .{ .dst = r(7), .value = k } },
        .{ .RNewInstance = .{ .dst = r(8), .class = core_ids.ClassId.from(0), .ctor = core_ids.FuncId.from(0), .args = r(7), .n_args = 1 } },
    };
    var handler = [_]Inst{.{ .BinOp = .{ .dst = r(6), .op = .Add, .lhs = r(5), .rhs = r(9) } }};
    var catches = [_]CatchHandler{.{ .class = core_ids.ClassId.from(0), .handler = BlockId.from(2), .exception_reg = r(9) }};
    var hs: core_func.BlockHandlers = .{ .catches = &catches };
    var blocks = testBlocks(3, .{ &before, &body, &handler }, .{ .{ .Goto = BlockId.from(1) }, .{ .Return = r(8) }, .{ .Return = r(6) } });
    blocks[1].handlers = &hs;
    const m = try compactAny(arena.allocator(), &blocks, 10);
    try testing.expect(m < 10);
    const five = blocks[0].insts[0].Const.dst;
    const seven = blocks[1].insts[0].Const.dst;
    const eight = blocks[1].insts[1].RNewInstance.dst;
    try testing.expect(five != seven and five != eight);
    try testing.expect(eight != seven);
    try testing.expectEqual(seven, blocks[1].insts[1].RNewInstance.args);
    try testing.expectEqual(five, blocks[2].insts[0].BinOp.lhs);
    try testing.expectEqual(hs.catches[0].exception_reg, blocks[2].insts[0].BinOp.rhs);
}

test "liveness follows the edges, and a handler's reads are live across its region" {
    const r = Reg.from;
    const k = core_ids.ConstId.from(0);
    var entry = [_]Inst{
        .{ .Const = .{ .dst = r(0), .value = k } },
        .{ .Const = .{ .dst = r(1), .value = k } },
    };
    var loop = [_]Inst{.{ .BinOp = .{ .dst = r(2), .op = .Less, .lhs = r(0), .rhs = r(1) } }};
    var exit = [_]Inst{.{ .Move = .{ .dst = r(3), .src = r(1) } }};
    var catches = [_]CatchHandler{.{ .class = core_ids.ClassId.from(0), .handler = BlockId.from(2), .exception_reg = r(4) }};
    var hs: core_func.BlockHandlers = .{ .catches = &catches };
    var blocks = testBlocks(3, .{ &entry, &loop, &exit }, .{
        .{ .Goto = BlockId.from(1) },
        .{ .Branch = .{ .cond = r(2), .t = BlockId.from(1), .f = BlockId.from(2) } },
        .{ .Return = r(3) },
    });
    blocks[1].handlers = &hs;
    var lv = (try Live.init(testing.allocator, &blocks, 5)).?;
    defer lv.deinit(testing.allocator);
    // Around the loop, both constants are live; out of it, only r1 is.
    try testing.expect(lv.isLiveOut(1, 0) and lv.isLiveOut(1, 1));
    try testing.expect(!lv.isLiveOut(0, 2));
    try testing.expect(lv.isHandled(1) and !lv.isHandled(0) and !lv.isHandled(4));
    // A register out of range makes no answer.
    try testing.expectEqual(@as(?Live, null), try Live.init(testing.allocator, &blocks, 3));
}

test "a copy's destination written again where its source is live does not share with it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = Reg.from;
    const k = core_ids.ConstId.from(0);
    // r1 copies r0, then is written again while r0 is still to be returned.
    var insts = [_]Inst{
        .{ .Const = .{ .dst = r(0), .value = k } },
        .{ .Move = .{ .dst = r(1), .src = r(0) } },
        .{ .BinOp = .{ .dst = r(2), .op = .Add, .lhs = r(1), .rhs = r(1) } },
        .{ .Const = .{ .dst = r(1), .value = k } },
        .{ .BinOp = .{ .dst = r(3), .op = .Add, .lhs = r(1), .rhs = r(2) } },
        .{ .BinOp = .{ .dst = r(4), .op = .Add, .lhs = r(3), .rhs = r(0) } },
    };
    var blocks = testBlocks(1, .{&insts}, .{.{ .Return = r(4) }});
    _ = try compactAny(arena.allocator(), &blocks, 5);
    const got = blocks[0].insts;
    // Written again while r0 is live, r1 cannot be r0's register, so the copy stays.
    try testing.expectEqual(@as(usize, 6), got.len);
    const zero = got[0].Const.dst;
    try testing.expect(got[1].Move.dst != zero);
    try testing.expectEqual(got[1].Move.dst, got[3].Const.dst);
    try testing.expectEqual(zero, got[5].BinOp.rhs);
}
