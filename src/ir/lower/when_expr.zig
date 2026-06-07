//! `when` expression lowering. Free functions over the shared
//! `FuncBuilder`; filled in alongside the expression dispatch.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../ir.zig");
const build = @import("../build.zig");
const span = @import("span");
const expr_lower = @import("expr.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const BinOp = ir.BinOp;
const BlockId = ir.BlockId;
const Const = ir.Const;
const ConstId = ir.ConstId;
const Inst = ir.Inst;
const Reg = ir.Reg;
const SwitchArm = ir.SwitchArm;
const Terminator = ir.Terminator;
const TypeRef = ir.TypeRef;

const lowerExpr = expr_lower.lowerExpr;

/// Switch-lowering layout for a subject-bound `when`: the constant cases
/// and their target blocks, the optional `else` block, and the body block
/// per branch in branch order.
const SwitchArms = struct {
    cases: []SwitchArm,
    default: ?BlockId,
    body_blocks: []?BlockId,
};

pub fn collectSwitchArms(
    b: *FuncBuilder,
    branches: []const ast.WhenBranch,
) Allocator.Error!?SwitchArms {
    var cases: std.ArrayList(SwitchArm) = .empty;
    errdefer cases.deinit(b.allocator);
    var body_blocks: std.ArrayList(?BlockId) = .empty;
    errdefer body_blocks.deinit(b.allocator);
    try body_blocks.ensureTotalCapacity(b.allocator, branches.len);
    var default: ?BlockId = null;
    for (branches) |branch| {
        const blk = try b.allocBlock();
        if (branch.patterns.len == 1 and branch.patterns[0].kind == .Else) {
            if (default != null) {
                cases.deinit(b.allocator);
                body_blocks.deinit(b.allocator);
                return null;
            }
            default = blk;
            try body_blocks.append(b.allocator, blk);
            continue;
        }
        for (branch.patterns) |pat| {
            if (pat.kind != .Value) {
                cases.deinit(b.allocator);
                body_blocks.deinit(b.allocator);
                return null;
            }
            const value_expr = pat.kind.Value;
            const const_id: ConstId = switch (value_expr) {
                // i32-representable literal narrows to Int (guarded above).
                .IntLit => |lit| blk: {
                    if (lit.value >= std.math.minInt(i32) and lit.value <= std.math.maxInt(i32)) {
                        break :blk try b.module.internConst(b.allocator, .{ .Int = @intCast(lit.value) });
                    }
                    break :blk try b.module.internConst(b.allocator, .{ .Long = lit.value });
                },
                .StringTemplate => |st| blk: {
                    if (st.parts.len == 1 and st.parts[0] == .Text) {
                        break :blk try b.module.internConst(b.allocator, .{ .String = st.parts[0].Text });
                    }
                    cases.deinit(b.allocator);
                    body_blocks.deinit(b.allocator);
                    return null;
                },
                .BoolLit => |lit| try b.module.internConst(b.allocator, .{ .Bool = lit.value }),
                .CharLit => |lit| try b.module.internConst(b.allocator, .{ .Char = lit.value }),
                .NullLit => try b.module.internConst(b.allocator, .Null),
                else => {
                    cases.deinit(b.allocator);
                    body_blocks.deinit(b.allocator);
                    return null;
                },
            };
            try cases.append(b.allocator, .{ .key = const_id, .target = blk });
        }
        try body_blocks.append(b.allocator, blk);
    }
    if (cases.items.len == 0 and default == null) {
        cases.deinit(b.allocator);
        body_blocks.deinit(b.allocator);
        return null;
    }
    return .{
        .cases = try cases.toOwnedSlice(b.allocator),
        .default = default,
        .body_blocks = try body_blocks.toOwnedSlice(b.allocator),
    };
}

/// Lower a `when` expression, returning the register holding its value.
/// `subject` is non-null for the subject-bound form `when (x) { … }`.
pub fn lowerWhen(
    b: *FuncBuilder,
    subject: ?*const Expr,
    branches: []const ast.WhenBranch,
    when_span: span.Span,
) Allocator.Error!Reg {
    _ = when_span;
    const subject_r: ?Reg = if (subject) |s| try lowerExpr(b, s) else null;
    const join = try b.allocBlock();
    const result = b.allocReg();
    if (subject_r) |subj| {
        if (try collectSwitchArms(b, branches)) |arms| {
            defer b.allocator.free(arms.body_blocks);
            const default: BlockId = if (arms.default) |blk| blk else def: {
                const dflt = try b.allocBlock();
                const saved = b.cur;
                b.switchTo(dflt);
                const u = try b.emitConst(.Unit);
                try b.push(.{ .Move = .{ .dst = result, .src = u } });
                b.terminate(.{ .Goto = join });
                b.switchTo(saved);
                break :def dflt;
            };
            b.terminate(.{ .Switch = .{
                .reg = subj,
                .arms = arms.cases,
                .default = default,
            } });
            for (branches, arms.body_blocks) |branch, body_blk| {
                if (body_blk) |blk| {
                    b.switchTo(blk);
                    const v = try lowerExpr(b, &branch.body);
                    try b.push(.{ .Move = .{ .dst = result, .src = v } });
                    b.terminate(.{ .Goto = join });
                }
            }
            b.switchTo(join);
            return result;
        }
    }
    for (branches) |branch| {
        const body_blk = try b.allocBlock();
        const next_blk = try b.allocBlock();
        const cond: Reg = blk: {
            if (branch.patterns.len == 1 and branch.patterns[0].kind == .Else) {
                b.terminate(.{ .Goto = body_blk });
                b.switchTo(body_blk);
                const v = try lowerExpr(b, &branch.body);
                try b.push(.{ .Move = .{ .dst = result, .src = v } });
                b.terminate(.{ .Goto = join });
                b.switchTo(next_blk);
                continue;
            }
            if (subject_r) |subj| {
                var regs: std.ArrayList(Reg) = .empty;
                defer regs.deinit(b.allocator);
                for (branch.patterns) |*p| {
                    try regs.append(b.allocator, try lowerSubjectPatternCond(b, p, subj));
                }
                break :blk try orChain(b, regs.items);
            } else {
                var regs: std.ArrayList(Reg) = .empty;
                defer regs.deinit(b.allocator);
                for (branch.patterns) |p| {
                    if (p.kind == .Value) {
                        try regs.append(b.allocator, try lowerExpr(b, &p.kind.Value));
                    } else {
                        try b.push(.{ .Trace = .{ .span = p.span } });
                        try regs.append(b.allocator, try b.emitConst(.{ .Bool = false }));
                    }
                }
                break :blk try orChain(b, regs.items);
            }
        };
        b.terminate(.{ .Branch = .{
            .cond = cond,
            .t = body_blk,
            .f = next_blk,
        } });
        b.switchTo(body_blk);
        const v = try lowerExpr(b, &branch.body);
        try b.push(.{ .Move = .{ .dst = result, .src = v } });
        b.terminate(.{ .Goto = join });
        b.switchTo(next_blk);
    }
    const u = try b.emitConst(.Unit);
    try b.push(.{ .Move = .{ .dst = result, .src = u } });
    b.terminate(.{ .Goto = join });
    b.switchTo(join);
    return result;
}

/// Lower one `when` pattern of a subject-bound branch into a Boolean
/// condition register comparing it against `subj`.
fn lowerSubjectPatternCond(
    b: *FuncBuilder,
    p: *const ast.WhenPattern,
    subj: Reg,
) Allocator.Error!Reg {
    switch (p.kind) {
        .Value => |e| {
            const v = try lowerExpr(b, &e);
            const dst = b.allocReg();
            try b.push(.{ .BinOp = .{
                .dst = dst,
                .op = BinOp.Eq,
                .lhs = subj,
                .rhs = v,
            } });
            return dst;
        },
        .IsType => |ty| {
            const dst = b.allocReg();
            try b.push(.{ .InstanceOf = .{
                .dst = dst,
                .src = subj,
                .ty = .{
                    .name = ty.name.name,
                    .nullable = ty.nullable,
                    .args = &.{},
                },
            } });
            return dst;
        },
        .NotIsType => |ty| {
            const raw = b.allocReg();
            try b.push(.{ .InstanceOf = .{
                .dst = raw,
                .src = subj,
                .ty = .{
                    .name = ty.name.name,
                    .nullable = ty.nullable,
                    .args = &.{},
                },
            } });
            const neg = b.allocReg();
            try b.push(.{ .Not = .{ .dst = neg, .src = raw } });
            return neg;
        },
        .InRange => |e| {
            const range_r = try lowerExpr(b, &e);
            const args_start = b.allocReg();
            try b.push(.{ .Move = .{ .dst = args_start, .src = subj } });
            const dst = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = "contains" });
            try b.push(.{ .CallMember = .{
                .dst = dst,
                .receiver = range_r,
                .name = nm,
                .args = args_start,
                .n_args = 1,
                .arg_names = &.{},
            } });
            return dst;
        },
        .NotInRange => |e| {
            const range_r = try lowerExpr(b, &e);
            const args_start = b.allocReg();
            try b.push(.{ .Move = .{ .dst = args_start, .src = subj } });
            const raw = b.allocReg();
            const nm = try b.module.internConst(b.allocator, .{ .String = "contains" });
            try b.push(.{ .CallMember = .{
                .dst = raw,
                .receiver = range_r,
                .name = nm,
                .args = args_start,
                .n_args = 1,
                .arg_names = &.{},
            } });
            const neg = b.allocReg();
            try b.push(.{ .Not = .{ .dst = neg, .src = raw } });
            return neg;
        },
        .Else => {
            try b.push(.{ .Trace = .{ .span = p.span } });
            return b.emitConst(.{ .Bool = false });
        },
    }
}

pub fn orChain(b: *FuncBuilder, regs: []const Reg) Allocator.Error!Reg {
    if (regs.len == 0) {
        return b.emitConst(.{ .Bool = false });
    }
    var acc = regs[0];
    for (regs[1..]) |r| {
        const dst = b.allocReg();
        try b.push(.{ .BinOp = .{
            .dst = dst,
            .op = BinOp.Or,
            .lhs = acc,
            .rhs = r,
        } });
        acc = dst;
    }
    return acc;
}

test {
    std.testing.refAllDecls(@This());
}
