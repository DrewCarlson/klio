//! Binary operator lowering, with the numeric promotion and operand shape
//! probes it consults.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const build = @import("../../build.zig");
const helpers = @import("../helpers.zig");
const ast_scan = @import("../ast_scan.zig");
const stmt_mod = @import("../stmt.zig");
const static_call_type = @import("../static_call_type.zig");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const AstBinOp = ast.BinOp;
const BinOp = ir.BinOp;
const Reg = ir.Reg;
const TypeRef = ir.TypeRef;
const astBinop = helpers.astBinop;
const isAnyTypedPath = helpers.isAnyTypedPath;
const isGenericTypedPath = helpers.isGenericTypedPath;
const isBoxedToAnyForm = ast_scan.isBoxedToAnyForm;
const staticCallReturnTypeRef = static_call_type.staticCallReturnTypeRef;

const expr_mod = @import("../expr.zig");
const lowerExpr = expr_mod.lowerExpr;

const member_mod = @import("member.zig");
const staticBareReceiverType = member_mod.staticBareReceiverType;

const call_mod = @import("call.zig");
const packContiguous = call_mod.packContiguous;

const arg_shape_mod = @import("arg_shape.zig");
const argDeclTypeRefLazy = arg_shape_mod.argDeclTypeRefLazy;
const argLitKind = arg_shape_mod.argLitKind;
const narrowIsCheckAll = arg_shape_mod.narrowIsCheckAll;
const narrowNullCheckAll = arg_shape_mod.narrowNullCheckAll;
const staticListHead = arg_shape_mod.staticListHead;

const type_probe_mod = @import("type_probe.zig");
const paramLitKind = type_probe_mod.paramLitKind;
const simpleTypeHead = type_probe_mod.simpleTypeHead;

const probe_mod = @import("probe.zig");
const argStaticHead = probe_mod.argStaticHead;
const typeHead = probe_mod.typeHead;
const userFunctionDeclared = probe_mod.userFunctionDeclared;

const member_call_mod = @import("member_call.zig");
const lowerResolvedExtensionCall = member_call_mod.lowerResolvedExtensionCall;
const lowerResolvedMemberCall = member_call_mod.lowerResolvedMemberCall;

/// `Binary` lowering: the short-circuiting operators (`&&`, `||`, `?:`),
/// the `in`/`!in` desugars, generic-operand comparisons, and the eager
/// primitive operators.
/// Numeric/string/char/bool simple type heads whose `+`/`-` stay primitive.
pub fn isPrimitiveTypeName(name: []const u8) bool {
    const prims = [_][]const u8{ "Int", "Long", "Short", "Byte", "Double", "Float", "Char", "Boolean", "String", "UInt", "ULong", "UShort", "UByte", "Number" };
    for (prims) |p2| {
        if (std.mem.eql(u8, name, p2)) return true;
    }
    return false;
}

/// Whether a nominal receiver carries enough structural arguments to prove an
/// overload choice. Head-only evidence for a generic class (`List`) cannot
/// substitute its declaration parameters and must not displace a complete
/// declaration-derived type (`List<Int>`).
pub fn staticClassifierArgsComplete(b: *FuncBuilder, ty: TypeRef) bool {
    var identity = std.mem.trimEnd(u8, ty.name, "?");
    if (std.mem.indexOfScalar(u8, identity, '<')) |lt| identity = identity[0..lt];
    const head = typeHead(identity);
    const cid = if (std.mem.indexOfScalar(u8, identity, '.') != null)
        b.module.classIdByFqn(identity)
    else
        b.module.uniqueClassIdBySimpleName(head);
    const class_id = cid orelse return true;
    if (class_id.int() >= b.module.classes.items.len) return false;
    const class = &b.module.classes.items[class_id.int()];
    return ty.args.len >= class.type_params.len;
}

/// Resolve a non-primitive binary operator through the same member/extension
/// declaration engine as its explicit-call form (`a + b` is `a.plus(b)`).
/// The static argument type is essential for overloads such as
/// `Collection<T>.plus(element: T)` versus `.plus(elements: Sequence<T>)`.
fn lowerResolvedBinaryOperator(
    b: *FuncBuilder,
    op: AstBinOp,
    lhs: *const Expr,
    rhs: *const Expr,
    call_span: ast.Span,
) Allocator.Error!?Reg {
    const method: []const u8 = switch (op) {
        .Add => "plus",
        .Sub => "minus",
        else => return null,
    };

    var inferred_lhs_ty: ?ir.TypeRef = null;
    defer if (inferred_lhs_ty) |*ty| ty.deinit(b.allocator);
    if (lhs.* == .Call or lhs.* == .Binary) {
        inferred_lhs_ty = try staticCallReturnTypeRef(b, lhs);
    }
    if (runtime.envOnce("KLIO_HOP_TRACE") != null) {
        const lazy = argDeclTypeRefLazy(b, lhs);
        const bare: ?[]const u8 = if (lhs.* == .Path and lhs.Path.segments.len == 1)
            staticBareReceiverType(b, lhs.Path.segments[0].name)
        else
            null;
        std.debug.print("[binop-in] {s} lhs={s} inferred={s} lazy={s} bare={s} owner={s}\n", .{
            method,
            @tagName(std.meta.activeTag(lhs.*)),
            if (inferred_lhs_ty) |t| t.name else "-",
            if (lazy) |t| t.name else "-",
            bare orelse "-",
            b.ownerClass() orelse "-",
        });
    }
    const declared_lhs_ty = inferred_lhs_ty orelse
        argDeclTypeRefLazy(b, lhs) orelse return null;
    if (isPrimitiveTypeName(typeHead(declared_lhs_ty.name))) return null;
    if (!staticClassifierArgsComplete(b, declared_lhs_ty)) return null;

    const args = rhs[0..1];
    const ident = ast.Ident{ .name = method, .span = call_span };
    const member_form = try lowerResolvedMemberCall(
        b,
        lhs,
        ident,
        args,
        &.{},
        &.{},
        declared_lhs_ty,
        .{},
    );
    if (runtime.envOnce("KLIO_HOP_TRACE") != null) {
        std.debug.print("[binop] {s} lhs_ty={s} member={s}\n", .{
            method,
            declared_lhs_ty.name,
            @tagName(std.meta.activeTag(member_form)),
        });
    }
    switch (member_form) {
        .lowered => |reg| return reg,
        .deferred => return null,
        .none => {},
    }
    member_call_mod.ext_route_tag = "lowerResolvedBinaryOperator:1404";
    return try lowerResolvedExtensionCall(
        b,
        lhs,
        ident,
        args,
        &.{},
        &.{},
        declared_lhs_ty,
    );
}

pub fn lowerBinary(b: *FuncBuilder, bin: anytype) Allocator.Error!Reg {
    const elvis_tail = b.tail_here;
    const op = bin.op;
    const lhs = bin.lhs;
    const rhs = bin.rhs;

    if (try lowerResolvedBinaryOperator(b, op, lhs, rhs, bin.span)) |reg| {
        return reg;
    }

    // Compatibility path for a known `this` receiver whose declaration set
    // is not yet complete enough for exact resolution. The shared resolver
    // runs first so smart casts and overload applicability can select the
    // precise static extension before this name-based fallback.
    if ((op == .Add or op == .Sub) and lhs.* == .This and lhs.This.qualifier == null) {
        const sty: ?[]const u8 = b.recvTy() orelse b.enclosingRecvTy();
        if (sty) |ty| {
            if (!isPrimitiveTypeName(ty)) {
                const l = try lowerExpr(b, lhs);
                const r = try lowerExpr(b, rhs);
                const args_start = try packContiguous(b, &.{r});
                const dst = b.allocReg();
                const nm = try b.module.internConst(b.allocator, .{ .String = if (op == .Add) "plus" else "minus" });
                try b.push(.{ .CallMember = .{
                    .dst = dst,
                    .receiver = l,
                    .name = nm,
                    .static_recv = try b.module.internConst(b.allocator, .{ .String = ty }),
                    .args = args_start,
                    .n_args = 1,
                    .arg_names = &.{},
                } });
                return dst;
            }
        }
    }

    // `list + (x as Any)`: kotlinc resolves `plus(element: T)` from the
    // RHS's STATIC type, appending the value as one element even when it
    // is itself a list at runtime. Route a statically list-headed LHS
    // with an Any-cast RHS through `plusElement`.
    if (op == .Add and staticListHead(lhs) and ast_scan.isBoxedToAnyForm(rhs)) {
        const l = try lowerExpr(b, lhs);
        const r = try lowerExpr(b, rhs);
        const args_start = try packContiguous(b, &.{r});
        const dst = b.allocReg();
        const nm = try b.module.internConst(b.allocator, .{ .String = "plusElement" });
        try b.push(.{ .CallMember = .{
            .dst = dst,
            .receiver = l,
            .name = nm,
            .args = args_start,
            .n_args = 1,
        } });
        return dst;
    }

    // `==` on a boxed operand (an `Any`-typed or generic type-parameter value,
    // e.g. `assertEquals(expected: T, actual: T)`) uses total-order equality —
    // `NaN == NaN` is true and `0.0 != -0.0`, matching boxed `Double.equals`.
    if ((op == .Eq or op == .Neq) and
        (isBoxedToAnyForm(lhs) or isBoxedToAnyForm(rhs) or
            isAnyTypedPath(b, lhs) or isAnyTypedPath(b, rhs) or
            isGenericTypedPath(b, lhs) or isGenericTypedPath(b, rhs) or
            isComparableCast(lhs) or isComparableCast(rhs) or
            (lhs.* == .Path and lhs.Path.segments.len == 1 and comparableTypedLocal(b, lhs.Path.segments[0].name)) or
            (rhs.* == .Path and rhs.Path.segments.len == 1 and comparableTypedLocal(b, rhs.Path.segments[0].name))))
    {
        const l = try lowerExpr(b, lhs);
        const r = try lowerExpr(b, rhs);
        const dst = b.allocReg();
        const ir_op: BinOp = if (op == .Eq) .BoxedEq else .BoxedNotEq;
        try b.push(.{ .BinOp = .{ .dst = dst, .op = ir_op, .lhs = l, .rhs = r } });
        return dst;
    }

    // `x in haystack` / `x !in haystack`.
    if (op == .In or op == .NotIn) {
        // `x in lo..hi` / `x in lo..<hi` with a range *literal* on the right
        // lowers to `lo <= x && x <(=) hi` — but only when `x` is provably a
        // scalar element. A range-valued `x` dispatches `contains` instead
        // (an in-scope `operator LongRange.contains(LongRange)` decides
        // range-in-range; the element compare would be wrong for it).
        if (rhs.* == .Binary and (rhs.Binary.op == .Range or rhs.Binary.op == .RangeUntil) and
            !lhsIsRangeShaped(b, lhs) and try rangeCompareApplies(b, lhs, rhs.Binary.lhs, rhs.Binary.rhs))
        {
            const r_op = rhs.Binary.op;
            const lo = rhs.Binary.lhs;
            const hi = rhs.Binary.rhs;
            // `(lo..hi).contains(x)`: the bounds are evaluated before the
            // element, as kotlinc orders the desugared call.
            const lo_r = try lowerExpr(b, lo);
            const hi_r = try lowerExpr(b, hi);
            const x = try lowerExpr(b, lhs);
            const ge = b.allocReg();
            try b.push(.{ .BinOp = .{ .dst = ge, .op = .LessEq, .lhs = lo_r, .rhs = x } });
            const upper: BinOp = if (r_op == .RangeUntil) .Less else .LessEq;
            const le = b.allocReg();
            try b.push(.{ .BinOp = .{ .dst = le, .op = upper, .lhs = x, .rhs = hi_r } });
            const both = b.allocReg();
            try b.push(.{ .BinOp = .{ .dst = both, .op = .And, .lhs = ge, .rhs = le } });
            if (op == .NotIn) {
                const dst = b.allocReg();
                try b.push(.{ .Not = .{ .dst = dst, .src = both } });
                return dst;
            }
            return both;
        }
        // `x in y` is `y.contains(x)`: lower the written-out member call so
        // it binds statically like the explicit form (a user extension
        // `IntRange.contains(String)` is a direct call, not a name walk).
        const callee_node = try b.allocator.create(Expr);
        callee_node.* = .{ .Member = .{
            .receiver = @constCast(rhs),
            .name = .{ .name = "contains", .span = bin.span },
            .safe = false,
            .span = bin.span,
        } };
        const call_args = try b.allocator.alloc(Expr, 1);
        call_args[0] = lhs.*;
        const call_names = try b.allocator.alloc(?[]const u8, 1);
        call_names[0] = null;
        const call_node = try b.allocator.create(Expr);
        call_node.* = .{ .Call = .{
            .callee = callee_node,
            .args = call_args,
            .arg_names = call_names,
            .type_args = &.{},
            .is_infix = false,
            .span = bin.span,
        } };
        const contains = try lowerExpr(b, call_node);
        if (op == .NotIn) {
            const dst = b.allocReg();
            try b.push(.{ .Not = .{ .dst = dst, .src = contains } });
            return dst;
        }
        return contains;
    }

    // Elvis `a ?: b` short-circuits.
    if (op == .Elvis) {
        const l = try lowerExpr(b, lhs);
        const null_r = try b.emitConst(.Null);
        const is_null = b.allocReg();
        try b.push(.{ .BinOp = .{ .dst = is_null, .op = .Eq, .lhs = l, .rhs = null_r } });
        const then_b = try b.allocBlock();
        const else_b = try b.allocBlock();
        const join = try b.allocBlock();
        const dst = b.allocReg();
        b.terminate(.{ .Branch = .{ .cond = is_null, .t = then_b, .f = else_b } });
        b.switchTo(then_b);
        b.tail_pos = elvis_tail;
        const rv = try lowerExpr(b, rhs);
        try b.push(.{ .Move = .{ .dst = dst, .src = rv } });
        b.terminate(.{ .Goto = join });
        b.switchTo(else_b);
        try b.push(.{ .Move = .{ .dst = dst, .src = l } });
        b.terminate(.{ .Goto = join });
        b.switchTo(join);
        return dst;
    }

    // Logical `&&` / `||`.
    if (op == .And or op == .Or) {
        const l = try lowerExpr(b, lhs);
        const then_b = try b.allocBlock();
        const else_b = try b.allocBlock();
        const join = try b.allocBlock();
        const dst = b.allocReg();
        b.terminate(.{ .Branch = .{ .cond = l, .t = then_b, .f = else_b } });
        if (op == .And) {
            b.switchTo(then_b);
            // The right operand sees every proof the left one establishes:
            // `it is UByte && it.toByte() ...` smart-casts `it` for the
            // member call, exactly as an `if` guard narrows its then-arm.
            var narrowed: std.ArrayList(build.FuncBuilder.NarrowedLocal) = .empty;
            defer narrowed.deinit(b.allocator);
            try narrowIsCheckAll(b, lhs, &narrowed);
            var not_null: std.ArrayList(build.FuncBuilder.NarrowedLocal) = .empty;
            defer not_null.deinit(b.allocator);
            try narrowNullCheckAll(b, lhs, true, &not_null);
            b.tail_pos = elvis_tail;
            const rv = try lowerExpr(b, rhs);
            var nn = not_null.items.len;
            while (nn > 0) : (nn -= 1) b.restoreLocal(not_null.items[nn - 1]);
            var ni = narrowed.items.len;
            while (ni > 0) : (ni -= 1) b.restoreLocal(narrowed.items[ni - 1]);
            try b.push(.{ .Move = .{ .dst = dst, .src = rv } });
            b.terminate(.{ .Goto = join });
            b.switchTo(else_b);
            const false_r = try b.emitConst(.{ .Bool = false });
            try b.push(.{ .Move = .{ .dst = dst, .src = false_r } });
            b.terminate(.{ .Goto = join });
        } else {
            b.switchTo(then_b);
            const true_r = try b.emitConst(.{ .Bool = true });
            try b.push(.{ .Move = .{ .dst = dst, .src = true_r } });
            b.terminate(.{ .Goto = join });
            b.switchTo(else_b);
            // `x == null || x.m()` runs its right operand only when the
            // left is false, which proves the null-checks' falsy side.
            var else_not_null: std.ArrayList(build.FuncBuilder.NarrowedLocal) = .empty;
            defer else_not_null.deinit(b.allocator);
            try narrowNullCheckAll(b, lhs, false, &else_not_null);
            b.tail_pos = elvis_tail;
            const rv = try lowerExpr(b, rhs);
            var en = else_not_null.items.len;
            while (en > 0) : (en -= 1) b.restoreLocal(else_not_null.items[en - 1]);
            try b.push(.{ .Move = .{ .dst = dst, .src = rv } });
            b.terminate(.{ .Goto = join });
        }
        b.switchTo(join);
        return dst;
    }

    // Comparison on a generic type-parameter operand → `a.compareTo(b) <op> 0`.
    // Inside a function that declares its own type parameters, an operand
    // with no concrete static type (`var min = iterator.next()` in the
    // generic `minOrNull` body) is `T`-typed under Kotlin's inference, so
    // the comparison also follows the `compareTo` total order — the IEEE
    // primitive comparison applies only where a numeric static type is
    // established (a literal, or a local with a numeric declared type or
    // literal initializer).
    if ((op == .Lt or op == .Le or op == .Gt or op == .Ge) and
        (isGenericOperand(b, lhs) or isGenericOperand(b, rhs) or
            (b.hasOwnTypeParams() and
                !staticallyOrderedOperand(b, lhs) and !staticallyOrderedOperand(b, rhs))))
    {
        const recv = try lowerExpr(b, lhs);
        const arg_slot = b.allocReg();
        const r = try lowerExpr(b, rhs);
        try b.push(.{ .Move = .{ .dst = arg_slot, .src = r } });
        const cmp = b.allocReg();
        const nm = try b.module.internConst(b.allocator, .{ .String = "compareTo" });
        try b.push(.{ .CallMember = .{
            .dst = cmp,
            .receiver = recv,
            .name = nm,
            .args = arg_slot,
            .n_args = 1,
            .arg_names = &.{},
        } });
        const zero = try b.emitConst(.{ .Int = 0 });
        const dst = b.allocReg();
        try b.push(.{ .BinOp = .{ .dst = dst, .op = astBinop(op), .lhs = cmp, .rhs = zero } });
        return dst;
    }

    const l0 = try lowerExpr(b, lhs);
    // `it + x` / `it - x` where `it` is statically a broad collection
    // (`Iterable`/`Collection`) produces a `List` even when the runtime value
    // is a `Set`; coerce the receiver to a list so the `List`-returning
    // `plus`/`minus` is dispatched rather than the `Set`-returning one.
    const l = if (op == .Add or op == .Sub)
        try helpers.coerceBroadCollectionToList(b, lhs, l0)
    else
        l0;
    const r = try lowerExpr(b, rhs);
    const dst = b.allocReg();
    try b.push(.{ .BinOp = .{ .dst = dst, .op = astBinop(op), .lhs = l, .rhs = r } });
    return dst;
}

fn isGenericOperand(b: *FuncBuilder, e: *const Expr) bool {
    return (e.* == .Path and e.Path.segments.len == 1 and
        (b.isGenericTypedParam(e.Path.segments[0].name) or comparableTypedLocal(b, e.Path.segments[0].name))) or
        isComparableCast(e);
}

/// A local or parameter declared as `Comparable<…>` orders by `compareTo`
/// and compares by `equals`, like a value read through a `Comparable` cast.
fn comparableTypedLocal(b: *FuncBuilder, name: []const u8) bool {
    const t = b.localDeclType(name) orelse return false;
    return std.mem.eql(u8, simpleTypeHead(t), "Comparable");
}

/// `(x as Comparable<Double>) >= y`: a value read through `Comparable`
/// orders by `compareTo` (the total order) and compares by `equals`.
fn isComparableCast(e: *const Expr) bool {
    if (e.* != .As) return false;
    return std.mem.eql(u8, simpleTypeHead(e.As.ty.name.name), "Comparable");
}

/// A comparison operand with an established concrete static type: a literal,
/// or a plain local/param whose declared type is a known builtin value head
/// or whose recorded initializer is a literal. Such an operand keeps the
/// primitive `BinOp` comparison inside a generic function; everything else
/// there is `T`-typed under Kotlin's inference and dispatches `compareTo`.
fn staticallyOrderedOperand(b: *FuncBuilder, e: *const Expr) bool {
    if (argLitKind(e) != null) return true;
    if (e.* == .Path and e.Path.segments.len == 1) {
        const n = e.Path.segments[0].name;
        if (b.localDeclType(n)) |t| return paramLitKind(t) != null;
        if (b.localInitExpr(n)) |ie| return argLitKind(ie) != null;
    }
    return false;
}

/// Write `val` back to the lvalue `target` (shared by prefix ++/-- and the
/// postfix path's pre-snapshot path). Delegates to the single write-back
/// decision in `stmt_mod.storeCombinedToTarget` so compound-assign, prefix,
/// and postfix never diverge on where a bare name lands (local / cell /
/// capture / own-member / lambda-this / top-level global).
pub fn writeBackLvalue(b: *FuncBuilder, target: *const Expr, val: Reg) Allocator.Error!void {
    try stmt_mod.storeCombinedToTarget(b, target, val);
}

/// Kotlin's promotion for arithmetic over the built-in numeric types: the
/// wider operand wins, with the unsigned family kept separate (mixing signed
/// and unsigned is not an operator Kotlin defines).
pub fn numericPromotion(a: []const u8, c: []const u8) ?[]const u8 {
    const order = [_][]const u8{ "Double", "Float", "Long", "Int", "Short", "Byte" };
    const uorder = [_][]const u8{ "ULong", "UInt", "UShort", "UByte" };
    const rank = struct {
        fn f(set: []const []const u8, n: []const u8) ?usize {
            for (set, 0..) |s2, i| {
                if (std.mem.eql(u8, s2, n)) return i;
            }
            return null;
        }
    }.f;
    if (rank(&order, a)) |ra| {
        const rc = rank(&order, c) orelse return null;
        // Byte/Short arithmetic yields Int in Kotlin — there is no
        // `Byte.plus(Byte): Byte`.
        const winner = order[@min(ra, rc)];
        if (std.mem.eql(u8, winner, "Short") or std.mem.eql(u8, winner, "Byte")) return "Int";
        return winner;
    }
    if (rank(&uorder, a)) |ra| {
        const rc = rank(&uorder, c) orelse return null;
        const winner = uorder[@min(ra, rc)];
        if (std.mem.eql(u8, winner, "UShort") or std.mem.eql(u8, winner, "UByte")) return "UInt";
        return winner;
    }
    return null;
}

/// The static-type head of a call argument when it is a plain local whose
/// declared type is known — used to disambiguate cast-rebound overloads by
/// parameter type (an `Iterable<Int>` arg must not bind an `IntRange` param).
/// Whether `lhs` of an `in` test is provably a RANGE value (a range
/// literal, or a binding declared with a range-family type), so the
/// element-compare inline for `x in lo..hi` must stand down in favor of a
/// `contains` dispatch.
/// Whether `x in lo..hi` may lower to the scalar compare `lo <= x && x <= hi`:
/// every operand is provably a non-null numeric scalar and no user operator
/// `rangeTo`/`contains` is declared that could take the call instead. Any
/// other shape dispatches `contains` on the range value.
fn rangeCompareApplies(b: *FuncBuilder, x: *const Expr, lo: *const Expr, hi: *const Expr) Allocator.Error!bool {
    if (userFunctionDeclared(b, "rangeTo") or userFunctionDeclared(b, "contains")) return false;
    return try scalarNumericShaped(b, x, 0) and try scalarNumericShaped(b, lo, 0) and try scalarNumericShaped(b, hi, 0);
}

fn numericScalarHead(head: []const u8) bool {
    for ([_][]const u8{
        "Int",   "Long",  "Short",  "Byte",   "Char",  "Double",
        "Float", "UInt",  "ULong",  "UShort", "UByte",
    }) |n| {
        if (std.mem.eql(u8, head, n)) return true;
    }
    return false;
}

fn scalarNumericShaped(b: *FuncBuilder, e: *const Expr, depth: u8) Allocator.Error!bool {
    if (depth > 6) return false;
    switch (e.*) {
        .IntLit, .FloatLit, .CharLit => return true,
        .Unary => |u| return try scalarNumericShaped(b, u.expr, depth + 1),
        .Binary => |bin| return switch (bin.op) {
            .Add, .Sub, .Mul, .Div, .Rem => try scalarNumericShaped(b, bin.lhs, depth + 1) and try scalarNumericShaped(b, bin.rhs, depth + 1),
            else => false,
        },
        .Path => |p| {
            if (p.segments.len != 1) return false;
            const nm = p.segments[0].name;
            if (b.localDeclType(nm)) |t| {
                if (std.mem.endsWith(u8, t, "?") or b.localDeclNullable(nm)) return false;
                return numericScalarHead(typeHead(t));
            }
            if (b.localInitExpr(nm)) |init| return try scalarNumericShaped(b, init, depth + 1);
            return false;
        },
        .Call => {
            const ty = try static_call_type.staticCallReturnTypeRef(b, e) orelse return false;
            if (ty.nullable or std.mem.endsWith(u8, ty.name, "?")) return false;
            return numericScalarHead(typeHead(ty.name));
        },
        else => return false,
    }
}

fn lhsIsRangeShaped(b: *FuncBuilder, lhs: *const Expr) bool {
    if (lhs.* == .Binary and (lhs.Binary.op == .Range or lhs.Binary.op == .RangeUntil)) return true;
    const head = argStaticHead(b, lhs) orelse return false;
    for ([_][]const u8{
        "IntRange",        "LongRange",        "CharRange",       "UIntRange",
        "ULongRange",      "IntProgression",   "LongProgression", "CharProgression",
        "UIntProgression", "ULongProgression", "ClosedRange",     "OpenEndRange",
    }) |fam| {
        if (std.mem.eql(u8, head, fam)) return true;
    }
    return false;
}

pub fn scalarBitBinOp(name: []const u8) ?ir.BinOp {
    if (std.mem.eql(u8, name, "and")) return .And;
    if (std.mem.eql(u8, name, "or")) return .Or;
    if (std.mem.eql(u8, name, "xor")) return .Xor;
    if (std.mem.eql(u8, name, "shl")) return .Shl;
    if (std.mem.eql(u8, name, "shr")) return .Shr;
    if (std.mem.eql(u8, name, "ushr")) return .UShr;
    return null;
}
