//! Control flow and the constructs whose meaning is fixed: `if`, `when`,
//! loops, `try`, jumps, templates, literals, `!!` and `?.`.
//!
//! A `try` follows the VM's handler protocol: its body's entry block carries
//! the catches (by class) and the `finally`, a post-finally sentinel marks
//! where the finally ends, and the join of a catch-only `try` pops the
//! body's frame on normal flow. A `return` or `throw` is routed through the
//! armed finallys by the VM. A `break`, a `continue` and a return out of an
//! inline region are jumps: each `try` they leave has its frame popped and
//! its `finally` lowered again at the jump, innermost first.

const std = @import("std");
const ast = @import("ast");
const sema = @import("sema");

const ir = @import("../../ir.zig");
const builder = @import("builder.zig");
const records = @import("records.zig");
const compose = @import("compose.zig");
const body = @import("body.zig");
const env = @import("env.zig");
const name = @import("name.zig");
const call = @import("call.zig");
const operator = @import("operator.zig");
const types = @import("types.zig");
const inline_mod = @import("inline.zig");
const tailrec = @import("tailrec.zig");

const Builder = builder.Builder;
const Error = records.Error;
const BlockId = ir.BlockId;
const Reg = ir.Reg;
const Sym = sema.Sym;
const TypeId = sema.TypeId;

/// `if`: a value when it has an `else`, `Unit` otherwise.
pub fn lowerIf(b: *Builder, e: *const ast.Expr) Error!Reg {
    const x = e.If;
    const cond = try body.lowerExpr(b, x.cond);
    // Branches that compose each run in a replace group of their own, and
    // a missing `else` in an empty one, so a flip replaces what the other
    // branch composed.
    const grouped = compose.composes(b, x.then_branch) or (if (x.else_branch) |eb| compose.composes(b, eb) else false);
    const result = b.newReg();
    const then_blk = try b.newBlock();
    const else_blk = try b.newBlock();
    const join = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = cond, .t = then_blk, .f = else_blk } });
    b.switchTo(then_blk);
    try arm(b, x.then_branch, result, join, grouped);
    b.switchTo(else_blk);
    if (x.else_branch) |eb| {
        try arm(b, eb, result, join, grouped);
    } else {
        if (grouped) try compose.emptyGroup(b, e.span());
        try b.emit(.{ .Move = .{ .dst = result, .src = try b.emitConst(.Unit) } });
        b.terminate(.{ .Goto = join });
    }
    b.switchTo(join);
    if (x.else_branch == null) return b.emitConst(.Unit);
    return result;
}

/// One branch: its value into `result`, then on to `join`, unless it
/// jumped away; in a replace group when `grouped`.
fn arm(b: *Builder, e: *const ast.Expr, result: Reg, join: BlockId, grouped: bool) Error!void {
    if (grouped) try compose.startReplaceGroup(b, e.span());
    const saved_block = b.compose_block;
    b.compose_block = .{ .end = e.span().end };
    const v = try body.lowerExpr(b, e);
    b.compose_block = saved_block;
    if (grouped) {
        b.compose_open -= 1;
        if (!b.terminated()) try compose.endReplaceGroupCall(b);
    }
    if (b.terminated()) return;
    try b.emit(.{ .Move = .{ .dst = result, .src = v } });
    b.terminate(.{ .Goto = join });
}

/// `when`, with or without a subject. Each pattern tests in order with
/// what sema recorded at its offset: `equals`, `contains` or a type test.
/// Without `else`, a `when` over an enum, sealed or `Boolean` subject that
/// matches nothing throws `NoWhenBranchMatchedException`.
pub fn lowerWhen(b: *Builder, e: *const ast.Expr) Error!Reg {
    const w = e.When;
    const s = b.p.s;
    var subject: ?Reg = null;
    var subject_t: TypeId = .none;
    if (w.subject) |subj| {
        // Its value when the `when` starts, whatever a pattern assigns.
        const v = b.newReg();
        try b.emit(.{ .Move = .{ .dst = v, .src = try body.lowerExpr(b, subj) } });
        subject = v;
        subject_t = b.exprType(subj.id());
        if (w.subject_binding != null) {
            const sym = try b.decl(w.id);
            try env.bindLocal(b, sym, v);
            subject_t = s.syms.localInfo(sym).ty;
        }
    }
    const result = b.newReg();
    const join = try b.newBlock();
    var has_else = false;
    var has_null = false;
    const grouped = for (w.branches) |*br| {
        if (compose.composes(b, &br.body)) break true;
    } else false;
    for (w.branches) |*br| {
        const body_blk = try b.newBlock();
        const next = try b.newBlock();
        for (br.patterns, 0..) |*pat, i| {
            const last = i + 1 == br.patterns.len;
            const fail_to = if (last) next else try b.newBlock();
            switch (pat.kind) {
                .Else => {
                    has_else = true;
                    b.terminate(.{ .Goto = body_blk });
                },
                else => {
                    if (pat.kind == .Value and pat.kind.Value == .NullLit) has_null = true;
                    const hit = try pattern(b, w.id, pat, subject, subject_t);
                    b.terminate(.{ .Branch = .{ .cond = hit, .t = body_blk, .f = fail_to } });
                },
            }
            b.switchTo(fail_to);
        }
        // `fail_to` of the last pattern is `next`, where the next branch tests.
        b.switchTo(body_blk);
        try arm(b, &br.body, result, join, grouped);
        b.switchTo(next);
    }
    // No branch matched.
    if (!has_else and subject != null and try exhaustiveSubject(s, subject_t, has_null)) {
        try throwNoBranch(b, e.span());
    } else {
        if (grouped and !has_else) try compose.emptyGroup(b, e.span());
        try b.emit(.{ .Move = .{ .dst = result, .src = try b.emitConst(.Unit) } });
        b.terminate(.{ .Goto = join });
    }
    b.switchTo(join);
    return result;
}

/// Whether a `when` over a subject of type `t` must match: an enum, a
/// sealed class or `Boolean`, not null unless a `null ->` branch covers it.
fn exhaustiveSubject(s: *sema.Sema, t: TypeId, has_null: bool) Error!bool {
    if (t == .none) return false;
    if (s.types.isNullable(t) and !has_null) return false;
    const cls = s.types.classSym(t);
    if (cls == .none) return false;
    if (cls == s.builtins.boolean) return true;
    if (s.syms.kind(cls) != .class) return false;
    return s.syms.classInfo(cls).kind == .enum_class or s.syms.flags(cls).modality == .sealed;
}

/// `throw NoWhenBranchMatchedException()`.
fn throwNoBranch(b: *Builder, sp: @import("span").Span) Error!void {
    const s = b.p.s;
    const cls = s.classByFqn("kotlin.NoWhenBranchMatchedException");
    if (cls == .none) return b.fail(sp, "the base declares no NoWhenBranchMatchedException", .{});
    const ctor = noArgCtor(s, cls) orelse return b.fail(sp, "NoWhenBranchMatchedException has no constructor taking no arguments", .{});
    const n = s.syms.functionInfo(ctor).params.len;
    const args = try b.p.a.alloc(sema.records.ArgSource, n);
    @memset(args, .default);
    const conv = try b.p.a.alloc(sema.records.Conv, n);
    @memset(conv, .none);
    const rec: records.CallRec = .{ .callee = ctor, .form = .ctor, .args = args, .conv = conv };
    const exc = try call.emitCall(b, &rec, .{ .exprs = &.{}, .regs = &.{}, .receiver = null });
    b.terminate(.{ .Throw = exc });
}

/// A constructor of `cls` every parameter of which has a default.
fn noArgCtor(s: *sema.Sema, cls: Sym) ?Sym {
    var best: ?Sym = null;
    for (sema.Symbols.members(&s.syms.classInfo(cls).members, sema.wk.init)) |ctor| {
        if (s.syms.kind(ctor) != .constructor) continue;
        const params = s.syms.functionInfo(ctor).params;
        for (params) |p| {
            if (!s.syms.flags(p).has_default) break;
        } else {
            if (best == null or params.len < s.syms.functionInfo(best.?).params.len) best = ctor;
        }
    }
    return best;
}

/// One `when` pattern as a `Boolean`.
fn pattern(b: *Builder, when_id: ast.NodeId, pat: *const ast.WhenPattern, subject: ?Reg, subject_t: TypeId) Error!Reg {
    switch (pat.kind) {
        .Value => |*v| {
            const sv = subject orelse return body.lowerExpr(b, v);
            const pv = try body.lowerExpr(b, v);
            if (v.* == .NullLit) {
                const dst = b.newReg();
                try b.emit(.{ .BinOp = .{ .dst = dst, .op = .IdentEq, .lhs = sv, .rhs = pv } });
                return dst;
            }
            const rec = switch (try b.whenPattern(when_id, v.span().start)) {
                .equals => |c| c,
                else => return error.Unrecorded,
            };
            return operator.equality(b, sv, subject_t, pv, b.exprType(v.id()), rec);
        },
        .InRange, .NotInRange => |*v| {
            const sv = subject orelse return b.fail(pat.span, "an `in` pattern without a subject", .{});
            const range = try body.lowerExpr(b, v);
            const rec = switch (try b.whenPattern(when_id, v.span().start)) {
                .contains => |c| c,
                else => return error.Unrecorded,
            };
            const r = try operator.callOn(b, &rec, range, &.{sv});
            return if (pat.kind == .NotInRange) operator.negate(b, r) else r;
        },
        .IsType, .NotIsType => {
            const sv = subject orelse return b.fail(pat.span, "an `is` pattern without a subject", .{});
            const rec = switch (try b.whenPattern(when_id, pat.span.start)) {
                .type_test => |t| t,
                else => return error.Unrecorded,
            };
            return types.testAgainst(b, &rec, sv);
        },
        .Else => unreachable,
    }
}

/// `while (cond) body`.
pub fn lowerWhile(b: *Builder, e: *const ast.Expr) Error!Reg {
    return loopWhile(b, e, null);
}

fn loopWhile(b: *Builder, e: *const ast.Expr, label: ?[]const u8) Error!Reg {
    const w = e.While;
    const groups = try compose.LoopGroups.begin(b, e, w.body, label);
    const cond_blk = try b.newBlock();
    const body_blk = try b.newBlock();
    const exit = try b.newBlock();
    b.terminate(.{ .Goto = cond_blk });
    b.switchTo(cond_blk);
    const c = try loopCondition(b, w.cond, groups);
    if (!b.terminated()) b.terminate(.{ .Branch = .{ .cond = c, .t = body_blk, .f = exit } });
    b.switchTo(body_blk);
    try loopBody(b, w.body, label, exit, cond_blk, groups);
    if (!b.terminated()) b.terminate(.{ .Goto = cond_blk });
    b.switchTo(exit);
    try groups.end(b);
    return b.emitConst(.Unit);
}

/// A loop's condition, in a replace group of its own when each iteration
/// has one.
fn loopCondition(b: *Builder, cond: *const ast.Expr, groups: compose.LoopGroups) Error!Reg {
    if (!groups.per_iteration) return body.lowerExpr(b, cond);
    try compose.startReplaceGroup(b, cond.span());
    const c = try body.lowerExpr(b, cond);
    b.compose_open -= 1;
    if (!b.terminated()) try compose.endReplaceGroupCall(b);
    return c;
}

/// `do body while (cond)`. A `continue`, labeled or not, goes to the
/// condition.
pub fn lowerDoWhile(b: *Builder, e: *const ast.Expr) Error!Reg {
    return loopDoWhile(b, e, null);
}

fn loopDoWhile(b: *Builder, e: *const ast.Expr, label: ?[]const u8) Error!Reg {
    const w = e.DoWhile;
    const groups = try compose.LoopGroups.begin(b, e, w.body, label);
    const body_blk = try b.newBlock();
    const cond_blk = try b.newBlock();
    const exit = try b.newBlock();
    b.terminate(.{ .Goto = body_blk });
    b.switchTo(body_blk);
    if (w.body) |bd| try loopBody(b, bd, label, exit, cond_blk, groups);
    if (!b.terminated()) b.terminate(.{ .Goto = cond_blk });
    b.switchTo(cond_blk);
    const c = try loopCondition(b, w.cond, groups);
    if (!b.terminated()) b.terminate(.{ .Branch = .{ .cond = c, .t = body_blk, .f = exit } });
    b.switchTo(exit);
    try groups.end(b);
    return b.emitConst(.Unit);
}

/// A loop's body with the loop on the stack for `break` and `continue`,
/// in a replace group of its own when each iteration has one, which a
/// `break` or `continue` closes. The body is a block scope whose groups
/// are all realized.
fn loopBody(b: *Builder, e: *const ast.Expr, label: ?[]const u8, break_to: BlockId, continue_to: BlockId, groups: compose.LoopGroups) Error!void {
    try b.loops.append(b.p.a, .{ .label = label, .break_to = break_to, .continue_to = continue_to, .finally_depth = b.finallys.items.len, .compose_open = b.compose_open });
    defer _ = b.loops.pop();
    const saved_block = b.compose_block;
    b.compose_block = .{ .end = e.span().end, .loop_body = true };
    defer b.compose_block = saved_block;
    if (groups.per_iteration) try compose.startReplaceGroup(b, e.span());
    _ = try body.lowerExpr(b, e);
    if (groups.per_iteration) {
        b.compose_open -= 1;
        if (!b.terminated()) try compose.endReplaceGroupCall(b);
    }
}

/// `for (x in c) body`: `c.iterator()`, then `hasNext()` and `next()` on
/// the iterator, as sema recorded them; the element binds the loop
/// variable, or each destructured entry through its `componentN`.
pub fn lowerFor(b: *Builder, e: *const ast.Expr) Error!Reg {
    return loopFor(b, e, null);
}

fn loopFor(b: *Builder, e: *const ast.Expr, label: ?[]const u8) Error!Reg {
    const f = e.For;
    const g = try b.forGroup(f.id);
    const groups = try compose.LoopGroups.begin(b, e, f.body, label);
    const src = try body.lowerExpr(b, f.iter);
    const iter = try operator.callOn(b, &g.iterator, src, &.{});
    const head = try b.newBlock();
    const body_blk = try b.newBlock();
    const exit = try b.newBlock();
    b.terminate(.{ .Goto = head });
    b.switchTo(head);
    if (groups.per_iteration) try compose.startReplaceGroup(b, f.iter.span());
    const more = try operator.callOn(b, &g.has_next, iter, &.{});
    if (groups.per_iteration) {
        b.compose_open -= 1;
        try compose.endReplaceGroupCall(b);
    }
    b.terminate(.{ .Branch = .{ .cond = more, .t = body_blk, .f = exit } });
    b.switchTo(body_blk);
    const elem = try operator.callOn(b, &g.next, iter, &.{});
    if (f.vars.len == 1 and !f.destructured) {
        try env.bindLocal(b, try b.decl(f.id), elem);
    } else {
        try body.destructure(b, f.id, f.vars, f.var_sources, elem);
    }
    try loopBody(b, f.body, label, exit, head, groups);
    if (!b.terminated()) b.terminate(.{ .Goto = head });
    b.switchTo(exit);
    try groups.end(b);
    return b.emitConst(.Unit);
}

/// A `Labeled` expression: a labeled loop takes the label onto the loop
/// stack; a labeled lambda's label is in its record.
pub fn lowerLabeled(b: *Builder, e: *const ast.Expr) Error!Reg {
    const l = e.Labeled;
    return switch (l.expr.*) {
        .While => loopWhile(b, l.expr, l.label.name),
        .DoWhile => loopDoWhile(b, l.expr, l.label.name),
        .For => loopFor(b, l.expr, l.label.name),
        else => body.lowerExpr(b, l.expr),
    };
}

/// `try`/`catch`/`finally`, as a value: the body's or the catching
/// handler's.
pub fn lowerTry(b: *Builder, e: *const ast.Expr) Error!Reg {
    const t = e.Try;
    const a = b.p.a;
    // Nothing inside a `try` is remembered, as the Compose compiler has it.
    const saved_remember = b.compose_remember;
    b.compose_remember = false;
    defer b.compose_remember = saved_remember;
    const result = b.newReg();
    const exit = try b.newBlock();
    const fin: ?BlockId = if (t.finally != null) try b.newBlock() else null;
    // Allocated before the handlers lower, so a throw in a catch runs the
    // finally and re-raises past this sentinel.
    const done: ?BlockId = if (fin != null) try b.newBlock() else null;
    // A catch of a reified type parameter tests the caught value against
    // the type the call passed: every clause then sits behind one handler
    // of `Throwable`, which tries them in order and rethrows past them all.
    const dynamic = for (t.catches) |*c| {
        if ((try b.typeTest(c.id)).class == .none) break true;
    } else false;
    const Handler = struct { blk: BlockId, exc: Reg };
    const n_handlers: usize = if (dynamic) 1 else t.catches.len;
    const handlers = try a.alloc(Handler, n_handlers);
    const catches = try a.alloc(ir.CatchHandler, n_handlers);
    for (handlers, catches, 0..) |*h, *ch, i| {
        h.* = .{ .blk = try b.newBlock(), .exc = b.newReg() };
        const class = if (dynamic) try types.throwableClass(b, t.catches[0].ty.span) else try types.catchClass(b, &t.catches[i]);
        ch.* = .{ .type_name = "", .handler = h.blk, .exception_reg = h.exc, .class_raw = class.int() };
    }
    const entry = try b.newBlock();
    b.terminate(.{ .Goto = entry });
    b.switchTo(entry);
    const eh = &b.blocks.items[entry.int()].handlers;
    eh.catches = catches;
    eh.finally = fin;
    if (done) |d| {
        b.blocks.items[entry.int()].handlers.finally_done = d;
        b.blocks.items[d.int()].handlers.finally_done_for = entry;
    }
    const catch_only = fin == null and t.catches.len != 0;
    if (catch_only) b.blocks.items[exit.int()].handlers.catch_done_for = entry;
    const fin_block: ?*const ast.Block = if (t.finally) |*fb| fb else null;

    const exit_to = fin orelse exit;
    {
        try b.finallys.append(a, .{ .block = fin_block, .try_entry = entry });
        defer _ = b.finallys.pop();
        const v = try body.lowerBlock(b, &t.body);
        if (!b.terminated()) {
            try b.emit(.{ .Move = .{ .dst = result, .src = v } });
            b.terminate(.{ .Goto = exit_to });
        }
    }
    for (handlers, 0..) |h, i| {
        b.switchTo(h.blk);
        // A handler is itself protected by the finally, so a throw from it
        // still runs the finally before propagating.
        const depth = b.finallys.items.len;
        if (fin) |f| {
            b.blocks.items[h.blk.int()].handlers.finally = f;
            b.blocks.items[h.blk.int()].handlers.finally_done = done;
            try b.finallys.append(a, .{ .block = fin_block, .try_entry = h.blk });
        }
        defer b.finallys.items.len = depth;
        if (!dynamic) {
            try catchBody(b, &t.catches[i], h.exc, result, exit_to);
            continue;
        }
        for (t.catches) |*c| {
            const rec = try b.typeTest(c.id);
            const hit = try types.testAgainst(b, &rec, h.exc);
            const caught = try b.newBlock();
            const next = try b.newBlock();
            b.terminate(.{ .Branch = .{ .cond = hit, .t = caught, .f = next } });
            b.switchTo(caught);
            try catchBody(b, c, h.exc, result, exit_to);
            b.switchTo(next);
        }
        b.terminate(.{ .Throw = h.exc });
    }
    if (fin) |f| {
        b.switchTo(f);
        _ = try body.lowerBlock(b, fin_block.?);
        if (!b.terminated()) b.terminate(.{ .Goto = done.? });
        b.switchTo(done.?);
        b.terminate(.{ .Goto = exit });
    }
    b.switchTo(exit);
    return result;
}

/// A catch clause's body over the caught value `exc`, its value moved into
/// `result` on the way to `exit_to`.
fn catchBody(b: *Builder, c: *const ast.Catch, exc: Reg, result: Reg, exit_to: BlockId) Error!void {
    const rec = try b.typeTest(c.id);
    if (rec.binding != .none) try env.bindLocal(b, rec.binding, exc);
    const v = try body.lowerBlock(b, &c.body);
    if (!b.terminated()) {
        try b.emit(.{ .Move = .{ .dst = result, .src = v } });
        b.terminate(.{ .Goto = exit_to });
    }
}

/// `throw value`.
pub fn lowerThrow(b: *Builder, e: *const ast.Expr) Error!Reg {
    const v = try body.lowerExpr(b, e.Throw.value);
    if (!b.terminated()) b.terminate(.{ .Throw = v });
    return deadEnd(b);
}

/// `return` to the function or lambda sema recorded. Out of an inline
/// region (D) it is a jump to the region's end; otherwise the body's own
/// `Return`, which the VM routes through the armed finallys.
pub fn lowerReturn(b: *Builder, e: *const ast.Expr) Error!Reg {
    const r = e.Return;
    const target = try b.returnTarget(r.id);
    if (r.value) |x| if (target == b.owner) try tailrec.markReturn(b, x);
    const v: ?Reg = if (r.value) |x| try body.lowerExpr(b, x) else null;
    if (b.terminated()) return deadEnd(b);
    if (inline_mod.returnRegion(b, target)) |region| {
        const dst, const to, const depth = switch (region.*) {
            .instance => |i| .{ i.result, i.join, i.finally_depth },
            .lambda => |l| .{ l.result, l.end, l.finally_depth },
        };
        switch (region.*) {
            // Out of inline code nested in the literal, the groups its
            // callees opened end back to the literal's marker.
            .lambda => |l| if (l.marker != null and innerRegions(b, region)) {
                try compose.endToMarker(b, l.marker.?);
            } else try compose.closeGroups(b, l.compose_open),
            .instance => {},
        }
        try b.emit(.{ .Move = .{ .dst = dst, .src = v orelse try b.emitConst(.Unit) } });
        try jumpOut(b, depth, to);
        return deadEnd(b);
    }
    // A composable body's return closes its groups on the way out.
    if (try compose.returnExit(b, target, v)) |exit| {
        try jumpOut(b, 0, exit);
        return deadEnd(b);
    }
    // A constructor returns the instance it built, from every exit; a
    // written value (`return Unit`) is evaluated for its effects only.
    const out = if (b.kind == .ctor and target == b.owner) try env.thisOf(b, b.env.this_class) else v;
    b.terminate(.{ .Return = out });
    return deadEnd(b);
}

/// Whether inline regions are open inside `region`, the one a return leaves.
fn innerRegions(b: *Builder, region: *const inline_mod.Region) bool {
    const items = b.regions.items;
    if (items.len == 0) return false;
    return region != &items[items.len - 1];
}

/// `break`, optionally labeled: to the exit of the innermost loop, or the
/// loop the label names.
pub fn lowerBreak(b: *Builder, e: *const ast.Expr) Error!Reg {
    const x = e.Break;
    const loop = findLoop(b, if (x.label) |l| l.name else null) orelse
        return b.fail(x.span, "`break` outside a loop", .{});
    try compose.closeGroups(b, loop.compose_open);
    try jumpOut(b, loop.finally_depth, loop.break_to);
    return deadEnd(b);
}

/// `continue`, optionally labeled: to the loop's condition (`while`,
/// `do-while`) or its next element (`for`).
pub fn lowerContinue(b: *Builder, e: *const ast.Expr) Error!Reg {
    const x = e.Continue;
    const loop = findLoop(b, if (x.label) |l| l.name else null) orelse
        return b.fail(x.span, "`continue` outside a loop", .{});
    try compose.closeGroups(b, loop.compose_open);
    try jumpOut(b, loop.finally_depth, loop.continue_to);
    return deadEnd(b);
}

fn findLoop(b: *Builder, label: ?[]const u8) ?builder.Loop {
    var i = b.loops.items.len;
    while (i > 0) {
        i -= 1;
        const l = b.loops.items[i];
        if (label) |want| {
            if (l.label) |have| if (std.mem.eql(u8, have, want)) return l;
            continue;
        }
        return l;
    }
    return null;
}

/// Jumps to `to`, leaving every `try` entered above `finally_depth`,
/// innermost first: its handler frame pops as the jump leaves it, then its
/// `finally` runs, outside that frame but inside the ones still enclosing.
pub fn jumpOut(b: *Builder, finally_depth: usize, to: BlockId) Error!void {
    const a = b.p.a;
    var i = b.finallys.items.len;
    while (i > finally_depth) {
        i -= 1;
        const f = b.finallys.items[i];
        try popOnExit(b, b.cur, f.try_entry);
        const next = try b.newBlock();
        b.terminate(.{ .Goto = next });
        b.switchTo(next);
        // A `try` of an inline function's copied body replays its IR.
        if (f.replay) |r| {
            try inline_mod.replayFinally(b, r);
            if (b.terminated()) return;
            continue;
        }
        const fb = f.block orelse continue;
        // While the finally lowers, a jump inside it leaves only the
        // enclosing ones.
        const saved = try a.dupe(builder.Finally, b.finallys.items[i..]);
        b.finallys.items.len = i;
        _ = try body.lowerBlock(b, fb);
        b.finallys.items.len = i;
        try b.finallys.appendSlice(a, saved);
        if (b.terminated()) return;
    }
    b.terminate(.{ .Goto = to });
}

/// Adds `frame` to the try-body entries whose frame `blk` pops when it
/// exits by `Goto`.
fn popOnExit(b: *Builder, blk: BlockId, frame: BlockId) Error!void {
    const h = &b.blocks.items[blk.int()].handlers;
    const merged = try b.p.a.alloc(BlockId, h.pop_on_exit.len + 1);
    @memcpy(merged[0..h.pop_on_exit.len], h.pop_on_exit);
    merged[h.pop_on_exit.len] = frame;
    h.pop_on_exit = merged;
}

/// After a jump: a fresh unreachable block for whatever follows, and the
/// `Unit` a `Nothing` expression stands for there.
fn deadEnd(b: *Builder) Error!Reg {
    const dead = try b.newBlock();
    b.switchTo(dead);
    return b.emitConst(.Unit);
}

/// A string template: each part as a string, joined with `StringConcat`.
/// A `String` or primitive part joins as it is; any other value is
/// converted by its `toString` through the slot of `Any.toString`, and a
/// null by the text `null`.
pub fn lowerTemplate(b: *Builder, e: *const ast.Expr) Error!Reg {
    const parts = e.StringTemplate.parts;
    // A lone primitive part still makes a string.
    var acc: ?Reg = if (parts.len == 1 and parts[0] != .Text) try b.emitConst(.{ .String = "" }) else null;
    for (parts) |part| {
        const v = switch (part) {
            .Text => |txt| try b.emitConst(.{ .String = txt }),
            .ShortInterp => |*id| try partString(b, try name.lowerTemplateName(b, id), b.exprType(id.id)),
            .Interp => |x| try partString(b, try body.lowerExpr(b, x), b.exprType(x.id())),
        };
        if (acc) |prev| {
            const dst = b.newReg();
            try b.emit(.{ .BinOp = .{ .dst = dst, .op = .StringConcat, .lhs = prev, .rhs = v } });
            acc = dst;
        } else acc = v;
    }
    return acc orelse b.emitConst(.{ .String = "" });
}

/// `v` of static type `t` as a template part: a `String` or a primitive
/// value, which `StringConcat` renders, or the string its `toString` gives.
fn partString(b: *Builder, v: Reg, t: TypeId) Error!Reg {
    const s = b.p.s;
    if (t != .none and !s.types.isNullable(t) and operator.primOf(s, t) != null) return v;
    const to_string = try anyToString(b);
    if (!operator.mayBeNull(s, t)) return operator.callOn(b, &to_string, v, &.{});
    const result = b.newReg();
    const on_null = try b.newBlock();
    const on_value = try b.newBlock();
    const join = try b.newBlock();
    const null_reg = try b.emitConst(.Null);
    const is_null = b.newReg();
    try b.emit(.{ .BinOp = .{ .dst = is_null, .op = .IdentEq, .lhs = v, .rhs = null_reg } });
    b.terminate(.{ .Branch = .{ .cond = is_null, .t = on_null, .f = on_value } });
    b.switchTo(on_null);
    try b.emit(.{ .Move = .{ .dst = result, .src = try b.emitConst(.{ .String = "null" }) } });
    b.terminate(.{ .Goto = join });
    b.switchTo(on_value);
    const str = try operator.callOn(b, &to_string, v, &.{});
    try b.emit(.{ .Move = .{ .dst = result, .src = str } });
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    return result;
}

/// A call of `Any.toString()` on a value: dispatched through its slot, so
/// the value's own override runs.
fn anyToString(b: *Builder) Error!records.CallRec {
    const s = b.p.s;
    const any = s.builtins.any;
    if (any == .none) return error.Unsupported;
    const n = s.names.lookup("toString") orelse return error.Unsupported;
    for (sema.Symbols.members(&s.syms.classInfo(any).members, n)) |m| {
        if (s.syms.kind(m) != .function) continue;
        if (s.syms.functionInfo(m).params.len != 0) continue;
        return .{ .callee = m, .form = .plain, .dispatch = .expr };
    }
    return error.Unsupported;
}

/// A literal constant, its kind from the type sema gave it.
pub fn lowerLiteral(b: *Builder, e: *const ast.Expr) Error!Reg {
    return switch (e.*) {
        .IntLit => |lit| b.emitConst(try operator.intConst(b, e, lit.value)),
        .FloatLit => |lit| b.emitConst(try operator.floatConst(b, e, lit.value, lit.kind)),
        .BoolLit => |lit| b.emitConst(.{ .Bool = lit.value }),
        .NullLit => b.emitConst(.Null),
        .CharLit => |lit| b.emitConst(.{ .Char = lit.value }),
        else => unreachable,
    };
}

/// `x!!`.
pub fn lowerNotNull(b: *Builder, e: *const ast.Expr) Error!Reg {
    const v = try body.lowerExpr(b, e.Postfix.expr);
    const dst = b.newReg();
    try b.emit(.{ .NotNullAssert = .{ .dst = dst, .src = v } });
    return dst;
}

/// `?.`: runs `then` on a non-null `recv`, else yields null. `then` is a
/// function `fn (*Builder, Reg) Error!Reg`, or a value whose `lower(b,
/// recv)` method is one.
pub fn lowerSafe(b: *Builder, recv: Reg, then: anytype) Error!Reg {
    const result = b.newReg();
    const null_reg = try b.emitConst(.Null);
    try b.emit(.{ .Move = .{ .dst = result, .src = null_reg } });
    const is_null = b.newReg();
    try b.emit(.{ .BinOp = .{ .dst = is_null, .op = .IdentEq, .lhs = recv, .rhs = null_reg } });
    const on_value = try b.newBlock();
    const join = try b.newBlock();
    b.terminate(.{ .Branch = .{ .cond = is_null, .t = join, .f = on_value } });
    b.switchTo(on_value);
    const T = @TypeOf(then);
    const v = if (@typeInfo(T) == .@"fn" or (@typeInfo(T) == .pointer and @typeInfo(@typeInfo(T).pointer.child) == .@"fn"))
        try then(b, recv)
    else
        try then.lower(b, recv);
    if (!b.terminated()) {
        try b.emit(.{ .Move = .{ .dst = result, .src = v } });
        b.terminate(.{ .Goto = join });
    }
    b.switchTo(join);
    return result;
}
