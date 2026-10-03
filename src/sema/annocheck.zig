//! What kotlinc refuses in the program's annotations: an annotation class
//! with members, parameters of a type an annotation cannot hold, defaults
//! that are not constant or parameters that cycle back to their class; and
//! an annotation written twice that is not repeatable. Each finding is an
//! `annotation` census site naming kotlinc's diagnostic.

const std = @import("std");
const ast = @import("ast");
const span = @import("span");

const sema_mod = @import("sema.zig");
const Sema = sema_mod.Sema;
const symbols = @import("symbols.zig");
const types = @import("types.zig");
const headers = @import("headers.zig");
const census = @import("census.zig");
const declcheck = @import("declcheck.zig");

const Allocator = std.mem.Allocator;
const Sym = symbols.Sym;
const TypeId = types.TypeId;
const Span = span.Span;

/// Checks every annotation class and annotated declaration of the
/// program's files.
pub fn checkProgram(s: *Sema) Allocator.Error!void {
    var i: u32 = 1;
    while (i < s.syms.count()) : (i += 1) {
        const sym = Sym.from(i);
        const info = s.syms.get(sym);
        const fc = s.fileOf(info.file) orelse continue;
        if (!declcheck.checked(fc)) continue;
        if (info.flags.synthetic) continue;
        const c = Checker{ .s = s, .file = info.file };
        // A program's declarations are checked, and each has its AST.
        const anns: []const ast.Annotation = switch (info.decl) {
            .class => |d| blk: {
                if (info.kind == .class and d.?.is_annotation) try c.annotationClass(sym, d.?);
                try c.repeated(sym, d.?.x().primary_ctor_annotations);
                break :blk d.?.annotations;
            },
            .object => |d| d.?.annotations,
            .function => |d| d.?.annotations,
            .property => |d| d.?.annotations,
            .param => |d| d.?.annotations,
            .class_param => |d| if (info.kind == .value_param) d.?.annotations else &.{},
            .secondary_ctor => |d| d.?.annotations,
            .accessor => |d| d.?.annotations,
            .enum_entry => |d| d.?.annotations,
            .type_alias => |d| d.?.annotations,
            else => &.{},
        };
        try c.repeated(sym, anns);
        try c.placed(sym, info.kind, info.decl);
    }
    // A file's own annotations stand on the file, an expression's on it.
    for (s.files.items, 0..) |fc, fi| {
        if (!declcheck.checked(&fc)) continue;
        const file = fc.ast orelse continue;
        const c = Checker{ .s = s, .file = @intCast(fi) };
        try c.targets(.none, file.file_annotations, .{ .admits = &.{.FILE}, .name = "file" });
        for (file.annotated_exprs) |ae| try c.targets(.none, ae.annotations, if (ae.function)
            .{ .admits = &.{ .FUNCTION, .EXPRESSION }, .name = "anonymous function" }
        else
            .{ .admits = &.{.EXPRESSION}, .name = "expression" });
    }
}

const Checker = struct {
    s: *Sema,
    file: u32,

    fn report(self: Checker, sp: Span, factory: census.Factory, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const msg = try std.fmt.allocPrint(self.s.arena, fmt, args);
        try self.s.census.reportFacts(.annotation, self.file, sp, .{ .message = msg, .factory = factory }, "{s}: {s}", .{ @tagName(factory), msg });
    }

    /// An annotation class holds constants only: `val` parameters of the
    /// types an annotation can carry, with constant defaults, and no other
    /// member.
    fn annotationClass(self: Checker, cls: Sym, c: *const ast.Class) Allocator.Error!void {
        const s = self.s;
        try self.expressionRetention(cls, c);
        for (c.members) |*m| switch (m.*) {
            .Function => |*f| try self.report(f.name.span, .ANNOTATION_CLASS_MEMBER, "Members are prohibited in annotation classes.", .{}),
            .Property => |p| try self.report(p.name.span, .ANNOTATION_CLASS_MEMBER, "Members are prohibited in annotation classes.", .{}),
            else => {},
        };
        const ctor = s.syms.classInfo(cls).primary_ctor;
        if (ctor == .none) return;
        try headers.functionHeader(s, ctor);
        const params = s.syms.functionInfo(ctor).params;
        if (params.len != c.primary_params.len) return;
        for (params, c.primary_params) |p, *cp| {
            if (cp.property == null) {
                try self.report(cp.span, .MISSING_VAL_ON_ANNOTATION_PARAMETER, "'val' keyword is missing in annotation parameter.", .{});
            } else if (cp.property == true) {
                try self.report(cp.span, .VAR_ANNOTATION_PARAMETER, "An annotation parameter cannot be 'var'.", .{});
            }
            const t = try headers.paramType(s, p);
            if (!s.types.isErr(t)) {
                if (s.types.isNullable(t)) {
                    try self.report(cp.ty.span, .NULLABLE_TYPE_OF_ANNOTATION_MEMBER, "Annotation parameters cannot be nullable.", .{});
                } else if (!try self.memberType(t)) {
                    try self.report(cp.ty.span, .INVALID_TYPE_OF_ANNOTATION_MEMBER, "Invalid type of annotation member.", .{});
                }
            }
            if (cp.default) |*d| {
                if (!try annotationValue(s, self.file, d)) {
                    try self.report(d.span(), .ANNOTATION_PARAMETER_DEFAULT_VALUE_MUST_BE_CONSTANT, "Default value of annotation parameter must be a compile-time constant.", .{});
                }
            }
            // A vararg parameter is an array, which breaks a cycle.
            if (!s.syms.flags(p).vararg and try self.cycles(cls, t)) {
                try self.report(cp.span, .CYCLE_IN_ANNOTATION_PARAMETER_ERROR, "Cycle formed by one or more annotations and their parameter types.", .{});
            }
        }
    }

    /// Whether an annotation can carry a value of type `t`: a primitive,
    /// unsigned or string value, a `KClass`, an enum entry, another
    /// annotation, or an array of these.
    fn memberType(self: Checker, t: TypeId) Allocator.Error!bool {
        const s = self.s;
        if (s.types.isErr(t)) return true;
        if (s.types.isNullable(t)) return false;
        const ct = switch (s.types.get(t)) {
            .class => |ct| ct,
            else => return false,
        };
        const cls = ct.sym;
        if (declcheck.primitive(s, cls) or declcheck.unsigned(s, cls) or cls == s.builtins.string) return true;
        if (cls == s.builtins.kclass) return true;
        switch (s.syms.classInfo(cls).kind) {
            .enum_class, .annotation => return true,
            else => {},
        }
        if (cls == s.builtins.array) {
            if (ct.args.len != 1 or ct.args[0].ty == .none) return false;
            return self.memberType(ct.args[0].ty);
        }
        const fqn = s.str(s.syms.classInfo(cls).fqn);
        for ([_][]const u8{
            "kotlin.IntArray",     "kotlin.LongArray",  "kotlin.ShortArray",  "kotlin.ByteArray",
            "kotlin.FloatArray",   "kotlin.DoubleArray", "kotlin.CharArray",  "kotlin.BooleanArray",
            "kotlin.UIntArray",    "kotlin.ULongArray", "kotlin.UShortArray", "kotlin.UByteArray",
        }) |a| if (std.mem.eql(u8, fqn, a)) return true;
        return false;
    }

    /// Whether a parameter of type `t` leads back to the annotation class
    /// `cls` through annotation-typed parameters. An array of annotations
    /// breaks the cycle, as kotlinc has it.
    fn cycles(self: Checker, cls: Sym, t: TypeId) Allocator.Error!bool {
        const s = self.s;
        var seen: std.AutoHashMapUnmanaged(Sym, void) = .empty;
        var work: std.ArrayList(Sym) = .empty;
        const first = annotationOf(s, t);
        if (first == .none) return false;
        try work.append(s.arena, first);
        while (work.pop()) |a| {
            if (a == cls) return true;
            if ((try seen.getOrPut(s.arena, a)).found_existing) continue;
            const ctor = s.syms.classInfo(a).primary_ctor;
            if (ctor == .none) continue;
            try headers.functionHeader(s, ctor);
            for (s.syms.functionInfo(ctor).params) |p| {
                if (s.syms.flags(p).vararg) continue;
                const next = annotationOf(s, try headers.paramType(s, p));
                if (next != .none) try work.append(s.arena, next);
            }
        }
        return false;
    }

    // ------------------------------------------------------------ targets --

    /// An annotation of expressions is kept in source only: its retention
    /// is `SOURCE`, written so.
    fn expressionRetention(self: Checker, cls: Sym, c: *const ast.Class) Allocator.Error!void {
        const s = self.s;
        const allowed = (try allowedTargets(s, cls)) orelse return;
        if (allowed.default or std.mem.indexOfScalar(Target, allowed.list, .EXPRESSION) == null) return;
        const ctx = headers.ctxOf(s, cls);
        var at: Span = if (c.annotations.len != 0) c.annotations[0].span else c.span;
        for (c.annotations) |*a| {
            const ac = try headers.annotationClass(s, ctx, a);
            if (ac == .none or !std.mem.eql(u8, s.str(s.syms.classInfo(ac).fqn), "kotlin.annotation.Retention")) continue;
            for (a.args) |*arg| {
                const name = switch (arg.*) {
                    .Member => |m| m.name.name,
                    .Path => |pa| pa.segments[pa.segments.len - 1].name,
                    else => "",
                };
                if (std.mem.eql(u8, name, "SOURCE")) return;
            }
            at = a.span;
        }
        try self.report(at, .RESTRICTED_RETENTION_FOR_EXPRESSION_ANNOTATION_ERROR, "Expression annotations with retention other than SOURCE are prohibited.", .{});
    }

    /// The annotations `sym`'s declaration carries, each against the place
    /// it stands: the declaration, its accessors, its type parameters.
    fn placed(self: Checker, sym: Sym, kind: symbols.Kind, decl: symbols.Decl) Allocator.Error!void {
        const s = self.s;
        switch (decl) {
            .class => |d| {
                const c = d.?;
                if (kind == .constructor) {
                    return self.targets(sym, c.x().primary_ctor_annotations, .{ .admits = &.{.CONSTRUCTOR}, .name = "constructor" });
                }
                if (kind != .class) return;
                try self.targets(sym, c.annotations, classSite(s, sym));
                try self.typeParams(sym, c.type_params);
            },
            .object => |d| if (kind == .class) try self.targets(sym, d.?.annotations, classSite(s, sym)),
            .function => |d| {
                const f = d.?;
                const owner = s.syms.owner(sym);
                const name: []const u8 = switch (s.syms.kind(owner)) {
                    .package => "top level function",
                    .class => "member function",
                    else => "local function",
                };
                try self.targets(sym, f.annotations, .{ .admits = &.{.FUNCTION}, .name = name });
                try self.typeParams(sym, f.type_params);
            },
            .property => |d| {
                const p = d.?;
                const top = s.syms.kind(s.syms.owner(sym)) == .package;
                const field = p.delegate == null and p.receiver_type == null and !p.is_abstract and declcheck.hasBackingField(p);
                const shape: []const u8 = if (p.delegate != null) "with delegate" else if (field) "with backing field" else "without backing field or delegate";
                const name = try std.fmt.allocPrint(s.arena, "{s} property {s}", .{ if (top) "top level" else "member", shape });
                try self.targets(sym, p.annotations, .{ .admits = if (field) &.{ .PROPERTY, .FIELD } else &.{.PROPERTY}, .name = name });
                if (p.getter) |g| try self.targets(sym, g.annotations, .{ .admits = &.{.PROPERTY_GETTER}, .name = "getter" });
                if (p.setter) |st| try self.targets(sym, st.annotations, .{ .admits = &.{.PROPERTY_SETTER}, .name = "setter" });
                try self.typeParams(sym, p.type_params);
            },
            .param => |d| try self.targets(sym, d.?.annotations, .{ .admits = &.{.VALUE_PARAMETER}, .name = "value parameter" }),
            .class_param => |d| if (kind == .value_param) {
                const p = d.?;
                try self.targets(sym, p.annotations, .{ .admits = if (p.property != null) &.{ .VALUE_PARAMETER, .PROPERTY, .FIELD } else &.{.VALUE_PARAMETER}, .name = "value parameter" });
            },
            .secondary_ctor => |d| try self.targets(sym, d.?.annotations, .{ .admits = &.{.CONSTRUCTOR}, .name = "constructor" }),
            .enum_entry => |d| try self.targets(sym, d.?.annotations, .{ .admits = &.{ .PROPERTY, .FIELD }, .name = "enum entry" }),
            .type_alias => |d| try self.targets(sym, d.?.annotations, .{ .admits = &.{.TYPEALIAS}, .name = "typealias" }),
            else => {},
        }
    }

    fn typeParams(self: Checker, sym: Sym, tps: []const ast.TypeParam) Allocator.Error!void {
        for (tps) |*tp| try self.targets(sym, tp.annotations, .{ .admits = &.{.TYPE_PARAMETER}, .name = "type parameter" });
    }

    /// Each annotation of `anns` whose class does not admit `site`, or the
    /// place its use-site target names.
    fn targets(self: Checker, sym: Sym, anns: []const ast.Annotation, site: Site) Allocator.Error!void {
        if (anns.len == 0) return;
        const ctx: headers.TypeCtx = if (sym != .none) headers.ctxOf(self.s, sym) else .{ .decl = .none, .file = self.file };
        return self.targetsIn(ctx, anns, site);
    }

    fn targetsIn(self: Checker, ctx: headers.TypeCtx, anns: []const ast.Annotation, site: Site) Allocator.Error!void {
        const s = self.s;
        for (anns) |*a| {
            const cls = try headers.annotationClass(s, ctx, a);
            if (cls == .none) continue;
            const allowed = (try allowedTargets(s, cls)) orelse continue;
            // A type written once is resolved more than once.
            if (s.census.reportedAt(self.file, a.span, .WRONG_ANNOTATION_TARGET) or s.census.reportedAt(self.file, a.span, .WRONG_ANNOTATION_TARGET_WITH_USE_SITE_TARGET)) continue;
            if (a.use_site) |u| {
                const place = useSitePlace(u) orelse continue;
                if (std.mem.indexOfScalar(Target, allowed.list, place.target) != null) continue;
                try self.report(a.span, .WRONG_ANNOTATION_TARGET_WITH_USE_SITE_TARGET, "This annotation is not applicable to target '{s}' and use-site target '@{s}'. Applicable targets: {s}", .{ place.name, place.written, try allowedText(s, allowed) });
                continue;
            }
            for (site.admits) |t| {
                if (std.mem.indexOfScalar(Target, allowed.list, t) != null) break;
            } else try self.report(a.span, .WRONG_ANNOTATION_TARGET, "This annotation is not applicable to target '{s}'. Applicable targets: {s}", .{ site.name, try allowedText(s, allowed) });
        }
    }

    /// An annotation kotlinc does not let a declaration carry twice: one
    /// whose class is not `@Repeatable`, written again with the same
    /// use-site target.
    fn repeated(self: Checker, sym: Sym, anns: []const ast.Annotation) Allocator.Error!void {
        const s = self.s;
        if (anns.len < 2) return;
        const ctx: headers.TypeCtx = .{ .decl = sym, .file = self.file };
        var classes: std.ArrayList(Sym) = .empty;
        for (anns) |*a| try classes.append(s.arena, try headers.annotationClass(s, ctx, a));
        for (anns, 0..) |*a, i| {
            const c = classes.items[i];
            if (c == .none) continue;
            for (anns[0..i], classes.items[0..i]) |*b, bc| {
                if (bc != c or a.use_site != b.use_site) continue;
                if (try repeatable(s, c)) break;
                try self.report(a.span, .REPEATED_ANNOTATION, "This annotation is not repeatable.", .{});
                break;
            }
        }
    }
};

/// Each of `anns`, written where `site` names and resolved in `ctx`, whose
/// class does not admit that place.
pub fn checkPlace(s: *Sema, ctx: headers.TypeCtx, anns: []const ast.Annotation, site: Site) Allocator.Error!void {
    if (anns.len == 0) return;
    const c = Checker{ .s = s, .file = ctx.file };
    return c.targetsIn(ctx, anns, site);
}

/// A place an annotation stands: the `AnnotationTarget`s that admit an
/// annotation there, and how kotlinc names the place.
pub const Site = struct { admits: []const Target, name: []const u8 };

/// `kotlin.annotation.AnnotationTarget`'s entries.
pub const Target = enum { CLASS, ANNOTATION_CLASS, TYPE_PARAMETER, PROPERTY, FIELD, LOCAL_VARIABLE, VALUE_PARAMETER, CONSTRUCTOR, FUNCTION, PROPERTY_GETTER, PROPERTY_SETTER, TYPE, EXPRESSION, FILE, TYPEALIAS };

fn targetText(t: Target) []const u8 {
    return switch (t) {
        .CLASS => "class",
        .ANNOTATION_CLASS => "annotation class",
        .TYPE_PARAMETER => "type parameter",
        .PROPERTY => "property",
        .FIELD => "field",
        .LOCAL_VARIABLE => "local variable",
        .VALUE_PARAMETER => "value parameter",
        .CONSTRUCTOR => "constructor",
        .FUNCTION => "function",
        .PROPERTY_GETTER => "getter",
        .PROPERTY_SETTER => "setter",
        .TYPE => "type usage",
        .EXPRESSION => "expression",
        .FILE => "file",
        .TYPEALIAS => "typealias",
    };
}

/// The targets an annotation class admits: its `@Target`'s, or the default
/// set when it writes none.
const Allowed = struct { list: []const Target, default: bool };

const default_targets = [_]Target{ .CLASS, .ANNOTATION_CLASS, .PROPERTY, .FIELD, .LOCAL_VARIABLE, .VALUE_PARAMETER, .CONSTRUCTOR, .FUNCTION, .PROPERTY_GETTER, .PROPERTY_SETTER };

/// The targets `cls` admits; null when its declaration is not in source,
/// where its `@Target` is not known.
fn allowedTargets(s: *Sema, cls: Sym) Allocator.Error!?Allowed {
    const c = switch (s.syms.get(cls).decl) {
        .class => |d| d orelse return null,
        else => return null,
    };
    const ctx = headers.ctxOf(s, cls);
    for (c.annotations) |*a| {
        const ac = try headers.annotationClass(s, ctx, a);
        if (ac == .none or !std.mem.eql(u8, s.str(s.syms.classInfo(ac).fqn), "kotlin.annotation.Target")) continue;
        var list: std.ArrayList(Target) = .empty;
        for (a.args) |*arg| try targetNames(s, arg, &list);
        return .{ .list = list.items, .default = false };
    }
    return .{ .list = &default_targets, .default = true };
}

/// The `AnnotationTarget` entries an argument of `@Target` names.
fn targetNames(s: *Sema, e: *const ast.Expr, out: *std.ArrayList(Target)) Allocator.Error!void {
    const name: []const u8 = switch (e.*) {
        .Member => |m| m.name.name,
        .Path => |p| p.segments[p.segments.len - 1].name,
        .Spread => |x| return targetNames(s, x.expr, out),
        .Call => |c| {
            // `*arrayOf(...)` and `[...]` spread entries.
            for (c.args) |*arg| try targetNames(s, arg, out);
            return;
        },
        else => return,
    };
    if (std.meta.stringToEnum(Target, name)) |t| try out.append(s.arena, t);
}

fn allowedText(s: *Sema, allowed: Allowed) Allocator.Error![]const u8 {
    if (allowed.default) return "class, annotation class, property, field, local variable, value parameter, constructor, function, getter, setter, backing field";
    var buf: std.ArrayList(u8) = .empty;
    for (allowed.list, 0..) |t, i| {
        if (i != 0) try buf.appendSlice(s.arena, ", ");
        try buf.appendSlice(s.arena, targetText(t));
    }
    return buf.items;
}

/// The place a use-site target names; null for `@all:`, which places the
/// annotation wherever its class admits.
fn useSitePlace(u: ast.AnnotationUseSite) ?struct { target: Target, name: []const u8, written: []const u8 } {
    return switch (u) {
        .Field => .{ .target = .FIELD, .name = "backing field", .written = "field" },
        .Property => .{ .target = .PROPERTY, .name = "property", .written = "property" },
        .Get => .{ .target = .PROPERTY_GETTER, .name = "getter", .written = "get" },
        .Set => .{ .target = .PROPERTY_SETTER, .name = "setter", .written = "set" },
        .Receiver => .{ .target = .VALUE_PARAMETER, .name = "receiver", .written = "receiver" },
        .Param => .{ .target = .VALUE_PARAMETER, .name = "value parameter", .written = "param" },
        .SetParam => .{ .target = .VALUE_PARAMETER, .name = "setter parameter", .written = "setparam" },
        .Delegate => .{ .target = .FIELD, .name = "delegate field", .written = "delegate" },
        .File => .{ .target = .FILE, .name = "file", .written = "file" },
        .All => null,
    };
}

/// How kotlinc names a classifier as an annotation's place.
fn classSite(s: *Sema, cls: Sym) Site {
    return switch (s.syms.classInfo(cls).kind) {
        .annotation => .{ .admits = &.{ .ANNOTATION_CLASS, .CLASS }, .name = "annotation class" },
        .enum_class => .{ .admits = &.{.CLASS}, .name = "enum class" },
        .interface => .{ .admits = &.{.CLASS}, .name = "interface" },
        .object => .{ .admits = &.{.CLASS}, .name = "standalone object" },
        .companion => .{ .admits = &.{.CLASS}, .name = "companion object" },
        else => .{ .admits = &.{.CLASS}, .name = if (localClass(s, cls)) "local class" else "class" },
    };
}

fn localClass(s: *Sema, cls: Sym) bool {
    var cur = s.syms.owner(cls);
    while (cur != .none) : (cur = s.syms.owner(cur)) {
        switch (s.syms.kind(cur)) {
            .package => return false,
            .class => {},
            else => return true,
        }
    }
    return false;
}

/// The annotation class `t` is, or `.none`.
fn annotationOf(s: *Sema, t: TypeId) Sym {
    if (s.types.isErr(t)) return .none;
    const cls = s.types.classSym(t);
    if (cls == .none or s.syms.kind(cls) != .class) return .none;
    return if (s.syms.classInfo(cls).kind == .annotation) cls else .none;
}

/// Whether an annotation class is marked `kotlin.annotation.Repeatable`
/// (or the JVM's `@JvmRepeatable`).
fn repeatable(s: *Sema, cls: Sym) Allocator.Error!bool {
    if (s.syms.get(cls).decl != .class) return true;
    for (try headers.annotationClasses(s, cls, .decl)) |ac| {
        if (ac == .none) continue;
        const fqn = s.str(s.syms.classInfo(ac).fqn);
        if (std.mem.eql(u8, fqn, "kotlin.annotation.Repeatable") or std.mem.eql(u8, fqn, "kotlin.jvm.JvmRepeatable")) return true;
    }
    return false;
}

/// Whether an expression is a value an annotation argument may be: a
/// constant, an enum entry, a class literal, another annotation, or an
/// array of these.
pub fn annotationValue(s: *Sema, file: u32, e: *const ast.Expr) Allocator.Error!bool {
    switch (e.*) {
        .MemberRef => |m| if (std.mem.eql(u8, m.name.name, "class")) return true,
        .Path => |p| {
            const target = try declcheck.refTarget(s, file, declcheck.pathAnchor(s, file, p.span, p.segments));
            if (target != .none and s.syms.kind(target) == .enum_entry) return true;
        },
        .Member => |m| {
            const target = try declcheck.refTarget(s, file, m.name.span);
            if (target != .none and s.syms.kind(target) == .enum_entry) return true;
        },
        .Call => |c| {
            const name_span: Span = switch (c.callee.*) {
                .Path => |p| declcheck.pathAnchor(s, file, p.span, p.segments),
                .Member => |m| m.name.span,
                else => return declcheck.constant(s, file, e),
            };
            const target = try declcheck.refTarget(s, file, name_span);
            const array_call = c.collection_literal or (target != .none and arrayFactory(s, target));
            const annotation_call = target != .none and s.syms.kind(target) == .constructor and
                s.syms.classInfo(s.syms.owner(target)).kind == .annotation;
            if (array_call or annotation_call) {
                for (c.args) |*arg| {
                    const inner: *const ast.Expr = switch (arg.*) {
                        .Spread => |sp| sp.expr,
                        else => arg,
                    };
                    if (!try annotationValue(s, file, inner)) return false;
                }
                return true;
            }
        },
        else => {},
    }
    return declcheck.constant(s, file, e);
}

/// `arrayOf`, `intArrayOf` and the rest, and `emptyArray`, of package
/// `kotlin`.
fn arrayFactory(s: *Sema, f: Sym) bool {
    if (s.syms.kind(f) != .function) return false;
    const owner = s.syms.owner(f);
    if (owner == .none or s.syms.kind(owner) != .package) return false;
    if (!std.mem.eql(u8, s.str(s.syms.packageInfo(owner).fqn), "kotlin")) return false;
    const n = s.str(s.syms.name(f));
    return std.mem.endsWith(u8, n, "rrayOf") or std.mem.eql(u8, n, "emptyArray");
}
