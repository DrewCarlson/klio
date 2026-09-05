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
    return lowerWhenWithSubjectReg(b, subject, null, branches, when_span);
}

/// `lowerWhen` over an already-lowered subject register. The subject-
/// binding form `when (val v = expr)` lowers `expr` exactly once for the
/// binding and passes the register here — Kotlin evaluates a `when`
/// subject once, so a side-effecting subject must not be re-lowered.
pub fn lowerWhenWithSubjectReg(
    b: *FuncBuilder,
    subject: ?*const Expr,
    pre_lowered: ?Reg,
    branches: []const ast.WhenBranch,
    when_span: span.Span,
) Allocator.Error!Reg {
    const when_tail = b.tail_arm;
    _ = when_span;
    const subject_r: ?Reg = if (pre_lowered) |r| r else if (subject) |s| try lowerExpr(b, s) else null;
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
                    b.tail_pos = when_tail;
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
                b.tail_pos = when_tail;
                const v = try lowerExpr(b, &branch.body);
                try b.push(.{ .Move = .{ .dst = result, .src = v } });
                b.terminate(.{ .Goto = join });
                b.switchTo(next_blk);
                continue;
            }
            if (subject_r) |subj| {
                // Kotlin evaluates a branch's comma-separated conditions
                // left to right and stops at the first match: each pattern
                // gets its own block, true jumps straight to the body, so
                // a later condition (`Source::class, Input::class ->`)
                // never evaluates once an earlier one matched.
                var i: usize = 0;
                while (i < branch.patterns.len) : (i += 1) {
                    const p = &branch.patterns[i];
                    const c = try lowerSubjectPatternCond(b, p, subj);
                    if (i + 1 == branch.patterns.len) break :blk c;
                    const alt = try b.allocBlock();
                    b.terminate(.{ .Branch = .{ .cond = c, .t = body_blk, .f = alt } });
                    b.switchTo(alt);
                }
                unreachable;
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
        // A subjectless branch narrows by EVERY proof its condition
        // establishes, `&&`-chains included (`v1 is ByteArray && v2 is
        // ByteArray -> v1 contentEquals v2` smart-casts both), plus the
        // truthy null-checks — the same collection an `if` guard applies.
        var cond_narrowed: std.ArrayList(build.FuncBuilder.NarrowedLocal) = .empty;
        defer cond_narrowed.deinit(b.allocator);
        const narrowed = if (subject != null)
            try narrowSubjectForBranch(b, subject, &branch)
        else blk: {
            try narrowConditionForBranchAll(b, &branch, &cond_narrowed);
            break :blk null;
        };
        // `when (this) { is T -> ... }` smart-casts the implicit receiver:
        // the branch body's calls resolve extensions against T (kotlinc
        // resolves statically, so `is List -> this.single()` must select
        // `List.single`, not recurse into the enclosing `Iterable.single`).
        const narrowed_this: ?(?[]const u8) = blk: {
            const subj = subject orelse break :blk null;
            if (subj.* != .This) break :blk null;
            if (branch.patterns.len != 1) break :blk null;
            if (branch.patterns[0].kind != .IsType) break :blk null;
            const head = expr_lower.loweredCheckTypeName(b, &branch.patterns[0].kind.IsType);
            if (head.len == 0) break :blk null;
            break :blk b.setThisNarrow(head);
        };
        b.tail_pos = when_tail;
        const v = try lowerExpr(b, &branch.body);
        if (narrowed_this) |prev| _ = b.setThisNarrow(prev);
        if (narrowed) |n| b.restoreLocal(n);
        var cn = cond_narrowed.items.len;
        while (cn > 0) : (cn -= 1) b.restoreLocal(cond_narrowed.items[cn - 1]);
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

/// A subjectless `when` branch's condition carries the same smart-cast
/// evidence as an `if` condition: every `is` check in its `&&` chain and
/// every truthy null-check narrows for the branch body. Applied in source
/// order; the caller restores in reverse.
fn narrowConditionForBranchAll(
    b: *FuncBuilder,
    branch: *const ast.WhenBranch,
    out: *std.ArrayList(build.FuncBuilder.NarrowedLocal),
) Allocator.Error!void {
    if (branch.patterns.len != 1) return;
    const p = &branch.patterns[0];
    if (p.kind != .Value) return;
    try expr_lower.narrowIsCheckAll(b, &p.kind.Value, out);
    try expr_lower.narrowNullCheckAll(b, &p.kind.Value, true, out);
}

/// A single `is T` pattern over a bare-name subject smart-casts that name to
/// `T` for the branch body. Kotlin resolves extensions against the STATIC type,
/// and lowering hands the receiver's declared head to the extension filter, so
/// without the narrowing `when (any) { is String -> any.isEmpty() }` refutes
/// `CharSequence.isEmpty` on the declared `Any?` and the call misses entirely.
/// A multi-pattern branch (`is A, is B ->`) narrows to no single type, and a
/// non-name subject has no binding to narrow.
fn narrowSubjectForBranch(
    b: *FuncBuilder,
    subject: ?*const Expr,
    branch: *const ast.WhenBranch,
) Allocator.Error!?build.FuncBuilder.NarrowedLocal {
    const subj = subject orelse return null;
    // `when (this)` smart-casts the implicit receiver: the branch body's
    // member/extension calls on `this` resolve against the narrowed type
    // (argDeclTypeRefLazy consults `localDeclTypeRef("this")` first), so
    // `is List -> this.single()` selects `List.single` instead of
    // recursing into the enclosing `Iterable.single`.
    const bind_name: []const u8 = blk: {
        if (subj.* == .This and subj.This.qualifier == null) break :blk "this";
        if (subj.* == .Path and subj.Path.segments.len == 1) break :blk subj.Path.segments[0].name;
        return null;
    };
    if (branch.patterns.len != 1) return null;
    const p = &branch.patterns[0];
    if (p.kind != .IsType) return null;
    const head = expr_lower.loweredCheckTypeName(b, &p.kind.IsType);
    if (head.len == 0) return null;
    return try b.narrowLocal(bind_name, head);
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
                    .name = expr_lower.loweredCheckTypeName(b, &ty),
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
                    .name = expr_lower.loweredCheckTypeName(b, &ty),
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
