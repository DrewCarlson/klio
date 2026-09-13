//! kotlinx-serialization compiler-plugin replacement.
//!
//! For every `@Serializable` declaration the plugin would process, this pass
//! synthesizes the artifacts it generates as ordinary Kotlin declarations,
//! parsed from generated source text, before anything downstream reads the
//! decls. Per original file that declares serializable classes:
//!
//! - A synthetic sibling file, same package with its own star imports of the
//!   kotlinx.serialization surface, holds the heavy artifacts as top-level
//!   declarations: the `<Name>$serializer` object, its generic
//!   `class <Name>$serializer<T>(typeSerial0)` form, and
//!   `fun <Name>$serializerImpl()` factories for the enum, object, sealed,
//!   polymorphic and `with=` forms.
//! - A splice into the class: a companion `serializer()` delegating to that
//!   artifact, which is what `Companion.serializer()` reaches.
//!
//! `KLIO_SERIAL_DUMP=1` dumps the generated text.

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

// Serializable-declaration index, across all files.

const Kind = enum { class, object, enum_class, sealed, polymorphic, value_class, with_custom, interface_sealed };

const Info = struct {
    name: []const u8,
    /// Dotted classifier path from the file's top level (`Outer.Inner`).
    path: []const u8,
    pkg: []const u8,
    kind: Kind,
    type_params: usize,
    with: ?[]const u8 = null,
    serial_name: ?[]const u8 = null,
    is_object_decl: bool = false,
    /// Suffix of the generated top-level artifact; a
    /// `@KeepGeneratedSerializer` twin uses `$generatedSerializer`.
    gen_suffix: []const u8 = "$serializer",
};

const SealedSub = struct { path: []const u8 };
const SubRecord = struct { sub_path: []const u8, sup_head: []const u8, scope: []const u8 };

const Index = struct {
    a: Allocator,
    by_name: std.StringHashMap(Info),
    by_path: std.StringHashMap(Info),
    all_paths: std.StringHashMap(void),
    sealed_subs: std.StringHashMap(std.ArrayList(SealedSub)),
    sub_records: std.ArrayList(SubRecord),
    objects: std.StringHashMap(void),
    /// Top-level `const val` strings, so a template-spelled annotation argument
    /// folds to the constant kotlinc sees.
    const_strings: std.StringHashMap([]const u8),
    /// A class carrying a `@MetaSerializable` annotation is serializable.
    meta_serializable: std.StringHashMap(void),
    serial_info: std.StringHashMap(void),
    /// Annotation classes marked `@InheritableSerialInfo`: pushed into the
    /// class annotations of every subclass descriptor.
    inheritable: std.StringHashMap(void),
    supers: std.StringHashMap([]const []const u8),
    class_annotations: std.StringHashMap([]const []const u8),
    class_nodes: std.StringHashMap(*const ast.Class),
    super_refs: std.StringHashMap([]const ast.TypeRef),
    /// `@Serializer(forClass = X::class)` target head per serializer path.
    serializer_for_class: std.StringHashMap([]const u8),
    /// Class paths declared `@Polymorphic`: every property of that type
    /// serializes polymorphically.
    polymorphic_classes: std.StringHashMap(void),
    /// Top-level `typealias` by simple name: a property typed through an alias
    /// serializes as the target, carrying the target's type-use annotations.
    type_aliases: std.StringHashMap(*const ast.TypeAlias),

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
            .serializer_for_class = std.StringHashMap([]const u8).init(a),
            .polymorphic_classes = std.StringHashMap(void).init(a),
            .type_aliases = std.StringHashMap(*const ast.TypeAlias).init(a),
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

/// `s` as the body of a Kotlin string literal. The lexer hands the pass the
/// unescaped text of a `@SerialName("...")`, so a quote, backslash, dollar or
/// control character is re-escaped on the way back into generated source.
fn kq(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var needs = false;
    for (s) |c| {
        if (c == '"' or c == '\\' or c == '$' or c < 0x20) {
            needs = true;
            break;
        }
    }
    if (!needs) return s;
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '$' => try out.appendSlice(a, "\\$"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            '\x08' => try out.appendSlice(a, "\\b"),
            else => {
                if (c < 0x20) {
                    var ub: [8]u8 = undefined;
                    try out.appendSlice(a, std.fmt.bufPrint(&ub, "\\u{x:0>4}", .{c}) catch unreachable);
                } else {
                    try out.append(a, c);
                }
            },
        }
    }
    return out.toOwnedSlice(a);
}

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

fn isSerializableLiteral(annotations: []const ast.Annotation) bool {
    return hasAnnotation(annotations, "Serializable");
}

fn isSerializableIn(idx: *const Index, annotations: []const ast.Annotation) bool {
    if (hasAnnotation(annotations, "Serializable")) return true;
    for (annotations) |*an| {
        if (idx.meta_serializable.contains(annotationSimpleName(an))) return true;
    }
    return false;
}

fn annotationCallText(a: Allocator, an: *const ast.Annotation) ?[]const u8 {
    const txt = sourceOf(an.span) orelse return null;
    const body = if (txt.len > 0 and txt[0] == '@') txt[1..] else txt;
    if (std.mem.findScalar(u8, body, '(') == null) return std.fmt.allocPrint(a, "{s}()", .{body}) catch null;
    return body;
}

/// Only a `@SerialInfo`-marked annotation class reaches the serial descriptor,
/// so a stdlib marker never becomes a runtime construction.
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
    if (std.mem.findScalarLast(u8, h, '.')) |d| h = h[d + 1 ..];
    return h;
}

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
    if (hasAnnotation(annotations, "Polymorphic")) try idx.polymorphic_classes.put(path, {});
    if (serializerForClassTarget(idx.a, annotations)) |target| {
        try idx.serializer_for_class.put(path, simpleHead(target));
    }
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
                // A class naming a supertype that is (or turns out to be) a
                // sealed serializable class; resolved once every path is known.
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
            .TypeAlias => |*ta| {
                if (outer.len == 0) try idx.type_aliases.put(ta.name.name, ta);
            },
            else => {},
        }
    }
}


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

const FileSettings = struct {
    contextual: std.StringHashMap(void),
    use_serializers: std.StringHashMap([]const u8),
    /// Type head -> serializer path for a nullable target (`KSerializer<Int?>`):
    /// it handles null itself, so a nullable property binds it directly.
    use_serializers_nullable: std.StringHashMap([]const u8),
};

const Gen = struct {
    a: Allocator,
    idx: *const Index,
    type_params: []const []const u8,
    /// Nested path of the class being generated; a bare type name resolves
    /// against its enclosing scopes first.
    scope_path: []const u8 = "",
    file: ?*const FileSettings = null,
    pkg: []const u8 = "",

    /// Qualify a type reference, keeping an explicit dotted qualifier: the
    /// `qualified_path` of `Outer.Nested` must survive, since the bare name is
    /// unresolvable from the synthetic file.
    fn qualifyTy(self: *const Gen, t: *const ast.TypeRef) Allocator.Error![]const u8 {
        return self.qualify(t.qualified_path orelse t.name.name);
    }

    fn qualify(self: *const Gen, written: []const u8) Allocator.Error![]const u8 {
        if (std.mem.findScalar(u8, written, '.') != null) {
            var scope = self.scope_path;
            while (true) {
                const cand = if (scope.len == 0) written else try std.fmt.allocPrint(self.a, "{s}.{s}", .{ scope, written });
                if (self.idx.all_paths.contains(cand)) return cand;
                if (scope.len == 0) break;
                scope = if (std.mem.findScalarLast(u8, scope, '.')) |d| scope[0..d] else "";
            }
            return written;
        }
        var scope = self.scope_path;
        while (true) {
            const cand = if (scope.len == 0) written else try std.fmt.allocPrint(self.a, "{s}.{s}", .{ scope, written });
            if (self.idx.all_paths.contains(cand)) return cand;
            if (scope.len == 0) break;
            scope = if (std.mem.findScalarLast(u8, scope, '.')) |d| scope[0..d] else "";
        }
        return written;
    }

    fn typeParamIndex(self: *const Gen, head: []const u8) ?usize {
        for (self.type_params, 0..) |tp, i| {
            if (std.mem.eql(u8, tp, head)) return i;
        }
        return null;
    }

    fn typeText(self: *const Gen, t: *const ast.TypeRef) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        if (t.function) |_| {
            try out.appendSlice(self.a, "Any");
        } else {
            try out.appendSlice(self.a, try self.qualifyTy(t));
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

    /// The serializer expression for a type. A `@file:UseSerializers` serializer
    /// declared over the nullable type handles null itself, so it binds directly
    /// rather than through a `.nullable` wrapper.
    fn nullableTargetRef(self: *const Gen, t: *const ast.TypeRef, annotations: []const ast.Annotation) Allocator.Error!?[]const u8 {
        if (!t.nullable) return null;
        if (serializableWith(self.a, annotations) != null) return null;
        if (hasAnnotation(annotations, "Contextual") or hasAnnotation(annotations, "Polymorphic")) return null;
        const fs = self.file orelse return null;
        const ser = fs.use_serializers_nullable.get(simpleHead(t.name.name)) orelse return null;
        return try self.customSerializerRef(t, ser);
    }

    fn serializerExpr(self: *const Gen, t: *const ast.TypeRef, annotations: []const ast.Annotation) Allocator.Error![]const u8 {
        if (try self.nullableTargetRef(t, annotations)) |ref| return ref;
        const base = try self.serializerExprNonNull(t, annotations);
        if (t.nullable) return std.fmt.allocPrint(self.a, "({s}).nullable", .{base});
        return base;
    }

    fn typeArgSerializer(self: *const Gen, t: *const ast.TypeRef, i: usize) Allocator.Error![]const u8 {
        if (i >= t.type_args.len or t.type_args[i].is_star) {
            return "PolymorphicSerializer(Any::class)";
        }
        return self.serializerExpr(&t.type_args[i].ty, t.type_args[i].ty.annotations);
    }

    /// `ContextualSerializer(X::class, fallback, args)`. A non-generic
    /// `@Serializable` `X` supplies its generated serializer as the fallback.
    fn contextualSerializerExpr(self: *const Gen, t: *const ast.TypeRef) Allocator.Error![]const u8 {
        const a = self.a;
        const q = try self.qualifyTy(t);
        var args: std.ArrayList(u8) = .empty;
        for (t.type_args, 0..) |_, i| {
            if (i != 0) try args.appendSlice(a, ", ");
            try args.appendSlice(a, try self.typeArgSerializer(t, i));
        }
        if (self.serializableInScope(t.name.name)) |ci| {
            if (ci.type_params == 0 and t.type_args.len == 0) {
                return std.fmt.allocPrint(a, "ContextualSerializer({s}::class, {s}.serializer(), arrayOf())", .{ q, q });
            }
            if (ci.type_params != 0 and ci.type_params == t.type_args.len) {
                return std.fmt.allocPrint(a, "ContextualSerializer({s}::class, {s}.serializer({s}), arrayOf({s}))", .{ q, q, args.items, args.items });
            }
        }
        return std.fmt.allocPrint(a, "ContextualSerializer({s}::class, null, arrayOf({s}))", .{ q, args.items });
    }

    fn serializableInScope(self: *const Gen, written: []const u8) ?Info {
        const a = self.a;
        var scope: []const u8 = self.scope_path;
        while (true) {
            const cand = if (scope.len == 0) written else std.fmt.allocPrint(a, "{s}.{s}", .{ scope, written }) catch return null;
            if (self.idx.by_path.get(cand)) |ci| return ci;
            if (scope.len == 0) break;
            scope = if (std.mem.findScalarLast(u8, scope, '.')) |d| scope[0..d] else "";
        }
        return null;
    }

    fn serializerExprNonNull(self: *const Gen, t: *const ast.TypeRef, annotations: []const ast.Annotation) Allocator.Error![]const u8 {
        const a = self.a;
        if (serializableWith(a, annotations)) |w| return self.customSerializerRef(t, w);
        if (serializableWith(a, t.annotations)) |w| return self.customSerializerRef(t, w);
        if (t.function == null and t.type_args.len == 0 and self.typeParamIndex(simpleHead(t.name.name)) == null) {
            if (self.idx.type_aliases.get(simpleHead(t.name.name))) |ta| {
                if (ta.type_params.len == 0 and !std.mem.eql(u8, simpleHead(ta.target.name.name), simpleHead(t.name.name))) {
                    return self.serializerExprNonNull(&ta.target, annotations);
                }
            }
        }
        const head = simpleHead(t.name.name);
        if (self.file) |fs| {
            if (!hasAnnotation(annotations, "Contextual") and !hasAnnotation(annotations, "Polymorphic")) {
                if (fs.use_serializers.get(head)) |ser| return self.customSerializerRef(t, ser);
                if (fs.contextual.contains(head)) {
                    return self.contextualSerializerExpr(t);
                }
            }
        }
        if (hasAnnotation(annotations, "Contextual")) {
            return self.contextualSerializerExpr(t);
        }
        if (hasAnnotation(annotations, "Polymorphic")) {
            // `@Polymorphic` on a type parameter serializes over the bound,
            // `Any`, the base the caller's module registers under.
            if (self.typeParamIndex(head) != null) return "PolymorphicSerializer(Any::class)";
            return std.fmt.allocPrint(a, "PolymorphicSerializer({s}::class)", .{try self.qualifyTy(t)});
        }
        if (self.serializableInScope(t.name.name)) |ci| {
            if (self.idx.polymorphic_classes.contains(ci.path)) {
                return std.fmt.allocPrint(a, "PolymorphicSerializer({s}::class)", .{try self.qualifyTy(t)});
            }
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
            const elem_head = if (t.type_args.len != 0 and !t.type_args[0].is_star) try self.qualifyTy(&t.type_args[0].ty) else "Any";
            return std.fmt.allocPrint(a, "ArraySerializer({s}::class, {s})", .{ elem_head, try self.typeArgSerializer(t, 0) });
        }
        if (eq(u8, head, "IntArray") or eq(u8, head, "LongArray") or eq(u8, head, "ShortArray") or eq(u8, head, "ByteArray") or
            eq(u8, head, "CharArray") or eq(u8, head, "FloatArray") or eq(u8, head, "DoubleArray") or eq(u8, head, "BooleanArray") or
            eq(u8, head, "UIntArray") or eq(u8, head, "ULongArray") or eq(u8, head, "UByteArray") or eq(u8, head, "UShortArray"))
        {
            return std.fmt.allocPrint(a, "{s}Serializer()", .{head});
        }
        const qn = try self.qualifyTy(t);
        // An interface is polymorphic unless it carries its own `@Serializable`,
        // and `@Polymorphic` forces it either way.
        if (self.idx.class_nodes.get(qn)) |cn| {
            if (cn.is_interface and (hasAnnotation(cn.annotations, "Polymorphic") or !isSerializableIn(self.idx, cn.annotations))) {
                return std.fmt.allocPrint(a, "PolymorphicSerializer({s}::class)", .{qn});
            }
            // An enum is serializable without `@Serializable` and has no
            // companion to ask, so its serializer is built in place.
            if (cn.is_enum and !isSerializableIn(self.idx, cn.annotations)) {
                const serial = if (self.pkg.len == 0) qn else try std.fmt.allocPrint(a, "{s}.{s}", .{ self.pkg, qn });
                var marked = false;
                for (cn.enum_entries) |*en| {
                    if (en.annotations.len != 0) marked = true;
                }
                const class_anns = try classAnnotationCalls(a, self.idx, qn);
                if (class_anns.len != 0) marked = true;
                if (marked) {
                    var out: std.ArrayList(u8) = .empty;
                    try writeAnnotatedEnumSerializer(&out, a, cn, serial, qn, class_anns);
                    return out.items;
                }
                return std.fmt.allocPrint(a, "createSimpleEnumSerializer(\"{s}\", {s}.values())", .{ try kq(a, serial), qn });
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

    fn customSerializerRef(self: *const Gen, t: ?*const ast.TypeRef, w: []const u8) Allocator.Error![]const u8 {
        const q = try self.qualify(w);
        if (self.idx.objects.contains(q) or self.idx.objects.contains(w) or self.idx.objects.contains(simpleHead(w))) return q;
        if (!self.idx.class_nodes.contains(q) and !self.idx.class_nodes.contains(w) and
            !self.idx.class_nodes.contains(simpleHead(w))) return q;
        // A generic serializer class named on a property takes the annotated
        // type's own type-argument serializers; a type-parameter argument
        // resolves to the enclosing `typeSerial<i>`.
        if (t) |ty| {
            if (ty.type_args.len != 0 and self.serializerClassIsGeneric(q)) {
                var out: std.ArrayList(u8) = .empty;
                try out.appendSlice(self.a, q);
                try out.append(self.a, '(');
                for (ty.type_args, 0..) |_, i| {
                    if (i > 0) try out.appendSlice(self.a, ", ");
                    try out.appendSlice(self.a, try self.typeArgSerializer(ty, i));
                }
                try out.append(self.a, ')');
                return out.toOwnedSlice(self.a);
            }
        }
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

    fn serializerClassIsGeneric(self: *const Gen, q: []const u8) bool {
        if (self.idx.class_nodes.get(q)) |cn| return cn.type_params.len != 0;
        if (self.idx.class_nodes.get(simpleHead(q))) |cn| return cn.type_params.len != 0;
        return false;
    }
};

// Element model of a serializable class.

const Elem = struct {
    name: []const u8,
    serial_name: []const u8,
    ty: *const ast.TypeRef,
    annotations: []const ast.Annotation,
    default_text: ?[]const u8,
    in_ctor: bool,
    /// `@Required`: never optional even with a default.
    required: bool,
    encode_default: enum { unset, always, never },
    is_var: bool,
    is_lateinit: bool = false,
    /// Declared by a `@Serializable` superclass: decoded and written, never
    /// handed to this class's constructor.
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
    // A `@Serializable` superclass's properties serialize first, and a supertype
    // argument instantiates the superclass's type parameter.
    for (c.supertypes) |*st| {
        const sup_path = try g.qualifyTy(st);
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
        // A body property is an element exactly when it has a backing field. One
        // assigned only in an init block is an element too, but its decoded value
        // is overwritten after construction.
        if (p.delegate != null) continue;
        const getter_field = if (p.getter) |gt| ast.accessorUsesField(gt) else false;
        const setter_field = if (p.setter) |st| ast.accessorUsesField(st) else false;
        const has_field = p.init != null or p.is_lateinit or
            (p.getter == null and p.setter == null) or getter_field or setter_field;
        if (!has_field) continue;
        // An unannotated property has an inferred type: name it from a literal
        // initializer, else fall back to `Any`.
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

/// The members of a generated serializer for `c`, and the body of a
/// `@Serializer(forClass = Name::class)` object. The primitive fast path
/// applies only to a plainly typed element; a custom or contextual serializer
/// routes through itself.
fn elemPrim(g: *const Gen, e: *const Elem) Prim {
    if (e.ty.nullable) return .none;
    if (serializableWith(std.heap.page_allocator, e.annotations) != null) return .none;
    if (hasAnnotation(e.annotations, "Contextual") or hasAnnotation(e.annotations, "Polymorphic")) return .none;
    // A file-level `@file:UseSerializers` entry for this element's type routes
    // through that serializer, so a primitive-typed element must not take the
    // primitive element codec.
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
    try wp(w, a, "    override val descriptor: SerialDescriptor = PluginGeneratedSerialDescriptor(\"{s}\", this, {d}).also {{ `$dd` ->\n", .{ try kq(a, serial), elems.len });
    for (elems) |*e| {
        try wp(w, a, "        `$dd`.addElement(\"{s}\", {s})\n", .{ try kq(a, e.serial_name), if (elemOptional(e)) "true" else "false" });
        for (e.annotations) |*an| {
            const n = annotationSimpleName(an);
            if (std.mem.eql(u8, n, "SerialName") or std.mem.eql(u8, n, "Serializable") or std.mem.eql(u8, n, "Transient") or
                std.mem.eql(u8, n, "Required") or std.mem.eql(u8, n, "EncodeDefault") or std.mem.eql(u8, n, "Contextual") or
                std.mem.eql(u8, n, "Polymorphic") or std.mem.eql(u8, n, "OptIn") or std.mem.eql(u8, n, "Suppress")) continue;
            if (!isSerialInfoAnnotation(g.idx, n)) continue;
            if (sourceOf(an.span)) |txt| {
                const body = if (txt.len > 0 and txt[0] == '@') txt[1..] else txt;
                const call = if (std.mem.findScalar(u8, body, '(') == null) try std.fmt.allocPrint(a, "{s}()", .{body}) else body;
                try wp(w, a, "        `$dd`.pushAnnotation({s})\n", .{call});
            }
        }
    }
    for (try classAnnotationCalls(a, g.idx, info.path)) |call| {
        try wp(w, a, "        `$dd`.pushClassAnnotation({s})\n", .{call});
    }
    try w.appendSlice(a, "    }\n");
    try w.appendSlice(a, "    override fun childSerializers(): Array<KSerializer<*>> = arrayOf<KSerializer<*>>(");
    for (elems, 0..) |*e, i| {
        if (i > 0) try w.appendSlice(a, ", ");
        try w.appendSlice(a, try g.serializerExpr(e.ty, e.annotations));
    }
    try w.appendSlice(a, ")\n");
    if (generic) {
        try wp(w, a, "    override fun typeParametersSerializers(): Array<KSerializer<*>> = arrayOf<KSerializer<*>>({s})\n", .{try typeSerialArgs(a, c)});
    }
    try wp(w, a, "    override fun serialize(encoder: Encoder, value: {s}) {{\n", .{self_ty});
    try w.appendSlice(a, "        val `$d` = descriptor\n        val `$out` = encoder.beginStructure(`$d`)\n");
    for (elems, 0..) |*e, i| {
        const p = elemPrim(g, e);
        const enc = if (p != .none)
            try std.fmt.allocPrint(a, "`$out`.encode{s}Element(`$d`, {d}, value.{s})", .{ primSuffix(p), i, e.name })
        else if (e.ty.nullable) blk: {
            if (try g.nullableTargetRef(e.ty, e.annotations)) |ref|
                break :blk try std.fmt.allocPrint(a, "`$out`.encodeSerializableElement(`$d`, {d}, {s}, value.{s})", .{ i, ref, e.name });
            break :blk try std.fmt.allocPrint(a, "`$out`.encodeNullableSerializableElement(`$d`, {d}, {s}, value.{s})", .{ i, try g.serializerExprNonNull(e.ty, e.annotations), e.name });
        } else
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
    var dec_stmts: std.ArrayList([]const u8) = .empty;
    for (elems, 0..) |*e, i| {
        const p = elemPrim(g, e);
        // Bit 31 and a full golden mask overflow a Kotlin Int literal, so both
        // are spelled as the signed value the `and` sees.
        const bit: i32 = @bitCast(@as(u32, 1) << @intCast(i % 32));
        const mk = i / 32;
        const st = if (p != .none)
            try std.fmt.allocPrint(a, "`$v{d}` = `$c`.decode{s}Element(`$d`, {d}); `$seen{d}` = `$seen{d}` or {d}", .{ i, primSuffix(p), i, mk, mk, bit })
        else if (e.ty.nullable) blk: {
            if (try g.nullableTargetRef(e.ty, e.annotations)) |ref|
                break :blk try std.fmt.allocPrint(a, "`$v{d}` = `$c`.decodeSerializableElement(`$d`, {d}, {s}, `$v{d}`); `$seen{d}` = `$seen{d}` or {d}", .{ i, i, ref, i, mk, mk, bit });
            break :blk try std.fmt.allocPrint(a, "`$v{d}` = `$c`.decodeNullableSerializableElement(`$d`, {d}, {s}, `$v{d}`); `$seen{d}` = `$seen{d}` or {d}", .{ i, i, try g.serializerExprNonNull(e.ty, e.annotations), i, mk, mk, bit });
        } else
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
    // Constructor properties re-evaluate their defaults in declaration order,
    // shadowed so a default can reference an earlier property.
    try w.appendSlice(a, "        return run {\n");
    // A `@Transient` property is never decoded, but its default still binds a
    // local for the defaults after it.
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
        // An init block runs after field assignment, so decode the element but
        // leave the construction alone.
        if (e.default_text == null and !e.is_lateinit) continue;
        const bit: i32 = @bitCast(@as(u32, 1) << @intCast(i % 32));
        const val_expr = if (e.ty.nullable) try std.fmt.allocPrint(a, "`$v{d}`", .{i}) else blk: {
            const p = primOf(simpleHead(e.ty.name.name));
            if (p != .none) break :blk try std.fmt.allocPrint(a, "`$v{d}`", .{i});
            // A type-parameter element may be instantiated nullable, so the
            // value is cast, never asserted.
            if (g.typeParamIndex(simpleHead(e.ty.name.name)) != null) break :blk try std.fmt.allocPrint(a, "(`$v{d}` as {s})", .{ i, try g.typeText(e.ty) });
            break :blk try std.fmt.allocPrint(a, "`$v{d}`!!", .{i});
        };
        try wp(w, a, "            if ((`$seen{d}` and {d}) != 0) `$inst`.{s} = {s}\n", .{ i / 32, bit, e.name, val_expr });
    }
    try w.appendSlice(a, "            `$inst`\n        }\n    }\n");
}

/// The class's own non-framework annotations plus every
/// `@InheritableSerialInfo` annotation on its supertype chain, nearest first.
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
            var sp: ?[]const u8 = null;
            var scope = cur;
            while (true) {
                scope = if (std.mem.findScalarLast(u8, scope, '.')) |d| scope[0..d] else "";
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
                    const head = if (std.mem.findScalar(u8, call, '(')) |lp| call[0..lp] else call;
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

fn genValueClassSerializer(w: *std.ArrayList(u8), a: Allocator, g: *const Gen, c: *const ast.Class, info: *const Info) Allocator.Error!void {
    const elems = try collectElems(a, g, c);
    if (elems.len != 1) return;
    const e = &elems[0];
    const gn = try genNameFor(a, info);
    const serial = try serialNameOf(a, info);
    const p = elemPrim(g, e);
    const tps = try typeParamList(a, c);
    const self_ty = try std.fmt.allocPrint(a, "{s}{s}", .{ info.path, tps });
    if (c.type_params.len != 0) {
        try wp(w, a, "class `{s}`{s}({s}) : GeneratedSerializer<{s}> {{\n", .{ gn, tps, try typeSerialParams(a, c), self_ty });
    } else {
        try wp(w, a, "object `{s}` : GeneratedSerializer<{s}> {{\n", .{ gn, self_ty });
    }
    try wp(w, a, "    override val descriptor: SerialDescriptor = InlineClassDescriptor(\"{s}\", this).also {{ `$dd` -> `$dd`.addElement(\"{s}\", false) }}\n", .{ try kq(a, serial), try kq(a, e.serial_name) });
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

fn writeAnnotatedEnumSerializer(w: *std.ArrayList(u8), a: Allocator, c: *const ast.Class, serial: []const u8, path: []const u8, class_anns: []const []const u8) Allocator.Error!void {
    try wp(w, a, "createAnnotatedEnumSerializer(\"{s}\", {s}.values(), arrayOf<String?>(", .{ try kq(a, serial), path });
    for (c.enum_entries, 0..) |*en, i| {
        if (i > 0) try w.appendSlice(a, ", ");
        if (findAnnotation(en.annotations, "SerialName")) |an| {
            if (annotationStringArg(an)) |s| {
                try wp(w, a, "\"{s}\"", .{try kq(a, s)});
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
                const call = if (std.mem.findScalar(u8, body, '(') == null) try std.fmt.allocPrint(a, "{s}()", .{body}) else body;
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
    try w.appendSlice(a, ")");
}

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
        try wp(w, a, "val `{s}Cache`: KSerializer<{s}> by lazy {{ createSimpleEnumSerializer(\"{s}\", {s}.values()) }}\nfun `{s}Impl`(): KSerializer<{s}> = `{s}Cache`\n\n", .{ gn, info.path, try kq(a, serial), info.path, gn, info.path, gn });
        return;
    }
    try wp(w, a, "val `{s}Cache`: KSerializer<{s}> by lazy {{ ", .{ gn, info.path });
    try writeAnnotatedEnumSerializer(w, a, c, serial, info.path, class_anns);
    try w.appendSlice(a, " }\n");
    try wp(w, a, "fun `{s}Impl`(): KSerializer<{s}> = `{s}Cache`\n\n", .{ gn, info.path, gn });
}

/// The concrete serializable subclasses of a sealed declaration, flattened
/// through nested sealed, abstract and interface subtypes, in declaration order.
fn collectSealedLeaves(a: Allocator, idx: *const Index, parent_path: []const u8, out: *std.ArrayList([]const u8), seen: *std.StringHashMap(void)) Allocator.Error!void {
    const subs: []const SealedSub = if (idx.sealed_subs.get(parent_path)) |l| l.items else &.{};
    for (subs) |sub| {
        if (seen.contains(sub.path)) continue;
        try seen.put(sub.path, {});
        const si = idx.by_path.get(sub.path) orelse {
            // An enum implementing the sealed interface is serializable without
            // `@Serializable`, and is a leaf like any other subclass.
            if (idx.class_nodes.get(sub.path)) |cn| {
                if (cn.is_enum) try out.append(a, sub.path);
            }
            continue;
        };
        switch (si.kind) {
            .sealed, .interface_sealed => try collectSealedLeaves(a, idx, si.path, out, seen),
            else => try out.append(a, sub.path),
        }
    }
}

/// A sealed leaf's `@SerialName`, else its qualified class name.
fn leafSerialName(a: Allocator, idx: *const Index, pkg: []const u8, path: []const u8) Allocator.Error![]const u8 {
    if (idx.by_path.get(path)) |li| return serialNameOf(a, &li);
    if (idx.class_nodes.get(path)) |cn| {
        if (findAnnotation(cn.annotations, "SerialName")) |an| {
            if (annotationStringArg(an)) |sn| return sn;
        }
    }
    if (pkg.len == 0) return path;
    return std.fmt.allocPrint(a, "{s}.{s}", .{ pkg, path });
}

fn leafIsPlainEnum(idx: *const Index, path: []const u8) bool {
    if (idx.by_path.get(path) != null) return false;
    const cn = idx.class_nodes.get(path) orelse return false;
    return cn.is_enum;
}

fn genSealedFactory(w: *std.ArrayList(u8), a: Allocator, idx: *const Index, info: *const Info) Allocator.Error!void {
    const gn = try genNameFor(a, info);
    const serial = try serialNameOf(a, info);
    var leaves: std.ArrayList([]const u8) = .empty;
    var seen = std.StringHashMap(void).init(a);
    try collectSealedLeaves(a, idx, info.path, &leaves, &seen);
    // The descriptor lists subclasses ordered by serial name.
    {
        const Ctx2 = struct {
            a: Allocator,
            idx: *const Index,
            pkg: []const u8,
            fn less(self: @This(), x: []const u8, y: []const u8) bool {
                const sx = leafSerialName(self.a, self.idx, self.pkg, x) catch x;
                const sy = leafSerialName(self.a, self.idx, self.pkg, y) catch y;
                return std.mem.lessThan(u8, sx, sy);
            }
        };
        std.sort.pdq([]const u8, leaves.items, Ctx2{ .a = a, .idx = idx, .pkg = info.pkg }, Ctx2.less);
    }
    const subs: []const []const u8 = leaves.items;
    try wp(w, a, "val `{s}Cache`: KSerializer<{s}> by lazy {{ SealedClassSerializer(\"{s}\", {s}::class, arrayOf<KClass<out {s}>>(", .{ gn, info.path, try kq(a, serial), info.path, info.path });
    for (subs, 0..) |sp, n| {
        if (n > 0) try w.appendSlice(a, ", ");
        try wp(w, a, "{s}::class", .{sp});
    }
    try wp(w, a, "), arrayOf<KSerializer<out {s}>>(", .{info.path});
    for (subs, 0..) |sp, n| {
        if (n > 0) try w.appendSlice(a, ", ");
        const leaf_tps: usize = if (idx.by_path.get(sp)) |li| li.type_params else 0;
        if (leafIsPlainEnum(idx, sp)) {
            try wp(w, a, "createSimpleEnumSerializer(\"{s}\", {s}.values())", .{ try kq(a, try leafSerialName(a, idx, info.pkg, sp)), sp });
        } else if (leaf_tps == 0) {
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
        try wp(w, a, "val `{s}Cache`: KSerializer<{s}> by lazy {{ ObjectSerializer(\"{s}\", {s}) }}\nfun `{s}Impl`(): KSerializer<{s}> = `{s}Cache`\n\n", .{ gn, info.path, try kq(a, serial), info.path, gn, info.path, gn });
    } else {
        try wp(w, a, "val `{s}Cache`: KSerializer<{s}> by lazy {{ ObjectSerializer(\"{s}\", {s}, arrayOf<Annotation>({s})) }}\nfun `{s}Impl`(): KSerializer<{s}> = `{s}Cache`\n\n", .{ gn, info.path, try kq(a, serial), info.path, try joinCalls(a, oanns), gn, info.path, gn });
    }
}

fn genWithFactory(w: *std.ArrayList(u8), a: Allocator, g: *const Gen, info: *const Info) Allocator.Error!void {
    const gn = try genNameFor(a, info);
    if (g.type_params.len != 0) {
        // The factory takes the type-argument serializers, so it is a function
        // of them and is not cached.
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
        try wp(w, a, "fun <{s}> `{s}Impl`({s}): KSerializer<{s}<{s}>> = {s}\n\n", .{ tps.items, gn, params.items, info.path, tps.items, try g.customSerializerRef(null, info.with.?) });
        return;
    }
    try wp(w, a, "val `{s}Cache`: KSerializer<{s}> by lazy {{ {s} }}\nfun `{s}Impl`(): KSerializer<{s}> = `{s}Cache`\n\n", .{ gn, info.path, try g.customSerializerRef(null, info.with.?), gn, info.path, gn });
}

fn genMemberSplice(a: Allocator, c: ?*const ast.Class, info: *const Info, kept: ?*const Info) Allocator.Error![]const u8 {
    const gn = try genNameFor(a, info);
    var out: std.ArrayList(u8) = .empty;
    // Mirror the class's nesting path so the parsed companion's identity derives
    // from its real owner, not from a shared wrapper name.
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
                try wp(&out, a, "fun {s} serializer({s}): KSerializer<{s}{s}> = `{s}Impl`({s})", .{
                    try typeParamList(a, c.?), try typeSerialParams(a, c.?), info.path, try typeParamList(a, c.?), gn, try typeSerialArgs(a, c.?),
                });
            } else if (c != null and c.?.type_params.len != 0) {
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

// Parsing generated text and splicing it into the original declarations.

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

fn spliceInto(a: Allocator, target_members: *[]ast.Decl, is_object: bool, snippet: *ast.KotlinFile) Allocator.Error!void {
    if (snippet.decls.len == 0) return;
    var wrapper = &snippet.decls[0];
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
    gen: std.ArrayList(u8),
    generated_any: bool = false,
    pad: []const u8,
    /// Extra padding so successive snippets in one file never share offsets,
    /// which a span-keyed registry would merge.
    next_pad: usize = 0,
    settings: FileSettings,
};

const SerTarget = struct { head: []const u8, nullable: bool };

fn serializerTargetHead(idx: *const Index, ser_path: []const u8) ?SerTarget {
    if (idx.super_refs.get(ser_path)) |sups| {
        for (sups) |*st| {
            if (!std.mem.eql(u8, simpleHead(st.name.name), "KSerializer")) continue;
            if (st.type_args.len == 0 or st.type_args[0].is_star) continue;
            return .{ .head = simpleHead(st.type_args[0].ty.name.name), .nullable = st.type_args[0].ty.nullable };
        }
    }
    if (idx.serializer_for_class.get(ser_path)) |target| {
        return .{ .head = target, .nullable = false };
    }
    return null;
}

fn fileSettings(a: Allocator, idx: *const Index, f: *const ast.KotlinFile) Allocator.Error!FileSettings {
    var fs = FileSettings{ .contextual = std.StringHashMap(void).init(a), .use_serializers = std.StringHashMap([]const u8).init(a), .use_serializers_nullable = std.StringHashMap([]const u8).init(a) };
    for (f.file_annotations) |*an| {
        const n = annotationSimpleName(an);
        if (std.mem.eql(u8, n, "UseContextualSerialization")) {
            for (an.args) |*arg| {
                if (exprClassRef(a, arg)) |c| try fs.contextual.put(simpleHead(c), {});
            }
        } else if (std.mem.eql(u8, n, "UseSerializers")) {
            for (an.args) |*arg| {
                const c = exprClassRef(a, arg) orelse continue;
                const ser_path: []const u8 = if (idx.super_refs.contains(c)) c else blk: {
                    var it = idx.super_refs.keyIterator();
                    while (it.next()) |k| {
                        if (std.mem.eql(u8, simpleHead(k.*), simpleHead(c))) break :blk k.*;
                    }
                    break :blk c;
                };
                if (serializerTargetHead(idx, ser_path)) |target| {
                    if (target.nullable)
                        try fs.use_serializers_nullable.put(target.head, ser_path)
                    else
                        try fs.use_serializers.put(target.head, ser_path);
                }
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

/// A `@Serializable` local class gets the same generated shapes as a top-level
/// one, but every artifact lives inside the class, which is visible only in its
/// body's scope. It never enters the index, since two functions may declare
/// same-named locals.
fn localScopePath(a: Allocator, outer: []const u8, local_name: []const u8) Allocator.Error![]const u8 {
    if (outer.len == 0) return local_name;
    return std.fmt.allocPrint(a, "{s}.{s}", .{ outer, local_name });
}

fn processFunctionLocals(ctx: *Ctx, f: *ast.Function, outer: []const u8) Allocator.Error!void {
    const dbg = std.c.getenv("KLIO_SERIAL_DUMP") != null;
    if (dbg) std.debug.print("[serial-pass] fn {s} body={s}\n", .{ f.name.name, if (f.body) |b| @tagName(std.meta.activeTag(b)) else "none" });
    if (f.body) |*fb| {
        switch (fb.*) {
            .Block => |*blk| try processLocalStmts(ctx, f, blk.stmts, outer),
            .Expr => |*e| try walkLocalExpr(ctx, f, e, outer),
        }
    }
}

fn walkLocalExpr(ctx: *Ctx, f: *ast.Function, e: *ast.Expr, outer: []const u8) Allocator.Error!void {
    switch (e.*) {
        .Call => |*c| {
            try walkLocalExpr(ctx, f, c.callee, outer);
            for (c.args) |*a| try walkLocalExpr(ctx, f, a, outer);
        },
        .Lambda => |*l| try processLocalStmts(ctx, f, l.body.stmts, outer),
        .Block => |*blk| try processLocalStmts(ctx, f, blk.stmts, outer),
        .If => |*i| {
            try walkLocalExpr(ctx, f, i.cond, outer);
            try walkLocalExpr(ctx, f, i.then_branch, outer);
            if (i.else_branch) |eb| try walkLocalExpr(ctx, f, eb, outer);
        },
        .While => |*w| {
            try walkLocalExpr(ctx, f, w.cond, outer);
            try walkLocalExpr(ctx, f, w.body, outer);
        },
        .DoWhile => |*w| {
            if (w.body) |wb| try walkLocalExpr(ctx, f, wb, outer);
            try walkLocalExpr(ctx, f, w.cond, outer);
        },
        .For => |*fr| {
            try walkLocalExpr(ctx, f, fr.iter, outer);
            try walkLocalExpr(ctx, f, fr.body, outer);
        },
        .Try => |*t| {
            try processLocalStmts(ctx, f, t.body.stmts, outer);
            for (t.catches) |*cc| try processLocalStmts(ctx, f, cc.body.stmts, outer);
            if (t.finally) |*fb| try processLocalStmts(ctx, f, fb.stmts, outer);
        },
        .When => |*w| {
            if (w.subject) |sub| try walkLocalExpr(ctx, f, sub, outer);
            for (w.branches) |*br| try walkLocalExpr(ctx, f, &br.body, outer);
        },
        .Return => |*r| if (r.value) |v| try walkLocalExpr(ctx, f, v, outer),
        .Labeled => |*l| try walkLocalExpr(ctx, f, l.expr, outer),
        .Throw => |*t| try walkLocalExpr(ctx, f, t.value, outer),
        .Binary => |*bin| {
            try walkLocalExpr(ctx, f, bin.lhs, outer);
            try walkLocalExpr(ctx, f, bin.rhs, outer);
        },
        .Unary => |*u| try walkLocalExpr(ctx, f, u.expr, outer),
        .Postfix => |*u| try walkLocalExpr(ctx, f, u.expr, outer),
        .Member => |*m| try walkLocalExpr(ctx, f, m.receiver, outer),
        .Index => |*ix| {
            try walkLocalExpr(ctx, f, ix.receiver, outer);
            for (ix.args) |*a| try walkLocalExpr(ctx, f, a, outer);
        },
        .Spread => |*sp| try walkLocalExpr(ctx, f, sp.expr, outer),
        .IsCheck => |*ic| try walkLocalExpr(ctx, f, ic.expr, outer),
        .As => |*ac| try walkLocalExpr(ctx, f, ac.expr, outer),
        .AnonFun => |*af| if (af.body) |fb| switch (fb.*) {
            .Block => |*blk| try processLocalStmts(ctx, f, blk.stmts, outer),
            .Expr => |*ex| try walkLocalExpr(ctx, f, ex, outer),
        },
        else => {},
    }
}

fn processLocalStmts(ctx: *Ctx, f: *ast.Function, stmts: []ast.Stmt, outer: []const u8) Allocator.Error!void {
    const dbg = std.c.getenv("KLIO_SERIAL_DUMP") != null;
    for (stmts) |*st| {
        switch (st.*) {
            .Expr => |*e| {
                try walkLocalExpr(ctx, f, e, outer);
                continue;
            },
            .Assign => |*a| {
                try walkLocalExpr(ctx, f, &a.value, outer);
                continue;
            },
            .DestructuringDecl => |*dd| {
                try walkLocalExpr(ctx, f, &dd.init, outer);
                continue;
            },
            .Decl => {},
        }
        if (dbg) std.debug.print("[serial-pass] local decl in {s}: {s}\n", .{ f.name.name, @tagName(std.meta.activeTag(st.Decl)) });
        switch (st.Decl) {
            .Property => |p| {
                if (p.init) |*init| try walkLocalExpr(ctx, f, init, outer);
                continue;
            },
            .Function => |*lf| {
                try processFunctionLocals(ctx, lf, outer);
                continue;
            },
            .Class => |*c| {
                if (companionForClassTarget(ctx.a, c.members) != null) continue;
                if (dbg) std.debug.print("[serial-pass] local class {s} serializable={}\n", .{ c.name.name, isSerializableIn(ctx.idx, c.annotations) });
                if (!isSerializableIn(ctx.idx, c.annotations)) continue;
                if (companionIsSerializer(c.members)) continue;
                const info = classInfo(ctx.idx, c, c.name.name, ctx.pkg);
                var tps: std.ArrayList([]const u8) = .empty;
                for (c.type_params) |*tp| try tps.append(ctx.a, tp.name.name);
                const g = Gen{ .a = ctx.a, .idx = ctx.idx, .pkg = ctx.pkg, .type_params = tps.items, .scope_path = try localScopePath(ctx.a, outer, c.name.name), .file = &ctx.settings };
                var local_gen: std.ArrayList(u8) = .empty;
                switch (info.kind) {
                    .class => try genClassSerializer(&local_gen, ctx.a, &g, c, &info),
                    .value_class => try genValueClassSerializer(&local_gen, ctx.a, &g, c, &info),
                    .enum_class => try genEnumFactory(&local_gen, ctx.a, ctx.idx, c, &info),
                    // For a local `with = X::class` class the top-level artifacts
                    // would land as instance members the companion cannot reach.
                    .with_custom => {},
                    .sealed, .interface_sealed, .polymorphic, .object => continue,
                }
                ctx.generated_any = true;
                if (local_gen.items.len != 0) {
                    const artifacts = try snippetPadded(ctx, local_gen.items);
                    if (dbg) std.debug.print("[serial-pass] local artifacts for {s}:\n{s}\n", .{ c.name.name, local_gen.items });
                    if (parseSnippet(ctx.a, ctx.file.span.file, artifacts)) |snip_val| {
                        if (dbg) std.debug.print("[serial-pass] local artifacts parsed: {d} decls\n", .{snip_val.decls.len});
                        try appendMembers(ctx.a, &c.members, snip_val.decls);
                    } else if (dbg) std.debug.print("[serial-pass] local artifacts FAILED to parse\n", .{});
                }
                const splice_text: []const u8 = if (info.kind == .with_custom)
                    try std.fmt.allocPrint(ctx.a, "class {s} {{ companion object {{ fun serializer(): KSerializer<{s}> = {s} }} }}", .{ c.name.name, c.name.name, try g.customSerializerRef(null, info.with.?) })
                else
                    try genMemberSplice(ctx.a, c, &info, null);
                const splice_src = try snippetPadded(ctx, splice_text);
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
                if (companionForClassTarget(ctx.a, c.members)) |target_written| {
                    if (findCompanion(c.members)) |comp| {
                        try genForClassCompanion(ctx, comp, path, target_written);
                    }
                    continue;
                }
                if (!isSerializableIn(ctx.idx, c.annotations)) continue;
                const info = ctx.idx.by_path.get(path) orelse continue;
                // A companion implementing `KSerializer<Self>` is itself the
                // serializer: no `$serializer` is generated.
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
                // `@KeepGeneratedSerializer` beside a custom `with=` still emits
                // the generated serializer, reached by `generatedSerializer()`.
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
            .Function => |*f| try processFunctionLocals(ctx, f, outer),
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

fn companionForClassTarget(a: Allocator, members: []const ast.Decl) ?[]const u8 {
    const comp = findCompanionConst(members) orelse return null;
    return serializerForClassTarget(a, comp.Class.annotations);
}

fn serializerForClassTarget(a: Allocator, annotations: []const ast.Annotation) ?[]const u8 {
    const an = findAnnotation(annotations, "Serializer") orelse return null;
    for (an.args) |*arg| {
        if (exprClassRef(a, arg)) |c| return c;
    }
    return null;
}

/// Fill a `@Serializer(forClass = X::class)` object with X's generated members,
/// keeping its own name and supertypes.
fn genForClassObject(ctx: *Ctx, o: *ast.ObjectDecl, obj_path: []const u8, target_written: []const u8) Allocator.Error!void {
    const a = ctx.a;
    const scope = if (std.mem.findScalarLast(u8, obj_path, '.')) |d| obj_path[0..d] else "";
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
    // The body names the serialization surface by simple name, so it needs the
    // sibling file's import scope: emit it there as `<Obj>$forClass`.
    const impl_name = try std.fmt.allocPrint(a, "{s}$forClass", .{try genName(a, obj_path)});
    try wp(&ctx.gen, a, "object `{s}` : GeneratedSerializer<{s}> {{\n", .{ impl_name, info.path });
    try genClassSerializerBody(&ctx.gen, a, &g, c, &info);
    try ctx.gen.appendSlice(a, "}\n\n");
    ctx.generated_any = true;
    const splice = try std.fmt.allocPrint(a,
        "object {s} : kotlinx.serialization.KSerializer<{s}> {{ override val descriptor: kotlinx.serialization.descriptors.SerialDescriptor get() = `{s}`.descriptor\n" ++
            "override fun serialize(encoder: kotlinx.serialization.encoding.Encoder, value: {s}) = `{s}`.serialize(encoder, value)\n" ++
            "override fun deserialize(decoder: kotlinx.serialization.encoding.Decoder): {s} = `{s}`.deserialize(decoder) }}",
        .{ o.name.name, info.path, impl_name, info.path, impl_name, info.path, impl_name });
    const splice_src = try snippetPadded(ctx, splice);
    if (parseSnippet(a, ctx.file.span.file, splice_src)) |snip_val| {
        var snip = snip_val;
        // A bodiless object declares no serializer supertype, so the splice
        // supplies the `KSerializer<X>` it must have.
        if (snip.decls.len != 0 and snip.decls[0] == .Object and !declaresSerializerSupertype(o.supertypes)) {
            const so = &snip.decls[0].Object;
            try appendSupertypes(a, o, so.supertypes);
        }
        try spliceInto(a, &o.members, true, &snip);
    }
}

fn declaresSerializerSupertype(supertypes: []const ast.TypeRef) bool {
    for (supertypes) |*st| {
        const head = simpleHead(st.name.name);
        if (std.mem.eql(u8, head, "KSerializer") or std.mem.eql(u8, head, "GeneratedSerializer") or
            std.mem.eql(u8, head, "SerializationStrategy") or std.mem.eql(u8, head, "DeserializationStrategy")) return true;
    }
    return false;
}

fn appendSupertypes(a: Allocator, o: *ast.ObjectDecl, extra: []const ast.TypeRef) Allocator.Error!void {
    if (extra.len == 0) return;
    var sups: std.ArrayList(ast.TypeRef) = .empty;
    try sups.appendSlice(a, o.supertypes);
    try sups.appendSlice(a, extra);
    o.supertypes = sups.items;
    var sargs: std.ArrayList(?[]ast.Expr) = .empty;
    try sargs.appendSlice(a, o.supertype_args);
    while (sargs.items.len < o.supertypes.len) try sargs.append(a, null);
    o.supertype_args = sargs.items;
    if (o.supertype_arg_names.len != 0) {
        var names: std.ArrayList(?[]const ?[]const u8) = .empty;
        try names.appendSlice(a, o.supertype_arg_names);
        while (names.items.len < o.supertypes.len) try names.append(a, null);
        o.supertype_arg_names = names.items;
    }
    if (o.supertype_delegates.len != 0) {
        var dels: std.ArrayList(?ast.Expr) = .empty;
        try dels.appendSlice(a, o.supertype_delegates);
        while (dels.items.len < o.supertypes.len) try dels.append(a, null);
        o.supertype_delegates = dels.items;
    }
}

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

/// Generated sibling files take ids beyond any real file, so their spans never
/// alias a real declaration.
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

/// Returns the originals followed by one generated sibling file per original
/// that declared serializable classes. Copies are shallow: decl arrays are
/// replaced, never mutated, so the caller's originals stay valid.
pub fn transformFiles(a: Allocator, files_in: []const ast.KotlinFile) Allocator.Error![]ast.KotlinFile {
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
    // Top-level string constants first: an annotation argument in one file may
    // reference a `const val` declared in another.
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
    // Resolve each subclass supertype to a declaration path, enclosing scopes
    // first, so two files' same-named sealed parents keep separate lists.
    for (idx.sub_records.items) |rec| {
        const parent_path: ?[]const u8 = blk: {
            var scope = rec.scope;
            while (true) {
                const cand = if (scope.len == 0) rec.sup_head else try std.fmt.allocPrint(a, "{s}.{s}", .{ scope, rec.sup_head });
                if (idx.all_paths.contains(cand)) break :blk cand;
                if (scope.len == 0) break;
                scope = if (std.mem.findScalarLast(u8, scope, '.')) |d| scope[0..d] else "";
            }
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
        const decls_copy = try a.alloc(ast.Decl, f.decls.len);
        @memcpy(decls_copy, f.decls);
        f.decls = decls_copy;
        const pad = try a.alloc(u8, f.span.end + 16);
        @memset(pad, ' ');
        var ctx = Ctx{ .a = a, .idx = &idx, .file = f, .pkg = packageText(a, f), .gen = .empty, .pad = pad, .settings = try fileSettings(a, &idx, f) };
        try processDecls(&ctx, f.decls, "");
        if (!ctx.generated_any) continue;
        var src: std.ArrayList(u8) = .empty;
        if (ctx.pkg.len != 0) try wp(&src, a, "package {s}\n\n", .{ctx.pkg});
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
    if (declsMentionSerializable(f.decls)) return true;
    // A class in a lambda, a block or an expression body is local too; the
    // source-text scan catches nestings the decl walk misses.
    if (sourceOf(f.span)) |txt| return std.mem.find(u8, txt, "@Serializable") != null;
    return false;
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
