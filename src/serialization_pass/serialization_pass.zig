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
};

const SealedSub = struct { path: []const u8 };

const Index = struct {
    a: Allocator,
    by_name: std.StringHashMap(Info),
    /// Sealed parent simple name -> ordered subclass paths.
    sealed_subs: std.StringHashMap(std.ArrayList(SealedSub)),
    /// Every `object` declaration path (for `with = X::class` object-vs-class).
    objects: std.StringHashMap(void),

    fn init(a: Allocator) Index {
        return .{
            .a = a,
            .by_name = std.StringHashMap(Info).init(a),
            .sealed_subs = std.StringHashMap(std.ArrayList(SealedSub)).init(a),
            .objects = std.StringHashMap(void).init(a),
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

fn exprStringLiteral(e: *const ast.Expr) ?[]const u8 {
    switch (e.*) {
        .StringTemplate => |st| {
            if (st.parts.len == 0) return "";
            if (st.parts.len == 1 and st.parts[0] == .Text) return st.parts[0].Text;
            return null;
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

fn isSerializable(annotations: []const ast.Annotation) bool {
    return hasAnnotation(annotations, "Serializable");
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

fn indexDecls(idx: *Index, decls: []const ast.Decl, outer: []const u8, pkg: []const u8) Allocator.Error!void {
    for (decls) |*d| {
        switch (d.*) {
            .Class => |*c| {
                const path = joinPath(idx.a, outer, c.name.name);
                if (isSerializable(c.annotations)) {
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
                    try idx.by_name.put(c.name.name, .{
                        .name = c.name.name,
                        .path = path,
                        .pkg = pkg,
                        .kind = kind,
                        .type_params = c.type_params.len,
                        .with = with,
                        .serial_name = sn,
                    });
                }
                // Sealed-parent registration: any class naming a supertype
                // that is (or turns out to be) a sealed serializable class.
                for (c.supertypes) |*st| {
                    const parent = simpleHead(st.name.name);
                    const gop = try idx.sealed_subs.getOrPut(parent);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(idx.a, .{ .path = path });
                }
                try indexDecls(idx, c.members, path, pkg);
            },
            .Object => |*o| {
                const path = joinPath(idx.a, outer, o.name.name);
                try idx.objects.put(path, {});
                try idx.objects.put(o.name.name, {});
                if (isSerializable(o.annotations)) {
                    const with = serializableWith(idx.a, o.annotations);
                    const sn: ?[]const u8 = if (findAnnotation(o.annotations, "SerialName")) |an| annotationStringArg(an) else null;
                    try idx.by_name.put(o.name.name, .{
                        .name = o.name.name,
                        .path = path,
                        .pkg = pkg,
                        .kind = if (with != null) .with_custom else .object,
                        .type_params = 0,
                        .with = with,
                        .serial_name = sn,
                        .is_object_decl = true,
                    });
                }
                for (o.supertypes) |*st| {
                    const parent = simpleHead(st.name.name);
                    const gop = try idx.sealed_subs.getOrPut(parent);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(idx.a, .{ .path = path });
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

const Gen = struct {
    a: Allocator,
    idx: *const Index,
    /// Type parameter names of the class being generated (index = typeSerial<i>).
    type_params: []const []const u8,

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
            try out.appendSlice(self.a, t.name.name);
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
        return self.serializerExpr(&t.type_args[i].ty, &.{});
    }

    fn serializerExprNonNull(self: *const Gen, t: *const ast.TypeRef, annotations: []const ast.Annotation) Allocator.Error![]const u8 {
        const a = self.a;
        if (serializableWith(a, annotations)) |w| return self.customSerializerRef(w);
        const head = simpleHead(t.name.name);
        if (hasAnnotation(annotations, "Contextual")) {
            return std.fmt.allocPrint(a, "ContextualSerializer({s}::class, null, arrayOf())", .{head});
        }
        if (hasAnnotation(annotations, "Polymorphic")) {
            return std.fmt.allocPrint(a, "PolymorphicSerializer({s}::class)", .{head});
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
            const elem_head = if (t.type_args.len != 0 and !t.type_args[0].is_star) simpleHead(t.type_args[0].ty.name.name) else "Any";
            return std.fmt.allocPrint(a, "ArraySerializer({s}::class, {s})", .{ elem_head, try self.typeArgSerializer(t, 0) });
        }
        if (eq(u8, head, "IntArray") or eq(u8, head, "LongArray") or eq(u8, head, "ShortArray") or eq(u8, head, "ByteArray") or
            eq(u8, head, "CharArray") or eq(u8, head, "FloatArray") or eq(u8, head, "DoubleArray") or eq(u8, head, "BooleanArray") or
            eq(u8, head, "UIntArray") or eq(u8, head, "ULongArray") or eq(u8, head, "UByteArray") or eq(u8, head, "UShortArray"))
        {
            return std.fmt.allocPrint(a, "{s}Serializer()", .{head});
        }
        // A user type: its companion `serializer(...)`, with type-argument
        // serializers for a generic one.
        if (t.type_args.len != 0) {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(a, t.name.name);
            try out.appendSlice(a, ".serializer(");
            for (t.type_args, 0..) |_, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try out.appendSlice(a, try self.typeArgSerializer(t, i));
            }
            try out.append(a, ')');
            return out.toOwnedSlice(a);
        }
        return std.fmt.allocPrint(a, "{s}.serializer()", .{t.name.name});
    }

    /// `S` for an object serializer, `S()` for a class serializer.
    fn customSerializerRef(self: *const Gen, w: []const u8) Allocator.Error![]const u8 {
        if (self.idx.objects.contains(w) or self.idx.objects.contains(simpleHead(w))) return w;
        return std.fmt.allocPrint(self.a, "{s}()", .{w});
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
};

fn encodeDefaultMode(annotations: []const ast.Annotation) @TypeOf(@as(Elem, undefined).encode_default) {
    const an = findAnnotation(annotations, "EncodeDefault") orelse return .unset;
    if (an.args.len == 0) return .always;
    if (exprPathText(std.heap.page_allocator, &an.args[0])) |p| {
        if (std.mem.endsWith(u8, p, "NEVER")) return .never;
    }
    return .always;
}

fn collectElems(a: Allocator, c: *const ast.Class) Allocator.Error![]Elem {
    var out: std.ArrayList(Elem) = .empty;
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
        // Backing field: an initializer, a lateinit, or a plain declaration
        // without a custom getter / delegate.
        const has_field = p.init != null or p.is_lateinit or (p.getter == null and p.delegate == null);
        if (!has_field) continue;
        if (p.delegate != null) continue;
        if (p.ty == null) continue;
        // Point INTO the AST (the property is boxed, so this outlives the loop).
        const ty: *const ast.TypeRef = &p.ty.?;
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
    const elems = try collectElems(a, c);
    if (elems.len > 32) return; // beyond one seen-mask: not generated (recorded limitation)
    const gn = try genName(a, info.path);
    const serial = try serialNameOf(a, info);
    const tps = try typeParamList(a, c);
    const self_ty = try std.fmt.allocPrint(a, "{s}{s}", .{ info.path, tps });
    const generic = c.type_params.len != 0;
    if (generic) {
        try wp(w, a, "class `{s}`{s}({s}) : GeneratedSerializer<{s}> {{\n", .{ gn, tps, try typeSerialParams(a, c), self_ty });
    } else {
        try wp(w, a, "object `{s}` : GeneratedSerializer<{s}> {{\n", .{ gn, self_ty });
    }
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
            if (sourceOf(an.span)) |txt| {
                // `@Foo(args)` -> `Foo(args)` (annotation classes are
                // constructible like classes).
                const body = if (txt.len > 0 and txt[0] == '@') txt[1..] else txt;
                const call = if (std.mem.indexOfScalar(u8, body, '(') == null) try std.fmt.allocPrint(a, "{s}()", .{body}) else body;
                try wp(w, a, "        `$dd`.pushAnnotation({s})\n", .{call});
            }
        }
    }
    for (c.annotations) |*an| {
        const n = annotationSimpleName(an);
        if (std.mem.eql(u8, n, "Serializable") or std.mem.eql(u8, n, "SerialName") or std.mem.eql(u8, n, "OptIn") or
            std.mem.eql(u8, n, "Suppress") or std.mem.eql(u8, n, "Polymorphic")) continue;
        if (sourceOf(an.span)) |txt| {
            const body = if (txt.len > 0 and txt[0] == '@') txt[1..] else txt;
            const call = if (std.mem.indexOfScalar(u8, body, '(') == null) try std.fmt.allocPrint(a, "{s}()", .{body}) else body;
            try wp(w, a, "        `$dd`.pushClassAnnotation({s})\n", .{call});
        }
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
        const p = if (e.ty.nullable) Prim.none else primOf(simpleHead(e.ty.name.name));
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
    try w.appendSlice(a, "        val `$d` = descriptor\n        val `$c` = decoder.beginStructure(`$d`)\n        var `$seen` = 0\n");
    for (elems, 0..) |*e, i| {
        const p = if (e.ty.nullable) Prim.none else primOf(simpleHead(e.ty.name.name));
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
        const p = if (e.ty.nullable) Prim.none else primOf(simpleHead(e.ty.name.name));
        const bit: u32 = @as(u32, 1) << @intCast(i);
        const st = if (p != .none)
            try std.fmt.allocPrint(a, "`$v{d}` = `$c`.decode{s}Element(`$d`, {d}); `$seen` = `$seen` or {d}", .{ i, primSuffix(p), i, bit })
        else if (e.ty.nullable)
            try std.fmt.allocPrint(a, "`$v{d}` = `$c`.decodeNullableSerializableElement(`$d`, {d}, {s}, `$v{d}`); `$seen` = `$seen` or {d}", .{ i, i, try g.serializerExprNonNull(e.ty, e.annotations), i, bit })
        else
            try std.fmt.allocPrint(a, "`$v{d}` = `$c`.decodeSerializableElement(`$d`, {d}, {s}, `$v{d}`); `$seen` = `$seen` or {d}", .{ i, i, try g.serializerExpr(e.ty, e.annotations), i, bit });
        try dec_stmts.append(a, st);
    }
    try w.appendSlice(a, "        if (`$c`.decodeSequentially()) {\n");
    for (dec_stmts.items) |st| try wp(w, a, "            {s}\n", .{st});
    try w.appendSlice(a, "        } else {\n            while (true) {\n                val `$index` = `$c`.decodeElementIndex(`$d`)\n                if (`$index` == -1) break\n                when (`$index`) {\n");
    for (dec_stmts.items, 0..) |st, i| try wp(w, a, "                    {d} -> {{ {s} }}\n", .{ i, st });
    try w.appendSlice(a, "                    else -> throw UnknownFieldException(`$index`)\n                }\n            }\n        }\n        `$c`.endStructure(`$d`)\n");
    // Missing-field check over the required elements.
    var golden: u32 = 0;
    for (elems, 0..) |*e, i| {
        if (!elemOptional(e)) golden |= @as(u32, 1) << @intCast(i);
    }
    if (golden != 0) {
        try wp(w, a, "        if ((`$seen` and {d}) != {d}) throwMissingFieldException(`$seen`, {d}, `$d`)\n", .{ golden, golden, golden });
    }
    // Construction: constructor properties with their defaults re-evaluated
    // in declaration order (shadowing so defaults can reference earlier
    // properties), then body properties assigned when seen.
    try w.appendSlice(a, "        return run {\n");
    for (elems, 0..) |*e, i| {
        if (!e.in_ctor) continue;
        const tt = try g.typeText(e.ty);
        const bit: u32 = @as(u32, 1) << @intCast(i);
        const val_expr = if (e.ty.nullable) try std.fmt.allocPrint(a, "`$v{d}`", .{i}) else blk: {
            const p = primOf(simpleHead(e.ty.name.name));
            break :blk if (p != .none) try std.fmt.allocPrint(a, "`$v{d}`", .{i}) else try std.fmt.allocPrint(a, "`$v{d}`!!", .{i});
        };
        if (e.default_text) |dflt| {
            try wp(w, a, "            val {s}: {s} = if ((`$seen` and {d}) == 0) ({s}) else {s}\n", .{ e.name, tt, bit, dflt, val_expr });
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
        const bit: u32 = @as(u32, 1) << @intCast(i);
        const val_expr = if (e.ty.nullable) try std.fmt.allocPrint(a, "`$v{d}`", .{i}) else blk: {
            const p = primOf(simpleHead(e.ty.name.name));
            break :blk if (p != .none) try std.fmt.allocPrint(a, "`$v{d}`", .{i}) else try std.fmt.allocPrint(a, "`$v{d}`!!", .{i});
        };
        try wp(w, a, "            if ((`$seen` and {d}) != 0) `$inst`.{s} = {s}\n", .{ bit, e.name, val_expr });
    }
    try w.appendSlice(a, "            `$inst`\n        }\n    }\n}\n\n");
}

/// Value class: one inline element.
fn genValueClassSerializer(w: *std.ArrayList(u8), a: Allocator, g: *const Gen, c: *const ast.Class, info: *const Info) Allocator.Error!void {
    const elems = try collectElems(a, c);
    if (elems.len != 1) return;
    const e = &elems[0];
    const gn = try genName(a, info.path);
    const serial = try serialNameOf(a, info);
    const p = if (e.ty.nullable) Prim.none else primOf(simpleHead(e.ty.name.name));
    try wp(w, a, "object `{s}` : GeneratedSerializer<{s}> {{\n", .{ gn, info.path });
    try wp(w, a, "    override val descriptor: SerialDescriptor = InlineClassDescriptor(\"{s}\", this).also {{ `$dd` -> `$dd`.addElement(\"{s}\", false) }}\n", .{ serial, e.serial_name });
    try wp(w, a, "    override fun childSerializers(): Array<KSerializer<*>> = arrayOf<KSerializer<*>>({s})\n", .{try g.serializerExpr(e.ty, e.annotations)});
    try wp(w, a, "    override fun serialize(encoder: Encoder, value: {s}) {{\n        val `$inl` = encoder.encodeInline(descriptor)\n", .{info.path});
    if (p != .none) {
        try wp(w, a, "        `$inl`.encode{s}(value.{s})\n", .{ primSuffix(p), e.name });
    } else if (e.ty.nullable) {
        try wp(w, a, "        `$inl`.encodeNullableSerializableValue({s}, value.{s})\n", .{ try g.serializerExprNonNull(e.ty, e.annotations), e.name });
    } else {
        try wp(w, a, "        `$inl`.encodeSerializableValue({s}, value.{s})\n", .{ try g.serializerExpr(e.ty, e.annotations), e.name });
    }
    try w.appendSlice(a, "    }\n");
    try wp(w, a, "    override fun deserialize(decoder: Decoder): {s} {{\n        val `$inl` = decoder.decodeInline(descriptor)\n", .{info.path});
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
fn genEnumFactory(w: *std.ArrayList(u8), a: Allocator, c: *const ast.Class, info: *const Info) Allocator.Error!void {
    const gn = try genName(a, info.path);
    const serial = try serialNameOf(a, info);
    var marked = false;
    for (c.enum_entries) |*en| {
        if (en.annotations.len != 0) marked = true;
    }
    if (!marked) {
        try wp(w, a, "fun `{s}Impl`(): KSerializer<{s}> = createSimpleEnumSerializer(\"{s}\", enumValues<{s}>())\n\n", .{ gn, info.path, serial, info.path });
        return;
    }
    try wp(w, a, "fun `{s}Impl`(): KSerializer<{s}> = createMarkedEnumSerializer(\"{s}\", enumValues<{s}>(), arrayOf<String?>(", .{ gn, info.path, serial, info.path });
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
    try w.appendSlice(a, "))\n\n");
}

fn genSealedFactory(w: *std.ArrayList(u8), a: Allocator, idx: *const Index, info: *const Info) Allocator.Error!void {
    const gn = try genName(a, info.path);
    const serial = try serialNameOf(a, info);
    const subs: []const SealedSub = if (idx.sealed_subs.get(info.name)) |l| l.items else &.{};
    try wp(w, a, "fun `{s}Impl`(): KSerializer<{s}> = SealedClassSerializer(\"{s}\", {s}::class, arrayOf<KClass<out {s}>>(", .{ gn, info.path, serial, info.path, info.path });
    var n: usize = 0;
    for (subs) |s| {
        if (idx.by_name.get(simpleHead(s.path)) == null) continue;
        if (n > 0) try w.appendSlice(a, ", ");
        try wp(w, a, "{s}::class", .{s.path});
        n += 1;
    }
    try wp(w, a, "), arrayOf<KSerializer<out {s}>>(", .{info.path});
    n = 0;
    for (subs) |s| {
        if (idx.by_name.get(simpleHead(s.path)) == null) continue;
        if (n > 0) try w.appendSlice(a, ", ");
        try wp(w, a, "{s}.serializer()", .{s.path});
        n += 1;
    }
    try w.appendSlice(a, "))\n\n");
}

fn genPolymorphicFactory(w: *std.ArrayList(u8), a: Allocator, info: *const Info) Allocator.Error!void {
    const gn = try genName(a, info.path);
    try wp(w, a, "fun `{s}Impl`(): KSerializer<{s}> = PolymorphicSerializer({s}::class)\n\n", .{ gn, info.path, info.path });
}

fn genObjectFactory(w: *std.ArrayList(u8), a: Allocator, info: *const Info) Allocator.Error!void {
    const gn = try genName(a, info.path);
    const serial = try serialNameOf(a, info);
    try wp(w, a, "fun `{s}Impl`(): KSerializer<{s}> = ObjectSerializer(\"{s}\", {s})\n\n", .{ gn, info.path, serial, info.path });
}

fn genWithFactory(w: *std.ArrayList(u8), a: Allocator, g: *const Gen, info: *const Info) Allocator.Error!void {
    const gn = try genName(a, info.path);
    try wp(w, a, "fun `{s}Impl`(): KSerializer<{s}> = {s}\n\n", .{ gn, info.path, try g.customSerializerRef(info.with.?) });
}

/// The member splice text for the class: a companion (or object member)
/// `serializer()` delegating to the generated top-level artifact.
fn genMemberSplice(a: Allocator, c: ?*const ast.Class, info: *const Info) Allocator.Error![]const u8 {
    const gn = try genName(a, info.path);
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
        try wp(&out, a, "object {s} {{ fun serializer(): KSerializer<{s}> = `{s}Impl`() }}", .{ last, info.path, gn });
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
        .value_class => try wp(&out, a, "fun serializer(): KSerializer<{s}> = `{s}`", .{ info.path, gn }),
        else => try wp(&out, a, "fun serializer(): KSerializer<{s}> = `{s}Impl`()", .{ info.path, gn }),
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
};

fn snippetPadded(ctx: *Ctx, text: []const u8) Allocator.Error![]const u8 {
    const extra = try ctx.a.alloc(u8, ctx.next_pad);
    @memset(extra, ' ');
    ctx.next_pad += text.len + 64;
    return std.fmt.allocPrint(ctx.a, "{s}{s}{s}", .{ ctx.pad, extra, text });
}

fn processDecls(ctx: *Ctx, decls: []ast.Decl, outer: []const u8) Allocator.Error!void {
    for (decls) |*d| {
        switch (d.*) {
            .Class => |*c| {
                const path = joinPath(ctx.a, outer, c.name.name);
                try processDecls(ctx, c.members, path);
                if (!isSerializable(c.annotations)) continue;
                const info = ctx.idx.by_name.get(c.name.name) orelse continue;
                if (!std.mem.eql(u8, info.path, path)) continue;
                var tps: std.ArrayList([]const u8) = .empty;
                for (c.type_params) |*tp| try tps.append(ctx.a, tp.name.name);
                const g = Gen{ .a = ctx.a, .idx = ctx.idx, .type_params = tps.items };
                switch (info.kind) {
                    .class => try genClassSerializer(&ctx.gen, ctx.a, &g, c, &info),
                    .value_class => try genValueClassSerializer(&ctx.gen, ctx.a, &g, c, &info),
                    .enum_class => try genEnumFactory(&ctx.gen, ctx.a, c, &info),
                    .sealed, .interface_sealed => try genSealedFactory(&ctx.gen, ctx.a, ctx.idx, &info),
                    .polymorphic => try genPolymorphicFactory(&ctx.gen, ctx.a, &info),
                    .with_custom => try genWithFactory(&ctx.gen, ctx.a, &g, &info),
                    .object => {},
                }
                ctx.generated_any = true;
                const splice_src = try snippetPadded(ctx, try genMemberSplice(ctx.a, c, &info));
                if (parseSnippet(ctx.a, ctx.file.span.file, splice_src)) |snip_val| {
                    var snip = snip_val;
                    try spliceInto(ctx.a, &c.members, false, &snip);
                }
            },
            .Object => |*o| {
                const path = joinPath(ctx.a, outer, o.name.name);
                try processDecls(ctx, o.members, path);
                if (!isSerializable(o.annotations)) continue;
                const info = ctx.idx.by_name.get(o.name.name) orelse continue;
                if (!std.mem.eql(u8, info.path, path)) continue;
                const g = Gen{ .a = ctx.a, .idx = ctx.idx, .type_params = &.{} };
                switch (info.kind) {
                    .with_custom => try genWithFactory(&ctx.gen, ctx.a, &g, &info),
                    else => try genObjectFactory(&ctx.gen, ctx.a, &info),
                }
                ctx.generated_any = true;
                const splice_src = try snippetPadded(ctx, try genMemberSplice(ctx.a, null, &info));
                if (parseSnippet(ctx.a, ctx.file.span.file, splice_src)) |snip_val| {
                    var snip = snip_val;
                    try spliceInto(ctx.a, &o.members, true, &snip);
                }
            },
            else => {},
        }
    }
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
    for (files_in) |*f| {
        try indexDecls(&idx, f.decls, "", packageText(a, f));
    }
    var out: std.ArrayList(ast.KotlinFile) = .empty;
    try out.appendSlice(a, files_in);
    const dump = std.c.getenv("KLIO_SERIAL_DUMP") != null;
    for (out.items[0..files_in.len]) |*f| {
        if (!fileMentionsSerializable(f)) continue;
        // Work on a copy of the decl array so the original stays intact.
        const decls_copy = try a.alloc(ast.Decl, f.decls.len);
        @memcpy(decls_copy, f.decls);
        f.decls = decls_copy;
        const pad = try a.alloc(u8, f.span.end + 16);
        @memset(pad, ' ');
        var ctx = Ctx{ .a = a, .idx = &idx, .file = f, .pkg = packageText(a, f), .gen = .empty, .pad = pad };
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
                if (isSerializable(c.annotations)) return true;
                if (declsMentionSerializable(c.members)) return true;
            },
            .Object => |*o| {
                if (isSerializable(o.annotations)) return true;
                if (declsMentionSerializable(o.members)) return true;
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
