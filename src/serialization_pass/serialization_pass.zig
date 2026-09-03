//! kotlinx-serialization compiler-plugin replacement.
//!
//! For every `@Serializable` declaration the plugin would process, this pass
//! synthesizes the artifacts the plugin generates — as ORDINARY KOTLIN
//! DECLARATIONS produced from generated source text and parsed with the
//! real parser — before anything downstream reads the decls. Everything
//! after this point (resolution, static dispatch, bytecode, leaves, the C
//! transpiler) therefore sees plain Kotlin, exactly as it does for the
//! Compose lowering plugin.
//!
//! Layout of the generated code, per original source file that declares
//! serializable classes:
//!
//! - A SYNTHETIC SIBLING FILE (same package, its own star imports of the
//!   kotlinx.serialization surface) carrying the heavy artifacts as
//!   top-level declarations: `object <Name>$serializer :
//!   GeneratedSerializer<Name>` (descriptor / serialize / deserialize /
//!   childSerializers), the generic `class <Name>$serializer<T>(typeSerial0)`
//!   form, and `fun <Name>$serializerImpl()` factories for the enum /
//!   object / sealed / polymorphic / `with=` forms.
//! - A small splice INTO the class itself: `companion object { fun
//!   serializer() = <Name>$serializer }` (merged into an existing
//!   companion), or `fun serializer()` on an `object`. That member is what
//!   upstream (`Companion.serializer()`, `compiledSerializerImpl`) reaches.
//!
//! Generated text can be dumped with `KLIO_SERIAL_DUMP=1`.

const std = @import("std");
const ast = @import("ast");
const span_mod = @import("span");
const lexer_mod = @import("lexer");
const parser_mod = @import("parser");

const Allocator = std.mem.Allocator;
const Span = span_mod.Span;
const FileId = span_mod.FileId;

fn wp(list: *std.ArrayList(u8), a: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const txt = try std.fmt.allocPrint(a, fmt, args);
    try list.appendSlice(a, txt);
}

// ---------------------------------------------------------------------------
// Serializable-declaration index (across all files)
// ---------------------------------------------------------------------------

const Kind = enum { class, object, enum_class, sealed, polymorphic, value_class, with_custom, interface_sealed };

const Info = struct {
    /// Simple name.
    name: []const u8,
    /// Dotted classifier path from the file's top level (`Outer.Inner`).
    path: []const u8,
    /// Package of the declaring file ("" for none).
    pkg: []const u8,
    kind: Kind,
    type_params: usize,
    /// `@Serializable(with = X::class)` target simple name (or dotted path).
    with: ?[]const u8 = null,
    /// `@SerialName("...")` override of the serial name.
    serial_name: ?[]const u8 = null,
    is_object_decl: bool = false,
    /// Suffix of the generated top-level artifact (`$serializer`; the
    /// `@KeepGeneratedSerializer` twin uses `$generatedSerializer`).
    gen_suffix: []const u8 = "$serializer",
};

const SealedSub = struct { path: []const u8 };
const SubRecord = struct { sub_path: []const u8, sup_head: []const u8, scope: []const u8 };

const Index = struct {
    a: Allocator,
    by_name: std.StringHashMap(Info),
    /// Every serializable declaration by its full nested path.
    by_path: std.StringHashMap(Info),
    /// Every class/object declaration path (serializable or not), for
    /// scope-aware qualification of type references.
    all_paths: std.StringHashMap(void),
    /// Sealed parent PATH -> ordered subclass paths (resolved after indexing).
    sealed_subs: std.StringHashMap(std.ArrayList(SealedSub)),
    /// Raw (subclass, supertype head, scope) records collected while indexing.
    sub_records: std.ArrayList(SubRecord),
    /// Every `object` declaration path (for `with = X::class` object-vs-class).
    objects: std.StringHashMap(void),
    /// Top-level `const val NAME = "literal"` values, so an annotation
    /// argument spelled as a template (`@SerialName("$prefix.Derived")`)
    /// folds to the compile-time string kotlinc sees.
    const_strings: std.StringHashMap([]const u8),
    /// Annotation classes annotated `@MetaSerializable`: a class annotated
    /// with one of these is serializable as if `@Serializable`.
    meta_serializable: std.StringHashMap(void),
    /// Annotation classes the descriptor carries: `@SerialInfo`,
    /// `@InheritableSerialInfo` and `@MetaSerializable` declarations.
    serial_info: std.StringHashMap(void),
    /// Annotation classes annotated `@InheritableSerialInfo`: pushed into
    /// the class annotations of every subclass descriptor.
    inheritable: std.StringHashMap(void),
    /// Declared supertypes (simple heads) per class path, for inheritance walks.
    supers: std.StringHashMap([]const []const u8),
    /// Class annotations (source text of each `@Foo(...)`) per class path.
    class_annotations: std.StringHashMap([]const []const u8),
    /// The declaring AST node per class path (for `@Serializer(forClass)`).
    class_nodes: std.StringHashMap(*const ast.Class),
    /// Declared supertypes (full TypeRefs) per class/object path, for
    /// `object X : KSerializer<T>` target resolution.
    super_refs: std.StringHashMap([]const ast.TypeRef),

    fn init(a: Allocator) Index {
        return .{
            .a = a,
            .by_name = std.StringHashMap(Info).init(a),
            .by_path = std.StringHashMap(Info).init(a),
            .all_paths = std.StringHashMap(void).init(a),
            .const_strings = std.StringHashMap([]const u8).init(a),
            .sealed_subs = std.StringHashMap(std.ArrayList(SealedSub)).init(a),
            .sub_records = .empty,
            .objects = std.StringHashMap(void).init(a),
            .meta_serializable = std.StringHashMap(void).init(a),
            .serial_info = std.StringHashMap(void).init(a),
            .inheritable = std.StringHashMap(void).init(a),
            .supers = std.StringHashMap([]const []const u8).init(a),
            .class_annotations = std.StringHashMap([]const []const u8).init(a),
            .class_nodes = std.StringHashMap(*const ast.Class).init(a),
            .super_refs = std.StringHashMap([]const ast.TypeRef).init(a),
        };
    }
};

fn annotationSimpleName(an: *const ast.Annotation) []const u8 {
    if (an.path.len == 0) return "";
    return an.path[an.path.len - 1].name;
}

fn hasAnnotation(annotations: []const ast.Annotation, name: []const u8) bool {
    for (annotations) |*an| {
        if (std.mem.eql(u8, annotationSimpleName(an), name)) return true;
    }
    return false;
}

fn findAnnotation(annotations: []const ast.Annotation, name: []const u8) ?*const ast.Annotation {
    for (annotations) |*an| {
        if (std.mem.eql(u8, annotationSimpleName(an), name)) return an;
    }
    return null;
}

/// The literal string of a single-string-argument annotation (`@SerialName("x")`).
fn annotationStringArg(an: *const ast.Annotation) ?[]const u8 {
    if (an.args.len == 0) return null;
    return exprStringLiteral(&an.args[0]);
}

threadlocal var active_index: ?*const Index = null;

fn exprStringLiteral(e: *const ast.Expr) ?[]const u8 {
    switch (e.*) {
        .StringTemplate => |st| {
            if (st.parts.len == 0) return "";
            if (st.parts.len == 1 and st.parts[0] == .Text) return st.parts[0].Text;
            // A template over `const val` strings is a compile-time constant.
            const idx = active_index orelse return null;
            var out: std.ArrayList(u8) = .empty;
            for (st.parts) |part| {
                switch (part) {
                    .Text => |t| out.appendSlice(idx.a, t) catch return null,
                    .ShortInterp => |id| {
                        const v = idx.const_strings.get(id.name) orelse return null;
                        out.appendSlice(idx.a, v) catch return null;
                    },
                    .Interp => return null,
                }
            }
            return out.toOwnedSlice(idx.a) catch null;
        },
        else => return null,
    }
}

/// `X::class` / `a.b.X::class` -> "X" / "a.b.X".
fn exprClassRef(a: Allocator, e: *const ast.Expr) ?[]const u8 {
    switch (e.*) {
        .MemberRef => |mr| {
            if (!std.mem.eql(u8, mr.name.name, "class")) return null;
            return exprPathText(a, mr.receiver);
        },
        else => return null,
    }
}

fn exprPathText(a: Allocator, e: *const ast.Expr) ?[]const u8 {
    switch (e.*) {
        .Path => |p| {
            var out: std.ArrayList(u8) = .empty;
            for (p.segments, 0..) |seg, i| {
                if (i > 0) out.append(a, '.') catch return null;
                out.appendSlice(a, seg.name) catch return null;
            }
            return out.toOwnedSlice(a) catch null;
        },
        .Member => |m| {
            const base = exprPathText(a, m.receiver) orelse return null;
            return std.fmt.allocPrint(a, "{s}.{s}", .{ base, m.name.name }) catch null;
        },
        else => return null,
    }
}

/// `@Serializable(with = X::class)` target, if any.
fn serializableWith(a: Allocator, annotations: []const ast.Annotation) ?[]const u8 {
    const an = findAnnotation(annotations, "Serializable") orelse return null;
    for (an.args, 0..) |*arg, i| {
        const named: ?[]const u8 = if (i < an.arg_names.len) an.arg_names[i] else null;
        if (named) |n| {
            if (!std.mem.eql(u8, n, "with")) continue;
        }
        if (exprClassRef(a, arg)) |c| return c;
    }
    return null;
}

/// The index-independent form (pre-pass): only the literal annotation.
fn isSerializableLiteral(annotations: []const ast.Annotation) bool {
    return hasAnnotation(annotations, "Serializable");
}

/// `@Serializable`, or an annotation whose class is `@MetaSerializable`.
fn isSerializableIn(idx: *const Index, annotations: []const ast.Annotation) bool {
    if (hasAnnotation(annotations, "Serializable")) return true;
    for (annotations) |*an| {
        if (idx.meta_serializable.contains(annotationSimpleName(an))) return true;
    }
    return false;
}

/// Source text of a class/property annotation as a constructor call
/// (`@Foo(1)` -> `Foo(1)`, `@Bare` -> `Bare()`), or null when unreadable.
fn annotationCallText(a: Allocator, an: *const ast.Annotation) ?[]const u8 {
    const txt = sourceOf(an.span) orelse return null;
    const body = if (txt.len > 0 and txt[0] == '@') txt[1..] else txt;
    if (std.mem.indexOfScalar(u8, body, '(') == null) return std.fmt.allocPrint(a, "{s}()", .{body}) catch null;
    return body;
}

/// Whether an annotation reaches the serial descriptor: only a
/// `@SerialInfo`-marked annotation class does (the plugin's rule), so a
/// stdlib marker such as `@ExperimentalUnsignedTypes` never becomes a
/// runtime construction.
fn isSerialInfoAnnotation(idx: *const Index, n: []const u8) bool {
    if (idx.serial_info.contains(n)) return true;
    const eq = std.mem.eql;
    return eq(u8, n, "JsonNames") or eq(u8, n, "JsonClassDiscriminator") or eq(u8, n, "JsonIgnoreUnknownKeys") or
        eq(u8, n, "ProtoNumber") or eq(u8, n, "ProtoType") or eq(u8, n, "ProtoPacked") or eq(u8, n, "ProtoOneOf") or
        eq(u8, n, "CborLabel") or eq(u8, n, "ByteString") or eq(u8, n, "XmlElement");
}

fn isFrameworkAnnotation(n: []const u8) bool {
    const eq = std.mem.eql;
    return eq(u8, n, "Serializable") or eq(u8, n, "SerialName") or eq(u8, n, "Transient") or eq(u8, n, "Required") or
        eq(u8, n, "EncodeDefault") or eq(u8, n, "Contextual") or eq(u8, n, "Polymorphic") or eq(u8, n, "OptIn") or
        eq(u8, n, "Suppress") or eq(u8, n, "JvmInline") or eq(u8, n, "Deprecated") or eq(u8, n, "JvmField") or
        eq(u8, n, "JvmStatic") or eq(u8, n, "Keep") or eq(u8, n, "KeepGeneratedSerializer") or eq(u8, n, "UseSerializers") or
        eq(u8, n, "UseContextualSerialization") or eq(u8, n, "ExperimentalSerializationApi") or eq(u8, n, "InternalSerializationApi");
}

fn packageText(a: Allocator, f: *const ast.KotlinFile) []const u8 {
    const ph = f.package orelse return "";
    var out: std.ArrayList(u8) = .empty;
    for (ph.path, 0..) |seg, i| {
        if (i > 0) out.append(a, '.') catch return "";
        out.appendSlice(a, seg.name) catch return "";
    }
    return out.toOwnedSlice(a) catch "";
}

fn joinPath(a: Allocator, outer: []const u8, name: []const u8) []const u8 {
    if (outer.len == 0) return name;
    return std.fmt.allocPrint(a, "{s}.{s}", .{ outer, name }) catch name;
}

fn simpleHead(name: []const u8) []const u8 {
    var h = name;
    if (std.mem.lastIndexOfScalar(u8, h, '.')) |d| h = h[d + 1 ..];
    return h;
}

/// Pre-pass: annotation classes and their meta-annotations.
fn indexAnnotationClasses(idx: *Index, decls: []const ast.Decl) Allocator.Error!void {
    for (decls) |*d| {
        switch (d.*) {
            .Class => |*c| {
                if (c.is_annotation) {
                    if (hasAnnotation(c.annotations, "MetaSerializable")) try idx.meta_serializable.put(c.name.name, {});
                    if (hasAnnotation(c.annotations, "InheritableSerialInfo")) try idx.inheritable.put(c.name.name, {});
                    if (hasAnnotation(c.annotations, "SerialInfo") or hasAnnotation(c.annotations, "InheritableSerialInfo") or
                        hasAnnotation(c.annotations, "MetaSerializable")) try idx.serial_info.put(c.name.name, {});
                }
                try indexAnnotationClasses(idx, c.members);
            },
            .Object => |*o| try indexAnnotationClasses(idx, o.members),
            else => {},
        }
    }
}

fn recordSupersAndAnnotations(idx: *Index, path: []const u8, supertypes: []const ast.TypeRef, annotations: []const ast.Annotation) Allocator.Error!void {
    try idx.super_refs.put(path, supertypes);
    var sup: std.ArrayList([]const u8) = .empty;
    for (supertypes) |*st| try sup.append(idx.a, simpleHead(st.name.name));
    try idx.supers.put(path, try sup.toOwnedSlice(idx.a));
    var anns: std.ArrayList([]const u8) = .empty;
    for (annotations) |*an| {
        if (isFrameworkAnnotation(annotationSimpleName(an))) continue;
        if (!isSerialInfoAnnotation(idx, annotationSimpleName(an))) continue;
        if (annotationCallText(idx.a, an)) |t| try anns.append(idx.a, t);
    }
    try idx.class_annotations.put(path, try anns.toOwnedSlice(idx.a));
}

/// The index record for a `@Serializable` class declaration.
fn classInfo(idx: *const Index, c: *const ast.Class, path: []const u8, pkg: []const u8) Info {
    const with = serializableWith(idx.a, c.annotations);
    const kind: Kind = if (with != null)
        .with_custom
    else if (c.is_enum)
        .enum_class
    else if (c.is_sealed)
        (if (c.is_interface) .interface_sealed else .sealed)
    else if (c.is_interface or c.is_abstract)
        .polymorphic
    else if (c.is_value)
        .value_class
    else
        .class;
    const sn: ?[]const u8 = if (findAnnotation(c.annotations, "SerialName")) |an| annotationStringArg(an) else null;
    return Info{
        .name = c.name.name,
        .path = path,
        .pkg = pkg,
        .kind = kind,
        .type_params = c.type_params.len,
        .with = with,
        .serial_name = sn,
    };
}

fn indexDecls(idx: *Index, decls: []const ast.Decl, outer: []const u8, pkg: []const u8) Allocator.Error!void {
    for (decls) |*d| {
        switch (d.*) {
            .Class => |*c| {
                const path = joinPath(idx.a, outer, c.name.name);
                try idx.all_paths.put(path, {});
                try idx.class_nodes.put(path, c);
                try recordSupersAndAnnotations(idx, path, c.supertypes, c.annotations);
                if (isSerializableIn(idx, c.annotations)) {
                    const ci = classInfo(idx, c, path, pkg);
                    try idx.by_name.put(c.name.name, ci);
                    try idx.by_path.put(path, ci);
                }
                // Sealed-parent registration: any class naming a supertype
                // that is (or turns out to be) a sealed serializable class;
                // resolved to the parent's path once every path is known.
                for (c.supertypes) |*st| {
                    try idx.sub_records.append(idx.a, .{ .sub_path = path, .sup_head = st.name.name, .scope = outer });
                }
                try indexDecls(idx, c.members, path, pkg);
            },
            .Object => |*o| {
                const path = joinPath(idx.a, outer, o.name.name);
                try idx.all_paths.put(path, {});
                try idx.objects.put(path, {});
                try idx.objects.put(o.name.name, {});
                try recordSupersAndAnnotations(idx, path, o.supertypes, o.annotations);
                if (isSerializableIn(idx, o.annotations)) {
                    const with = serializableWith(idx.a, o.annotations);
                    const sn: ?[]const u8 = if (findAnnotation(o.annotations, "SerialName")) |an| annotationStringArg(an) else null;
                    const oi = Info{
                        .name = o.name.name,
                        .path = path,
                        .pkg = pkg,
                        .kind = if (with != null) .with_custom else .object,
                        .type_params = 0,
                        .with = with,
                        .serial_name = sn,
                        .is_object_decl = true,
                    };
                    try idx.by_name.put(o.name.name, oi);
                    try idx.by_path.put(path, oi);
                }
                for (o.supertypes) |*st| {
                    try idx.sub_records.append(idx.a, .{ .sub_path = path, .sup_head = st.name.name, .scope = outer });
                }
                try indexDecls(idx, o.members, path, pkg);
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Source text access (default-value expressions are duplicated verbatim,
// exactly as the plugin compiles an initializer twice).
// ---------------------------------------------------------------------------

fn sourceOf(sp: Span) ?[]const u8 {
    const dbg = std.c.getenv("KLIO_SERIAL_DUMP") != null;
    const map = span_mod.active_map orelse {
        if (dbg) std.debug.print("[serial-pass] sourceOf: no active source map\n", .{});
        return null;
    };
    const sf = map.getChecked(sp.file) orelse {
        if (dbg) std.debug.print("[serial-pass] sourceOf: file {d} not in map\n", .{sp.file.int()});
        return null;
    };
    if (sp.end > sf.source.len or sp.start > sp.end) {
        if (dbg) std.debug.print("[serial-pass] sourceOf: span {d}..{d} out of range (len {d})\n", .{ sp.start, sp.end, sf.source.len });
        return null;
    }
    return sf.source[sp.start..sp.end];
}

fn exprText(e: *const ast.Expr) ?[]const u8 {
    return sourceOf(e.span());
}

// ---------------------------------------------------------------------------
// Type -> serializer expression / element codec
// ---------------------------------------------------------------------------

const Prim = enum { int, long, short, byte, char, boolean, float, double, string, none };

fn primOf(head: []const u8) Prim {
    const eq = std.mem.eql;
    if (eq(u8, head, "Int")) return .int;
    if (eq(u8, head, "Long")) return .long;
    if (eq(u8, head, "Short")) return .short;
    if (eq(u8, head, "Byte")) return .byte;
    if (eq(u8, head, "Char")) return .char;
    if (eq(u8, head, "Boolean")) return .boolean;
    if (eq(u8, head, "Float")) return .float;
    if (eq(u8, head, "Double")) return .double;
    if (eq(u8, head, "String")) return .string;
    return .none;
}

fn primSuffix(p: Prim) []const u8 {
    return switch (p) {
        .int => "Int",
        .long => "Long",
        .short => "Short",
        .byte => "Byte",
        .char => "Char",
        .boolean => "Boolean",
        .float => "Float",
        .double => "Double",
        .string => "String",
        .none => "",
    };
}

fn primZero(p: Prim) []const u8 {
    return switch (p) {
        .int => "0",
        .long => "0L",
        .short => "0",
        .byte => "0",
        .char => "'\\u0000'",
        .boolean => "false",
        .float => "0f",
        .double => "0.0",
        .string => "\"\"",
        .none => "null",
    };
}

/// Per-file serializer policy from `@file:` annotations.
const FileSettings = struct {
    /// Type heads listed in `@file:UseContextualSerialization(...)`.
    contextual: std.StringHashMap(void),
    /// Type head -> serializer reference path from `@file:UseSerializers(...)`.
    use_serializers: std.StringHashMap([]const u8),
};

const Gen = struct {
    a: Allocator,
    idx: *const Index,
    /// Type parameter names of the class being generated (index = typeSerial<i>).
    type_params: []const []const u8,
    /// Nested path of the class being generated (`Outer.Inner`); a bare
    /// type name resolves against its enclosing scopes first.
    scope_path: []const u8 = "",
    file: ?*const FileSettings = null,
    /// Package of the file being generated for (serial names of the
    /// unannotated enums it references).
    pkg: []const u8 = "",

    /// Qualify a type reference as written in the class to the path the
    /// synthetic top-level file can name: a sibling nested class
    /// (`SimpleType` inside `Outer`) becomes `Outer.SimpleType`.
    fn qualify(self: *const Gen, written: []const u8) Allocator.Error![]const u8 {
        if (std.mem.indexOfScalar(u8, written, '.') != null) {
            // Already dotted: try it as a path under each enclosing scope.
            var scope = self.scope_path;
            while (true) {
                const cand = if (scope.len == 0) written else try std.fmt.allocPrint(self.a, "{s}.{s}", .{ scope, written });
                if (self.idx.all_paths.contains(cand)) return cand;
                if (scope.len == 0) break;
                scope = if (std.mem.lastIndexOfScalar(u8, scope, '.')) |d| scope[0..d] else "";
            }
            return written;
        }
        var scope = self.scope_path;
        while (true) {
            const cand = if (scope.len == 0) written else try std.fmt.allocPrint(self.a, "{s}.{s}", .{ scope, written });
            if (self.idx.all_paths.contains(cand)) return cand;
            if (scope.len == 0) break;
            scope = if (std.mem.lastIndexOfScalar(u8, scope, '.')) |d| scope[0..d] else "";
        }
        return written;
    }

    fn typeParamIndex(self: *const Gen, head: []const u8) ?usize {
        for (self.type_params, 0..) |tp, i| {
            if (std.mem.eql(u8, tp, head)) return i;
        }
        return null;
    }

    /// Render a type reference as Kotlin source (for locals / signatures).
    fn typeText(self: *const Gen, t: *const ast.TypeRef) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        if (t.function) |_| {
            // Function-typed properties are not serializable; keep the
            // spelling opaque so the generated code still parses.
            try out.appendSlice(self.a, "Any");
        } else {
            try out.appendSlice(self.a, try self.qualify(t.name.name));
            if (t.type_args.len != 0) {
                try out.append(self.a, '<');
                for (t.type_args, 0..) |*ta, i| {
                    if (i > 0) try out.appendSlice(self.a, ", ");
                    if (ta.is_star) {
                        try out.append(self.a, '*');
                    } else {
                        try out.appendSlice(self.a, try self.typeText(&ta.ty));
                    }
                }
                try out.append(self.a, '>');
            }
        }
        if (t.nullable) try out.append(self.a, '?');
        return out.toOwnedSlice(self.a);
    }

    /// The serializer expression for a type, honoring the property's own
    /// annotations (`@Serializable(with=)`, `@Contextual`, `@Polymorphic`).
    fn serializerExpr(self: *const Gen, t: *const ast.TypeRef, annotations: []const ast.Annotation) Allocator.Error![]const u8 {
        const base = try self.serializerExprNonNull(t, annotations);
        if (t.nullable) return std.fmt.allocPrint(self.a, "({s}).nullable", .{base});
        return base;
    }

    fn typeArgSerializer(self: *const Gen, t: *const ast.TypeRef, i: usize) Allocator.Error![]const u8 {
        if (i >= t.type_args.len or t.type_args[i].is_star) {
            return "PolymorphicSerializer(Any::class)";
        }
        // A type argument carries its own use-site annotations
        // (`Map<String, @Polymorphic InnerBase>`), which select the
        // polymorphic / contextual serializer exactly as on a property.
        return self.serializerExpr(&t.type_args[i].ty, t.type_args[i].ty.annotations);
    }

    /// `ContextualSerializer(X::class, fallback, args)`: a `@Serializable`
    /// non-generic `X` supplies its generated serializer as the fallback,
    /// as the plugin does — the contextual descriptor then carries `X`'s
    /// annotations and a module without a contextual entry still decodes.
    fn contextualSerializerExpr(self: *const Gen, t: *const ast.TypeRef) Allocator.Error![]const u8 {
        const a = self.a;
        const q = try self.qualify(t.name.name);
        // The class IN SCOPE (the enclosing scopes of the declaration, then
        // top level): the flat simple-name map would answer another file's
        // same-named class.
        if (self.serializableInScope(t.name.name)) |ci| {
            if (ci.type_params == 0 and t.type_args.len == 0) {
                return std.fmt.allocPrint(a, "ContextualSerializer({s}::class, {s}.serializer(), arrayOf())", .{ q, q });
            }
        }
        return std.fmt.allocPrint(a, "ContextualSerializer({s}::class, null, arrayOf())", .{q});
    }

    /// The `@Serializable` declaration a written type name resolves to from
    /// this generation's scope, walking the enclosing paths outward and
    /// then the top level; null when nothing in scope is serializable.
    fn serializableInScope(self: *const Gen, written: []const u8) ?Info {
        const a = self.a;
        var scope: []const u8 = self.scope_path;
        while (true) {
            const cand = if (scope.len == 0) written else std.fmt.allocPrint(a, "{s}.{s}", .{ scope, written }) catch return null;
            if (self.idx.by_path.get(cand)) |ci| return ci;
            if (scope.len == 0) break;
            scope = if (std.mem.lastIndexOfScalar(u8, scope, '.')) |d| scope[0..d] else "";
        }
        return null;
    }

    fn serializerExprNonNull(self: *const Gen, t: *const ast.TypeRef, annotations: []const ast.Annotation) Allocator.Error![]const u8 {
        const a = self.a;
        if (serializableWith(a, annotations)) |w| return self.customSerializerRef(w);
        const head = simpleHead(t.name.name);
        // File-level policy applies after the property's own annotations.
        if (self.file) |fs| {
            if (!hasAnnotation(annotations, "Contextual") and !hasAnnotation(annotations, "Polymorphic")) {
                if (fs.use_serializers.get(head)) |ser| return self.customSerializerRef(ser);
                if (fs.contextual.contains(head)) {
                    return self.contextualSerializerExpr(t);
                }
            }
        }
        if (hasAnnotation(annotations, "Contextual")) {
            return self.contextualSerializerExpr(t);
        }
        if (hasAnnotation(annotations, "Polymorphic")) {
            return std.fmt.allocPrint(a, "PolymorphicSerializer({s}::class)", .{try self.qualify(t.name.name)});
        }
        if (self.typeParamIndex(head)) |i| {
            return std.fmt.allocPrint(a, "typeSerial{d}", .{i});
        }
        const eq = std.mem.eql;
        const p = primOf(head);
        if (p != .none) return std.fmt.allocPrint(a, "{s}.serializer()", .{primSuffix(p)});
        if (eq(u8, head, "Unit")) return "Unit.serializer()";
        if (eq(u8, head, "Any")) return "PolymorphicSerializer(Any::class)";
        if (eq(u8, head, "UInt") or eq(u8, head, "ULong") or eq(u8, head, "UByte") or eq(u8, head, "UShort"))
            return std.fmt.allocPrint(a, "{s}.serializer()", .{head});
        if (eq(u8, head, "Duration")) return "Duration.serializer()";
        if (eq(u8, head, "Instant")) return "Instant.serializer()";
        if (eq(u8, head, "List") or eq(u8, head, "MutableList") or eq(u8, head, "ArrayList") or
            eq(u8, head, "Collection") or eq(u8, head, "MutableCollection") or eq(u8, head, "Iterable"))
        {
            return std.fmt.allocPrint(a, "ArrayListSerializer({s})", .{try self.typeArgSerializer(t, 0)});
        }
        if (eq(u8, head, "Set") or eq(u8, head, "MutableSet") or eq(u8, head, "LinkedHashSet")) {
            return std.fmt.allocPrint(a, "LinkedHashSetSerializer({s})", .{try self.typeArgSerializer(t, 0)});
        }
        if (eq(u8, head, "HashSet")) {
            return std.fmt.allocPrint(a, "HashSetSerializer({s})", .{try self.typeArgSerializer(t, 0)});
        }
        if (eq(u8, head, "Map") or eq(u8, head, "MutableMap") or eq(u8, head, "LinkedHashMap")) {
            return std.fmt.allocPrint(a, "LinkedHashMapSerializer({s}, {s})", .{ try self.typeArgSerializer(t, 0), try self.typeArgSerializer(t, 1) });
        }
        if (eq(u8, head, "HashMap")) {
            return std.fmt.allocPrint(a, "HashMapSerializer({s}, {s})", .{ try self.typeArgSerializer(t, 0), try self.typeArgSerializer(t, 1) });
        }
        if (eq(u8, head, "Entry")) {
            return std.fmt.allocPrint(a, "MapEntrySerializer({s}, {s})", .{ try self.typeArgSerializer(t, 0), try self.typeArgSerializer(t, 1) });
        }
        if (eq(u8, head, "Pair")) {
            return std.fmt.allocPrint(a, "PairSerializer({s}, {s})", .{ try self.typeArgSerializer(t, 0), try self.typeArgSerializer(t, 1) });
        }
        if (eq(u8, head, "Triple")) {
            return std.fmt.allocPrint(a, "TripleSerializer({s}, {s}, {s})", .{ try self.typeArgSerializer(t, 0), try self.typeArgSerializer(t, 1), try self.typeArgSerializer(t, 2) });
        }
        if (eq(u8, head, "Array")) {
            const elem_head = if (t.type_args.len != 0 and !t.type_args[0].is_star) try self.qualify(t.type_args[0].ty.name.name) else "Any";
            return std.fmt.allocPrint(a, "ArraySerializer({s}::class, {s})", .{ elem_head, try self.typeArgSerializer(t, 0) });
        }
        if (eq(u8, head, "IntArray") or eq(u8, head, "LongArray") or eq(u8, head, "ShortArray") or eq(u8, head, "ByteArray") or
            eq(u8, head, "CharArray") or eq(u8, head, "FloatArray") or eq(u8, head, "DoubleArray") or eq(u8, head, "BooleanArray") or
            eq(u8, head, "UIntArray") or eq(u8, head, "ULongArray") or eq(u8, head, "UByteArray") or eq(u8, head, "UShortArray"))
        {
            return std.fmt.allocPrint(a, "{s}Serializer()", .{head});
        }
        // A user type: its companion `serializer(...)`, with type-argument
        // serializers for a generic one. Qualified to the path the
        // synthetic file can name.
        const qn = try self.qualify(t.name.name);
        // An interface type is polymorphic unless it carries its own
        // `@Serializable` (a sealed interface's generated serializer, or a
        // custom `with=`); `@Polymorphic` on the interface forces it.
        if (self.idx.class_nodes.get(qn)) |cn| {
            if (cn.is_interface and (hasAnnotation(cn.annotations, "Polymorphic") or !isSerializableIn(self.idx, cn.annotations))) {
                return std.fmt.allocPrint(a, "PolymorphicSerializer({s}::class)", .{qn});
            }
            // An enum is serializable without `@Serializable`: the plugin
            // builds its serializer in place (no companion exists to ask).
            if (cn.is_enum and !isSerializableIn(self.idx, cn.annotations)) {
                const serial = if (self.pkg.len == 0) qn else try std.fmt.allocPrint(a, "{s}.{s}", .{ self.pkg, qn });
                return std.fmt.allocPrint(a, "createSimpleEnumSerializer(\"{s}\", {s}.values())", .{ serial, qn });
            }
        }
        if (t.type_args.len != 0) {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(a, qn);
            try out.appendSlice(a, ".serializer(");
            for (t.type_args, 0..) |_, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try out.appendSlice(a, try self.typeArgSerializer(t, i));
            }
            try out.append(a, ')');
            return out.toOwnedSlice(a);
        }
        return std.fmt.allocPrint(a, "{s}.serializer()", .{qn});
    }

    /// `S` for an object serializer, `S()` for a class serializer.
    fn customSerializerRef(self: *const Gen, w: []const u8) Allocator.Error![]const u8 {
        const q = try self.qualify(w);
        if (self.idx.objects.contains(q) or self.idx.objects.contains(w) or self.idx.objects.contains(simpleHead(w))) return q;
        // A serializer CLASS for a generic declaration takes the
        // type-argument serializers, exactly as the plugin constructs it
        // (`ParametrizedSerializer(typeSerial0)`).
        if (self.type_params.len != 0) {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(self.a, q);
            try out.append(self.a, '(');
            for (self.type_params, 0..) |_, i| {
                if (i > 0) try out.appendSlice(self.a, ", ");
                try wp(&out, self.a, "typeSerial{d}", .{i});
            }
            try out.append(self.a, ')');
            return out.toOwnedSlice(self.a);
        }
        return std.fmt.allocPrint(self.a, "{s}()", .{q});
    }
};

// ---------------------------------------------------------------------------
// Element model of a serializable class
// ---------------------------------------------------------------------------

const Elem = struct {
    /// Property name in the class.
    name: []const u8,
    /// Serial (wire) name.
    serial_name: []const u8,
    ty: *const ast.TypeRef,
    annotations: []const ast.Annotation,
    /// Source text of the default / initializer expression, if any.
    default_text: ?[]const u8,
    /// Constructor property (vs body property).
    in_ctor: bool,
    /// `@Required`: never optional even with a default.
    required: bool,
    encode_default: enum { unset, always, never },
    is_var: bool,
    is_lateinit: bool = false,
    /// Declared by a `@Serializable` superclass: decoded and written like
    /// the plugin does, never handed to this class's constructor.
    inherited: bool = false,
};

fn encodeDefaultMode(annotations: []const ast.Annotation) @TypeOf(@as(Elem, undefined).encode_default) {
    const an = findAnnotation(annotations, "EncodeDefault") orelse return .unset;
    if (an.args.len == 0) return .always;
    if (exprPathText(std.heap.page_allocator, &an.args[0])) |p| {
        if (std.mem.endsWith(u8, p, "NEVER")) return .never;
    }
    return .always;
}

fn collectElems(a: Allocator, g: *const Gen, c: *const ast.Class) Allocator.Error![]Elem {
    var out: std.ArrayList(Elem) = .empty;
    // The plugin serializes a `@Serializable` superclass's properties
    // first (`sealed class Typed<T>(val a: T)` under `Child(val y)`
    // encodes `a` then `y`); a supertype argument instantiates the
    // superclass's type parameter for those elements.
    for (c.supertypes) |*st| {
        const sup_path = try g.qualify(st.name.name);
        const sup = g.idx.class_nodes.get(sup_path) orelse continue;
        if (sup.is_interface or !isSerializableIn(g.idx, sup.annotations)) continue;
        var tps: std.ArrayList([]const u8) = .empty;
        for (sup.type_params) |*tp| try tps.append(a, tp.name.name);
        var g2 = g.*;
        g2.scope_path = sup_path;
        g2.type_params = tps.items;
        const inh = try collectElems(a, &g2, sup);
        for (inh) |e0| {
            var e = e0;
            e.inherited = true;
            e.in_ctor = false;
            e.default_text = null;
            e.is_lateinit = false;
            for (sup.type_params, 0..) |*tp, ti| {
                if (!std.mem.eql(u8, e.ty.name.name, tp.name.name)) continue;
                if (ti < st.type_args.len and !st.type_args[ti].is_star) e.ty = &st.type_args[ti].ty;
                break;
            }
            try out.append(a, e);
        }
    }
    for (c.primary_params) |*p| {
        if (p.property == null) continue;
        if (hasAnnotation(p.annotations, "Transient")) continue;
        const sn: []const u8 = if (findAnnotation(p.annotations, "SerialName")) |an| (annotationStringArg(an) orelse p.name.name) else p.name.name;
        try out.append(a, .{
            .name = p.name.name,
            .serial_name = sn,
            .ty = &p.ty,
            .annotations = p.annotations,
            .default_text = if (p.default) |*d| exprText(d) else null,
            .in_ctor = true,
            .required = hasAnnotation(p.annotations, "Required"),
            .encode_default = encodeDefaultMode(p.annotations),
            .is_var = p.property.?,
        });
    }
    for (c.members) |*m| {
        if (m.* != .Property) continue;
        const p: *ast.Property = m.Property;
        if (p.receiver_type != null) continue;
        if (hasAnnotation(p.annotations, "Transient")) continue;
        if (p.is_abstract) continue;
        // The plugin's element rule for body properties: a BACKING FIELD
        // makes the property an element — an initializer, a lateinit, a
        // plain declaration without custom accessors, or an accessor that
        // reads/writes `field`. A property whose accessors never touch
        // `field` has no storage and is skipped. (A field assigned only in
        // an init block IS an element, but its decoded value is discarded —
        // the init block runs after construction; see the assignment step.)
        if (p.delegate != null) continue;
        const getter_field = if (p.getter) |gt| ast.accessorUsesField(gt) else false;
        const setter_field = if (p.setter) |st| ast.accessorUsesField(st) else false;
        const has_field = p.init != null or p.is_lateinit or
            (p.getter == null and p.setter == null) or getter_field or setter_field;
        if (!has_field) continue;
        // A property with no annotation carries an INFERRED type: name it
        // from a literal initializer (the plugin's inference has the real
        // answer; a non-literal initializer falls back to `Any`, which the
        // polymorphic path reports honestly if it cannot serialize).
        const ty: *const ast.TypeRef = if (p.ty) |*t| t else blk: {
            const init = p.init orelse continue;
            const inferred_name: []const u8 = switch (init) {
                .StringTemplate => "String",
                .IntLit => |lit| switch (lit.kind) {
                    .Long => "Long",
                    .UInt => "UInt",
                    .ULong => "ULong",
                    .Int => "Int",
                },
                .FloatLit => |lit| if (lit.kind == .Float) "Float" else "Double",
                .BoolLit => "Boolean",
                .CharLit => "Char",
                else => "Any",
            };
            const t = try a.create(ast.TypeRef);
            t.* = .{
                .name = .{ .name = inferred_name, .span = p.name.span },
                .nullable = false,
                .span = p.name.span,
                .type_args = &.{},
                .function = null,
                .definitely_non_null = false,
                .annotations = &.{},
                .qualified_path = null,
            };
            break :blk t;
        };
        const sn: []const u8 = if (findAnnotation(p.annotations, "SerialName")) |an| (annotationStringArg(an) orelse p.name.name) else p.name.name;
        try out.append(a, .{
            .name = p.name.name,
            .serial_name = sn,
            .ty = ty,
            .annotations = p.annotations,
            .default_text = if (p.init) |*i| exprText(i) else null,
            .in_ctor = false,
            .required = hasAnnotation(p.annotations, "Required"),
            .encode_default = encodeDefaultMode(p.annotations),
            .is_var = p.mutable,
            .is_lateinit = p.is_lateinit,
        });
    }
    return out.toOwnedSlice(a);
}

fn elemOptional(e: *const Elem) bool {
    return e.default_text != null and !e.required;
}

// ---------------------------------------------------------------------------
// Generation
// ---------------------------------------------------------------------------

fn genNameFor(a: Allocator, info: *const Info) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (info.path) |ch| try out.append(a, if (ch == '.') '_' else ch);
    try out.appendSlice(a, info.gen_suffix);
    return out.toOwnedSlice(a);
}

fn genName(a: Allocator, path: []const u8) Allocator.Error![]const u8 {
    // `Outer.Inner` -> `Outer_Inner$serializer` (a legal backticked name).
    var out: std.ArrayList(u8) = .empty;
    for (path) |ch| try out.append(a, if (ch == '.') '_' else ch);
    try out.appendSlice(a, "$serializer");
    return out.toOwnedSlice(a);
}

fn serialNameOf(a: Allocator, info: *const Info) Allocator.Error![]const u8 {
    if (info.serial_name) |sn| return sn;
    if (info.pkg.len == 0) return info.path;
    return std.fmt.allocPrint(a, "{s}.{s}", .{ info.pkg, info.path });
}

fn typeParamList(a: Allocator, c: *const ast.Class) Allocator.Error![]const u8 {
    if (c.type_params.len == 0) return "";
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, '<');
    for (c.type_params, 0..) |*tp, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, tp.name.name);
    }
    try out.append(a, '>');
    return out.toOwnedSlice(a);
}

fn typeSerialParams(a: Allocator, c: *const ast.Class) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (c.type_params, 0..) |*tp, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try wp(&out, a, "typeSerial{d}: KSerializer<{s}>", .{ i, tp.name.name });
    }
    return out.toOwnedSlice(a);
}

fn typeSerialArgs(a: Allocator, c: *const ast.Class) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (c.type_params, 0..) |_, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try wp(&out, a, "typeSerial{d}", .{i});
    }
    return out.toOwnedSlice(a);
}

/// The full `$serializer` for a plain class.
fn genClassSerializer(w: *std.ArrayList(u8), a: Allocator, g: *const Gen, c: *const ast.Class, info: *const Info) Allocator.Error!void {
    const gn = try genNameFor(a, info);
    const tps = try typeParamList(a, c);
    const self_ty = try std.fmt.allocPrint(a, "{s}{s}", .{ info.path, tps });
    const generic = c.type_params.len != 0;
    if (generic) {
        try wp(w, a, "class `{s}`{s}({s}) : GeneratedSerializer<{s}> {{\n", .{ gn, tps, try typeSerialParams(a, c), self_ty });
    } else {
        try wp(w, a, "object `{s}` : GeneratedSerializer<{s}> {{\n", .{ gn, self_ty });
    }
    try genClassSerializerBody(w, a, g, c, info);
    try w.appendSlice(a, "}\n\n");
}

/// The members of a generated serializer for `c` (descriptor, child
/// serializers, serialize, deserialize) — the body of `<Name>$serializer`,
/// and of a `@Serializer(forClass = Name::class)` object the plugin fills.
/// The primitive fast path (`encodeIntElement` / `decodeStringElement`)
/// applies only to a plainly-typed element: a custom or contextual
/// serializer on the property routes through the serializer instead.
fn elemPrim(g: *const Gen, e: *const Elem) Prim {
    if (e.ty.nullable) return .none;
    if (serializableWith(std.heap.page_allocator, e.annotations) != null) return .none;
    if (hasAnnotation(e.annotations, "Contextual") or hasAnnotation(e.annotations, "Polymorphic")) return .none;
    // A file-level `@file:UseSerializers` / `@file:UseContextualSerialization`
    // serializer for this element's type routes through that serializer, so a
    // primitive-typed element (`nonNullable: Int`) must NOT take the primitive
    // element codec that would ignore it.
    if (g.file) |fs| {
        const head = simpleHead(e.ty.name.name);
        if (fs.use_serializers.get(head) != null or fs.contextual.contains(head)) return .none;
    }
    return primOf(simpleHead(e.ty.name.name));
}

fn genClassSerializerBody(w: *std.ArrayList(u8), a: Allocator, g: *const Gen, c: *const ast.Class, info: *const Info) Allocator.Error!void {
    const elems = try collectElems(a, g, c);
    const serial = try serialNameOf(a, info);
    const tps = try typeParamList(a, c);
    const self_ty = try std.fmt.allocPrint(a, "{s}{s}", .{ info.path, tps });
    const generic = c.type_params.len != 0;
    // Descriptor.
    try wp(w, a, "    override val descriptor: SerialDescriptor = PluginGeneratedSerialDescriptor(\"{s}\", this, {d}).also {{ `$dd` ->\n", .{ serial, elems.len });
    for (elems) |*e| {
        try wp(w, a, "        `$dd`.addElement(\"{s}\", {s})\n", .{ e.serial_name, if (elemOptional(e)) "true" else "false" });
        // Non-framework property annotations travel into the descriptor.
        for (e.annotations) |*an| {
            const n = annotationSimpleName(an);
            if (std.mem.eql(u8, n, "SerialName") or std.mem.eql(u8, n, "Serializable") or std.mem.eql(u8, n, "Transient") or
                std.mem.eql(u8, n, "Required") or std.mem.eql(u8, n, "EncodeDefault") or std.mem.eql(u8, n, "Contextual") or
                std.mem.eql(u8, n, "Polymorphic") or std.mem.eql(u8, n, "OptIn") or std.mem.eql(u8, n, "Suppress")) continue;
            if (!isSerialInfoAnnotation(g.idx, n)) continue;
            if (sourceOf(an.span)) |txt| {
                // `@Foo(args)` -> `Foo(args)` (annotation classes are
                // constructible like classes).
                const body = if (txt.len > 0 and txt[0] == '@') txt[1..] else txt;
                const call = if (std.mem.indexOfScalar(u8, body, '(') == null) try std.fmt.allocPrint(a, "{s}()", .{body}) else body;
                try wp(w, a, "        `$dd`.pushAnnotation({s})\n", .{call});
            }
        }
    }
    for (try classAnnotationCalls(a, g.idx, info.path)) |call| {
        try wp(w, a, "        `$dd`.pushClassAnnotation({s})\n", .{call});
    }
    try w.appendSlice(a, "    }\n");
    // childSerializers / typeParametersSerializers.
    try w.appendSlice(a, "    override fun childSerializers(): Array<KSerializer<*>> = arrayOf<KSerializer<*>>(");
    for (elems, 0..) |*e, i| {
        if (i > 0) try w.appendSlice(a, ", ");
        try w.appendSlice(a, try g.serializerExpr(e.ty, e.annotations));
    }
    try w.appendSlice(a, ")\n");
    if (generic) {
        try wp(w, a, "    override fun typeParametersSerializers(): Array<KSerializer<*>> = arrayOf<KSerializer<*>>({s})\n", .{try typeSerialArgs(a, c)});
    }
    // serialize.
    try wp(w, a, "    override fun serialize(encoder: Encoder, value: {s}) {{\n", .{self_ty});
    try w.appendSlice(a, "        val `$d` = descriptor\n        val `$out` = encoder.beginStructure(`$d`)\n");
    for (elems, 0..) |*e, i| {
        const p = elemPrim(g, e);
        const enc = if (p != .none)
            try std.fmt.allocPrint(a, "`$out`.encode{s}Element(`$d`, {d}, value.{s})", .{ primSuffix(p), i, e.name })
        else if (e.ty.nullable)
            try std.fmt.allocPrint(a, "`$out`.encodeNullableSerializableElement(`$d`, {d}, {s}, value.{s})", .{ i, try g.serializerExprNonNull(e.ty, e.annotations), e.name })
        else
            try std.fmt.allocPrint(a, "`$out`.encodeSerializableElement(`$d`, {d}, {s}, value.{s})", .{ i, try g.serializerExpr(e.ty, e.annotations), e.name });
        if (elemOptional(e) and e.encode_default != .always) {
            const dflt = e.default_text.?;
            if (e.encode_default == .never) {
                try wp(w, a, "        if (value.run {{ {s} != ({s}) }}) {s}\n", .{ e.name, dflt, enc });
            } else {
                try wp(w, a, "        if (`$out`.shouldEncodeElementDefault(`$d`, {d}) || value.run {{ {s} != ({s}) }}) {s}\n", .{ i, e.name, dflt, enc });
            }
        } else {
            try wp(w, a, "        {s}\n", .{enc});
        }
    }
    try w.appendSlice(a, "        `$out`.endStructure(`$d`)\n    }\n");
    // deserialize.
    try wp(w, a, "    override fun deserialize(decoder: Decoder): {s} {{\n", .{self_ty});
    try w.appendSlice(a, "        val `$d` = descriptor\n        val `$c` = decoder.beginStructure(`$d`)\n");
    const n_masks: usize = (elems.len + 31) / 32;
    {
        var mi: usize = 0;
        while (mi < n_masks) : (mi += 1) try wp(w, a, "        var `$seen{d}` = 0\n", .{mi});
    }
    for (elems, 0..) |*e, i| {
        const p = elemPrim(g, e);
        if (p != .none) {
            try wp(w, a, "        var `$v{d}`: {s} = {s}\n", .{ i, primSuffix(p), primZero(p) });
        } else {
            const tt = try g.typeText(e.ty);
            const nn = if (e.ty.nullable) tt else try std.fmt.allocPrint(a, "{s}?", .{tt});
            try wp(w, a, "        var `$v{d}`: {s} = null\n", .{ i, nn });
        }
    }
    // Per-element decode statements (shared by the sequential and looped paths).
    var dec_stmts: std.ArrayList([]const u8) = .empty;
    for (elems, 0..) |*e, i| {
        const p = elemPrim(g, e);
        // Bit 31 and a full golden mask overflow a Kotlin Int literal;
        // both are spelled as the signed value the `and` sees.
        const bit: i32 = @bitCast(@as(u32, 1) << @intCast(i % 32));
        const mk = i / 32;
        const st = if (p != .none)
            try std.fmt.allocPrint(a, "`$v{d}` = `$c`.decode{s}Element(`$d`, {d}); `$seen{d}` = `$seen{d}` or {d}", .{ i, primSuffix(p), i, mk, mk, bit })
        else if (e.ty.nullable)
            try std.fmt.allocPrint(a, "`$v{d}` = `$c`.decodeNullableSerializableElement(`$d`, {d}, {s}, `$v{d}`); `$seen{d}` = `$seen{d}` or {d}", .{ i, i, try g.serializerExprNonNull(e.ty, e.annotations), i, mk, mk, bit })
        else
            try std.fmt.allocPrint(a, "`$v{d}` = `$c`.decodeSerializableElement(`$d`, {d}, {s}, `$v{d}`); `$seen{d}` = `$seen{d}` or {d}", .{ i, i, try g.serializerExpr(e.ty, e.annotations), i, mk, mk, bit });
        try dec_stmts.append(a, st);
    }
    try w.appendSlice(a, "        if (`$c`.decodeSequentially()) {\n");
    for (dec_stmts.items) |st| try wp(w, a, "            {s}\n", .{st});
    try w.appendSlice(a, "        } else {\n            while (true) {\n                val `$index` = `$c`.decodeElementIndex(`$d`)\n                if (`$index` == -1) break\n                when (`$index`) {\n");
    for (dec_stmts.items, 0..) |st, i| try wp(w, a, "                    {d} -> {{ {s} }}\n", .{ i, st });
    try w.appendSlice(a, "                    else -> throw UnknownFieldException(`$index`)\n                }\n            }\n        }\n        `$c`.endStructure(`$d`)\n");
    // Missing-field check over the required elements, one mask per 32.
    {
        var mi: usize = 0;
        while (mi < n_masks) : (mi += 1) {
            var golden_u: u32 = 0;
            for (elems, 0..) |*e, i| {
                if (i / 32 != mi) continue;
                if (!elemOptional(e)) golden_u |= @as(u32, 1) << @intCast(i % 32);
            }
            const golden: i32 = @bitCast(golden_u);
            if (golden != 0) {
                try wp(w, a, "        if ((`$seen{d}` and {d}) != {d}) throwMissingFieldException(`$seen{d}`, {d}, `$d`)\n", .{ mi, golden, golden, mi, golden });
            }
        }
    }
    // Construction: constructor properties with their defaults re-evaluated
    // in declaration order (shadowing so defaults can reference earlier
    // properties), then body properties assigned when seen.
    try w.appendSlice(a, "        return run {\n");
    // Constructor parameters walk in DECLARATION order so a default may
    // reference any earlier parameter, transient ones included: a
    // `@Transient` property is never decoded, but its default still binds
    // a local for the defaults that follow (`transientRefFromProp: Int =
    // constTransient + 4`).
    for (c.primary_params) |*pp| {
        if (pp.property == null) continue;
        if (hasAnnotation(pp.annotations, "Transient")) {
            if (pp.default) |*d| {
                if (exprText(d)) |dt| try wp(w, a, "            val {s}: {s} = ({s})\n", .{ pp.name.name, try g.typeText(&pp.ty), dt });
            }
            continue;
        }
        var ei: ?usize = null;
        for (elems, 0..) |*cand, ci| {
            if (cand.in_ctor and std.mem.eql(u8, cand.name, pp.name.name)) {
                ei = ci;
                break;
            }
        }
        const i = ei orelse continue;
        const e = &elems[i];
        const tt = try g.typeText(e.ty);
        const bit: i32 = @bitCast(@as(u32, 1) << @intCast(i % 32));
        const val_expr = if (e.ty.nullable) try std.fmt.allocPrint(a, "`$v{d}`", .{i}) else blk: {
            const p = primOf(simpleHead(e.ty.name.name));
            if (p != .none) break :blk try std.fmt.allocPrint(a, "`$v{d}`", .{i});
            // A type-parameter element (`val boxed: T`) may be instantiated
            // nullable (`Box<Int?>`): the value is cast, never asserted.
            if (g.typeParamIndex(simpleHead(e.ty.name.name)) != null) break :blk try std.fmt.allocPrint(a, "(`$v{d}` as {s})", .{ i, tt });
            break :blk try std.fmt.allocPrint(a, "`$v{d}`!!", .{i});
        };
        if (e.default_text) |dflt| {
            try wp(w, a, "            val {s}: {s} = if ((`$seen{d}` and {d}) == 0) ({s}) else {s}\n", .{ e.name, tt, i / 32, bit, dflt, val_expr });
        } else {
            try wp(w, a, "            val {s}: {s} = {s}\n", .{ e.name, tt, val_expr });
        }
    }
    try wp(w, a, "            val `$inst` = {s}(", .{info.path});
    var first = true;
    for (elems) |*e| {
        if (!e.in_ctor) continue;
        if (!first) try w.appendSlice(a, ", ");
        first = false;
        try wp(w, a, "{s} = {s}", .{ e.name, e.name });
    }
    try w.appendSlice(a, ")\n");
    for (elems, 0..) |*e, i| {
        if (e.in_ctor) continue;
        // A body property with no initializer and not lateinit is assigned
        // by an init block, which the plugin runs AFTER field assignment —
        // the decoded value never survives. Decode it (the element exists)
        // but leave the constructed value alone.
        if (e.default_text == null and !e.is_lateinit) continue;
        const bit: i32 = @bitCast(@as(u32, 1) << @intCast(i % 32));
        const val_expr = if (e.ty.nullable) try std.fmt.allocPrint(a, "`$v{d}`", .{i}) else blk: {
            const p = primOf(simpleHead(e.ty.name.name));
            if (p != .none) break :blk try std.fmt.allocPrint(a, "`$v{d}`", .{i});
            // A type-parameter element (`val boxed: T`) may be instantiated
            // nullable (`Box<Int?>`): the value is cast, never asserted.
            if (g.typeParamIndex(simpleHead(e.ty.name.name)) != null) break :blk try std.fmt.allocPrint(a, "(`$v{d}` as {s})", .{ i, try g.typeText(e.ty) });
            break :blk try std.fmt.allocPrint(a, "`$v{d}`!!", .{i});
        };
        try wp(w, a, "            if ((`$seen{d}` and {d}) != 0) `$inst`.{s} = {s}\n", .{ i / 32, bit, e.name, val_expr });
    }
    try w.appendSlice(a, "            `$inst`\n        }\n    }\n");
}

/// The class annotations a generated descriptor carries: the class's own
/// non-framework annotations plus every `@InheritableSerialInfo`-marked
/// annotation found on its supertype chain (nearest first, no duplicates).
fn classAnnotationCalls(a: Allocator, idx: *const Index, path: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (idx.class_annotations.get(path)) |own| try out.appendSlice(a, own);
    var seen_paths = std.StringHashMap(void).init(a);
    var queue: std.ArrayList([]const u8) = .empty;
    try queue.append(a, path);
    var qi: usize = 0;
    while (qi < queue.items.len) : (qi += 1) {
        const cur = queue.items[qi];
        const sups = idx.supers.get(cur) orelse continue;
        for (sups) |sh| {
            // Resolve the supertype's path: same nesting scope, then top.
            var sp: ?[]const u8 = null;
            var scope = cur;
            while (true) {
                scope = if (std.mem.lastIndexOfScalar(u8, scope, '.')) |d| scope[0..d] else "";
                const cand = if (scope.len == 0) sh else try std.fmt.allocPrint(a, "{s}.{s}", .{ scope, sh });
                if (idx.supers.contains(cand)) {
                    sp = cand;
                    break;
                }
                if (scope.len == 0) break;
            }
            const spath = sp orelse continue;
            if (seen_paths.contains(spath)) continue;
            try seen_paths.put(spath, {});
            if (idx.class_annotations.get(spath)) |anns| {
                for (anns) |call| {
                    const head = if (std.mem.indexOfScalar(u8, call, '(')) |lp| call[0..lp] else call;
                    if (!idx.inheritable.contains(simpleHead(head))) continue;
                    var dup = false;
                    for (out.items) |x| {
                        if (std.mem.eql(u8, x, call)) dup = true;
                    }
                    if (!dup) try out.append(a, call);
                }
            }
            try queue.append(a, spath);
        }
    }
    return out.toOwnedSlice(a);
}

/// Value class: one inline element.
fn genValueClassSerializer(w: *std.ArrayList(u8), a: Allocator, g: *const Gen, c: *const ast.Class, info: *const Info) Allocator.Error!void {
    const elems = try collectElems(a, g, c);
    if (elems.len != 1) return;
    const e = &elems[0];
    const gn = try genNameFor(a, info);
    const serial = try serialNameOf(a, info);
    const p = elemPrim(g, e);
    const tps = try typeParamList(a, c);
    const self_ty = try std.fmt.allocPrint(a, "{s}{s}", .{ info.path, tps });
    // A generic value class (`value class MyList<T>(val list: List<T>)`)
    // takes its type-argument serializers as constructor parameters, as
    // a generic class's serializer does.
    if (c.type_params.len != 0) {
        try wp(w, a, "class `{s}`{s}({s}) : GeneratedSerializer<{s}> {{\n", .{ gn, tps, try typeSerialParams(a, c), self_ty });
    } else {
        try wp(w, a, "object `{s}` : GeneratedSerializer<{s}> {{\n", .{ gn, self_ty });
    }
    try wp(w, a, "    override val descriptor: SerialDescriptor = InlineClassDescriptor(\"{s}\", this).also {{ `$dd` -> `$dd`.addElement(\"{s}\", false) }}\n", .{ serial, e.serial_name });
    try wp(w, a, "    override fun childSerializers(): Array<KSerializer<*>> = arrayOf<KSerializer<*>>({s})\n", .{try g.serializerExpr(e.ty, e.annotations)});
    try wp(w, a, "    override fun serialize(encoder: Encoder, value: {s}) {{\n        val `$inl` = encoder.encodeInline(descriptor)\n", .{self_ty});
    if (p != .none) {
        try wp(w, a, "        `$inl`.encode{s}(value.{s})\n", .{ primSuffix(p), e.name });
    } else if (e.ty.nullable) {
        try wp(w, a, "        `$inl`.encodeNullableSerializableValue({s}, value.{s})\n", .{ try g.serializerExprNonNull(e.ty, e.annotations), e.name });
    } else {
        try wp(w, a, "        `$inl`.encodeSerializableValue({s}, value.{s})\n", .{ try g.serializerExpr(e.ty, e.annotations), e.name });
    }
    try w.appendSlice(a, "    }\n");
    try wp(w, a, "    override fun deserialize(decoder: Decoder): {s} {{\n        val `$inl` = decoder.decodeInline(descriptor)\n", .{self_ty});
    if (p != .none) {
        try wp(w, a, "        return {s}(`$inl`.decode{s}())\n", .{ info.path, primSuffix(p) });
    } else if (e.ty.nullable) {
        try wp(w, a, "        return {s}(`$inl`.decodeNullableSerializableValue({s}))\n", .{ info.path, try g.serializerExprNonNull(e.ty, e.annotations) });
    } else {
        try wp(w, a, "        return {s}(`$inl`.decodeSerializableValue({s}))\n", .{ info.path, try g.serializerExpr(e.ty, e.annotations) });
    }
    try w.appendSlice(a, "    }\n}\n\n");
}

/// Enum: a top-level factory the companion's `serializer()` calls.
fn genEnumFactory(w: *std.ArrayList(u8), a: Allocator, idx: *const Index, c: *const ast.Class, info: *const Info) Allocator.Error!void {
    const gn = try genNameFor(a, info);
    const serial = try serialNameOf(a, info);
    var marked = false;
    for (c.enum_entries) |*en| {
        if (en.annotations.len != 0) marked = true;
    }
    const class_anns = try classAnnotationCalls(a, idx, info.path);
    if (class_anns.len != 0) marked = true;
    if (!marked) {
        try wp(w, a, "val `{s}Cache`: KSerializer<{s}> by lazy {{ createSimpleEnumSerializer(\"{s}\", {s}.values()) }}\nfun `{s}Impl`(): KSerializer<{s}> = `{s}Cache`\n\n", .{ gn, info.path, serial, info.path, gn, info.path, gn });
        return;
    }
    try wp(w, a, "val `{s}Cache`: KSerializer<{s}> by lazy {{ createAnnotatedEnumSerializer(\"{s}\", {s}.values(), arrayOf<String?>(", .{ gn, info.path, serial, info.path });
    for (c.enum_entries, 0..) |*en, i| {
        if (i > 0) try w.appendSlice(a, ", ");
        if (findAnnotation(en.annotations, "SerialName")) |an| {
            if (annotationStringArg(an)) |s| {
                try wp(w, a, "\"{s}\"", .{s});
                continue;
            }
        }
        try w.appendSlice(a, "null");
    }
    try w.appendSlice(a, "), arrayOf<Array<Annotation>?>(");
    for (c.enum_entries, 0..) |*en, i| {
        if (i > 0) try w.appendSlice(a, ", ");
        var anns: std.ArrayList([]const u8) = .empty;
        for (en.annotations) |*an| {
            const n = annotationSimpleName(an);
            if (std.mem.eql(u8, n, "SerialName")) continue;
            if (sourceOf(an.span)) |txt| {
                const body = if (txt.len > 0 and txt[0] == '@') txt[1..] else txt;
                const call = if (std.mem.indexOfScalar(u8, body, '(') == null) try std.fmt.allocPrint(a, "{s}()", .{body}) else body;
                try anns.append(a, call);
            }
        }
        if (anns.items.len == 0) {
            try w.appendSlice(a, "null");
        } else {
            try w.appendSlice(a, "arrayOf<Annotation>(");
            for (anns.items, 0..) |s, j| {
                if (j > 0) try w.appendSlice(a, ", ");
                try w.appendSlice(a, s);
            }
            try w.appendSlice(a, ")");
        }
    }
    try w.appendSlice(a, "), ");
    if (class_anns.len == 0) {
        try w.appendSlice(a, "null");
    } else {
        try w.appendSlice(a, "arrayOf<Annotation>(");
        for (class_anns, 0..) |call, i| {
            if (i > 0) try w.appendSlice(a, ", ");
            try w.appendSlice(a, call);
        }
        try w.appendSlice(a, ")");
    }
    try w.appendSlice(a, ") }\n");
    try wp(w, a, "fun `{s}Impl`(): KSerializer<{s}> = `{s}Cache`\n\n", .{ gn, info.path, gn });
}

/// The concrete serializable subclasses of a sealed declaration, flattened
/// through nested sealed / abstract / interface subtypes (the plugin lists
/// leaves only), in declaration order, without duplicates.
fn collectSealedLeaves(a: Allocator, idx: *const Index, parent_path: []const u8, out: *std.ArrayList([]const u8), seen: *std.StringHashMap(void)) Allocator.Error!void {
    const subs: []const SealedSub = if (idx.sealed_subs.get(parent_path)) |l| l.items else &.{};
    for (subs) |sub| {
        if (seen.contains(sub.path)) continue;
        try seen.put(sub.path, {});
        const si = idx.by_path.get(sub.path) orelse continue;
        switch (si.kind) {
            .sealed, .interface_sealed, .polymorphic => try collectSealedLeaves(a, idx, si.path, out, seen),
            else => try out.append(a, sub.path),
        }
    }
}

fn genSealedFactory(w: *std.ArrayList(u8), a: Allocator, idx: *const Index, info: *const Info) Allocator.Error!void {
    const gn = try genNameFor(a, info);
    const serial = try serialNameOf(a, info);
    var leaves: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(a);
    try collectSealedLeaves(a, idx, info.path, &leaves, &seen);
    const subs: []const []const u8 = leaves.items;
    try wp(w, a, "val `{s}Cache`: KSerializer<{s}> by lazy {{ SealedClassSerializer(\"{s}\", {s}::class, arrayOf<KClass<out {s}>>(", .{ gn, info.path, serial, info.path, info.path });
    for (subs, 0..) |sp, n| {
        if (n > 0) try w.appendSlice(a, ", ");
        try wp(w, a, "{s}::class", .{sp});
    }
    try wp(w, a, "), arrayOf<KSerializer<out {s}>>(", .{info.path});
    for (subs, 0..) |sp, n| {
        if (n > 0) try w.appendSlice(a, ", ");
        // A generic leaf's type arguments are star-projected in the sealed
        // serializer: each binds the polymorphic `Any` serializer, as the
        // plugin emits.
        const leaf_tps: usize = if (idx.by_path.get(sp)) |li| li.type_params else 0;
        if (leaf_tps == 0) {
            try wp(w, a, "{s}.serializer()", .{sp});
        } else {
            try wp(w, a, "{s}.serializer(", .{sp});
            var ti: usize = 0;
            while (ti < leaf_tps) : (ti += 1) {
                if (ti != 0) try w.appendSlice(a, ", ");
                try w.appendSlice(a, "PolymorphicSerializer(Any::class)");
            }
            try w.appendSlice(a, ")");
        }
    }
    const sanns = try classAnnotationCalls(a, idx, info.path);
    if (sanns.len != 0) {
        try wp(w, a, "), arrayOf<Annotation>({s}", .{try joinCalls(a, sanns)});
    }
    try w.appendSlice(a, ")) }\n");
    try wp(w, a, "fun `{s}Impl`(): KSerializer<{s}> = `{s}Cache`\n\n", .{ gn, info.path, gn });
}

fn joinCalls(a: Allocator, calls: []const []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (calls, 0..) |c, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, c);
    }
    return out.toOwnedSlice(a);
}

fn genPolymorphicFactory(w: *std.ArrayList(u8), a: Allocator, idx: *const Index, info: *const Info) Allocator.Error!void {
    const gn = try genNameFor(a, info);
    const panns = try classAnnotationCalls(a, idx, info.path);
    if (panns.len == 0) {
        try wp(w, a, "val `{s}Cache`: KSerializer<{s}> by lazy {{ PolymorphicSerializer({s}::class) }}\nfun `{s}Impl`(): KSerializer<{s}> = `{s}Cache`\n\n", .{ gn, info.path, info.path, gn, info.path, gn });
    } else {
        try wp(w, a, "val `{s}Cache`: KSerializer<{s}> by lazy {{ PolymorphicSerializer({s}::class, arrayOf<Annotation>({s})) }}\nfun `{s}Impl`(): KSerializer<{s}> = `{s}Cache`\n\n", .{ gn, info.path, info.path, try joinCalls(a, panns), gn, info.path, gn });
    }
}

fn genObjectFactory(w: *std.ArrayList(u8), a: Allocator, idx: *const Index, info: *const Info) Allocator.Error!void {
    const gn = try genNameFor(a, info);
    const serial = try serialNameOf(a, info);
    const oanns = try classAnnotationCalls(a, idx, info.path);
    if (oanns.len == 0) {
        try wp(w, a, "val `{s}Cache`: KSerializer<{s}> by lazy {{ ObjectSerializer(\"{s}\", {s}) }}\nfun `{s}Impl`(): KSerializer<{s}> = `{s}Cache`\n\n", .{ gn, info.path, serial, info.path, gn, info.path, gn });
    } else {
        try wp(w, a, "val `{s}Cache`: KSerializer<{s}> by lazy {{ ObjectSerializer(\"{s}\", {s}, arrayOf<Annotation>({s})) }}\nfun `{s}Impl`(): KSerializer<{s}> = `{s}Cache`\n\n", .{ gn, info.path, serial, info.path, try joinCalls(a, oanns), gn, info.path, gn });
    }
}

fn genWithFactory(w: *std.ArrayList(u8), a: Allocator, g: *const Gen, info: *const Info) Allocator.Error!void {
    const gn = try genNameFor(a, info);
    if (g.type_params.len != 0) {
        // A generic class's custom serializer takes the type-argument
        // serializers, so the factory is a function of them (no cache).
        var tps: std.ArrayList(u8) = .empty;
        var params: std.ArrayList(u8) = .empty;
        for (g.type_params, 0..) |tp, i| {
            if (i != 0) {
                try tps.appendSlice(a, ", ");
                try params.appendSlice(a, ", ");
            }
            try tps.appendSlice(a, tp);
            try wp(&params, a, "typeSerial{d}: KSerializer<{s}>", .{ i, tp });
        }
        try wp(w, a, "fun <{s}> `{s}Impl`({s}): KSerializer<{s}<{s}>> = {s}\n\n", .{ tps.items, gn, params.items, info.path, tps.items, try g.customSerializerRef(info.with.?) });
        return;
    }
    try wp(w, a, "val `{s}Cache`: KSerializer<{s}> by lazy {{ {s} }}\nfun `{s}Impl`(): KSerializer<{s}> = `{s}Cache`\n\n", .{ gn, info.path, try g.customSerializerRef(info.with.?), gn, info.path, gn });
}

/// The member splice text for the class: a companion (or object member)
/// `serializer()` delegating to the generated top-level artifact.
fn genMemberSplice(a: Allocator, c: ?*const ast.Class, info: *const Info, kept: ?*const Info) Allocator.Error![]const u8 {
    const gn = try genNameFor(a, info);
    var out: std.ArrayList(u8) = .empty;
    // Mirror the class's nesting path (`class Outer { class Inner { … } }`)
    // so the parsed companion's identity derives from its real owner —
    // a shared wrapper name collided every generated companion onto one.
    var segs = std.mem.splitScalar(u8, info.path, '.');
    var depth: usize = 0;
    var last: []const u8 = info.name;
    var seg_list: std.ArrayList([]const u8) = .empty;
    while (segs.next()) |sg| try seg_list.append(a, sg);
    for (seg_list.items, 0..) |sg, i| {
        last = sg;
        if (i + 1 < seg_list.items.len) {
            try wp(&out, a, "class {s} {{ ", .{sg});
            depth += 1;
        }
    }
    if (info.is_object_decl) {
        // A kept object serializer is the builtin `ObjectSerializer`.
        if (kept != null) {
            try wp(&out, a, "object {s} {{ fun serializer(): KSerializer<{s}> = `{s}Impl`()\nval `$generatedSerializerCache`: KSerializer<{s}> by lazy {{ kotlinx.serialization.internal.ObjectSerializer(\"{s}\", {s}) }}\nfun generatedSerializer(): KSerializer<{s}> = `$generatedSerializerCache` }}", .{ last, info.path, gn, info.path, try serialNameOf(a, info), info.path, info.path });
        } else {
            try wp(&out, a, "object {s} {{ fun serializer(): KSerializer<{s}> = `{s}Impl`() }}", .{ last, info.path, gn });
        }
        var k: usize = 0;
        while (k < depth) : (k += 1) try out.appendSlice(a, " }");
        return out.toOwnedSlice(a);
    }
    try wp(&out, a, "class {s} {{ companion object {{ ", .{last});
    switch (info.kind) {
        .class => {
            if (c != null and c.?.type_params.len != 0) {
                try wp(&out, a, "fun {s} serializer({s}): KSerializer<{s}{s}> = `{s}`{s}({s})", .{
                    try typeParamList(a, c.?), try typeSerialParams(a, c.?), info.path, try typeParamList(a, c.?), gn, try typeParamList(a, c.?), try typeSerialArgs(a, c.?),
                });
            } else {
                try wp(&out, a, "fun serializer(): KSerializer<{s}> = `{s}`", .{ info.path, gn });
            }
        },
        .value_class => {
            if (c != null and c.?.type_params.len != 0) {
                try wp(&out, a, "fun {s} serializer({s}): KSerializer<{s}{s}> = `{s}`{s}({s})", .{
                    try typeParamList(a, c.?), try typeSerialParams(a, c.?), info.path, try typeParamList(a, c.?), gn, try typeParamList(a, c.?), try typeSerialArgs(a, c.?),
                });
            } else {
                try wp(&out, a, "fun serializer(): KSerializer<{s}> = `{s}`", .{ info.path, gn });
            }
        },
        else => {
            if (c != null and c.?.type_params.len != 0 and info.with != null) {
                // A generic class's custom serializer receives the
                // type-argument serializers.
                try wp(&out, a, "fun {s} serializer({s}): KSerializer<{s}{s}> = `{s}Impl`({s})", .{
                    try typeParamList(a, c.?), try typeSerialParams(a, c.?), info.path, try typeParamList(a, c.?), gn, try typeSerialArgs(a, c.?),
                });
            } else if (c != null and c.?.type_params.len != 0) {
                // A generic sealed/polymorphic/enum declaration still takes the
                // type-argument serializers (and ignores them), exactly as
                // the plugin's companion does.
                try wp(&out, a, "fun {s} serializer({s}): KSerializer<{s}{s}> = `{s}Impl`() as KSerializer<{s}{s}>", .{
                    try typeParamList(a, c.?), try typeSerialParams(a, c.?), info.path, try typeParamList(a, c.?), gn, info.path, try typeParamList(a, c.?),
                });
            } else {
                try wp(&out, a, "fun serializer(): KSerializer<{s}> = `{s}Impl`()", .{ info.path, gn });
            }
        },
    }
    if (kept) |ki| {
        const kn = try genNameFor(a, ki);
        switch (ki.kind) {
            .enum_class => try wp(&out, a, " fun generatedSerializer(): KSerializer<{s}> = `{s}Impl`()", .{ info.path, kn }),
            else => {
                if (c != null and c.?.type_params.len != 0) {
                    try wp(&out, a, " fun {s} generatedSerializer({s}): KSerializer<{s}{s}> = `{s}`{s}({s})", .{
                        try typeParamList(a, c.?), try typeSerialParams(a, c.?), info.path, try typeParamList(a, c.?), kn, try typeParamList(a, c.?), try typeSerialArgs(a, c.?),
                    });
                } else {
                    try wp(&out, a, " fun generatedSerializer(): KSerializer<{s}> = `{s}`", .{ info.path, kn });
                }
            },
        }
    }
    try out.appendSlice(a, " } }");
    var k2: usize = 0;
    while (k2 < depth) : (k2 += 1) try out.appendSlice(a, " }");
    return out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Parsing generated text + splicing
// ---------------------------------------------------------------------------

fn parseSnippet(a: Allocator, file: FileId, src: []const u8) ?ast.KotlinFile {
    var lx = lexer_mod.Lexer.init(a, file, src) catch return null;
    var lexed = lx.tokenize() catch return null;
    if (lexed.diagnostics.hasErrors()) return null;
    var p = parser_mod.Parser.new(a, file, src, lexed.tokens);
    const kf = p.parseFile();
    if (p.diagnostics.hasErrors()) {
        if (std.c.getenv("KLIO_SERIAL_DUMP") != null) {
            for (p.diagnostics.diags()) |d| std.debug.print("[serial-pass] parse error: {s}\n", .{d.message});
        }
        return null;
    }
    return kf;
}

fn findCompanion(members: []ast.Decl) ?*ast.Decl {
    // A companion parses as a `Class` decl with `is_companion` set.
    for (members) |*m| {
        switch (m.*) {
            .Class => |*c| if (c.is_companion) return m,
            else => {},
        }
    }
    return null;
}

fn appendMembers(a: Allocator, members: *[]ast.Decl, extra: []const ast.Decl) Allocator.Error!void {
    var list: std.ArrayList(ast.Decl) = .empty;
    try list.appendSlice(a, members.*);
    try list.appendSlice(a, extra);
    members.* = try list.toOwnedSlice(a);
}

fn companionMembers(d: *ast.Decl) *[]ast.Decl {
    return switch (d.*) {
        .Class => |*c| &c.members,
        .Object => |*o| &o.members,
        else => unreachable,
    };
}

/// Splice the parsed `__KlioSplice` members into the target class/object.
fn spliceInto(a: Allocator, target_members: *[]ast.Decl, is_object: bool, snippet: *ast.KotlinFile) Allocator.Error!void {
    if (snippet.decls.len == 0) return;
    var wrapper = &snippet.decls[0];
    // Descend outer wrapper classes down to the innermost one.
    while (wrapper.* == .Class and wrapper.Class.members.len == 1 and
        (wrapper.Class.members[0] == .Class and !wrapper.Class.members[0].Class.is_companion or wrapper.Class.members[0] == .Object))
    {
        wrapper = &wrapper.Class.members[0];
    }
    if (is_object) {
        if (wrapper.* != .Object) return;
        try appendMembers(a, target_members, wrapper.Object.members);
        return;
    }
    if (wrapper.* != .Class) return;
    // The wrapper's only member is the companion object; merge or add.
    if (findCompanion(target_members.*)) |existing| {
        const gen_comp = findCompanion(wrapper.Class.members) orelse return;
        try appendMembers(a, companionMembers(existing), companionMembers(gen_comp).*);
    } else {
        try appendMembers(a, target_members, wrapper.Class.members);
    }
}

fn starImport(a: Allocator, sp: Span, pkg: []const []const u8) Allocator.Error!ast.ImportDecl {
    const path = try a.alloc(ast.Ident, pkg.len);
    for (pkg, 0..) |seg, i| path[i] = .{ .name = seg, .span = sp };
    return .{ .path = path, .alias = null, .wildcard = true, .span = sp };
}

fn nameImport(a: Allocator, sp: Span, pkg: []const []const u8) Allocator.Error!ast.ImportDecl {
    const path = try a.alloc(ast.Ident, pkg.len);
    for (pkg, 0..) |seg, i| path[i] = .{ .name = seg, .span = sp };
    return .{ .path = path, .alias = null, .wildcard = false, .span = sp };
}

const Ctx = struct {
    a: Allocator,
    idx: *const Index,
    file: *ast.KotlinFile,
    pkg: []const u8,
    /// Accumulated generated top-level source for this file.
    gen: std.ArrayList(u8),
    generated_any: bool = false,
    /// Padding so snippet spans never collide with the file's real spans.
    pad: []const u8,
    /// Extra padding so successive snippets in one file never share
    /// offsets either (span-keyed registries would merge them).
    next_pad: usize = 0,
    settings: FileSettings,
};

/// The type a serializer declaration serializes: its `KSerializer<T>`
/// supertype argument head, resolved through the index.
fn serializerTargetHead(idx: *const Index, ser_path: []const u8) ?[]const u8 {
    const sups = idx.super_refs.get(ser_path) orelse return null;
    for (sups) |*st| {
        if (!std.mem.eql(u8, simpleHead(st.name.name), "KSerializer")) continue;
        if (st.type_args.len == 0 or st.type_args[0].is_star) continue;
        return simpleHead(st.type_args[0].ty.name.name);
    }
    return null;
}

fn fileSettings(a: Allocator, idx: *const Index, f: *const ast.KotlinFile) Allocator.Error!FileSettings {
    var fs = FileSettings{ .contextual = std.StringHashMap(void).init(a), .use_serializers = std.StringHashMap([]const u8).init(a) };
    for (f.file_annotations) |*an| {
        const n = annotationSimpleName(an);
        if (std.mem.eql(u8, n, "UseContextualSerialization")) {
            for (an.args) |*arg| {
                if (exprClassRef(a, arg)) |c| try fs.contextual.put(simpleHead(c), {});
            }
        } else if (std.mem.eql(u8, n, "UseSerializers")) {
            for (an.args) |*arg| {
                const c = exprClassRef(a, arg) orelse continue;
                // Resolve the serializer's path: as written, then by simple name.
                const ser_path: []const u8 = if (idx.super_refs.contains(c)) c else blk: {
                    var it = idx.super_refs.keyIterator();
                    while (it.next()) |k| {
                        if (std.mem.eql(u8, simpleHead(k.*), simpleHead(c))) break :blk k.*;
                    }
                    break :blk c;
                };
                if (serializerTargetHead(idx, ser_path)) |target| try fs.use_serializers.put(target, ser_path);
            }
        }
    }
    return fs;
}

fn snippetPadded(ctx: *Ctx, text: []const u8) Allocator.Error![]const u8 {
    const extra = try ctx.a.alloc(u8, ctx.next_pad);
    @memset(extra, ' ');
    ctx.next_pad += text.len + 64;
    return std.fmt.allocPrint(ctx.a, "{s}{s}{s}", .{ ctx.pad, extra, text });
}

/// A `@Serializable` LOCAL class (declared in a function body) gets the
/// same generated shapes as a top-level one, but every artifact lives
/// INSIDE the class as a nested member: the class is visible only in its
/// body's scope, so nothing at file level could name it. The record is
/// not entered into the index — two functions may declare same-named
/// locals, and no other declaration can reference a local class.
fn processFunctionLocals(ctx: *Ctx, f: *ast.Function) Allocator.Error!void {
    const dbg = std.c.getenv("KLIO_SERIAL_DUMP") != null;
    if (dbg) std.debug.print("[serial-pass] fn {s} body={s}\n", .{ f.name.name, if (f.body) |b| @tagName(std.meta.activeTag(b)) else "none" });
    const body = f.body orelse return;
    if (body != .Block) return;
    for (body.Block.stmts) |*st| {
        if (st.* != .Decl) continue;
        if (dbg) std.debug.print("[serial-pass] local decl in {s}: {s}\n", .{ f.name.name, @tagName(std.meta.activeTag(st.Decl)) });
        switch (st.Decl) {
            .Class => |*c| {
                if (companionForClassTarget(ctx.a, c.members) != null) continue;
                if (dbg) std.debug.print("[serial-pass] local class {s} serializable={}\n", .{ c.name.name, isSerializableIn(ctx.idx, c.annotations) });
                if (!isSerializableIn(ctx.idx, c.annotations)) continue;
                if (companionIsSerializer(c.members)) continue;
                const info = classInfo(ctx.idx, c, c.name.name, ctx.pkg);
                var tps: std.ArrayList([]const u8) = .empty;
                for (c.type_params) |*tp| try tps.append(ctx.a, tp.name.name);
                const g = Gen{ .a = ctx.a, .idx = ctx.idx, .pkg = ctx.pkg, .type_params = tps.items, .scope_path = c.name.name, .file = &ctx.settings };
                var local_gen: std.ArrayList(u8) = .empty;
                switch (info.kind) {
                    .class => try genClassSerializer(&local_gen, ctx.a, &g, c, &info),
                    .value_class => try genValueClassSerializer(&local_gen, ctx.a, &g, c, &info),
                    .enum_class => try genEnumFactory(&local_gen, ctx.a, ctx.idx, c, &info),
                    .with_custom => try genWithFactory(&local_gen, ctx.a, &g, &info),
                    .sealed, .interface_sealed, .polymorphic, .object => continue,
                }
                ctx.generated_any = true;
                const artifacts = try snippetPadded(ctx, local_gen.items);
                if (dbg) std.debug.print("[serial-pass] local artifacts for {s}:\n{s}\n", .{ c.name.name, local_gen.items });
                if (parseSnippet(ctx.a, ctx.file.span.file, artifacts)) |snip_val| {
                    if (dbg) std.debug.print("[serial-pass] local artifacts parsed: {d} decls\n", .{snip_val.decls.len});
                    try appendMembers(ctx.a, &c.members, snip_val.decls);
                } else if (dbg) std.debug.print("[serial-pass] local artifacts FAILED to parse\n", .{});
                const splice_src = try snippetPadded(ctx, try genMemberSplice(ctx.a, c, &info, null));
                if (parseSnippet(ctx.a, ctx.file.span.file, splice_src)) |snip_val| {
                    var snip = snip_val;
                    try spliceInto(ctx.a, &c.members, false, &snip);
                }
            },
            else => {},
        }
    }
}

fn processDecls(ctx: *Ctx, decls: []ast.Decl, outer: []const u8) Allocator.Error!void {
    for (decls) |*d| {
        switch (d.*) {
            .Class => |*c| {
                const path = joinPath(ctx.a, outer, c.name.name);
                try processDecls(ctx, c.members, path);
                // A companion annotated @Serializer(forClass = X::class) is
                // filled with X's generated body (splice + delegating members)
                // and answers `serializer()` with itself.
                if (companionForClassTarget(ctx.a, c.members)) |target_written| {
                    if (findCompanion(c.members)) |comp| {
                        try genForClassCompanion(ctx, comp, path, target_written);
                    }
                    continue;
                }
                if (!isSerializableIn(ctx.idx, c.annotations)) continue;
                const info = ctx.idx.by_path.get(path) orelse continue;
                // "Companion object as serializer": the companion implements
                // KSerializer<Self>, so it IS the serializer — no generated
                // `$serializer`; `serializer()` returns the companion.
                if (companionIsSerializer(c.members)) {
                    ctx.generated_any = true;
                    const splice_src = try snippetPadded(ctx, try genSelfSerializerSplice(ctx.a, &info));
                    if (parseSnippet(ctx.a, ctx.file.span.file, splice_src)) |snip_val| {
                        var snip = snip_val;
                        try spliceInto(ctx.a, &c.members, false, &snip);
                    }
                    continue;
                }
                var tps: std.ArrayList([]const u8) = .empty;
                for (c.type_params) |*tp| try tps.append(ctx.a, tp.name.name);
                const g = Gen{ .a = ctx.a, .idx = ctx.idx, .pkg = ctx.pkg, .type_params = tps.items, .scope_path = path, .file = &ctx.settings };
                switch (info.kind) {
                    .class => try genClassSerializer(&ctx.gen, ctx.a, &g, c, &info),
                    .value_class => try genValueClassSerializer(&ctx.gen, ctx.a, &g, c, &info),
                    .enum_class => try genEnumFactory(&ctx.gen, ctx.a, ctx.idx, c, &info),
                    .sealed, .interface_sealed => try genSealedFactory(&ctx.gen, ctx.a, ctx.idx, &info),
                    .polymorphic => try genPolymorphicFactory(&ctx.gen, ctx.a, ctx.idx, &info),
                    .with_custom => try genWithFactory(&ctx.gen, ctx.a, &g, &info),
                    .object => {},
                }
                // `@KeepGeneratedSerializer` beside a custom `with=`: the
                // plugin still emits the generated serializer, reachable
                // through the companion's `generatedSerializer()`.
                var kept_info: ?Info = null;
                if (info.kind == .with_custom and hasAnnotation(c.annotations, "KeepGeneratedSerializer")) {
                    var kept = info;
                    kept.with = null;
                    kept.gen_suffix = "$generatedSerializer";
                    kept.kind = if (c.is_value) .value_class else if (c.is_enum) .enum_class else .class;
                    if (info.is_object_decl) kept.kind = .object;
                    switch (kept.kind) {
                        .class => try genClassSerializer(&ctx.gen, ctx.a, &g, c, &kept),
                        .value_class => try genValueClassSerializer(&ctx.gen, ctx.a, &g, c, &kept),
                        .enum_class => try genEnumFactory(&ctx.gen, ctx.a, ctx.idx, c, &kept),
                        else => {},
                    }
                    kept_info = kept;
                }
                ctx.generated_any = true;
                const splice_src = try snippetPadded(ctx, try genMemberSplice(ctx.a, c, &info, if (kept_info) |*k| k else null));
                const parsed_splice = parseSnippet(ctx.a, ctx.file.span.file, splice_src);
                if (std.c.getenv("KLIO_SERIAL_DUMP") != null) std.debug.print("[serial-pass] member splice for {s} parsed={}:\n{s}\n", .{ path, parsed_splice != null, splice_src });
                if (parsed_splice) |snip_val| {
                    var snip = snip_val;
                    try spliceInto(ctx.a, &c.members, false, &snip);
                }
            },
            .Function => |*f| try processFunctionLocals(ctx, f),
            .Object => |*o| {
                const path = joinPath(ctx.a, outer, o.name.name);
                try processDecls(ctx, o.members, path);
                if (serializerForClassTarget(ctx.a, o.annotations)) |target_written| {
                    try genForClassObject(ctx, o, path, target_written);
                    continue;
                }
                if (!isSerializableIn(ctx.idx, o.annotations)) continue;
                const info = ctx.idx.by_path.get(path) orelse continue;
                const g = Gen{ .a = ctx.a, .idx = ctx.idx, .pkg = ctx.pkg, .type_params = &.{}, .scope_path = path, .file = &ctx.settings };
                switch (info.kind) {
                    .with_custom => try genWithFactory(&ctx.gen, ctx.a, &g, &info),
                    else => try genObjectFactory(&ctx.gen, ctx.a, ctx.idx, &info),
                }
                ctx.generated_any = true;
                // `@KeepGeneratedSerializer` on an object beside `with=`: the
                // kept serializer is the builtin object serializer.
                var kept_obj: ?Info = null;
                if (info.kind == .with_custom and hasAnnotation(o.annotations, "KeepGeneratedSerializer")) {
                    var kept = info;
                    kept.with = null;
                    kept.kind = .object;
                    kept_obj = kept;
                }
                const splice_src = try snippetPadded(ctx, try genMemberSplice(ctx.a, null, &info, if (kept_obj) |*k| k else null));
                if (parseSnippet(ctx.a, ctx.file.span.file, splice_src)) |snip_val| {
                    var snip = snip_val;
                    try spliceInto(ctx.a, &o.members, true, &snip);
                }
            },
            else => {},
        }
    }
}

/// Whether `members` holds a companion whose supertypes include
/// `KSerializer<…>` — the "companion object as serializer" pattern: the
/// plugin uses the companion itself as the class's serializer.
fn findCompanionConst(members: []const ast.Decl) ?*const ast.Decl {
    for (members) |*m| {
        switch (m.*) {
            .Class => |*c| if (c.is_companion) return m,
            else => {},
        }
    }
    return null;
}

fn companionIsSerializer(members: []const ast.Decl) bool {
    const comp = findCompanionConst(members) orelse return false;
    for (comp.Class.supertypes) |*st| {
        if (std.mem.eql(u8, simpleHead(st.name.name), "KSerializer")) return true;
    }
    return false;
}

/// A companion annotated `@Serializer(forClass = X::class)`, if any.
fn companionForClassTarget(a: Allocator, members: []const ast.Decl) ?[]const u8 {
    const comp = findCompanionConst(members) orelse return null;
    return serializerForClassTarget(a, comp.Class.annotations);
}

/// `@Serializer(forClass = X::class)` target as written, if any.
fn serializerForClassTarget(a: Allocator, annotations: []const ast.Annotation) ?[]const u8 {
    const an = findAnnotation(annotations, "Serializer") orelse return null;
    for (an.args) |*arg| {
        if (exprClassRef(a, arg)) |c| return c;
    }
    return null;
}

/// Fill a `@Serializer(forClass = X::class)` object with X's generated
/// serializer members (the plugin does exactly this for a bodiless
/// object). The object keeps its own name and supertypes; the body text is
/// parsed as a wrapper object and its members spliced in.
fn genForClassObject(ctx: *Ctx, o: *ast.ObjectDecl, obj_path: []const u8, target_written: []const u8) Allocator.Error!void {
    const a = ctx.a;
    const scope = if (std.mem.lastIndexOfScalar(u8, obj_path, '.')) |d| obj_path[0..d] else "";
    var g0 = Gen{ .a = a, .idx = ctx.idx, .pkg = ctx.pkg, .type_params = &.{}, .scope_path = obj_path };
    const target_path = try g0.qualify(target_written);
    _ = scope;
    const c = ctx.idx.class_nodes.get(target_path) orelse return;
    const info = ctx.idx.by_path.get(target_path) orelse Info{
        .name = c.name.name,
        .path = target_path,
        .pkg = ctx.pkg,
        .kind = .class,
        .type_params = c.type_params.len,
    };
    var tps: std.ArrayList([]const u8) = .empty;
    for (c.type_params) |*tp| try tps.append(a, tp.name.name);
    const g = Gen{ .a = a, .idx = ctx.idx, .pkg = ctx.pkg, .type_params = tps.items, .scope_path = target_path, .file = &ctx.settings };
    var body: std.ArrayList(u8) = .empty;
    try wp(&body, a, "object {s} : GeneratedSerializer<{s}> {{\n", .{o.name.name, info.path});
    try genClassSerializerBody(&body, a, &g, c, &info);
    try body.appendSlice(a, "}\n");
    // The body references the serialization surface by simple name, so it
    // lives in the synthetic sibling file's import scope: emit it there as
    // a top-level object `<Obj>$forClass` and delegate the object's members.
    const impl_name = try std.fmt.allocPrint(a, "{s}$forClass", .{try genName(a, obj_path)});
    try wp(&ctx.gen, a, "object `{s}` : GeneratedSerializer<{s}> {{\n", .{ impl_name, info.path });
    try genClassSerializerBody(&ctx.gen, a, &g, c, &info);
    try ctx.gen.appendSlice(a, "}\n\n");
    ctx.generated_any = true;
    const splice = try std.fmt.allocPrint(a,
        "object {s} {{ override val descriptor: kotlinx.serialization.descriptors.SerialDescriptor get() = `{s}`.descriptor\n" ++
            "override fun serialize(encoder: kotlinx.serialization.encoding.Encoder, value: {s}) = `{s}`.serialize(encoder, value)\n" ++
            "override fun deserialize(decoder: kotlinx.serialization.encoding.Decoder): {s} = `{s}`.deserialize(decoder) }}",
        .{ o.name.name, impl_name, info.path, impl_name, info.path, impl_name });
    const splice_src = try snippetPadded(ctx, splice);
    if (parseSnippet(a, ctx.file.span.file, splice_src)) |snip_val| {
        var snip = snip_val;
        try spliceInto(a, &o.members, true, &snip);
    }
}

/// `companion object { fun serializer(): KSerializer<C> = this }` wrapped in
/// the class's real nesting path (same splice shape as genMemberSplice).
fn genSelfSerializerSplice(a: Allocator, info: *const Info) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var segs = std.mem.splitScalar(u8, info.path, '.');
    var seg_list: std.ArrayList([]const u8) = .empty;
    while (segs.next()) |sg| try seg_list.append(a, sg);
    var depth: usize = 0;
    var last: []const u8 = info.name;
    for (seg_list.items, 0..) |sg, i| {
        last = sg;
        if (i + 1 < seg_list.items.len) {
            try wp(&out, a, "class {s} {{ ", .{sg});
            depth += 1;
        }
    }
    try wp(&out, a, "class {s} {{ companion object {{ fun serializer(): KSerializer<{s}> = this }} }}", .{ last, info.path });
    var k: usize = 0;
    while (k < depth) : (k += 1) try out.appendSlice(a, " }");
    return out.toOwnedSlice(a);
}

/// A companion annotated `@Serializer(forClass = X::class)`: emit X's
/// generated serializer as a top-level object in the synthetic file and
/// splice delegating members plus `serializer() = this` into the companion.
fn genForClassCompanion(ctx: *Ctx, comp: *ast.Decl, class_path: []const u8, target_written: []const u8) Allocator.Error!void {
    const a = ctx.a;
    var g0 = Gen{ .a = a, .idx = ctx.idx, .pkg = ctx.pkg, .type_params = &.{}, .scope_path = class_path };
    const target_path = try g0.qualify(target_written);
    const c = ctx.idx.class_nodes.get(target_path) orelse return;
    const info = ctx.idx.by_path.get(target_path) orelse Info{
        .name = c.name.name,
        .path = target_path,
        .pkg = ctx.pkg,
        .kind = .class,
        .type_params = c.type_params.len,
    };
    var tps: std.ArrayList([]const u8) = .empty;
    for (c.type_params) |*tp| try tps.append(a, tp.name.name);
    const g = Gen{ .a = a, .idx = ctx.idx, .pkg = ctx.pkg, .type_params = tps.items, .scope_path = target_path, .file = &ctx.settings };
    const impl_name = try std.fmt.allocPrint(a, "{s}$forClass", .{try genName(a, class_path)});
    try wp(&ctx.gen, a, "object `{s}` : GeneratedSerializer<{s}> {{\n", .{ impl_name, info.path });
    try genClassSerializerBody(&ctx.gen, a, &g, c, &info);
    try ctx.gen.appendSlice(a, "}\n\n");
    ctx.generated_any = true;
    var out: std.ArrayList(u8) = .empty;
    var segs = std.mem.splitScalar(u8, class_path, '.');
    var seg_list: std.ArrayList([]const u8) = .empty;
    while (segs.next()) |sg| try seg_list.append(a, sg);
    var depth: usize = 0;
    var last: []const u8 = class_path;
    for (seg_list.items, 0..) |sg, i| {
        last = sg;
        if (i + 1 < seg_list.items.len) {
            try wp(&out, a, "class {s} {{ ", .{sg});
            depth += 1;
        }
    }
    // `@KeepGeneratedSerializer` beside a `@Serializer(forClass)` companion:
    // the generated body IS the kept serializer.
    const kept_member: []const u8 = if (hasAnnotation(c.annotations, "KeepGeneratedSerializer"))
        try std.fmt.allocPrint(a, "\nfun generatedSerializer(): kotlinx.serialization.KSerializer<{s}> = `{s}`", .{ info.path, impl_name })
    else
        "";
    try wp(&out, a,
        "class {s} {{ companion object {{ fun serializer(): kotlinx.serialization.KSerializer<{s}> = this\n" ++
            "override val descriptor: kotlinx.serialization.descriptors.SerialDescriptor get() = `{s}`.descriptor\n" ++
            "override fun serialize(encoder: kotlinx.serialization.encoding.Encoder, value: {s}) = `{s}`.serialize(encoder, value)\n" ++
            "override fun deserialize(decoder: kotlinx.serialization.encoding.Decoder): {s} = `{s}`.deserialize(decoder){s} }} }}",
        .{ last, info.path, impl_name, info.path, impl_name, info.path, impl_name, kept_member });
    var k: usize = 0;
    while (k < depth) : (k += 1) try out.appendSlice(a, " }");
    const splice_src = try snippetPadded(ctx, out.items);
    if (parseSnippet(a, ctx.file.span.file, splice_src)) |snip_val| {
        var snip = snip_val;
        // Merge into the existing companion (comp is that companion).
        const wrapper = innermostWrapper(&snip);
        if (wrapper) |w| {
            if (w.* == .Class) {
                if (findCompanion(w.Class.members)) |gen_comp| {
                    try appendMembers(a, companionMembers(comp), companionMembers(gen_comp).*);
                }
            }
        }
    }
}

fn innermostWrapper(snippet: *ast.KotlinFile) ?*ast.Decl {
    if (snippet.decls.len == 0) return null;
    var wrapper = &snippet.decls[0];
    while (wrapper.* == .Class and wrapper.Class.members.len == 1 and
        (wrapper.Class.members[0] == .Class and !wrapper.Class.members[0].Class.is_companion or wrapper.Class.members[0] == .Object))
    {
        wrapper = &wrapper.Class.members[0];
    }
    return wrapper;
}

/// Synthetic file id allocation: the generated sibling files get ids
/// beyond any real file so their spans never alias a real declaration.
var next_synthetic_file: u32 = 0x4000_0000;

const gen_imports = [_][]const []const u8{
    &.{ "kotlinx", "serialization" },
    &.{ "kotlinx", "serialization", "internal" },
    &.{ "kotlinx", "serialization", "builtins" },
    &.{ "kotlinx", "serialization", "descriptors" },
    &.{ "kotlinx", "serialization", "encoding" },
    &.{ "kotlinx", "serialization", "modules" },
    &.{ "kotlin", "reflect" },
    &.{ "kotlin", "time" },
};

/// Transform every file: returns a new slice holding the (possibly
/// patched) originals followed by one generated sibling file per original
/// that declared serializable classes. Copies are shallow — decl arrays
/// are replaced, never mutated in place, so the caller's originals stay
/// structurally valid.
pub fn transformFiles(a: Allocator, files_in: []const ast.KotlinFile) Allocator.Error![]ast.KotlinFile {
    // Fast exit: nothing serializable anywhere.
    var any = false;
    for (files_in) |*f| {
        if (fileMentionsSerializable(f)) {
            any = true;
            break;
        }
    }
    if (!any) {
        const out = try a.alloc(ast.KotlinFile, files_in.len);
        @memcpy(out, files_in);
        return out;
    }
    var idx = Index.init(a);
    active_index = &idx;
    defer active_index = null;
    // Top-level string constants first: an annotation argument in any
    // file may reference a `const val` declared in another.
    for (files_in) |*f| {
        for (f.decls) |*d| {
            if (d.* != .Property) continue;
            const p = d.Property;
            if (!p.is_const) continue;
            const ini = p.init orelse continue;
            if (exprStringLiteral(&ini)) |txt| try idx.const_strings.put(p.name.name, txt);
        }
    }
    for (files_in) |*f| try indexAnnotationClasses(&idx, f.decls);
    for (files_in) |*f| {
        try indexDecls(&idx, f.decls, "", packageText(a, f));
    }
    // Resolve each subclass record's supertype to a declaration PATH (the
    // subclass's enclosing scopes first, then top level) so two files'
    // same-named sealed parents keep separate subclass lists.
    for (idx.sub_records.items) |rec| {
        const parent_path: ?[]const u8 = blk: {
            var scope = rec.scope;
            while (true) {
                const cand = if (scope.len == 0) rec.sup_head else try std.fmt.allocPrint(a, "{s}.{s}", .{ scope, rec.sup_head });
                if (idx.all_paths.contains(cand)) break :blk cand;
                if (scope.len == 0) break;
                scope = if (std.mem.lastIndexOfScalar(u8, scope, '.')) |d| scope[0..d] else "";
            }
            // A dotted supertype written from the top (`Outer.Base`).
            if (idx.all_paths.contains(rec.sup_head)) break :blk rec.sup_head;
            break :blk null;
        };
        const pp = parent_path orelse continue;
        const gop = try idx.sealed_subs.getOrPut(pp);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, .{ .path = rec.sub_path });
    }
    var out: std.ArrayList(ast.KotlinFile) = .empty;
    try out.appendSlice(a, files_in);
    const dump = std.c.getenv("KLIO_SERIAL_DUMP") != null;
    for (out.items[0..files_in.len]) |*f| {
        if (dump) std.debug.print("[serial-pass] file {} mentions={}\n", .{ f.span.file, fileMentionsSerializable(f) });
        if (!fileMentionsSerializable(f)) continue;
        // Work on a copy of the decl array so the original stays intact.
        const decls_copy = try a.alloc(ast.Decl, f.decls.len);
        @memcpy(decls_copy, f.decls);
        f.decls = decls_copy;
        const pad = try a.alloc(u8, f.span.end + 16);
        @memset(pad, ' ');
        var ctx = Ctx{ .a = a, .idx = &idx, .file = f, .pkg = packageText(a, f), .gen = .empty, .pad = pad, .settings = try fileSettings(a, &idx, f) };
        try processDecls(&ctx, f.decls, "");
        if (!ctx.generated_any) continue;
        // The generated sibling file.
        var src: std.ArrayList(u8) = .empty;
        if (ctx.pkg.len != 0) try wp(&src, a, "package {s}\n\n", .{ctx.pkg});
        // Carry the original file's imports (so user types referenced by
        // the generated code resolve exactly as they do in the class), then
        // the serialization surface.
        for (f.imports) |*imp| {
            if (sourceOf(imp.span)) |txt| {
                try wp(&src, a, "{s}\n", .{txt});
            }
        }
        for (gen_imports) |pkg| {
            try src.appendSlice(a, "import ");
            for (pkg, 0..) |seg, i| {
                if (i > 0) try src.appendSlice(a, ".");
                try src.appendSlice(a, seg);
            }
            try src.appendSlice(a, ".*\n");
        }
        try src.appendSlice(a, "\n");
        try src.appendSlice(a, ctx.gen.items);
        if (dump) std.debug.print("[serial-pass] generated for file {d}:\n{s}\n", .{ f.span.file.int(), src.items });
        const fid = FileId.from(next_synthetic_file);
        next_synthetic_file += 1;
        // Register the synthetic source so spans/diagnostics inside it read.
        if (span_mod.active_map) |m| {
            const mm: *span_mod.SourceMap = @constCast(m);
            _ = mm.addBorrowed(try std.fmt.allocPrint(a, "<generated-serializers-{d}>", .{fid.int()}), src.items) catch {};
        }
        if (parseSnippet(a, fid, src.items)) |gf| {
            try out.append(a, gf);
        } else if (dump) {
            std.debug.print("[serial-pass] generated file failed to parse; dropped\n", .{});
        }
    }
    return out.toOwnedSlice(a);
}

fn fileMentionsSerializable(f: *const ast.KotlinFile) bool {
    return declsMentionSerializable(f.decls);
}

fn declsMentionSerializable(decls: []const ast.Decl) bool {
    for (decls) |*d| {
        switch (d.*) {
            .Class => |*c| {
                if (isSerializableLiteral(c.annotations) or c.is_annotation) return true;
                if (declsMentionSerializable(c.members)) return true;
            },
            .Object => |*o| {
                if (isSerializableLiteral(o.annotations)) return true;
                if (declsMentionSerializable(o.members)) return true;
            },
            // A LOCAL class in a function body.
            .Function => |*f| {
                const body = f.body orelse continue;
                if (body != .Block) continue;
                for (body.Block.stmts) |*st| {
                    if (st.* != .Decl) continue;
                    if (declsMentionSerializable(@as([*]const ast.Decl, @ptrCast(&st.Decl))[0..1])) return true;
                }
            },
            else => {},
        }
    }
    return false;
}

test "genName mangles nested paths" {
    const a = std.testing.allocator;
    const n = try genName(a, "Outer.Inner");
    defer a.free(n);
    try std.testing.expectEqualStrings("Outer_Inner$serializer", n);
}
