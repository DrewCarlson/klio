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

/// True when `e` is a bare name bound to a non-nullable generic type-parameter
/// parameter (`a: T`). Such a value is boxed, so `==` on it is total-order
/// (`NaN == NaN`), matching boxed `Double.equals`.
pub fn isGenericTypedPath(b: *const FuncBuilder, e: *const Expr) bool {
    return switch (e.*) {
        .Path => |p| p.segments.len == 1 and b.isGenericTypedParam(p.segments[0].name),
        else => false,
    };
}

/// A read-only/iterable collection type whose `plus`/`minus` operator returns a
/// `List` regardless of the runtime element container. A `Set` value reached
/// through such a static type must therefore produce a `List`, not a `Set`.
pub fn isBroadCollectionTypeName(name: []const u8) bool {
    const broad = [_][]const u8{ "Iterable", "MutableIterable", "Collection", "MutableCollection" };
    for (broad) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

/// True when `e` names a local/param statically typed as a broad collection
/// (see `isBroadCollectionTypeName`).
pub fn isBroadCollectionReceiver(b: *const FuncBuilder, e: *const Expr) bool {
    return switch (e.*) {
        .Path => |p| p.segments.len == 1 and
            (b.isBroadCollectionLocal(p.segments[0].name) or
                isBroadCollectionClassProp(b, p.segments[0].name)),
        else => false,
    };
}

/// Whether a bare name reads an enclosing-class PROPERTY whose declared
/// type head (type-parameter bounds substituted at registration) is a
/// broad collection — `data` in `IterableTests<T : Iterable<String>>`.
/// Kotlin resolves `data - x` against the static Iterable, producing a
/// List regardless of the runtime collection kind.
fn isBroadCollectionClassProp(b: *const FuncBuilder, name: []const u8) bool {
    if (b.resolve(name) != null or b.knowsOuter(name)) return false;
    const owner = b.ownerClass() orelse return false;
    const heads = b.module.registry.class_prop_type_heads;
    const chain: []const []const u8 = b.module.registry.class_super_names.get(owner) orelse &.{};
    var idx: usize = 0;
    while (idx <= chain.len) : (idx += 1) {
        const cls = if (idx == 0) owner else chain[idx - 1];
        if (heads.get(.{ .a = cls, .b = name })) |head| {
            return std.mem.eql(u8, head, "Iterable") or
                std.mem.eql(u8, head, "Collection") or
                std.mem.eql(u8, head, "MutableCollection");
        }
    }
    return false;
}

/// When `recv_expr` is statically a broad collection, emit `recv.toList()` and
/// return the coerced register so a following `+`/`-` produces a `List`. Other
/// receivers pass through unchanged.
pub fn coerceBroadCollectionToList(
    b: *FuncBuilder,
    recv_expr: *const Expr,
    recv: Reg,
) Allocator.Error!Reg {
    if (!isBroadCollectionReceiver(b, recv_expr)) return recv;
    const dst = b.allocReg();
    const args = b.allocReg();
    const nm = try b.module.internConst(b.allocator, .{ .String = "toList" });
    try b.push(.{ .CallMember = .{
        .dst = dst,
        .receiver = recv,
        .name = nm,
        .args = args,
        .n_args = 0,
        .arg_names = &.{},
    } });
    return dst;
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
    // No rebind: a `when` arm lowers into its own BLOCK without a scope
    // push, so binding the loaded reg here would let a use AFTER the join
    // read a register only the (possibly untaken) arm block defines —
    // `when (v) { 1 -> a++; 2 -> b++ }` left every sibling arm's cell
    // reading Unit after the join. A fresh cell load per use is cheap and
    // register-correct on every path.
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
pub fn lowerArgRun(b: *FuncBuilder, args: []const Expr) Allocator.Error!struct { Reg, u32 } {
    return lowerArgRunWithArity(b, args, null);
}

/// Emit the coerced constant for an integer/float literal (optionally negated)
/// argument whose declared parameter type is a numeric primitive that differs
/// from the literal's natural type (kotlinc literal typing). Only literals are
/// touched, and the negated literal is folded to a constant (no runtime `Neg`).
pub fn coerceNumericLiteralArg(b: *FuncBuilder, e: *const Expr, type_name: []const u8) Allocator.Error!?Reg {
    var int_val: ?i64 = null;
    var flt_val: ?f64 = null;
    switch (e.*) {
        // An integer literal of any integer kind (`5`, `5u`, `5L`) can re-type
        // to a different numeric primitive parameter; the parsed value carries
        // the magnitude regardless of suffix.
        .IntLit => |l| int_val = l.value,
        .FloatLit => |l| flt_val = l.value,
        .Unary => |u| if (u.op == .Neg) switch (u.expr.*) {
            .IntLit => |l| {
                if (l.kind == .Int or l.kind == .Long) int_val = -l.value;
            },
            .FloatLit => |l| flt_val = -l.value,
            else => {},
        },
        else => {},
    }
    const eq = std.mem.eql;
    if (int_val) |iv| {
        if (eq(u8, type_name, "Byte")) return try b.emitConst(.{ .Byte = @truncate(iv) });
        if (eq(u8, type_name, "Short")) return try b.emitConst(.{ .Short = @truncate(iv) });
        if (eq(u8, type_name, "Long")) return try b.emitConst(.{ .Long = iv });
        if (eq(u8, type_name, "Float")) return try b.emitConst(.{ .Float = @floatFromInt(iv) });
        if (eq(u8, type_name, "Double")) return try b.emitConst(.{ .Double = @floatFromInt(iv) });
        const uv: u64 = @bitCast(iv);
        if (eq(u8, type_name, "UByte")) return try b.emitConst(.{ .UByte = @truncate(uv) });
        if (eq(u8, type_name, "UShort")) return try b.emitConst(.{ .UShort = @truncate(uv) });
        if (eq(u8, type_name, "UInt")) return try b.emitConst(.{ .UInt = @truncate(uv) });
        if (eq(u8, type_name, "ULong")) return try b.emitConst(.{ .ULong = uv });
    } else if (flt_val) |fv| {
        if (eq(u8, type_name, "Float")) return try b.emitConst(.{ .Float = @floatCast(fv) });
        if (eq(u8, type_name, "Double")) return try b.emitConst(.{ .Double = fv });
    }
    return null;
}

pub fn lowerArgRunFull(
    b: *FuncBuilder,
    args: []const Expr,
    arg_arity: ?[]const i16,
    param_ty_names: ?[]const ?[]const u8,
) Allocator.Error!struct { Reg, u32 } {
    const n = args.len;
    if (n == 0) return .{ b.allocReg(), 0 };
    const first = b.allocReg();
    var slots = try b.allocator.alloc(Reg, n);
    defer b.allocator.free(slots);
    slots[0] = first;
    var i: usize = 1;
    while (i < n) : (i += 1) slots[i] = b.allocReg();
    // Prefer the enclosing call's own name over the ambient pending label:
    // lowering a call-shaped receiver re-arms the ambient state with the
    // receiver's callee, and the argument lambdas here belong to the call
    // the user wrote, not to its receiver.
    const call_label = b.current_call_label orelse b.pending_lambda_label;
    b.pending_lambda_label = null;
    const arg_broad_masks = b.pending_arg_broad_masks;
    const arg_fn_generic = b.pending_arg_fn_generic;
    const arg_lambda_param_types = b.pending_arg_lambda_param_types;
    const arg_lambda_unit = b.pending_arg_lambda_unit;
    b.pending_arg_broad_masks = null;
    b.pending_arg_fn_generic = null;
    b.pending_arg_lambda_param_types = null;
    b.pending_arg_lambda_unit = null;
    defer if (arg_lambda_unit) |m| b.allocator.free(m);
    const prev_expected = b.pushExpected(null);
    for (slots, 0..) |slot, j| {
        // A sibling-solved expected type applies to exactly one arg node.
        if (b.sib_expected_site) |site| {
            if (site == @as(*const anyopaque, @ptrCast(&args[j]))) b.restoreExpected(b.sib_expected_ty);
        }
        b.pending_lambda_label = call_label;
        b.pending_lambda_arity = if (arg_arity) |aa| (if (j < aa.len) aa[j] else -1) else -1;
        b.pending_lambda_broad_mask = if (arg_broad_masks) |m| (if (j < m.len) m[j] else 0) else 0;
        b.pending_ref_fn_generic = if (arg_fn_generic) |g| (j < g.len and g[j]) else false;
        b.pending_ref_lambda_param_types = if (arg_lambda_param_types) |types|
            (if (j < types.len) types[j] else null)
        else
            null;
        b.pending_ref_lambda_unit = if (arg_lambda_unit) |m| (j < m.len and m[j]) else false;
        const coerced: ?Reg = if (param_ty_names) |pts|
            (if (j < pts.len) (if (pts[j]) |tn| try coerceNumericLiteralArg(b, &args[j], tn) else null) else null)
        else
            null;
        const r = coerced orelse try expr_mod.lowerExpr(b, &args[j]);
        b.pending_lambda_label = null;
        b.pending_lambda_arity = -1;
        b.pending_lambda_broad_mask = 0;
        b.pending_ref_fn_generic = false;
        b.pending_ref_lambda_param_types = null;
        b.pending_ref_lambda_unit = false;
        if (b.sib_expected_site != null) b.restoreExpected(null);
        try b.push(.{ .Move = .{ .dst = slot, .src = r } });
    }
    b.restoreExpected(prev_expected);
    return .{ first, @intCast(n) };
}

/// As `lowerArgRun`, with an optional per-argument expected lambda arity
/// (parallel to `args`). A zero-`->` lambda in slot `j` binds its implicit
/// `it` only when `arg_arity[j] == 1`; for `0` (a `() -> R` or receiver
/// lambda) the `it` reference resolves to an enclosing lambda. Passed
/// explicitly rather than through builder state so a stale value can never
/// leak into an unrelated call's arguments.
pub fn lowerArgRunWithArity(b: *FuncBuilder, args: []const Expr, arg_arity: ?[]const i16) Allocator.Error!struct { Reg, u32 } {
    const arg_lambda_unit = b.pending_arg_lambda_unit;
    b.pending_arg_lambda_unit = null;
    defer if (arg_lambda_unit) |m| b.allocator.free(m);
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
    // The call's simple name is the implicit label of any lambda literal
    // directly in this argument list. Re-arm it before each argument so a
    // trailing lambda records it, then clear it so it never leaks past
    // this run. The scoped `current_call_label` wins over the ambient
    // pending label, which a call-shaped receiver re-arms in passing.
    const call_label = b.current_call_label orelse b.pending_lambda_label;
    b.pending_lambda_label = null;
    const arg_broad_masks = b.pending_arg_broad_masks;
    const arg_fn_generic = b.pending_arg_fn_generic;
    const arg_lambda_param_types = b.pending_arg_lambda_param_types;
    b.pending_arg_broad_masks = null;
    b.pending_arg_fn_generic = null;
    b.pending_arg_lambda_param_types = null;
    // Arguments are not in the call's tail position, so the enclosing
    // expected-type hint must not reach a reified inline call here.
    const prev_expected = b.pushExpected(null);
    for (slots, 0..) |slot, j| {
        // A sibling-solved expected type applies to exactly one arg node.
        if (b.sib_expected_site) |site| {
            if (site == @as(*const anyopaque, @ptrCast(&args[j]))) b.restoreExpected(b.sib_expected_ty);
        }
        b.pending_lambda_label = call_label;
        b.pending_lambda_arity = if (arg_arity) |aa| (if (j < aa.len) aa[j] else -1) else -1;
        b.pending_lambda_broad_mask = if (arg_broad_masks) |m| (if (j < m.len) m[j] else 0) else 0;
        b.pending_ref_fn_generic = if (arg_fn_generic) |g| (j < g.len and g[j]) else false;
        b.pending_ref_lambda_param_types = if (arg_lambda_param_types) |types|
            (if (j < types.len) types[j] else null)
        else
            null;
        b.pending_ref_lambda_unit = if (arg_lambda_unit) |m| (j < m.len and m[j]) else false;
        const r = try expr_mod.lowerExpr(b, &args[j]);
        b.pending_lambda_label = null;
        b.pending_lambda_arity = -1;
        b.pending_lambda_broad_mask = 0;
        b.pending_ref_fn_generic = false;
        b.pending_ref_lambda_param_types = null;
        b.pending_ref_lambda_unit = false;
        if (b.sib_expected_site != null) b.restoreExpected(null);
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

/// `internTypeArgs` with the lexical-scope type-rename ladder applied: a
/// reified type argument naming a mangled nested class (`enumEntries<Item>()`
/// inside a class whose nested `Item` lifted as `A$Item`) records the LIFTED
/// name, so the runtime class lookup hits the real ClassDef.
pub fn internTypeArgsScoped(
    b: *FuncBuilder,
    type_args: []const ast.TypeRef,
) Allocator.Error![]ConstId {
    if (type_args.len == 0) return &.{};
    const out = try b.allocator.alloc(ConstId, type_args.len);
    for (type_args, out) |t, *slot| {
        // A bare name matching an active splice's reified parameter means
        // the bound ACTUAL (lexical substitution) — `typeOf<T>()` inside a
        // spliced `typeInfo<List<Int>>()` stamps `List<Int>` even when the
        // callee's type params are registered in another module's registry.
        const nm = b.resolveReifiedTypeName(t.name.name) orelse
            qualifiedClassName(b, &t) orelse
            (expr_mod.scopeTypeRename(b, t.name.name, t.name.span.file.int()) orelse t.name.name);
        // A nested-generic argument (`typeOf<List<Int>>()`) stamps its FULL
        // spelling so runtime KType materialisation sees the arguments;
        // class-resolving consumers strip at `<`. Plain heads stamp as-is.
        const head = if (t.type_args.len == 0) nm else try renderFullTypeArg(b, nm, &t);
        // NULLABILITY is part of the argument: `filterIsInstance<Int?>()`
        // differs from `filterIsInstance<Int>()` only in the `?`, and the
        // body's `is T` is what reads it. A head already carrying one (a
        // reified substitution of a nullable actual) is left alone.
        const full = if (t.nullable and !std.mem.endsWith(u8, head, "?"))
            try std.fmt.allocPrint(b.allocator, "{s}?", .{head})
        else
            head;
        slot.* = try b.module.internConst(b.allocator, .{ .String = full });
    }
    return out;
}

/// A DOTTED type spelling (`Outer.B`) names the class the fqn suffix
/// resolves to; its registered (lifted) name is what the runtime class
/// table holds — the bare tail would answer another same-named class.
fn qualifiedClassName(b: *FuncBuilder, t: *const ast.TypeRef) ?[]const u8 {
    const qp = t.qualified_path orelse return null;
    const cid = b.module.classIdByQualifiedSuffix(qp) orelse return null;
    if (cid.int() >= b.module.classes.items.len) return null;
    return b.module.classes.items[cid.int()].name;
}

fn renderFullTypeArg(b: *FuncBuilder, head: []const u8, t: *const ast.TypeRef) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(b.allocator, head);
    try buf.append(b.allocator, '<');
    for (t.type_args, 0..) |*ta, i| {
        if (i != 0) try buf.appendSlice(b.allocator, ", ");
        if (ta.is_star) {
            try buf.append(b.allocator, '*');
            continue;
        }
        const inner_head = b.resolveReifiedTypeName(ta.ty.name.name) orelse
            qualifiedClassName(b, &ta.ty) orelse
            (expr_mod.scopeTypeRename(b, ta.ty.name.name, ta.ty.name.span.file.int()) orelse ta.ty.name.name);
        const inner = if (ta.ty.type_args.len == 0) blk: {
            if (!ta.ty.nullable) break :blk inner_head;
            break :blk try std.fmt.allocPrint(b.allocator, "{s}?", .{inner_head});
        } else try renderFullTypeArg(b, inner_head, &ta.ty);
        try buf.appendSlice(b.allocator, inner);
    }
    try buf.append(b.allocator, '>');
    if (t.nullable) try buf.append(b.allocator, '?');
    return buf.toOwnedSlice(b.allocator);
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
