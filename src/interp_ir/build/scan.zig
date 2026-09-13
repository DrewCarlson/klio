//! AST-walk scanning helpers: package prefixes and fully qualified names,
//! property scope and type-head recording, constant folding of literal
//! initializers, and member-name collection across the class hierarchy.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");

const Allocator = std.mem.Allocator;
const Module = ir.Module;
const Const = ir.Const;
const Value = runtime.Value;
const Decl = ast.Decl;
const StringSet = std.StringHashMap(void);

const build_types = @import("types.zig");
const FileClasses = build_types.FileClasses;
const Span = build_types.Span;
const SpanStrMap = build_types.SpanStrMap;
const TypedDefault = build_types.TypedDefault;

pub fn boundTypeRecordComplete(bound: *const ast.TypeRef) bool {
    return !bound.nullable and bound.type_args.len == 0 and
        bound.function == null and !bound.definitely_non_null and
        bound.qualified_path == null;
}

pub fn collectClassTypeParamBounds(
    allocator: Allocator,
    class: *const ast.Class,
) Allocator.Error!?[]const ir.ModuleRegistry.TypeParamBound {
    if (class.type_params.len == 0) return null;
    var bounds: std.ArrayList(ir.ModuleRegistry.TypeParamBound) = .empty;
    errdefer bounds.deinit(allocator);
    for (class.type_params) |*param| {
        const first = bounds.items.len;
        var any_bound = false;
        if (param.upper_bound) |*upper| {
            try bounds.append(allocator, .{
                .param = param.name.name,
                .bound = upper.name.name,
                .complete = boundTypeRecordComplete(upper),
                .args = try ir.lower.decl.concreteBoundArgs(allocator, class.type_params, upper),
            });
            any_bound = true;
        }
        for (class.where_bounds) |*where_bound| {
            if (!std.mem.eql(u8, where_bound.name.name, param.name.name)) continue;
            try bounds.append(allocator, .{
                .param = param.name.name,
                .bound = where_bound.bound.name.name,
                .complete = boundTypeRecordComplete(&where_bound.bound),
            });
            any_bound = true;
        }
        if (!any_bound) {
            try bounds.append(allocator, .{
                .param = param.name.name,
                .bound = "kotlin.Any",
            });
        }
        if (bounds.items.len - first > 1) {
            for (bounds.items[first..]) |*bound| bound.complete = false;
        }
    }
    return @as(?[]const ir.ModuleRegistry.TypeParamBound, try bounds.toOwnedSlice(allocator));
}
/// Map a declared property type annotation to its static-field default
/// category. Nullable, function, and non-primitive heads are references
/// (default null); a qualified head only counts as a builtin primitive
/// when the qualifier is exactly `kotlin`.
/// Simple type-name head for ctor-overload disambiguation: drop any package
/// qualifier, generic arguments, and trailing nullability.
/// The simple head of each class type parameter's upper bound, from the
/// inline `<T : Int>` form or a `where T : Int` clause; empty when the
/// parameter is unbounded or bounded by a function type.
pub fn classTypeParamBoundHeads(a: Allocator, type_params: []const ast.TypeParam, where_bounds: []const ast.WhereBound) Allocator.Error![]const []const u8 {
    if (type_params.len == 0) return &.{};
    const out = try a.alloc([]const u8, type_params.len);
    for (type_params, out) |*tp, *slot| {
        slot.* = "";
        var bound: ?*const ast.TypeRef = if (tp.upper_bound) |*ub| ub else null;
        if (bound == null) {
            for (where_bounds) |*wb| {
                if (std.mem.eql(u8, wb.name.name, tp.name.name)) {
                    bound = &wb.bound;
                    break;
                }
            }
        }
        const b = bound orelse continue;
        if (b.function != null) continue;
        slot.* = try a.dupe(u8, simpleTypeHead(b.name.name));
    }
    return out;
}

pub fn simpleTypeHead(name: []const u8) []const u8 {
    var s = name;
    if (std.mem.lastIndexOfScalar(u8, s, '.')) |i| s = s[i + 1 ..];
    if (std.mem.indexOfScalar(u8, s, '<')) |i| s = s[0..i];
    if (s.len > 0 and s[s.len - 1] == '?') s = s[0 .. s.len - 1];
    return s;
}

pub fn typedDefaultFor(ty: ?*const ast.TypeRef) TypedDefault {
    const t = ty orelse return .none;
    if (t.nullable or t.function != null) return .null_ref;
    const heads = .{
        .{ "Int", TypedDefault.int },
        .{ "Long", TypedDefault.long },
        .{ "Short", TypedDefault.short },
        .{ "Byte", TypedDefault.byte },
        .{ "UInt", TypedDefault.uint },
        .{ "ULong", TypedDefault.ulong },
        .{ "UShort", TypedDefault.ushort },
        .{ "UByte", TypedDefault.ubyte },
        .{ "Boolean", TypedDefault.boolean },
        .{ "Char", TypedDefault.char },
        .{ "Float", TypedDefault.float },
        .{ "Double", TypedDefault.double },
    };
    inline for (heads) |h| {
        if (std.mem.eql(u8, t.name.name, h[0])) {
            if (t.qualified_path) |q| {
                if (!std.mem.startsWith(u8, q, "kotlin.") or !std.mem.eql(u8, q["kotlin.".len..], h[0])) return .null_ref;
            }
            return h[1];
        }
    }
    return .null_ref;
}

/// Static-field default category for an unannotated top-level property,
/// inferred from a trivially-typed initializer. kotlinc defaults a forward
/// read of a not-yet-initialized property from the property's inferred type;
/// without a type checker the only inferable shapes on the lowering path are
/// the literal initializers whose type is fixed by the literal itself
/// (`val n = 10` -> Int, `val s = "x"` -> reference). Non-literal
/// initializers (a HOF call, an arithmetic expression) need full inference
/// and keep the on-demand drive path (`.none`).
pub fn typedDefaultForInit(init: *const ast.Expr) TypedDefault {
    return switch (init.*) {
        .IntLit => |lit| switch (lit.kind) {
            .Int => .int,
            .Long => .long,
            .UInt => .uint,
            .ULong => .ulong,
        },
        .FloatLit => |lit| switch (lit.kind) {
            .Double => .double,
            .Float => .float,
        },
        .BoolLit => .boolean,
        .CharLit => .char,
        // A string literal / template is a non-null reference; its
        // pre-init field default is null, matching kotlinc.
        .StringTemplate => .null_ref,
        else => .none,
    };
}
pub fn packagePrefix(allocator: Allocator, pkg: ?ast.PackageHeader) Allocator.Error![]const u8 {
    const p = pkg orelse return "";
    return joinIdents(allocator, p.path, ".");
}

pub fn joinIdents(allocator: Allocator, idents: []const ast.Ident, sep: []const u8) Allocator.Error![]const u8 {
    if (idents.len == 0) return "";
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (idents, 0..) |id, i| {
        if (i != 0) try buf.appendSlice(allocator, sep);
        try buf.appendSlice(allocator, id.name);
    }
    return buf.toOwnedSlice(allocator);
}

pub fn collectClassifierFqns(allocator: Allocator, d: *const Decl, pkg: []const u8, out: *SpanStrMap) Allocator.Error!void {
    if (d.* == .TypeAlias) {
        const ta = &d.TypeAlias;
        if (pkg.len != 0) {
            try out.put(ta.span, try std.fmt.allocPrint(
                allocator,
                "{s}.{s}",
                .{ pkg, ta.name.name },
            ));
        }
    }
    if (d.* == .Class) {
        const c = &d.Class;
        if (pkg.len != 0) {
            try out.put(c.span, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ pkg, c.name.name }));
        }
        const inner_pkg = if (pkg.len == 0)
            c.name.name
        else
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ pkg, c.name.name });
        for (c.members) |*m| try collectClassifierFqns(allocator, m, inner_pkg, out);
    }
    if (d.* == .Object) {
        const o = &d.Object;
        if (pkg.len != 0) {
            try out.put(o.span, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ pkg, o.name.name }));
        }
        const inner_pkg = if (pkg.len == 0)
            o.name.name
        else
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ pkg, o.name.name });
        for (o.members) |*m| try collectClassifierFqns(allocator, m, inner_pkg, out);
    }
}

/// Record the DECLARING package of every decl — including members of
/// classes and objects at any nesting depth, whose lifted top-level
/// forms keep their source spans. A nested class's FQN override is
/// class-qualified (`pkg.Outer.Inner`), so the package cannot be
/// recovered from it; this map carries the file's package directly.
/// The no-package case records `""` for the same reason: a nested
/// decl's class-qualified override (`Outer.Inner`) would otherwise be
/// misread as a package prefix.
pub fn collectDeclPkgs(allocator: Allocator, d: *const Decl, pkg: []const u8, out: *SpanStrMap) Allocator.Error!void {
    switch (d.*) {
        .Class => |*c| {
            try out.put(c.span, pkg);
            for (c.members) |*m| try collectDeclPkgs(allocator, m, pkg, out);
        },
        .Object => |*o| {
            try out.put(o.span, pkg);
            for (o.members) |*m| try collectDeclPkgs(allocator, m, pkg, out);
        },
        .Function => |*f| try out.put(f.span, pkg),
        .Property => |p| try out.put(p.span, pkg),
        .TypeAlias => |*ta| try out.put(ta.span, pkg),
    }
}

/// Package of one top-level decl in the combined multi-file program.
/// Used to seed `setLowerSelfPackage` around accessor/thunk lowering
/// that runs outside the class/function body drivers, so the symbol
/// index keys those bodies on their declaring package too.
/// Record one top-level property's scoping identity (FQN + declaring
/// package) into the registry, so a bare read can be ranked under Kotlin
/// scoping. Uses the property-FQN override map (which already carries the
/// package-qualified FQN for packaged properties) and `decl_pkg` for the
/// package, falling back to the package derived from the FQN.
/// Record a top-level EXTENSION property's declared type head keyed by its
/// receiver head, in the decl scan before any body lowers — the bare-read
/// type channel (`extPropReturnHead`) answers from this map even while the
/// declaring library itself is still lowering (`val IntArray.indices:
/// IntRange` types the `indices` receiver inside `_Arrays.kt` bodies).
pub fn noteExtPropTypeHead(module: *Module, p: *const ast.Property) Allocator.Error!void {
    const recv = &(p.receiver_type orelse return);
    const ty = &(p.ty orelse return);
    if (recv.name.name.len == 0) return;
    // A function-typed property records the `<function>` marker: no class
    // answers a bare read's type from it, but the member-call route knows
    // `recv.name(args)` invokes the property's value.
    if (ty.function != null) {
        try module.registry.ext_prop_type_heads.put(.{ .a = recv.name.name, .b = p.name.name }, "<function>");
        return;
    }
    if (ty.name.name.len == 0) return;
    try module.registry.ext_prop_type_heads.put(
        .{ .a = recv.name.name, .b = p.name.name },
        ty.name.name,
    );
}

pub fn notePropScope(
    a: Allocator,
    module: *Module,
    func_fqn_overrides: *const SpanStrMap,
    decl_pkg: *const SpanStrMap,
    package_prefix: []const u8,
    p: *const ast.Property,
) Allocator.Error!void {
    const fqn = blk: {
        const resolved = try resolveFqn(a, func_fqn_overrides, p.span, package_prefix, p.name.name);
        // A file-private collision rename (`prefix$f12`) happened after the
        // span-keyed override was recorded: the registered fqn must carry
        // the mangled simple name, or two files' consts share one key.
        const last = if (std.mem.lastIndexOfScalar(u8, resolved, '.')) |d| resolved[d + 1 ..] else resolved;
        if (std.mem.eql(u8, last, p.name.name)) break :blk resolved;
        if (std.mem.lastIndexOfScalar(u8, resolved, '.')) |d| {
            break :blk try std.fmt.allocPrint(a, "{s}.{s}", .{ resolved[0..d], p.name.name });
        }
        break :blk p.name.name;
    };
    const pkg = try declPackage(a, decl_pkg, func_fqn_overrides, p.span, package_prefix, p.name.name);
    const gop = try module.registry.top_level_prop_pkgs.getOrPut(p.name.name);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    // A re-lowered property (same FQN) is not a second declaration.
    for (gop.value_ptr.items) |existing| {
        if (std.mem.eql(u8, existing.fqn, fqn)) return;
    }
    try gop.value_ptr.append(a, .{ .fqn = fqn, .package = pkg });
    // The declared type head, so a bare read used as a receiver types
    // statically (`asserter.assertEquals(...)`).
    if (p.ty) |*ty| {
        if (ty.function == null and ty.name.name.len != 0) {
            try module.registry.top_level_prop_type_heads.put(fqn, ty.name.name);
            if (ty.type_args.len != 0) {
                var concrete = true;
                for (ty.type_args) |*ta| {
                    if (ta.is_star or ta.ty.name.name.len == 0) concrete = false;
                }
                if (concrete) {
                    try module.registry.top_level_prop_type_refs.put(
                        fqn,
                        try ir.lower.decl.loweredTypeRef(a, ty, true),
                    );
                }
            }
        }
    } else if (p.init) |*init| {
        // An UNANNOTATED property states its type through a literal
        // initializer just as definitely as an annotation would, and the
        // stdlib writes its file-level constants that way
        // (`private const val NANOS_PER_SECOND = 1_000_000_000`). Without
        // this, every member call on such a read resolved by name.
        if (constExprTypeHead(module, init)) |head| {
            try module.registry.top_level_prop_type_heads.put(fqn, head);
        } else if (initCalleeName(init)) |callee| {
            // A factory or constructor call states the type as definitely as
            // an annotation, but the name has to be RESOLVED to say what it
            // returns, and nothing is registered yet. Record the name; the
            // module answers when the whole declaration set is in.
            try module.registry.top_level_prop_init_callees.put(fqn, callee);
        }
    }
    // A `const val` with a literal initializer records its value so the
    // lowering can inline the constant at reference sites, exactly as
    // kotlinc does.
    if (p.is_const) {
        if (p.init) |*init| {
            if (constLiteralOf(init)) |cv| {
                try module.registry.top_level_const_vals.put(fqn, cv);
            }
        }
    }
}

/// The `ir.Const` for a compile-time-constant initializer expression: a
/// plain literal, optionally under unary minus. Anything else (arithmetic,
/// references, string templates with interpolation) returns null and the
/// property keeps the ordinary global-read path.
/// The type a literal initializer states outright. Deliberately literals
/// only: a call or a name would need resolution this early pass does not
/// have, and a wrong head is worse than none.
/// `private val capacity = buffer.size` — a member-read initializer whose
/// receiver is a primary param of a builtin SIZED container states Int as
/// definitely as an annotation.
pub fn memberSizedInitHead(c: *const ast.Class, init: *const ast.Expr) ?[]const u8 {
    if (init.* != .Member) return null;
    const m = init.Member;
    const nm = m.name.name;
    if (!std.mem.eql(u8, nm, "size") and !std.mem.eql(u8, nm, "length")) return null;
    if (m.receiver.* != .Path or m.receiver.Path.segments.len != 1) return null;
    const rn = m.receiver.Path.segments[0].name;
    for (c.primary_params) |*pp| {
        if (!std.mem.eql(u8, pp.name.name, rn)) continue;
        const h = pp.ty.name.name;
        const sized = [_][]const u8{
            "Array",         "ByteArray",  "ShortArray",   "IntArray",     "LongArray",
            "FloatArray",    "DoubleArray", "BooleanArray", "CharArray",    "UByteArray",
            "UShortArray",   "UIntArray",  "ULongArray",   "List",         "MutableList",
            "Set",           "MutableSet", "Map",          "MutableMap",   "Collection",
            "MutableCollection", "String", "CharSequence", "StringBuilder",
        };
        for (sized) |s| {
            if (std.mem.eql(u8, h, s)) return "Int";
        }
        return null;
    }
    return null;
}

pub fn promoteConstHeads(l: []const u8, r: []const u8) ?[]const u8 {
    const eq = std.mem.eql;
    if (eq(u8, l, r)) {
        if (eq(u8, l, "Int") or eq(u8, l, "Long") or eq(u8, l, "Float") or
            eq(u8, l, "Double") or eq(u8, l, "UInt") or eq(u8, l, "ULong")) return l;
        return null;
    }
    const li = eq(u8, l, "Int");
    const ri = eq(u8, r, "Int");
    if ((li and eq(u8, r, "Long")) or (ri and eq(u8, l, "Long"))) return "Long";
    if (eq(u8, l, "Double") or eq(u8, r, "Double")) {
        if (li or ri or eq(u8, l, "Long") or eq(u8, r, "Long") or
            eq(u8, l, "Float") or eq(u8, r, "Float")) return "Double";
    }
    return null;
}

/// The type head of a CONST-EXPRESSION initializer: literals, unary +/-,
/// arithmetic over foldable operands, and a bare Path naming an
/// already-recorded top-level property whose every declaration agrees on
/// one head (`DAYS_0000_TO_1970 = DAYS_PER_CYCLE * 5 - (30 * 365 + 7)`).
pub fn constExprTypeHead(module: *Module, e: *const ast.Expr) ?[]const u8 {
    if (literalTypeHead(e)) |h| return h;
    switch (e.*) {
        .Unary => |u| return switch (u.op) {
            .Neg, .Pos => constExprTypeHead(module, u.expr),
            else => null,
        },
        .Binary => |bin| {
            const l = constExprTypeHead(module, bin.lhs) orelse return null;
            const r = constExprTypeHead(module, bin.rhs) orelse return null;
            return switch (bin.op) {
                .Add, .Sub, .Mul, .Div, .Rem => promoteConstHeads(l, r),
                else => null,
            };
        },
        .Path => |p| {
            if (p.segments.len != 1) return null;
            const list = module.registry.top_level_prop_pkgs.get(p.segments[0].name) orelse return null;
            var head: ?[]const u8 = null;
            for (list.items) |pd| {
                const h = module.registry.top_level_prop_type_heads.get(pd.fqn) orelse return null;
                if (head) |prev| {
                    if (!std.mem.eql(u8, prev, h)) return null;
                } else head = h;
            }
            return head;
        },
        else => return null,
    }
}

pub fn literalTypeHead(e: *const ast.Expr) ?[]const u8 {
    return switch (e.*) {
        .IntLit => |lit| switch (lit.kind) {
            .Int => if (lit.value >= std.math.minInt(i32) and lit.value <= std.math.maxInt(i32)) "Int" else "Long",
            .Long => "Long",
            .UInt => "UInt",
            .ULong => "ULong",
        },
        .FloatLit => |lit| if (lit.kind == .Float) "Float" else "Double",
        .BoolLit => "Boolean",
        .CharLit => "Char",
        .StringTemplate => "String",
        else => null,
    };
}

/// The simple name an unannotated property initializer CALLS, seeing through
/// the scope functions that return their own receiver
/// (`IntArray(256).apply { … }` is an `IntArray`).
pub fn initCalleeName(e: *const ast.Expr) ?[]const u8 {
    if (e.* != .Call) return null;
    const callee = e.Call.callee;
    switch (callee.*) {
        .Path => |p| {
            if (p.segments.len == 0) return null;
            return p.segments[p.segments.len - 1].name;
        },
        .Member => |m| {
            const identity = [_][]const u8{ "apply", "also" };
            for (identity) |id| {
                if (std.mem.eql(u8, m.name.name, id)) return initCalleeName(m.receiver);
            }
            return null;
        },
        else => return null,
    }
}

pub fn constLiteralOf(e: *const ast.Expr) ?ir.Const {
    switch (e.*) {
        .IntLit => |il| {
            switch (il.kind) {
                .Int => {
                    const v = std.math.cast(i32, il.value) orelse return null;
                    return .{ .Int = v };
                },
                .Long => return .{ .Long = il.value },
                .UInt => {
                    const wide: u64 = @bitCast(il.value);
                    const v = std.math.cast(u32, wide) orelse return null;
                    return .{ .UInt = v };
                },
                .ULong => return .{ .ULong = @bitCast(il.value) },
            }
        },
        .FloatLit => |fl| {
            return switch (fl.kind) {
                .Double => .{ .Double = fl.value },
                .Float => .{ .Float = @floatCast(fl.value) },
            };
        },
        .BoolLit => |bl| return .{ .Bool = bl.value },
        .CharLit => |cl| return .{ .Char = cl.value },
        .StringTemplate => |st| {
            if (st.parts.len == 0) return .{ .String = "" };
            if (st.parts.len == 1 and st.parts[0] == .Text) return .{ .String = st.parts[0].Text };
            return null;
        },
        .Unary => |u| {
            if (u.op != .Neg) return null;
            const inner = constLiteralOf(u.expr) orelse return null;
            return switch (inner) {
                .Int => |v| .{ .Int = -%v },
                .Long => |v| .{ .Long = -%v },
                .Double => |v| .{ .Double = -v },
                .Float => |v| .{ .Float = -v },
                else => null,
            };
        },
        else => return null,
    }
}

/// The classifier path of an owner fqn without its package: the leading
/// lowercase-initial dotted segments are the package by Kotlin convention
/// (`androidx.compose.runtime.PersistentCompositionLocalMap` ->
/// `PersistentCompositionLocalMap`, `kotlin.time.Duration.Companion` ->
/// `Duration.Companion`). Null when stripping changes nothing.
pub fn ownerSimplePath(owner: []const u8) ?[]const u8 {
    var rest = owner;
    while (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
        const seg = rest[0..dot];
        if (seg.len == 0 or !std.ascii.isLower(seg[0])) break;
        rest = rest[dot + 1 ..];
    }
    if (rest.len == owner.len or rest.len == 0) return null;
    return rest;
}

pub fn declPackage(a: Allocator, decl_pkg: *const SpanStrMap, overrides: *const SpanStrMap, decl_span: Span, package_prefix: []const u8, simple: []const u8) Allocator.Error![]const u8 {
    if (decl_pkg.get(decl_span)) |p| return p;
    const fqn = try resolveFqn(a, overrides, decl_span, package_prefix, simple);
    return packageOfFqn(fqn, simple);
}

/// Resolve a declaration's FQN: the per-span override if present, else
/// the package-qualified name, else the bare simple name.
pub fn resolveFqn(allocator: Allocator, overrides: *const SpanStrMap, decl_span: Span, package_prefix: []const u8, simple: []const u8) Allocator.Error![]const u8 {
    if (overrides.get(decl_span)) |f| return f;
    if (package_prefix.len == 0) return simple;
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ package_prefix, simple });
}

pub const packageOfFqn = ir.packageOfFqn;

// -------------------------------------------------------------------------
// AST-walk helpers (member-name collection across the class hierarchy).
// -------------------------------------------------------------------------

/// Record every member name a class/object declares — functions,
/// properties, primary-ctor properties — recursing into nested classes
/// and objects (companions included) so the flat program-wide
/// member-name universe is complete.
pub fn collectClassMemberNamesInto(out: *StringSet, primary_params: []const ast.ClassParam, members: []const ast.Decl) Allocator.Error!void {
    for (primary_params) |*p| {
        if (p.property != null) try out.put(p.name.name, {});
    }
    for (members) |*m| {
        switch (m.*) {
            .Function => |*f| try out.put(f.name.name, {}),
            .Property => |p| try out.put(p.name.name, {}),
            .Class => |*c| try collectClassMemberNamesInto(out, c.primary_params, c.members),
            .Object => |*o| try collectClassMemberNamesInto(out, &.{}, o.members),
            else => {},
        }
    }
}

pub fn collectHierarchyMethodNames(start: []const u8, by_name: *const FileClasses, out: *StringSet, seen: *StringSet) Allocator.Error!void {
    const gop = try seen.getOrPut(start);
    if (gop.found_existing) return;
    const c = (by_name.get(start) orelse return).get();
    for (c.members) |*m| {
        if (m.* == .Function) try out.put(m.Function.name.name, {});
    }
    for (c.supertypes) |*st| try collectHierarchyMethodNames(st.name.name, by_name, out, seen);
}

pub fn memberTrailingLambdaShape(module: *const ir.Module, f: *const ast.Function) ?ir.ModuleRegistry.MemberTrailingLambdaShape {
    if (f.params.len == 0) return null;
    const last_ty = f.params[f.params.len - 1].ty;
    const value_arity: i16 = if (last_ty.function) |ft|
        @intCast(@min(ft.params.len + ft.context_params.len, std.math.maxInt(i16)))
    else blk: {
        const tag = module.registry.type_aliases.get(last_ty.name.name) orelse return null;
        if (!std.mem.startsWith(u8, tag, "Function")) return null;
        break :blk std.fmt.parseInt(i16, tag["Function".len..], 10) catch return null;
    };
    const receiver_head: ?[]const u8 = if (last_ty.function) |ft|
        if (ft.receiver) |rt| rt.name.name else null
    else
        null;

    var accepted: u64 = 0;
    var nargs: usize = 1;
    while (nargs <= f.params.len and nargs < 63) : (nargs += 1) {
        const leading = nargs - 1;
        var fits = true;
        for (f.params[leading .. f.params.len - 1]) |*p| {
            if (p.default == null and !p.is_vararg) {
                fits = false;
                break;
            }
        }
        if (fits) accepted |= @as(u64, 1) << @intCast(nargs);
    }
    if (accepted == 0) return null;
    return .{
        .accepted_arities = accepted,
        .value_arity = value_arity,
        .receiver_head = receiver_head,
    };
}

pub fn collectMemberTrailingLambdaShapes(module: *ir.Module, by_name: *const FileClasses) Allocator.Error!void {
    const a = module.registry.allocator;
    var it = by_name.iterator();
    while (it.next()) |entry| {
        const cls = entry.key_ptr.*;
        const c = entry.value_ptr.get();
        for (c.members) |*member| {
            if (member.* != .Function) continue;
            const f = &member.Function;
            const shape = memberTrailingLambdaShape(module, f) orelse continue;
            const key = ir.StrPair{ .a = cls, .b = f.name.name };
            const gop = try module.registry.member_trailing_lambda_shapes.getOrPut(key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            var duplicate = false;
            for (gop.value_ptr.items) |old| {
                const same_recv = if (old.receiver_head == null or shape.receiver_head == null)
                    old.receiver_head == null and shape.receiver_head == null
                else
                    std.mem.eql(u8, old.receiver_head.?, shape.receiver_head.?);
                if (old.accepted_arities == shape.accepted_arities and
                    old.value_arity == shape.value_arity and same_recv)
                {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) try gop.value_ptr.append(a, shape);
        }
    }
}

/// Transitive member-NAME set for the member-shadow gate: every kind a bare
/// name could bind through the implicit receiver (functions, properties,
/// primary-ctor `val`/`var` params, nested-object/companion members), walked
/// through the supertype chain. Returns false when any supertype in the
/// chain is not resolvable from this build's class set — the set is then
/// INCOMPLETE and must not be used to prove non-shadowability.
pub fn collectHierarchyShadowNames(start: []const u8, by_name: *const FileClasses, out: *StringSet, seen: *StringSet) Allocator.Error!bool {
    const gop = try seen.getOrPut(start);
    if (gop.found_existing) return true;
    const ref = by_name.get(start) orelse return false;
    const c = ref.get();
    try collectClassMemberNamesInto(out, c.primary_params, c.members);
    var complete = true;
    for (c.supertypes) |*st| {
        if (!try collectHierarchyShadowNames(st.name.name, by_name, out, seen)) complete = false;
    }
    return complete;
}

/// Collect a class's transitive supertype simple names, nearest first:
/// each direct supertype, then that supertype's own chain. A supertype
/// whose declaration is not in `by_name` (a pack-internal or built-in
/// base) still records its name — its own ancestors are simply
/// unknowable from here.
/// The declared head of a class property's type, substituting a class
/// type-parameter name with its upper bound's head. Null when nothing
/// static is known (no bound, unresolvable).
/// The single expression a property's static head may be inferred from: its
/// initializer, or — for an accessor-only property — the getter's
/// single-expression body.
pub fn propHeadSourceExpr(prop: *const ast.Property) ?*const ast.Expr {
    if (prop.init) |*init| return init;
    if (prop.getter) |g| {
        if (g.body == .Expr) return &g.body.Expr;
    }
    return null;
}

/// Constructor-call head evidence for a property with no declared type: the
/// initializer (or single-expression getter) constructs a class declared in
/// this file set (`val Traversable get() = NodeKind<T>(mask)` -> `NodeKind`).
/// Only a name that IS a declared class counts — a same-shaped factory call
/// may return a different type, so an unknown callee proves nothing.
pub fn propCtorHeadEvidence(prop: *const ast.Property, decls: []const ast.Decl, module: *const ir.Module, enclosing: ?*const ast.Class) ?[]const u8 {
    const src = propHeadSourceExpr(prop) orelse return null;
    if (src.* != .Call) return null;
    const callee = src.Call.callee;
    if (callee.* != .Path or callee.Path.segments.len != 1) return null;
    const nm = callee.Path.segments[0].name;
    if (nm.len == 0) return null;
    if (std.c.getenv("KLIO_PROPHEAD_TRACE") != null)
        std.debug.print("[prophead] {s} init-callee={s} class={} funcs={d}\n", .{ prop.name.name, nm, module.classId(nm) != null, module.funcsBySimpleName(nm).len });
    if (std.ascii.isUpper(nm[0])) {
        for (decls) |*d| {
            if (d.* == .Class and std.mem.eql(u8, d.Class.name.name, nm)) return nm;
        }
        // A class registered elsewhere (a pack's `Json { }` builder names
        // its type exactly as its constructor would).
        if (module.classId(nm) != null) return nm;
        // A NESTED class of the enclosing class named exactly as its
        // constructor (`val expected = MF(...)` where `MF` is nested in the
        // property's own class): report the simple head; the reader qualifies
        // it through the enclosing scope (`Outer$MF`).
        if (enclosing) |ec| {
            for (ec.members) |*m| {
                if (m.* == .Class and std.mem.eql(u8, m.Class.name.name, nm)) return nm;
            }
        }
        return null;
    }
    // A FACTORY call names its type just as a constructor does, as long as
    // exactly one declaration answers to the name and it declares a return
    // type: `val cache = newCache()` is whatever `newCache` returns.
    if (std.mem.eql(u8, runtime.envOnce("KLIO_FACTORY_PROP") orelse "1", "0")) return null;
    var found: ?[]const u8 = null;
    for (decls) |*d| {
        if (d.* != .Function) continue;
        if (!std.mem.eql(u8, d.Function.name.name, nm)) continue;
        if (found != null) return null;
        const rt = d.Function.return_type orelse return null;
        if (rt.nullable or rt.function != null or rt.qualified_path != null) return null;
        found = rt.name.name;
    }
    if (found != null) return found;
    // A registered top-level function (a pack factory): every same-named
    // plain function must agree on a declared, concrete return head.
    var agreed: ?[]const u8 = null;
    for (module.funcsBySimpleName(nm)) |fid| {
        const f = module.funcById(fid) orelse continue;
        if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) continue;
        var head = std.mem.trimEnd(u8, f.return_ty.name, "?");
        if (std.mem.indexOfScalar(u8, head, '<')) |lt| head = head[0..lt];
        if (head.len == 0 or std.mem.eql(u8, head, "Unit") or (head.len <= 2 and std.ascii.isUpper(head[0]))) return null;
        if (agreed) |g| {
            if (!std.mem.eql(u8, g, head)) return null;
        } else agreed = head;
    }
    return agreed;
}

/// The materialized array head a `vararg` property has (mirrors the body-side
/// mapping in ir/lower/decl.zig): a primitive-specialized array for primitive
/// elements, `Array` otherwise (including generic elements).
pub fn varargPropArrayHead(elem: []const u8) []const u8 {
    const eq = std.mem.eql;
    if (eq(u8, elem, "Byte")) return "ByteArray";
    if (eq(u8, elem, "Short")) return "ShortArray";
    if (eq(u8, elem, "Int")) return "IntArray";
    if (eq(u8, elem, "Long")) return "LongArray";
    if (eq(u8, elem, "Char")) return "CharArray";
    if (eq(u8, elem, "Boolean")) return "BooleanArray";
    if (eq(u8, elem, "Float")) return "FloatArray";
    if (eq(u8, elem, "Double")) return "DoubleArray";
    if (eq(u8, elem, "UByte")) return "UByteArray";
    if (eq(u8, elem, "UShort")) return "UShortArray";
    if (eq(u8, elem, "UInt")) return "UIntArray";
    if (eq(u8, elem, "ULong")) return "ULongArray";
    return "Array";
}

/// Record a class property's FULL declared type beside its head. Only a
/// type with ARGUMENTS is worth storing — a head-only entry already answers
/// through `class_prop_type_heads`, and the argument list is the whole point
/// (`val items: List<Named>` says what iterating or indexing it yields).
/// A type ARGUMENT that is one of the class's own parameters is KEPT: the
/// read site substitutes it from the receiver's own arguments
/// (`Map<K, V>.values: Collection<V>` on a `Map<String, Named>` receiver is
/// a `Collection<Named>`). Where the receiver carries no arguments the
/// substitution declines and the head-only answer stands.
/// Records a class property's declared type head under the class's simple
/// name and, when it differs, under its qualified name too. A reader that
/// resolved the owner through file scope then gets the exact class when two
/// packages share a simple name: `graphics.Shadow.offset` is an `Offset`
/// while `graphics.shadow.Shadow.offset` is a `DpOffset`, and the simple
/// key can only hold one of them.
/// A declaration's qualified name in a merged multi-file build: the
/// recorded override for its declaration span, else its own file's package
/// (the primary file's prefix covers only that file's declarations).
pub fn declFqnAt(a: Allocator, module: *const Module, overrides: *const SpanStrMap, decl_span: Span, package_prefix: []const u8, simple: []const u8) Allocator.Error![]const u8 {
    if (overrides.get(decl_span)) |f| return f;
    const prefix = if (package_prefix.len != 0) package_prefix else (module.packageOfFile(decl_span.file) orelse "");
    if (prefix.len == 0) return simple;
    return std.fmt.allocPrint(a, "{s}.{s}", .{ prefix, simple });
}

pub fn putClassPropHead(module: *Module, simple: []const u8, fqn: []const u8, prop: []const u8, head: []const u8) Allocator.Error!void {
    try module.registry.class_prop_type_heads.put(.{ .a = simple, .b = prop }, head);
    if (!std.mem.eql(u8, fqn, simple)) {
        try module.registry.class_prop_type_heads.put(.{ .a = fqn, .b = prop }, head);
    }
}

pub fn notePropTypeRef(
    a: Allocator,
    module: *Module,
    c: *const ast.Class,
    prop_name: []const u8,
    ty: *const ast.TypeRef,
) Allocator.Error!void {
    if (ty.function != null or ty.type_args.len == 0) return;
    for (ty.type_args) |*ta| {
        if (ta.is_star) return;
    }
    const lowered = try ir.lower.decl.loweredTypeRef(a, ty, true);
    try module.registry.class_prop_type_refs.put(.{ .a = c.name.name, .b = prop_name }, lowered);
}

pub fn classPropHead(c: *const ast.Class, ty: *const ast.TypeRef) ?[]const u8 {
    // A type written qualified (`BytesHexFormat.Builder`) keeps its dotted
    // path: `name` alone is the last segment, and recording just `Builder`
    // made the receiver typing bind a same-named class from an enclosing
    // scope. A qualified reference is never a type parameter.
    if (ty.qualified_path) |qp| return qp;
    const head = ty.name.name;
    for (c.type_params) |*tp| {
        // An UNBOUNDED class type parameter is still the property's type,
        // and the bound record carries the `Any?` Kotlin gives it — so the
        // head resolves through the bound rather than naming nothing.
        // Dropping it left every `CompareContext<out T>.actual`-shaped
        // receiver untyped inside a body that is lowered once.
        if (std.mem.eql(u8, tp.name.name, head)) return tp.name.name;
    }
    return head;
}

pub fn collectHierarchySuperNames(a: Allocator, c: *const ast.Class, by_name: *const FileClasses, out: *std.ArrayList([]const u8), seen: *StringSet) Allocator.Error!void {
    for (c.supertypes) |*st| {
        const nm = st.name.name;
        const gop = try seen.getOrPut(nm);
        if (gop.found_existing) continue;
        try out.append(a, nm);
        if (by_name.get(nm)) |parent| {
            try collectHierarchySuperNames(a, parent.get(), by_name, out, seen);
        }
    }
}

pub fn collectHierarchyMemberNames(start: []const u8, by_name: *const FileClasses, out: *StringSet, seen: *StringSet) Allocator.Error!void {
    const gop = try seen.getOrPut(start);
    if (gop.found_existing) return;
    const c = (by_name.get(start) orelse return).get();
    for (c.primary_params) |*p| {
        if (p.property != null) try out.put(p.name.name, {});
    }
    for (c.members) |*m| {
        switch (m.*) {
            .Function => |*f| try out.put(f.name.name, {}),
            .Property => |p| try out.put(p.name.name, {}),
            else => {},
        }
    }
    for (c.supertypes) |*st| try collectHierarchyMemberNames(st.name.name, by_name, out, seen);
}

/// Collect the companion-object member names declared by `start` and each of
/// its supertypes. A subclass sees an inherited companion's members under their
/// bare names (Kotlin: `MinId` inside `Rgb` binds `ColorSpace.Companion.MinId`);
/// a secondary-constructor delegation/default thunk has no `this` to walk at
/// runtime, so those names must be in its static member set to resolve as a
/// companion access rather than an unbound global.
pub fn collectHierarchyCompanionMemberNames(start: []const u8, by_name: *const FileClasses, out: *StringSet, seen: *StringSet) Allocator.Error!void {
    const gop = try seen.getOrPut(start);
    if (gop.found_existing) return;
    const c = (by_name.get(start) orelse return).get();
    for (c.members) |*m| {
        if (m.* == .Class and m.Class.is_companion) {
            const comp = &m.Class;
            for (comp.members) |*cm| {
                switch (cm.*) {
                    .Function => |*f| try out.put(f.name.name, {}),
                    .Property => |p| try out.put(p.name.name, {}),
                    else => {},
                }
            }
            for (comp.primary_params) |*p| {
                if (p.property != null) try out.put(p.name.name, {});
            }
        }
    }
    for (c.supertypes) |*st| try collectHierarchyCompanionMemberNames(st.name.name, by_name, out, seen);
}

/// Int literals narrow to i32 and Double literals narrow to f32, matching
/// Kotlin's Int/Float literal types.
pub fn literalToConst(e: *const ast.Expr) ?Const {
    return switch (e.*) {
        .IntLit => |lit| switch (lit.kind) {
            // A suffix-less integer literal whose magnitude exceeds the `Int`
            // range is a `Long` in Kotlin; mirror the IntLit-lowering widening
            // in `ir/lower/expr.zig` so `const val` folding does not truncate.
            .Int => if (lit.value >= std.math.minInt(i32) and lit.value <= std.math.maxInt(i32))
                Const{ .Int = @truncate(lit.value) }
            else
                Const{ .Long = lit.value },
            // Unsigned literals keep their unsigned Const type, matching
            // `constLiteralOf`; folding them to Int/Long made a `const val`
            // materialise its global as the signed type, so a member call
            // whose receiver read that global (`twoVal.plus(oneVal)`) hit a
            // mixed Int/UInt BinOp.
            .UInt => blk: {
                const wide: u64 = @bitCast(lit.value);
                break :blk if (std.math.cast(u32, wide)) |v| Const{ .UInt = v } else null;
            },
            .Long => Const{ .Long = lit.value },
            .ULong => Const{ .ULong = @bitCast(lit.value) },
        },
        .FloatLit => |lit| switch (lit.kind) {
            .Double => Const{ .Double = lit.value },
            .Float => Const{ .Float = @floatCast(lit.value) },
        },
        .BoolLit => |lit| Const{ .Bool = lit.value },
        .CharLit => |lit| Const{ .Char = lit.value },
        .StringTemplate => |st| if (st.parts.len == 1 and st.parts[0] == .Text)
            Const{ .String = st.parts[0].Text }
        else
            null,
        else => null,
    };
}

/// Default `Value` for a non-nullable primitive property with no
/// initializer — so such a field starts as `0`/`false` instead of `Null`.
/// Whether the property's type is a non-nullable scalar: an annotation says so
/// directly, and an inferred type is read off a primitive literal initializer.
/// A custom getter can return anything, and a delegate/lateinit has no plain
/// stored field, so neither qualifies.
pub fn scalarNonNullProp(p: *const ast.Property) bool {
    if (p.is_abstract or p.is_lateinit or p.delegate != null or p.getter != null) return false;
    if (p.ty) |ty| {
        if (ty.nullable) return false;
        const n = ty.name.name;
        const names = [_][]const u8{ "Int", "Long", "Double", "Float", "Boolean", "Byte", "Short", "Char" };
        for (names) |s2| if (std.mem.eql(u8, n, s2)) return true;
        return false;
    }
    const init = p.init orelse return false;
    return switch (init) {
        .IntLit, .BoolLit, .FloatLit, .CharLit => true,
        else => false,
    };
}

/// The value a property's stored field holds BEFORE its initializer runs.
///
/// A non-nullable scalar reads as its type's zero, exactly as it does on the
/// JVM — a superclass `init` that calls an overridden method sees `0`, not an
/// uninitialized slot. klio previously left such a field Null until the
/// initializer ran (only an UNINITIALIZED declaration got a zero), so that
/// program failed with "get_field `n` on `B`" instead of printing 0. It is also
/// what lets the JIT prove a scalar field read non-null: the slot never holds
/// Null at any point in the object's life.
pub fn primitiveZeroFor(p: *const ast.Property) ?Value {
    if (p.is_abstract or p.is_lateinit or p.getter != null or p.delegate != null) return null;
    if (p.ty) |ty| {
        if (ty.nullable) return null;
        return zeroForScalarName(ty.name.name);
    }
    // Inferred: a primitive literal initializer names the type exactly.
    const init = p.init orelse return null;
    return switch (init) {
        .IntLit => Value{ .Int = 0 },
        .BoolLit => Value{ .Bool = false },
        .FloatLit => Value{ .Double = 0.0 },
        .CharLit => Value{ .Char = 0 },
        else => null,
    };
}

pub fn zeroForScalarName(n: []const u8) ?Value {
    if (std.mem.eql(u8, n, "Int")) return Value{ .Int = 0 };
    if (std.mem.eql(u8, n, "Long")) return Value{ .Long = 0 };
    if (std.mem.eql(u8, n, "Short")) return Value{ .Short = 0 };
    if (std.mem.eql(u8, n, "Byte")) return Value{ .Byte = 0 };
    if (std.mem.eql(u8, n, "Float")) return Value{ .Float = 0.0 };
    if (std.mem.eql(u8, n, "Double")) return Value{ .Double = 0.0 };
    if (std.mem.eql(u8, n, "Boolean")) return Value{ .Bool = false };
    if (std.mem.eql(u8, n, "Char")) return Value{ .Char = 0 };
    return null;
}
