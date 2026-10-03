//! Declaration headers: the types a declaration names outside its body.
//! Each is resolved on first use and memoized on the symbol; a cycle (a
//! supertype that reaches back to the class being resolved) sees the
//! in-progress state and answers without recursing.

const std = @import("std");
const ast = @import("ast");

const sema_mod = @import("sema.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");
const subtyping = @import("subtyping.zig");
const annocheck = @import("annocheck.zig");
const declcheck = @import("declcheck.zig");
const names_mod = @import("names.zig");
const scope = @import("scope.zig");
const body = @import("body.zig");

const Allocator = std.mem.Allocator;
const Sema = sema_mod.Sema;
const Sym = symbols.Sym;
const TypeId = types.TypeId;
const Name = names_mod.Name;

/// Where a type reference is written: the innermost declaration (whose type
/// parameters and enclosing classes are in scope) and the file (whose
/// imports are).
pub const TypeCtx = struct {
    decl: Sym,
    file: u32,
    /// Resolving the class `decl`'s header: its nested classifiers are not
    /// in scope.
    header: bool = false,
};

fn classifierIn(s: *Sema, ctx: TypeCtx, n: Name) Allocator.Error!Sym {
    return scope.classifierInContextOf(s, ctx.decl, ctx.file, n, if (ctx.header) ctx.decl else .none);
}

pub fn ctxOf(s: *Sema, decl: Sym) TypeCtx {
    return .{ .decl = decl, .file = s.syms.get(decl).file };
}

/// Resolves a written type. An unknown name is reported and becomes the
/// error type.
pub fn resolveTypeRef(s: *Sema, ctx: TypeCtx, tr: *const ast.TypeRef) Allocator.Error!TypeId {
    if (tr.function) |ft| return resolveFunctionTypeRef(s, ctx, tr, ft);
    const cls = try resolveClassifierRef(s, ctx, tr);
    if (cls == .none) {
        try s.census.reportFmt(.unresolved_type, ctx.file, tr.span, "{s}", .{typeRefText(tr)});
        return s.types.errType();
    }
    if (tr.definitely_non_null) try definitelyNonNullLeft(s, ctx, cls, tr);
    if (tr.x().annotations.len != 0) try typeAnnotations(s, ctx, tr);
    switch (s.syms.kind(cls)) {
        .type_param => {
            if (tr.definitely_non_null) {
                return s.types.definitelyNotNull(try s.types.param(cls, false));
            }
            return s.types.param(cls, tr.nullable);
        },
        .type_alias => {
            const expanded = try expandAlias(s, ctx, cls, tr);
            return if (tr.nullable) s.types.makeNullable(expanded) else expanded;
        },
        .class => {
            var args = try resolveTypeArgs(s, ctx, tr.type_args);
            // An inner class written without its outer's arguments takes
            // them from the innermost enclosing class that is, or extends,
            // the outer class.
            const all = try classTypeParams(s, cls);
            const own = s.syms.classInfo(cls).type_params.len;
            if (all.len > own and args.len == own) {
                const full = try s.arena.alloc(types.Arg, all.len);
                @memcpy(full[0..own], args);
                // `Outer<String>.Inner` wrote them on its qualifiers, the
                // nearest outer class last.
                var written: std.ArrayList(types.Arg) = .empty;
                const quals = tr.x().qualifier_args;
                var qi = quals.len;
                while (qi > 0 and written.items.len < all.len - own) {
                    qi -= 1;
                    try written.appendSlice(s.arena, try resolveTypeArgs(s, ctx, quals[qi]));
                }
                if (written.items.len == all.len - own) {
                    @memcpy(full[own..], written.items);
                } else {
                    const view = try enclosingView(s, ctx.decl, s.syms.owner(cls));
                    for (all[own..], full[own..]) |tp, *a| {
                        const t = if (view) |v| v.get(tp) orelse try s.types.param(tp, false) else try s.types.param(tp, false);
                        a.* = .{ .variance = .inv, .ty = t };
                    }
                }
                args = full;
            }
            return s.types.classAttrs(cls, args, tr.nullable, try typeAttrs(s, ctx, tr));
        },
        else => {
            try s.census.reportFacts(.unresolved_type, ctx.file, tr.span, .{
                .message = try std.fmt.allocPrint(s.arena, "`{s}` is not a type", .{typeRefText(tr)}),
            }, "{s} is not a type", .{typeRefText(tr)});
            return s.types.errType();
        },
    }
}

/// The substitution `outer`'s type parameters take inside `decl`: from the
/// innermost class enclosing `decl` that is `outer` or extends it.
/// A written type's annotations stand on a type usage, in the files whose
/// declarations are checked.
fn typeAnnotations(s: *Sema, ctx: TypeCtx, tr: *const ast.TypeRef) Allocator.Error!void {
    const fc = s.fileOf(ctx.file) orelse return;
    if (!declcheck.checked(fc)) return;
    try annocheck.checkPlace(s, ctx, tr.x().annotations, .{ .admits = &.{.TYPE}, .name = "type usage" });
}

/// `T & Any` makes a type parameter whose bound admits null not null; any
/// other left side is refused, once where it is written.
fn definitelyNonNullLeft(s: *Sema, ctx: TypeCtx, cls: Sym, tr: *const ast.TypeRef) Allocator.Error!void {
    if (s.syms.kind(cls) == .type_param) {
        const bounds = try typeParamBounds(s, cls);
        for (bounds) |b| {
            if (!try subtyping.admitsNull(s, b)) break;
        } else return;
    }
    if (s.census.reportedAt(ctx.file, tr.span, .INCORRECT_LEFT_COMPONENT_OF_INTERSECTION)) return;
    const msg = "Intersection types are supported only for definitely non-nullable types: left part must be a type parameter with nullable bounds.";
    try s.census.reportFacts(.declaration, ctx.file, tr.span, .{ .message = msg, .factory = .INCORRECT_LEFT_COMPONENT_OF_INTERSECTION }, "{s}", .{msg});
}

fn enclosingView(s: *Sema, decl: Sym, outer: Sym) Allocator.Error!?types.Subst {
    var d = decl;
    while (d != .none) : (d = s.syms.owner(d)) {
        if (s.syms.kind(d) != .class) continue;
        if (d == outer) return null;
        const st = (try subtyping.supertypeWithClass(s, try selfType(s, d), outer)) orelse continue;
        return try subtyping.classSubst(s, st);
    }
    return null;
}

fn typeRefText(tr: *const ast.TypeRef) []const u8 {
    return tr.x().qualified_path orelse tr.name.name;
}

fn typeAttrs(s: *Sema, ctx: TypeCtx, tr: *const ast.TypeRef) Allocator.Error!types.Attrs {
    var a: types.Attrs = .{};
    if (s.builtins.composable != .none) a.composable = try annotatedWith(s, ctx, tr.x().annotations, s.builtins.composable);
    return a;
}

/// The annotation class an annotation names, resolved like a type written
/// in `ctx`; none when it does not resolve.
pub fn annotationClass(s: *Sema, ctx: TypeCtx, ann: *const ast.Annotation) Allocator.Error!Sym {
    if (ann.path.len == 0) return .none;
    const c = if (ann.path.len == 1) blk: {
        const n = s.names.lookup(ann.path[0].name) orelse return .none;
        break :blk try classifierIn(s, ctx, n);
    } else try resolveQualifiedClassifier(s, ctx, ann.path);
    if (c != .none and s.syms.kind(c) == .type_alias) return s.types.classSym(try aliasTarget(s, c));
    return c;
}

/// Where on a declaration an annotation is written: on the declaration,
/// on a property's getter or setter, or on the type a parameter is written
/// with.
pub const AnnotationSite = enum(u2) { decl, getter, setter, written_type };

pub fn annotationKey(sym: Sym, site: AnnotationSite) u64 {
    return (@as(u64, sym.int()) << 2) | @intFromEnum(site);
}

/// The annotations written on `sym` at `site`; null for a declaration with
/// no AST, one read back from a base image.
pub fn writtenAnnotations(s: *Sema, sym: Sym, site: AnnotationSite) ?[]const ast.Annotation {
    const d = s.syms.get(sym).decl;
    return switch (site) {
        .decl => switch (d) {
            .function => |x| (x orelse return null).annotations,
            .property, .local_prop => |x| (x orelse return null).annotations,
            // A primary constructor's are written before `constructor`.
            .class => |x| if (s.syms.kind(sym) == .constructor) (x orelse return null).x().primary_ctor_annotations else (x orelse return null).annotations,
            .object => |x| (x orelse return null).annotations,
            .secondary_ctor => |x| (x orelse return null).annotations,
            .enum_entry => |x| (x orelse return null).annotations,
            .type_alias => |x| (x orelse return null).annotations,
            .class_param => |x| (x orelse return null).annotations,
            .param => |x| (x orelse return null).annotations,
            .accessor => |x| (x orelse return null).annotations,
            .lambda => |x| (x orelse return null).annotations,
            else => &.{},
        },
        .getter, .setter => switch (d) {
            .property, .local_prop => |x| blk: {
                const pd = x orelse return null;
                const acc = (if (site == .getter) pd.getter else pd.setter) orelse break :blk &.{};
                break :blk acc.annotations;
            },
            else => &.{},
        },
        .written_type => switch (d) {
            .param => |x| (x orelse return null).ty.x().annotations,
            else => &.{},
        },
    };
}

/// The annotation classes written on `sym` at `site`, each resolved where
/// `sym` is declared, once. A declaration read back from a base image has
/// its answer from the bake (`Sema.annotation_classes`).
pub fn annotationClasses(s: *Sema, sym: Sym, site: AnnotationSite) Allocator.Error![]const Sym {
    const key = annotationKey(sym, site);
    if (s.annotation_classes.get(key)) |hit| return hit;
    const anns = writtenAnnotations(s, sym, site) orelse return &.{};
    if (anns.len == 0) return &.{};
    const ctx: TypeCtx = .{ .decl = sym, .file = s.syms.get(sym).file };
    const out = try s.arena.alloc(Sym, anns.len);
    for (anns, out) |*ann, *o| o.* = try annotationClass(s, ctx, ann);
    try s.annotation_classes.put(s.arena, key, out);
    return out;
}

/// Whether `sym` carries the annotation class `cls` at `site`.
pub fn hasAnnotation(s: *Sema, sym: Sym, site: AnnotationSite, cls: Sym) Allocator.Error!bool {
    if (cls == .none) return false;
    return std.mem.indexOfScalar(Sym, try annotationClasses(s, sym, site), cls) != null;
}

/// Whether one of `anns` names the annotation class `cls`.
pub fn annotatedWith(s: *Sema, ctx: TypeCtx, anns: []const ast.Annotation, cls: Sym) Allocator.Error!bool {
    if (cls == .none) return false;
    for (anns) |*ann| {
        if (try annotationClass(s, ctx, ann) == cls) return true;
    }
    return false;
}

fn resolveTypeArgs(s: *Sema, ctx: TypeCtx, targs: []const ast.TypeArg) Allocator.Error![]const types.Arg {
    if (targs.len == 0) return &.{};
    const out = try s.arena.alloc(types.Arg, targs.len);
    for (targs, out) |*ta, *o| {
        if (ta.is_star) {
            o.* = .{ .variance = .star, .ty = .none };
            continue;
        }
        o.* = .{
            .variance = switch (ta.variance) {
                .Invariant => .inv,
                .Out => .out,
                .In => .in,
            },
            .ty = try resolveTypeRef(s, ctx, &ta.ty),
        };
    }
    return out;
}

/// The classifier a type reference names: a type parameter, class or type
/// alias, or `.none`.
pub fn resolveClassifierRef(s: *Sema, ctx: TypeCtx, tr: *const ast.TypeRef) Allocator.Error!Sym {
    // A qualified reference carries its path out of line, except a function
    // receiver, whose name the parser keeps dotted.
    const dotted: ?[]const u8 = tr.x().qualified_path orelse
        if (std.mem.indexOfScalar(u8, tr.name.name, '.') != null) tr.name.name else null;
    if (dotted) |qp| {
        var segs: std.ArrayList(ast.Ident) = .empty;
        var it = std.mem.splitScalar(u8, qp, '.');
        while (it.next()) |seg| try segs.append(s.arena, .{ .name = seg, .span = tr.span });
        return resolveQualifiedClassifier(s, ctx, segs.items);
    }
    const n = s.names.lookup(tr.name.name) orelse return .none;
    return classifierIn(s, ctx, n);
}

/// `A.B.C` as a classifier: the first segment in scope (or a package path),
/// then nested classifiers.
pub fn resolveQualifiedClassifier(s: *Sema, ctx: TypeCtx, path: []const ast.Ident) Allocator.Error!Sym {
    if (path.len == 0) return .none;
    const first = s.names.lookup(path[0].name) orelse return .none;
    var cur = try classifierIn(s, ctx, first);
    var i: usize = 1;
    if (cur == .none) {
        // A package path, then classes; the last segment may also be a
        // type alias (`lib.events.EventHandler<T>`).
        if (path.len < 2) return .none;
        const r = try scope.resolvePathContainer(s, path[0 .. path.len - 1]);
        if (r.used != path.len - 1) return .none;
        const last = s.names.lookup(path[path.len - 1].name) orelse return .none;
        const found = scope.classifierIn(s, r.container, last);
        if (found == .none) return .none;
        return switch (s.syms.kind(found)) {
            .class, .type_alias => found,
            else => .none,
        };
    }
    while (i < path.len) : (i += 1) {
        if (s.syms.kind(cur) != .class) return .none;
        const n = s.names.lookup(path[i].name) orelse return .none;
        const next = try scope.nestedClassifier(s, cur, n);
        if (next == .none) return .none;
        cur = next;
    }
    return cur;
}

fn resolveFunctionTypeRef(s: *Sema, ctx: TypeCtx, tr: *const ast.TypeRef, ft: *const ast.FunctionTypeRef) Allocator.Error!TypeId {
    // Contexts first, then the receiver, then the parameters.
    var contexts: std.ArrayList(TypeId) = .empty;
    for (ft.context_params) |*cp| try contexts.append(s.arena, try resolveTypeRef(s, ctx, cp));
    const recv: TypeId = if (ft.receiver) |*r| try resolveTypeRef(s, ctx, r) else .none;
    var params: std.ArrayList(TypeId) = .empty;
    for (ft.params) |*p| try params.append(s.arena, try resolveTypeRef(s, ctx, p));
    const ret = try resolveTypeRef(s, ctx, &ft.ret);
    const n: u32 = @intCast(contexts.items.len + params.items.len + @intFromBool(recv != .none));
    const cls = try s.functionClass(n, ft.is_suspend);
    var args: std.ArrayList(types.Arg) = .empty;
    for (contexts.items) |c| try args.append(s.arena, .{ .variance = .inv, .ty = c });
    if (recv != .none) try args.append(s.arena, .{ .variance = .inv, .ty = recv });
    for (params.items) |p| try args.append(s.arena, .{ .variance = .inv, .ty = p });
    try args.append(s.arena, .{ .variance = .inv, .ty = ret });
    var attrs = try typeAttrs(s, ctx, tr);
    attrs.ext_fn = recv != .none;
    attrs.context_count = @intCast(@min(ft.context_params.len, 15));
    return s.types.classAttrs(cls, args.items, tr.nullable, attrs);
}

fn expandAlias(s: *Sema, ctx: TypeCtx, alias: Sym, tr: *const ast.TypeRef) Allocator.Error!TypeId {
    const target = try aliasTarget(s, alias);
    const info = s.syms.aliasInfo(alias);
    if (info.type_params.len == 0) return target;
    var subst: types.Subst = .empty;
    var starred: std.ArrayList(Sym) = .empty;
    const Projected = struct { tp: Sym, variance: types.Variance, ty: TypeId };
    var projected: std.ArrayList(Projected) = .empty;
    for (info.type_params, 0..) |tp, i| {
        if (i < tr.type_args.len and !tr.type_args[i].is_star) {
            const at = try resolveTypeRef(s, ctx, &tr.type_args[i].ty);
            switch (tr.type_args[i].variance) {
                .Invariant => try subst.put(s.arena, tp, at),
                .In => try projected.append(s.arena, .{ .tp = tp, .variance = .in, .ty = at }),
                .Out => try projected.append(s.arena, .{ .tp = tp, .variance = .out, .ty = at }),
            }
        } else try starred.append(s.arena, tp);
    }
    var t = try s.types.substitute(target, &subst);
    // `ML<out T>` for `MutableList<K>` is `MutableList<out T>`: a projected
    // argument projects each place the parameter is a type argument.
    for (projected.items) |pj| {
        t = try projectParam(s, t, pj.tp, pj.variance, pj.ty);
        var rest: types.Subst = .empty;
        try rest.put(s.arena, pj.tp, pj.ty);
        t = try s.types.substitute(t, &rest);
    }
    // `Provider<*>` for `(Base) -> Strategy<Base>?` is
    // `Function1<*, Strategy<*>?>`: a star argument projects each place the
    // parameter is a type argument.
    for (starred.items) |tp| t = try starProject(s, t, tp);
    return t;
}

/// `t` with each type argument that is the parameter `tp` replaced by
/// `ty` projected `v`; a projection the place already has the other way
/// round becomes a star.
fn projectParam(s: *Sema, t: TypeId, tp: Sym, v: types.Variance, ty: TypeId) Allocator.Error!TypeId {
    switch (s.types.get(t)) {
        .class => |c| {
            var changed = false;
            const args = try s.arena.alloc(types.Arg, c.args.len);
            for (c.args, args) |a, *o| {
                o.* = a;
                if (a.variance == .star) continue;
                switch (s.types.get(a.ty)) {
                    .param => |p| if (p.sym == tp) {
                        const arg_t = if (p.nullable) try s.types.makeNullable(ty) else ty;
                        o.* = if (a.variance == .inv or a.variance == v)
                            .{ .variance = v, .ty = arg_t }
                        else
                            .{ .variance = .star, .ty = .none };
                        changed = true;
                        continue;
                    },
                    else => {},
                }
                const inner = try projectParam(s, a.ty, tp, v, ty);
                if (inner != a.ty) {
                    o.ty = inner;
                    changed = true;
                }
            }
            if (!changed) return t;
            return s.types.classAttrs(c.sym, args, c.nullable, c.attrs);
        },
        else => return t,
    }
}

fn starProject(s: *Sema, t: TypeId, tp: Sym) Allocator.Error!TypeId {
    switch (s.types.get(t)) {
        .param => |p| return if (p.sym == tp) s.t.any_q else t,
        .class => |c| {
            var changed = false;
            const args = try s.arena.alloc(types.Arg, c.args.len);
            for (c.args, args) |a, *o| {
                o.* = a;
                if (a.variance == .star) continue;
                switch (s.types.get(a.ty)) {
                    .param => |p| if (p.sym == tp) {
                        o.* = .{ .variance = .star, .ty = .none };
                        changed = true;
                        continue;
                    },
                    else => {},
                }
                const inner = try starProject(s, a.ty, tp);
                if (inner != a.ty) {
                    o.ty = inner;
                    changed = true;
                }
            }
            if (!changed) return t;
            return s.types.classAttrs(c.sym, args, c.nullable, c.attrs);
        },
        else => return t,
    }
}

pub fn aliasTarget(s: *Sema, alias: Sym) Allocator.Error!TypeId {
    const info = s.syms.aliasInfo(alias);
    switch (info.state) {
        .done => return info.target,
        .resolving => return s.types.errType(),
        .pending => {},
    }
    info.state = .resolving;
    // Only a declaration from source is pending: an image's are resolved.
    const ta = s.syms.get(alias).decl.type_alias.?;
    const t = try resolveTypeRef(s, ctxOf(s, alias), &ta.target);
    const info2 = s.syms.aliasInfo(alias);
    info2.target = t;
    info2.state = .done;
    return t;
}

/// A class's direct supertypes. A class that names none extends `Any`; an
/// enum class `Enum<Self>`; an annotation class `Annotation`.
pub fn supertypes(s: *Sema, cls: Sym) Allocator.Error![]const TypeId {
    const info = s.syms.classInfo(cls);
    switch (info.supertypes_state) {
        .done => return info.supertypes,
        .resolving => return &.{},
        .pending => {},
    }
    info.supertypes_state = .resolving;
    const sym = s.syms.get(cls);
    const kind = info.kind;
    const written: []const ast.TypeRef = switch (sym.decl) {
        .class => |c| c.?.supertypes,
        .object => |o| o.?.supertypes,
        .object_literal => |o| o.?.supertypes,
        else => &.{},
    };
    // Supertypes are written in the class header, where the class's own
    // type parameters are in scope and its nested classifiers are not.
    const ctx = TypeCtx{ .decl = cls, .file = sym.file, .header = true };
    var out: std.ArrayList(TypeId) = .empty;
    for (written) |*tr| {
        const t = try resolveTypeRef(s, ctx, tr);
        if (s.types.isErr(t)) continue;
        try out.append(s.arena, t);
    }
    // An enum class extends `Enum<Self>` before the interfaces it names;
    // an annotation class, `Annotation`.
    if (kind == .enum_class and s.builtins.enum_ != .none and cls != s.builtins.enum_) {
        try out.insert(s.arena, 0, try s.types.class(s.builtins.enum_, &.{.{ .variance = .inv, .ty = try selfType(s, cls) }}, false));
    }
    if (kind == .annotation and out.items.len == 0 and s.builtins.annotation != .none) {
        try out.append(s.arena, try s.simpleType(s.builtins.annotation));
    }
    if (out.items.len == 0 and cls != s.builtins.any and s.builtins.any != .none) try out.append(s.arena, s.t.any);
    const info2 = s.syms.classInfo(cls);
    info2.supertypes = out.items;
    info2.supertypes_state = .done;
    return out.items;
}

/// The type `this` has in a class body: the class applied to its own type
/// parameters.
/// The type parameters a class's type takes arguments for: its own, then,
/// for an inner class, its outer class's (`Outer<String>.Inner<Int>` is
/// `Inner` applied to `Int, String`).
pub fn classTypeParams(s: *Sema, cls: Sym) Allocator.Error![]const Sym {
    const info = s.syms.classInfo(cls);
    if (info.all_type_params) |all| return all;
    var out: []const Sym = info.type_params;
    const outer = s.syms.owner(cls);
    var captured: std.ArrayList(Sym) = .empty;
    if (s.syms.flags(cls).inner and outer != .none and s.syms.kind(outer) == .class) {
        try captured.appendSlice(s.arena, try classTypeParams(s, outer));
    } else if (outer != .none and s.syms.kind(outer) != .package and !scope.isMemberClass(s, cls)) {
        // A class declared in a body sees the type parameters in scope
        // there, and its type carries them: `fun <T> T.self() = object {
        // fun calc(): T = ... }` called on an `Int` makes an object whose
        // `calc` returns an `Int`.
        var cur = outer;
        while (cur != .none) : (cur = s.syms.owner(cur)) {
            switch (s.syms.kind(cur)) {
                .function, .constructor => try captured.appendSlice(s.arena, s.syms.functionInfo(cur).type_params),
                .property => try captured.appendSlice(s.arena, s.syms.propertyInfo(cur).type_params),
                .class => {
                    try captured.appendSlice(s.arena, try classTypeParams(s, cur));
                    break;
                },
                else => break,
            }
        }
    }
    if (captured.items.len != 0) {
        const all = try s.arena.alloc(Sym, out.len + captured.items.len);
        @memcpy(all[0..out.len], out);
        @memcpy(all[out.len..], captured.items);
        out = all;
    }
    s.syms.classInfo(cls).all_type_params = out;
    return out;
}

pub fn selfType(s: *Sema, cls: Sym) Allocator.Error!TypeId {
    const info = s.syms.classInfo(cls);
    if (info.self_type != .none) return info.self_type;
    const tps = try classTypeParams(s, cls);
    const args = try s.arena.alloc(types.Arg, tps.len);
    for (tps, args) |tp, *a| a.* = .{ .variance = .inv, .ty = try s.types.param(tp, false) };
    const t = try s.types.class(cls, args, false);
    s.syms.classInfo(cls).self_type = t;
    return t;
}

/// Upper bounds of a type parameter: its own and any `where` clause naming
/// it. None written means `Any?`.
pub fn typeParamBounds(s: *Sema, tp: Sym) Allocator.Error![]const TypeId {
    const info = s.syms.typeParamInfo(tp);
    switch (info.state) {
        .done => return info.bounds,
        .resolving => return &.{},
        .pending => {},
    }
    info.state = .resolving;
    const sym = s.syms.get(tp);
    const owner = sym.owner;
    const ctx = TypeCtx{ .decl = owner, .file = sym.file };
    var out: std.ArrayList(TypeId) = .empty;
    if (sym.decl == .type_param) {
        if (sym.decl.type_param.?.upper_bound) |*ub| try out.append(s.arena, try resolveTypeRef(s, ctx, ub));
    }
    const where: []const ast.WhereBound = switch (s.syms.get(owner).decl) {
        .function => |f| f.?.where_bounds,
        .class => |c| c.?.x().where_bounds,
        else => &.{},
    };
    for (where) |*wb| {
        if (!std.mem.eql(u8, wb.name.name, s.str(sym.name))) continue;
        try out.append(s.arena, try resolveTypeRef(s, ctx, &wb.bound));
    }
    if (out.items.len == 0) try out.append(s.arena, s.t.any_q);
    const info2 = s.syms.typeParamInfo(tp);
    info2.bounds = out.items;
    info2.state = .done;
    return out.items;
}

/// Fills a function's receiver and parameter types and, when written, its
/// return type. An unwritten return type of an expression body is inferred
/// by `returnType`.
pub fn functionHeader(s: *Sema, f: Sym) Allocator.Error!void {
    const info = s.syms.functionInfo(f);
    if (info.state != .pending) return;
    info.state = .resolving;
    const sym = s.syms.get(f);
    const ctx = TypeCtx{ .decl = f, .file = sym.file };
    var recv: TypeId = .none;
    var ret: TypeId = .none;
    switch (sym.decl) {
        .function => |fd_opt| {
            const fd = fd_opt.?;
            if (try annotatedWith(s, ctx, fd.annotations, s.builtins.composable)) s.syms.getMut(f).flags.composable = true;
            if (fd.receiver_type) |rt| recv = try resolveTypeRef(s, ctx, rt);
            if (fd.return_type) |rt| {
                ret = try resolveTypeRef(s, ctx, rt);
            } else if (fd.body == null or fd.body.? == .Block) {
                ret = s.t.unit;
            }
        },
        .class, .object, .secondary_ctor => {
            // A constructor returns its class.
            ret = try selfType(s, sym.owner);
        },
        else => {},
    }
    for (s.syms.functionInfo(f).params) |p| _ = try paramType(s, p);
    for (s.syms.functionInfo(f).context_params) |p| _ = try paramType(s, p);
    const info2 = s.syms.functionInfo(f);
    info2.receiver = recv;
    if (info2.ret == .none) info2.ret = ret;
    info2.state = .done;
}

/// The declared or inferred return type.
pub fn returnType(s: *Sema, f: Sym) Allocator.Error!TypeId {
    try functionHeader(s, f);
    const info = s.syms.functionInfo(f);
    if (info.ret != .none) return info.ret;
    return body.inferReturnType(s, f);
}

pub fn receiverType(s: *Sema, f: Sym) Allocator.Error!TypeId {
    switch (s.syms.kind(f)) {
        .function, .constructor => {
            try functionHeader(s, f);
            return s.syms.functionInfo(f).receiver;
        },
        .property => {
            try propertyHeader(s, f);
            return s.syms.propertyInfo(f).receiver;
        },
        else => return .none,
    }
}

/// The declared type of a value parameter. The element type of a `vararg`
/// parameter is what is written; `paramType` answers the written type and
/// callers wrap it in the array type where the parameter is read.
pub fn paramType(s: *Sema, p: Sym) Allocator.Error!TypeId {
    const info = s.syms.paramInfo(p);
    switch (info.state) {
        .done => return info.ty,
        .resolving => return s.types.errType(),
        .pending => {},
    }
    info.state = .resolving;
    const sym = s.syms.get(p);
    const ctx = TypeCtx{ .decl = sym.owner, .file = sym.file };
    const t: TypeId = switch (sym.decl) {
        .param => |pd| try resolveTypeRef(s, ctx, &pd.?.ty),
        .class_param => |cp| try resolveTypeRef(s, ctx, &cp.?.ty),
        .context_param => |cp| try resolveTypeRef(s, ctx, &cp.?.ty),
        else => s.types.errType(),
    };
    const info2 = s.syms.paramInfo(p);
    info2.ty = t;
    info2.state = .done;
    return t;
}

/// Fills a property's receiver and, when written, its type.
pub fn propertyHeader(s: *Sema, p: Sym) Allocator.Error!void {
    const info = s.syms.propertyInfo(p);
    if (info.state != .pending) return;
    info.state = .resolving;
    const sym = s.syms.get(p);
    const ctx = TypeCtx{ .decl = p, .file = sym.file };
    var recv: TypeId = .none;
    var ty: TypeId = .none;
    switch (sym.decl) {
        .property => |pd_opt| {
            const pd = pd_opt.?;
            if (pd.receiver_written orelse pd.receiver_type) |rt| recv = try resolveTypeRef(s, ctx, rt);
            if (pd.ty) |t| ty = try resolveTypeRef(s, ctx, t);
            const comp = s.builtins.composable;
            if (try annotatedWith(s, ctx, pd.annotations, comp) or
                (pd.getter != null and try annotatedWith(s, ctx, pd.getter.?.annotations, comp)))
            {
                s.syms.getMut(p).flags.composable = true;
            }
        },
        .class_param => |cp_opt| {
            const cp = cp_opt.?;
            ty = try resolveTypeRef(s, .{ .decl = sym.owner, .file = sym.file }, &cp.ty);
            // A `vararg val` constructor property holds the array.
            if (cp.is_vararg) ty = try s.varargArrayType(ty);
        },
        else => {},
    }
    const info2 = s.syms.propertyInfo(p);
    info2.receiver = recv;
    if (info2.ty == .none) info2.ty = ty;
    info2.state = .done;
}

/// The declared or inferred type of a property.
pub fn propertyType(s: *Sema, p: Sym) Allocator.Error!TypeId {
    try propertyHeader(s, p);
    const info = s.syms.propertyInfo(p);
    if (info.ty != .none) return info.ty;
    // A property whose initializer is being resolved answers with the error
    // type to the lookup that reached it again, and that answer is not
    // kept: the initializer's own type fills the property when it is done.
    return body.inferPropertyType(s, p);
}

/// Resolves every header the base set declares, so the census sees every
/// unresolved type a signature names without resolving a body.
pub fn resolveAllHeaders(s: *Sema) Allocator.Error!void {
    var i: u32 = 1;
    while (i < s.syms.count()) : (i += 1) {
        const sym = Sym.from(i);
        switch (s.syms.kind(sym)) {
            .class => _ = try supertypes(s, sym),
            .function, .constructor => try functionHeader(s, sym),
            .property => try propertyHeader(s, sym),
            .type_param => _ = try typeParamBounds(s, sym),
            .type_alias => _ = try aliasTarget(s, sym),
            else => {},
        }
    }
}
