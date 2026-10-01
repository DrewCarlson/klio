//! The optimizing tier's passes over a finished graph (`graph.zig`).

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const graph = @import("graph.zig");

const Graph = graph.Graph;
const Id = graph.Id;
const no_id = graph.no_id;

/// An `unbox`, or a check of a tag, of a word already of its tag is that word (a
/// parameter's representation is known only once the graph is finished); a constant moves
/// to the entry block, where it is made once for the whole loop. A check of a word of
/// another tag always leaves, which the code does (`emit`).
pub fn simplify(g: *Graph) !void {
    for (g.nodes.items) |*n| {
        if (n.forward != no_id or (n.op != .unbox and n.op != .check_tag)) continue;
        const x = g.nodes.items[g.resolve(n.a)];
        if (x.repr == .word and x.tag == n.tag) n.forward = n.a;
    }
    // `forward` points at the operand; now every argument through it.
    for (g.nodes.items) |*n| {
        n.a = g.resolve(n.a);
        n.b = g.resolve(n.b);
        n.c = g.resolve(n.c);
    }
    var it = g.phi_args.iterator();
    while (it.next()) |e| for (e.value_ptr.*) |*x| {
        x.* = g.resolve(x.*);
    };
    for (g.exits.items) |*x| {
        for (@constCast(x.slots)) |*s| s.v = g.resolve(s.v);
        x.span = g.resolve(x.span);
    }
    const entry = &g.blocks.items[g.entry_block];
    for (g.blocks.items, 0..) |*blk, bi| {
        if (blk.term == .branch) blk.term.branch.cond = g.resolve(blk.term.branch.cond);
        var w: usize = 0;
        for (blk.nodes.items) |id| {
            const n = &g.nodes.items[id];
            if (n.forward != no_id) continue;
            if (n.op == .konst and bi != g.entry_block) {
                n.block = g.entry_block;
                try entry.nodes.append(g.a, id);
                continue;
            }
            blk.nodes.items[w] = id;
            w += 1;
        }
        blk.nodes.shrinkRetainingCapacity(w);
    }
}

/// Whether node `n` reads new value `v` only as the object it works on: a use that lets
/// nothing else reach `v`.
fn onlyOn(n: graph.Node, v: Id) bool {
    return switch (n.op) {
        .get_field, .init_field, .set_field, .array_size, .array_get, .check_slots, .check_plain, .check_class, .class_is => n.a == v and n.b != v and n.c != v,
        else => false,
    };
}

fn isNew(n: graph.Node) bool {
    return n.op == .new_inst or n.op == .new_prim;
}

/// A new value nothing else reaches (no store, parameter, call or exit takes it): a read of
/// one of its fields no store changes after its making is the value its making stored
/// there, and the length of a new array is its size. A new value only stores then read
/// is not made at all, nor are its stores.
pub fn foldNew(g: *Graph) !void {
    const nv = g.nodes.items.len;
    const reached = try g.a.alloc(bool, nv);
    defer g.a.free(reached);
    const stored = try g.a.alloc(bool, nv);
    defer g.a.free(stored);
    @memset(reached, false);
    @memset(stored, false);
    for (g.blocks.items) |blk| {
        for (blk.nodes.items) |id| {
            const n = g.nodes.items[id];
            inline for (.{ n.a, n.b, n.c }) |x| if (x != no_id and isNew(g.nodes.items[x]) and !onlyOn(n, x)) {
                reached[x] = true;
            };
            if (n.op == .set_field and n.a != no_id) stored[n.a] = true;
        }
        if (blk.term == .leave) {
            var it = g.exits.items[blk.term.leave].reads();
            while (it.next()) |x| reached[x] = true;
        }
    }
    var pit = g.phi_args.iterator();
    while (pit.next()) |e| for (e.value_ptr.*) |x| {
        reached[x] = true;
    };
    for (g.blocks.items) |blk| for (blk.nodes.items) |id| {
        const n = g.nodes.items[id];
        if (n.exit == graph.no_exit) continue;
        // The length of a new array, answered below where nothing else reaches the array,
        // takes its exit with it.
        if (n.op == .array_size and g.nodes.items[n.a].op == .new_prim) continue;
        var it = g.exits.items[n.exit].reads();
        while (it.next()) |x| reached[x] = true;
    };
    // Reads answered by the making.
    for (g.nodes.items) |*n| {
        if (n.forward != no_id or n.a == no_id) continue;
        const v = n.a;
        const made = g.nodes.items[v];
        if (!isNew(made) or reached[v]) continue;
        switch (n.op) {
            .get_field => {
                if (made.op != .new_inst or stored[v]) continue;
                const slot = n.aux & 0xffff_ffff;
                // The making's last store to the slot: its stores follow it in its block.
                var value: Id = no_id;
                for (g.blocks.items[made.block].nodes.items) |s| {
                    const sn = g.nodes.items[s];
                    if (sn.op == .init_field and sn.a == v and sn.aux == slot) value = sn.b;
                }
                if (value != no_id) n.forward = value;
            },
            .array_size => if (made.op == .new_prim) {
                n.forward = made.a;
            },
            else => {},
        }
    }
    try simplify(g);
    // What is left of each new value's uses: none but its stores, and it goes.
    const read = reached;
    @memset(read, false);
    for (g.blocks.items) |blk| for (blk.nodes.items) |id| {
        const n = g.nodes.items[id];
        inline for (.{ n.a, n.b, n.c }) |x| if (x != no_id and isNew(g.nodes.items[x])) {
            const store_on = (n.op == .init_field or n.op == .set_field) and n.a == x and n.b != x;
            if (!store_on) read[x] = true;
        };
        if (n.exit != graph.no_exit) {
            var it = g.exits.items[n.exit].reads();
            while (it.next()) |x| read[x] = true;
        }
    };
    for (g.blocks.items) |blk| if (blk.term == .leave) {
        var it = g.exits.items[blk.term.leave].reads();
        while (it.next()) |x| read[x] = true;
    };
    var pit2 = g.phi_args.iterator();
    while (pit2.next()) |e| for (e.value_ptr.*) |x| {
        read[x] = true;
    };
    for (g.blocks.items) |*blk| {
        var w: usize = 0;
        for (blk.nodes.items) |id| {
            const n = g.nodes.items[id];
            const gone = if (isNew(n))
                !read[id]
            else if ((n.op == .init_field or n.op == .set_field) and isNew(g.nodes.items[n.a]))
                !read[n.a]
            else
                false;
            if (gone) continue;
            blk.nodes.items[w] = id;
            w += 1;
        }
        blk.nodes.shrinkRetainingCapacity(w);
    }
}

/// A check whose answer a check before it already gave, on every path to it, goes: a tag
/// check or an unbox of a value checked for that tag is the first check's word; a check of
/// an instance's slots no more than one before it checked, of its plainness after one did
/// or after its class was proved, or of its class after it was proved, is dropped. A
/// class is proved by a check of it, or on the taken edge of a branch on a test of it. The
/// checks' exits go with them.
pub fn dedupChecks(g: *Graph, module: ?*const ir.Module) !void {
    const a = g.a;
    const order = try g.reversePostorder(a);
    const idom = try g.dominators(a, order);
    const nb = g.blocks.items.len;
    var children = try a.alloc(std.ArrayList(u32), nb);
    for (children) |*c| c.* = .empty;
    for (order[1..]) |b| if (idom[b] != graph.no_exit) try children[idom[b]].append(a, b);
    // What the checks on the path from the entry proved: the undo log restores a block's
    // parent's facts when the walk leaves it.
    const Key = struct { what: u8, v: Id, arg: u64 };
    var facts: std.AutoHashMapUnmanaged(Key, u64) = .empty;
    const Undo = struct { key: Key, had: ?u64 };
    var undo: std.ArrayList(Undo) = .empty;
    const Facts = struct {
        facts: *std.AutoHashMapUnmanaged(Key, u64),
        undo: *std.ArrayList(Undo),
        a: std.mem.Allocator,
        fn set(f: @This(), k: Key, val: u64) !void {
            try f.undo.append(f.a, .{ .key = k, .had = f.facts.get(k) });
            try f.facts.put(f.a, k, val);
        }
        fn get(f: @This(), k: Key) ?u64 {
            return f.facts.get(k);
        }
    };
    const f: Facts = .{ .facts = &facts, .undo = &undo, .a = a };
    const tag_k: u8 = 0;
    const slots_k: u8 = 1;
    const plain_k: u8 = 2;
    const class_k: u8 = 3;
    const Class = struct {
        fn plain(m: ?*const ir.Module, class: u64) bool {
            if (comptime !runtime.plain_slots) return false;
            const mod = m orelse return false;
            const r = mod.resolved orelse return false;
            if (class >= r.classes.len) return false;
            return runtime.InstanceData.seqOf(r.classes[class].def) & runtime.PLAIN_SLOTS != 0;
        }
    };
    const proveClass = struct {
        fn prove(fs: Facts, m: ?*const ir.Module, v: Id, class: u64) !void {
            try fs.set(.{ .what = class_k, .v = v, .arg = 0 }, class);
            if (Class.plain(m, class)) try fs.set(.{ .what = plain_k, .v = v, .arg = 0 }, 1);
        }
    }.prove;
    var stack: std.ArrayList(struct { b: u32, mark: usize, child: usize }) = .empty;
    try stack.append(a, .{ .b = g.entry_block, .mark = 0, .child = 0 });
    var entered = true;
    while (stack.items.len != 0) {
        const top = &stack.items[stack.items.len - 1];
        if (entered) {
            entered = false;
            top.mark = undo.items.len;
            const b = top.b;
            // The taken edge of a branch on a class test proves the class.
            const preds = g.blocks.items[b].preds.items;
            if (preds.len == 1) {
                const t = g.blocks.items[preds[0]].term;
                if (t == .branch and t.branch.t == b and t.branch.t != t.branch.f) {
                    const c = g.nodes.items[g.resolve(t.branch.cond)];
                    if (c.op == .class_is) try proveClass(f, module, g.resolve(c.a), c.aux);
                }
            }
            for (g.blocks.items[b].nodes.items) |id| {
                const n = &g.nodes.items[id];
                if (n.forward != no_id) continue;
                const x = g.resolve(n.a);
                switch (n.op) {
                    .check_tag, .unbox => {
                        const k: Key = .{ .what = tag_k, .v = x, .arg = @intFromEnum(n.tag) };
                        if (f.get(k)) |y| n.forward = @intCast(y) else try f.set(k, id);
                    },
                    .check_slots => {
                        const k: Key = .{ .what = slots_k, .v = x, .arg = 0 };
                        const had = f.get(k);
                        if (had != null and had.? >= n.aux) n.forward = x else try f.set(k, n.aux);
                    },
                    .check_plain => {
                        const k: Key = .{ .what = plain_k, .v = x, .arg = 0 };
                        if (f.get(k) != null) n.forward = x else try f.set(k, 1);
                    },
                    .check_class => {
                        const k: Key = .{ .what = class_k, .v = x, .arg = 0 };
                        if (f.get(k)) |c| {
                            if (c == n.aux) n.forward = x;
                        } else try proveClass(f, module, x, n.aux);
                    },
                    else => {},
                }
            }
        }
        if (top.child < children[top.b].items.len) {
            const c = children[top.b].items[top.child];
            top.child += 1;
            try stack.append(a, .{ .b = c, .mark = 0, .child = 0 });
            entered = true;
            continue;
        }
        // Leaving the block: its facts no longer hold.
        while (undo.items.len > top.mark) {
            const u = undo.pop().?;
            if (u.had) |h| try facts.put(a, u.key, h) else _ = facts.remove(u.key);
        }
        _ = stack.pop();
    }
    try simplify(g);
}

const testing = std.testing;

test "an unbox of a word of its tag is the word, and a constant is made in the entry block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const b0 = try g.newBlock();
    const b1 = try g.newBlock();
    g.entry_block = b0;
    const w = try g.add(b0, .{ .op = .entry, .repr = .word, .tag = .Int, .block = b0 });
    const k = try g.konst(b1, .Int, 7);
    const u = try g.add(b1, .{ .op = .unbox, .repr = .word, .tag = .Int, .a = w, .block = b1 });
    const s = try g.add(b1, .{ .op = .arith, .repr = .word, .tag = .Int, .a = u, .b = k, .block = b1 });
    try simplify(&g);
    try testing.expectEqual(w, g.nodes.items[s].a);
    try testing.expectEqual(b0, g.nodes.items[k].block);
    try testing.expectEqual(@as(usize, 1), g.blocks.items[b1].nodes.items.len);
    try testing.expect(std.mem.indexOfScalar(Id, g.blocks.items[b0].nodes.items, k) != null);
}

test "a field read of a new instance nothing else reaches is the value its making stored, and the instance is not made" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // The same loop twice: the second leaves with the instance in a register.
    for ([_]bool{ false, true }) |kept| {
        var g = Graph.init(arena.allocator());
        const b0 = try g.newBlock();
        const b1 = try g.newBlock();
        g.entry_block = b0;
        const x = try g.add(b0, .{ .op = .entry, .repr = .word, .tag = .Int, .block = b0 });
        const y = try g.add(b0, .{ .op = .entry, .repr = .word, .tag = .Int, .block = b0 });
        const made = try g.add(b1, .{ .op = .new_inst, .repr = .word, .tag = .Instance, .len = 64, .block = b1, .exit = 0 });
        try g.exits.append(g.a, .{ .pc = 0, .blk = 0, .slots = &.{} });
        _ = try g.add(b1, .{ .op = .init_field, .repr = .none, .a = made, .b = x, .aux = 0, .block = b1 });
        _ = try g.add(b1, .{ .op = .init_field, .repr = .none, .a = made, .b = y, .aux = 1, .block = b1 });
        const read = try g.add(b1, .{ .op = .get_field, .repr = .pair, .a = made, .aux = 1 | (@as(u64, 1) << 32), .block = b1 });
        const u = try g.add(b1, .{ .op = .unbox, .repr = .word, .tag = .Int, .a = read, .block = b1 });
        const s = try g.add(b1, .{ .op = .arith, .repr = .word, .tag = .Int, .a = u, .b = x, .aux = @intFromEnum(ir.BinOp.Add), .block = b1 });
        const slots: []const graph.Slot = if (kept) &.{ .{ .reg = 0, .v = s }, .{ .reg = 1, .v = made } } else &.{.{ .reg = 0, .v = s }};
        try g.exits.append(g.a, .{ .pc = 9, .blk = 1, .slots = slots });
        g.blocks.items[b1].term = .{ .leave = 1 };
        try foldNew(&g);
        const left = g.blocks.items[b1].nodes.items;
        if (kept) {
            // The instance leaves in a register: it is made, and its field read.
            try testing.expect(std.mem.indexOfScalar(Id, left, made) != null);
            try testing.expectEqual(@as(usize, 6), left.len);
        } else {
            // Its read is `y`; nothing is left of it but the sum.
            try testing.expectEqual(y, g.nodes.items[s].a);
            try testing.expectEqual(@as(usize, 1), left.len);
            try testing.expectEqual(s, left[0]);
        }
    }
}

test "the length of a new primitive array nothing else reaches is its size" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const b0 = try g.newBlock();
    const b1 = try g.newBlock();
    g.entry_block = b0;
    const n = try g.add(b0, .{ .op = .entry, .repr = .word, .tag = .Int, .block = b0 });
    const arr = try g.add(b1, .{ .op = .new_prim, .repr = .word, .tag = .Array, .a = n, .block = b1, .exit = 0 });
    try g.exits.append(g.a, .{ .pc = 0, .blk = 0, .slots = &.{} });
    // The length's own exit holds the array, as the call it leaves to reads it.
    try g.exits.append(g.a, .{ .pc = 5, .blk = 1, .slots = &.{.{ .reg = 1, .v = arr }} });
    const len = try g.add(b1, .{ .op = .array_size, .repr = .word, .tag = .Int, .a = arr, .aux = 1, .block = b1, .exit = 1 });
    const s = try g.add(b1, .{ .op = .arith, .repr = .word, .tag = .Int, .a = len, .b = n, .aux = @intFromEnum(ir.BinOp.Add), .block = b1 });
    try g.exits.append(g.a, .{ .pc = 9, .blk = 1, .slots = &.{.{ .reg = 0, .v = s }} });
    g.blocks.items[b1].term = .{ .leave = 2 };
    try foldNew(&g);
    try testing.expectEqual(n, g.nodes.items[s].a);
    try testing.expectEqual(@as(usize, 1), g.blocks.items[b1].nodes.items.len);
}

test "a check a dominating check answered goes, and one on a path the first is not on stays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    // B0 -> B1: checks, then a branch on a class test: B2 (taken), B3 (not); both -> B4.
    const b0 = try g.newBlock();
    const b1 = try g.newBlock();
    const b2 = try g.newBlock();
    const b3 = try g.newBlock();
    const b4 = try g.newBlock();
    g.entry_block = b0;
    for ([_][2]u32{ .{ b0, b1 }, .{ b1, b2 }, .{ b1, b3 }, .{ b2, b4 }, .{ b3, b4 } }) |e| try g.addEdge(e[0], e[1]);
    g.blocks.items[b0].term = .{ .jump = b1 };
    g.blocks.items[b2].term = .{ .jump = b4 };
    g.blocks.items[b3].term = .{ .jump = b4 };
    try g.exits.append(g.a, .{ .pc = 0, .blk = 0, .slots = &.{} });
    const p = try g.add(b0, .{ .op = .entry, .repr = .pair, .block = b0 });
    const t1 = try g.add(b1, .{ .op = .check_tag, .repr = .word, .tag = .Instance, .a = p, .block = b1, .exit = 0 });
    const s1 = try g.add(b1, .{ .op = .check_slots, .repr = .none, .a = t1, .aux = 1, .block = b1, .exit = 0 });
    const is = try g.add(b1, .{ .op = .class_is, .repr = .word, .tag = .Bool, .a = t1, .aux = 7, .block = b1 });
    g.blocks.items[b1].term = .{ .branch = .{ .cond = is, .t = b2, .f = b3 } };
    // Taken edge: the same tag check, fewer slots, and a check of the class the test proved.
    const t2 = try g.add(b2, .{ .op = .check_tag, .repr = .word, .tag = .Instance, .a = p, .block = b2, .exit = 0 });
    const s2 = try g.add(b2, .{ .op = .check_slots, .repr = .none, .a = t1, .aux = 0, .block = b2, .exit = 0 });
    const c2 = try g.add(b2, .{ .op = .check_class, .repr = .none, .a = t1, .aux = 7, .block = b2, .exit = 0 });
    // Not taken: more slots, and the class, which nothing proved there.
    const s3 = try g.add(b3, .{ .op = .check_slots, .repr = .none, .a = t1, .aux = 3, .block = b3, .exit = 0 });
    const c3 = try g.add(b3, .{ .op = .check_class, .repr = .none, .a = t1, .aux = 7, .block = b3, .exit = 0 });
    // After the join: the class, proved on one path only.
    const c4 = try g.add(b4, .{ .op = .check_class, .repr = .none, .a = t1, .aux = 7, .block = b4, .exit = 0 });
    try g.exits.append(g.a, .{ .pc = 9, .blk = 1, .slots = &.{} });
    g.blocks.items[b4].term = .{ .leave = 1 };
    try dedupChecks(&g, null);
    const has = struct {
        fn f(gr: *const Graph, b: u32, id: Id) bool {
            return std.mem.indexOfScalar(Id, gr.blocks.items[b].nodes.items, id) != null;
        }
    }.f;
    try testing.expect(has(&g, b1, t1) and has(&g, b1, s1));
    try testing.expect(!has(&g, b2, t2) and !has(&g, b2, s2) and !has(&g, b2, c2));
    try testing.expectEqual(t1, g.resolve(t2));
    try testing.expect(has(&g, b3, s3) and has(&g, b3, c3));
    try testing.expect(has(&g, b4, c4));
}
