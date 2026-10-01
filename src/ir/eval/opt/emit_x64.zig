//! x86-64 code for a loop's graph (`graph.zig`), as `emit.zig` makes AArch64
//! code: the values in the registers `regalloc.zig` gave them or in its stack
//! slots. The code pushes the registers it uses, the context's and the
//! frame's among them (values take those two; the code keeps their pointers
//! in its own stack), and leaves the registers compiled code runs on as they
//! were. Its entry loads the loop's live registers from the frame and checks
//! the kinds the code relies on, going to the baseline's head when one
//! differs; every exit writes the root registers the frame must hold, gives
//! the registers back, and jumps to the baseline's code for the op it leaves
//! to. The thread's spin counter stays in its record.

const std = @import("std");
const runtime = @import("runtime");
const jit = @import("jit");
const ir = @import("../../ir.zig");
const kinds_mod = @import("../kinds.zig");
const masm = @import("../masm.zig");
const graph = @import("graph.zig");
const regalloc = @import("regalloc.zig");
const common = @import("emit.zig");

const X = jit.x64;
const Reg = X.Reg;
const XR = X.X;
const Mem = X.Mem;
const Cond = X.Cond;
const Graph = graph.Graph;
const Id = graph.Id;
const no_id = graph.no_id;
const Tag = graph.Tag;

pub const Error = masm.Error || std.mem.Allocator.Error;
pub const Layout = common.Layout;

/// The registers values are given, by `regalloc.Loc` index: the ones a call keeps first,
/// then the context's and the frame's, which the code keeps in its stack instead.
pub const value_regs = [_]Reg{ .rbx, .rbp, .r12, .r13, .r14, .r15, .rdi, .rsi };
/// The registers Doubles are given, which a call does not keep.
pub const float_regs = [_]XR{ .xmm2, .xmm3, .xmm4, .xmm5, .xmm6, .xmm7, .xmm8, .xmm9, .xmm10, .xmm11, .xmm12, .xmm13 };

/// The context and the frame as the code is entered; the frame's registers throughout.
const ctx: Reg = .rdi;
const frame: Reg = .rsi;
const regs: Reg = .rdx;
/// Scratch.
const s0: Reg = .rax;
const s1: Reg = .r10;
const s2: Reg = .r11;
const s3: Reg = .r8;
/// Operands read from memory, a node's first and second; the second is the shift count's
/// register, and holds the code while compiled code runs (pushed at the entry).
const ta: Reg = .r9;
const tb: Reg = .rcx;
const fa: XR = .xmm0;
const fb: XR = .xmm1;
/// A slot's 16 bytes, whole.
const p0: XR = .xmm15;
const p1: XR = .xmm14;
/// Pushed at the entry, in order: the code register, the context, the frame, then the
/// registers calls keep.
const saved = [_]Reg{ .rcx, .rdi, .rsi, .rbx, .rbp, .r12, .r13, .r14, .r15 };
/// The code's stack below the pushes, aligned to 16: the thread's eval record, the stack
/// pointer before the alignment, the context, the frame, then the values' slots.
const local_ev: u32 = 0;
const local_sp: u32 = 8;
const local_ctx: u32 = 16;
const local_frame: u32 = 24;
const local_spills: u32 = 32;

fn at(base: Reg, off: u32) Mem {
    return Mem.at(base, @intCast(off));
}

const Emitter = struct {
    m: *masm.X64,
    a: std.mem.Allocator,
    g: *const Graph,
    al: regalloc.Alloc,
    lay: Layout,
    labels: []X.Label,
    exit_labels: []X.Label,
    fail_entry: X.Label,
    uses: []u32,
    /// The bytes the stack pointer is below the code's locals: a host call's area while it
    /// is made, else 0.
    sp_adjust: u32 = 0,

    fn asm_(e: *Emitter) *X.Asm {
        return &e.m.a;
    }

    fn reg(e: *const Emitter, v: Id) Reg {
        return value_regs[e.al.loc[v].word];
    }

    fn tagReg(e: *const Emitter, v: Id) Reg {
        return value_regs[e.al.loc[v].tag];
    }

    fn freg(e: *const Emitter, v: Id) XR {
        return float_regs[e.al.loc[v].word];
    }

    fn isFloat(e: *const Emitter, v: Id) bool {
        return regalloc.isFloat(e.node(v));
    }

    fn inMemory(e: *const Emitter, v: Id) bool {
        return e.al.loc[v].inMemory();
    }

    /// The code's own stack at `off` past the stack pointer as the loop runs.
    fn local(e: *const Emitter, off: u32) Mem {
        return at(.rsp, e.sp_adjust + off);
    }

    fn localsBytes(e: *const Emitter) u32 {
        return local_spills + 16 * @as(u32, e.al.spills);
    }

    /// Where value `v`, in memory, keeps its word: its root register in the frame, or its
    /// stack slot.
    fn homeWord(e: *const Emitter, v: Id) Mem {
        const l = e.al.loc[v];
        if (l.frame) return at(regs, @as(u32, @intCast(e.node(v).aux)) * 16);
        return e.local(local_spills + 16 * @as(u32, l.spill));
    }

    fn homeTag(e: *const Emitter, v: Id) Mem {
        const l = e.al.loc[v];
        if (l.frame) return at(regs, @as(u32, @intCast(e.node(v).aux)) * 16 + e.lay.tag_off);
        return e.local(local_spills + 16 * @as(u32, l.spill) + 8);
    }

    fn node(e: *const Emitter, v: Id) graph.Node {
        return e.g.nodes.items[v];
    }

    /// The width a word of tag `t` computes in.
    fn width(t: Tag) X.W {
        return switch (t) {
            .Int, .Bool, .Char, .Short, .Byte => .d,
            else => .q,
        };
    }

    /// A general register holding value `v`'s payload word: its own, or `tmp` for a
    /// Double's bits, a constant, or an entry value read from the frame.
    fn payload(e: *Emitter, v: Id, tmp: Reg) Error!Reg {
        if (regalloc.remade(e.node(v)) or e.inMemory(v)) return e.operand(v, tmp);
        if (!e.isFloat(v)) return e.reg(v);
        try e.asm_().movFromX(.q, tmp, e.freg(v));
        return tmp;
    }

    /// A general register holding word `v`: its own, or `tmp` with a constant made in it or
    /// an entry value read from the frame (a Bool's low byte, an Int's low word).
    fn operand(e: *Emitter, v: Id, tmp: Reg) Error!Reg {
        const as = e.asm_();
        const n = e.node(v);
        if (e.inMemory(v)) {
            const m = e.homeWord(v);
            if (n.repr == .word and n.tag == .Bool) {
                try as.loadU8(tmp, m);
            } else try as.load(if (n.repr == .word) width(n.tag) else .q, tmp, m);
            return tmp;
        }
        if (!regalloc.remade(n)) return e.reg(v);
        try as.movImm(tmp, n.aux);
        return tmp;
    }

    /// A general register holding pair `v`'s tag word: its own, or `tmp` read from the frame.
    fn tagOf(e: *Emitter, v: Id, tmp: Reg) Error!Reg {
        if (!e.inMemory(v)) return e.tagReg(v);
        try e.asm_().load(.q, tmp, e.homeTag(v));
        return tmp;
    }

    /// A floating register holding Double `v`: its own, or `tmp` read from the frame.
    fn fregIn(e: *Emitter, v: Id, tmp: XR) Error!XR {
        if (!e.inMemory(v)) return e.freg(v);
        try e.asm_().movsdLoad(true, tmp, e.homeWord(v));
        return tmp;
    }

    /// Value `v`, made in its registers, stored to its stack slot.
    fn storeHome(e: *Emitter, v: Id) Error!void {
        const as = e.asm_();
        const n = e.node(v);
        if (e.isFloat(v)) return as.movsdStore(true, e.homeWord(v), e.freg(v));
        try as.store(.q, e.homeWord(v), e.reg(v));
        if (n.repr == .pair) try as.store(.q, e.homeTag(v), e.tagReg(v));
    }

    /// The pushes, then the code's stack, aligned whatever the stack was.
    fn pushFrame(e: *Emitter) Error!void {
        const as = e.asm_();
        for (saved) |r| try as.push(r);
        try as.mov(.q, s2, .rsp);
        try as.andImm(.q, .rsp, -16);
        try as.subImm(.q, .rsp, @intCast(e.localsBytes()));
        try as.store(.q, at(.rsp, local_sp), s2);
        try as.store(.q, at(.rsp, local_ctx), ctx);
        try as.store(.q, at(.rsp, local_frame), frame);
    }

    fn popFrame(e: *Emitter) Error!void {
        const as = e.asm_();
        try as.load(.q, .rsp, at(.rsp, local_sp));
        var i = saved.len;
        while (i > 0) {
            i -= 1;
            try as.pop(saved[i]);
        }
    }

    /// `d = x`, the whole register.
    fn mov(e: *Emitter, d: Reg, x: Reg) Error!void {
        if (d != x) try e.asm_().mov(.q, d, x);
    }

    /// `dst`'s tag, masked to its kind, compared with `t`, in `s0`.
    fn cmpTag(e: *Emitter, tag: Reg, t: Tag) Error!void {
        const as = e.asm_();
        try as.mov(.d, s0, tag);
        try as.andImm(.d, s0, 0x3f);
        try as.cmpImm(.d, s0, @intFromEnum(t));
    }

    /// `d` = 1 where condition `c` holds, else 0.
    fn setBool(e: *Emitter, c: Cond, d: Reg) Error!void {
        const as = e.asm_();
        try as.setcc(c, s0);
        try as.movzx(.b, d, s0);
    }

    fn entry(e: *Emitter) Error!void {
        const as = e.asm_();
        try e.pushFrame();
        try as.load(.q, s0, at(ctx, e.lay.ctx_ev));
        try as.store(.q, e.local(local_ev), s0);
        if (e.g.calls_in_place) {
            // A call a callee in place stands for would throw past the eval depth's bound:
            // the deepest must fit, as the depth cannot change while the loop runs.
            try as.load(.q, s1, at(s0, e.lay.ev_depth));
            try as.addImm(.q, s1, @intCast(e.g.max_level));
            try as.cmpLoad(.q, s1, at(s0, e.lay.ev_depth_cap));
            try as.jcc(.ge, e.fail_entry);
        }
        const b0 = e.g.blocks.items[e.g.entry_block];
        for (b0.nodes.items) |v| {
            const n = e.node(v);
            if (n.op != .entry) continue;
            const r: u32 = @intCast(n.aux);
            const off = r * 16;
            const framed = e.inMemory(v);
            switch (n.repr) {
                .pair => if (!framed) {
                    try as.load(.q, e.reg(v), at(regs, off));
                    try as.load(.q, e.tagReg(v), at(regs, off + e.lay.tag_off));
                },
                .word => {
                    try as.load(.d, s0, at(regs, off + e.lay.tag_off));
                    try as.andImm(.d, s0, 0x3f);
                    try as.cmpImm(.d, s0, @intFromEnum(n.tag));
                    try as.jcc(.ne, e.fail_entry);
                    if (framed) {} else if (n.tag == .Bool) {
                        try as.loadU8(e.reg(v), at(regs, off));
                    } else if (n.tag == .Double) {
                        try as.movsdLoad(true, e.freg(v), at(regs, off));
                    } else try as.load(width(n.tag), e.reg(v), at(regs, off));
                    const k: kinds_mod.Kind = @intCast(n.variable);
                    if (kinds_mod.isInstFact(k)) {
                        const obj = try e.operand(v, s1);
                        const slots = kinds_mod.factSlots(k);
                        if (slots != 0) {
                            try as.cmpMemImm(.q, at(obj, e.lay.inst_slots + 8), @intCast(slots));
                            try as.jcc(.l, e.fail_entry);
                        }
                        if (kinds_mod.factPlain(k)) {
                            try as.load(.d, s0, at(obj, e.lay.inst_seq));
                            try as.testImm(.d, s0, @bitCast(@as(u32, 1 << 31)));
                            try as.jcc(.e, e.fail_entry);
                        }
                    }
                },
                .none => {},
            }
        }
    }

    /// A place a parameter's value moves between: general registers by number, floating
    /// ones past 16, and past 32 the halves of the stack slots (a slot's word, then its tag).
    const Loc = u16;
    fn gp(r: Reg) Loc {
        return @intFromEnum(r);
    }
    fn fp(v: XR) Loc {
        return 16 + @as(u16, @intFromEnum(v));
    }
    fn slotWord(e: *const Emitter, v: Id) Loc {
        return 32 + 2 * @as(u16, e.al.loc[v].spill);
    }
    fn slotTag(e: *const Emitter, v: Id) Loc {
        return 33 + 2 * @as(u16, e.al.loc[v].spill);
    }
    fn slotMem(e: *const Emitter, l: Loc) Mem {
        return e.local(local_spills + 8 * @as(u32, l - 32));
    }
    /// Where value `v`'s word is, as a place: its register or its stack slot's word.
    fn wordLoc(e: *const Emitter, v: Id) Loc {
        if (e.al.loc[v].spill != regalloc.no_spill) return e.slotWord(v);
        return if (e.isFloat(v)) fp(e.freg(v)) else gp(e.reg(v));
    }
    fn tagLoc(e: *const Emitter, v: Id) Loc {
        if (e.al.loc[v].spill != regalloc.no_spill) return e.slotTag(v);
        return gp(e.tagReg(v));
    }

    const Width = enum { b, d, q };
    /// A move into a place: from another, of a constant, or a load from the frame at `at`
    /// of width `w`.
    const Move = struct { dst: Loc, src: ?Loc, imm: u64 = 0, at: ?u32 = null, w: Width = .q };

    /// The moves an edge from `from` to `to` makes into `to`'s parameters, as one parallel
    /// copy (`emit.zig`'s), its places registers and stack slots alike.
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
                const off = @as(u32, @intCast(xn.aux)) * 16;
                const w: Width = if (xn.repr == .pair) .q else if (xn.tag == .Bool) .b else if (width(xn.tag) == .d) .d else .q;
                try moves.append(e.a, .{ .dst = dst, .src = null, .at = off, .w = w });
                if (pn.repr == .pair) {
                    if (xn.repr == .pair) {
                        try moves.append(e.a, .{ .dst = e.tagLoc(p), .src = null, .at = off + e.lay.tag_off, .w = .q });
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
                const park: Loc = if (src >= 16 and src < 32) fp(fa) else gp(s0);
                try e.move(.{ .dst = park, .src = src });
                for (pending) |*o| if (o.src != null and o.src.? == src) {
                    o.src = park;
                };
            }
        }
    }

    /// One move; one between two stack slots, or of a constant or a frame word into one,
    /// goes through `s2`, which no parked source is in.
    fn move(e: *Emitter, mv: Move) Error!void {
        const as = e.asm_();
        const dst = mv.dst;
        const to_mem = dst >= 32;
        const to_float = dst >= 16 and dst < 32;
        if (mv.at) |off| {
            if (to_float) return as.movsdLoad(true, @enumFromInt(dst - 16), at(regs, off));
            const into: Reg = if (to_mem) s2 else @enumFromInt(dst);
            switch (mv.w) {
                .b => try as.loadU8(into, at(regs, off)),
                .d => try as.load(.d, into, at(regs, off)),
                .q => try as.load(.q, into, at(regs, off)),
            }
            if (to_mem) try as.store(.q, e.slotMem(dst), s2);
            return;
        }
        const s = mv.src orelse {
            if (to_float or to_mem) {
                try as.movImm(s2, mv.imm);
                if (to_mem) return as.store(.q, e.slotMem(dst), s2);
                return as.movToX(.q, @enumFromInt(dst - 16), s2);
            }
            return as.movImm(@enumFromInt(dst), mv.imm);
        };
        const from_mem = s >= 32;
        const from_float = s >= 16 and s < 32;
        if (to_mem) {
            if (from_float) return as.movsdStore(true, e.slotMem(dst), @enumFromInt(s - 16));
            if (from_mem) {
                try as.load(.q, s2, e.slotMem(s));
                return as.store(.q, e.slotMem(dst), s2);
            }
            return as.store(.q, e.slotMem(dst), @enumFromInt(s));
        }
        if (to_float) {
            if (from_mem) return as.movsdLoad(true, @enumFromInt(dst - 16), e.slotMem(s));
            if (from_float) return as.movapd(@enumFromInt(dst - 16), @enumFromInt(s - 16));
            return as.movToX(.q, @enumFromInt(dst - 16), @enumFromInt(s));
        }
        if (from_mem) return as.load(.q, @enumFromInt(dst), e.slotMem(s));
        if (from_float) return as.movFromX(.q, @enumFromInt(dst), @enumFromInt(s - 16));
        return as.mov(.q, @enumFromInt(dst), @enumFromInt(s));
    }

    fn exitLabel(e: *const Emitter, x: u32) X.Label {
        return e.exit_labels[x];
    }

    /// The condition of an integer compare `bop`.
    fn intCond(bop: ir.BinOp) Cond {
        return switch (bop) {
            .Eq => .e,
            .NotEq => .ne,
            .Less => .l,
            .LessEq => .le,
            .Greater => .g,
            .GreaterEq => .ge,
            else => unreachable,
        };
    }

    /// A Double compare `bop` of `l` and `r` as flags: the operands in the order that makes
    /// an order compare an "above" (false for NaN, which leaves the carry set); equality's
    /// flags want the parity clear too.
    fn floatCompare(e: *Emitter, bop: ir.BinOp, l: XR, r: XR) Error!Cond {
        const as = e.asm_();
        switch (bop) {
            .Less => {
                try as.ucomisd(true, r, l);
                return .a;
            },
            .LessEq => {
                try as.ucomisd(true, r, l);
                return .ae;
            },
            .Greater => {
                try as.ucomisd(true, l, r);
                return .a;
            },
            .GreaterEq => {
                try as.ucomisd(true, l, r);
                return .ae;
            },
            .Eq, .NotEq => {
                try as.ucomisd(true, l, r);
                return if (bop == .Eq) .e else .ne;
            },
            else => unreachable,
        }
    }

    fn fusedCompare(e: *const Emitter, v: Id) bool {
        const n = e.node(v);
        if ((n.op != .cmp and n.op != .class_is) or e.uses[v] != 1) return false;
        const blk = e.g.blocks.items[n.block];
        if (blk.term != .branch or blk.term.branch.cond != v) return false;
        return blk.nodes.items[blk.nodes.items.len - 1] == v;
    }

    /// A branch on compare `v` to `t` where it answers `taken`, falling through else.
    fn compareBranch(e: *Emitter, v: Id, t: X.Label, taken: bool) Error!void {
        const as = e.asm_();
        const n = e.node(v);
        if (n.op == .class_is) {
            try as.cmpMemImm(.d, at(try e.operand(n.a, ta), e.lay.inst_class), @intCast(n.aux));
            return as.jcc(if (taken) .e else .ne, t);
        }
        const bop: ir.BinOp = @enumFromInt(n.aux & 0xff);
        const tag: Tag = @enumFromInt(n.aux >> 8);
        if (tag != .Double) {
            try as.cmp(width(tag), try e.operand(n.a, s0), try e.operand(n.b, s1));
            const c = intCond(bop);
            return as.jcc(if (taken) c else c.invert(), t);
        }
        const c = try e.floatCompare(bop, try e.fregIn(n.a, fa), try e.fregIn(n.b, fb));
        // Equal: zero set and parity clear; its negation (NaN included) the rest.
        const equal_wanted = (bop == .Eq) == taken;
        if (bop == .Eq or bop == .NotEq) {
            if (equal_wanted) {
                const skip = try as.newLabel();
                try as.jcc(.p, skip);
                try as.jcc(.e, t);
                as.bind(skip);
            } else {
                try as.jcc(.ne, t);
                try as.jcc(.p, t);
            }
            return;
        }
        // An order compare's inverse is true for NaN, as the compare's negation is.
        try as.jcc(if (taken) c else c.invert(), t);
    }

    fn nodeCode(e: *Emitter, v: Id) Error!void {
        const as = e.asm_();
        const n = e.node(v);
        if (e.fusedCompare(v)) return;
        switch (n.op) {
            .entry, .phi => {},
            .konst => if (e.isFloat(v)) {
                try as.movImm(s0, n.aux);
                try as.movToX(.q, e.freg(v), s0);
            },
            .unbox => if (e.isFloat(v)) {
                try as.movToX(.q, e.freg(v), try e.payload(n.a, s0));
            } else try e.mov(e.reg(v), try e.payload(n.a, s0)),
            .box => {
                try e.mov(e.reg(v), try e.payload(n.a, s0));
                try as.movImm(e.tagReg(v), @intFromEnum(n.tag));
            },
            .check_tag => {
                if (e.node(n.a).repr == .word) {
                    // A word of another tag (one of its own is the word itself, `simplify`).
                    try as.jmp(e.exitLabel(n.exit));
                    return;
                }
                try e.cmpTag(try e.tagOf(n.a, ta), n.tag);
                try as.jcc(.ne, e.exitLabel(n.exit));
                const word = try e.operand(n.a, tb);
                if (n.tag == .Bool) {
                    try as.movzx(.b, e.reg(v), word);
                } else if (n.tag == .Double) {
                    try as.movToX(.q, e.freg(v), word);
                } else try e.mov(e.reg(v), word);
            },
            .arith => try e.arith(v, n),
            .cmp => {
                const bop: ir.BinOp = @enumFromInt(n.aux & 0xff);
                const t: Tag = @enumFromInt(n.aux >> 8);
                const d = e.reg(v);
                if (t != .Double) {
                    try as.cmp(width(t), try e.operand(n.a, s0), try e.operand(n.b, s1));
                    return e.setBool(intCond(bop), d);
                }
                const c = try e.floatCompare(bop, try e.fregIn(n.a, fa), try e.fregIn(n.b, fb));
                if (bop == .Eq or bop == .NotEq) {
                    // Equal: zero set and parity clear.
                    try as.setcc(if (bop == .Eq) .e else .ne, s0);
                    try as.setcc(if (bop == .Eq) .np else .p, s1);
                    if (bop == .Eq) try as.@"and"(.d, s0, s1) else try as.@"or"(.d, s0, s1);
                    return as.movzx(.b, d, s0);
                }
                try e.setBool(c, d);
            },
            .conv => try e.conv(v, n),
            .step => {
                const w = width(n.tag);
                const d = e.reg(v);
                const x = try e.operand(n.a, s0);
                if (d != x) try as.mov(w, d, x);
                if (n.aux == 1) try as.addImm(w, d, 1) else try as.subImm(w, d, 1);
            },
            .check_slots => {
                try as.cmpMemImm(.q, at(try e.operand(n.a, ta), e.lay.inst_slots + 8), @intCast(n.aux & 0xffff_ffff));
                try as.jcc(.le, e.exitLabel(n.exit));
            },
            .check_plain => {
                try as.load(.d, s0, at(try e.operand(n.a, ta), e.lay.inst_seq));
                try as.testImm(.d, s0, @bitCast(@as(u32, 1 << 31)));
                try as.jcc(.e, e.exitLabel(n.exit));
            },
            .get_field => {
                const slot: u32 = @intCast(n.aux & 0xffff_ffff);
                try as.load(.q, s0, at(try e.operand(n.a, ta), e.lay.inst_slots));
                try e.loadPair(e.reg(v), e.tagReg(v), s0, slot * 16);
            },
            .set_field => try e.setField(n),
            .check_poll => {
                const exit = e.exitLabel(n.exit);
                try as.load(.q, s0, e.local(local_ev));
                try as.load(.q, s1, at(s0, e.lay.ev_spin));
                try as.addImm(.q, s1, 1);
                try as.testImm(.d, s1, 0xffff);
                try as.jcc(.e, exit);
                try as.movImm(s2, e.lay.edge_flags);
                try as.cmpMemImm(.d, at(s2, 0), 0);
                try as.jcc(.ne, exit);
                try as.store(.q, at(s0, e.lay.ev_spin), s1);
            },
            .check_class => {
                try as.cmpMemImm(.d, at(try e.operand(n.a, ta), e.lay.inst_class), @intCast(n.aux));
                try as.jcc(.ne, e.exitLabel(n.exit));
            },
            .class_is => {
                try as.cmpMemImm(.d, at(try e.operand(n.a, ta), e.lay.inst_class), @intCast(n.aux));
                try e.setBool(.e, e.reg(v));
            },
            .array_get => try e.arrayGet(v, n),
            .new_inst => try e.newInst(v, n),
            .init_field => {
                // Nothing else sees the instance yet: two plain stores.
                const off = e.lay.inst_cell + @as(u32, @intCast(n.aux)) * 16;
                const val = e.node(n.b);
                const obj = try e.operand(n.a, ta);
                try as.store(.q, at(obj, off), try e.payload(n.b, s0));
                if (val.repr == .pair) {
                    try as.store(.q, at(obj, off + e.lay.tag_off), try e.tagOf(n.b, s1));
                } else try as.storeImm(.q, at(obj, off + e.lay.tag_off), @intFromEnum(val.tag));
            },
            .new_prim => try e.newPrim(v, n),
            .check_not_null => {
                try e.cmpTag(try e.tagOf(n.a, ta), .Null);
                try as.jcc(.e, e.exitLabel(n.exit));
            },
            .is_null => {
                try e.cmpTag(try e.tagOf(n.a, ta), .Null);
                try e.setBool(if (n.aux == 1) .ne else .e, e.reg(v));
            },
            .check_nonzero => {
                const x = try e.operand(n.a, ta);
                try as.@"test"(width(n.tag), x, x);
                try as.jcc(.e, e.exitLabel(n.exit));
            },
            .host_call => try e.hostCall(v, n),
            .list_get => try e.listGet(v, n),
            .list_size => {
                try e.listStorage(n);
                try as.load(.q, e.reg(v), at(s0, e.lay.list_items + 8));
            },
            .check_closure => {
                try as.movImm(s1, n.aux);
                try as.cmpLoad(.q, s1, at(try e.operand(n.a, ta), e.lay.closure_body));
                try as.jcc(.ne, e.exitLabel(n.exit));
            },
            .capture => {
                // Past the captures, `Unit`, as the lambda's frame reads it.
                const clo = try e.operand(n.a, ta);
                const unit = try as.newLabel();
                const done = try as.newLabel();
                const idx: u32 = @intCast(n.aux);
                try as.cmpMemImm(.q, at(clo, e.lay.closure_captures + 8), @intCast(idx));
                try as.jcc(.be, unit);
                try as.load(.q, s0, at(clo, e.lay.closure_captures));
                try as.load(.q, e.reg(v), at(s0, idx * 16));
                try as.load(.q, e.tagReg(v), at(s0, idx * 16 + e.lay.tag_off));
                try as.jmp(done);
                as.bind(unit);
                try as.movImm(e.reg(v), 0);
                try as.movImm(e.tagReg(v), @intFromEnum(Tag.Unit));
                as.bind(done);
            },
            .array_size => {
                const d = e.reg(v);
                const arr = try e.operand(n.a, ta);
                try as.mov(.q, s0, arr);
                try as.andImm(.q, s0, 0xf);
                try as.cmpImm(.q, s0, @intCast(n.aux));
                try as.jcc(.ne, e.exitLabel(n.exit));
                try as.mov(.q, s1, arr);
                try as.andImm(.q, s1, -16);
                if (n.aux == 0) {
                    try as.load(.q, d, at(s1, e.lay.list_items + 8));
                } else {
                    const kind: runtime.PrimitiveArrayKind = @enumFromInt(n.aux - 1);
                    try as.load(.q, d, at(s1, e.lay.prim_items + 8));
                    try as.shrImm(.q, d, std.math.log2_int(usize, kind.elemSize()));
                }
            },
        }
    }

    /// `d`, `t` = the 16 bytes at `[base + off]`, in one access.
    fn loadPair(e: *Emitter, d: Reg, t: Reg, base: Reg, off: u32) Error!void {
        const as = e.asm_();
        try as.movdqaLoad(p0, at(base, off));
        try as.movFromX(.q, d, p0);
        try as.punpckhqdq(p0, p0);
        try as.movFromX(.q, t, p0);
    }

    /// The 16 bytes at `[base + off]` = `w`, `t`, in one access.
    fn storePair(e: *Emitter, base: Reg, off: u32, w: Reg, t: Reg) Error!void {
        const as = e.asm_();
        try as.movToX(.q, p0, w);
        try as.movToX(.q, p1, t);
        try as.punpcklqdq(p0, p1);
        try as.movdqaStore(at(base, off), p0);
    }

    fn arith(e: *Emitter, v: Id, n: graph.Node) Error!void {
        const as = e.asm_();
        const bop: ir.BinOp = @enumFromInt(n.aux & 0xff);
        if (n.tag == .Double) {
            const fd = e.freg(v);
            const fl = try e.fregIn(n.a, fa);
            var fr = try e.fregIn(n.b, fb);
            if (fd == fr and fd != fl) {
                // `fd` is written before the right operand is read.
                try as.movapd(fb, fr);
                fr = fb;
            }
            if (fd != fl) try as.movapd(fd, fl);
            switch (bop) {
                .Add => try as.addsd(true, fd, fr),
                .Sub => try as.subsd(true, fd, fr),
                .Mul => try as.mulsd(true, fd, fr),
                .Div => try as.divsd(true, fd, fr),
                else => unreachable,
            }
            return;
        }
        const d = e.reg(v);
        const l = try e.operand(n.a, s0);
        var r = try e.operand(n.b, s1);
        const w = width(n.tag);
        switch (bop) {
            .Add, .Mul, .And, .Or, .Xor => {
                const other = if (d == r) l else r;
                if (d != r and d != l) try as.mov(.q, d, l);
                switch (bop) {
                    .Add => try as.add(w, d, other),
                    .Mul => try as.imul(w, d, other),
                    .And => try as.@"and"(w, d, other),
                    .Or => try as.@"or"(w, d, other),
                    .Xor => try as.xor(w, d, other),
                    else => unreachable,
                }
            },
            .Sub => {
                if (d == r and d != l) {
                    try as.mov(.q, s2, r);
                    r = s2;
                }
                if (d != l) try as.mov(.q, d, l);
                try as.sub(w, d, r);
            },
            .Shl, .Shr, .UShr => {
                // The count in `cl`, which the hardware masks as Kotlin's shifts do.
                try as.mov(.q, .rcx, r);
                if (d != l) try as.mov(.q, d, l);
                switch (bop) {
                    .Shl => try as.shlCl(w, d),
                    .Shr => try as.sarCl(w, d),
                    .UShr => try as.shrCl(w, d),
                    else => unreachable,
                }
            },
            .Div, .Mod => {
                // `idiv` takes the dividend in rax:rdx and traps on `MIN_VALUE / -1`,
                // which Kotlin answers `MIN_VALUE` (and 0 for the remainder).
                const minus_one = try as.newLabel();
                const done = try as.newLabel();
                try as.cmpImm(w, r, -1);
                try as.jcc(.e, minus_one);
                try as.mov(.q, s2, regs);
                if (l != s0) try as.mov(.q, s0, l);
                try as.signExtendAcc(w);
                try as.idiv(w, r);
                try as.mov(.q, d, if (bop == .Div) s0 else .rdx);
                try as.mov(.q, regs, s2);
                try as.jmp(done);
                as.bind(minus_one);
                if (bop == .Div) {
                    if (d != l) try as.mov(.q, d, l);
                    try as.neg(w, d);
                } else try as.xor(.d, d, d);
                as.bind(done);
            },
            else => unreachable,
        }
    }

    fn conv(e: *Emitter, v: Id, n: graph.Node) Error!void {
        const as = e.asm_();
        const from: Tag = @enumFromInt(n.aux);
        switch (from) {
            .Int => switch (n.tag) {
                .Long => try as.movsxd(e.reg(v), try e.operand(n.a, s0)),
                .Double => try as.cvtsi2sd(true, e.freg(v), .d, try e.operand(n.a, s0)),
                else => unreachable,
            },
            .Long => switch (n.tag) {
                .Int => try as.mov(.d, e.reg(v), try e.operand(n.a, s0)),
                .Double => try as.cvtsi2sd(true, e.freg(v), .q, try e.operand(n.a, s0)),
                else => unreachable,
            },
            .Double => {
                // As Kotlin's: NaN to 0, and past the range its bound. The processor answers
                // the least value for both, which the checks after sort out.
                const w = width(n.tag);
                const d = e.reg(v);
                const x = try e.fregIn(n.a, fa);
                const done = try as.newLabel();
                const nan = try as.newLabel();
                try as.cvttsd2si(true, w, d, x);
                if (w == .q) {
                    try as.movImm(s0, 1 << 63);
                    try as.cmp(.q, d, s0);
                } else try as.cmpImm(.d, d, std.math.minInt(i32));
                try as.jcc(.ne, done);
                try as.ucomisd(true, x, x);
                try as.jcc(.p, nan);
                try as.xorpd(fb, fb);
                try as.ucomisd(true, x, fb);
                try as.jcc(.be, done);
                try as.movImm(d, if (w == .q) std.math.maxInt(i64) else std.math.maxInt(i32));
                try as.jmp(done);
                as.bind(nan);
                try as.xor(.d, d, d);
                as.bind(done);
            },
            else => unreachable,
        }
    }

    /// A store into a plain slot, as `emit.zig`'s: a value no reference as it is, a
    /// reference into an old instance only once it is remembered. x86-64 keeps stores in
    /// order, so publication takes no fence.
    fn setField(e: *Emitter, n: graph.Node) Error!void {
        const as = e.asm_();
        const slot: u32 = @intCast(n.aux & 0xffff_ffff);
        const obj = try e.operand(n.a, ta);
        const val = e.node(n.b);
        const word = try e.payload(n.b, s3);
        const store_l = try as.newLabel();
        if (val.repr == .word and @intFromEnum(val.tag) <= @intFromEnum(Tag.Bool)) {
            try as.movImm(s1, @intFromEnum(val.tag));
        } else {
            if (val.repr == .pair) {
                try as.mov(.q, s1, try e.tagOf(n.b, tb));
            } else try as.movImm(s1, @intFromEnum(val.tag));
            const young = try as.newLabel();
            try as.mov(.d, s2, s1);
            try as.andImm(.d, s2, 0x3f);
            try as.cmpImm(.d, s2, @intFromEnum(Tag.Bool));
            try as.jcc(.be, store_l);
            try as.testMemImm8(at(obj, e.lay.inst_gen), 0xff);
            try as.jcc(.e, young);
            try as.testMemImm8(at(obj, e.lay.inst_remembered), 0xff);
            try as.jcc(.e, e.exitLabel(n.exit));
            as.bind(young);
        }
        as.bind(store_l);
        try as.load(.q, s0, at(obj, e.lay.inst_slots));
        try e.storePair(s0, slot * 16, word, s1);
    }

    /// Exit `x`: its slots to the frame, then, the frame's pointer back, the span, the
    /// registers back, and the baseline's code at its op.
    fn exitCode(e: *Emitter, x: u32, target: X.Label) Error!void {
        const as = e.asm_();
        const ex = e.g.exits.items[x];
        if (e.lay.exit_counts) |c| try e.count(&c[x]);
        if (ex.bounce) try e.spendBudget();
        for (ex.slots) |s| {
            const n = e.node(s.v);
            const off = s.reg * 16;
            try as.store(.q, at(regs, off), try e.payload(s.v, s1));
            if (n.repr == .pair) {
                try as.store(.q, at(regs, off + e.lay.tag_off), try e.tagOf(s.v, s0));
            } else try as.storeImm(.q, at(regs, off + e.lay.tag_off), @intFromEnum(n.tag));
        }
        // The span's value before the frame's register, which a value may hold, is set back.
        const span_reg: ?Reg = if (ex.span != no_id and e.node(ex.span).op != .konst) try e.operand(ex.span, s1) else null;
        if (span_reg) |r| if (r != s1) try as.mov(.q, s1, r);
        try as.load(.q, frame, e.local(local_frame));
        if (ex.span != no_id) try e.exitSpan(ex.span);
        try e.popFrame();
        try as.jmp(target);
    }

    /// The frame's span = the one value `v` names (0: the one it holds already), a value
    /// other than a constant read into `s1` before.
    fn exitSpan(e: *Emitter, v: Id) Error!void {
        const as = e.asm_();
        const n = e.node(v);
        if (n.op == .konst) {
            if (n.aux != 0) try e.m.storeFrameBytes(e.lay.frame_span, &common.spanBytes(e.g.spans.items[n.aux]));
            return;
        }
        const done = try as.newLabel();
        for (e.g.spans.items, 0..) |sp, id| {
            if (id == 0) continue;
            const other = try as.newLabel();
            try as.cmpImm(.d, s1, @intCast(id));
            try as.jcc(.ne, other);
            try e.m.storeFrameBytes(e.lay.frame_span, &common.spanBytes(sp));
            try as.jmp(done);
            as.bind(other);
        }
        as.bind(done);
    }

    /// `s0` = the storage cell of list `n.a`, one that is no view of another collection.
    fn listStorage(e: *Emitter, n: graph.Node) Error!void {
        const as = e.asm_();
        const data = try e.operand(n.a, ta);
        try as.cmpMemImm(.q, at(data, e.lay.list_data_backing), 0);
        try as.jcc(.ne, e.exitLabel(n.exit));
        try as.load(.q, s0, at(data, e.lay.list_data_items));
    }

    /// Element `n.b` of list `n.a` into pair `v`, between equal even readings of its storage's
    /// write sequence; x86-64 keeps loads in order, so the readings need no fence.
    fn listGet(e: *Emitter, v: Id, n: graph.Node) Error!void {
        const as = e.asm_();
        const exit = e.exitLabel(n.exit);
        try e.listStorage(n);
        try as.load(.d, s2, at(s0, e.lay.list_seq));
        try as.testImm(.d, s2, 1);
        try as.jcc(.ne, exit);
        try as.movsxd(s3, try e.operand(n.b, tb));
        try as.@"test"(.q, s3, s3);
        try as.jcc(.s, exit);
        try as.cmpLoad(.q, s3, at(s0, e.lay.list_items + 8));
        try as.jcc(.ae, exit);
        try as.shlImm(.q, s3, 4);
        try as.addLoad(.q, s3, at(s0, e.lay.list_items));
        try as.cmpLoad(.d, s2, at(s0, e.lay.list_seq));
        try as.jcc(.ne, exit);
        try as.load(.q, e.reg(v), at(s3, 0));
        try as.load(.q, e.tagReg(v), at(s3, 8));
        try as.cmpLoad(.d, s2, at(s0, e.lay.list_seq));
        try as.jcc(.ne, exit);
    }

    /// Whether a call leaves register `r` as it was.
    fn calleeSaved(r: Reg) bool {
        return switch (r) {
            .rbx, .rbp, .r12, .r13, .r14, .r15 => true,
            else => false,
        };
    }

    /// A called intrinsic's body into pair `v`, as `emit.zig`'s: its arguments and answer in
    /// memory below the stack pointer, the frame's registers and the values held across the
    /// call in registers it may change saved there too.
    fn hostCall(e: *Emitter, v: Id, n: graph.Node) Error!void {
        const as = e.asm_();
        var saves: std.ArrayList(Reg) = .empty;
        var fsaves: std.ArrayList(XR) = .empty;
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
        const words: u32 = 1 + @as(u32, @intCast(saves.items.len + fsaves.items.len));
        const total = (save_at + 8 * words + 15) & ~@as(u32, 15);
        try as.subImm(.q, .rsp, @intCast(total));
        e.sp_adjust = total;
        defer e.sp_adjust = 0;
        const args = [3]Id{ n.a, n.b, n.c };
        for (args[0..nargs], 0..) |x, i| {
            const xn = e.node(x);
            const off: u32 = @intCast(16 * i);
            try as.store(.q, at(.rsp, off), try e.payload(x, s0));
            if (xn.repr == .pair) {
                try as.store(.q, at(.rsp, off + e.lay.tag_off), try e.tagOf(x, s1));
            } else try as.storeImm(.q, at(.rsp, off + e.lay.tag_off), @intFromEnum(xn.tag));
        }
        try as.store(.q, at(.rsp, save_at), regs);
        var off: u32 = save_at + 8;
        for (saves.items) |r| {
            try as.store(.q, at(.rsp, off), r);
            off += 8;
        }
        for (fsaves.items) |f| {
            try as.movsdStore(true, at(.rsp, off), f);
            off += 8;
        }
        try as.load(.q, .rdi, e.local(local_ctx));
        try as.movImm(.rsi, n.ptr);
        try as.lea(.rdx, at(.rsp, 0));
        try as.lea(.rcx, at(.rsp, dst_at));
        try as.callAbs(n.aux);
        try as.andImm(.d, s0, 0xff);
        // The saved values back first: the exit reads some the answer's registers may hold.
        off = save_at + 8;
        for (saves.items) |r| {
            try as.load(.q, r, at(.rsp, off));
            off += 8;
        }
        for (fsaves.items) |f| {
            try as.movsdLoad(true, f, at(.rsp, off));
            off += 8;
        }
        try as.load(.q, regs, at(.rsp, save_at));
        const took = try as.newLabel();
        try as.@"test"(.d, s0, s0);
        try as.jcc(.ne, took);
        try as.addImm(.q, .rsp, @intCast(total));
        try as.jmp(e.exitLabel(n.exit));
        as.bind(took);
        try as.load(.q, e.reg(v), at(.rsp, dst_at));
        try as.load(.q, e.tagReg(v), at(.rsp, dst_at + e.lay.tag_off));
        try as.addImm(.q, .rsp, @intCast(total));
    }

    /// `s3` = `bytes` (in `s1`) bumped out of the thread's region hole; leaves by `exit`
    /// when the hole has less room.
    fn bump(e: *Emitter, bytes: Reg, exit: X.Label) Error!void {
        const as = e.asm_();
        try as.load(.q, s2, e.local(local_ctx));
        try as.load(.q, s2, at(s2, e.lay.ctx_tlab));
        try as.load(.q, s3, at(s2, e.lay.tlab_cursor));
        try as.load(.q, s0, at(s2, e.lay.tlab_limit));
        try as.sub(.q, s0, s3);
        try as.cmp(.q, s0, bytes);
        try as.jcc(.b, exit);
        try as.lea(s0, Mem.indexed(s3, bytes, 0, 0));
        try as.store(.q, at(s2, e.lay.tlab_cursor), s0);
    }

    /// The template of `len` bytes at `image` copied to `[s3]`, 16 bytes at a time.
    fn copyTemplate(e: *Emitter, image: u64, len: u32) Error!void {
        const as = e.asm_();
        try as.movImm(s1, image);
        var off: u32 = 0;
        while (off < len) : (off += 16) {
            try as.movdquLoad(p0, at(s1, off));
            try as.movdquStore(at(s3, off), p0);
        }
    }

    fn newInst(e: *Emitter, v: Id, n: graph.Node) Error!void {
        const as = e.asm_();
        try as.movImm(s1, n.len);
        try e.bump(s1, e.exitLabel(n.exit));
        try e.copyTemplate(n.aux, n.len);
        try as.lea(s0, at(s3, e.lay.inst_cell));
        try as.store(.q, at(s3, e.lay.inst_slots), s0);
        try as.mov(.q, e.reg(v), s3);
    }

    /// A new primitive array into `v`, as `emit.zig`'s.
    fn newPrim(e: *Emitter, v: Id, n: graph.Node) Error!void {
        const as = e.asm_();
        const exit = e.exitLabel(n.exit);
        const d = e.reg(v);
        const kind: runtime.PrimitiveArrayKind = @enumFromInt(n.kind);
        const shift: u6 = @intCast(std.math.log2_int(usize, kind.elemSize()));
        const cell = e.lay.prim_cell;
        const size = e.node(n.a);
        const known: ?u32 = if (size.op == .konst) blk: {
            const elems: i32 = @bitCast(@as(u32, @truncate(size.aux)));
            if (elems < 0 or (@as(u64, @intCast(elems)) << shift) > e.lay.prim_new_max) {
                try as.jmp(exit);
                return;
            }
            break :blk @as(u32, @intCast(elems)) << @intCast(shift);
        } else null;
        // `ta`: the elements' bytes; `s1`: the cell and the elements, rounded as the hole bumps.
        if (known) |bytes| {
            try as.movImm(ta, bytes);
            try as.movImm(s1, (bytes + cell + 15) & ~@as(u32, 15));
        } else {
            try as.movsxd(ta, try e.operand(n.a, ta));
            try as.@"test"(.q, ta, ta);
            try as.jcc(.s, exit);
            try as.cmpImm(.q, ta, @intCast(e.lay.prim_new_max >> @intCast(shift)));
            try as.jcc(.g, exit);
            try as.shlImm(.q, ta, shift);
            try as.lea(s1, at(ta, cell + 15));
            try as.andImm(.q, s1, -16);
        }
        try e.bump(s1, exit);
        try e.copyTemplate(n.aux, n.len);
        try as.lea(s2, at(s3, cell));
        try as.store(.q, at(s3, e.lay.prim_items), s2);
        try as.store(.q, at(s3, e.lay.prim_items + 8), ta);
        try as.store(.q, at(s3, e.lay.prim_capacity), ta);
        try as.store(.d, at(s3, e.lay.prim_trailing), ta);
        try as.lea(s2, at(ta, cell));
        try as.orImm(.d, s2, @bitCast(e.lay.region_bit));
        try as.store(.d, at(s3, e.lay.prim_gc_bytes), s2);
        // The elements and the rest of the rounding, zeroed.
        try as.xorpd(p0, p0);
        if (known) |bytes| {
            var off: u32 = cell;
            const end = (bytes + cell + 15) & ~@as(u32, 15);
            while (off < end) : (off += 16) try as.movdquStore(at(s3, off), p0);
        } else {
            try as.lea(s2, at(ta, cell + 15));
            try as.andImm(.q, s2, -16);
            try as.add(.q, s2, s3);
            try as.lea(s1, at(s3, cell));
            const loop = try as.newLabel();
            const done = try as.newLabel();
            as.bind(loop);
            try as.cmp(.q, s1, s2);
            try as.jcc(.ae, done);
            try as.movdquStore(at(s1, 0), p0);
            try as.addImm(.q, s1, 16);
            try as.jmp(loop);
            as.bind(done);
        }
        try as.lea(d, at(s3, @intFromEnum(kind) + 1));
    }

    /// Element `n.b` of array `n.a` into pair `v`, as `emit.zig`'s reads it.
    fn arrayGet(e: *Emitter, v: Id, n: graph.Node) Error!void {
        const as = e.asm_();
        const exit = e.exitLabel(n.exit);
        const done = try as.newLabel();
        const arr = try e.operand(n.a, ta);
        const dp = e.reg(v);
        const dt = e.tagReg(v);
        try as.mov(.q, s0, arr);
        try as.andImm(.q, s0, 0xf);
        try as.mov(.q, s1, arr);
        try as.andImm(.q, s1, -16);
        try as.movsxd(s2, try e.operand(n.b, s2));
        try as.@"test"(.q, s2, s2);
        try as.jcc(.s, exit);
        const Kind = struct { bits: u8, shift: u8, w: X.W, tag: Tag };
        const kinds = [_]Kind{
            .{ .bits = 1, .shift = 2, .w = .d, .tag = .Int },
            .{ .bits = 2, .shift = 3, .w = .q, .tag = .Long },
            .{ .bits = 3, .shift = 3, .w = .q, .tag = .Double },
        };
        for (kinds) |k| {
            const other = try as.newLabel();
            try as.cmpImm(.q, s0, k.bits);
            try as.jcc(.ne, other);
            try as.mov(.q, s3, s2);
            try as.shlImm(.q, s3, k.shift);
            try as.cmpLoad(.q, s3, at(s1, e.lay.prim_items + 8));
            try as.jcc(.ae, exit);
            try as.load(.q, dt, at(s1, e.lay.prim_items));
            try as.load(k.w, dp, Mem.indexed(dt, s3, 0, 0));
            try as.movImm(dt, @intFromEnum(k.tag));
            try as.jmp(done);
            as.bind(other);
        }
        // An `Array<T>`: its element between two equal even readings of its sequence.
        try as.@"test"(.q, s0, s0);
        try as.jcc(.ne, exit);
        try as.load(.d, s0, at(s1, e.lay.list_seq));
        try as.testImm(.d, s0, 1);
        try as.jcc(.ne, exit);
        try as.cmpLoad(.q, s2, at(s1, e.lay.list_items + 8));
        try as.jcc(.ae, exit);
        try as.shlImm(.q, s2, 4);
        try as.addLoad(.q, s2, at(s1, e.lay.list_items));
        try as.load(.q, dp, at(s2, 0));
        try as.load(.q, dt, at(s2, 8));
        try as.cmpLoad(.d, s0, at(s1, e.lay.list_seq));
        try as.jcc(.ne, exit);
        as.bind(done);
    }

    fn spendBudget(e: *Emitter) Error!void {
        const gate = e.lay.gate orelse return;
        const as = e.asm_();
        const left = try as.newLabel();
        try as.movImm(s0, @intFromPtr(&gate.budget));
        try as.load(.d, s1, at(s0, 0));
        try as.subImm(.d, s1, 1);
        try as.store(.d, at(s0, 0), s1);
        try as.jcc(.ne, left);
        try as.movImm(s0, @intFromPtr(&gate.on));
        try as.storeImm(.d, at(s0, 0), 0);
        as.bind(left);
    }

    fn count(e: *Emitter, p: *u64) Error!void {
        const as = e.asm_();
        try as.movImm(s0, @intFromPtr(p));
        try as.addMemImm(.q, at(s0, 0), 1);
    }
};

/// Emits the loop's code, as `emit.zig`'s `emit` does.
pub fn emit(m: *masm.X64, a: std.mem.Allocator, g: *const Graph, al: regalloc.Alloc, lay: Layout, entry_label: X.Label, head_baseline: X.Label, targets: anytype) Error!void {
    var e: Emitter = .{
        .m = m,
        .a = a,
        .g = g,
        .al = al,
        .lay = lay,
        .labels = try a.alloc(X.Label, g.blocks.items.len),
        .exit_labels = try a.alloc(X.Label, g.exits.items.len),
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
                if (next == null or next.? != t) try as.jmp(e.labels[t]);
            },
            .branch => |br| {
                const fused = e.fusedCompare(br.cond);
                if (!fused and regalloc.remade(g.nodes.items[br.cond])) {
                    const to = if (g.nodes.items[br.cond].aux != 0) br.t else br.f;
                    if (next == null or next.? != to) try as.jmp(e.labels[to]);
                    continue;
                }
                if (next != null and next.? == br.t) {
                    if (fused) try e.compareBranch(br.cond, e.labels[br.f], false) else {
                        const c = try e.operand(br.cond, ta);
                        try as.@"test"(.d, c, c);
                        try as.jcc(.e, e.labels[br.f]);
                    }
                } else {
                    if (fused) try e.compareBranch(br.cond, e.labels[br.t], true) else {
                        const c = try e.operand(br.cond, ta);
                        try as.@"test"(.d, c, c);
                        try as.jcc(.ne, e.labels[br.t]);
                    }
                    if (next == null or next.? != br.f) try as.jmp(e.labels[br.f]);
                }
            },
            .leave => |x| try as.jmp(e.exit_labels[x]),
            .open => unreachable,
        }
    }
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
    try as.jmp(head_baseline);
}
