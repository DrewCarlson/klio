//! `for (x in xs) body` loop lowering. Free functions over the shared
//! `FuncBuilder`; filled in alongside the expression dispatch.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../ir.zig");
const build = @import("../build.zig");
const expr = @import("expr.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Reg = ir.Reg;
const Inst = ir.Inst;
const Const = ir.Const;
const Terminator = ir.Terminator;

const lowerExpr = expr.lowerExpr;

pub fn lowerFor(
    b: *FuncBuilder,
    vars: []const ast.Ident,
    iter: *const Expr,
    body: *const Expr,
) Allocator.Error!Reg {
    return lowerForLabeled(b, vars, iter, body, null);
}

pub fn lowerForLabeled(
    b: *FuncBuilder,
    vars: []const ast.Ident,
    iter: *const Expr,
    body: *const Expr,
    label: ?[]const u8,
) Allocator.Error!Reg {
    const recv = try lowerExpr(b, iter);
    const it_reg = b.allocReg();
    const zero = b.allocReg();
    try b.push(.{ .Move = .{ .dst = zero, .src = recv } });
    const name = try b.module.internConst(b.allocator, .{ .String = "iterator" });
    const args_start = b.allocReg();
    try b.push(.{ .CallMember = .{
        .dst = it_reg,
        .receiver = zero,
        .name = name,
        .args = args_start,
        .n_args = 0,
        .arg_names = &.{},
    } });
    const header = try b.allocBlock();
    const body_blk = try b.allocBlock();
    const exit = try b.allocBlock();
    b.terminate(.{ .Goto = header });

    b.switchTo(header);
    const has_next = b.allocReg();
    const hn_name = try b.module.internConst(b.allocator, .{ .String = "hasNext" });
    const hn_args = b.allocReg();
    try b.push(.{ .CallMember = .{
        .dst = has_next,
        .receiver = it_reg,
        .name = hn_name,
        .args = hn_args,
        .n_args = 0,
        .arg_names = &.{},
    } });
    b.terminate(.{ .Branch = .{
        .cond = has_next,
        .t = body_blk,
        .f = exit,
    } });

    b.switchTo(body_blk);
    try b.pushScope();
    const next_reg = b.allocReg();
    const next_name = try b.module.internConst(b.allocator, .{ .String = "next" });
    const nargs = b.allocReg();
    try b.push(.{ .CallMember = .{
        .dst = next_reg,
        .receiver = it_reg,
        .name = next_name,
        .args = nargs,
        .n_args = 0,
        .arg_names = &.{},
    } });
    if (vars.len == 1) {
        try b.bind(vars[0].name, next_reg);
        if (try expr.iterableElementTypeName(b, iter)) |elem| {
            try b.setLocalDeclTypeOwned(vars[0].name, .{
                .name = elem,
                .nullable = false,
                .args = &.{},
            });
        }
    } else {
        for (vars, 0..) |v, i| {
            const comp = b.allocReg();
            const comp_name = try std.fmt.allocPrint(b.allocator, "component{d}", .{i + 1});
            const nm = try b.module.internConst(b.allocator, .{ .String = comp_name });
            const cargs = b.allocReg();
            try b.push(.{ .CallMember = .{
                .dst = comp,
                .receiver = next_reg,
                .name = nm,
                .args = cargs,
                .n_args = 0,
                .arg_names = &.{},
            } });
            try b.bind(v.name, comp);
        }
    }
    try b.pushLoop(label, header, exit);
    _ = try lowerExpr(b, body);
    b.popLoop();
    try b.popScope();
    b.terminate(.{ .Goto = header });

    b.switchTo(exit);
    return b.emitConst(.Unit);
}

test {
    std.testing.refAllDecls(@This());
}
