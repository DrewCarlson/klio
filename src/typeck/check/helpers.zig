//! Shared helper functions for the type checker.

const std = @import("std");

const span = @import("span");
const ast = @import("ast");
const types = @import("types");

const root = @import("../check.zig");

const Allocator = std.mem.Allocator;
const Span = span.Span;
const Type = types.Type;
const GenericArg = types.GenericArg;
const Variance = types.Variance;
const builtinByName = types.builtinByName;
const convertTypeRefLossy = types.convertTypeRefLossy;

const TypeRef = ast.TypeRef;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Block = ast.Block;
const Decl = ast.Decl;
const Accessor = ast.Accessor;
const FunctionBody = ast.FunctionBody;
const AssignOp = ast.AssignOp;
const Annotation = ast.Annotation;
const WhenPatternKind = ast.WhenPatternKind;
const StringPart = ast.StringPart;

const ClassInfo = root.ClassInfo;
const FnSig = root.FnSig;

pub fn typeRefUses(t: *const TypeRef, name: []const u8) bool {
    // `@UnsafeVariance` annotation on the TypeRef itself suppresses the
    // declaration-site variance position check at this occurrence.
    if (hasUnsafeVariance(t.annotations)) {
        return false;
    }
    if (std.mem.eql(u8, t.name.name, name) and t.type_args.len == 0 and t.function == null) {
        return true;
    }
    for (t.type_args) |a| {
        if (!a.is_star and typeRefUses(&a.ty, name)) {
            return true;
        }
    }
    if (t.function) |f| {
        if (f.receiver) |*r| {
            if (typeRefUses(r, name)) return true;
        }
        for (f.params) |*p| {
            if (typeRefUses(p, name)) return true;
        }
        if (typeRefUses(&f.ret, name)) return true;
    }
    return false;
}

pub fn hasUnsafeVariance(anns: []const Annotation) bool {
    return annotationsInclude(anns, "UnsafeVariance");
}

pub fn annotationsInclude(anns: []const Annotation, simple_name: []const u8) bool {
    for (anns) |a| {
        if (a.path.len > 0 and std.mem.eql(u8, a.path[a.path.len - 1].name, simple_name)) {
            return true;
        }
    }
    return false;
}

pub fn hasPublishedApi(anns: []const Annotation) bool {
    return annotationsInclude(anns, "PublishedApi");
}

/// Collect every named type reference appearing inside `t` (head name plus
/// every type-argument head, plus function-type receivers, params, and
/// return). Used by the typealias cycle detector.
pub fn collectAliasedNames(allocator: Allocator, t: *const TypeRef, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    if (t.function) |f| {
        if (f.receiver) |*r| try collectAliasedNames(allocator, r, out);
        for (f.params) |*p| try collectAliasedNames(allocator, p, out);
        try collectAliasedNames(allocator, &f.ret, out);
    } else {
        try out.append(allocator, t.name.name);
    }
    for (t.type_args) |*ta| {
        if (!ta.is_star) try collectAliasedNames(allocator, &ta.ty, out);
    }
}

/// True when `before` and `after` differ structurally — i.e. the
/// substitution actually replaced some `TypeParam`.
pub fn expectedChanged(before: *const Type, after: *const Type) bool {
    return !before.eql(after.*);
}

/// Replaces every `Type.TypeParam(name)` whose `name` is a key in `subst`
/// with the corresponding concrete type. The result owns its heap data.
pub fn substituteTypeParams(
    allocator: Allocator,
    t: *const Type,
    subst: *const std.StringHashMap(Type),
) Allocator.Error!Type {
    switch (t.*) {
        .TypeParam => |n| {
            if (subst.get(n)) |found| return found.clone(allocator);
            return t.clone(allocator);
        },
        .Nullable => |inner| {
            var sub = try substituteTypeParams(allocator, inner, subst);
            return sub.asNullable(allocator);
        },
        .Function => |f| {
            const params = try allocator.alloc(Type, f.params.len);
            for (f.params, params) |*p, *dst| dst.* = try substituteTypeParams(allocator, p, subst);
            const ret = try allocator.create(Type);
            ret.* = try substituteTypeParams(allocator, f.return_type, subst);
            return .{ .Function = .{ .params = params, .return_type = ret, .is_suspend = f.is_suspend, .receiver_head = f.receiver_head } };
        },
        .Range => |inner| {
            const ret = try allocator.create(Type);
            ret.* = try substituteTypeParams(allocator, inner, subst);
            return .{ .Range = ret };
        },
        .Generic => |gen| {
            const args = try allocator.alloc(GenericArg, gen.args.len);
            for (gen.args, args) |*a, *dst| {
                dst.* = .{
                    .variance = a.variance,
                    .is_star = a.is_star,
                    .ty = if (a.is_star) try a.ty.clone(allocator) else try substituteTypeParams(allocator, &a.ty, subst),
                };
            }
            return .{ .Generic = .{ .name = try allocator.dupe(u8, gen.name), .args = args } };
        },
        else => return t.clone(allocator),
    }
}

/// Lowers a `TypeRef` while preserving references to declared type
/// parameters as `Type.TypeParam(name)`. Outside of `tparams`, falls back
/// to `convertTypeRefLossy`.
pub fn convertTypeRefWithTparams(
    allocator: Allocator,
    t: *const TypeRef,
    tparams: *const std.StringHashMap(void),
) Allocator.Error!Type {
    if (std.mem.eql(u8, t.name.name, "*")) {
        return .Any;
    }
    if (tparams.contains(t.name.name) and t.type_args.len == 0 and t.function == null) {
        const inner: Type = .{ .TypeParam = try allocator.dupe(u8, t.name.name) };
        return if (t.nullable) inner.asNullable(allocator) else inner;
    }
    if (t.function) |ft| {
        const params = try allocator.alloc(Type, ft.params.len);
        for (ft.params, params) |*p, *dst| dst.* = try convertTypeRefWithTparams(allocator, p, tparams);
        const ret = try allocator.create(Type);
        ret.* = try convertTypeRefWithTparams(allocator, &ft.ret, tparams);
        const func: Type = .{ .Function = .{ .params = params, .return_type = ret, .is_suspend = ft.is_suspend, .receiver_head = if (ft.receiver) |*r| r.name.name else null } };
        return if (t.nullable) func.asNullable(allocator) else func;
    }
    if (t.type_args.len != 0) {
        const args = try allocator.alloc(GenericArg, t.type_args.len);
        for (t.type_args, args) |*a, *dst| {
            if (a.is_star) {
                dst.* = .{ .variance = Variance.fromAst(a.variance), .is_star = true, .ty = .Any };
            } else {
                dst.* = .{
                    .variance = Variance.fromAst(a.variance),
                    .is_star = false,
                    .ty = try convertTypeRefWithTparams(allocator, &a.ty, tparams),
                };
            }
        }
        const g: Type = .{ .Generic = .{ .name = try allocator.dupe(u8, t.name.name), .args = args } };
        return if (t.nullable) g.asNullable(allocator) else g;
    }
    return convertTypeRefLossy(allocator, t);
}

pub fn classNameFromTyperef(t: *const TypeRef) ?[]const u8 {
    if (t.function != null) return null;
    if (builtinByName(t.name.name) != null) return null;
    return t.name.name;
}

/// Walk a lambda body for a non-local `return`.
pub fn scanLambdaStmtsForReturn(stmts: []const Stmt) bool {
    for (stmts) |s| {
        const hit = switch (s) {
            .Expr => |*e| scanLambdaExprForReturn(e),
            .Assign => |a| scanLambdaExprForReturn(&a.target) or scanLambdaExprForReturn(&a.value),
            .DestructuringDecl => |d| scanLambdaExprForReturn(&d.init),
            .Decl => |d| switch (d) {
                .Property => |p| if (p.init) |*i| scanLambdaExprForReturn(i) else false,
                else => false,
            },
        };
        if (hit) return true;
    }
    return false;
}

pub fn scanLambdaExprForReturn(e: *const Expr) bool {
    return switch (e.*) {
        .Return => true,
        .Lambda, .AnonFun, .ObjectExpr => false,
        .Block => |b| scanLambdaStmtsForReturn(b.stmts),
        .If => |i| scanLambdaExprForReturn(i.cond) or scanLambdaExprForReturn(i.then_branch) or
            (if (i.else_branch) |eb| scanLambdaExprForReturn(eb) else false),
        .While => |w| scanLambdaExprForReturn(w.cond) or scanLambdaExprForReturn(w.body),
        .DoWhile => |w| (if (w.body) |b| scanLambdaExprForReturn(b) else false) or scanLambdaExprForReturn(w.cond),
        .For => |f| scanLambdaExprForReturn(f.iter) or scanLambdaExprForReturn(f.body),
        .When => |w| (if (w.subject) |s| scanLambdaExprForReturn(s) else false) or blk: {
            for (w.branches) |*br| {
                if (scanLambdaExprForReturn(&br.body)) break :blk true;
            }
            break :blk false;
        },
        .Try => |t| scanLambdaStmtsForReturn(t.body.stmts) or blk: {
            for (t.catches) |*c| {
                if (scanLambdaStmtsForReturn(c.body.stmts)) break :blk true;
            }
            break :blk if (t.finally) |fb| scanLambdaStmtsForReturn(fb.stmts) else false;
        },
        .Labeled => |x| scanLambdaExprForReturn(x.expr),
        .Unary => |x| scanLambdaExprForReturn(x.expr),
        .Postfix => |x| scanLambdaExprForReturn(x.expr),
        .Throw => |x| scanLambdaExprForReturn(x.value),
        .Spread => |x| scanLambdaExprForReturn(x.expr),
        .As => |x| scanLambdaExprForReturn(x.expr),
        .IsCheck => |x| scanLambdaExprForReturn(x.expr),
        .Member => |m| scanLambdaExprForReturn(m.receiver),
        .MemberRef => |m| scanLambdaExprForReturn(m.receiver),
        .Call => |c| scanLambdaExprForReturn(c.callee) or anyExprReturn(c.args),
        .Index => |x| scanLambdaExprForReturn(x.receiver) or anyExprReturn(x.args),
        .Binary => |b| scanLambdaExprForReturn(b.lhs) or scanLambdaExprForReturn(b.rhs),
        else => false,
    };
}

fn anyExprReturn(args: []const Expr) bool {
    for (args) |*a| {
        if (scanLambdaExprForReturn(a)) return true;
    }
    return false;
}

pub fn stmtSpan(s: *const Stmt) Span {
    return switch (s.*) {
        .Expr => |*e| e.span(),
        .Decl => |d| switch (d) {
            .Function => |f| f.name.span,
            .Property => |p| p.name.span,
            .Class => |c| c.name.span,
            .Object => |o| o.name.span,
            .TypeAlias => |t| t.name.span,
        },
        .Assign => |a| a.span,
        .DestructuringDecl => |d| d.span,
    };
}

pub fn isBuiltinOverridable(name: []const u8) bool {
    const names = [_][]const u8{
        "toString", "equals", "hashCode", "compareTo", "iterator",
        "next",     "hasNext", "get",      "set",       "size",
        "length",
    };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// The eight actual Kotlin primitive types. `String` is NOT a primitive.
pub fn isPrimitiveTypeName(name: []const u8) bool {
    const names = [_][]const u8{ "Int", "Long", "Short", "Byte", "Float", "Double", "Boolean", "Char" };
    for (names) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

pub fn isConstCapableTypeName(name: []const u8) bool {
    return isPrimitiveTypeName(name) or std.mem.eql(u8, name, "String");
}

pub fn accessorUsesField(a: *const Accessor) bool {
    return switch (a.body) {
        .Block => |b| blockUsesField(&b),
        .Expr => |e| exprUsesField(&e),
    };
}

pub fn blockUsesField(b: *const Block) bool {
    for (b.stmts) |s| {
        const hit = switch (s) {
            .Expr => |*e| exprUsesField(e),
            .Assign => |a| exprUsesField(&a.target) or exprUsesField(&a.value),
            .Decl => |d| switch (d) {
                .Property => |p| if (p.init) |*i| exprUsesField(i) else false,
                else => false,
            },
            else => false,
        };
        if (hit) return true;
    }
    return false;
}

/// Walk `e` and record any bare-name path segment whose first identifier
/// maps to an entry in `by_name`. Used by the T0076 cycle detector.
pub fn collectPropertyReads(
    e: *const Expr,
    by_name: *const std.StringHashMap(usize),
    out: *std.AutoHashMap(usize, void),
) Allocator.Error!void {
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len > 0) {
                if (by_name.get(p.segments[0].name)) |idx| try out.put(idx, {});
            }
        },
        .Call => |c| {
            try collectPropertyReads(c.callee, by_name, out);
            for (c.args) |*a| try collectPropertyReads(a, by_name, out);
        },
        .Index => |x| {
            try collectPropertyReads(x.receiver, by_name, out);
            for (x.args) |*a| try collectPropertyReads(a, by_name, out);
        },
        .Binary => |b| {
            try collectPropertyReads(b.lhs, by_name, out);
            try collectPropertyReads(b.rhs, by_name, out);
        },
        .If => |i| {
            try collectPropertyReads(i.cond, by_name, out);
            try collectPropertyReads(i.then_branch, by_name, out);
            if (i.else_branch) |eb| try collectPropertyReads(eb, by_name, out);
        },
        .When => |w| {
            if (w.subject) |s| try collectPropertyReads(s, by_name, out);
            for (w.branches) |*b| {
                for (b.patterns) |*p| {
                    switch (p.kind) {
                        .Value, .InRange, .NotInRange => |*pe| try collectPropertyReads(pe, by_name, out),
                        else => {},
                    }
                }
                try collectPropertyReads(&b.body, by_name, out);
            }
        },
        .Block => |b| {
            for (b.stmts) |s| {
                if (s == .Expr) try collectPropertyReads(&s.Expr, by_name, out);
            }
        },
        .StringTemplate => |st| {
            for (st.parts) |part| {
                switch (part) {
                    .ShortInterp => |id| {
                        if (by_name.get(id.name)) |idx| try out.put(idx, {});
                    },
                    .Interp => |pe| try collectPropertyReads(pe, by_name, out),
                    .Text => {},
                }
            }
        },
        .Member => |m| try collectPropertyReads(m.receiver, by_name, out),
        .Unary => |x| try collectPropertyReads(x.expr, by_name, out),
        .Postfix => |x| try collectPropertyReads(x.expr, by_name, out),
        .Labeled => |x| try collectPropertyReads(x.expr, by_name, out),
        .Return => |r| {
            if (r.value) |v| try collectPropertyReads(v, by_name, out);
        },
        .Throw => |x| try collectPropertyReads(x.value, by_name, out),
        .IsCheck => |x| try collectPropertyReads(x.expr, by_name, out),
        .As => |x| try collectPropertyReads(x.expr, by_name, out),
        .Spread => |x| try collectPropertyReads(x.expr, by_name, out),
        else => {},
    }
}

/// Spec §7.1.2: does the LHS type carry a built-in or stdlib-shipped
/// matching `*Assign` operator function?
pub fn typeHasCompoundAssign(ty: *const Type, op: AssignOp) bool {
    if (op == .Assign) return false;
    switch (ty.*) {
        .Unresolved, .TypeParam => return true,
        else => {},
    }
    const head: []const u8 = switch (ty.*) {
        .Generic => |g| g.name,
        .Nullable => |inner| return typeHasCompoundAssign(inner, op),
        else => return false,
    };
    const plus_minus_names = [_][]const u8{
        "MutableList",   "MutableSet",     "MutableMap",  "MutableCollection",
        "MutableIterable", "ArrayList",    "HashMap",     "HashSet",
        "LinkedHashMap", "LinkedHashSet",  "StringBuilder", "AtomicInt",
        "AtomicLong",
    };
    var allow_plus_minus = false;
    for (plus_minus_names) |n| {
        if (std.mem.eql(u8, head, n)) {
            allow_plus_minus = true;
            break;
        }
    }
    return switch (op) {
        .Add, .Sub => allow_plus_minus,
        else => std.mem.eql(u8, head, "AtomicInt") or std.mem.eql(u8, head, "AtomicLong"),
    };
}

/// Spec §6.3: labels may only be attached to lambda literals, loop
/// statements, or a call whose trailing argument is a lambda literal.
pub fn isLabelableTarget(e: *const Expr) bool {
    return switch (e.*) {
        .Lambda, .For, .While, .DoWhile => true,
        .Call => |c| c.args.len > 0 and c.args[c.args.len - 1] == .Lambda,
        else => false,
    };
}

pub fn exprUsesField(e: *const Expr) bool {
    return switch (e.*) {
        .Path => |p| p.segments.len == 1 and std.mem.eql(u8, p.segments[0].name, "field"),
        .Block => |b| blockUsesField(&b),
        .If => |i| exprUsesField(i.cond) or exprUsesField(i.then_branch) or
            (if (i.else_branch) |eb| exprUsesField(eb) else false),
        .When => |w| (if (w.subject) |s| exprUsesField(s) else false) or blk: {
            for (w.branches) |*b| {
                if (exprUsesField(&b.body)) break :blk true;
            }
            break :blk false;
        },
        .Call => |c| exprUsesField(c.callee) or anyExprUsesField(c.args),
        .Index => |x| exprUsesField(x.receiver) or anyExprUsesField(x.args),
        .Binary => |b| exprUsesField(b.lhs) or exprUsesField(b.rhs),
        .Return => |r| if (r.value) |v| exprUsesField(v) else false,
        .Member => |m| exprUsesField(m.receiver),
        .Unary => |x| exprUsesField(x.expr),
        .Postfix => |x| exprUsesField(x.expr),
        .As => |x| exprUsesField(x.expr),
        .IsCheck => |x| exprUsesField(x.expr),
        .Spread => |x| exprUsesField(x.expr),
        .Labeled => |x| exprUsesField(x.expr),
        else => false,
    };
}

fn anyExprUsesField(args: []const Expr) bool {
    for (args) |*a| {
        if (exprUsesField(a)) return true;
    }
    return false;
}

pub const PhaseFScope = enum {
    TopLevel,
    Object,
    Class,
};

/// Render a type to an owned display string. Caller frees the result.
pub fn typeDisplay(allocator: Allocator, t: *const Type) Allocator.Error![]u8 {
    return t.toString(allocator);
}

/// Dot-path identity for an `Expr`: returns `Some("a.b.c")` for `Path` /
/// `Member` chains over plain identifiers. Result is owned by `allocator`.
pub fn dotPathKey(allocator: Allocator, e: *const Expr) Allocator.Error!?[]u8 {
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len == 1) return try allocator.dupe(u8, p.segments[0].name);
            return null;
        },
        .Member => |m| {
            if (m.safe) return null;
            const lhs = try dotPathKey(allocator, m.receiver) orelse return null;
            defer allocator.free(lhs);
            return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ lhs, m.name.name });
        },
        else => return null,
    }
}

pub fn singlePathName(e: *const Expr) ?[]const u8 {
    if (e.* == .Path and e.Path.segments.len == 1) {
        return e.Path.segments[0].name;
    }
    return null;
}

/// Element type of a primitive-array class name (`IntArray` -> `Int`).
pub fn primitiveArrayElemByName(name: []const u8) ?Type {
    const short = if (std.mem.startsWith(u8, name, "kotlin.")) name["kotlin.".len..] else name;
    const map = .{
        .{ "IntArray", Type.Int },     .{ "LongArray", Type.Long },
        .{ "ShortArray", Type.Short }, .{ "ByteArray", Type.Byte },
        .{ "DoubleArray", Type.Double }, .{ "FloatArray", Type.Float },
        .{ "BooleanArray", Type.Boolean }, .{ "CharArray", Type.Char },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, short, entry[0])) return entry[1];
    }
    return null;
}

/// Extract the element type of an array-shaped value type. The result owns
/// its heap data when non-null. Recognizes `Array<T>` and the primitive
/// specializations plus their nullable forms.
pub fn arrayElementType(allocator: Allocator, t: *const Type) Allocator.Error!?Type {
    const nn = t.nonNull();
    switch (nn.*) {
        .Generic => |gen| {
            if (std.mem.eql(u8, gen.name, "Array")) {
                if (gen.args.len > 0 and !gen.args[0].is_star) {
                    return try gen.args[0].ty.clone(allocator);
                }
                return null;
            }
            const map = .{
                .{ "IntArray", Type.Int },     .{ "LongArray", Type.Long },
                .{ "ShortArray", Type.Short }, .{ "ByteArray", Type.Byte },
                .{ "DoubleArray", Type.Double }, .{ "FloatArray", Type.Float },
                .{ "BooleanArray", Type.Boolean }, .{ "CharArray", Type.Char },
            };
            inline for (map) |entry| {
                if (std.mem.eql(u8, gen.name, entry[0])) return entry[1];
            }
            return null;
        },
        else => return null,
    }
}

/// True if `a` and `b` are statically compatible enough that an equality
/// comparison is meaningful.
pub fn equalityTypesCompatible(a: *const Type, b: *const Type) bool {
    if (a.* == .Unresolved or b.* == .Unresolved) return true;
    if (a.* == .Nothing or b.* == .Nothing) return true;
    if (a.* == .Any or a.* == .Nullable or b.* == .Any or b.* == .Nullable) {
        if (a.nonNull().* == .Any or b.nonNull().* == .Any) return true;
    }
    if (a.* == .TypeParam or b.* == .TypeParam) return true;
    if (a.isSubtypeOf(b.*) or b.isSubtypeOf(a.*)) return true;
    if (isNumeric(a) and isNumeric(b)) return true;
    if (a.* == .Generic or b.* == .Generic) return true;
    return false;
}

/// Render a type to an owned label string. Caller frees the result.
pub fn typeLabel(allocator: Allocator, t: *const Type) Allocator.Error![]u8 {
    return t.toString(allocator);
}

pub fn isNumeric(t: *const Type) bool {
    return switch (t.nonNull().*) {
        .Int, .Long, .Short, .Byte, .Double, .Float => true,
        else => false,
    };
}

pub fn numericRank(t: *const Type) ?u8 {
    return switch (t.nonNull().*) {
        .Byte => 1,
        .Short => 2,
        .Int => 3,
        .Long => 4,
        .Float => 5,
        .Double => 6,
        else => null,
    };
}

pub fn numericLub(a: *const Type, b: *const Type) Type {
    const ra = numericRank(a) orelse return .Unresolved;
    const rb = numericRank(b) orelse return .Unresolved;
    const max_rank = @max(ra, rb);
    const winner = if (ra >= rb) a.nonNull().* else b.nonNull().*;
    if (max_rank <= 3 and (winner == .Byte or winner == .Short)) {
        return .Int;
    }
    return winner;
}

/// Least upper bound for if/when/try branch unification. The result owns
/// its heap data.
pub fn lub(allocator: Allocator, a: *const Type, b: *const Type) Allocator.Error!Type {
    if (a.* == .Unresolved or b.* == .Unresolved) return .Unresolved;
    if (a.eql(b.*)) return a.clone(allocator);
    if (a.* == .Nothing) return b.clone(allocator);
    if (b.* == .Nothing) return a.clone(allocator);
    if (a.isSubtypeOf(b.*)) return b.clone(allocator);
    if (b.isSubtypeOf(a.*)) return a.clone(allocator);
    if (a.isNullable() or b.isNullable()) {
        const na = a.nonNull();
        const nb = b.nonNull();
        var inner = try lub(allocator, na, nb);
        return inner.asNullable(allocator);
    }
    if (a.* == .Unit or b.* == .Unit) return .Unit;
    if (isNumeric(a) and isNumeric(b)) return numericLub(a, b);
    return .Any;
}

/// Score a parameter list by Widen-rank — lower is more specific.
pub fn widenScore(params: []const Type) u32 {
    var sum: u32 = 0;
    for (params) |*p| sum += intWidenRank(p);
    return sum;
}

/// Describe a parameter list as a comma-joined display string. Caller
/// frees the result.
pub fn describeParams(allocator: Allocator, params: []const Type) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    for (params, 0..) |*p, i| {
        if (i > 0) aw.writer.writeAll(", ") catch return error.OutOfMemory;
        p.format(&aw.writer) catch return error.OutOfMemory;
    }
    return aw.toOwnedSlice();
}

/// Lower rank = wider integer type per Kotlin's literal-widening rule.
pub fn intWidenRank(t: *const Type) u32 {
    return switch (t.*) {
        .Int => 0,
        .Short => 1,
        .Long => 2,
        .Byte => 3,
        else => 0,
    };
}

pub fn isBuiltinInteger(t: *const Type) bool {
    return switch (t.*) {
        .Int, .Long, .Short, .Byte => true,
        else => false,
    };
}

pub fn isBuiltinNumeric(t: *const Type) bool {
    return isBuiltinInteger(t) or t.* == .Float or t.* == .Double;
}

/// Position in Kotlin's numeric widening tower (Byte ⊂ Short ⊂ Int ⊂
/// Long ⊂ Float ⊂ Double). A narrower type is the more specific overload
/// target, so a smaller rank is more specific.
pub fn numTowerRank(t: *const Type) u32 {
    return switch (t.*) {
        .Byte => 0,
        .Short => 1,
        .Int => 2,
        .Long => 3,
        .Float => 4,
        .Double => 5,
        else => 0,
    };
}

/// Class-aware subtype check used by the MSC pairwise test. Walks `sub`'s
/// supertype chain in `classes` looking for `sup`.
pub fn classIsSubtypeOf(
    allocator: Allocator,
    classes: *const std.StringHashMap(ClassInfo),
    sub: []const u8,
    sup: []const u8,
) Allocator.Error!bool {
    if (std.mem.eql(u8, sub, sup)) return true;
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(allocator);
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    try stack.append(allocator, sub);
    while (stack.pop()) |n| {
        if ((try seen.getOrPut(n)).found_existing) continue;
        if (classes.get(n)) |info| {
            for (info.supertypes.items) |s| {
                if (std.mem.eql(u8, s, sup)) return true;
                try stack.append(allocator, s);
            }
        }
    }
    return false;
}

/// Spec §11.4.2: returns true when F1 is equally or more applicable than
/// F2 as an overload candidate for a call providing `arg_count` arguments.
pub fn atLeastAsApplicable(
    allocator: Allocator,
    f1: *const FnSig,
    f2: *const FnSig,
    arg_count: usize,
    classes: *const std.StringHashMap(ClassInfo),
) Allocator.Error!bool {
    const n = @min(@min(arg_count, f1.params.len), f2.params.len);
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const x = &f1.params[k];
        const y = &f2.params[k];
        if (isBuiltinInteger(x) and isBuiltinInteger(y)) {
            if (intWidenRank(x) > intWidenRank(y)) return false;
        } else if (isBuiltinNumeric(x) and isBuiltinNumeric(y)) {
            if (numTowerRank(x) > numTowerRank(y)) return false;
        } else if (x.* == .Unresolved and y.* == .Unresolved) {
            const xn = if (k < f1.param_class_names.len) f1.param_class_names[k] else null;
            const yn = if (k < f2.param_class_names.len) f2.param_class_names[k] else null;
            if (xn != null and yn != null) {
                if (!try classIsSubtypeOf(allocator, classes, xn.?, yn.?)) return false;
            }
        } else if (!x.isSubtypeOf(y.*)) {
            return false;
        }
    }
    return true;
}

/// Result of `pickMsc`: a unique most-specific candidate, or the
/// equally-specific frontier set on ambiguity.
pub const MscResult = union(enum) {
    ok: *const FnSig,
    ambiguous: []const *const FnSig,
};

/// Spec §11.4.2: pick the most specific candidate among `fitting`.
pub fn pickMsc(
    allocator: Allocator,
    fitting: []const *const FnSig,
    arg_count: usize,
    classes: *const std.StringHashMap(ClassInfo),
) Allocator.Error!MscResult {
    if (fitting.len == 0) return .{ .ambiguous = &.{} };
    if (fitting.len == 1) return .{ .ok = fitting[0] };

    var frontier: std.ArrayList(*const FnSig) = .empty;
    defer frontier.deinit(allocator);
    for (fitting, 0..) |f1, i| {
        var dominates_all = true;
        for (fitting, 0..) |f2, j| {
            if (i == j) continue;
            if (!try atLeastAsApplicable(allocator, f1, f2, arg_count, classes)) {
                dominates_all = false;
                break;
            }
        }
        if (dominates_all) try frontier.append(allocator, f1);
    }
    if (frontier.items.len == 0) {
        try frontier.appendSlice(allocator, fitting);
    }
    if (frontier.items.len == 1) return .{ .ok = frontier.items[0] };

    // Tiebreaker: non-parameterized > parameterized.
    var any_non_param = false;
    for (frontier.items) |s| {
        if (s.type_param_count == 0) {
            any_non_param = true;
            break;
        }
    }
    if (any_non_param) retainMsc(&frontier, struct {
        fn keep(s: *const FnSig) bool {
            return s.type_param_count == 0;
        }
    }.keep);
    if (frontier.items.len == 1) return .{ .ok = frontier.items[0] };

    // Tiebreaker: fewer unspecified defaults.
    var min_defaults: usize = std.math.maxInt(usize);
    for (frontier.items) |s| {
        const used = usedDefaults(s, arg_count);
        if (used < min_defaults) min_defaults = used;
    }
    {
        var i: usize = 0;
        while (i < frontier.items.len) {
            if (usedDefaults(frontier.items[i], arg_count) != min_defaults) {
                _ = frontier.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
    if (frontier.items.len == 1) return .{ .ok = frontier.items[0] };

    // Tiebreaker: no-vararg > has-vararg.
    var any_no_vararg = false;
    for (frontier.items) |s| {
        if (!anyVararg(s)) {
            any_no_vararg = true;
            break;
        }
    }
    if (any_no_vararg) retainMsc(&frontier, struct {
        fn keep(s: *const FnSig) bool {
            return !anyVararg(s);
        }
    }.keep);
    if (frontier.items.len == 1) return .{ .ok = frontier.items[0] };

    return .{ .ambiguous = try frontier.toOwnedSlice(allocator) };
}

fn retainMsc(frontier: *std.ArrayList(*const FnSig), keep: *const fn (*const FnSig) bool) void {
    var i: usize = 0;
    while (i < frontier.items.len) {
        if (!keep(frontier.items[i])) {
            _ = frontier.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn usedDefaults(s: *const FnSig, arg_count: usize) usize {
    const supplied = @min(arg_count, s.params.len);
    var count: usize = 0;
    for (s.has_default[0..supplied]) |h| {
        if (h) count += 1;
    }
    for (s.has_default[supplied..]) |h| {
        if (h) count += 1;
    }
    return count;
}

fn anyVararg(s: *const FnSig) bool {
    for (s.is_vararg) |v| {
        if (v) return true;
    }
    return false;
}

// === Phase K tailrec analysis helpers ===

pub fn tailrecIsSelfCall(callee: *const Expr, fn_name: []const u8) bool {
    return switch (callee.*) {
        .Path => |p| p.segments.len == 1 and std.mem.eql(u8, p.segments[0].name, fn_name),
        else => false,
    };
}

pub fn tailrecWalkBlock(
    b: *const Block,
    tail: bool,
    fn_name: []const u8,
    sites: *std.AutoHashMap(Span, void),
) Allocator.Error!void {
    const n = b.stmts.len;
    for (b.stmts, 0..) |s, i| {
        const is_last = i + 1 == n;
        const stmt_tail = tail and is_last;
        switch (s) {
            .Expr => |*e| try tailrecWalkExpr(e, stmt_tail, fn_name, sites),
            .Decl => {},
            .Assign => |a| {
                try tailrecWalkExpr(&a.target, false, fn_name, sites);
                try tailrecWalkExpr(&a.value, false, fn_name, sites);
            },
            .DestructuringDecl => |d| try tailrecWalkExpr(&d.init, false, fn_name, sites),
        }
    }
}

pub fn tailrecWalkExpr(
    e: *const Expr,
    tail: bool,
    fn_name: []const u8,
    sites: *std.AutoHashMap(Span, void),
) Allocator.Error!void {
    switch (e.*) {
        .Call => |c| {
            if (tail and tailrecIsSelfCall(c.callee, fn_name)) {
                try sites.put(c.span, {});
            }
            try tailrecWalkExpr(c.callee, false, fn_name, sites);
            for (c.args) |*a| try tailrecWalkExpr(a, false, fn_name, sites);
        },
        .If => |i| {
            try tailrecWalkExpr(i.cond, false, fn_name, sites);
            try tailrecWalkExpr(i.then_branch, tail, fn_name, sites);
            if (i.else_branch) |eb| try tailrecWalkExpr(eb, tail, fn_name, sites);
        },
        .When => |w| {
            if (w.subject) |s| try tailrecWalkExpr(s, false, fn_name, sites);
            for (w.branches) |*br| {
                for (br.patterns) |*p| {
                    switch (p.kind) {
                        .Value, .InRange, .NotInRange => |*ex| try tailrecWalkExpr(ex, false, fn_name, sites),
                        else => {},
                    }
                }
                try tailrecWalkExpr(&br.body, tail, fn_name, sites);
            }
        },
        .Block => |b| try tailrecWalkBlock(&b, tail, fn_name, sites),
        .Return => |r| {
            const returns_to_self = if (r.label) |l| std.mem.eql(u8, l.name, fn_name) else true;
            if (r.value) |v| try tailrecWalkExpr(v, returns_to_self, fn_name, sites);
        },
        .Labeled => |x| try tailrecWalkExpr(x.expr, tail, fn_name, sites),
        .Try => |t| {
            try tailrecWalkBlock(&t.body, false, fn_name, sites);
            for (t.catches) |*c| try tailrecWalkBlock(&c.body, false, fn_name, sites);
            if (t.finally) |fb| try tailrecWalkBlock(&fb, false, fn_name, sites);
        },
        .While => |w| {
            try tailrecWalkExpr(w.cond, false, fn_name, sites);
            try tailrecWalkExpr(w.body, false, fn_name, sites);
        },
        .DoWhile => |w| {
            if (w.body) |b| try tailrecWalkExpr(b, false, fn_name, sites);
            try tailrecWalkExpr(w.cond, false, fn_name, sites);
        },
        .For => |f| {
            try tailrecWalkExpr(f.iter, false, fn_name, sites);
            try tailrecWalkExpr(f.body, false, fn_name, sites);
        },
        .Binary => |b| {
            try tailrecWalkExpr(b.lhs, false, fn_name, sites);
            try tailrecWalkExpr(b.rhs, false, fn_name, sites);
        },
        .Index => |x| {
            try tailrecWalkExpr(x.receiver, false, fn_name, sites);
            for (x.args) |*a| try tailrecWalkExpr(a, false, fn_name, sites);
        },
        .Unary => |x| try tailrecWalkExpr(x.expr, false, fn_name, sites),
        .Postfix => |x| try tailrecWalkExpr(x.expr, false, fn_name, sites),
        .Member => |m| try tailrecWalkExpr(m.receiver, false, fn_name, sites),
        .Throw => |x| try tailrecWalkExpr(x.value, false, fn_name, sites),
        .IsCheck => |x| try tailrecWalkExpr(x.expr, false, fn_name, sites),
        .As => |x| try tailrecWalkExpr(x.expr, false, fn_name, sites),
        .Spread => |x| try tailrecWalkExpr(x.expr, false, fn_name, sites),
        .Lambda, .AnonFun, .ObjectExpr => {},
        else => {},
    }
}

pub fn tailrecCollectAllBlock(
    allocator: Allocator,
    b: *const Block,
    fn_name: []const u8,
    out: *std.ArrayList(Span),
) Allocator.Error!void {
    for (b.stmts) |s| {
        switch (s) {
            .Expr => |*e| try tailrecCollectAllExpr(allocator, e, fn_name, out),
            .Assign => |a| {
                try tailrecCollectAllExpr(allocator, &a.target, fn_name, out);
                try tailrecCollectAllExpr(allocator, &a.value, fn_name, out);
            },
            .DestructuringDecl => |d| try tailrecCollectAllExpr(allocator, &d.init, fn_name, out),
            .Decl => {},
        }
    }
}

pub fn tailrecCollectAllExpr(
    allocator: Allocator,
    e: *const Expr,
    fn_name: []const u8,
    out: *std.ArrayList(Span),
) Allocator.Error!void {
    switch (e.*) {
        .Call => |c| {
            if (tailrecIsSelfCall(c.callee, fn_name)) try out.append(allocator, c.span);
            try tailrecCollectAllExpr(allocator, c.callee, fn_name, out);
            for (c.args) |*a| try tailrecCollectAllExpr(allocator, a, fn_name, out);
        },
        .If => |i| {
            try tailrecCollectAllExpr(allocator, i.cond, fn_name, out);
            try tailrecCollectAllExpr(allocator, i.then_branch, fn_name, out);
            if (i.else_branch) |eb| try tailrecCollectAllExpr(allocator, eb, fn_name, out);
        },
        .When => |w| {
            if (w.subject) |s| try tailrecCollectAllExpr(allocator, s, fn_name, out);
            for (w.branches) |*br| {
                for (br.patterns) |*p| {
                    switch (p.kind) {
                        .Value, .InRange, .NotInRange => |*ex| try tailrecCollectAllExpr(allocator, ex, fn_name, out),
                        else => {},
                    }
                }
                try tailrecCollectAllExpr(allocator, &br.body, fn_name, out);
            }
        },
        .Block => |b| try tailrecCollectAllBlock(allocator, &b, fn_name, out),
        .Return => |r| {
            if (r.value) |v| try tailrecCollectAllExpr(allocator, v, fn_name, out);
        },
        .Try => |t| {
            try tailrecCollectAllBlock(allocator, &t.body, fn_name, out);
            for (t.catches) |*c| try tailrecCollectAllBlock(allocator, &c.body, fn_name, out);
            if (t.finally) |fb| try tailrecCollectAllBlock(allocator, &fb, fn_name, out);
        },
        .While => |w| {
            try tailrecCollectAllExpr(allocator, w.cond, fn_name, out);
            try tailrecCollectAllExpr(allocator, w.body, fn_name, out);
        },
        .DoWhile => |w| {
            if (w.body) |b| try tailrecCollectAllExpr(allocator, b, fn_name, out);
            try tailrecCollectAllExpr(allocator, w.cond, fn_name, out);
        },
        .For => |f| {
            try tailrecCollectAllExpr(allocator, f.iter, fn_name, out);
            try tailrecCollectAllExpr(allocator, f.body, fn_name, out);
        },
        .Binary => |b| {
            try tailrecCollectAllExpr(allocator, b.lhs, fn_name, out);
            try tailrecCollectAllExpr(allocator, b.rhs, fn_name, out);
        },
        .Index => |x| {
            try tailrecCollectAllExpr(allocator, x.receiver, fn_name, out);
            for (x.args) |*a| try tailrecCollectAllExpr(allocator, a, fn_name, out);
        },
        .Labeled => |x| try tailrecCollectAllExpr(allocator, x.expr, fn_name, out),
        .Unary => |x| try tailrecCollectAllExpr(allocator, x.expr, fn_name, out),
        .Postfix => |x| try tailrecCollectAllExpr(allocator, x.expr, fn_name, out),
        .Member => |m| try tailrecCollectAllExpr(allocator, m.receiver, fn_name, out),
        .Throw => |x| try tailrecCollectAllExpr(allocator, x.value, fn_name, out),
        .IsCheck => |x| try tailrecCollectAllExpr(allocator, x.expr, fn_name, out),
        .As => |x| try tailrecCollectAllExpr(allocator, x.expr, fn_name, out),
        .Spread => |x| try tailrecCollectAllExpr(allocator, x.expr, fn_name, out),
        .Lambda, .AnonFun, .ObjectExpr => {},
        else => {},
    }
}

test {
    std.testing.refAllDecls(@This());
}
