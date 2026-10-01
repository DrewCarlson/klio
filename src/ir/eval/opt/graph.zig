//! The optimizing tier's graph (`plans/jit-opt.md`): a loop's ops as values
//! in SSA form over blocks, built as the ops are read (Braun et al.,
//! "Simple and Efficient Construction of Static Single Assignment Form"):
//! each register of the root and of every callee compiled in place is a
//! variable, a read finds the value its block or its predecessors last
//! wrote, and a block whose predecessors are not all known yet (the loop's
//! head, until its back edges are read) takes a parameter it fills in when
//! they are.
//!
//! A value is held one of two ways (`Repr`): a machine word whose tag is
//! known, or a whole 16-byte value, payload and tag word. Checks name the
//! exit their failure takes: the root op to leave to and the root registers
//! the frame must hold for it.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");

const Value = runtime.Value;
pub const Tag = std.meta.Tag(Value);

pub const Id = u32;
pub const no_id: Id = std.math.maxInt(u32);
pub const no_exit: u32 = std.math.maxInt(u32);

/// How a value is held.
pub const Repr = enum(u8) {
    /// One machine word whose tag is `Node.tag`: an Int's or a Bool's low 32
    /// bits, a Long's or a Double's 64, a reference's pointer.
    word,
    /// A whole value: its payload word and its tag word.
    pair,
    /// No value (a store, a check that answers nothing).
    none,
};

pub const Op = enum(u8) {
    /// A root register's value where the loop is entered: `aux` the register.
    entry,
    /// A block parameter, one input per predecessor in `Block.preds` order (`Graph.phiArgs`).
    phi,
    /// A constant: `aux` the payload bits, `tag` its tag.
    konst,
    /// The pair `a` as a word of tag `tag`; leaves by `exit` when its tag is another.
    check_tag,
    /// `a op b` over words of tag `tag` (Int, Long, Double): `aux` the `ir.BinOp`.
    arith,
    /// `a op b` compared: `aux` the `ir.BinOp`, the operands' tag in `aux >> 8`; a Bool.
    cmp,
    /// `a` converted: `aux` the operand's tag, `tag` the result's.
    conv,
    /// `a + 1` or `a - 1` (`aux` 1 or -1 as bits) over a word of tag `tag`.
    step,
    /// The value in slot `aux & 0xffff_ffff` of the instance `a`, a pair; plain slots
    /// where `aux >> 32` is 1.
    get_field,
    /// Slot `aux & 0xffff_ffff` of the instance `a` = `b`; plain slots where `aux >> 32`.
    set_field,
    /// Leaves by `exit` unless the instance `a` has more than `aux` slots.
    check_slots,
    /// Leaves by `exit` unless the instance `a` has plain slots.
    check_plain,
    /// Leaves by `exit` unless the instance `a`'s class is `aux`.
    check_class,
    /// Whether the instance `a`'s class is `aux`: a Bool.
    class_is,
    /// Element `b` (an Int) of the array `a`, a pair: an IntArray's, a LongArray's, a
    /// DoubleArray's, or an `Array<T>`'s read between two equal even readings of its write
    /// sequence; leaves by `exit` for any other array, an index out of range, or a writer.
    array_get,
    /// A word as a pair: `a` with its tag `tag`.
    box,
    /// The pair `a` as a word of tag `tag`, which the kinds prove it holds: no check.
    unbox,
    /// Leaves by `exit` when the back edge's guard has work: the edge flags are up, or
    /// the thread's spin counter reaches its check.
    check_poll,
    /// A new instance, a word: a copy of its class's template (`aux` the image's address,
    /// `len` its bytes) bumped out of the thread's region hole; leaves by `exit` when the
    /// hole has no room.
    new_inst,
    /// Slot `aux` of the new instance `a` = `b`, before anything else can see it.
    init_field,
    /// A new primitive array of kind `kind` with `a` (an Int) elements, zeroed, a word: a
    /// copy of the kind's template (`aux`, `len`) and its elements bumped out of the
    /// thread's region hole; leaves by `exit` for a size out of range or a hole without
    /// room.
    new_prim,
    /// The length of the array `a`, an Int, for an array of kind bits `aux` (0 for
    /// `Array<T>`, a primitive kind's plus one); leaves by `exit` for another array.
    array_size,
    /// Leaves by `exit` unless the closure `a` is one over the lambda record `aux`.
    check_closure,
    /// Capture `aux` of the closure `a`, a pair: `Unit` past its captures.
    capture,
    /// Leaves by `exit` when the pair `a` is null.
    check_not_null,
    /// Whether the pair `a` is null, a Bool; whether it is not where `aux` is 1.
    is_null,
    /// Leaves by `exit` when the word `a` (an Int or a Long divisor) is zero.
    check_nonzero,
    /// Element `b` (an Int) of the list `a`, a pair, read between two equal even readings
    /// of its storage's write sequence; leaves by `exit` for a view of another collection,
    /// an index out of range, or a writer.
    list_get,
    /// The size of the list `a`, an Int; leaves by `exit` for a view of another collection.
    list_size,
    /// A host function's body called straight (`intrinsics.zig`): `aux` its entry, `ptr`
    /// the module, its `kind` arguments `a`, `b` and `c` in turn; a pair, or by `exit`
    /// where the body does not take its arguments, having done nothing.
    host_call,
};

pub const Node = struct {
    op: Op,
    repr: Repr,
    /// A word's tag, or the tag a check answers.
    tag: Tag = .Unit,
    a: Id = no_id,
    b: Id = no_id,
    c: Id = no_id,
    aux: u64 = 0,
    block: u32,
    /// Where a check leaves when it fails.
    exit: u32 = no_exit,
    /// A parameter found to be another value (`tryRemoveTrivial`): read it through `resolve`.
    forward: Id = no_id,
    /// A parameter's variable.
    variable: u32 = 0,
    /// A new value's template bytes, and a new primitive array's kind or a host call's
    /// arguments.
    len: u32 = 0,
    kind: u8 = 0,
    /// A host call's module.
    ptr: u64 = 0,
};

pub const Term = union(enum) {
    /// Not yet read.
    open,
    jump: u32,
    branch: struct { cond: Id, t: u32, f: u32 },
    /// Leaves the loop by exit `n`.
    leave: u32,
};

pub const Block = struct {
    nodes: std.ArrayList(Id) = .empty,
    preds: std.ArrayList(u32) = .empty,
    term: Term = .open,
    /// Every predecessor is known: a read no longer needs a parameter it fills later.
    sealed: bool = false,
    /// Parameters taken before the block was sealed, to fill when it is.
    incomplete: std.ArrayList(Id) = .empty,
};

/// A root register and the value the frame must hold for it at an exit.
pub const Slot = struct { reg: u32, v: Id };

pub const Exit = struct {
    /// The root op the code leaves to, and its block.
    pc: u32,
    blk: u32,
    /// The root registers the loop changed on the way here, with their values.
    slots: []const Slot,
    /// Where the op's block finds a span that differs by path, the span the frame must
    /// hold: an Int naming one of `Graph.spans`, 0 for the one it holds already.
    span: Id = no_id,
    /// Whether leaving here goes on with the loop in the baseline's code, which the loop's
    /// bounce budget counts: not its end, its return, or its back edge's guard.
    bounce: bool = false,

    /// Each value the exit reads, in turn.
    pub fn reads(x: *const Exit) Reads {
        return .{ .x = x };
    }
};

pub const Reads = struct {
    x: *const Exit,
    i: usize = 0,

    pub fn next(r: *Reads) ?Id {
        defer r.i += 1;
        if (r.i < r.x.slots.len) return r.x.slots[r.i].v;
        if (r.i == r.x.slots.len and r.x.span != no_id) return r.x.span;
        return null;
    }
};

pub const Graph = struct {
    a: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    blocks: std.ArrayList(Block) = .empty,
    exits: std.ArrayList(Exit) = .empty,
    /// The spans exits store, named by their index; index 0 is none (the frame's own).
    spans: std.ArrayList(?ir.Span) = .empty,
    /// A parameter's inputs, by the parameter's id.
    phi_args: std.AutoHashMapUnmanaged(Id, []Id) = .empty,
    /// The value a block last wrote to a variable: `(block << 32) | variable`.
    defs: std.AutoHashMapUnmanaged(u64, Id) = .empty,
    /// The value of a root register where the loop is entered, made on its first read.
    entries: std.AutoHashMapUnmanaged(u32, Id) = .empty,
    /// The block the loop is entered through, whose reads are the entry values.
    entry_block: u32 = 0,
    /// Whether a call's callee is read in place, and the level of the deepest such call's
    /// op (the root's are level 0): the entry checks the thread's eval depth leaves room.
    calls_in_place: bool = false,
    max_level: u32 = 0,

    pub fn init(a: std.mem.Allocator) Graph {
        return .{ .a = a };
    }

    pub fn newBlock(g: *Graph) !u32 {
        const id: u32 = @intCast(g.blocks.items.len);
        try g.blocks.append(g.a, .{});
        return id;
    }

    pub fn node(g: *const Graph, id: Id) *Node {
        return &g.nodes.items[id];
    }

    /// Appends `n` to block `b`.
    pub fn add(g: *Graph, b: u32, n: Node) !Id {
        var x = n;
        x.block = b;
        const id: Id = @intCast(g.nodes.items.len);
        try g.nodes.append(g.a, x);
        try g.blocks.items[b].nodes.append(g.a, id);
        return id;
    }

    /// A constant of tag `tag` with payload bits `bits`, in block `b`.
    pub fn konst(g: *Graph, b: u32, tag: Tag, bits: u64) !Id {
        return g.add(b, .{ .op = .konst, .repr = .word, .tag = tag, .aux = bits, .block = b });
    }

    /// Edge `from` -> `to`.
    pub fn addEdge(g: *Graph, from: u32, to: u32) !void {
        try g.blocks.items[to].preds.append(g.a, from);
    }

    /// `id`, or the value a parameter it names was found to be.
    pub fn resolve(g: *const Graph, id: Id) Id {
        var x = id;
        while (x != no_id and g.nodes.items[x].forward != no_id) x = g.nodes.items[x].forward;
        return x;
    }

    // ------------------------------------------------------------ variables --

    pub fn writeVar(g: *Graph, variable: u32, b: u32, v: Id) !void {
        try g.defs.put(g.a, key(b, variable), v);
    }

    fn key(b: u32, variable: u32) u64 {
        return (@as(u64, b) << 32) | variable;
    }

    /// The value of `variable` in block `b`. `entryOf` answers a root register's
    /// value where the loop is entered; a variable read in the entry block that is not
    /// a root register has none there, and the read fails.
    pub fn readVar(g: *Graph, variable: u32, b: u32, entryOf: anytype) error{ OutOfMemory, Unsupported }!Id {
        if (g.defs.get(key(b, variable))) |v| return g.resolve(v);
        return g.readVarRecursive(variable, b, entryOf);
    }

    fn readVarRecursive(g: *Graph, variable: u32, b: u32, entryOf: anytype) error{ OutOfMemory, Unsupported }!Id {
        var v: Id = undefined;
        const blk = &g.blocks.items[b];
        if (b == g.entry_block) {
            v = try entryOf.value(g, variable);
        } else if (!blk.sealed) {
            v = try g.newPhi(b, variable);
            try g.blocks.items[b].incomplete.append(g.a, v);
        } else if (blk.preds.items.len == 1) {
            v = try g.readVar(variable, blk.preds.items[0], entryOf);
        } else {
            const p = try g.newPhi(b, variable);
            try g.writeVar(variable, b, p);
            v = try g.addPhiOperands(p, entryOf);
        }
        try g.writeVar(variable, b, v);
        return v;
    }

    fn newPhi(g: *Graph, b: u32, variable: u32) !Id {
        // A parameter comes first in its block: nodes are listed in order, parameters
        // at the front.
        const id: Id = @intCast(g.nodes.items.len);
        try g.nodes.append(g.a, .{ .op = .phi, .repr = .none, .block = b, .variable = variable });
        try g.blocks.items[b].nodes.insert(g.a, 0, id);
        return id;
    }

    fn addPhiOperands(g: *Graph, p: Id, entryOf: anytype) error{ OutOfMemory, Unsupported }!Id {
        const b = g.nodes.items[p].block;
        const variable = g.nodes.items[p].variable;
        const preds = g.blocks.items[b].preds.items;
        const args = try g.a.alloc(Id, preds.len);
        for (preds, args) |pr, *x| x.* = try g.readVar(variable, pr, entryOf);
        try g.phi_args.put(g.a, p, args);
        return g.tryRemoveTrivial(p);
    }

    /// A parameter all of whose inputs are one value (or itself) is that value.
    fn tryRemoveTrivial(g: *Graph, p: Id) Id {
        const args = g.phi_args.get(p) orelse return p;
        var same: Id = no_id;
        for (args) |raw| {
            const x = g.resolve(raw);
            if (x == same or x == p) continue;
            if (same != no_id) return p;
            same = x;
        }
        if (same == no_id) return p;
        g.nodes.items[p].forward = same;
        return same;
    }

    /// Every predecessor of `b` is known: the parameters its reads took get their inputs.
    pub fn seal(g: *Graph, b: u32, entryOf: anytype) !void {
        const pending = try g.blocks.items[b].incomplete.toOwnedSlice(g.a);
        defer g.a.free(pending);
        for (pending) |p| _ = try g.addPhiOperands(p, entryOf);
        g.blocks.items[b].sealed = true;
    }

    /// Resolves every argument through the parameters found trivial, drops those
    /// parameters from their blocks, and gives each remaining parameter its
    /// representation: a word when every input is a word of one tag, else a pair.
    pub fn finish(g: *Graph) !void {
        for (g.nodes.items) |*n| {
            n.a = g.resolve(n.a);
            n.b = g.resolve(n.b);
            n.c = g.resolve(n.c);
        }
        var it = g.phi_args.iterator();
        while (it.next()) |e| for (e.value_ptr.*) |*x| {
            x.* = g.resolve(x.*);
        };
        for (g.blocks.items) |*blk| {
            if (blk.term == .branch) blk.term.branch.cond = g.resolve(blk.term.branch.cond);
            var w: usize = 0;
            for (blk.nodes.items) |id| {
                if (g.nodes.items[id].forward != no_id) continue;
                blk.nodes.items[w] = id;
                w += 1;
            }
            blk.nodes.shrinkRetainingCapacity(w);
        }
        for (g.exits.items) |*x| {
            const slots = @constCast(x.slots);
            for (slots) |*s| s.v = g.resolve(s.v);
            x.span = g.resolve(x.span);
        }
        g.reprs();
        // A parameter whose inputs but the loop's entry values are words of one tag takes
        // those entry values as words of the tag too, checked where the loop is entered:
        // a variable the loop keeps as one kind was most likely that kind before it.
        var again = true;
        while (again) {
            again = false;
            var pit = g.phi_args.iterator();
            while (pit.next()) |e| {
                const p = g.nodes.items[e.key_ptr.*];
                if (p.forward != no_id or p.repr != .pair) continue;
                var tag: ?Tag = null;
                var entries: usize = 0;
                const typed = for (e.value_ptr.*) |x| {
                    if (x == e.key_ptr.*) continue;
                    const n = g.nodes.items[x];
                    if (n.op == .entry and n.repr == .pair) {
                        entries += 1;
                        continue;
                    }
                    if (n.repr != .word) break false;
                    if (tag != null and tag.? != n.tag) break false;
                    tag = n.tag;
                } else true;
                if (!typed or entries == 0 or tag == null) continue;
                switch (tag.?) {
                    .Int, .Long, .Double, .Bool => {},
                    else => continue,
                }
                for (e.value_ptr.*) |x| {
                    const n = &g.nodes.items[x];
                    if (n.op != .entry or n.repr != .pair) continue;
                    n.repr = .word;
                    n.tag = tag.?;
                    n.variable = @intFromEnum(tag.?);
                }
                again = true;
            }
            if (again) g.reprs();
        }
    }

    /// Each parameter's representation from its inputs', to a fixed point around loops:
    /// a word when every input is a word of one tag, else a pair.
    fn reprs(g: *Graph) void {
        var changed = true;
        while (changed) {
            changed = false;
            var pit = g.phi_args.iterator();
            while (pit.next()) |e| {
                const p = &g.nodes.items[e.key_ptr.*];
                if (p.forward != no_id) continue;
                var repr: Repr = .none;
                var tag: Tag = .Unit;
                for (e.value_ptr.*) |x| {
                    if (x == e.key_ptr.*) continue;
                    const n = g.nodes.items[x];
                    if (n.repr == .none) continue;
                    if (repr == .none) {
                        repr = n.repr;
                        tag = n.tag;
                    } else if (repr != n.repr or (repr == .word and tag != n.tag)) {
                        repr = .pair;
                    }
                }
                if (repr != p.repr or tag != p.tag) {
                    p.repr = repr;
                    p.tag = tag;
                    changed = true;
                }
            }
        }
    }

    // --------------------------------------------------------------- order --

    /// The blocks block `b` goes on to.
    pub fn successors(g: *const Graph, b: u32, out: *[2]u32) []const u32 {
        return switch (g.blocks.items[b].term) {
            .jump => |t| blk: {
                out[0] = t;
                break :blk out[0..1];
            },
            .branch => |br| blk: {
                out.* = .{ br.t, br.f };
                break :blk out[0..2];
            },
            else => out[0..0],
        };
    }

    /// The blocks from the entry in reverse postorder, the edges back to a block already on
    /// the path left out.
    pub fn reversePostorder(g: *const Graph, a: std.mem.Allocator) ![]u32 {
        const nb = g.blocks.items.len;
        const state = try a.alloc(u8, nb);
        @memset(state, 0);
        var post: std.ArrayList(u32) = .empty;
        var stack: std.ArrayList(struct { b: u32, next: usize }) = .empty;
        try stack.append(a, .{ .b = g.entry_block, .next = 0 });
        state[g.entry_block] = 1;
        while (stack.items.len != 0) {
            const top = &stack.items[stack.items.len - 1];
            var buf: [2]u32 = undefined;
            const succ = g.successors(top.b, &buf);
            if (top.next == succ.len) {
                state[top.b] = 2;
                try post.append(a, top.b);
                _ = stack.pop();
                continue;
            }
            const t = succ[top.next];
            top.next += 1;
            if (state[t] != 0) continue;
            state[t] = 1;
            try stack.append(a, .{ .b = t, .next = 0 });
        }
        std.mem.reverse(u32, post.items);
        return post.items;
    }

    /// Each block's immediate dominator over `order` (a reverse postorder from the entry),
    /// as Cooper, Harvey and Kennedy iterate it; the entry's is itself, and `no_exit` is a
    /// block the entry does not reach.
    pub fn dominators(g: *const Graph, a: std.mem.Allocator, order: []const u32) ![]u32 {
        const nb = g.blocks.items.len;
        const idom = try a.alloc(u32, nb);
        @memset(idom, no_exit);
        const rank = try a.alloc(u32, nb);
        @memset(rank, no_exit);
        for (order, 0..) |b, i| rank[b] = @intCast(i);
        idom[g.entry_block] = g.entry_block;
        var changed = true;
        while (changed) {
            changed = false;
            for (order[1..]) |b| {
                var new: u32 = no_exit;
                for (g.blocks.items[b].preds.items) |p| {
                    if (idom[p] == no_exit) continue;
                    if (new == no_exit) {
                        new = p;
                        continue;
                    }
                    var x = p;
                    var y = new;
                    while (x != y) {
                        while (rank[x] > rank[y]) x = idom[x];
                        while (rank[y] > rank[x]) y = idom[y];
                    }
                    new = x;
                }
                if (new != idom[b]) {
                    idom[b] = new;
                    changed = true;
                }
            }
        }
        return idom;
    }

    // ------------------------------------------------------------ printing --

    pub fn dump(g: *const Graph, w: *std.Io.Writer) !void {
        for (g.blocks.items, 0..) |blk, bi| {
            try w.print("  B{d}", .{bi});
            if (blk.preds.items.len != 0) {
                try w.print(" <-", .{});
                for (blk.preds.items) |p| try w.print(" B{d}", .{p});
            }
            try w.print(":\n", .{});
            for (blk.nodes.items) |id| try g.dumpNode(w, id);
            switch (blk.term) {
                .open => try w.print("    (open)\n", .{}),
                .jump => |t| try w.print("    jump B{d}\n", .{t}),
                .branch => |br| try w.print("    branch v{d} ? B{d} : B{d}\n", .{ br.cond, br.t, br.f }),
                .leave => |x| try g.dumpExit(w, "leave", x),
            }
        }
    }

    fn dumpNode(g: *const Graph, w: *std.Io.Writer, id: Id) !void {
        const n = g.nodes.items[id];
        try w.print("    v{d} = {s}", .{ id, @tagName(n.op) });
        switch (n.repr) {
            .word => try w.print(":{s}", .{@tagName(n.tag)}),
            .pair => try w.print(":pair", .{}),
            .none => {},
        }
        switch (n.op) {
            .entry => try w.print(" r{d}", .{n.aux}),
            .konst => try w.print(" {x}", .{n.aux}),
            .arith, .cmp => try w.print(" {s}", .{@tagName(@as(ir.BinOp, @enumFromInt(n.aux & 0xff)))}),
            .get_field, .set_field, .init_field, .check_slots, .check_class, .class_is => try w.print(" #{d}", .{n.aux & 0xffff_ffff}),
            .new_inst => try w.print(" {d}B", .{n.len}),
            .new_prim => try w.print(" kind{d}", .{n.kind}),
            .check_tag => try w.print(" {s}", .{@tagName(n.tag)}),
            .phi => {
                try w.print(" r{d} [", .{n.variable});
                if (g.phi_args.get(id)) |args| for (args, 0..) |x, i| {
                    if (i != 0) try w.print(",", .{});
                    try w.print(" v{d}", .{x});
                };
                try w.print(" ]", .{});
            },
            else => {},
        }
        inline for (.{ n.a, n.b, n.c }) |x| if (x != no_id) try w.print(" v{d}", .{x});
        if (n.exit != no_exit) try g.dumpExit(w, " ->", n.exit) else try w.print("\n", .{});
    }

    fn dumpExit(g: *const Graph, w: *std.Io.Writer, what: []const u8, x: u32) !void {
        const e = g.exits.items[x];
        try w.print("{s} @{d}{{", .{ what, e.pc });
        for (e.slots, 0..) |s, i| {
            if (i != 0) try w.print(",", .{});
            try w.print(" r{d}=v{d}", .{ s.reg, s.v });
        }
        try w.print(" }}\n", .{});
    }
};

const testing = std.testing;

/// Root registers' entry values for the tests: a pair for every register.
const TestEntries = struct {
    pub fn value(_: TestEntries, g: *Graph, variable: u32) !Id {
        if (g.entries.get(variable)) |v| return v;
        const v = try g.add(g.entry_block, .{ .op = .entry, .repr = .pair, .aux = variable, .block = g.entry_block });
        try g.entries.put(g.a, variable, v);
        return v;
    }
};

test "a variable a loop writes takes a parameter at its head, its entry value the kind the loop keeps it, and one it only reads is its entry value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var g = Graph.init(arena.allocator());
    const e = TestEntries{};
    // B0 (entry) -> B1 (head) -> B2 (body) -> B1; i (r1) counts, n (r0) is read.
    const b0 = try g.newBlock();
    const b1 = try g.newBlock();
    const b2 = try g.newBlock();
    g.entry_block = b0;
    try g.seal(b0, e);
    try g.addEdge(b0, b1);
    g.blocks.items[b0].term = .{ .jump = b1 };
    const n1 = try g.readVar(0, b1, e);
    const i_head = try g.readVar(1, b1, e);
    try testing.expectEqual(Op.phi, g.node(i_head).op);
    try g.addEdge(b1, b2);
    try g.seal(b2, e);
    const one = try g.konst(b2, .Int, 1);
    const i_body = try g.readVar(1, b2, e);
    const inc = try g.add(b2, .{ .op = .arith, .repr = .word, .tag = .Int, .a = i_body, .b = one, .aux = @intFromEnum(ir.BinOp.Add), .block = b2 });
    try g.writeVar(1, b2, inc);
    _ = try g.readVar(0, b2, e);
    try g.addEdge(b2, b1);
    try g.seal(b1, e);
    try g.finish();
    // n was never written: its reads are the entry value, not a parameter.
    try testing.expectEqual(Op.entry, g.node(g.resolve(n1)).op);
    // i's parameter takes its entry value and the increment.
    const p = g.resolve(i_head);
    try testing.expectEqual(Op.phi, g.node(p).op);
    const args = g.phi_args.get(p).?;
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqual(Op.entry, g.node(args[0]).op);
    try testing.expectEqual(inc, args[1]);
    // An entry pair and an Int word meet as an Int word: the entry value is taken as an
    // Int, which the loop's entry checks.
    try testing.expectEqual(Repr.word, g.node(p).repr);
    try testing.expectEqual(Tag.Int, g.node(p).tag);
    try testing.expectEqual(Repr.word, g.node(args[0]).repr);
    try testing.expectEqual(Tag.Int, g.node(args[0]).tag);
}
