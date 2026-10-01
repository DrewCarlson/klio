//! Machine registers for a loop's graph (`graph.zig`): the blocks laid out
//! from the entry, the loop's back edges left out, then each value's range
//! over that layout from its definition to its last use, stretched over the
//! whole loop for a value live around its back edge, and a linear scan
//! handing each range a register (two for a pair) that no overlapping range
//! holds. Where there are too few, one of the values live where the scan
//! ran out goes to memory, the cheapest first: a value the loop was entered
//! with is read from the frame where it is used, as the frame holds it
//! unchanged while the loop runs; another takes a slot of the code's own
//! stack, a register only where it is made, stored to its slot there and
//! read from it where it is used.

const std = @import("std");
const graph = @import("graph.zig");

const Graph = graph.Graph;
const Id = graph.Id;
const no_id = graph.no_id;

pub const Error = error{ OutOfMemory, Unsupported };

/// A value's registers, indexes into the register sets the caller gives: its word (a
/// word's, or a pair's payload) and a pair's tag word; a Double's word is in the
/// floating set.
pub const Loc = struct {
    word: u8 = none,
    tag: u8 = none,
    /// An entry value read from its root register in the frame at each use.
    frame: bool = false,
    /// The stack slot holding the value, 16 bytes (its word, then a pair's tag); its
    /// registers, if any, hold it only where it is made.
    spill: u16 = no_spill,

    pub fn inMemory(l: Loc) bool {
        return l.frame or l.spill != no_spill;
    }
};

pub const no_spill: u16 = 0xffff;
/// The most stack slots a loop's code takes; one needing more is refused.
pub const max_spills: u16 = 128;

/// Whether value `n` is held in a floating register.
pub fn isFloat(n: graph.Node) bool {
    return n.repr == .word and n.tag == .Double;
}

/// Whether value `n` takes no register, made again at each read: a constant, but a
/// Double's, which takes a floating register once for the loop.
pub fn remade(n: graph.Node) bool {
    return n.op == .konst and !isFloat(n);
}
pub const none: u8 = 0xff;

pub const Alloc = struct {
    /// The blocks in the order their code is laid out.
    order: []u32,
    /// Per value, its registers.
    loc: []Loc,
    /// Per host call, the values held in registers across it, which a call may not keep.
    across: []const []const Id,
    /// The stack slots the values in memory take.
    spills: u16 = 0,
};

/// The values block `b`'s nodes and its terminator read, and the inputs its successors'
/// parameters take from it.
fn uses(g: *const Graph, b: u32, out: *std.ArrayList(Id), a: std.mem.Allocator) !void {
    const blk = g.blocks.items[b];
    for (blk.nodes.items) |id| {
        const n = g.nodes.items[id];
        if (n.op == .phi) continue;
        inline for (.{ n.a, n.b, n.c }) |x| if (x != no_id) try out.append(a, x);
    }
    switch (blk.term) {
        .branch => |br| try out.append(a, br.cond),
        .leave => |x| {
            var it = g.exits.items[x].reads();
            while (it.next()) |v| try out.append(a, v);
        },
        else => {},
    }
    for (blk.nodes.items) |id| {
        const n = g.nodes.items[id];
        if (n.exit != graph.no_exit) {
            var it = g.exits.items[n.exit].reads();
            while (it.next()) |v| try out.append(a, v);
        }
    }
}

/// The input parameter `p` takes from predecessor `pred`.
pub fn phiInput(g: *const Graph, p: Id, pred: u32) Id {
    const n = g.nodes.items[p];
    const preds = g.blocks.items[n.block].preds.items;
    const args = g.phi_args.get(p).?;
    for (preds, args) |pr, x| if (pr == pred) return x;
    unreachable;
}

/// Registers for `g`'s values from `n_regs` general and `n_fregs` floating ones.
pub fn allocate(a: std.mem.Allocator, g: *const Graph, n_regs: u8, n_fregs: u8) Error!Alloc {
    const order = try g.reversePostorder(a);
    const nb = g.blocks.items.len;
    const nv = g.nodes.items.len;
    // Positions: two per node (its reads, then its write), two for each block's end.
    const start = try a.alloc(u32, nb);
    const end = try a.alloc(u32, nb);
    const pos = try a.alloc(u32, nv);
    @memset(start, 0);
    @memset(end, 0);
    var p: u32 = 0;
    for (order) |b| {
        start[b] = p;
        p += 2;
        for (g.blocks.items[b].nodes.items) |id| {
            pos[id] = p + 1;
            p += 2;
        }
        end[b] = p;
        p += 2;
    }
    // Liveness over the blocks, to a fixed point around the loop.
    const W = (nv + 63) / 64;
    const live_in = try a.alloc(u64, nb * W);
    @memset(live_in, 0);
    const live_out = try a.alloc(u64, nb * W);
    @memset(live_out, 0);
    var scratch: std.ArrayList(Id) = .empty;
    var changed = true;
    while (changed) {
        changed = false;
        var k = order.len;
        while (k > 0) {
            k -= 1;
            const b = order[k];
            const out = live_out[b * W ..][0..W];
            var buf: [2]u32 = undefined;
            for (g.successors(b, &buf)) |s| {
                const sin = live_in[s * W ..][0..W];
                for (out, sin) |*o, x| o.* |= x;
                // A successor's parameters are written on the edge; their inputs from here
                // are read at this block's end.
                for (g.blocks.items[s].nodes.items) |id| {
                    if (g.nodes.items[id].op != .phi) continue;
                    unset(out, id);
                    set(out, phiInput(g, id, b));
                }
            }
            const in = try a.dupe(u64, out);
            scratch.clearRetainingCapacity();
            const blk = g.blocks.items[b];
            // The terminator's reads and an exit's values.
            switch (blk.term) {
                .branch => |br| set(in, br.cond),
                .leave => |x| {
                    var it = g.exits.items[x].reads();
                    while (it.next()) |v| set(in, v);
                },
                else => {},
            }
            var i = blk.nodes.items.len;
            while (i > 0) {
                i -= 1;
                const id = blk.nodes.items[i];
                const n = g.nodes.items[id];
                unset(in, id);
                if (n.op == .phi) continue;
                inline for (.{ n.a, n.b, n.c }) |x| if (x != no_id) set(in, x);
                if (n.exit != graph.no_exit) {
                    var it = g.exits.items[n.exit].reads();
                    while (it.next()) |x| set(in, x);
                }
            }
            const old = live_in[b * W ..][0..W];
            if (!std.mem.eql(u64, old, in)) {
                @memcpy(old, in);
                changed = true;
            }
        }
    }
    // Each value's range: from its write to its last read, over every block it lives
    // through.
    const lo = try a.alloc(u32, nv);
    const hi = try a.alloc(u32, nv);
    @memset(lo, std.math.maxInt(u32));
    @memset(hi, 0);
    const Span = struct {
        fn cover(l: []u32, h: []u32, v: Id, at: u32) void {
            if (at < l[v]) l[v] = at;
            if (at > h[v]) h[v] = at;
        }
    };
    for (order) |b| {
        const blk = g.blocks.items[b];
        for (blk.nodes.items) |id| {
            const n = g.nodes.items[id];
            if (n.op == .phi) Span.cover(lo, hi, id, start[b]) else Span.cover(lo, hi, id, pos[id]);
            inline for (.{ n.a, n.b, n.c }) |x| if (x != no_id and n.op != .phi) Span.cover(lo, hi, x, pos[id] - 1);
            // What an exit writes to the frame lives through the node's write: a node may
            // leave after writing its registers (a read between two readings of a write
            // sequence), which must not be one the exit reads.
            if (n.exit != graph.no_exit) {
                var it = g.exits.items[n.exit].reads();
                while (it.next()) |x| Span.cover(lo, hi, x, pos[id]);
            }
        }
        for (0..nv) |v| {
            const id: Id = @intCast(v);
            if (get(live_in[b * W ..][0..W], id)) Span.cover(lo, hi, id, start[b]);
            if (get(live_out[b * W ..][0..W], id)) Span.cover(lo, hi, id, end[b]);
        }
        switch (blk.term) {
            .branch => |br| Span.cover(lo, hi, br.cond, end[b]),
            .leave => |x| {
                var it = g.exits.items[x].reads();
                while (it.next()) |v| Span.cover(lo, hi, v, end[b]);
            },
            else => {},
        }
    }
    // Per value, its reads, which say which entry value to leave in the frame first.
    const reads = try a.alloc(u32, nv);
    @memset(reads, 0);
    for (order) |b| {
        var used: std.ArrayList(Id) = .empty;
        try uses(g, b, &used, a);
        for (used.items) |x| reads[x] += 1;
    }
    var pit0 = g.phi_args.iterator();
    while (pit0.next()) |e| for (e.value_ptr.*) |x| {
        reads[x] += 1;
    };
    const in_frame = try a.alloc(bool, nv);
    @memset(in_frame, false);
    const spilled = try a.alloc(bool, nv);
    @memset(spilled, false);
    while (true) {
        var fail: Id = no_id;
        if (scan(a, g, pos, lo, hi, in_frame, spilled, n_regs, n_fregs, &fail)) |loc| {
            var slots: u16 = 0;
            for (loc, spilled) |*l, sp| if (sp) {
                if (slots == max_spills) return error.Unsupported;
                l.spill = slots;
                slots += 1;
            };
            try check(g, order, loc);
            return .{ .order = order, .loc = loc, .across = try acrossCalls(a, g, order, pos, lo, hi, loc), .spills = slots };
        } else |e| switch (e) {
            error.Unsupported => {},
            else => return e,
        }
        if (fail == no_id) return error.Unsupported;
        // Too few registers where `fail` is made: of the values held there, the one
        // cheapest in memory goes there, a read costing a load and a making a store (an
        // entry value is made by the frame), the longest held first.
        const at = if (spilled[fail]) pos[fail] else lo[fail];
        var pick: Id = no_id;
        var pick_cost: u32 = 0;
        for (0..nv) |v| {
            const n = g.nodes.items[v];
            if (n.forward != no_id or n.repr == .none or remade(n) or in_frame[v] or spilled[v]) continue;
            if (lo[v] == std.math.maxInt(u32) or lo[v] > at or hi[v] < at) continue;
            const cost = reads[v] + @intFromBool(n.op != .entry);
            if (pick == no_id or cost < pick_cost or (cost == pick_cost and hi[v] - lo[v] > hi[pick] - lo[pick])) {
                pick = @intCast(v);
                pick_cost = cost;
            }
        }
        if (pick == no_id) return error.Unsupported;
        if (g.nodes.items[pick].op == .entry) in_frame[pick] = true else spilled[pick] = true;
    }
}

/// A register for each range of `g` not `in_frame`, in the order ranges start, a value
/// `spilled` holding one only where it is made (a parameter none); or
/// `error.Unsupported` where there are too few, `fail` the value that found none.
fn scan(a: std.mem.Allocator, g: *const Graph, pos: []const u32, lo_all: []const u32, hi_all: []const u32, in_frame: []const bool, spilled: []const bool, n_regs: u8, n_fregs: u8, fail: *Id) Error![]Loc {
    const nv = g.nodes.items.len;
    const lo = try a.dupe(u32, lo_all);
    const hi = try a.dupe(u32, hi_all);
    // Linear scan over the ranges in the order they start.
    const vals = try a.alloc(Id, nv);
    var n_vals: usize = 0;
    for (0..nv) |v| {
        const n = g.nodes.items[v];
        if (n.forward != no_id or n.repr == .none or lo[v] == std.math.maxInt(u32) or remade(n) or in_frame[v]) continue;
        if (spilled[v]) {
            if (n.op == .phi) continue;
            lo[v] = pos[v];
            hi[v] = pos[v];
        }
        vals[n_vals] = @intCast(v);
        n_vals += 1;
    }
    const sorted = vals[0..n_vals];
    std.mem.sort(Id, sorted, lo, struct {
        fn lt(l: []const u32, x: Id, y: Id) bool {
            return l[x] < l[y];
        }
    }.lt);
    const loc = try a.alloc(Loc, nv);
    @memset(loc, .{});
    for (in_frame, loc) |f, *l| l.frame = f;
    // A parameter's input from a back edge takes the parameter's registers where they are
    // free, so the edge moves nothing.
    const hint = try a.alloc(Id, nv);
    @memset(hint, no_id);
    var pit = g.phi_args.iterator();
    while (pit.next()) |e| {
        const phi = e.key_ptr.*;
        if (g.nodes.items[phi].forward != no_id) continue;
        for (e.value_ptr.*) |x| if (x != phi and hint[x] == no_id and lo[x] > lo[phi]) {
            hint[x] = phi;
        };
    }
    // Per register of each set, the end of the range holding it.
    const busy_until = try a.alloc(u32, @as(usize, n_regs) + n_fregs);
    @memset(busy_until, 0);
    const held = try a.alloc(bool, @as(usize, n_regs) + n_fregs);
    @memset(held, false);
    for (sorted) |v| {
        const n = g.nodes.items[v];
        const need: u8 = if (n.repr == .pair) 2 else 1;
        const base: usize = if (isFloat(n)) n_regs else 0;
        const count: usize = if (isFloat(n)) n_fregs else n_regs;
        var got: [2]u8 = .{ none, none };
        var k: u8 = 0;
        if (hint[v] != no_id) {
            const h = loc[hint[v]];
            const want = [2]u8{ h.word, h.tag };
            for (want[0..need]) |i| {
                if (i == none) break;
                const r = base + i;
                if (held[r] and busy_until[r] >= lo[v]) break;
                got[k] = i;
                k += 1;
            }
            if (k < need) k = 0;
        }
        for (0..count) |i| {
            if (k == need) break;
            if (k == 1 and got[0] == i) continue;
            const r = base + i;
            if (held[r] and busy_until[r] >= lo[v]) continue;
            got[k] = @intCast(i);
            k += 1;
        }
        if (k < need) {
            fail.* = v;
            return error.Unsupported;
        }
        for (got[0..need]) |i| {
            held[base + i] = true;
            busy_until[base + i] = hi[v];
        }
        loc[v] = .{ .word = got[0], .tag = got[1] };
    }
    return loc;
}

/// Per host call of `g`, the values in registers whose ranges run over it (written before
/// it and read after), and those its exit writes to the frame, which it leaves by after
/// the call.
fn acrossCalls(a: std.mem.Allocator, g: *const Graph, order: []const u32, pos: []const u32, lo: []const u32, hi: []const u32, loc: []const Loc) Error![]const []const Id {
    const nv = g.nodes.items.len;
    const out = try a.alloc([]const Id, nv);
    @memset(out, &.{});
    for (order) |b| for (g.blocks.items[b].nodes.items) |id| {
        if (g.nodes.items[id].op != .host_call) continue;
        const at = pos[id];
        var held: std.ArrayList(Id) = .empty;
        const exit_reads = try a.alloc(bool, nv);
        @memset(exit_reads, false);
        var it = g.exits.items[g.nodes.items[id].exit].reads();
        while (it.next()) |x| exit_reads[x] = true;
        for (0..nv) |v| {
            if (v == id or loc[v].word == none or loc[v].inMemory()) continue;
            if ((lo[v] < at and hi[v] > at) or exit_reads[v]) try held.append(a, @intCast(v));
        }
        out[id] = held.items;
    };
    return out;
}

/// Every value read has its registers, or its place in the frame: a graph whose layout
/// left a read value out is refused rather than read from none.
fn check(g: *const Graph, order: []const u32, loc: []const Loc) Error!void {
    const Check = struct {
        fn has(gr: *const Graph, l: []const Loc, x: Id) bool {
            if (x == no_id) return true;
            const n = gr.nodes.items[x];
            if (n.repr == .none or remade(n) or l[x].inMemory()) return true;
            if (l[x].word == none) return false;
            return n.repr != .pair or l[x].tag != none;
        }
    };
    for (order) |b| {
        const blk = g.blocks.items[b];
        for (blk.nodes.items) |id| {
            const n = g.nodes.items[id];
            if (!Check.has(g, loc, id)) return error.Unsupported;
            if (n.op == .phi) {
                for (g.phi_args.get(id).?) |x| if (!Check.has(g, loc, x)) return error.Unsupported;
                continue;
            }
            inline for (.{ n.a, n.b, n.c }) |x| if (!Check.has(g, loc, x)) return error.Unsupported;
            if (n.exit != graph.no_exit) {
                var it = g.exits.items[n.exit].reads();
                while (it.next()) |x| if (!Check.has(g, loc, x)) return error.Unsupported;
            }
        }
        switch (blk.term) {
            .branch => |br| if (!Check.has(g, loc, br.cond)) return error.Unsupported,
            .leave => |x| {
                var it = g.exits.items[x].reads();
                while (it.next()) |v| if (!Check.has(g, loc, v)) return error.Unsupported;
            },
            else => {},
        }
    }
}

inline fn set(s: []u64, v: Id) void {
    s[v >> 6] |= @as(u64, 1) << @as(u6, @truncate(v));
}
inline fn unset(s: []u64, v: Id) void {
    s[v >> 6] &= ~(@as(u64, 1) << @as(u6, @truncate(v)));
}
inline fn get(s: []const u64, v: Id) bool {
    return s[v >> 6] & (@as(u64, 1) << @as(u6, @truncate(v))) != 0;
}

const testing = std.testing;

test "a counter and an accumulator live around the loop hold registers apart, an entry value is read from the frame where registers run out, and then a value takes a stack slot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Graph.init(a);
    const E = struct {
        pub fn value(_: @This(), gr: *Graph, variable: u32) !Id {
            if (gr.entries.get(variable)) |v| return v;
            const v = try gr.add(gr.entry_block, .{ .op = .entry, .repr = .word, .tag = .Int, .aux = variable, .block = gr.entry_block });
            try gr.entries.put(gr.a, variable, v);
            return v;
        }
    };
    const e = E{};
    const b0 = try g.newBlock();
    const b1 = try g.newBlock();
    const b2 = try g.newBlock();
    g.entry_block = b0;
    try g.seal(b0, e);
    try g.addEdge(b0, b1);
    g.blocks.items[b0].term = .{ .jump = b1 };
    // head: i and acc; body: acc += i; i += 1; back
    const ihead = try g.readVar(1, b1, e);
    const acc0 = try g.readVar(2, b1, e);
    const lim = try g.readVar(0, b1, e);
    const cond = try g.add(b1, .{ .op = .cmp, .repr = .word, .tag = .Bool, .a = ihead, .b = lim, .aux = @intFromEnum(@import("../../ir.zig").BinOp.Less), .block = b1 });
    try g.addEdge(b1, b2);
    try g.seal(b2, e);
    const sum = try g.add(b2, .{ .op = .arith, .repr = .word, .tag = .Int, .a = acc0, .b = ihead, .aux = 0, .block = b2 });
    try g.writeVar(2, b2, sum);
    const inc = try g.add(b2, .{ .op = .step, .repr = .word, .tag = .Int, .a = ihead, .aux = 1, .block = b2 });
    try g.writeVar(1, b2, inc);
    try g.addEdge(b2, b1);
    g.blocks.items[b2].term = .{ .jump = b1 };
    const b3 = try g.newBlock();
    try g.addEdge(b1, b3);
    try g.seal(b3, e);
    try g.exits.append(a, .{ .pc = 0, .blk = 0, .slots = try a.dupe(graph.Slot, &.{.{ .reg = 2, .v = try g.readVar(2, b3, e) }}) });
    g.blocks.items[b3].term = .{ .leave = 0 };
    g.blocks.items[b1].term = .{ .branch = .{ .cond = cond, .t = b2, .f = b3 } };
    try g.seal(b1, e);
    try g.finish();
    const al = try allocate(a, &g, 6, 0);
    const pi = g.resolve(ihead);
    const pacc = g.resolve(acc0);
    const plim = g.resolve(lim);
    // The parameters, the limit and the condition each hold a register of their own
    // wherever they overlap.
    try testing.expect(al.loc[pi].word != none and al.loc[pacc].word != none);
    try testing.expect(al.loc[pi].word != al.loc[pacc].word);
    try testing.expect(al.loc[plim].word != none and al.loc[plim].word != al.loc[pi].word and al.loc[plim].word != al.loc[pacc].word);
    try testing.expect(!al.loc[plim].frame);
    // One register fewer than the head reads at once: the limit, which the loop was
    // entered with, is read from the frame, and the parameters keep registers.
    const tight = try allocate(a, &g, 3, 0);
    try testing.expect(tight.loc[plim].frame);
    try testing.expect(tight.loc[pi].word != none and tight.loc[pacc].word != none and tight.loc[pi].word != tight.loc[pacc].word);
    // Fewer still: a value the loop makes takes a stack slot, with a register only where
    // it is made, and every value read has its place.
    const spill = try allocate(a, &g, 2, 0);
    try testing.expect(spill.spills >= 1);
    var slotted: u32 = 0;
    for (g.nodes.items, spill.loc, 0..) |n, l, v| {
        if (l.spill == no_spill) continue;
        slotted += 1;
        try testing.expect(n.op != .entry);
        try testing.expect(l.spill < spill.spills);
        for (spill.loc, 0..) |o, w| if (w != v and o.spill != no_spill) try testing.expect(o.spill != l.spill);
    }
    try testing.expectEqual(@as(u32, spill.spills), slotted);
    try check(&g, spill.order, spill.loc);
    // No register to make a value in: refused.
    try testing.expectError(error.Unsupported, allocate(a, &g, 0, 0));
}

test "a node's result takes no register of a value its exit writes to the frame" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var g = Graph.init(a);
    const b0 = try g.newBlock();
    const b1 = try g.newBlock();
    g.entry_block = b0;
    try g.addEdge(b0, b1);
    g.blocks.items[b0].term = .{ .jump = b1 };
    const arr = try g.add(b0, .{ .op = .entry, .repr = .word, .tag = .Array, .aux = 0, .block = b0 });
    const i = try g.add(b0, .{ .op = .entry, .repr = .word, .tag = .Int, .aux = 1, .block = b0 });
    // An index made in the loop, read by the element's read and its exit only.
    const j = try g.add(b1, .{ .op = .step, .repr = .word, .tag = .Int, .a = i, .aux = 1, .block = b1 });
    try g.exits.append(a, .{ .pc = 0, .blk = 1, .slots = try a.dupe(graph.Slot, &.{.{ .reg = 2, .v = j }}) });
    const elem = try g.add(b1, .{ .op = .array_get, .repr = .pair, .a = arr, .b = j, .block = b1, .exit = 0 });
    try g.exits.append(a, .{ .pc = 9, .blk = 1, .slots = try a.dupe(graph.Slot, &.{.{ .reg = 3, .v = elem }}) });
    g.blocks.items[b1].term = .{ .leave = 1 };
    const al = try allocate(a, &g, 6, 0);
    // The element's read may leave after writing its registers: the index its exit writes
    // back is in neither.
    try testing.expect(al.loc[elem].word != al.loc[j].word and al.loc[elem].tag != al.loc[j].word);
}
