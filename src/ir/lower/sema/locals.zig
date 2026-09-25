//! A `var` local lives in a register of its own, and an expression reads
//! that register where it stands and writes its result into it, with no
//! copy between.
//!
//! A read is copied only when the value must outlive a write to the local
//! before it is used: `f(a, run { a = 5; 0 })` passes the `a` it read
//! first, and `a + a++` adds the old `a`. Each statement knows the locals
//! it writes while the values it reads are in flight (`Hazard`); a read of
//! one of those is copied, any other read uses the register. A branch
//! condition's values are used by the branch, so a condition answers only
//! for its own writes, and a statement nested in an expression for its
//! own, except the last one of a block, whose value leaves it.
//!
//! A value is written into the local's register by the instruction that
//! computes it (`retarget`), becomes the register of a local it
//! initializes (`adoptable`), or is computed into its slot of a call's
//! argument run (`runFrom`), when nothing else holds or reads it.

const std = @import("std");
const ast = @import("ast");

const ir = @import("../../ir.zig");
const builder = @import("builder.zig");

const Builder = builder.Builder;
const Reg = ir.Reg;
const Allocator = std.mem.Allocator;

// ------------------------------------------------------------- hazards --

/// The locals a construct writes while the values read in it are in
/// flight: a statement's, a branch condition's, or a block's last
/// statement's together with the enclosing construct's (`parent`). The
/// names are found when a `var` is first read under it.
pub const Hazard = struct {
    what: What,
    /// Only the last statement of a block gives its value to the
    /// enclosing construct, whose writes it then answers for too.
    parent: ?*Hazard = null,
    names: ?[]const []const u8 = null,

    pub const What = union(enum) {
        stmt: *const ast.Stmt,
        expr: *const ast.Expr,
    };

    fn written(h: *Hazard, a: Allocator) Allocator.Error![]const []const u8 {
        if (h.names) |n| return n;
        var w: Writes = .{ .a = a };
        switch (h.what) {
            .stmt => |st| try w.stmtTop(st),
            .expr => |e| try w.expr(e),
        }
        h.names = w.names.items;
        return w.names.items;
    }

    /// Whether the construct, or an enclosing one it answers for, writes
    /// a local named `name` while a value read now is in flight.
    pub fn writes(h: *Hazard, a: Allocator, name: []const u8) Allocator.Error!bool {
        var cur: ?*Hazard = h;
        while (cur) |c| : (cur = c.parent) {
            for (try c.written(a)) |n| if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }
};

/// Whether a read of the `var` local `name` must be copied: something it
/// is lowered under writes it before the value is used.
pub fn mustCopy(b: *Builder, name: []const u8) Allocator.Error!bool {
    const h = b.hazard orelse return false;
    return h.writes(b.p.a, name);
}

/// The names of the locals an expression or statement assigns, increments
/// or decrements, by name: a shadowing local of the same name costs a copy
/// and nothing else. A lambda literal counts, since an inline call runs it
/// in place; a local function, class or object does not, since a local it
/// writes is captured into a cell, which no register holds.
const Writes = struct {
    a: Allocator,
    names: std.ArrayList([]const u8) = .empty,

    fn add(w: *Writes, target: *const ast.Expr) Allocator.Error!void {
        const p = switch (target.*) {
            .Path => |p| p,
            else => return,
        };
        if (p.segments.len != 1) return;
        const n = p.segments[0].name;
        for (w.names.items) |have| if (std.mem.eql(u8, have, n)) return;
        try w.names.append(w.a, n);
    }

    /// A statement, less the write of its own top-level assignment or
    /// increment, which happens once every value it read is used.
    fn stmtTop(w: *Writes, st: *const ast.Stmt) Allocator.Error!void {
        switch (st.*) {
            .Assign => |as| {
                try w.targetParts(&as.target);
                try w.expr(&as.value);
            },
            .Expr => |*e| switch (e.*) {
                .Unary => |u| if (u.op == .PreInc or u.op == .PreDec) try w.targetParts(u.expr) else try w.expr(e),
                .Postfix => |pf| if (pf.op == .Inc or pf.op == .Dec) try w.targetParts(pf.expr) else try w.expr(e),
                else => try w.expr(e),
            },
            else => try w.stmt(st),
        }
    }

    /// What an assignment target evaluates before it is written: a
    /// member's receiver, an index's receiver and indices.
    fn targetParts(w: *Writes, target: *const ast.Expr) Allocator.Error!void {
        switch (target.*) {
            .Path => {},
            .Member => |m| try w.expr(m.receiver),
            .Index => |ix| {
                try w.expr(ix.receiver);
                for (ix.args) |*x| try w.expr(x);
            },
            else => try w.expr(target),
        }
    }

    fn stmt(w: *Writes, st: *const ast.Stmt) Allocator.Error!void {
        switch (st.*) {
            .Expr => |*e| try w.expr(e),
            .Assign => |as| {
                try w.add(&as.target);
                try w.targetParts(&as.target);
                try w.expr(&as.value);
            },
            .DestructuringDecl => |d| try w.expr(&d.init),
            .Decl => |d| switch (d.*) {
                .Property => |p| {
                    if (p.init) |e| try w.expr(e);
                    if (p.delegate) |e| try w.expr(e);
                },
                .Function, .Class, .Object, .TypeAlias => {},
            },
        }
    }

    fn block(w: *Writes, blk: *const ast.Block) Allocator.Error!void {
        for (blk.stmts) |*st| try w.stmt(st);
    }

    fn expr(w: *Writes, e: *const ast.Expr) Allocator.Error!void {
        switch (e.*) {
            .IntLit, .FloatLit, .BoolLit, .NullLit, .CharLit, .Path, .This, .Super, .Break, .Continue, .PropertyRef, .ObjectExpr => {},
            .StringTemplate => |t| for (t.parts) |part| switch (part) {
                .Interp => |x| try w.expr(x),
                .Text, .ShortInterp => {},
            },
            .Member => |m| try w.expr(m.receiver),
            .Call => |c| {
                try w.expr(c.callee);
                for (c.args) |*x| try w.expr(x);
            },
            .Index => |ix| {
                try w.expr(ix.receiver);
                for (ix.args) |*x| try w.expr(x);
            },
            .Binary => |x| {
                try w.expr(x.lhs);
                try w.expr(x.rhs);
            },
            .Unary => |u| {
                if (u.op == .PreInc or u.op == .PreDec) try w.add(u.expr);
                try w.expr(u.expr);
            },
            .Postfix => |pf| {
                if (pf.op == .Inc or pf.op == .Dec) try w.add(pf.expr);
                try w.expr(pf.expr);
            },
            .If => |x| {
                try w.expr(x.cond);
                try w.expr(x.then_branch);
                if (x.else_branch) |eb| try w.expr(eb);
            },
            .While => |x| {
                try w.expr(x.cond);
                try w.expr(x.body);
            },
            .DoWhile => |x| {
                if (x.body) |bd| try w.expr(bd);
                try w.expr(x.cond);
            },
            .For => |x| {
                try w.expr(x.iter);
                try w.expr(x.body);
            },
            .Return => |x| if (x.value) |v| try w.expr(v),
            .Throw => |x| try w.expr(x.value),
            .Labeled => |x| try w.expr(x.expr),
            .Block => |*blk| try w.block(blk),
            .Try => |t| {
                try w.block(&t.body);
                for (t.catches) |*c| try w.block(&c.body);
                if (t.finally) |*f| try w.block(f);
            },
            .Lambda => |l| try w.block(&l.body),
            .AnonFun => |f| if (f.body) |fb| switch (fb.*) {
                .Block => |*blk| try w.block(blk),
                .Expr => |*x| try w.expr(x),
            },
            .MemberRef => |m| try w.expr(m.receiver),
            .When => |x| {
                if (x.subject) |s| try w.expr(s);
                for (x.branches) |*br| {
                    for (br.patterns) |*pat| switch (pat.kind) {
                        .Value, .InRange, .NotInRange => |*pe| try w.expr(pe),
                        .IsType, .NotIsType, .Else => {},
                    };
                    if (br.guard) |g| try w.expr(&g.expr);
                    try w.expr(&br.body);
                }
            },
            .IsCheck => |x| try w.expr(x.expr),
            .As => |x| try w.expr(x.expr),
            .Spread => |x| try w.expr(x.expr),
        }
    }
};

// ------------------------------------------------------------ targeting --

/// Where lowering stood before a value was lowered: the registers, blocks
/// and instructions after it are the value's.
pub const Mark = struct {
    next_reg: u32,
    blocks: usize,
    cur: ir.BlockId,
    cur_len: usize,
    entry_len: usize,
};

pub fn mark(b: *const Builder) Mark {
    return .{
        .next_reg = b.next_reg,
        .blocks = b.blocks.items.len,
        .cur = b.cur,
        .cur_len = b.blocks.items[b.cur.int()].insts.items.len,
        .entry_len = b.blocks.items[0].insts.items.len,
    };
}

/// Whether `v` is a register the value lowered since `m` computed and
/// nothing else holds: allocated after `m`, and not a local's home, a
/// loaded parameter, capture or receiver, the body's `Unit` or `null`, or
/// a register a composable scope keeps.
fn ownedTemp(b: *const Builder, m: Mark, v: Reg) bool {
    if (v.int() < m.next_reg) return false;
    if (b.unit_reg) |r| if (r == v) return false;
    if (b.null_reg) |r| if (r == v) return false;
    if (b.env.composer) |r| if (r == v) return false;
    if (b.compose_marker) |r| if (r == v) return false;
    for (b.env.changed) |r| if (r == v) return false;
    for (b.compose_dirty) |r| if (r == v) return false;
    var loaded = b.env.loaded.valueIterator();
    while (loaded.next()) |r| if (r.* == v) return false;
    var homes = b.locals.valueIterator();
    while (homes.next()) |h| switch (h.*) {
        .reg, .cell => |r| if (r == v) return false,
    };
    return true;
}

const Use = struct {
    reg: Reg,
    defs: u32 = 0,
    uses: u32 = 0,

    fn visit(u: *Use, r: Reg, is_def: bool) void {
        if (r != u.reg) return;
        if (is_def) u.defs += 1 else u.uses += 1;
    }
};

fn countBlock(u: *Use, blk: *const builder.BlockBuf, from: usize) void {
    for (blk.insts.items[@min(from, blk.insts.items.len)..]) |*inst| ir.visitInstRegs(inst, u, Use.visit);
    if (blk.terminator) |*t| ir.visitTerminatorRegs(t, u, Use.visit);
    for (blk.handlers.catches) |c| u.visit(c.exception_reg, true);
}

/// How often the instructions emitted since `m` define and read `v`.
fn count(b: *const Builder, m: Mark, v: Reg) Use {
    var u: Use = .{ .reg = v };
    const blocks = b.blocks.items;
    if (m.cur.int() != 0) countBlock(&u, &blocks[0], m.entry_len);
    countBlock(&u, &blocks[m.cur.int()], m.cur_len);
    for (blocks[m.blocks..]) |*blk| countBlock(&u, blk, 0);
    return u;
}

/// Makes the instruction that computed `v`, the last one lowering wrote
/// since `m`, write `dst` instead, when `v` is an owned temporary it
/// defines once and nothing reads: `a = a + i` is one `BinOp` into `a`.
/// False when it cannot, and the caller moves `v` into `dst`.
pub fn retarget(b: *Builder, m: Mark, v: Reg, dst: Reg) bool {
    if (b.terminated() or !ownedTemp(b, m, v)) return false;
    const insts = b.blocks.items[b.cur.int()].insts.items;
    const since = if (b.cur == m.cur) m.cur_len else if (b.cur.int() >= m.blocks) 0 else return false;
    if (insts.len <= since) return false;
    const last = &insts[insts.len - 1];
    // A load into the entry block is a register the body keeps.
    if (b.cur.int() == 0 and b.entry_last == insts.len - 1) return false;
    if (dstOf(last) != v) return false;
    const u = count(b, m, v);
    if (u.defs != 1 or u.uses != 0) return false;
    setDst(last, dst);
    return true;
}

/// Whether `v`, a value lowered since `m`, can become the home of a local
/// it initializes: an owned temporary nothing else holds.
pub fn adoptable(b: *const Builder, m: Mark, v: Reg) bool {
    return ownedTemp(b, m, v);
}

fn dstOf(inst: *const ir.Inst) ?Reg {
    return switch (inst.*) {
        .LoadParam, .LoadCapture, .MakeCell => null,
        inline else => |x| if (@hasField(@TypeOf(x), "dst")) x.dst else null,
    };
}

fn setDst(inst: *ir.Inst, dst: Reg) void {
    switch (inst.*) {
        inline else => |*x| if (@hasField(@TypeOf(x.*), "dst")) {
            x.dst = dst;
        },
    }
}

// ------------------------------------------------------------------- runs --

const Site = struct { block: u32, inst: u32 };

const RunCount = struct {
    regs: []const Reg,
    defs: []u32,
    uses: []u32,
    at: []Site,
    block: u32 = 0,
    inst: u32 = 0,

    fn visit(c: *RunCount, r: Reg, is_def: bool) void {
        for (c.regs, 0..) |x, i| {
            if (x != r) continue;
            if (is_def) {
                c.defs[i] += 1;
                c.at[i] = .{ .block = c.block, .inst = c.inst };
            } else c.uses[i] += 1;
        }
    }

    fn scan(c: *RunCount, b: *const Builder, blk: u32, from: usize) void {
        const buf = &b.blocks.items[blk];
        c.block = blk;
        var i = from;
        while (i < buf.insts.items.len) : (i += 1) {
            c.inst = @intCast(i);
            ir.visitInstRegs(&buf.insts.items[i], c, visit);
        }
        c.inst = std.math.maxInt(u32);
        if (buf.terminator) |*t| ir.visitTerminatorRegs(t, c, visit);
        for (buf.handlers.catches) |h| c.visit(h.exception_reg, true);
    }
};

/// A call's argument run: `regs` in a fresh contiguous run. A value lowered
/// since `from` that the run alone holds (an owned temporary defined once,
/// read nowhere, named once in `regs`) is computed straight into its slot
/// by the instruction that defines it; any other is moved in.
pub fn runFrom(b: *Builder, from: Mark, regs: []const Reg) builder.Error!Reg {
    const a = b.p.a;
    const first = b.next_reg;
    b.next_reg += @intCast(regs.len);
    const cand = try a.alloc(Reg, regs.len);
    for (regs, cand, 0..) |r, *c, i| {
        const once = for (regs, 0..) |o, j| {
            if (j != i and o == r) break false;
        } else true;
        c.* = if (once and ownedTemp(b, from, r)) r else Reg.from(std.math.maxInt(u32));
    }
    var rc: RunCount = .{
        .regs = cand,
        .defs = try a.alloc(u32, regs.len),
        .uses = try a.alloc(u32, regs.len),
        .at = try a.alloc(Site, regs.len),
    };
    @memset(rc.defs, 0);
    @memset(rc.uses, 0);
    if (from.cur.int() != 0) rc.scan(b, 0, from.entry_len);
    rc.scan(b, @intCast(from.cur.int()), from.cur_len);
    var blk: u32 = @intCast(from.blocks);
    while (blk < b.blocks.items.len) : (blk += 1) rc.scan(b, blk, 0);
    for (regs, 0..) |r, i| {
        const slot = Reg.from(first + @as(u32, @intCast(i)));
        if (rc.defs[i] == 1 and rc.uses[i] == 0 and rc.at[i].inst != std.math.maxInt(u32)) {
            const inst = &b.blocks.items[rc.at[i].block].insts.items[rc.at[i].inst];
            if (dstOf(inst) == r and !(rc.at[i].block == 0 and rc.at[i].inst == b.entry_last)) {
                setDst(inst, slot);
                continue;
            }
        }
        try b.emit(.{ .Move = .{ .dst = slot, .src = r } });
    }
    return Reg.from(first);
}
