//! `tailrec` functions: a self-call in tail position is a jump back to the
//! top of the body with the call's arguments as the new parameters.
//!
//! Tail positions are marked as the body lowers, before the expression
//! holding them: the body's own expression, the value of a `return` that
//! leaves the function, and in a function returning `Unit` the last
//! statement (or the one before a closing bare `return`). Through `if`
//! and `when` branches, the right of `?:`, `||` and `&&`, and a label, the
//! position carries into the part whose value is the whole's.

const std = @import("std");
const ast = @import("ast");
const sema = @import("sema");

const ir = @import("../../ir.zig");
const builder = @import("builder.zig");
const records = @import("records.zig");
const env = @import("env.zig");

const Builder = builder.Builder;
const Error = records.Error;
const Reg = ir.Reg;

/// Whether the body being lowered is a `tailrec` function's, with its
/// loop set up.
pub fn active(b: *const Builder) bool {
    return b.tail_head != null;
}

/// For a `tailrec` function: every parameter loaded in the entry block,
/// and the body starting in a block of its own that a tail call jumps to.
pub fn begin(b: *Builder) Error!void {
    const s = b.p.s;
    if (b.kind != .function and b.kind != .local_fun) return;
    if (s.syms.kind(b.owner) != .function or !s.syms.flags(b.owner).tailrec) return;
    b.tail_params = try env.paramRegs(b);
    const head = try b.newBlock();
    b.terminate(.{ .Goto = head });
    b.switchTo(head);
    b.tail_head = head;
}

/// Marks `e`, the value that leaves the function, and the parts of it in
/// tail position.
pub fn markExpr(b: *Builder, e: *const ast.Expr) Error!void {
    // Not inside an inline instantiation or a `try`, where the call is an
    // ordinary one.
    if (!active(b) or b.regions.items.len != 0 or b.finallys.items.len != 0) return;
    try markTail(b, e);
}

/// Marks the value of a `return` from the function itself. From a lambda
/// an inline call takes, that return leaves the function as well, so its
/// value is in tail position there too; inside a `try` it is not.
pub fn markReturn(b: *Builder, e: *const ast.Expr) Error!void {
    if (!active(b) or b.finallys.items.len != 0) return;
    try markTail(b, e);
}

fn markTail(b: *Builder, e: *const ast.Expr) Error!void {
    var cur = e;
    while (true) {
        try b.tails.put(b.p.a, cur, {});
        switch (cur.*) {
            .If => |x| {
                try markBranch(b, x.then_branch);
                if (x.else_branch) |el| try markBranch(b, el);
                return;
            },
            .When => |w| {
                for (w.branches) |*br| try markBranch(b, &br.body);
                return;
            },
            .Binary => |x| switch (x.op) {
                .Elvis, .Or, .And => cur = x.rhs,
                else => return,
            },
            .Labeled => |x| cur = x.expr,
            .Block => |*blk| return markLast(b, blk.stmts),
            else => return,
        }
    }
}

fn markBranch(b: *Builder, e: *const ast.Expr) Error!void {
    switch (e.*) {
        .Block => |*blk| try markLast(b, blk.stmts),
        else => try markTail(b, e),
    }
}

/// The last statement of `stmts` whose value is the block's, or which
/// ends the function when a bare `return` follows it.
pub fn markStmts(b: *Builder, stmts: []const ast.Stmt) Error!void {
    if (!active(b) or b.regions.items.len != 0 or b.finallys.items.len != 0) return;
    try markLast(b, stmts);
}

fn markLast(b: *Builder, stmts: []const ast.Stmt) Error!void {
    if (stmts.len == 0) return;
    var last = &stmts[stmts.len - 1];
    if (isBareReturn(last) and stmts.len > 1) last = &stmts[stmts.len - 2];
    switch (last.*) {
        .Expr => |*e| try markTail(b, e),
        else => {},
    }
}

/// In a function returning `Unit`, the body's last statement is in tail
/// position.
pub fn markUnitBody(b: *Builder, stmts: []const ast.Stmt) Error!void {
    if (!active(b)) return;
    const s = b.p.s;
    const ret = s.syms.functionInfo(b.owner).ret;
    if (ret != s.t.unit) return;
    try markStmts(b, stmts);
}

fn isBareReturn(st: *const ast.Stmt) bool {
    return switch (st.*) {
        .Expr => |e| e == .Return and e.Return.value == null and e.Return.label == null,
        else => false,
    };
}

/// Whether call `e`, to `callee`, is a tail call of the function being
/// lowered.
pub fn isTailCall(b: *Builder, e: *const ast.Expr, callee: sema.Sym) bool {
    if (!active(b) or callee != b.owner) return false;
    return b.tails.contains(e);
}

/// The jump a tail call becomes: `run` (the call's arguments in the
/// calling convention's order) into the parameters, then back to the top.
pub fn jump(b: *Builder, run: []const Reg) Error!Reg {
    if (run.len != b.tail_params.len) return b.fail(b.cur_span, "a tail call's arguments do not match the parameters", .{});
    // Every argument first, so a parameter one of them reads is still the
    // old value (`f(b, a)`).
    const temps = try b.p.a.alloc(Reg, run.len);
    for (run, temps) |r, *t| {
        t.* = b.newReg();
        try b.emit(.{ .Move = .{ .dst = t.*, .src = r } });
    }
    for (b.tail_params, temps) |p, t| {
        const dst = p orelse continue;
        try b.emit(.{ .Move = .{ .dst = dst, .src = t } });
    }
    b.terminate(.{ .Goto = b.tail_head.? });
    return b.unit();
}
