//! Type tests and casts, catch classes, and the run-time type values of
//! reified type parameters. Each test is the class sema recorded for the
//! written type, erased; a type parameter is tested through its reified
//! value.

const std = @import("std");
const ast = @import("ast");
const sema = @import("sema");

const ir = @import("../../ir.zig");
const bridge = @import("../../core/bridge.zig");
const builder = @import("builder.zig");
const records = @import("records.zig");
const body = @import("body.zig");
const coerce = @import("coerce.zig");
const env = @import("env.zig");

const Builder = builder.Builder;
const Error = records.Error;
const TypeTestRec = records.TypeTestRec;
const ClassId = ir.ClassId;
const Reg = ir.Reg;
const Sym = sema.Sym;
const TypeId = sema.TypeId;

/// `is` / `!is`.
pub fn lowerIsCheck(b: *Builder, e: *const ast.Expr) Error!Reg {
    const c = e.IsCheck;
    // A scalar class's value is tested boxed, as an instance of its class.
    const v = try coerce.coerce(b, try body.lowerExpr(b, c.expr), b.exprType(c.expr.id()), .none);
    const rec = try b.typeTest(e.id());
    return testAgainst(b, &rec, v);
}

/// `as` / `as?`. A cast to a type parameter that is not reified is
/// unchecked; it checks the parameter's erased bound, as the JVM does.
pub fn lowerAs(b: *Builder, e: *const ast.Expr) Error!Reg {
    const c = e.As;
    // A scalar class's value is cast boxed; the result converts to the
    // cast's own type.
    const v = try coerce.coerce(b, try body.lowerExpr(b, c.expr), b.exprType(c.expr.id()), .none);
    const cast = try castOf(b, e, v);
    return coerce.coerce(b, cast, .none, b.exprType(e.id()));
}

fn castOf(b: *Builder, e: *const ast.Expr, v: Reg) Error!Reg {
    const rec = try b.typeTest(e.id());
    const safe = rec.kind == .as_safe;
    const dst = b.newReg();
    if (rec.class != .none) {
        try b.emit(.{ .RCast = .{ .dst = dst, .src = v, .class = testClass(b, &rec), .nullable = rec.nullable, .safe = safe } });
        return dst;
    }
    if (reifiedParam(b.p.s, rec.ty)) |_| {
        const ty = try typeValue(b, rec.ty);
        try b.emit(.{ .CastDyn = .{ .dst = dst, .src = v, .ty = ty, .nullable = rec.nullable, .safe = safe } });
        return dst;
    }
    // `T & Any` is checked for null: the cast of null throws.
    const dnn = switch (b.p.s.types.get(rec.ty)) {
        .param => |p| p.dnn,
        else => false,
    };
    if (try erasedBound(b.p.s, rec.ty)) |cls| {
        // A bound that admits null admits it through the cast.
        try b.emit(.{ .RCast = .{ .dst = dst, .src = v, .class = b.p.br.classOf(cls), .nullable = !dnn, .safe = safe } });
        return dst;
    }
    if (dnn) if (b.p.br.classOfOpt(b.p.s.builtins.any)) |any| {
        try b.emit(.{ .RCast = .{ .dst = dst, .src = v, .class = any, .nullable = false, .safe = safe } });
        return dst;
    };
    try b.emit(.{ .Move = .{ .dst = dst, .src = v } });
    return dst;
}

/// The test `rec` names applied to `v`: `is`, or `!is` negated, for `is`
/// expressions and `when` patterns.
pub fn testAgainst(b: *Builder, rec: *const TypeTestRec, v: Reg) Error!Reg {
    const dst = b.newReg();
    if (rec.class != .none) {
        try b.emit(.{ .RInstanceOf = .{ .dst = dst, .src = v, .class = testClass(b, rec), .nullable = rec.nullable } });
    } else {
        const ty = try typeValue(b, rec.ty);
        try b.emit(.{ .InstanceOfDyn = .{ .dst = dst, .src = v, .ty = ty, .nullable = rec.nullable } });
    }
    if (rec.kind != .not_is) return dst;
    const neg = b.newReg();
    try b.emit(.{ .Not = .{ .dst = neg, .src = dst } });
    return neg;
}

/// The class a test or cast checks against: the class sema recorded, but
/// for a `@Composable` function type the `FunctionN` its values are, which
/// takes the composer pair after the parameters.
fn testClass(b: *Builder, rec: *const TypeTestRec) ClassId {
    const s = b.p.s;
    const plain = b.p.br.classOf(rec.class);
    if (!bridge.composableType(s, rec.ty)) return plain;
    const args = s.types.argsOf(rec.ty);
    if (args.len == 0) return plain;
    const arity = args.len - 1;
    const composed = s.function_classes.get(@intCast(arity + 1 + bridge.lambdaChangedInts(arity))) orelse return plain;
    return b.p.br.classOfOpt(composed) orelse plain;
}

/// The class a `catch` parameter catches.
/// `kotlin.Throwable`: the class a handler catches when it tries a `try`'s
/// clauses itself, one of them a reified type parameter.
pub fn throwableClass(b: *Builder, sp: @import("span").Span) Error!ClassId {
    const t = b.p.s.builtins.throwable;
    if (t == .none) return b.fail(sp, "the base declares no `kotlin.Throwable`", .{});
    return b.p.br.classOf(t);
}

pub fn catchClass(b: *Builder, c: *const ast.Catch) Error!ClassId {
    const rec = try b.typeTest(c.id);
    if (rec.class == .none) return b.fail(c.ty.span, "a catch parameter whose type is not a class", .{});
    return b.p.br.classOf(rec.class);
}

/// The run-time type value of `t`: of a class type, the `KType` the base
/// builds (its `KClass` alone in a base without the builder); for a
/// reified type parameter, the value its function received, which the
/// body binds to the parameter's symbol.
pub fn typeValue(b: *Builder, t: TypeId) Error!Reg {
    const s = b.p.s;
    // An intersection has no class of its own: kotlinc's `typeOf` gives an
    // intersection argument as `Nothing` (`typeOf<In<A & B>>()` is
    // `In<Nothing>`).
    if (s.types.get(t) == .intersection) return typeValue(b, s.t.nothing);
    const cls = s.types.classSym(t);
    if (cls != .none) {
        const k = try classLiteral(b, cls);
        // With the base's `KType` builder, the whole type: its class, its
        // arguments and whether it is nullable, as `typeOf<T>()` gives it.
        const make = helper(b, "__klio_type") orelse return k;
        const project = helper(b, "__klio_projection") orelse return k;
        var projections: std.ArrayList(Reg) = .empty;
        for (s.types.argsOf(t)) |arg| {
            // An argument erased at run time (a type parameter that is not
            // reified) is known only as a star.
            const known = arg.variance != .star and arg.ty != .none and !erased(s, arg.ty);
            const variance: i32 = if (!known) 3 else switch (arg.variance) {
                .inv => 0,
                .in => 1,
                .out => 2,
                .star => 3,
            };
            const inner = if (!known) try b.nullValue() else try typeValue(b, arg.ty);
            try projections.append(b.p.a, try callStatic(b, project, &.{ try b.emitConst(.{ .Int = variance }), inner }));
        }
        const arr = b.p.br.classOfOpt(s.builtins.array) orelse return error.Unsupported;
        const args = b.newReg();
        try b.emit(.{ .NewArray = .{ .dst = args, .class = arr, .args = try b.run(projections.items), .n_args = @intCast(projections.items.len) } });
        const nullable = try b.emitConst(.{ .Bool = s.types.isNullable(t) });
        return callStatic(b, make, &.{ k, nullable, args });
    }
    const tp = reifiedParam(s, t) orelse
        return b.fail(b.cur_span, "no run-time type value for a type of kind `{s}`", .{@tagName(std.meta.activeTag(s.types.get(t)))});
    // A local of the function, or a capture of a nested body.
    const home = (try env.homeOf(b, tp)) orelse return error.Unrecorded;
    const v = switch (home) {
        .reg => |r| r,
        .cell => |cell| blk: {
            const dst = b.newReg();
            try b.emit(.{ .CellGet = .{ .dst = dst, .cell = cell } });
            break :blk dst;
        },
    };
    // `T?` is the type `T` stands for, marked nullable: `impl<T?>()` in a
    // body where `T` is a `Byte` passes `Byte?`.
    if (!s.types.isNullable(t)) return v;
    const nullable = helper(b, "__klio_typeNullable") orelse return v;
    return callStatic(b, nullable, &.{v});
}

/// The `KClass` a class literal names: of class type `t`, or of the type a
/// reified type parameter stands for.
pub fn classValue(b: *Builder, t: TypeId) Error!Reg {
    const cls = b.p.s.types.classSym(t);
    if (cls != .none) return classLiteral(b, cls);
    const v = try typeValue(b, t);
    const of = helper(b, "__klio_typeClass") orelse return v;
    return callStatic(b, of, &.{v});
}

fn classLiteral(b: *Builder, cls: Sym) Error!Reg {
    const dst = b.newReg();
    try b.emit(.{ .ClassLiteral = .{ .dst = dst, .class = b.p.br.classOf(cls) } });
    return dst;
}

/// The base's `kotlin.reflect` helper `name` that builds a run-time type;
/// null when the base declares none, and a type value is its class alone.
fn helper(b: *Builder, name: []const u8) ?ir.FuncId {
    const s = b.p.s;
    const pkg_name = s.names.lookup("kotlin.reflect") orelse return null;
    const pkg = s.syms.package_by_fqn.get(pkg_name) orelse return null;
    const n = s.names.lookup(name) orelse return null;
    for (sema.scope.membersOf(s, pkg, n)) |m| {
        if (s.syms.kind(m) != .function) continue;
        if (b.p.br.funcOfOpt(m)) |f| return f;
    }
    return null;
}

fn callStatic(b: *Builder, f: ir.FuncId, args: []const Reg) Error!Reg {
    const dst = b.newReg();
    try b.emit(.{ .CallStatic = .{ .dst = dst, .func = f, .args = try b.run(args), .n_args = @intCast(args.len) } });
    return dst;
}

/// Whether `t` is a reified type parameter.
pub fn isReified(s: *sema.Sema, t: TypeId) bool {
    return reifiedParam(s, t) != null;
}

/// The base's `KType` builder a reified type value of a class type is
/// made with, if the base has one.
pub fn typeBuilder(b: *Builder) ?ir.FuncId {
    return helper(b, "__klio_type");
}

/// The base's functions a run-time type value is built with: they only
/// allocate the value.
pub fn typeBuilders(b: *Builder) [3]?ir.FuncId {
    return .{ helper(b, "__klio_type"), helper(b, "__klio_projection"), helper(b, "__klio_typeNullable") };
}

/// Whether `t` is a type parameter that is not reified.
fn erased(s: *sema.Sema, t: TypeId) bool {
    return switch (s.types.get(t)) {
        .param => |p| !s.syms.flags(p.sym).reified,
        else => false,
    };
}

/// The reified type parameter `t` is, or null.
fn reifiedParam(s: *sema.Sema, t: TypeId) ?Sym {
    return switch (s.types.get(t)) {
        .param => |p| if (s.syms.flags(p.sym).reified) p.sym else null,
        else => null,
    };
}

/// The class a type parameter's first bound erases to, or null when it is
/// unbounded or bounded by `Any?`.
fn erasedBound(s: *sema.Sema, t: TypeId) Error!?Sym {
    var cur = t;
    // A bound may be another type parameter: follow it to a class.
    var hops: u8 = 0;
    while (hops < 16) : (hops += 1) {
        switch (s.types.get(cur)) {
            .param => |p| {
                const bounds = try sema.headers.typeParamBounds(s, p.sym);
                if (bounds.len == 0) return null;
                cur = bounds[0];
            },
            .class => |c| return if (c.sym == s.builtins.any) null else c.sym,
            else => return null,
        }
    }
    return null;
}
