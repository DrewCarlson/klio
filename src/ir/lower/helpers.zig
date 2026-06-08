//! Builder-side lowering helpers: argument-run materialisation, arg-name
//! / type-arg interning, the AST→IR binop mapping, and the closure
//! mutation-analysis walks the HOF-writeback path consults.

const std = @import("std");
const ast = @import("ast");
const ir = @import("../ir.zig");
const build = @import("../build.zig");
const expr_mod = @import("expr.zig");

const Allocator = std.mem.Allocator;

const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const AstBinOp = ast.BinOp;
const BinOp = ir.BinOp;
const Const = ir.Const;
const ConstId = ir.ConstId;
const Inst = ir.Inst;
const Module = ir.Module;
const Reg = ir.Reg;
const StringSet = std.StringHashMap(void);

/// True when `arg` is `expr as Any` (or transitively wraps one through
/// trivial parens / binding) — mirrors tree walker's
/// `is_boxed_to_any_form` heuristic. (`is_boxed_to_any_form` itself lives
/// in `ast_scan.zig`.)
pub fn isAnyTypedPath(b: *const FuncBuilder, e: *const Expr) bool {
    return switch (e.*) {
        .Path => |p| p.segments.len == 1 and b.isAnyTyped(p.segments[0].name),
        else => false,
    };
}

/// True when `arg` is a lambda whose body assigns to a name that the IR's
/// current scope shadows or knows as an outer capture.
pub fn lambdaWritesOuterVar(b: *FuncBuilder, arg: *const Expr) Allocator.Error!bool {
    const lam = switch (arg.*) {
        .Lambda => |l| l,
        else => return false,
    };
    var visible = try b.visibleNames();
    defer visible.deinit();
    for (lam.body.stmts) |*s| {
        if (writesWalkStmt(s, &visible)) return true;
    }
    return false;
}

fn writesWalkStmt(s: *const Stmt, visible: *const StringSet) bool {
    return switch (s.*) {
        .Assign => |a| writesIsPathOuter(&a.target, visible),
        .Expr => |*e| writesWalkExpr(e, visible),
        else => false,
    };
}

fn writesIsPathOuter(e: *const Expr, visible: *const StringSet) bool {
    return switch (e.*) {
        .Path => |p| p.segments.len == 1 and visible.contains(p.segments[0].name),
        else => false,
    };
}

fn writesWalkExpr(e: *const Expr, visible: *const StringSet) bool {
    return switch (e.*) {
        .Postfix => |u| (u.op == .Inc or u.op == .Dec) and writesIsPathOuter(u.expr, visible),
        .Unary => |u| (u.op == .PreInc or u.op == .PreDec) and writesIsPathOuter(u.expr, visible),
        // Non-local return from inside the lambda body propagates as
        // `EvalError.NonLocalReturn`; no EvalAst fallback is needed.
        .Return => false,
        .Block => |b| blk: {
            for (b.stmts) |*s| {
                if (writesWalkStmt(s, visible)) break :blk true;
            }
            break :blk false;
        },
        .If => |f| writesWalkExpr(f.cond, visible) or
            writesWalkExpr(f.then_branch, visible) or
            (f.else_branch != null and writesWalkExpr(f.else_branch.?, visible)),
        .While => |w| writesWalkExpr(w.cond, visible) or writesWalkExpr(w.body, visible),
        .DoWhile => |w| (w.body != null and writesWalkExpr(w.body.?, visible)) or
            writesWalkExpr(w.cond, visible),
        .For => |f| writesWalkExpr(f.body, visible),
        .When => |w| blk: {
            for (w.branches) |*br| {
                if (writesWalkExpr(&br.body, visible)) break :blk true;
            }
            break :blk false;
        },
        .Try => |t| blk: {
            for (t.body.stmts) |*s| {
                if (writesWalkStmt(s, visible)) break :blk true;
            }
            for (t.catches) |*c| {
                for (c.body.stmts) |*s| {
                    if (writesWalkStmt(s, visible)) break :blk true;
                }
            }
            if (t.finally) |fb| {
                for (fb.stmts) |*s| {
                    if (writesWalkStmt(s, visible)) break :blk true;
                }
            }
            break :blk false;
        },
        else => false,
    };
}

/// Resolve the register holding the shared `Value.Cell` for a boxed
/// `var`. In the declaring scope the cell lives in the var's
/// `mutable_home`; once a capturing lambda has loaded it the name is
/// rebound to that reg; otherwise it is captured from the enclosing frame
/// so every closure shares the same cell.
pub fn boxedCellReg(b: *FuncBuilder, name: []const u8) Allocator.Error!Reg {
    if (b.mutableHome(name)) |r| return r;
    if (b.resolve(name)) |r| return r;
    const idx = try b.recordCapture(name);
    const c = b.allocReg();
    try b.push(.{ .LoadCapture = .{ .dst = c, .idx = idx } });
    try b.bind(name, c);
    return c;
}

/// Simple name of a call's callee, used as the implicit label of a lambda
/// literal in its argument list: `with(x) { … }` → `"with"`,
/// `sb.apply { … }` → `"apply"`. `null` when the callee has no simple
/// name (a call on an arbitrary value expression).
pub fn calleeLabel(callee: *const Expr) ?[]const u8 {
    return switch (callee.*) {
        .Path => |p| if (p.segments.len == 1) p.segments[0].name else null,
        .Member => |m| m.name.name,
        else => null,
    };
}

/// Materialise a contiguous run of argument registers for a Call /
/// `CallMember` / `CallValue` / `NewInstance` instruction.
///
/// The lowering pass otherwise produces non-contiguous register numbering
/// when sub-expressions allocate intermediate temporaries. Reserve
/// `args.len` contiguous registers up front (so the run [args_start,
/// args_start + n_args) is dense), lower each arg into its own scratch
/// reg, then `Move` the scratch into the matching arg slot.
pub fn lowerArgRun(b: *FuncBuilder, args: []const Expr) Allocator.Error!struct { Reg, u8 } {
    const n = args.len;
    if (n == 0) {
        // Reserve a sentinel slot so the n_args=0 reads do not alias an
        // unrelated register.
        return .{ b.allocReg(), 0 };
    }
    const first = b.allocReg();
    var slots = try b.allocator.alloc(Reg, n);
    defer b.allocator.free(slots);
    slots[0] = first;
    var i: usize = 1;
    while (i < n) : (i += 1) slots[i] = b.allocReg();
    // The call's simple name (set by the Call lowering just before this)
    // is the implicit label of any lambda literal directly in this
    // argument list. Re-arm it before each argument so a trailing lambda
    // records it, then clear it so it never leaks past this run.
    const call_label = b.pending_lambda_label;
    b.pending_lambda_label = null;
    // Arguments are not in the call's tail position, so the enclosing
    // expected-type hint must not reach a reified inline call here.
    const prev_expected = b.pushExpected(null);
    for (slots, 0..) |slot, j| {
        b.pending_lambda_label = call_label;
        const r = try expr_mod.lowerExpr(b, &args[j]);
        b.pending_lambda_label = null;
        try b.push(.{ .Move = .{ .dst = slot, .src = r } });
    }
    b.restoreExpected(prev_expected);
    return .{ first, @intCast(n) };
}

/// Intern an `arg_names` slice into a parallel `[]?ConstId` suitable for
/// `Inst.Call` / `CallMember` / `CallValue` / `NewInstance`. Returns an
/// empty slice when every entry is null (positional-only). The caller
/// owns the returned slice.
pub fn internArgNames(
    allocator: Allocator,
    module: *Module,
    arg_names: []const ?[]const u8,
) Allocator.Error![]?ConstId {
    var any = false;
    for (arg_names) |opt| {
        if (opt != null) {
            any = true;
            break;
        }
    }
    if (!any) return &.{};
    const out = try allocator.alloc(?ConstId, arg_names.len);
    for (arg_names, out) |opt, *slot| {
        slot.* = if (opt) |s| try module.internConst(allocator, .{ .String = s }) else null;
    }
    return out;
}

pub fn internTypeArgs(
    allocator: Allocator,
    module: *Module,
    type_args: []const ast.TypeRef,
) Allocator.Error![]ConstId {
    if (type_args.len == 0) return &.{};
    const out = try allocator.alloc(ConstId, type_args.len);
    for (type_args, out) |t, *slot| {
        slot.* = try module.internConst(allocator, .{ .String = t.name.name });
    }
    return out;
}

pub fn astBinop(op: AstBinOp) BinOp {
    return switch (op) {
        .Add => .Add,
        .Sub => .Sub,
        .Mul => .Mul,
        .Div => .Div,
        .Rem => .Mod,
        .Eq => .Eq,
        .Neq => .NotEq,
        .IdentEq => .IdentEq,
        .IdentNeq => .IdentNeq,
        .Lt => .Less,
        .Le => .LessEq,
        .Gt => .Greater,
        .Ge => .GreaterEq,
        .And => .And,
        .Or => .Or,
        .Range => .RangeTo,
        .RangeUntil => .RangeUntil,
        .Elvis => .Elvis,
        // in / !in / assign are not lowered as plain binops; they need
        // dedicated IR instructions. Fall back to Add so the lowering
        // pass remains total; the dedicated forms land in the call /
        // assign lowering.
        .In, .NotIn, .Assign => .Add,
    };
}

pub fn exprSpan(e: *const Expr) ir.Span {
    return e.span();
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;
const span = @import("span");

test {
    testing.refAllDecls(@This());
}

fn dummySpan() span.Span {
    return span.Span.init(span.FileId.from(0), 0, 0);
}

test "ast binop maps rem to mod" {
    try testing.expectEqual(BinOp.Mod, astBinop(.Rem));
    try testing.expectEqual(BinOp.Less, astBinop(.Lt));
    try testing.expectEqual(BinOp.RangeTo, astBinop(.Range));
    try testing.expectEqual(BinOp.Add, astBinop(.In));
}

test "callee label extracts simple name" {
    var seg = [_]ast.Ident{.{ .name = "with", .span = dummySpan() }};
    const path = Expr{ .Path = .{ .segments = &seg, .span = dummySpan() } };
    try testing.expectEqualStrings("with", calleeLabel(&path).?);

    var recvseg = [_]ast.Ident{.{ .name = "sb", .span = dummySpan() }};
    var recv = Expr{ .Path = .{ .segments = &recvseg, .span = dummySpan() } };
    const member = Expr{ .Member = .{ .receiver = &recv, .name = .{ .name = "apply", .span = dummySpan() }, .safe = false, .span = dummySpan() } };
    try testing.expectEqualStrings("apply", calleeLabel(&member).?);
}

test "intern arg names is empty for positional-only" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    const names = [_]?[]const u8{ null, null };
    const out = try internArgNames(testing.allocator, &m, &names);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "intern arg names interns named slots" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    const names = [_]?[]const u8{ null, "x" };
    const out = try internArgNames(testing.allocator, &m, &names);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expect(out[0] == null);
    try testing.expect(out[1] != null);
}

test "intern type args interns simple names" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    const args = [_]ast.TypeRef{.{
        .name = .{ .name = "String", .span = dummySpan() },
        .nullable = false,
        .span = dummySpan(),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    }};
    const out = try internTypeArgs(testing.allocator, &m, &args);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 1), out.len);
}

test "lower arg run reserves sentinel for empty" {
    var m = Module.default(testing.allocator);
    defer m.deinit(testing.allocator);
    var b = try FuncBuilder.init(testing.allocator, &m);
    defer b.deinit();
    const run = try lowerArgRun(&b, &.{});
    try testing.expectEqual(@as(u8, 0), run[1]);
}
