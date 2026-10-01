//! A loop's ops read into the optimizing tier's graph (`graph.zig`): each
//! stream block of the loop becomes a block of the graph, each root register
//! a variable, each op the values it computes and the checks it cannot leave
//! to the kinds. Branches out of the loop leave by exits to their targets; a
//! failed check leaves to its op; the back edge's guard leaves to the op that
//! ends the iteration. An op the tier does not take refuses the loop
//! (`error.Unsupported`), which the baseline then runs alone.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const kinds_mod = @import("../kinds.zig");
const intrinsics = @import("../intrinsics.zig");
const graph = @import("graph.zig");

const bc = ir.bc;
const Op = bc.Op;
const Graph = graph.Graph;
const Id = graph.Id;
const Tag = graph.Tag;
const Kinds = kinds_mod.Kinds;

pub const Error = error{ OutOfMemory, Unsupported };

/// A loop of the root function: its head block and the blocks in it.
pub const Loop = struct {
    head: u32,
    body: []const bool,
};

/// What the baseline decides for ops the tier compiles as it does: how a `new` makes its
/// value in place, and the host function a static call runs as an intrinsic.
pub const Hooks = struct {
    /// The template a `new` at `pc` of `fs` copies and the field stores its constructor
    /// makes, when the op compiles in place.
    new_plan: *const fn (fs: *const bc.FuncStreams, pc: usize) ?NewPlan,
    /// The kind and template of a new primitive array of class `class`, when a `new` of it
    /// compiles in place.
    prim_new: *const fn (module: *const ir.Module, class: u32) ?PrimNew,
    /// The intrinsic a static call of function `fid` runs as, or none.
    static_intrinsic: *const fn (module: *const ir.Module, fid: u32) intrinsics.Intrinsic,
    /// The tag of every value of class `class` and of no other, or none.
    class_tag: *const fn (module: *const ir.Module, class: u32) ?Tag,
    /// The intrinsic host function `nid` runs as, or none.
    native_intrinsic: *const fn (module: *const ir.Module, nid: ir.NativeId) intrinsics.Intrinsic,
    /// The entry compiled code calls a called intrinsic's body at (`Intrinsic.called`).
    intrinsic_entry: *const fn (k: intrinsics.Intrinsic) usize,
    /// The tag of the values a call site keeps host functions under class `class` for,
    /// when it is the class of every value with the tag (a list's, a map's, a builder's).
    host_tag: *const fn (module: *const ir.Module, class: u32) ?Tag,
};

pub const NewPlan = struct { stores: []const bc.FieldStore, image: []const u8 };
pub const PrimNew = struct { kind: runtime.PrimitiveArrayKind, image: []const u8 };

pub const Env = struct {
    fs: *const bc.FuncStreams,
    kinds: *const Kinds,
    module: ?*const ir.Module,
    loop: Loop,
    hooks: ?*const Hooks = null,
    /// Whether a list's element is read without its lock, between readings of its write
    /// sequence (`runtime.lockfreeReads`): the tier reads lists only so.
    list_reads: bool = false,
    /// Root ops the loop leaves at, to the baseline's code: ops the tier does not take,
    /// which a loop may run seldom (`buildLeaving`).
    cold: []const u32 = &.{},
};

/// Why the last loop the builder refused was refused, for `KLIO_JIT_OPT_DUMP`.
pub var last_refusal: []const u8 = "";
/// The root op the last refusal was at, when an op it did not take was the reason (a
/// callee's op is its call's).
pub var last_refused_pc: ?u32 = null;
/// The ops the last loop built leaves at to the baseline's code (`buildLeaving`), and why
/// the tier did not take each.
pub var last_cold: []const u32 = &.{};
pub var last_cold_why: []const []const u8 = &.{};

/// The variable holding the span the frame would hold: an Int naming one of the graph's
/// spans, 0 for the one the frame held where the loop was entered.
const span_var: u32 = 0xffff_ff00;
/// The first variable of the callees read in place; the root's registers come before.
const callee_base: u32 = 0x0100_0000;
/// The deepest a call is read in place, the largest callee, and the callees' words in all.
const max_depth = 4;
const max_callee_words = 400;
const max_inlined_words = 2000;

/// A function whose ops are read: the root, or a callee read in place of its call.
const Level = struct {
    fs: *const bc.FuncStreams,
    kinds: *const Kinds,
    /// Its registers' first variable.
    base: u32,
    /// Per stream block, its graph block.
    block_of: []u32,
    /// A callee's: the caller's register its result goes to, the caller's first variable,
    /// the graph block its returns go on to, and its parameters' values.
    dst: u32 = 0,
    caller_base: u32 = 0,
    cont: u32 = 0,
    params: []const Id = &.{},
    /// The returns read so far.
    rets: u32 = 0,
    /// A lambda's: the closure its call ran, whose captures its body reads.
    closure: Id = graph.no_id,
};

const Builder = struct {
    g: Graph,
    env: Env,
    /// The root, then each callee being read in place, the innermost last.
    levels: std.ArrayList(Level) = .empty,
    /// The next callee's first variable.
    next_base: u32 = callee_base,
    inlined_words: u32 = 0,
    /// The root's call op a check inside a callee leaves to, and its block; and whether a
    /// callee has done what another can see since it (a check after that is refused).
    call_pc: usize = 0,
    call_blk: u32 = 0,
    effect: bool = false,
    /// Per stream block of the loop, its graph block.
    block_of: []u32,
    /// The root registers some op of the loop writes: what an exit may have to write back.
    written: []bool,
    /// The root's register liveness, at its blocks' edges and where a catch starts.
    live: ir.regs.Live,
    /// The pc the loop's head is entered at.
    head_pc: usize,
    /// Scratch sets of registers, for `exitTo`.
    need: []u64,
    defd: []u64,
    /// The graph block ops are being read into.
    cur: u32 = 0,

    fn level(b: *const Builder) *Level {
        return &b.levels.items[b.levels.items.len - 1];
    }

    fn inCallee(b: *const Builder) bool {
        return b.levels.items.len > 1;
    }

    fn code(b: *const Builder, pc: usize, k: usize) u32 {
        return b.level().fs.code[pc + k];
    }

    /// Register `r`'s kind at the op at `pc` of the function being read, as its kinds show it.
    fn kindAt(b: *const Builder, pc: usize, r: u32) kinds_mod.Kind {
        return b.level().kinds.kindAt(pc, r);
    }

    /// The root register `r` where the loop is entered: a word where the kinds at the
    /// head prove its tag (the entry checks them), else a pair.
    pub fn value(b: *Builder, g: *Graph, r: u32) Error!Id {
        _ = g;
        if (b.g.entries.get(r)) |v| return v;
        if (r == span_var or r >= callee_base) {
            // The span the frame holds, or a callee's register not yet written: a callee's
            // frame fills those with `Unit`.
            const v = if (r == span_var) try b.g.konst(b.g.entry_block, .Int, 0) else try b.g.konst(b.g.entry_block, .Unit, 0);
            try b.g.entries.put(b.g.a, r, v);
            return v;
        }
        const head_pc = b.env.fs.blocks[b.env.loop.head].enter;
        const k = b.env.kinds.kindAt(head_pc, r);
        const typed = if (kinds_mod.tagOf(k)) |t| switch (t) {
            .Int, .Long, .Double, .Bool, .Instance, .Array, .IrClosure => true,
            else => false,
        } else false;
        const v = if (typed)
            try b.g.add(b.g.entry_block, .{ .op = .entry, .repr = .word, .tag = kinds_mod.tagOf(k).?, .aux = r, .block = 0, .variable = k })
        else
            try b.g.add(b.g.entry_block, .{ .op = .entry, .repr = .pair, .aux = r, .block = 0, .variable = kinds_mod.unknown });
        try b.g.entries.put(b.g.a, r, v);
        return v;
    }

    fn read(b: *Builder, r: u32) Error!Id {
        return b.g.readVar(b.level().base + r, b.cur, b);
    }

    fn write(b: *Builder, r: u32, v: Id) Error!void {
        try b.g.writeVar(b.level().base + r, b.cur, v);
    }

    fn readRoot(b: *Builder, r: u32) Error!Id {
        return b.g.readVar(r, b.cur, b);
    }

    fn add(b: *Builder, n: graph.Node) Error!Id {
        return b.g.add(b.cur, n);
    }

    /// An exit to the op at `pc` of block `blk`. The frame holds, for each root register
    /// the loop changed on the way here: those the code from the op on may read (its
    /// block's live-out, what its block reads from the op on, what a catch reads), and
    /// those the kinds show written there but not at the head, which the baseline's code
    /// after the op takes as marked.
    fn exitTo(b: *Builder, at_pc: usize, at_blk: u32) Error!u32 {
        var pc = at_pc;
        var blk = at_blk;
        if (b.inCallee()) {
            // Inside a callee the root's call runs again, whole: only while nothing the
            // callee did can be seen.
            if (b.effect) return refuse("a check after a callee's effect");
            pc = b.call_pc;
            blk = b.call_blk;
        }
        // A block whose entry span differs by path finds it in the frame, where the edges
        // into it leave theirs: the graph follows it as a variable (`span_var`).
        const es = b.env.fs.entry_spans;
        const span: Id = if (blk < es.len and es[blk] == .dyn) try b.readRoot(span_var) else graph.no_id;
        try b.liveAt(pc, blk);
        var slots: std.ArrayList(graph.Slot) = .empty;
        for (b.written, 0..) |w, r| {
            if (!w) continue;
            const reg: u32 = @intCast(r);
            const live = (b.need[r >> 6] >> @as(u6, @truncate(r))) & 1 != 0;
            const marked = b.env.kinds.written(pc, reg) and !b.env.kinds.written(b.head_pc, reg);
            if (!live and !marked) continue;
            const v = try b.readRoot(reg);
            // A register the loop has not changed on this path is in the frame as it was.
            if (b.g.nodes.items[v].op == .entry) continue;
            // One nothing reads from here on needs only to hold a value: its own would keep
            // alive what nothing else needs.
            const held = if (live) v else try b.g.konst(b.cur, .Unit, 0);
            try slots.append(b.g.a, .{ .reg = @intCast(r), .v = held });
        }
        const id: u32 = @intCast(b.g.exits.items.len);
        const inside = blk < b.env.loop.body.len and b.env.loop.body[blk];
        try b.g.exits.append(b.g.a, .{ .pc = @intCast(pc), .blk = blk, .slots = try slots.toOwnedSlice(b.g.a), .span = span, .bounce = inside });
        return id;
    }

    /// The span the branch or jump whose span words are at `at` leaves in the frame, as the
    /// interpreter's `leaveSpan` does.
    fn leaveSpan(b: *Builder, at: usize) Error!void {
        // A callee's spans are its level's; a check in it leaves to its call.
        if (b.inCallee()) return;
        const c = b.env.fs.code;
        if (c[at] == bc.NO_SPAN) return;
        const sp = bc.wordsSpan(c, at);
        if (b.g.spans.items.len == 0) try b.g.spans.append(b.g.a, null);
        const id: u32 = @intCast(b.g.spans.items.len);
        try b.g.spans.append(b.g.a, sp);
        try b.g.writeVar(span_var, b.cur, try b.g.konst(b.cur, .Int, id));
    }

    /// `need` = the root registers the code from the op at `pc` (of block `blk`) may read:
    /// those the block's instructions from the op's on read before they write them, and those
    /// live out of the block that it does not write again, and what a catch reads.
    fn liveAt(b: *Builder, pc: usize, blk: u32) Error!void {
        @memset(b.need, 0);
        @memset(b.defd, 0);
        const fb = &b.env.fs.func.blocks[blk];
        const idx_pc = b.env.fs.blocks[blk].idx_pc;
        const Walk = struct {
            need: []u64,
            defd: []u64,
            fn f(c: @This(), r: ir.Reg, is_def: bool) void {
                const i = r.int();
                if ((i >> 6) >= c.need.len) return;
                const bit = @as(u64, 1) << @as(u6, @truncate(i));
                if (is_def) {
                    c.defd[i >> 6] |= bit;
                } else if (c.defd[i >> 6] & bit == 0) c.need[i >> 6] |= bit;
            }
        };
        const w: Walk = .{ .need = b.need, .defd = b.defd };
        for (fb.insts, 0..) |*inst, i| {
            // The instructions from the op on, each reading its operands before it writes its
            // result: an exit's op starts its instruction's code, or is the block's branch
            // after them all.
            if (i >= idx_pc.len or idx_pc[i] < pc) continue;
            ir.visitInstRegs(inst, w, readsOnly(Walk));
            ir.visitInstRegs(inst, w, writesOnly(Walk));
        }
        ir.visitTerminatorRegs(&fb.terminator, w, Walk.f);
        for (b.need, b.live.liveOut(blk), b.defd, b.live.handled) |*x, o, d, h| x.* |= (o & ~d) | h;
    }

    fn readsOnly(comptime W: type) fn (W, ir.Reg, bool) void {
        return struct {
            fn f(c: W, r: ir.Reg, is_def: bool) void {
                if (!is_def) W.f(c, r, false);
            }
        }.f;
    }

    fn writesOnly(comptime W: type) fn (W, ir.Reg, bool) void {
        return struct {
            fn f(c: W, r: ir.Reg, is_def: bool) void {
                if (is_def) W.f(c, r, true);
            }
        }.f;
    }

    /// Register `r` at the op at `pc` as a word of tag `t`: no check where the kinds prove
    /// it (the value unboxed if it is a pair), else a check that leaves to the op.
    fn word(b: *Builder, r: u32, t: Tag, pc: usize, blk: u32) Error!Id {
        const v = try b.read(r);
        const n = b.g.nodes.items[v];
        if (n.repr == .word and n.tag == t) return v;
        if (kinds_mod.tagOf(b.kindAt(pc, r)) == t) {
            if (n.repr == .word) return v;
            return b.add(.{ .op = .unbox, .repr = .word, .tag = t, .a = v, .block = 0 });
        }
        if (n.repr == .word) {
            // A word of another tag here would leave every time.
            last_refusal = "a word of another tag where a check is needed";
            return error.Unsupported;
        }
        return b.add(.{ .op = .check_tag, .repr = .word, .tag = t, .a = v, .block = 0, .exit = try b.exitTo(pc, blk) });
    }

    /// The tag both operands of an arithmetic op or compare at `pc` hold, as the kinds
    /// show them or, where they do not, as a word the graph already holds for one shows it;
    /// null where the two differ, and the op is refused.
    fn pairTag(b: *Builder, pc: usize, l: u32, r: u32) Error!?Tag {
        const lk = kinds_mod.tagOf(b.kindAt(pc, l)) orelse try b.wordTag(l);
        const rk = kinds_mod.tagOf(b.kindAt(pc, r)) orelse try b.wordTag(r);
        if (lk) |t| {
            if (rk != null and rk.? != t) return null;
            return t;
        }
        // Neither known: an Int, checked, as most are.
        return rk orelse .Int;
    }

    /// The tag of register `r`'s value where the graph holds it as a word.
    fn wordTag(b: *Builder, r: u32) Error!?Tag {
        const n = b.g.nodes.items[try b.read(r)];
        return if (n.repr == .word) n.tag else null;
    }

    fn arithOp(bop: ir.BinOp, t: Tag) bool {
        return switch (t) {
            .Int, .Long => switch (bop) {
                .Add, .Sub, .Mul, .And, .Or, .Xor, .Shl, .Shr, .UShr, .Div, .Mod => true,
                else => false,
            },
            .Double => switch (bop) {
                .Add, .Sub, .Mul, .Div => true,
                else => false,
            },
            else => false,
        };
    }

    fn cmpOp(bop: ir.BinOp) bool {
        return switch (bop) {
            .Eq, .NotEq, .Less, .LessEq, .Greater, .GreaterEq => true,
            else => false,
        };
    }

    /// `dst = l op r` at `pc`, or its compare.
    fn binary(b: *Builder, pc: usize, blk: u32, bop: ir.BinOp, dst: u32, l: u32, r: u32) Error!void {
        const t = (try b.pairTag(pc, l, r)) orelse {
            last_refusal = "an arithmetic op the kinds know neither operand of";
            return error.Unsupported;
        };
        if (cmpOp(bop)) {
            if (t != .Int and t != .Long and t != .Double) return refuse("a compare of another kind");
            const lv = try b.word(l, t, pc, blk);
            const rv = try b.word(r, t, pc, blk);
            try b.write(dst, try b.add(.{ .op = .cmp, .repr = .word, .tag = .Bool, .a = lv, .b = rv, .aux = @intFromEnum(bop) | (@as(u64, @intFromEnum(t)) << 8), .block = 0 }));
            return;
        }
        if (!arithOp(bop, t)) return refuse("an arithmetic op the tier does not compute");
        // A shift's count is an Int, whatever the value shifted.
        const rt: Tag = if (bop == .Shl or bop == .Shr or bop == .UShr) .Int else t;
        const lv = try b.word(l, t, pc, blk);
        const rv = try b.word(r, rt, pc, blk);
        if ((bop == .Div or bop == .Mod) and t != .Double) {
            // A zero divisor throws: the op's.
            const k = b.g.nodes.items[rv];
            if (k.op != .konst or k.aux == 0) _ = try b.add(.{ .op = .check_nonzero, .repr = .none, .tag = t, .a = rv, .block = 0, .exit = try b.exitTo(pc, blk) });
        }
        try b.write(dst, try b.add(.{ .op = .arith, .repr = .word, .tag = t, .a = lv, .b = rv, .aux = @intFromEnum(bop), .block = 0 }));
    }

    /// Whether register `r` is null, for a compare `bop` of it with null: a Bool, constant
    /// for a word (null only as the null constant).
    fn nullTest(b: *Builder, r: u32, bop: ir.BinOp) Error!Id {
        const negate = switch (bop) {
            .Eq, .BoxedEq, .IdentEq => false,
            .NotEq, .BoxedNotEq, .IdentNeq => true,
            else => return refuse("an order compare with null"),
        };
        const v = try b.read(r);
        const n = b.g.nodes.items[v];
        if (n.repr == .word) return b.g.konst(b.cur, .Bool, @intFromBool((n.tag == .Null) != negate));
        return b.add(.{ .op = .is_null, .repr = .word, .tag = .Bool, .a = v, .aux = @intFromBool(negate), .block = 0 });
    }

    /// The constant a `bin_k` or `cmp_br_k` op at `pc` carries, as a word.
    fn kConst(b: *Builder, pc: usize) Error!struct { Id, Tag } {
        const kt: bc.KType = @enumFromInt((b.code(pc, 1) >> 8) & 0xff);
        const bits = @as(u64, b.code(pc, 5)) << 32 | b.code(pc, 4);
        return switch (kt) {
            .int => .{ try b.g.konst(b.cur, .Int, bits & 0xffff_ffff), .Int },
            .long => .{ try b.g.konst(b.cur, .Long, bits), .Long },
            .double => .{ try b.g.konst(b.cur, .Double, bits), .Double },
            .null => .{ try b.g.konst(b.cur, .Null, 0), .Null },
            else => refuse("a constant operand of another kind"),
        };
    }

    /// A branch on `cond` to the stream blocks `t` and `f` (entering at `tpc` and `fpc`).
    /// On each edge the register `cond_reg` the branch's compare wrote holds the Bool the
    /// edge was taken on, a constant, so nothing but the branch reads the compare.
    fn branch(b: *Builder, pc: usize, blk: u32, cond: Id, t: u32, tpc: u32, f: u32, fpc: u32, cond_reg: ?u32) Error!void {
        const from = b.cur;
        const tb = try b.edgeToWith(pc, blk, t, tpc, cond_reg, true);
        b.cur = from;
        const fb = try b.edgeToWith(pc, blk, f, fpc, cond_reg, false);
        b.g.blocks.items[from].term = .{ .branch = .{ .cond = cond, .t = tb, .f = fb } };
    }

    /// The graph block an edge from the current block to stream block `t` (entering at
    /// `tpc`) goes to: `t`'s block inside the loop, through the back edge's guard to the
    /// head; an exit's block out of it.
    fn edgeTo(b: *Builder, pc: usize, blk: u32, t: u32, tpc: u32) Error!u32 {
        return b.edgeToWith(pc, blk, t, tpc, null, false);
    }

    fn edgeToWith(b: *Builder, pc: usize, blk: u32, t: u32, tpc: u32, cond_reg: ?u32, taken: bool) Error!u32 {
        const from = b.cur;
        const e = try b.g.newBlock();
        try b.g.addEdge(from, e);
        try b.g.seal(e, b);
        b.cur = e;
        if (cond_reg) |r| try b.write(r, try b.g.konst(e, .Bool, @intFromBool(taken)));
        if (b.inCallee()) {
            // Within a callee, whose blocks are all read and none loops.
            const target = b.level().block_of[t];
            if (target == graph.no_exit) return refuse("an edge to a callee's block it does not reach");
            try b.g.addEdge(e, target);
            b.g.blocks.items[e].term = .{ .jump = target };
            return e;
        }
        if (t >= b.env.loop.body.len or !b.env.loop.body[t]) {
            b.g.blocks.items[e].term = .{ .leave = try b.exitTo(tpc, t) };
            return e;
        }
        if (t == b.env.loop.head) {
            // The back edge: its guard leaves to the op ending the iteration, which the
            // baseline runs again, guard and all.
            const x = try b.exitTo(pc, blk);
            b.g.exits.items[x].bounce = false;
            _ = try b.add(.{ .op = .check_poll, .repr = .none, .block = 0, .exit = x });
        }
        const target = b.level().block_of[t];
        try b.g.addEdge(e, target);
        b.g.blocks.items[e].term = .{ .jump = target };
        return e;
    }

    fn jumpTo(b: *Builder, pc: usize, blk: u32, t: u32, tpc: u32) Error!void {
        const from = b.cur;
        const e = try b.edgeTo(pc, blk, t, tpc);
        b.g.blocks.items[from].term = .{ .jump = e };
    }

    /// Reads the ops of stream block `blk` into its graph block.
    fn readBlock(b: *Builder, blk: u32) Error!void {
        const fs = b.level().fs;
        const sb = fs.blocks[blk];
        b.cur = b.level().block_of[blk];
        var pc: usize = sb.enter;
        while (pc <= sb.end) {
            const op = fs.opAt(pc);
            if (!b.inCallee() and std.mem.indexOfScalar(u32, b.env.cold, @intCast(pc)) != null) {
                // An op the loop leaves at: the baseline runs it and the rest of the iteration.
                b.g.blocks.items[b.cur].term = .{ .leave = try b.exitTo(pc, blk) };
                return;
            }
            const done = b.readOp(op, pc, blk) catch |e| {
                if (e == error.Unsupported and last_refused_pc == null) last_refused_pc = @intCast(if (b.inCallee()) b.call_pc else pc);
                return e;
            };
            if (done) return;
            pc += bc.opLen(op, fs.code, pc);
            // A `bin_k` prefix's fronted op was read with it.
            if (bc.kOperator(op) != null and !isCmpBrK(op)) pc += bc.opLen(fs.opAt(pc), fs.code, pc);
        }
        return refuse("a block that ends without a branch");
    }

    /// Reads the op at `pc`; true when it ends its block.
    fn readOp(b: *Builder, op: Op, pc: usize, blk: u32) Error!bool {
        switch (op) {
            // Pushes the block's try frame, which the baseline's code keeps.
            .block_entry => return refuse("a try frame's push"),
            .const_int => try b.write(b.code(pc, 1), try b.g.konst(b.cur, .Int, b.code(pc, 2))),
            .const_val => {
                const v = b.level().fs.values[b.code(pc, 2)];
                const k: struct { Tag, u64 } = switch (v) {
                    .Int => |x| .{ .Int, @as(u32, @bitCast(x)) },
                    .Long => |x| .{ .Long, @bitCast(x) },
                    .Double => |x| .{ .Double, @bitCast(x) },
                    .Bool => |x| .{ .Bool, @intFromBool(x) },
                    .Null => .{ .Null, 0 },
                    .Unit => .{ .Unit, 0 },
                    else => return refuse("a constant of another kind"),
                };
                try b.write(b.code(pc, 1), try b.g.konst(b.cur, k[0], k[1]));
            },
            .move => try b.write(b.code(pc, 1), try b.read(b.code(pc, 2))),
            .add, .sub, .cmp, .bin_mul, .bin_and, .bin_or, .bin_xor, .bin_shl, .bin_shr, .bin_ushr, .bin_div, .bin_mod => {
                const bop: ir.BinOp = @enumFromInt(b.code(pc, 2) & 0xff);
                try b.binary(pc, blk, bop, b.code(pc, 3), b.code(pc, 4), b.code(pc, 5));
            },
            .bin_k_add, .bin_k_sub, .bin_k_mul, .bin_k_div, .bin_k_mod, .bin_k_and, .bin_k_or, .bin_k_xor, .bin_k_shl, .bin_k_shr, .bin_k_ushr, .bin_k_less, .bin_k_less_eq, .bin_k_greater, .bin_k_greater_eq, .bin_k_eq, .bin_k_not_eq, .bin_k_boxed_eq, .bin_k_boxed_not_eq, .bin_k_ident_eq, .bin_k_ident_neq => {
                // The prefix computes with its constant in place of the register the
                // constant's op writes, which only this op reads.
                const kv, const kt = try b.kConst(pc);
                try b.write(b.code(pc, 3), kv);
                const bop = bc.kOperator(op).?;
                const l = b.code(pc, 2);
                const dst = b.code(pc, 9);
                if (kt == .Null) {
                    try b.write(dst, try b.nullTest(l, bop));
                    return false;
                }
                if (bop == .BoxedEq or bop == .BoxedNotEq or bop == .IdentEq or bop == .IdentNeq) return refuse("an identity compare with a number");
                // A constant zero divisor throws: the op's.
                if ((bop == .Div or bop == .Mod) and kt != .Double and b.g.nodes.items[kv].aux == 0) return refuse("a division by a constant zero");
                const t = kinds_mod.tagOf(b.kindAt(pc, l)) orelse kt;
                if (t != kt) return refuse("a constant operand of another kind than its operand");
                const lv = try b.word(l, t, pc, blk);
                if (cmpOp(bop)) {
                    try b.write(dst, try b.add(.{ .op = .cmp, .repr = .word, .tag = .Bool, .a = lv, .b = kv, .aux = @intFromEnum(bop) | (@as(u64, @intFromEnum(t)) << 8), .block = 0 }));
                } else {
                    if (!arithOp(bop, t)) return refuse("an arithmetic op the tier does not compute");
                    const rv = if (bop == .Shl or bop == .Shr or bop == .UShr) try b.g.konst(b.cur, .Int, b.g.nodes.items[kv].aux & 0xffff_ffff) else kv;
                    try b.write(dst, try b.add(.{ .op = .arith, .repr = .word, .tag = t, .a = lv, .b = rv, .aux = @intFromEnum(bop), .block = 0 }));
                }
                // The fronted op is read with its prefix.
                return false;
            },
            .un_inc, .un_dec => {
                const src = b.code(pc, 4);
                const t = kinds_mod.tagOf(b.kindAt(pc, src)) orelse return refuse("an increment of an unknown kind");
                if (t != .Int and t != .Long) return refuse("an increment of another kind");
                const v = try b.word(src, t, pc, blk);
                const bits: u64 = if (op == .un_inc) 1 else @bitCast(@as(i64, -1));
                try b.write(b.code(pc, 3), try b.add(.{ .op = .step, .repr = .word, .tag = t, .a = v, .aux = bits, .block = 0 }));
            },
            .conv_long, .conv_int, .conv_double => {
                const src = b.code(pc, 4);
                // A kind the kinds do not know is the one such a conversion most often
                // takes, checked: an Int widened, a Long narrowed.
                const from = kinds_mod.tagOf(b.kindAt(pc, src)) orelse (if (op == .conv_int) Tag.Long else Tag.Int);
                if (from != .Int and from != .Long and from != .Double) return refuse("a conversion of another kind");
                const to: Tag = switch (op) {
                    .conv_long => .Long,
                    .conv_int => .Int,
                    else => .Double,
                };
                const v = try b.word(src, from, pc, blk);
                try b.write(b.code(pc, 3), if (from == to) v else try b.add(.{ .op = .conv, .repr = .word, .tag = to, .a = v, .aux = @intFromEnum(from), .block = 0 }));
            },
            .get_field => try b.getField(pc, blk),
            .array_get => {
                const av = try b.word(b.code(pc, 3), .Array, pc, blk);
                const iv = try b.word(b.code(pc, 4), .Int, pc, blk);
                try b.write(b.code(pc, 2), try b.add(.{ .op = .array_get, .repr = .pair, .a = av, .b = iv, .block = 0, .exit = try b.exitTo(pc, blk) }));
            },
            .set_field => {
                try b.setField(pc, blk);
                // A store another can see: a check after it cannot run the call again.
                if (b.inCallee()) b.effect = true;
            },
            .load_params => {
                if (!b.inCallee()) return refuse("the root's parameters loaded in its loop");
                const n = b.code(pc, 1);
                for (0..n) |k| try b.param(b.code(pc, 2 + 2 * k), b.code(pc, 3 + 2 * k));
            },
            .load_param => {
                if (!b.inCallee()) return refuse("the root's parameters loaded in its loop");
                try b.param(b.code(pc, 1), b.code(pc, 2));
            },
            .call => try b.call(pc, blk),
            .vcall => try b.vcall(pc, blk),
            .callv => try b.callv(pc, blk),
            .new => try b.newOp(pc, blk),
            .load_capture => {
                const clo = b.level().closure;
                if (clo == graph.no_id) return refuse("the root's captures");
                try b.write(b.code(pc, 1), try b.add(.{ .op = .capture, .repr = .pair, .a = clo, .aux = b.code(pc, 2), .block = 0 }));
            },
            .cast => try b.cast(pc, blk),
            .unbox_value => {
                // A value class's value held as its underlying value (no instance) is itself;
                // an instance is the op's.
                const v = try b.read(b.code(pc, 3));
                const n = b.g.nodes.items[v];
                const itself = n.repr == .word and switch (n.tag) {
                    .Int, .Long, .Double, .Bool => true,
                    else => false,
                };
                if (!itself) return refuse("unbox_value");
                try b.write(b.code(pc, 2), v);
            },
            // An instance is itself, checked; a number to box (or a null) leaves to the op.
            .box_value => try b.write(b.code(pc, 2), try b.word(b.code(pc, 3), .Instance, pc, blk)),
            .not => {
                const v = try b.word(b.code(pc, 3), .Bool, pc, blk);
                try b.write(b.code(pc, 2), try b.add(.{ .op = .arith, .repr = .word, .tag = .Bool, .a = v, .b = try b.g.konst(b.cur, .Bool, 1), .aux = @intFromEnum(ir.BinOp.Xor), .block = 0 }));
            },
            .native => {
                const hooks = b.env.hooks orelse return refuse("native");
                const module = b.env.module orelse return refuse("native");
                try b.intrinsic(hooks.native_intrinsic(module, @enumFromInt(b.code(pc, 2))), pc, blk);
            },
            .not_null => {
                const v = try b.read(b.code(pc, 3));
                const n = b.g.nodes.items[v];
                if (n.repr == .word) {
                    // A word's tag is never Null's.
                    try b.write(b.code(pc, 2), v);
                } else {
                    _ = try b.add(.{ .op = .check_not_null, .repr = .none, .a = v, .block = 0, .exit = try b.exitTo(pc, blk) });
                    try b.write(b.code(pc, 2), v);
                }
            },
            .ret => {
                if (!b.inCallee()) {
                    // The root returns: the baseline runs its return.
                    const x = try b.exitTo(pc, blk);
                    b.g.exits.items[x].bounce = false;
                    b.g.blocks.items[b.cur].term = .{ .leave = x };
                    return true;
                }
                const l = b.level();
                const v = if (b.code(pc, 1) != 0) try b.read(b.code(pc, 2)) else try b.g.konst(b.cur, .Unit, 0);
                try b.g.writeVar(l.caller_base + l.dst, b.cur, v);
                try b.g.addEdge(b.cur, l.cont);
                b.g.blocks.items[b.cur].term = .{ .jump = l.cont };
                l.rets += 1;
                return true;
            },
            .cmp_br => {
                const bop: ir.BinOp = @enumFromInt(b.code(pc, 2) & 0xff);
                try b.binary(pc, blk, bop, b.code(pc, 3), b.code(pc, 4), b.code(pc, 5));
                try b.leaveSpan(pc + 10);
                try b.branch(pc, blk, try b.read(b.code(pc, 3)), b.code(pc, 6), b.code(pc, 7), b.code(pc, 8), b.code(pc, 9), b.code(pc, 3));
                return true;
            },
            .cmp_br_k_less, .cmp_br_k_less_eq, .cmp_br_k_greater, .cmp_br_k_greater_eq, .cmp_br_k_eq, .cmp_br_k_not_eq, .cmp_br_k_boxed_eq, .cmp_br_k_boxed_not_eq, .cmp_br_k_ident_eq, .cmp_br_k_ident_neq => {
                const kv, const kt = try b.kConst(pc);
                try b.write(b.code(pc, 3), kv);
                const bop = bc.kOperator(op).?;
                const l = b.code(pc, 2);
                if (kt == .Null) {
                    const cond = try b.nullTest(l, bop);
                    try b.write(b.code(pc, 9), cond);
                    try b.leaveSpan(pc + 16);
                    try b.branch(pc, blk, cond, b.code(pc, 12), b.code(pc, 13), b.code(pc, 14), b.code(pc, 15), b.code(pc, 9));
                    return true;
                }
                if (bop == .BoxedEq or bop == .BoxedNotEq or bop == .IdentEq or bop == .IdentNeq) return refuse("an identity compare with a number");
                const t = kinds_mod.tagOf(b.kindAt(pc, l)) orelse kt;
                if (t != kt) return refuse("a constant operand of another kind than its operand");
                const lv = try b.word(l, t, pc, blk);
                const cond = try b.add(.{ .op = .cmp, .repr = .word, .tag = .Bool, .a = lv, .b = kv, .aux = @intFromEnum(bop) | (@as(u64, @intFromEnum(t)) << 8), .block = 0 });
                try b.write(b.code(pc, 9), cond);
                try b.leaveSpan(pc + 16);
                try b.branch(pc, blk, cond, b.code(pc, 12), b.code(pc, 13), b.code(pc, 14), b.code(pc, 15), b.code(pc, 9));
                return true;
            },
            .jump => {
                try b.leaveSpan(pc + 3);
                try b.jumpTo(pc, blk, b.code(pc, 1), b.code(pc, 2));
                return true;
            },
            .br => {
                const cond = try b.word(b.code(pc, 1), .Bool, pc, blk);
                try b.leaveSpan(pc + 6);
                try b.branch(pc, blk, cond, b.code(pc, 2), b.code(pc, 3), b.code(pc, 4), b.code(pc, 5), null);
                return true;
            },
            else => {
                last_refusal = @tagName(op);
                return error.Unsupported;
            },
        }
        return false;
    }

    /// The instance in register `obj` at `pc`, as a word, with more than `slot` slots and
    /// plain ones: checks where the kinds do not prove it.
    fn instance(b: *Builder, obj: u32, slot: u32, pc: usize, blk: u32) Error!Id {
        const v = try b.word(obj, .Instance, pc, blk);
        const k = b.kindAt(pc, obj);
        if (kinds_mod.factSlots(k) <= slot) {
            _ = try b.add(.{ .op = .check_slots, .repr = .none, .a = v, .aux = slot, .block = 0, .exit = try b.exitTo(pc, blk) });
        }
        if (!kinds_mod.factPlain(k)) {
            if (comptime !runtime.plain_slots) return refuse("a field of a build whose slots are never plain");
            _ = try b.add(.{ .op = .check_plain, .repr = .none, .a = v, .block = 0, .exit = try b.exitTo(pc, blk) });
        }
        return v;
    }

    /// A callee's register `r` = its parameter `p`, the value its call passed.
    fn param(b: *Builder, r: u32, p: u32) Error!void {
        const ps = b.level().params;
        if (p >= ps.len) return refuse("a parameter past the call's arguments");
        try b.write(r, ps[p]);
    }

    /// `new` at `pc`: an instance whose constructor only stores its parameters, its stores
    /// made in place; or a primitive array of a size.
    fn newOp(b: *Builder, pc: usize, blk: u32) Error!void {
        const hooks = b.env.hooks orelse return refuse("new");
        const module = b.env.module orelse return refuse("new");
        const dst = b.code(pc, 6);
        const lo = b.code(pc, 4);
        if (hooks.prim_new(module, b.code(pc, 2))) |pn| {
            if (b.code(pc, 5) != 1) return refuse("a primitive array made from other arguments than its size");
            const n = try b.word(lo, .Int, pc, blk);
            try b.write(dst, try b.add(.{ .op = .new_prim, .repr = .word, .tag = .Array, .a = n, .aux = @intFromPtr(pn.image.ptr), .len = @intCast(pn.image.len), .kind = @intFromEnum(pn.kind), .block = 0, .exit = try b.exitTo(pc, blk) }));
            return;
        }
        const plan = hooks.new_plan(b.level().fs, pc) orelse return refuse("a new whose constructor does more than store its parameters");
        const v = try b.add(.{ .op = .new_inst, .repr = .word, .tag = .Instance, .aux = @intFromPtr(plan.image.ptr), .len = @intCast(plan.image.len), .block = 0, .exit = try b.exitTo(pc, blk) });
        for (plan.stores) |st| {
            // Parameter 0 is the instance.
            const x = if (st.param == 0) v else try b.read(lo + st.param - 1);
            _ = try b.add(.{ .op = .init_field, .repr = .none, .a = v, .b = x, .aux = st.slot, .block = 0 });
        }
        try b.write(dst, v);
    }

    /// A static call at `pc` of a host function the tier computes or calls straight.
    fn hostCall(b: *Builder, pc: usize, blk: u32) Error!void {
        const hooks = b.env.hooks orelse return refuse("a call whose site holds no callee");
        const module = b.env.module orelse return refuse("a call whose site holds no callee");
        try b.intrinsic(hooks.static_intrinsic(module, b.code(pc, 2)), pc, blk);
    }

    /// The call at `pc` (a `call`, `vcall` or `native`, its argument run and result register
    /// in its words 3 to 5) of a host function run as intrinsic `k`: computed in place, or
    /// its body called straight; an argument the intrinsic does not take leaves to the op.
    fn intrinsic(b: *Builder, k: intrinsics.Intrinsic, pc: usize, blk: u32) Error!void {
        const lo = b.code(pc, 3);
        const n = b.code(pc, 4);
        const dst = b.code(pc, 5);
        if (!k.fits(lo, n, dst)) return refuse("a call of a host function");
        if (k.called()) {
            const hooks = b.env.hooks.?;
            const module = b.env.module.?;
            var args: [3]Id = .{ graph.no_id, graph.no_id, graph.no_id };
            for (0..k.arity()) |i| args[i] = try b.read(lo + @as(u32, @intCast(i)));
            // Nothing is done where the body does not take its arguments: the op runs again.
            const exit = try b.exitTo(pc, blk);
            const v = try b.add(.{ .op = .host_call, .repr = .pair, .a = args[0], .b = args[1], .c = args[2], .aux = hooks.intrinsic_entry(k), .ptr = @intFromPtr(module), .kind = @intCast(k.arity()), .block = 0, .exit = exit });
            try b.write(dst, v);
            switch (k) {
                .map_get, .map_size, .sb_length => {},
                // A store another can see: a check after it cannot run the call again.
                else => if (b.inCallee()) {
                    b.effect = true;
                },
            }
            return;
        }
        switch (k) {
            .array_size => |bits| {
                const av = try b.word(lo, .Array, pc, blk);
                try b.write(dst, try b.add(.{ .op = .array_size, .repr = .word, .tag = .Int, .a = av, .aux = bits, .block = 0, .exit = try b.exitTo(pc, blk) }));
            },
            .list_get => {
                if (!b.env.list_reads) return refuse("a list read under its lock");
                const lv = try b.word(lo, .List, pc, blk);
                const iv = try b.word(lo + 1, .Int, pc, blk);
                try b.write(dst, try b.add(.{ .op = .list_get, .repr = .pair, .a = lv, .b = iv, .block = 0, .exit = try b.exitTo(pc, blk) }));
            },
            .list_size => {
                const lv = try b.word(lo, .List, pc, blk);
                try b.write(dst, try b.add(.{ .op = .list_size, .repr = .word, .tag = .Int, .a = lv, .block = 0, .exit = try b.exitTo(pc, blk) }));
            },
            else => return refuse("a call of a host function"),
        }
    }

    /// `call` at `pc`: its callee's ops read in place, from the one its site keeps.
    fn call(b: *Builder, pc: usize, blk: u32) Error!void {
        const fs = b.level().fs;
        const site = b.code(pc, 6);
        if (site >= fs.callees.len) return refuse("a call site past the function's");
        const sc = fs.callees[site].load(.acquire) orelse return b.hostCall(pc, blk);
        const cont = try b.g.newBlock();
        try b.inlineCall(pc, blk, sc, cont);
        try b.enterCont(cont);
    }

    /// `vcall` at `pc`: the implementations of the one or two classes its site keeps, each
    /// read in place behind a test of the receiver's class; any other class leaves.
    fn vcall(b: *Builder, pc: usize, blk: u32) Error!void {
        const fs = b.level().fs;
        const site = b.code(pc, 6);
        if (site >= fs.vcallees.len) return refuse("a call site past the function's");
        const e = fs.vcallees[site].load(.acquire) orelse return refuse("a call whose site holds no callee");
        var n: usize = 0;
        for (0..2) |i| {
            if (e.streams[i] == null) break;
            n += 1;
        }
        if (n == 0) {
            // One host function, of the values of one tag: the tag checked, the function
            // computed or called as an intrinsic.
            const hooks = b.env.hooks orelse return refuse("a virtual call of a host function");
            const module = b.env.module orelse return refuse("a virtual call of a host function");
            if (e.n != 1) return refuse("a virtual call of host functions of two classes");
            const tag = hooks.host_tag(module, e.classes[0]) orelse return refuse("a virtual call of a host function of instances");
            // The receiver's register holds the checked word from here on.
            try b.write(b.code(pc, 3), try b.word(b.code(pc, 3), tag, pc, blk));
            return b.intrinsic(hooks.native_intrinsic(module, e.natives[0]), pc, blk);
        }
        const recv = try b.word(b.code(pc, 3), .Instance, pc, blk);
        const cont = try b.g.newBlock();
        if (n == 2) {
            const is0 = try b.add(.{ .op = .class_is, .repr = .word, .tag = .Bool, .a = recv, .aux = e.classes[0], .block = 0 });
            const from = b.cur;
            const tb = try b.g.newBlock();
            const fb = try b.g.newBlock();
            try b.g.addEdge(from, tb);
            try b.g.addEdge(from, fb);
            try b.g.seal(tb, b);
            try b.g.seal(fb, b);
            b.g.blocks.items[from].term = .{ .branch = .{ .cond = is0, .t = tb, .f = fb } };
            b.cur = tb;
            try b.inlineCall(pc, blk, e.streams[0].?, cont);
            b.cur = fb;
            _ = try b.add(.{ .op = .check_class, .repr = .none, .a = recv, .aux = e.classes[1], .block = 0, .exit = try b.exitTo(pc, blk) });
            try b.inlineCall(pc, blk, e.streams[1].?, cont);
        } else {
            _ = try b.add(.{ .op = .check_class, .repr = .none, .a = recv, .aux = e.classes[0], .block = 0, .exit = try b.exitTo(pc, blk) });
            try b.inlineCall(pc, blk, e.streams[0].?, cont);
        }
        try b.enterCont(cont);
    }

    /// `callv` at `pc`: the body of the lambda its site keeps read in place, behind a test that
    /// the closure called is one over the lambda's record; any other leaves.
    fn callv(b: *Builder, pc: usize, blk: u32) Error!void {
        const fs = b.level().fs;
        const site = b.code(pc, 6);
        if (site >= fs.lambdas.len) return refuse("a call site past the function's");
        const ls = fs.lambdas[site].load(.acquire) orelse return refuse("a lambda call whose site holds no lambda");
        // The lambda's body runs against this module's tables.
        const module = b.env.module orelse return refuse("a lambda");
        if (ls.module != module or ls.owning != null) return refuse("a lambda of another module");
        const clo = try b.word(b.code(pc, 2), .IrClosure, pc, blk);
        _ = try b.add(.{ .op = .check_closure, .repr = .none, .a = clo, .aux = @intFromPtr(ls.record), .block = 0, .exit = try b.exitTo(pc, blk) });
        const cont = try b.g.newBlock();
        try b.inlineCallWith(pc, blk, ls.sc, cont, clo);
        try b.enterCont(cont);
    }

    /// `cast` at `pc` to a class whose values are those of one tag: the value, checked to
    /// hold it; one that does not leaves to the op, which throws.
    fn cast(b: *Builder, pc: usize, blk: u32) Error!void {
        const hooks = b.env.hooks orelse return refuse("cast");
        const module = b.env.module orelse return refuse("cast");
        // A nullable or safe cast answers null for what it does not take.
        if (b.code(pc, 5) != 0) return refuse("a nullable or safe cast");
        const t = hooks.class_tag(module, b.code(pc, 4)) orelse return refuse("a cast to a class of instances");
        switch (t) {
            .Int, .Long, .Double, .Bool => {},
            else => return refuse("a cast to a class of another tag"),
        }
        try b.write(b.code(pc, 2), try b.word(b.code(pc, 3), t, pc, blk));
    }

    /// The block after a call read in place, which its returns go to: read on in it.
    fn enterCont(b: *Builder, cont: u32) Error!void {
        if (b.g.blocks.items[cont].preds.items.len == 0) return refuse("a callee that never returns");
        try b.g.seal(cont, b);
        b.cur = cont;
    }

    /// The call at `pc` (`call` or `vcall`: its argument run and result register in the op's
    /// words) of callee `sc` read in place, its returns going on to `cont`.
    fn inlineCall(b: *Builder, pc: usize, blk: u32, sc: *const bc.FuncStreams, cont: u32) Error!void {
        return b.inlineCallWith(pc, blk, sc, cont, graph.no_id);
    }

    /// `inlineCall`, of a lambda's body where `closure` is the closure called.
    fn inlineCallWith(b: *Builder, pc: usize, blk: u32, sc: *const bc.FuncStreams, cont: u32, closure: Id) Error!void {
        const depth = b.levels.items.len;
        if (depth > max_depth) return refuse("calls in place too deep");
        if (sc.code.len > max_callee_words) return refuse("a callee too large");
        if (b.inlined_words + sc.code.len > max_inlined_words) return refuse("callees too large in all");
        for (b.levels.items) |l| if (l.fs == sc) return refuse("a recursive call");
        if (closure == graph.no_id and sc.func.params.len > 0 and sc.func.is_lambda) return refuse("a lambda");
        b.inlined_words += @intCast(sc.code.len);
        const lo = b.code(pc, 3);
        const n = b.code(pc, 4);
        const a = b.g.a;
        // The callee's kinds, its parameters taking what its arguments hold at the call.
        const arg_kinds = try a.alloc(kinds_mod.Kind, n);
        const params = try a.alloc(Id, n);
        for (0..n) |i| {
            const r: u32 = lo + @as(u32, @intCast(i));
            arg_kinds[i] = b.kindAt(pc, r);
            params[i] = try b.read(r);
        }
        const kinds = try a.create(Kinds);
        kinds.* = try kinds_mod.analyzeWith(a, sc, arg_kinds, b.env.module);
        const order = try readOrder(a, sc, sc.func.entry.int(), null, false);
        const block_of = try a.alloc(u32, sc.blocks.len);
        @memset(block_of, graph.no_exit);
        for (order) |bi| block_of[bi] = try b.g.newBlock();
        if (depth == 1) {
            b.call_pc = pc;
            b.call_blk = blk;
            b.effect = false;
        }
        b.g.max_level = @max(b.g.max_level, @as(u32, @intCast(depth - 1)));
        b.g.calls_in_place = true;
        const base = b.next_base;
        b.next_base += sc.func.n_locals;
        try b.levels.append(a, .{
            .fs = sc,
            .kinds = kinds,
            .base = base,
            .block_of = block_of,
            .dst = b.code(pc, 5),
            .caller_base = b.level().base,
            .cont = cont,
            .params = params,
            .closure = closure,
        });
        const entry = block_of[sc.func.entry.int()];
        try b.g.addEdge(b.cur, entry);
        b.g.blocks.items[b.cur].term = .{ .jump = entry };
        for (order) |bi| {
            try b.g.seal(block_of[bi], b);
            try b.readBlock(bi);
        }
        _ = b.levels.pop();
    }

    fn getField(b: *Builder, pc: usize, blk: u32) Error!void {
        const dst = b.code(pc, 2);
        const obj = b.code(pc, 3);
        const slot = b.code(pc, 4);
        const v = try b.instance(obj, slot, pc, blk);
        try b.write(dst, try b.add(.{ .op = .get_field, .repr = .pair, .a = v, .aux = slot | (@as(u64, 1) << 32), .block = 0 }));
    }

    fn setField(b: *Builder, pc: usize, blk: u32) Error!void {
        const obj = b.code(pc, 2);
        const slot = b.code(pc, 3);
        const val = b.code(pc, 4);
        const v = try b.instance(obj, slot, pc, blk);
        const x = try b.read(val);
        // A reference stored into an old instance not remembered yet leaves to the op,
        // whose handler takes the write barrier.
        _ = try b.add(.{ .op = .set_field, .repr = .none, .a = v, .b = x, .aux = slot | (@as(u64, 1) << 32), .block = 0, .exit = try b.exitTo(pc, blk) });
    }
};

fn isCmpBrK(op: Op) bool {
    return @intFromEnum(op) >= @intFromEnum(Op.cmp_br_k_less) and @intFromEnum(op) <= @intFromEnum(Op.cmp_br_k_ident_neq);
}

fn refuse(why: []const u8) error{Unsupported} {
    last_refusal = why;
    return error.Unsupported;
}

/// The root registers the loop's instructions write, as the IR names them: every one an
/// op of the loop writes, whatever the op.
fn writtenRegs(a: std.mem.Allocator, fs: *const bc.FuncStreams, loop: Loop) ![]bool {
    const n = fs.func.n_locals;
    const out = try a.alloc(bool, n);
    @memset(out, false);
    const Def = struct {
        out: []bool,
        fn f(c: @This(), r: ir.Reg, is_def: bool) void {
            if (is_def and r.int() < c.out.len) c.out[r.int()] = true;
        }
    };
    for (fs.func.blocks, 0..) |*blk, bi| {
        if (bi >= loop.body.len or !loop.body[bi]) continue;
        for (blk.insts) |*inst| ir.visitInstRegs(inst, Def{ .out = out }, Def.f);
    }
    return out;
}

/// The most ops a loop leaves at to the baseline's code (`buildLeaving`).
pub const max_cold = 8;

/// The graph of `env.loop`, leaving at each op the tier does not take rather than refusing
/// the loop, up to `max_cold` of them: such an op in a path the loop seldom takes costs it
/// nothing, and one it takes each time makes the loop's code give way to the baseline's
/// (`emit`'s bounce budget). Refused for anything else.
pub fn buildLeaving(a: std.mem.Allocator, env: Env) Error!Graph {
    var cold: std.ArrayList(u32) = .empty;
    var why: std.ArrayList([]const u8) = .empty;
    try cold.appendSlice(a, env.cold);
    while (true) {
        var e = env;
        e.cold = cold.items;
        last_cold = cold.items;
        last_cold_why = why.items;
        last_refused_pc = null;
        if (build(a, e)) |g| return g else |err| {
            if (err != error.Unsupported) return err;
            const pc = last_refused_pc orelse return err;
            if (cold.items.len >= max_cold or std.mem.indexOfScalar(u32, cold.items, pc) != null) return err;
            try cold.append(a, pc);
            try why.append(a, last_refusal);
        }
    }
}

/// The graph of `env.loop`, in `a`.
pub fn build(a: std.mem.Allocator, env: Env) Error!Graph {
    const fs = env.fs;
    const live = (try ir.regs.Live.init(a, fs.func.blocks, fs.func.n_locals)) orelse return refuse("registers past the frame");
    var b: Builder = .{
        .g = Graph.init(a),
        .env = env,
        .block_of = try a.alloc(u32, fs.blocks.len),
        .written = try writtenRegs(a, fs, env.loop),
        .live = live,
        .head_pc = fs.blocks[env.loop.head].enter,
        .need = try a.alloc(u64, live.words),
        .defd = try a.alloc(u64, live.words),
    };
    @memset(b.block_of, graph.no_exit);
    try b.levels.append(a, .{ .fs = fs, .kinds = env.kinds, .base = 0, .block_of = b.block_of });
    const entry = try b.g.newBlock();
    b.g.entry_block = entry;
    try b.g.seal(entry, &b);
    const order = try readOrder(a, fs, env.loop.head, env.loop.body, true);
    for (order) |bi| b.block_of[bi] = try b.g.newBlock();
    try b.g.addEdge(entry, b.block_of[env.loop.head]);
    b.g.blocks.items[entry].term = .{ .jump = b.block_of[env.loop.head] };
    for (order) |bi| {
        // A block only an op the loop leaves at reached is left to the baseline.
        if (bi != env.loop.head and b.g.blocks.items[b.block_of[bi]].preds.items.len == 0) continue;
        // A block other than the head has all its predecessors read by now.
        if (bi != env.loop.head) try b.g.seal(b.block_of[bi], &b);
        try b.readBlock(bi);
    }
    try b.g.seal(b.block_of[env.loop.head], &b);
    // Code that leaves before it comes back to the head takes the loop's time for nothing.
    if (b.g.blocks.items[b.block_of[env.loop.head]].preds.items.len < 2) return refuse("a loop its code leaves before it turns");
    try b.g.finish();
    return b.g;
}

/// The loop's blocks in reverse postorder from its head over the edges inside it, the
/// head's back edges left out: each block after every predecessor it has in the loop but
/// the head's back edges, which the reading order needs. Refused when an edge inside
/// the loop other than to the head goes back (a loop inside it).
fn readOrder(a: std.mem.Allocator, fs: *const bc.FuncStreams, head: u32, body: ?[]const bool, loops_to_head: bool) Error![]u32 {
    const loop: Loop = .{ .head = head, .body = body orelse &.{} };
    const nb = fs.blocks.len;
    const state = try a.alloc(u8, nb);
    @memset(state, 0);
    var post: std.ArrayList(u32) = .empty;
    var stack: std.ArrayList(struct { blk: u32, succ: [2]u32, n: usize, next: usize }) = .empty;
    try stack.append(a, .{ .blk = loop.head, .succ = undefined, .n = 0, .next = 0 });
    stack.items[0].n = blockSuccs(fs, loop.head, &stack.items[0].succ);
    state[loop.head] = 1;
    while (stack.items.len != 0) {
        const top = &stack.items[stack.items.len - 1];
        if (top.next == top.n) {
            state[top.blk] = 2;
            try post.append(a, top.blk);
            _ = stack.pop();
            continue;
        }
        const t = top.succ[top.next];
        top.next += 1;
        if (t >= nb) continue;
        if (body != null and (t >= loop.body.len or !loop.body[t])) continue;
        if (t == loop.head) {
            if (loops_to_head) continue;
            return refuse("a loop in a callee");
        }
        switch (state[t]) {
            0 => {
                state[t] = 1;
                var e: @TypeOf(stack.items[0]) = .{ .blk = t, .succ = undefined, .n = 0, .next = 0 };
                e.n = blockSuccs(fs, t, &e.succ);
                try stack.append(a, e);
            },
            1 => return refuse("a loop inside the loop"),
            else => {},
        }
    }
    // A block of the loop its head does not reach is reached from nowhere (the head
    // dominates the loop), and is left out.
    std.mem.reverse(u32, post.items);
    return post.items;
}

/// The blocks stream block `blk`'s branches go to, from the op that ends it.
fn blockSuccs(fs: *const bc.FuncStreams, blk: u32, out: *[2]u32) usize {
    const c = fs.code;
    const sb = fs.blocks[blk];
    var pc: usize = sb.enter;
    while (pc <= sb.end) {
        const op = fs.opAt(pc);
        switch (op) {
            .jump, .goto_try => {
                out[0] = c[pc + 1];
                return 1;
            },
            .br => {
                out.* = .{ c[pc + 2], c[pc + 4] };
                return 2;
            },
            .cmp_br => {
                out.* = .{ c[pc + 6], c[pc + 8] };
                return 2;
            },
            .ret, .ret_try, .term_exit, .end => return 0,
            else => if (isCmpBrK(op)) {
                out.* = .{ c[pc + 12], c[pc + 14] };
                return 2;
            },
        }
        pc += bc.opLen(op, c, pc);
        if (bc.kOperator(op) != null and !isCmpBrK(op)) pc += bc.opLen(fs.opAt(pc), c, pc);
    }
    return 0;
}

const testing = std.testing;
const hand = @import("../hand.zig");

fn branchOn(cond: u32, t: u32, f: u32) ir.Terminator {
    return .{ .Branch = .{ .cond = hand.reg(cond), .t = .from(t), .f = .from(f) } };
}

test "a counted loop's graph takes its counter and accumulator as words around the back edge" {
    var mem = hand.TestMemory.init();
    defer mem.deinit();
    const a = mem.allocator();
    var h = try hand.Hand.init(a);
    const zero = try h.constant(.{ .Int = 0 });
    const one = try h.constant(.{ .Int = 1 });
    const zero_l = try h.constant(.{ .Long = 0 });
    // var i = 0; var acc = 0L; while (i < n) { acc = acc + i.toLong(); i = i + 1 }; return acc
    const f = try h.func("sum", 1);
    try h.body(f, &.{
        .{ .insts = &.{ hand.param(0, 0), hand.konst(1, zero), hand.konst(2, zero_l) }, .term = hand.jump(1) },
        .{ .insts = &.{hand.bin(3, .Less, 1, 0)}, .term = branchOn(3, 2, 3) },
        .{ .insts = &.{
            .{ .UnOp = .{ .dst = hand.reg(4), .op = .ToLong, .operand = hand.reg(1) } },
            hand.bin(2, .Add, 2, 4),
            hand.konst(5, one),
            hand.bin(1, .Add, 1, 5),
        }, .term = hand.jump(1) },
        .{ .insts = &.{}, .term = hand.ret(2) },
    });
    h.m.funcByIdMut(f).?.params[0].ty = .{ .name = "kotlin.Int", .nullable = false, .args = &.{} };
    try h.finish();
    const fs = bc.funcStreams(h.funcPtr(f), h.m.consts.items) orelse return error.TestUnexpectedResult;
    const k = try kinds_mod.analyze(a, fs, h.m);
    const body = try a.alloc(bool, fs.blocks.len);
    @memset(body, false);
    body[1] = true;
    body[2] = true;
    const g = try build(a, .{ .fs = fs, .kinds = &k, .module = h.m, .loop = .{ .head = 1, .body = body } });
    // The counter and the accumulator are parameters at the head, words of their kinds.
    var int_phi = false;
    var long_phi = false;
    for (g.blocks.items[g.blocks.items[0].term.jump].nodes.items) |id| {
        const n = g.nodes.items[id];
        if (n.op != .phi) continue;
        try testing.expectEqual(graph.Repr.word, n.repr);
        if (n.tag == .Int) int_phi = true;
        if (n.tag == .Long) long_phi = true;
    }
    try testing.expect(int_phi and long_phi);
    // The loop leaves to its exit block and, through the back edge's guard, to its compare.
    var leaves: usize = 0;
    var polls: usize = 0;
    for (g.blocks.items) |blk| {
        if (blk.term == .leave) leaves += 1;
        for (blk.nodes.items) |id| {
            if (g.nodes.items[id].op == .check_poll) polls += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), leaves);
    try testing.expectEqual(@as(usize, 1), polls);
    // No tag check: the kinds prove every operand.
    for (g.nodes.items) |n| try testing.expect(n.op != .check_tag);
}
