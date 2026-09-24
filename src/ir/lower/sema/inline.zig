//! Inline instantiation: at a call of an inline function, the callee's own
//! IR is copied into the caller with its registers and blocks renumbered,
//! its parameters bound to the argument run, its returns sent to a join,
//! and lambda-literal arguments lowered in place.
//!
//! The callee is lowered once, as an ordinary function. Copying it:
//!
//! - `LoadParam i` becomes a `Move` from the run's register `i`.
//! - A parameter the call passes a lambda literal for, and which the body
//!   only calls (through its `LoadParam` register or single-assignment
//!   copies of it), has each `RCallValue` on it replaced by the literal
//!   lowered in place with the call's arguments: its `return` leaves the
//!   caller, its `return@label` the literal, its `break` and `continue`
//!   reach the caller's loops. A parameter the body also uses as a value
//!   (stores it, captures it in a closure) takes the literal as a closure.
//! - A dynamic type test on a reified type value the caller gave as a
//!   class literal becomes a static one.
//! - `Return v` becomes a move into the call's result and a jump to its
//!   join. The body's `try` frames armed there are left on the way, each
//!   popped and its `finally` replayed from the copied IR, innermost
//!   first, as the VM does for a real return. A jump out of a literal
//!   lowered in place leaves them the same way (`FinallyReplay`).
//!
//! Suspend calls are ordinary calls: the VM suspends the caller's frame,
//! which now holds the copied body.

const std = @import("std");
const ast = @import("ast");
const sema = @import("sema");

const ir = @import("../../ir.zig");
const builder = @import("builder.zig");
const records = @import("records.zig");
const body = @import("body.zig");
const lambda = @import("lambda.zig");
const call = @import("call.zig");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Builder = builder.Builder;
const Error = records.Error;
const CallRec = records.CallRec;
const BlockId = ir.BlockId;
const ClassId = ir.ClassId;
const FuncId = ir.FuncId;
const Inst = ir.Inst;
const Reg = ir.Reg;
const Sym = sema.Sym;
const Terminator = ir.Terminator;

/// `finally_depth` is `Builder.finallys.items.len` where the region
/// starts: a return out of it leaves the `try`s entered above it.
pub const Region = union(enum) {
    /// One instantiation: where its returns go.
    instance: struct { callee: FuncId, result: Reg, join: BlockId, finally_depth: usize },
    /// A lambda literal lowered in place: where `return@label` goes.
    lambda: struct { func: Sym, result: Reg, end: BlockId, finally_depth: usize, compose_open: u32 = 0, marker: ?Reg = null },
};

/// A `try` frame of the callee: the block that arms it, and its `finally`
/// with the sentinel that ends the finally.
pub const Frame = struct { entry: BlockId, fin: ?BlockId, done: ?BlockId };

/// How the copy treats one parameter.
const ParamUse = enum {
    /// Bound to the run's register.
    value,
    /// A lambda literal lowered in place at each call.
    in_place,
};

/// One instantiation while it is copied.
pub const Instance = struct {
    callee: *const ir.Func,
    /// Added to every callee register.
    base: u32,
    /// Callee block -> the copy's first block.
    map: []const BlockId,
    /// Callee block -> the frames armed while it runs, outermost first.
    at: []const []const Frame,
    /// By parameter: the register the run gives it.
    run: []const Reg,
    uses: []const ParamUse,
    lambdas: []const ?*const ast.Expr,
    /// By callee register: the parameter it holds unchanged, if any.
    param_of: []const ?u16,
    result: Reg,
    join: BlockId,
};

/// A copied frame's `finally`, for a jump that leaves it (`control.jumpOut`).
pub const FinallyReplay = struct { inst: *const Instance, frame: Frame };

/// Copies `callee`'s body into `b` over the argument run `run` (one
/// register per parameter in the callee's calling convention), lowering
/// each non-null entry of `lambdas` (per parameter) in place, and returns
/// the register holding the call's result.
pub fn instantiate(b: *Builder, rec: *const CallRec, callee: FuncId, run: []const Reg, lambdas: []const ?*const ast.Expr) Error!Reg {
    _ = rec;
    const p = b.p;
    const a = p.a;
    try ensureLowered(b, callee);
    const f = &p.m.funcs.items[callee.int()];
    const nregs = f.n_locals;

    const param_of = try paramRegisters(a, f);
    const uses = try a.alloc(ParamUse, run.len);
    const run_regs = try a.dupe(Reg, run);
    for (uses, 0..) |*u, i| {
        u.* = .value;
        const lit = if (i < lambdas.len) lambdas[i] else null;
        const l = lit orelse continue;
        if (onlyCalled(f, param_of, @intCast(i))) {
            u.* = .in_place;
        } else {
            // Used as a value too: the literal is a closure.
            const saved = b.unmemoized;
            b.unmemoized = l;
            defer b.unmemoized = saved;
            run_regs[i] = try body.lowerExpr(b, l);
        }
    }

    const inst = try a.create(Instance);
    const map = try a.alloc(BlockId, f.blocks.len);
    const base = b.next_reg;
    b.next_reg += nregs;
    const result = b.newReg();
    const join = try b.newBlock();
    for (map) |*m| m.* = try b.newBlock();
    inst.* = .{
        .callee = f,
        .base = base,
        .map = map,
        .at = try simulate(a, f),
        .run = run_regs,
        .uses = uses,
        .lambdas = lambdas,
        .param_of = param_of,
        .result = result,
        .join = join,
    };
    b.terminate(.{ .Goto = map[f.entry.int()] });
    for (f.blocks, 0..) |_, k| try copyBlock(b, inst, @intCast(k), .{ .map = map });
    b.switchTo(join);
    return result;
}

/// For `lowerReturn`: the region a `return` to `target` leaves, if any.
pub fn returnRegion(b: *Builder, target: Sym) ?*Region {
    var i = b.regions.items.len;
    while (i > 0) {
        i -= 1;
        const r = &b.regions.items[i];
        switch (r.*) {
            .lambda => |l| if (l.func == target) return r,
            .instance => {},
        }
    }
    return null;
}

/// Replays a copied frame's `finally` at a jump that leaves it, after the
/// frame is popped; control continues in a fresh block unless the finally
/// itself leaves.
pub fn replayFinally(b: *Builder, r: *const FinallyReplay) Error!void {
    try replayRegion(b, r.inst, r.frame);
}

fn ensureLowered(b: *Builder, callee: FuncId) Error!void {
    const p = b.p;
    // A body a base image holds decodes on first use.
    if (p.isLowered(callee)) {
        _ = p.m.ensureFuncBody(&p.m.funcs.items[callee.int()]);
        return;
    }
    try body.lowerBody(p, callee);
    if (p.isLowered(callee)) return;
    const f = &p.m.funcs.items[callee.int()];
    return b.fail(b.cur_span, "inline function `{s}` has no body to instantiate", .{f.fqn});
}

// ------------------------------------------------------------- analysis --

/// By callee register: the parameter whose value it holds unchanged, from
/// its only definition: `LoadParam`, or a `Move` from such a register.
fn paramRegisters(a: Allocator, f: *const ir.Func) Error![]const ?u16 {
    const n = f.n_locals;
    const defs = try a.alloc(u32, n);
    @memset(defs, 0);
    const Count = struct {
        defs: []u32,
        fn cb(c: @This(), r: Reg, is_def: bool) void {
            if (is_def and r.int() < c.defs.len) c.defs[r.int()] += 1;
        }
    };
    for (f.blocks) |blk| {
        for (blk.insts) |*inst| ir.visitInstRegs(inst, Count{ .defs = defs }, Count.cb);
        for (blk.h().catches) |c| {
            if (c.exception_reg.int() < n) defs[c.exception_reg.int()] += 1;
        }
    }
    const out = try a.alloc(?u16, n);
    @memset(out, null);
    for (f.blocks) |blk| for (blk.insts) |inst| switch (inst) {
        .LoadParam => |x| if (x.dst.int() < n and defs[x.dst.int()] == 1) {
            out[x.dst.int()] = x.idx;
        },
        else => {},
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (f.blocks) |blk| for (blk.insts) |inst| switch (inst) {
            .Move => |x| {
                if (x.dst.int() >= n or x.src.int() >= n) continue;
                if (out[x.dst.int()] != null or defs[x.dst.int()] != 1) continue;
                if (out[x.src.int()]) |i| {
                    out[x.dst.int()] = i;
                    changed = true;
                }
            },
            else => {},
        };
    }
    return out;
}

/// Whether the body reads parameter `i` only to call it: every read of a
/// register holding it is an `RCallValue`'s callee or a copy into another
/// such register.
fn onlyCalled(f: *const ir.Func, param_of: []const ?u16, i: u16) bool {
    const Scan = struct {
        param_of: []const ?u16,
        i: u16,
        skip: ?Reg,
        bad: *bool,
        fn cb(c: @This(), r: Reg, is_def: bool) void {
            if (is_def or r.int() >= c.param_of.len) return;
            if (c.param_of[r.int()] != c.i) return;
            if (c.skip) |s| if (s == r) return;
            c.bad.* = true;
        }
    };
    var bad = false;
    for (f.blocks) |blk| {
        for (blk.insts) |*inst| {
            var skip: ?Reg = null;
            switch (inst.*) {
                .RCallValue => |x| {
                    // The callee operand is the call; the arguments are reads.
                    if (x.callee.int() < param_of.len and param_of[x.callee.int()] == i) {
                        var k: u32 = 0;
                        while (k < x.n_args) : (k += 1) {
                            const r = Reg.from(x.args.int() + k);
                            if (r.int() < param_of.len and param_of[r.int()] == i) return false;
                        }
                        continue;
                    }
                },
                .Move => |x| if (x.dst.int() < param_of.len and param_of[x.dst.int()] == i) {
                    skip = x.src;
                },
                else => {},
            }
            ir.visitInstRegs(inst, Scan{ .param_of = param_of, .i = i, .skip = skip, .bad = &bad }, Scan.cb);
            if (bad) return false;
        }
        const t = blk.terminator;
        ir.visitTerminatorRegs(&t, Scan{ .param_of = param_of, .i = i, .skip = null, .bad = &bad }, Scan.cb);
        if (bad) return false;
    }
    return true;
}

/// The `try` frames armed while each block runs, as the VM arms and pops
/// them: a block with catches or a finally arms one on entry; entering
/// a finally, the join of a catch-only `try`, the exit of a finally's
/// sentinel and a `pop_on_exit` pop one; a handler runs with the frames
/// outside its `try`.
fn simulate(a: Allocator, f: *const ir.Func) Error![]const []const Frame {
    const n = f.blocks.len;
    const at = try a.alloc([]const Frame, n);
    @memset(at, &.{});
    const incoming = try a.alloc(?[]const Frame, n);
    @memset(incoming, null);
    var work: std.ArrayList(u32) = .empty;
    incoming[f.entry.int()] = &.{};
    try work.append(a, f.entry.int());
    while (work.pop()) |k| {
        const blk = &f.blocks[k];
        const h = blk.h();
        var st: std.ArrayList(Frame) = .empty;
        try st.appendSlice(a, incoming[k].?);
        if (h.catch_done_for) |entry| removeEntry(&st, entry);
        removeFinally(&st, BlockId.from(k));
        const outside = try a.dupe(Frame, st.items);
        if (h.catches.len != 0 or h.finally != null) {
            try st.append(a, .{ .entry = BlockId.from(k), .fin = h.finally, .done = h.finally_done });
            for (h.catches) |c| try seed(a, incoming, &work, c.handler, outside);
            if (h.finally) |fin| try seed(a, incoming, &work, fin, outside);
        }
        at[k] = st.items;
        var out: std.ArrayList(Frame) = .empty;
        try out.appendSlice(a, st.items);
        if (blk.terminator == .Goto) {
            if (h.finally_done_for) |entry| removeEntry(&out, entry);
            for (h.pop_on_exit) |entry| removeEntry(&out, entry);
        }
        switch (blk.terminator) {
            .Goto => |t| try seed(a, incoming, &work, t, out.items),
            .Branch => |x| {
                try seed(a, incoming, &work, x.t, out.items);
                try seed(a, incoming, &work, x.f, out.items);
            },
            .Switch => |x| {
                for (x.arms) |arm| try seed(a, incoming, &work, arm.target, out.items);
                try seed(a, incoming, &work, x.default, out.items);
            },
            else => {},
        }
    }
    return at;
}

fn seed(a: Allocator, incoming: []?[]const Frame, work: *std.ArrayList(u32), t: BlockId, st: []const Frame) Error!void {
    if (t.int() >= incoming.len or incoming[t.int()] != null) return;
    incoming[t.int()] = st;
    try work.append(a, t.int());
}

fn removeEntry(st: *std.ArrayList(Frame), entry: BlockId) void {
    var i = st.items.len;
    while (i > 0) {
        i -= 1;
        if (st.items[i].entry == entry) {
            _ = st.orderedRemove(i);
            return;
        }
    }
}

fn removeFinally(st: *std.ArrayList(Frame), fin: BlockId) void {
    var i = st.items.len;
    while (i > 0) {
        i -= 1;
        if (st.items[i].fin == fin) {
            _ = st.orderedRemove(i);
            return;
        }
    }
}

// ---------------------------------------------------------------- copying --

/// Where a copy's jumps go: each callee block's copy, and for a replayed
/// finally its sentinel's replacement.
const Target = struct {
    map: []const BlockId,
    /// The sentinel a replayed finally ends at, and where control goes then.
    done: ?BlockId = null,
    cont: BlockId = BlockId.from(0),

    fn block(t: Target, k: BlockId) BlockId {
        if (t.done) |d| if (d == k) return t.cont;
        return t.map[k.int()];
    }
};

/// Copies callee block `k` into `b`, starting at its copy and continuing
/// wherever a literal lowered in place leaves off.
fn copyBlock(b: *Builder, inst: *const Instance, k: u32, tg: Target) Error!void {
    const a = b.p.a;
    const blk = &inst.callee.blocks[k];
    const h = blk.h();
    const first = tg.map[k];
    b.switchTo(first);
    // Handlers that act on entering the block go on its copy's first
    // block; those that act on leaving it, on the last.
    {
        const fh = &b.blocks.items[first.int()].handlers;
        if (h.catches.len != 0) {
            const cs = try a.alloc(ir.CatchHandler, h.catches.len);
            for (h.catches, cs) |c, *o| o.* = .{
                .type_name = c.type_name,
                .handler = tg.block(c.handler),
                .exception_reg = mapReg(inst, c.exception_reg),
                .class_raw = c.class_raw,
            };
            fh.catches = cs;
        }
        if (h.finally) |x| fh.finally = tg.block(x);
        if (h.finally_done) |x| fh.finally_done = tg.block(x);
        if (h.catch_done_for) |x| fh.catch_done_for = tg.block(x);
    }
    for (blk.insts) |*x| try copyInst(b, inst, k, tg, x);
    if (b.terminated()) return;
    {
        const lh = &b.blocks.items[b.cur.int()].handlers;
        if (h.finally_done_for) |x| lh.finally_done_for = tg.block(x);
        if (h.pop_on_exit.len != 0) {
            const ps = try a.alloc(BlockId, h.pop_on_exit.len);
            for (h.pop_on_exit, ps) |x, *o| o.* = tg.block(x);
            lh.pop_on_exit = ps;
        }
    }
    switch (blk.terminator) {
        .Return => |v| try returnExit(b, inst, k, tg, if (v) |r| mapReg(inst, r) else null),
        else => |t| b.terminate(try mapTerminator(b, inst, tg, t)),
    }
}

fn copyInst(b: *Builder, inst: *const Instance, k: u32, tg: Target, x: *const Inst) Error!void {
    switch (x.*) {
        .LoadParam => |lp| {
            const src = if (lp.idx < inst.run.len) inst.run[lp.idx] else try b.unit();
            return b.emit(.{ .Move = .{ .dst = mapReg(inst, lp.dst), .src = src } });
        },
        .LoadCapture => return b.fail(b.cur_span, "an inline function's body reads a capture", .{}),
        .RCallValue => |cv| if (paramOf(inst, cv.callee)) |i| {
            if (inst.uses[i] == .in_place) return inPlace(b, inst, k, tg, i, cv);
        },
        .InstanceOfDyn => |t| if (paramOf(inst, t.ty)) |i| {
            if (concreteClass(b, inst, i)) |cls| return b.emit(.{ .RInstanceOf = .{ .dst = mapReg(inst, t.dst), .src = mapReg(inst, t.src), .class = cls, .nullable = t.nullable } });
        },
        .CastDyn => |t| if (paramOf(inst, t.ty)) |i| {
            if (concreteClass(b, inst, i)) |cls| return b.emit(.{ .RCast = .{ .dst = mapReg(inst, t.dst), .src = mapReg(inst, t.src), .class = cls, .nullable = t.nullable, .safe = t.safe } });
        },
        .CallStatic => |cs| if (try enumIntrinsic(b, inst, cs)) return,
        else => {},
    }
    try b.emit(try mapInst(b, inst, tg, x.*));
}

fn paramOf(inst: *const Instance, r: Reg) ?u16 {
    return if (r.int() < inst.param_of.len) inst.param_of[r.int()] else null;
}

/// The class a reified type value the caller passed names, when the caller
/// made it with a class literal just before the call.
fn concreteClass(b: *Builder, inst: *const Instance, i: u16) ?ClassId {
    if (i >= inst.run.len) return null;
    const r = inst.run[i];
    // The literal is in the block the call started in; the copy may have
    // moved on, so search every block of the caller written so far.
    var bi = b.blocks.items.len;
    while (bi > 0) {
        bi -= 1;
        const list = b.blocks.items[bi].insts.items;
        var j = list.len;
        while (j > 0) {
            j -= 1;
            switch (list[j]) {
                .ClassLiteral => |cl| if (cl.dst == r) return cl.class,
                else => {},
            }
        }
    }
    return null;
}

/// A call of an enum intrinsic over a reified type parameter
/// (`call.enumIntrinsic`) whose type value the caller made from an enum
/// class: that class's own `valueOf`, `values` or `entries`. False when
/// the class is not known here, and the call is copied as it is for an
/// outer copy to replace.
fn enumIntrinsic(b: *Builder, inst: *const Instance, cs: anytype) Error!bool {
    const br = b.p.br;
    if (cs.n_args == 0 or cs.func.int() >= br.origin.len) return false;
    const sym = switch (br.origin[cs.func.int()]) {
        .decl => |d| d,
        else => return false,
    };
    const which = call.enumIntrinsicOf(b.p.s, sym) orelse return false;
    const i = paramOf(inst, Reg.from(cs.args.int() + cs.n_args - 1)) orelse return false;
    if (i >= inst.run.len) return false;
    const cls = typeValueClass(b, inst.run[i]) orelse return false;
    if (cls.int() >= br.class_origin.len) return false;
    const cls_sym = switch (br.class_origin[cls.int()]) {
        .decl => |d| d,
        .sam => return false,
    };
    const args = try b.p.a.alloc(Reg, cs.n_args - 1);
    for (args, 0..) |*r, j| r.* = mapReg(inst, Reg.from(cs.args.int() + @as(u32, @intCast(j))));
    const v = try call.enumIntrinsicCall(b, which, cls_sym, args);
    try b.emit(.{ .Move = .{ .dst = mapReg(inst, cs.dst), .src = v } });
    return true;
}

/// The class type value `r` names, when the caller made it here from a
/// class literal: the literal itself, or the `KType` the base builds over
/// it.
fn typeValueClass(b: *Builder, r: Reg) ?ClassId {
    const make = types.typeBuilder(b);
    var cur = r;
    var hops: u8 = 0;
    while (hops < 8) : (hops += 1) {
        switch (lastDef(b, cur) orelse return null) {
            .ClassLiteral => |cl| return cl.class,
            .Move => |m| cur = m.src,
            .CallStatic => |c| {
                if (make == null or c.func != make.? or c.n_args == 0) return null;
                cur = c.args;
            },
            else => return null,
        }
    }
    return null;
}

/// The latest instruction of the caller written so far that defines `r`.
fn lastDef(b: *Builder, r: Reg) ?Inst {
    const Find = struct {
        r: Reg,
        hit: *bool,
        fn cb(c: @This(), reg: Reg, is_def: bool) void {
            if (is_def and reg == c.r) c.hit.* = true;
        }
    };
    var bi = b.blocks.items.len;
    while (bi > 0) {
        bi -= 1;
        const list = b.blocks.items[bi].insts.items;
        var j = list.len;
        while (j > 0) {
            j -= 1;
            var hit = false;
            ir.visitInstRegs(&list[j], Find{ .r = r, .hit = &hit }, Find.cb);
            if (hit) return list[j];
        }
    }
    return null;
}

/// A call of parameter `i`, whose literal is lowered here with the call's
/// arguments. The frames armed at the call are left through their copied
/// finallys by a jump out of the literal.
fn inPlace(b: *Builder, inst: *const Instance, k: u32, tg: Target, i: u16, cv: anytype) Error!void {
    const a = b.p.a;
    const args = try a.alloc(Reg, cv.n_args);
    for (args, 0..) |*r, j| r.* = Reg.from(cv.args.int() + inst.base + @as(u32, @intCast(j)));
    const depth = b.finallys.items.len;
    defer b.finallys.items.len = depth;
    for (inst.at[k]) |fr| {
        const rp: ?*const FinallyReplay = if (fr.fin != null) blk: {
            const x = try a.create(FinallyReplay);
            x.* = .{ .inst = inst, .frame = fr };
            break :blk x;
        } else null;
        try b.finallys.append(a, .{ .block = null, .try_entry = tg.block(fr.entry), .replay = rp });
    }
    const v = try lambda.lowerInPlace(b, inst.lambdas[i].?, args);
    try b.emit(.{ .Move = .{ .dst = mapReg(inst, cv.dst), .src = v } });
}

/// A `return` of the callee: its value into the result, then out of each
/// armed frame, innermost first, running its finally, then to the join.
fn returnExit(b: *Builder, inst: *const Instance, k: u32, tg: Target, v: ?Reg) Error!void {
    try b.emit(.{ .Move = .{ .dst = inst.result, .src = v orelse try b.unit() } });
    const frames = inst.at[k];
    var j = frames.len;
    while (j > 0) {
        j -= 1;
        const fr = frames[j];
        try popOnExit(b, tg.block(fr.entry));
        const next = try b.newBlock();
        b.terminate(.{ .Goto = next });
        b.switchTo(next);
        if (fr.fin != null) {
            try replayRegion(b, inst, fr);
            if (b.terminated()) return;
        }
    }
    b.terminate(.{ .Goto = inst.join });
}

fn popOnExit(b: *Builder, entry: BlockId) Error!void {
    const h = &b.blocks.items[b.cur.int()].handlers;
    const merged = try b.p.a.alloc(BlockId, h.pop_on_exit.len + 1);
    @memcpy(merged[0..h.pop_on_exit.len], h.pop_on_exit);
    merged[h.pop_on_exit.len] = entry;
    h.pop_on_exit = merged;
}

/// Copies frame `fr`'s finally again, from its entry up to its sentinel,
/// into fresh blocks starting at the current one; control continues in a
/// fresh block after it.
fn replayRegion(b: *Builder, inst: *const Instance, fr: Frame) Error!void {
    const a = b.p.a;
    const f = inst.callee;
    const fin = fr.fin orelse return;
    // The finally's blocks: reachable from its entry without its sentinel.
    var in_region = try std.DynamicBitSetUnmanaged.initEmpty(a, f.blocks.len);
    var work: std.ArrayList(u32) = .empty;
    try work.append(a, fin.int());
    in_region.set(fin.int());
    while (work.pop()) |k| {
        const blk = &f.blocks[k];
        var succ: std.ArrayList(BlockId) = .empty;
        switch (blk.terminator) {
            .Goto => |t| try succ.append(a, t),
            .Branch => |x| try succ.appendSlice(a, &.{ x.t, x.f }),
            .Switch => |x| {
                for (x.arms) |arm| try succ.append(a, arm.target);
                try succ.append(a, x.default);
            },
            else => {},
        }
        const h = blk.h();
        for (h.catches) |c| try succ.append(a, c.handler);
        if (h.finally) |x| try succ.append(a, x);
        if (h.finally_done) |x| try succ.append(a, x);
        for (succ.items) |t| {
            if (fr.done) |d| if (t == d) continue;
            if (t.int() >= f.blocks.len or in_region.isSet(t.int())) continue;
            in_region.set(t.int());
            try work.append(a, t.int());
        }
    }
    const map = try a.dupe(BlockId, inst.map);
    var it = in_region.iterator(.{});
    while (it.next()) |k| map[k] = try b.newBlock();
    const cont = try b.newBlock();
    b.terminate(.{ .Goto = map[fin.int()] });
    const tg: Target = .{ .map = map, .done = fr.done, .cont = cont };
    it = in_region.iterator(.{});
    while (it.next()) |k| try copyBlock(b, inst, @intCast(k), tg);
    b.switchTo(cont);
}

fn mapReg(inst: *const Instance, r: Reg) Reg {
    return Reg.from(r.int() + inst.base);
}

fn mapInst(b: *Builder, inst: *const Instance, tg: Target, x: Inst) Error!Inst {
    return switch (x) {
        inline else => |payload, tag| @unionInit(Inst, @tagName(tag), try mapValue(@TypeOf(payload), b, inst, tg, payload)),
    };
}

fn mapTerminator(b: *Builder, inst: *const Instance, tg: Target, t: Terminator) Error!Terminator {
    return switch (t) {
        .TailJump, .TailCallFunc, .NonLocalReturn, .LabeledReturn => b.fail(b.cur_span, "an inline function's body ends in `{s}`", .{@tagName(t)}),
        inline else => |payload, tag| @unionInit(Terminator, @tagName(tag), try mapValue(@TypeOf(payload), b, inst, tg, payload)),
    };
}

/// An instruction's or terminator's payload with its registers moved by
/// the instantiation's base and its blocks mapped to their copies. Payloads
/// the lowering from sema never emits (boxed ones) are refused.
fn mapValue(comptime T: type, b: *Builder, inst: *const Instance, tg: Target, v: T) Error!T {
    if (T == Reg) return mapReg(inst, v);
    if (T == BlockId) return tg.block(v);
    switch (@typeInfo(T)) {
        .@"struct" => |st| {
            var out = v;
            inline for (st.fields) |fld| {
                if (fld.is_comptime) continue;
                @field(out, fld.name) = try mapValue(fld.type, b, inst, tg, @field(v, fld.name));
            }
            return out;
        },
        .optional => |o| {
            const x = v orelse return null;
            return try mapValue(o.child, b, inst, tg, x);
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (comptime !holdsIds(p.child)) return v;
                const out = try b.p.a.alloc(p.child, v.len);
                for (v, out) |e, *o| o.* = try mapValue(p.child, b, inst, tg, e);
                return out;
            },
            else => return b.fail(b.cur_span, "an inline function's body holds a boxed instruction", .{}),
        },
        else => return v,
    }
}

/// Whether a value of `T` can hold a register or a block id.
fn holdsIds(comptime T: type) bool {
    if (T == Reg or T == BlockId) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |st| blk: {
            inline for (st.fields) |fld| {
                if (holdsIds(fld.type)) break :blk true;
            }
            break :blk false;
        },
        .optional => |o| holdsIds(o.child),
        else => false,
    };
}
