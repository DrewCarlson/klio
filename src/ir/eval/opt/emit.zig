//! AArch64 code for a loop's graph (`graph.zig`), its values in the
//! registers `regalloc.zig` gave them or in its stack slots. The code has a
//! frame record of its own and saves the callee-saved registers it uses, keeps the thread's spin
//! counter and the edge flags' address in two of them, and leaves the
//! registers compiled code runs on (the context, the frame, its registers,
//! the code) as they were. Its entry loads the loop's live registers from the
//! frame and checks the kinds the code relies on, going to the baseline's
//! head when one differs; every exit writes the root registers the frame must
//! hold, gives the frame and the spin counter back, and jumps to the
//! baseline's code for the op it leaves to.

const std = @import("std");
const runtime = @import("runtime");
const jit = @import("jit");
const ir = @import("../../ir.zig");
const kinds_mod = @import("../kinds.zig");
const masm = @import("../masm.zig");
const graph = @import("graph.zig");
const regalloc = @import("regalloc.zig");

const A = jit.a64;
const Reg = A.Reg;
const Graph = graph.Graph;
const Id = graph.Id;
const no_id = graph.no_id;
const Tag = graph.Tag;

pub const Error = masm.Error || std.mem.Allocator.Error;

/// The registers values are given, by `regalloc.Loc` index: callee-saved ones first,
/// then scratch ones compiled code keeps nothing in between ops.
pub const value_regs = [_]Reg{ .x19, .x20, .x21, .x22, .x23, .x24, .x25, .x26, .x4, .x5, .x6, .x7, .x8, .x13 };
/// The registers Doubles are given: ones no call the code makes keeps, and it makes none.
pub const float_regs = [_]A.V{ .v18, .v19, .v20, .v21, .v22, .v23, .v24, .v25, .v26, .v27, .v28, .v29, .v30, .v31 };

const ctx: Reg = .x0;
const frame: Reg = .x1;
const regs: Reg = .x2;
/// The thread's spin counter, and the edge flags' address, for the back edge's guard.
const spin: Reg = .x28;
const flags: Reg = .x27;
/// Scratch.
const s0: Reg = .x9;
const s1: Reg = .x10;
const s2: Reg = .x11;
const s3: Reg = .x12;
const fa: A.V = .v16;
const fb: A.V = .v17;
/// Operands read from the frame, a node's first, second and third.
const ta: Reg = .x14;
const tb: Reg = .x16;
const tc: Reg = .x17;
/// The frame record and the saved registers: x29 and x30, then x19 to x28.
const frame_bytes: i32 = 96;

/// Whether an optimized loop's code is entered, kept with the code: it is while its
/// exits back into the loop (`Exit.bounce`) and its failed entries have not used up the
/// budget, after which the loop runs in the baseline's code alone. Counted without a lock:
/// a race between threads miscounts by a few.
pub const Gate = extern struct {
    on: u32 = 1,
    budget: u32 = bounce_budget,
};

/// The times an optimized loop may leave back into itself, or fail its entry, before its
/// code gives way to the baseline's for good.
pub const bounce_budget: u32 = 512;

/// Where the code reads what it reads, as the baseline lays it out.
pub const Layout = struct {
    tag_off: u32,
    ctx_ev: u32,
    ev_spin: u32,
    inst_slots: u32,
    inst_seq: u32,
    inst_gen: u32,
    inst_remembered: u32,
    inst_class: u32,
    prim_items: u32,
    list_items: u32,
    list_seq: u32,
    /// A list value's data: the collection it is a view of, and its storage cell.
    list_data_backing: u32,
    list_data_items: u32,
    ev_depth: u32,
    ev_depth_cap: u32,
    frame_span: u32,
    edge_flags: usize,
    /// The thread's region hole a `new` bumps: its record in the context, its cursor and
    /// limit there.
    ctx_tlab: u32,
    tlab_cursor: u32,
    tlab_limit: u32,
    /// An instance's cell, its slots after it; a primitive array's cell, its elements after.
    inst_cell: u32,
    prim_cell: u32,
    prim_capacity: u32,
    prim_trailing: u32,
    prim_gc_bytes: u32,
    region_bit: u32,
    /// The most bytes of elements a new primitive array has in place.
    prim_new_max: u32,
    /// A closure's lambda record, and its captures' slice.
    closure_body: u32,
    closure_captures: u32,
    /// `KLIO_JIT_OPT_EXITS`: per exit, a counter its code adds one to, and one the entry's
    /// failure adds one to after them.
    exit_counts: ?[]u64 = null,
    /// The loop's gate, whose budget its bounces spend.
    gate: ?*Gate = null,
};

/// The bytes of `sp` as the evaluator stores an optional span.
pub fn spanBytes(sp: ?ir.Span) [@sizeOf(?ir.Span)]u8 {
    var buf: [@sizeOf(?ir.Span)]u8 = @splat(0);
    @as(*?ir.Span, @ptrCast(@alignCast(&buf))).* = sp;
    return buf;
}

const Emitter = struct {
    m: *masm.A64,
    a: std.mem.Allocator,
    g: *const Graph,
    al: regalloc.Alloc,
    lay: Layout,
    /// Per block, its label.
    labels: []A.Label,
    /// Per exit, its label.
    exit_labels: []A.Label,
    fail_entry: A.Label,
    /// Per value, the reads of it: a compare only its block's branch reads, last in its
    /// block, is the branch's own compare (`fusedCompare`).
    uses: []u32,
    /// The bytes the stack pointer is below the values' stack slots: a host call's area
    /// while it is made, else 0.
    sp_adjust: u32 = 0,

    fn asm_(e: *Emitter) *A.Asm {
        return &e.m.a;
    }

    fn reg(e: *const Emitter, v: Id) Reg {
        return value_regs[e.al.loc[v].word];
    }

    fn tagReg(e: *const Emitter, v: Id) Reg {
        return value_regs[e.al.loc[v].tag];
    }

    fn freg(e: *const Emitter, v: Id) A.V {
        return float_regs[e.al.loc[v].word];
    }

    fn isFloat(e: *const Emitter, v: Id) bool {
        return regalloc.isFloat(e.node(v));
    }

    fn inMemory(e: *const Emitter, v: Id) bool {
        return e.al.loc[v].inMemory();
    }

    /// Where value `v`, in memory, keeps its word: its root register in the frame, or its
    /// stack slot.
    fn homeWord(e: *const Emitter, v: Id) struct { Reg, u32 } {
        const l = e.al.loc[v];
        if (l.frame) return .{ regs, @as(u32, @intCast(e.node(v).aux)) * 16 };
        return .{ A.sp, e.sp_adjust + 16 * @as(u32, l.spill) };
    }

    fn homeTag(e: *const Emitter, v: Id) struct { Reg, u32 } {
        const l = e.al.loc[v];
        if (l.frame) return .{ regs, @as(u32, @intCast(e.node(v).aux)) * 16 + e.lay.tag_off };
        return .{ A.sp, e.sp_adjust + 16 * @as(u32, l.spill) + 8 };
    }

    fn spillBytes(e: *const Emitter) u32 {
        return 16 * @as(u32, e.al.spills);
    }

    /// Value `v`, made in its registers, stored to its stack slot.
    fn storeHome(e: *Emitter, v: Id) Error!void {
        const as = e.asm_();
        const base, const off = e.homeWord(v);
        if (e.isFloat(v)) return as.strF(.d, e.freg(v), base, @intCast(off));
        try e.store(.x, e.reg(v), base, off);
        if (e.node(v).repr == .pair) {
            const tb_, const to = e.homeTag(v);
            try e.store(.x, e.tagReg(v), tb_, to);
        }
    }

    /// A general register holding value `v`'s payload word: its own, or `tmp` for a
    /// Double's bits moved out of its floating register, a constant made there, or an
    /// entry value read from the frame.
    fn payload(e: *Emitter, v: Id, tmp: Reg) Error!Reg {
        if (regalloc.remade(e.node(v)) or e.inMemory(v)) return e.operand(v, tmp);
        if (!e.isFloat(v)) return e.reg(v);
        try e.asm_().fmovFromV(.x, tmp, e.freg(v));
        return tmp;
    }

    /// A general register holding word `v`: its own, or `tmp` with a constant made in it or
    /// an entry value read from the frame (a Bool's low byte, an Int's low word).
    fn operand(e: *Emitter, v: Id, tmp: Reg) Error!Reg {
        const n = e.node(v);
        if (e.inMemory(v)) {
            const base, const at = e.homeWord(v);
            if (n.repr == .word and n.tag == .Bool) {
                try e.loadByte(tmp, base, at);
            } else try e.load(if (n.repr == .word) width(n.tag) else .x, tmp, base, at);
            return tmp;
        }
        if (!regalloc.remade(n)) return e.reg(v);
        try e.asm_().movImm(.x, tmp, n.aux);
        return tmp;
    }

    /// A general register holding pair `v`'s tag word: its own, or `tmp` read from the frame.
    fn tagOf(e: *Emitter, v: Id, tmp: Reg) Error!Reg {
        if (!e.inMemory(v)) return e.tagReg(v);
        const base, const at = e.homeTag(v);
        try e.load(.x, tmp, base, at);
        return tmp;
    }

    /// A floating register holding Double `v`: its own, or `tmp` read from the frame.
    fn fregIn(e: *Emitter, v: Id, tmp: A.V) Error!A.V {
        if (!e.inMemory(v)) return e.freg(v);
        const base, const at = e.homeWord(v);
        try e.load(.x, ta, base, at);
        try e.asm_().fmovToV(.x, tmp, ta);
        return tmp;
    }

    fn node(e: *const Emitter, v: Id) graph.Node {
        return e.g.nodes.items[v];
    }

    /// The width a word of tag `t` computes in.
    fn width(t: Tag) A.W {
        return switch (t) {
            .Int, .Bool, .Char, .Short, .Byte => .w,
            else => .x,
        };
    }

    fn popFrame(e: *Emitter) Error!void {
        const as = e.asm_();
        if (e.spillBytes() != 0) try as.addImm(.x, A.sp, A.sp, e.spillBytes());
        try as.ldp(.x19, .x20, A.sp, 16);
        try as.ldp(.x21, .x22, A.sp, 32);
        try as.ldp(.x23, .x24, A.sp, 48);
        try as.ldp(.x25, .x26, A.sp, 64);
        try as.ldp(.x27, .x28, A.sp, 80);
        try as.ldpPost(.x29, .x30, A.sp, frame_bytes);
    }

    fn pushFrame(e: *Emitter) Error!void {
        const as = e.asm_();
        try as.stpPre(.x29, .x30, A.sp, -frame_bytes);
        try as.addImm(.x, .x29, A.sp, 0);
        try as.stp(.x19, .x20, A.sp, 16);
        try as.stp(.x21, .x22, A.sp, 32);
        try as.stp(.x23, .x24, A.sp, 48);
        try as.stp(.x25, .x26, A.sp, 64);
        try as.stp(.x27, .x28, A.sp, 80);
        if (e.spillBytes() != 0) try as.subImm(.x, A.sp, A.sp, e.spillBytes());
    }

    /// `dst = [base + off]`, 64 or 32 bits, for any offset.
    fn load(e: *Emitter, w: A.W, dst: Reg, base: Reg, off: u32) Error!void {
        const as = e.asm_();
        if (off <= 4095) return as.ldr(if (w == .x) .x else .w, dst, base, @intCast(off));
        try as.movImm(.x, .x15, off);
        try as.add(.x, .x15, base, .x15);
        try as.ldr(if (w == .x) .x else .w, dst, .x15, 0);
    }

    /// `dst = [base + off]`'s byte, for any offset.
    fn loadByte(e: *Emitter, dst: Reg, base: Reg, off: u32) Error!void {
        const as = e.asm_();
        if (off <= 4095) return as.ldr(.b, dst, base, @intCast(off));
        try as.movImm(.x, .x15, off);
        try as.add(.x, .x15, base, .x15);
        try as.ldr(.b, dst, .x15, 0);
    }

    fn store(e: *Emitter, w: A.W, src: Reg, base: Reg, off: u32) Error!void {
        const as = e.asm_();
        if (off <= 4095) return as.str(if (w == .x) .x else .w, src, base, @intCast(off));
        try as.movImm(.x, .x15, off);
        try as.add(.x, .x15, base, .x15);
        try as.str(if (w == .x) .x else .w, src, .x15, 0);
    }

    /// The entry: the frame record, the spin counter and the flags' address, then each
    /// root register the loop reads as it comes in, its kind checked.
    fn entry(e: *Emitter) Error!void {
        const as = e.asm_();
        try e.pushFrame();
        try as.ldr(.x, s0, ctx, @intCast(e.lay.ctx_ev));
        try e.load(.x, spin, s0, e.lay.ev_spin);
        try as.movImm(.x, flags, e.lay.edge_flags);
        if (e.g.calls_in_place) {
            // A call a callee in place stands for would throw past the eval depth's bound:
            // the deepest must fit, as the depth cannot change while the loop runs.
            try e.load(.x, s1, s0, e.lay.ev_depth);
            try e.load(.x, s2, s0, e.lay.ev_depth_cap);
            try as.addImm(.x, s1, s1, e.g.max_level);
            try as.cmp(.x, s1, s2);
            try as.bCond(.ge, e.fail_entry);
        }
        const b0 = e.g.blocks.items[e.g.entry_block];
        for (b0.nodes.items) |v| {
            const n = e.node(v);
            if (n.op != .entry) continue;
            const r: u32 = @intCast(n.aux);
            const at = r * 16;
            // An entry value left in the frame is read there at each use; a word's kind is
            // checked all the same.
            const framed = e.inMemory(v);
            switch (n.repr) {
                .pair => if (!framed) {
                    try e.load(.x, e.reg(v), regs, at);
                    try e.load(.x, e.tagReg(v), regs, at + e.lay.tag_off);
                },
                .word => {
                    try e.load(.x, s0, regs, at + e.lay.tag_off);
                    try as.andImm(.w, s0, s0, 0x3f);
                    try as.cmpImm(.w, s0, @intFromEnum(n.tag));
                    try as.bCond(.ne, e.fail_entry);
                    // A Bool's payload is its low byte.
                    if (framed) {} else if (n.tag == .Bool) {
                        try e.loadByte(e.reg(v), regs, at);
                    } else if (n.tag == .Double) {
                        try e.load(.x, s0, regs, at);
                        try as.fmovToV(.x, e.freg(v), s0);
                    } else try e.load(width(n.tag), e.reg(v), regs, at);
                    const k: kinds_mod.Kind = @intCast(n.variable);
                    if (kinds_mod.isInstFact(k)) {
                        const obj = try e.operand(v, s1);
                        const slots = kinds_mod.factSlots(k);
                        if (slots != 0) {
                            try e.load(.x, s0, obj, e.lay.inst_slots + 8);
                            try as.cmpImm(.x, s0, slots);
                            try as.bCond(.lt, e.fail_entry);
                        }
                        if (kinds_mod.factPlain(k)) {
                            try e.load(.w, s0, obj, e.lay.inst_seq);
                            try as.tbz(s0, 31, e.fail_entry);
                        }
                    }
                },
                .none => {},
            }
        }
    }

    /// A place a parameter's value moves between: general registers by number, floating
    /// ones past 32, and past 64 the halves of the stack slots (a slot's word, then its tag).
    const Loc = u16;
    fn gp(r: Reg) Loc {
        return @intFromEnum(r);
    }
    fn fp(v: A.V) Loc {
        return 32 + @as(u16, @intFromEnum(v));
    }
    fn slotOff(e: *const Emitter, l: Loc) u32 {
        return e.sp_adjust + 8 * @as(u32, l - 64);
    }
    /// Where value `v`'s word is, as a place: its register or its stack slot's word.
    fn wordLoc(e: *const Emitter, v: Id) Loc {
        const l = e.al.loc[v];
        if (l.spill != regalloc.no_spill) return 64 + 2 * @as(u16, l.spill);
        return if (e.isFloat(v)) fp(e.freg(v)) else gp(e.reg(v));
    }
    fn tagLoc(e: *const Emitter, v: Id) Loc {
        const l = e.al.loc[v];
        if (l.spill != regalloc.no_spill) return 65 + 2 * @as(u16, l.spill);
        return gp(e.tagReg(v));
    }

    /// The moves an edge from `from` to `to` makes into `to`'s parameters, as one parallel
    /// copy: each destination written after every source it would overwrite was read.
    fn phiMoves(e: *Emitter, from: u32, to: u32) Error!void {
        var moves: std.ArrayList(Move) = .empty;
        for (e.g.blocks.items[to].nodes.items) |p| {
            const pn = e.node(p);
            if (pn.op != .phi) continue;
            if (pn.repr == .none) continue;
            const x = regalloc.phiInput(e.g, p, from);
            const xn = e.node(x);
            const dst = e.wordLoc(p);
            if (e.al.loc[x].frame) {
                // An entry value the frame holds, read from there into the parameter.
                const at = @as(u32, @intCast(xn.aux)) * 16;
                const w: Width = if (xn.repr == .pair) .x else if (xn.tag == .Bool) .b else if (width(xn.tag) == .w) .w else .x;
                try moves.append(e.a, .{ .dst = dst, .src = null, .at = at, .w = w });
                if (pn.repr == .pair) {
                    if (xn.repr == .pair) {
                        try moves.append(e.a, .{ .dst = e.tagLoc(p), .src = null, .at = at + e.lay.tag_off, .w = .x });
                    } else try moves.append(e.a, .{ .dst = e.tagLoc(p), .src = null, .imm = @intFromEnum(xn.tag) });
                }
                continue;
            }
            if (regalloc.remade(xn)) {
                try moves.append(e.a, .{ .dst = dst, .src = null, .imm = xn.aux });
            } else try moves.append(e.a, .{ .dst = dst, .src = e.wordLoc(x) });
            if (pn.repr == .pair) {
                if (xn.repr == .pair) {
                    try moves.append(e.a, .{ .dst = e.tagLoc(p), .src = e.tagLoc(x) });
                } else {
                    try moves.append(e.a, .{ .dst = e.tagLoc(p), .src = null, .imm = @intFromEnum(xn.tag) });
                }
            }
        }
        // Drop moves onto themselves; then repeatedly write a destination no pending move
        // reads, breaking a cycle through a scratch register of its set.
        var pending = moves.items;
        var n: usize = 0;
        for (pending) |mv| if (mv.src == null or mv.src.? != mv.dst) {
            pending[n] = mv;
            n += 1;
        };
        pending = pending[0..n];
        while (pending.len != 0) {
            var progressed = false;
            var i: usize = 0;
            while (i < pending.len) {
                const mv = pending[i];
                const read_by_other = for (pending, 0..) |o, j| {
                    if (j != i and o.src != null and o.src.? == mv.dst) break true;
                } else false;
                if (read_by_other) {
                    i += 1;
                    continue;
                }
                try e.move(mv);
                pending[i] = pending[pending.len - 1];
                pending = pending[0 .. pending.len - 1];
                progressed = true;
            }
            if (!progressed) {
                // A cycle: park one source in scratch and read it from there.
                const mv = pending[0];
                const src = mv.src.?;
                const park: Loc = if (src >= 32 and src < 64) fp(fa) else gp(s0);
                try e.move(.{ .dst = park, .src = src });
                for (pending) |*o| if (o.src != null and o.src.? == src) {
                    o.src = park;
                };
            }
        }
    }

    const Width = enum { b, w, x };

    /// A move into a place: from another, of a constant, or a load from the frame at `at`
    /// of width `w`.
    const Move = struct { dst: Loc, src: ?Loc, imm: u64 = 0, at: ?u32 = null, w: Width = .x };

    /// One move; one into a stack slot of a constant, a frame word or another slot's goes
    /// through `s2`, which no parked source is in.
    fn move(e: *Emitter, mv: Move) Error!void {
        const as = e.asm_();
        const dst = mv.dst;
        const to_mem = dst >= 64;
        const to_float = dst >= 32 and dst < 64;
        if (mv.at) |at| {
            const into: Reg = if (to_float) ta else if (to_mem) s2 else @enumFromInt(dst);
            switch (mv.w) {
                .b => try e.loadByte(into, regs, at),
                .w => try e.load(.w, into, regs, at),
                .x => try e.load(.x, into, regs, at),
            }
            if (to_float) try as.fmovToV(.x, @enumFromInt(dst - 32), ta);
            if (to_mem) try e.store(.x, s2, A.sp, e.slotOff(dst));
            return;
        }
        const s = mv.src orelse {
            if (to_mem) {
                try as.movImm(.x, s2, mv.imm);
                return e.store(.x, s2, A.sp, e.slotOff(dst));
            }
            return as.movImm(.x, @enumFromInt(dst), mv.imm);
        };
        const from_mem = s >= 64;
        const from_float = s >= 32 and s < 64;
        if (to_mem) {
            if (from_float) return as.strF(.d, @enumFromInt(s - 32), A.sp, @intCast(e.slotOff(dst)));
            if (from_mem) {
                try e.load(.x, s2, A.sp, e.slotOff(s));
                return e.store(.x, s2, A.sp, e.slotOff(dst));
            }
            return e.store(.x, @enumFromInt(s), A.sp, e.slotOff(dst));
        }
        if (to_float) {
            if (from_mem) return as.ldrF(.d, @enumFromInt(dst - 32), A.sp, @intCast(e.slotOff(s)));
            if (from_float) return as.fmovV(.d, @enumFromInt(dst - 32), @enumFromInt(s - 32));
            return as.fmovToV(.x, @enumFromInt(dst - 32), @enumFromInt(s));
        }
        if (from_mem) return e.load(.x, @enumFromInt(dst), A.sp, e.slotOff(s));
        if (from_float) return as.fmovFromV(.x, @enumFromInt(dst), @enumFromInt(s - 32));
        return as.mov(.x, @enumFromInt(dst), @enumFromInt(s));
    }

    fn exitLabel(e: *const Emitter, x: u32) A.Label {
        return e.exit_labels[x];
    }

    fn cond(bop: ir.BinOp, float: bool) A.Cond {
        return switch (bop) {
            .Eq => .eq,
            .NotEq => .ne,
            // A float compare with NaN is unordered, which these answer false for.
            .Less => if (float) .mi else .lt,
            .LessEq => if (float) .ls else .le,
            .Greater => .gt,
            .GreaterEq => .ge,
            else => unreachable,
        };
    }

    /// Whether compare `v`, the last node of its block and read by nothing but the block's
    /// branch, compares at the branch instead of making a Bool.
    fn fusedCompare(e: *const Emitter, v: Id) bool {
        const n = e.node(v);
        if ((n.op != .cmp and n.op != .class_is) or e.uses[v] != 1) return false;
        const blk = e.g.blocks.items[n.block];
        if (blk.term != .branch or blk.term.branch.cond != v) return false;
        return blk.nodes.items[blk.nodes.items.len - 1] == v;
    }

    /// A branch on compare `v` to `t`, falling through to the code after.
    fn compareBranch(e: *Emitter, v: Id, t: A.Label, taken: bool) Error!void {
        const as = e.asm_();
        const n = e.node(v);
        if (n.op == .class_is) {
            try e.load(.w, s0, try e.operand(n.a, ta), e.lay.inst_class);
            try e.cmpConst(s0, n.aux);
            return as.bCond(if (taken) .eq else .ne, t);
        }
        const bop: ir.BinOp = @enumFromInt(n.aux & 0xff);
        const tag: Tag = @enumFromInt(n.aux >> 8);
        var c: A.Cond = undefined;
        if (tag == .Double) {
            try as.fcmp(.d, try e.fregIn(n.a, fa), try e.fregIn(n.b, fb));
            c = cond(bop, true);
        } else {
            try as.cmp(width(tag), try e.operand(n.a, s0), try e.operand(n.b, s1));
            c = cond(bop, false);
        }
        // The float conditions' inverses are true for NaN, as a compare's negation is.
        try as.bCond(if (taken) c else c.invert(), t);
    }

    fn nodeCode(e: *Emitter, v: Id) Error!void {
        const as = e.asm_();
        const n = e.node(v);
        if (e.fusedCompare(v)) return;
        switch (n.op) {
            .entry, .phi => {},
            // A constant other than a Double's is made where it is read.
            .konst => if (e.isFloat(v)) {
                try as.movImm(.x, s0, n.aux);
                try as.fmovToV(.x, e.freg(v), s0);
            },
            .unbox => if (e.isFloat(v)) {
                try as.fmovToV(.x, e.freg(v), try e.payload(n.a, s0));
            } else try as.mov(.x, e.reg(v), try e.payload(n.a, s0)),
            .box => {
                try as.mov(.x, e.reg(v), try e.payload(n.a, s0));
                try as.movImm(.x, e.tagReg(v), @intFromEnum(n.tag));
            },
            .check_tag => {
                if (e.node(n.a).repr == .word) {
                    // A word of another tag (one of its own is the word itself, `simplify`).
                    try as.b(e.exitLabel(n.exit));
                    return;
                }
                try as.andImm(.w, s0, try e.tagOf(n.a, ta), 0x3f);
                try as.cmpImm(.w, s0, @intFromEnum(n.tag));
                try as.bCond(.ne, e.exitLabel(n.exit));
                const word = try e.operand(n.a, tb);
                // A Bool's payload is its low byte; the word above it is unspecified.
                if (n.tag == .Bool) {
                    try as.andImm(.w, e.reg(v), word, 0xff);
                } else if (n.tag == .Double) {
                    try as.fmovToV(.x, e.freg(v), word);
                } else try as.mov(.x, e.reg(v), word);
            },
            .arith => {
                const bop: ir.BinOp = @enumFromInt(n.aux & 0xff);
                if (n.tag == .Double) {
                    const fd = e.freg(v);
                    const fl = try e.fregIn(n.a, fa);
                    const fr = try e.fregIn(n.b, fb);
                    switch (bop) {
                        .Add => try as.fadd(.d, fd, fl, fr),
                        .Sub => try as.fsub(.d, fd, fl, fr),
                        .Mul => try as.fmul(.d, fd, fl, fr),
                        .Div => try as.fdiv(.d, fd, fl, fr),
                        else => unreachable,
                    }
                    return;
                }
                const d = e.reg(v);
                const l = try e.operand(n.a, s0);
                const r = try e.operand(n.b, s1);
                const w = width(n.tag);
                switch (bop) {
                    .Add => try as.add(w, d, l, r),
                    .Sub => try as.sub(w, d, l, r),
                    .Mul => try as.mul(w, d, l, r),
                    .And => try as.@"and"(w, d, l, r),
                    .Or => try as.orr(w, d, l, r),
                    .Xor => try as.eor(w, d, l, r),
                    .Shl => try as.lslv(w, d, l, r),
                    .Shr => try as.asrv(w, d, l, r),
                    .UShr => try as.lsrv(w, d, l, r),
                    // As Kotlin's: the quotient truncated, `MIN_VALUE / -1` is `MIN_VALUE`.
                    .Div => try as.sdiv(w, d, l, r),
                    .Mod => {
                        try as.sdiv(w, s2, l, r);
                        try as.msub(w, d, s2, r, l);
                    },
                    else => unreachable,
                }
            },
            .cmp => {
                const bop: ir.BinOp = @enumFromInt(n.aux & 0xff);
                const t: Tag = @enumFromInt(n.aux >> 8);
                if (t == .Double) {
                    try as.fcmp(.d, try e.fregIn(n.a, fa), try e.fregIn(n.b, fb));
                    try as.cset(.w, e.reg(v), cond(bop, true));
                } else {
                    try as.cmp(width(t), try e.operand(n.a, s0), try e.operand(n.b, s1));
                    try as.cset(.w, e.reg(v), cond(bop, false));
                }
            },
            .conv => {
                const from: Tag = @enumFromInt(n.aux);
                switch (from) {
                    .Int => switch (n.tag) {
                        .Long => try as.sxtw(e.reg(v), try e.operand(n.a, s0)),
                        .Double => try as.scvtf(.d, e.freg(v), .w, try e.operand(n.a, s0)),
                        else => unreachable,
                    },
                    .Long => switch (n.tag) {
                        .Int => try as.mov(.w, e.reg(v), try e.operand(n.a, s0)),
                        .Double => try as.scvtf(.d, e.freg(v), .x, try e.operand(n.a, s0)),
                        else => unreachable,
                    },
                    // As Kotlin's: NaN to 0, and past the range its bound.
                    .Double => try as.fcvtzs(width(n.tag), e.reg(v), .d, try e.fregIn(n.a, fa)),
                    else => unreachable,
                }
            },
            .step => {
                const w = width(n.tag);
                const x = try e.operand(n.a, s0);
                if (n.aux == 1) try as.addImm(w, e.reg(v), x, 1) else try as.subImm(w, e.reg(v), x, 1);
            },
            .check_slots => {
                try e.load(.x, s0, try e.operand(n.a, ta), e.lay.inst_slots + 8);
                try as.cmpImm(.x, s0, @intCast(n.aux & 0xffff_ffff));
                try as.bCond(.le, e.exitLabel(n.exit));
            },
            .check_plain => {
                try e.load(.w, s0, try e.operand(n.a, ta), e.lay.inst_seq);
                try as.tbz(s0, 31, e.exitLabel(n.exit));
            },
            .get_field => {
                const slot: u32 = @intCast(n.aux & 0xffff_ffff);
                try e.load(.x, s0, try e.operand(n.a, ta), e.lay.inst_slots);
                if (slot * 16 > 504) {
                    try as.movImm(.x, s1, slot * 16);
                    try as.add(.x, s0, s0, s1);
                    try as.ldp(e.reg(v), e.tagReg(v), s0, 0);
                } else try as.ldp(e.reg(v), e.tagReg(v), s0, @intCast(slot * 16));
            },
            .set_field => try e.setField(v, n),
            .check_poll => {
                try as.addImm(.x, s0, spin, 1);
                try as.tstImm(.x, s0, 0xffff);
                try as.bCond(.eq, e.exitLabel(n.exit));
                try as.ldr(.w, s1, flags, 0);
                try as.cbnz(.w, s1, e.exitLabel(n.exit));
                try as.mov(.x, spin, s0);
            },
            .check_class => {
                try e.load(.w, s0, try e.operand(n.a, ta), e.lay.inst_class);
                try e.cmpConst(s0, n.aux);
                try as.bCond(.ne, e.exitLabel(n.exit));
            },
            .array_get => try e.arrayGet(v, n),
            .new_inst => try e.newInst(v, n),
            .init_field => {
                const off = e.lay.inst_cell + @as(u32, @intCast(n.aux)) * 16;
                const val = e.node(n.b);
                const word = try e.payload(n.b, s0);
                const tag = if (val.repr == .pair) try e.tagOf(n.b, s1) else blk: {
                    try as.movImm(.x, s1, @intFromEnum(val.tag));
                    break :blk s1;
                };
                const obj = try e.operand(n.a, ta);
                if (off <= 504) {
                    try as.stp(word, tag, obj, @intCast(off));
                } else {
                    try as.movImm(.x, s2, off);
                    try as.add(.x, s2, obj, s2);
                    try as.stp(word, tag, s2, 0);
                }
            },
            .new_prim => try e.newPrim(v, n),
            .check_not_null => {
                try as.andImm(.w, s0, try e.tagOf(n.a, ta), 0x3f);
                try as.cmpImm(.w, s0, @intFromEnum(Tag.Null));
                try as.bCond(.eq, e.exitLabel(n.exit));
            },
            .host_call => try e.hostCall(v, n),
            .is_null => {
                try as.andImm(.w, s0, try e.tagOf(n.a, ta), 0x3f);
                try as.cmpImm(.w, s0, @intFromEnum(Tag.Null));
                try as.cset(.w, e.reg(v), if (n.aux == 1) .ne else .eq);
            },
            .check_nonzero => try as.cbz(width(n.tag), try e.operand(n.a, ta), e.exitLabel(n.exit)),
            .list_get => try e.listGet(v, n),
            .list_size => {
                try e.listStorage(n);
                try e.load(.x, e.reg(v), s0, e.lay.list_items + 8);
            },
            .check_closure => {
                try e.load(.x, s0, try e.operand(n.a, ta), e.lay.closure_body);
                try as.movImm(.x, s1, n.aux);
                try as.cmp(.x, s0, s1);
                try as.bCond(.ne, e.exitLabel(n.exit));
            },
            .capture => {
                // Past the captures, `Unit`, as the lambda's frame reads it.
                const clo = try e.operand(n.a, ta);
                const unit = try as.newLabel();
                const done = try as.newLabel();
                const idx: u32 = @intCast(n.aux);
                try e.load(.x, s0, clo, e.lay.closure_captures + 8);
                try as.movImm(.x, s1, idx);
                try as.cmp(.x, s0, s1);
                try as.bCond(.ls, unit);
                try e.load(.x, s0, clo, e.lay.closure_captures);
                if (idx * 16 <= 504) {
                    try as.ldp(e.reg(v), e.tagReg(v), s0, @intCast(idx * 16));
                } else {
                    try as.movImm(.x, s1, idx * 16);
                    try as.add(.x, s0, s0, s1);
                    try as.ldp(e.reg(v), e.tagReg(v), s0, 0);
                }
                try as.b(done);
                as.bind(unit);
                try as.movImm(.x, e.reg(v), 0);
                try as.movImm(.x, e.tagReg(v), @intFromEnum(Tag.Unit));
                as.bind(done);
            },
            .array_size => {
                const d = e.reg(v);
                const arr = try e.operand(n.a, ta);
                try as.andImm(.x, s0, arr, 0xf);
                try as.cmpImm(.x, s0, @intCast(n.aux));
                try as.bCond(.ne, e.exitLabel(n.exit));
                try as.andImm(.x, s1, arr, ~@as(u64, 0xf));
                if (n.aux == 0) {
                    try e.load(.x, d, s1, e.lay.list_items + 8);
                } else {
                    const kind: runtime.PrimitiveArrayKind = @enumFromInt(n.aux - 1);
                    try e.load(.x, d, s1, e.lay.prim_items + 8);
                    try as.lsrImm(.x, d, d, std.math.log2_int(usize, kind.elemSize()));
                }
            },
            .class_is => {
                try e.load(.w, s0, try e.operand(n.a, ta), e.lay.inst_class);
                try e.cmpConst(s0, n.aux);
                try as.cset(.w, e.reg(v), .eq);
            },
        }
    }

    /// A store into a plain slot: a value that is no reference as it is; a reference into
    /// an old instance only once the instance is remembered (the write barrier's own work
    /// is the handler's), after a fence so the object is seen whole where it is published.
    fn setField(e: *Emitter, v: Id, n: graph.Node) Error!void {
        _ = v;
        const as = e.asm_();
        const slot: u32 = @intCast(n.aux & 0xffff_ffff);
        const obj = try e.operand(n.a, ta);
        const val = e.node(n.b);
        const word = try e.payload(n.b, s3);
        const store_l = try as.newLabel();
        if (val.repr == .word and @intFromEnum(val.tag) <= @intFromEnum(Tag.Bool)) {
            try as.movImm(.x, s1, @intFromEnum(val.tag));
        } else {
            const tag = if (val.repr == .pair) try e.tagOf(n.b, tb) else blk: {
                try as.movImm(.x, s1, @intFromEnum(val.tag));
                break :blk s1;
            };
            if (tag != s1) try as.mov(.x, s1, tag);
            const young = try as.newLabel();
            try as.andImm(.w, s2, s1, 0x3f);
            try as.cmpImm(.w, s2, @intFromEnum(Tag.Bool));
            try as.bCond(.ls, store_l);
            try as.ldr(.b, s2, obj, @intCast(e.lay.inst_gen));
            try as.cbz(.w, s2, young);
            try as.ldr(.b, s2, obj, @intCast(e.lay.inst_remembered));
            try as.cbz(.w, s2, e.exitLabel(n.exit));
            as.bind(young);
            try as.dmb(.ishst);
        }
        as.bind(store_l);
        try e.load(.x, s0, obj, e.lay.inst_slots);
        if (slot * 16 > 504) {
            try as.movImm(.x, s2, slot * 16);
            try as.add(.x, s0, s0, s2);
            try as.stp(word, s1, s0, 0);
        } else try as.stp(word, s1, s0, @intCast(slot * 16));
    }

    /// Exit `x`: its slots to the frame, the spin counter and the frame
    /// back, then the baseline's code at its op.
    fn exitCode(e: *Emitter, x: u32, target: A.Label) Error!void {
        const as = e.asm_();
        const ex = e.g.exits.items[x];
        if (e.lay.exit_counts) |c| try e.count(&c[x]);
        if (ex.bounce) try e.spendBudget();
        for (ex.slots) |s| {
            const n = e.node(s.v);
            const at = s.reg * 16;
            try e.store(.x, try e.payload(s.v, s1), regs, at);
            if (n.repr == .pair) {
                try e.store(.x, try e.tagOf(s.v, s0), regs, at + e.lay.tag_off);
            } else {
                try as.movImm(.x, s0, @intFromEnum(n.tag));
                try e.store(.x, s0, regs, at + e.lay.tag_off);
            }
        }
        if (ex.span != no_id) try e.exitSpan(ex.span);
        try as.ldr(.x, s0, ctx, @intCast(e.lay.ctx_ev));
        try e.storeAt(s0, e.lay.ev_spin, spin);
        try e.popFrame();
        try as.b(target);
    }

    /// The frame's span = the one value `v` names (0: the one it holds already).
    fn exitSpan(e: *Emitter, v: Id) Error!void {
        const as = e.asm_();
        const n = e.node(v);
        if (n.op == .konst) {
            if (n.aux != 0) try e.m.storeFrameBytes(e.lay.frame_span, &spanBytes(e.g.spans.items[n.aux]));
            return;
        }
        const done = try as.newLabel();
        // Read before the stores, which make their words in `s0`.
        const r = try e.operand(v, s1);
        for (e.g.spans.items, 0..) |sp, id| {
            if (id == 0) continue;
            const other = try as.newLabel();
            try as.cmpImm(.w, r, @intCast(id));
            try as.bCond(.ne, other);
            try e.m.storeFrameBytes(e.lay.frame_span, &spanBytes(sp));
            try as.b(done);
            as.bind(other);
        }
        as.bind(done);
    }

    /// `s0` = the storage cell of list `n.a`, one that is no view of another collection;
    /// another leaves by `n.exit`.
    fn listStorage(e: *Emitter, n: graph.Node) Error!void {
        const as = e.asm_();
        const data = try e.operand(n.a, ta);
        try e.load(.x, s1, data, e.lay.list_data_backing);
        try as.cbnz(.x, s1, e.exitLabel(n.exit));
        try e.load(.x, s0, data, e.lay.list_data_items);
    }

    /// Element `n.b` of list `n.a` into pair `v`, as the baseline's `listRead` reads it: the
    /// storage's items and length between two equal even readings of its write sequence,
    /// and the element between two more.
    fn listGet(e: *Emitter, v: Id, n: graph.Node) Error!void {
        const as = e.asm_();
        const exit = e.exitLabel(n.exit);
        try e.listStorage(n);
        try as.addImm(.x, s3, s0, e.lay.list_seq);
        try as.ldar(.w, s2, s3);
        try as.tbnz(s2, 0, exit);
        try e.load(.x, s1, s0, e.lay.list_items + 8);
        try as.sxtw(s3, try e.operand(n.b, tb));
        try as.tbnz(s3, 63, exit);
        try as.cmp(.x, s3, s1);
        try as.bCond(.hs, exit);
        try as.lslImm(.x, s3, s3, 4);
        try e.load(.x, s1, s0, e.lay.list_items);
        try as.add(.x, s1, s1, s3);
        try as.dmb(.ishld);
        try e.load(.w, s3, s0, e.lay.list_seq);
        try as.cmp(.w, s3, s2);
        try as.bCond(.ne, exit);
        try as.ldp(e.reg(v), e.tagReg(v), s1, 0);
        try as.dmb(.ishld);
        try e.load(.w, s3, s0, e.lay.list_seq);
        try as.cmp(.w, s3, s2);
        try as.bCond(.ne, exit);
    }

    /// Whether a call leaves register `r` as it was.
    fn calleeSaved(r: Reg) bool {
        return @intFromEnum(r) >= @intFromEnum(Reg.x19) and @intFromEnum(r) <= @intFromEnum(Reg.x28);
    }

    /// A called intrinsic's body into pair `v`, as the baseline's `callHost` calls it: its
    /// arguments and its answer in memory below the stack pointer, the registers compiled
    /// code runs on and the values held across the call in registers it may change saved
    /// there too; a body that does not take its arguments leaves by `exit`.
    fn hostCall(e: *Emitter, v: Id, n: graph.Node) Error!void {
        const as = e.asm_();
        var saves: std.ArrayList(Reg) = .empty;
        var fsaves: std.ArrayList(A.V) = .empty;
        for (e.al.across[v]) |x| {
            const l = e.al.loc[x];
            if (e.isFloat(x)) {
                try fsaves.append(e.a, float_regs[l.word]);
                continue;
            }
            if (!calleeSaved(value_regs[l.word])) try saves.append(e.a, value_regs[l.word]);
            if (e.node(x).repr == .pair and !calleeSaved(value_regs[l.tag])) try saves.append(e.a, value_regs[l.tag]);
        }
        const nargs: u32 = n.kind;
        const dst_at: u32 = 16 * nargs;
        const save_at: u32 = dst_at + 16;
        const words: u32 = 4 + @as(u32, @intCast(saves.items.len + fsaves.items.len));
        const total = (save_at + 8 * words + 15) & ~@as(u32, 15);
        try as.subImm(.x, A.sp, A.sp, total);
        e.sp_adjust = total;
        defer e.sp_adjust = 0;
        const args = [3]Id{ n.a, n.b, n.c };
        for (args[0..nargs], 0..) |x, i| {
            const xn = e.node(x);
            const at: u32 = @intCast(16 * i);
            try as.str(.x, try e.payload(x, s0), A.sp, @intCast(at));
            const tag = if (xn.repr == .pair) try e.tagOf(x, s1) else blk: {
                try as.movImm(.x, s1, @intFromEnum(xn.tag));
                break :blk s1;
            };
            try as.str(.x, tag, A.sp, @intCast(at + e.lay.tag_off));
        }
        try as.stp(ctx, frame, A.sp, @intCast(save_at));
        try as.stp(regs, .x3, A.sp, @intCast(save_at + 16));
        var at: u32 = save_at + 32;
        for (saves.items) |r| {
            try as.str(.x, r, A.sp, @intCast(at));
            at += 8;
        }
        for (fsaves.items) |f| {
            try as.strF(.d, f, A.sp, @intCast(at));
            at += 8;
        }
        try as.movImm(.x, .x1, n.ptr);
        try as.addImm(.x, .x2, A.sp, 0);
        try as.addImm(.x, .x3, A.sp, dst_at);
        try as.callAbs(n.aux, .x16);
        try as.andImm(.w, s0, .x0, 0xff);
        // The saved values back first: the exit reads some the answer's registers may hold.
        at = save_at + 32;
        for (saves.items) |r| {
            try as.ldr(.x, r, A.sp, @intCast(at));
            at += 8;
        }
        for (fsaves.items) |f| {
            try as.ldrF(.d, f, A.sp, @intCast(at));
            at += 8;
        }
        try as.ldp(regs, .x3, A.sp, @intCast(save_at + 16));
        try as.ldp(ctx, frame, A.sp, @intCast(save_at));
        const took = try as.newLabel();
        try as.cbnz(.w, s0, took);
        try as.addImm(.x, A.sp, A.sp, total);
        try as.b(e.exitLabel(n.exit));
        as.bind(took);
        try as.ldr(.x, e.reg(v), A.sp, @intCast(dst_at));
        try as.ldr(.x, e.tagReg(v), A.sp, @intCast(dst_at + e.lay.tag_off));
        try as.addImm(.x, A.sp, A.sp, total);
    }

    /// `s3` = `bytes` bumped out of the thread's region hole, `s2` the hole's record; leaves
    /// by `exit` when the hole has less room.
    fn bump(e: *Emitter, bytes: Reg, exit: A.Label) Error!void {
        const as = e.asm_();
        try e.load(.x, s2, ctx, e.lay.ctx_tlab);
        try e.load(.x, s3, s2, e.lay.tlab_cursor);
        try e.load(.x, s0, s2, e.lay.tlab_limit);
        try as.sub(.x, s0, s0, s3);
        try as.cmp(.x, s0, bytes);
        try as.bCond(.lo, exit);
        try as.add(.x, s0, s3, bytes);
        try e.store(.x, s0, s2, e.lay.tlab_cursor);
    }

    /// The template of `len` bytes at `image` copied to `[s3]`, through `s1`, `s2` and `t`.
    fn copyTemplate(e: *Emitter, image: u64, len: u32, t: Reg) Error!void {
        const as = e.asm_();
        try as.movImm(.x, s1, image);
        var off: u32 = 0;
        while (off < len) : (off += 16) {
            try as.ldp(s2, t, s1, @intCast(off));
            try as.stp(s2, t, s3, @intCast(off));
        }
    }

    /// A new instance into `v`, as the baseline's `newOp` makes it: its template copied into
    /// memory bumped out of the thread's region hole, its slots pointed after its cell.
    fn newInst(e: *Emitter, v: Id, n: graph.Node) Error!void {
        const as = e.asm_();
        const d = e.reg(v);
        try as.movImm(.x, s1, n.len);
        try e.bump(s1, e.exitLabel(n.exit));
        try e.copyTemplate(n.aux, n.len, s0);
        try as.addImm(.x, s0, s3, e.lay.inst_cell);
        try e.store(.x, s0, s3, e.lay.inst_slots);
        try as.mov(.x, d, s3);
    }

    /// A new primitive array into `v`, as the baseline's `primNewOp` makes it: its cell's
    /// template and its zeroed elements bumped out of the thread's region hole, the value
    /// its address with its kind's bits.
    fn newPrim(e: *Emitter, v: Id, n: graph.Node) Error!void {
        const as = e.asm_();
        const exit = e.exitLabel(n.exit);
        const d = e.reg(v);
        const kind: runtime.PrimitiveArrayKind = @enumFromInt(n.kind);
        const shift: u6 = @intCast(std.math.log2_int(usize, kind.elemSize()));
        const cell = e.lay.prim_cell;
        const size = e.node(n.a);
        // s0: the elements' bytes; d: the cell and the elements, rounded as the hole bumps.
        // The size is read before `d` is written, which may be its register.
        const known: ?u32 = if (size.op == .konst) blk: {
            const elems: i32 = @bitCast(@as(u32, @truncate(size.aux)));
            if (elems < 0 or (@as(u64, @intCast(elems)) << shift) > e.lay.prim_new_max) {
                try as.b(exit);
                return;
            }
            break :blk @as(u32, @intCast(elems)) << @intCast(shift);
        } else null;
        if (known) |bytes| {
            try as.movImm(.x, s0, bytes);
            try as.movImm(.x, d, (bytes + cell + 15) & ~@as(u32, 15));
        } else {
            try as.sxtw(s0, try e.operand(n.a, s0));
            try as.tbnz(s0, 63, exit);
            try as.cmpImm(.x, s0, @intCast(e.lay.prim_new_max >> @intCast(shift)));
            try as.bCond(.gt, exit);
            try as.lslImm(.x, s0, s0, shift);
            try as.addImm(.x, d, s0, cell + 15);
            try as.andImm(.x, d, d, ~@as(u64, 15));
        }
        // The bump keeps s0 in s1's stead: the elements' bytes go on in s1.
        try as.mov(.x, s1, s0);
        try e.load(.x, s2, ctx, e.lay.ctx_tlab);
        try e.load(.x, s3, s2, e.lay.tlab_cursor);
        try e.load(.x, s0, s2, e.lay.tlab_limit);
        try as.sub(.x, s0, s0, s3);
        try as.cmp(.x, s0, d);
        try as.bCond(.lo, exit);
        try as.add(.x, s0, s3, d);
        try e.store(.x, s0, s2, e.lay.tlab_cursor);
        // s0: the elements' bytes again; the template copied through s1, s2 and d.
        try as.mov(.x, s0, s1);
        try e.copyTemplate(n.aux, n.len, d);
        try as.addImm(.x, s2, s3, cell);
        try e.store(.x, s2, s3, e.lay.prim_items);
        try e.store(.x, s0, s3, e.lay.prim_items + 8);
        try e.store(.x, s0, s3, e.lay.prim_capacity);
        try e.store(.w, s0, s3, e.lay.prim_trailing);
        try as.addImm(.x, s2, s0, cell);
        try as.movImm(.x, s1, e.lay.region_bit);
        try as.orr(.x, s2, s2, s1);
        try e.store(.w, s2, s3, e.lay.prim_gc_bytes);
        // The elements and the rest of the rounding, zeroed: s1 up to s2.
        if (known) |bytes| {
            var off: u32 = cell;
            const end = (bytes + cell + 15) & ~@as(u32, 15);
            while (off < end) : (off += 16) {
                if (off <= 504) {
                    try as.stp(.zr, .zr, s3, @intCast(off));
                } else {
                    try as.movImm(.x, s1, off);
                    try as.add(.x, s1, s3, s1);
                    try as.stp(.zr, .zr, s1, 0);
                }
            }
        } else {
            try as.addImm(.x, s2, s0, cell + 15);
            try as.andImm(.x, s2, s2, ~@as(u64, 15));
            try as.add(.x, s2, s2, s3);
            try as.addImm(.x, s1, s3, cell);
            const loop = try as.newLabel();
            const done = try as.newLabel();
            as.bind(loop);
            try as.cmp(.x, s1, s2);
            try as.bCond(.hs, done);
            try as.stp(.zr, .zr, s1, 0);
            try as.addImm(.x, s1, s1, 16);
            try as.b(loop);
            as.bind(done);
        }
        try as.movImm(.x, s0, @intFromEnum(kind) + 1);
        try as.orr(.x, d, s3, s0);
    }

    /// Element `n.b` of array `n.a` into pair `v`, as the baseline's `arrayGet` reads it.
    fn arrayGet(e: *Emitter, v: Id, n: graph.Node) Error!void {
        const as = e.asm_();
        const exit = e.exitLabel(n.exit);
        const done = try as.newLabel();
        const arr = try e.operand(n.a, ta);
        const dp = e.reg(v);
        const dt = e.tagReg(v);
        try as.andImm(.x, s0, arr, 0xf);
        try as.andImm(.x, s1, arr, ~@as(u64, 0xf));
        try as.sxtw(s2, try e.operand(n.b, s2));
        try as.tbnz(s2, 63, exit);
        const Kind = struct { bits: u8, shift: u6, size: A.Size, tag: Tag };
        const kinds = [_]Kind{
            .{ .bits = 1, .shift = 2, .size = .w, .tag = .Int },
            .{ .bits = 2, .shift = 3, .size = .x, .tag = .Long },
            .{ .bits = 3, .shift = 3, .size = .x, .tag = .Double },
        };
        comptime std.debug.assert(@intFromEnum(@import("runtime").PrimitiveArrayKind.Int) + 1 == 1);
        comptime std.debug.assert(@intFromEnum(@import("runtime").PrimitiveArrayKind.Long) + 1 == 2);
        comptime std.debug.assert(@intFromEnum(@import("runtime").PrimitiveArrayKind.Double) + 1 == 3);
        for (kinds) |k| {
            const other = try as.newLabel();
            try as.cmpImm(.x, s0, k.bits);
            try as.bCond(.ne, other);
            try as.lslImm(.x, s3, s2, k.shift);
            try e.load(.x, dt, s1, e.lay.prim_items + 8);
            try as.cmp(.x, s3, dt);
            try as.bCond(.hs, exit);
            try e.load(.x, dt, s1, e.lay.prim_items);
            try as.ldrReg(k.size, dp, dt, s3, false);
            try as.movImm(.x, dt, @intFromEnum(k.tag));
            try as.b(done);
            as.bind(other);
        }
        // An `Array<T>`: its buffer never moves, so its element read between two equal even
        // readings of the sequence is one writer's.
        try as.cbnz(.x, s0, exit);
        try as.addImm(.x, s3, s1, e.lay.list_seq);
        try as.ldar(.w, s0, s3);
        try as.tbnz(s0, 0, exit);
        try e.load(.x, dt, s1, e.lay.list_items + 8);
        try as.cmp(.x, s2, dt);
        try as.bCond(.hs, exit);
        try e.load(.x, dt, s1, e.lay.list_items);
        try as.lslImm(.x, s2, s2, 4);
        try as.add(.x, s2, dt, s2);
        try as.ldp(dp, dt, s2, 0);
        try as.dmb(.ishld);
        try e.load(.w, s2, s1, e.lay.list_seq);
        try as.cmp(.w, s0, s2);
        try as.bCond(.ne, exit);
        as.bind(done);
    }

    /// One of the gate's bounces spent; the last shuts the gate.
    fn spendBudget(e: *Emitter) Error!void {
        const gate = e.lay.gate orelse return;
        const as = e.asm_();
        const left = try as.newLabel();
        try as.movImm(.x, s0, @intFromPtr(&gate.budget));
        try as.ldr(.w, s1, s0, 0);
        try as.subsImm(.w, s1, s1, 1);
        try as.str(.w, s1, s0, 0);
        try as.bCond(.ne, left);
        try as.movImm(.x, s0, @intFromPtr(&gate.on));
        try as.str(.w, .zr, s0, 0);
        as.bind(left);
    }

    /// The counter at `p` += 1.
    fn count(e: *Emitter, p: *u64) Error!void {
        const as = e.asm_();
        try as.movImm(.x, s0, @intFromPtr(p));
        try as.ldr(.x, s1, s0, 0);
        try as.addImm(.x, s1, s1, 1);
        try as.str(.x, s1, s0, 0);
    }

    /// Compares the Int in `r` with `k`, whatever its size.
    fn cmpConst(e: *Emitter, r: Reg, k: u64) Error!void {
        const as = e.asm_();
        if (k <= 4095) return as.cmpImm(.w, r, @intCast(k));
        try as.movImm(.x, s1, k);
        try as.cmp(.w, r, s1);
    }

    fn storeAt(e: *Emitter, base: Reg, off: u32, src: Reg) Error!void {
        try e.store(.x, src, base, off);
    }
};

/// Emits the loop's code: its entry at `entry_label`, going to `head_baseline` when the
/// entry's checks fail; `targets.of(pc)` is the baseline's label for the op an exit
/// leaves to.
pub fn emit(m: *masm.A64, a: std.mem.Allocator, g: *const Graph, al: regalloc.Alloc, lay: Layout, entry_label: A.Label, head_baseline: A.Label, targets: anytype) Error!void {
    var e: Emitter = .{
        .m = m,
        .a = a,
        .g = g,
        .al = al,
        .lay = lay,
        .labels = try a.alloc(A.Label, g.blocks.items.len),
        .exit_labels = try a.alloc(A.Label, g.exits.items.len),
        .fail_entry = try m.a.newLabel(),
        .uses = try a.alloc(u32, g.nodes.items.len),
    };
    @memset(e.uses, 0);
    for (g.nodes.items) |n| {
        if (n.forward != no_id) continue;
        inline for (.{ n.a, n.b, n.c }) |x| if (x != no_id) {
            e.uses[x] += 1;
        };
    }
    {
        var pit = g.phi_args.iterator();
        while (pit.next()) |pe| for (pe.value_ptr.*) |x| {
            e.uses[x] += 1;
        };
        for (g.exits.items) |*ex| {
            var it = ex.reads();
            while (it.next()) |x| e.uses[x] += 1;
        }
        for (g.blocks.items) |blk| if (blk.term == .branch) {
            e.uses[blk.term.branch.cond] += 1;
        };
    }
    for (e.labels) |*l| l.* = try m.a.newLabel();
    for (e.exit_labels) |*l| l.* = try m.a.newLabel();
    const as = &m.a;
    as.bind(entry_label);
    try e.entry();
    for (al.order, 0..) |b, i| {
        const blk = g.blocks.items[b];
        if (b != g.entry_block) as.bind(e.labels[b]);
        for (blk.nodes.items) |v| {
            try e.nodeCode(v);
            const n = g.nodes.items[v];
            if (al.loc[v].spill != regalloc.no_spill and n.op != .phi and !e.fusedCompare(v)) try e.storeHome(v);
        }
        const next: ?u32 = if (i + 1 < al.order.len) al.order[i + 1] else null;
        switch (blk.term) {
            .jump => |t| {
                try e.phiMoves(b, t);
                if (next == null or next.? != t) try as.b(e.labels[t]);
            },
            .branch => |br| {
                const fused = e.fusedCompare(br.cond);
                if (!fused and regalloc.remade(g.nodes.items[br.cond])) {
                    // A branch on a constant goes one way.
                    const to = if (g.nodes.items[br.cond].aux != 0) br.t else br.f;
                    if (next == null or next.? != to) try as.b(e.labels[to]);
                    continue;
                }
                if (next != null and next.? == br.t) {
                    // Falls through to the taken edge.
                    if (fused) try e.compareBranch(br.cond, e.labels[br.f], false) else try as.cbz(.w, try e.operand(br.cond, ta), e.labels[br.f]);
                } else {
                    if (fused) try e.compareBranch(br.cond, e.labels[br.t], true) else try as.cbnz(.w, try e.operand(br.cond, ta), e.labels[br.t]);
                    if (next == null or next.? != br.f) try as.b(e.labels[br.f]);
                }
            },
            .leave => |x| try as.b(e.exit_labels[x]),
            .open => unreachable,
        }
    }
    // Exits and the failed entry, out of the loop's way: those something leaves by (a
    // value a pass removed takes its exit with it).
    const taken = try a.alloc(bool, g.exits.items.len);
    @memset(taken, false);
    for (g.blocks.items) |blk| {
        for (blk.nodes.items) |v| if (g.nodes.items[v].exit != graph.no_exit) {
            taken[g.nodes.items[v].exit] = true;
        };
        if (blk.term == .leave) taken[blk.term.leave] = true;
    }
    for (g.exits.items, 0..) |ex, x| {
        if (!taken[x]) continue;
        as.bind(e.exit_labels[x]);
        try e.exitCode(@intCast(x), targets.of(ex.pc));
    }
    as.bind(e.fail_entry);
    if (lay.exit_counts) |c| try e.count(&c[g.exits.items.len]);
    try e.spendBudget();
    try e.popFrame();
    try as.b(head_baseline);
}
