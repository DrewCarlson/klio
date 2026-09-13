//! Class and member registration: `ClassDef` synthesis, the member-AST, supertype and
//! inline registries, annotation records, property anchors, and the expect/actual rules.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const FF = runtime.forest.ForestField;
const ast = @import("ast");
const stdlib = @import("stdlib");
const lift = @import("lift.zig");

const Allocator = std.mem.Allocator;
const Module = ir.Module;
const FuncId = ir.FuncId;
const ClassId = ir.ClassId;
const ClassDef = runtime.ClassDef;
const ClassParamDef = runtime.ClassParamDef;
const PropertyDef = runtime.PropertyDef;
const TypeShape = runtime.TypeShape;
const InstanceData = runtime.InstanceData;
const Env = runtime.Env;
const ObjRef = runtime.ObjRef;
const Decl = ast.Decl;
const StringSet = std.StringHashMap(void);

const build_scan = @import("scan.zig");
const classTypeParamBoundHeads = build_scan.classTypeParamBoundHeads;
const literalToConst = build_scan.literalToConst;
const primitiveZeroFor = build_scan.primitiveZeroFor;
const resolveFqn = build_scan.resolveFqn;
const scalarNonNullProp = build_scan.scalarNonNullProp;

const build_types = @import("types.zig");
const FileClasses = build_types.FileClasses;
const Span = build_types.Span;
const SpanStrMap = build_types.SpanStrMap;


pub fn replaceDotWithDollar(allocator: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, out) |ch, *dst| dst.* = if (ch == '.') '$' else ch;
    return out;
}

/// A supertype reference resolves to the mangled top-level name when the nested type
/// it names was mangled, matching the last two qualified segments.
pub fn resolveMangled(allocator: Allocator, mangled_nested: *const lift.MangledMap, t: *const ast.TypeRef) ?[]const u8 {
    const qp = t.qualified_path orelse return null;
    var last: ?usize = null;
    var prev: ?usize = null;
    var i: usize = 0;
    while (i < qp.len) : (i += 1) {
        if (qp[i] == '.') {
            prev = last;
            last = i;
        }
    }
    const key = if (last != null) blk: {
        const start = if (prev) |p| p + 1 else 0;
        break :blk qp[start..];
    } else qp;
    _ = allocator;
    return mangled_nested.get(key);
}

pub fn collectConsts(module: *Module, cls_name: []const u8, members: []const Decl) Allocator.Error!void {
    for (members) |*m| {
        switch (m.*) {
            .Property => |p| if (p.is_const) {
                if (p.init) |*init| {
                    if (literalToConst(init)) |c| {
                        try module.registry.class_const_inits.put(.{ .a = cls_name, .b = p.name.name }, c);
                    }
                }
            },
            .Class => |*inner| if (inner.is_companion) {
                try collectConsts(module, cls_name, inner.members);
            },
            else => {},
        }
    }
}

/// Registered under owner class or object, recursing into nested types, so
/// reified-type-argument inference can resolve a property-access argument.
pub fn registerMemberPropAsts(a: Allocator, members: []const Decl, owner: []const u8, qualified: ?[]const u8) void {
    for (members) |*m| {
        switch (m.*) {
            .Property => |p| {
                ir.lower.registerMemberPropAst(a, owner, p);
                // The qualified owner too: two inner classes of one package can share a simple name.
                if (qualified) |q| {
                    if (!std.mem.eql(u8, q, owner)) ir.lower.registerMemberPropAst(a, q, p);
                }
                // A member-EXTENSION property takes a dedicated key so a same-named plain member cannot
                // hide it; a read whose static receiver type matches takes the extension getter.
                if (p.receiver_type) |rt| {
                    ir.lower.registerMemberExtPropRecv(a, owner, p.name.name, rt.name.name);
                }
            },
            .Class => |*c| registerMemberPropAsts(a, c.members, c.name.name, nestedQualified(a, qualified, c.name.name)),
            .Object => |*o| registerMemberPropAsts(a, o.members, o.name.name, nestedQualified(a, qualified, o.name.name)),
            else => {},
        }
    }
}

pub fn nestedQualified(a: Allocator, outer: ?[]const u8, simple: []const u8) ?[]const u8 {
    const o = outer orelse return null;
    return std.fmt.allocPrint(a, "{s}.{s}", .{ o, simple }) catch null;
}

pub fn registerClassSupertypes(members: []const Decl) void {
    for (members) |*m| {
        switch (m.*) {
            .Class => |*c| {
                ir.lower.registerClassSupertypeRefs(c.name.name, c.supertypes);
                registerClassSupertypes(c.members);
            },
            .Object => |*o| {
                ir.lower.registerClassSupertypeRefs(o.name.name, o.supertypes);
                registerClassSupertypes(o.members);
            },
            else => {},
        }
    }
}

/// Mirrors `collectInline`'s recursion into nested types, so the owner map covers exactly
/// the member inline fns the candidate table holds.
pub fn registerInlineMemberOwners(members: []const Decl, owner: []const u8) void {
    for (members) |*m| {
        switch (m.*) {
            .Function => |*f| {
                if (f.is_inline and f.body != null) {
                    ir.lower.registerInlineMemberOwner(f, owner);
                }
                // On-demand return derivation: a caller lowered before this member's own pass still types
                // its locals from the inferred return.
                if (f.body != null) {
                    ir.lower.registerExprBodyMember(owner, f) catch {};
                }
            },
            .Class => |*c| registerInlineMemberOwners(c.members, c.name.name),
            .Object => |*o| registerInlineMemberOwners(o.members, o.name.name),
            else => {},
        }
    }
}

pub fn collectInline(allocator: Allocator, d: *const Decl, out: *std.StringHashMap(std.ArrayList(FF(ast.Function)))) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| if (f.is_inline and f.body != null) {
            const gop = try out.getOrPut(f.name.name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, FF(ast.Function).fromPtr(f));
        },
        .Class => |*c| for (c.members) |*m| try collectInline(allocator, m, out),
        .Object => |*o| for (o.members) |*m| try collectInline(allocator, m, out),
        else => {},
    }
}

pub fn collectCompanionOwnMembers(c: *const ast.Class, own: *StringSet) Allocator.Error!void {
    for (c.members) |*m| {
        if (m.* == .Class and m.Class.is_companion) {
            const inner = &m.Class;
            try own.put(inner.name.name, {});
            for (inner.members) |*cm| {
                switch (cm.*) {
                    .Function => |*f| try own.put(f.name.name, {}),
                    .Property => |p| try own.put(p.name.name, {}),
                    else => {},
                }
            }
            for (inner.primary_params) |*p| {
                if (p.property != null) try own.put(p.name.name, {});
            }
        }
    }
}

/// Null when the class is unknown or declares no `@Target`, which admit the default set.
pub fn annotationTargetEntries(
    a: Allocator,
    file_classes: *const FileClasses,
    leaf: []const u8,
) Allocator.Error!?[]const []const u8 {
    const ref = file_classes.get(leaf) orelse return null;
    const cls = ref.get();
    if (!cls.is_annotation) return null;
    for (cls.annotations) |*ann| {
        if (ann.path.len == 0) continue;
        if (!std.mem.eql(u8, ann.path[ann.path.len - 1].name, "Target")) continue;
        var names: std.ArrayList([]const u8) = .empty;
        for (ann.args) |*arg| {
            switch (arg.*) {
                .Path => |p| if (p.segments.len > 0) {
                    try names.append(a, p.segments[p.segments.len - 1].name);
                },
                .Member => |m| try names.append(a, m.name.name),
                else => {},
            }
        }
        return try names.toOwnedSlice(a);
    }
    return null;
}

pub fn serializerForClassAnnotated(annotations: []const ast.Annotation) bool {
    for (annotations) |*ann| {
        if (ann.path.len == 0) continue;
        const name = ann.path[ann.path.len - 1].name;
        if (!std.mem.eql(u8, name, "Serializer")) continue;
        for (ann.args) |*arg| {
            if (arg.* == .MemberRef and std.mem.eql(u8, arg.MemberRef.name.name, "class")) return true;
        }
    }
    return false;
}

/// Resolved FQN candidates plus resolved constructor arguments.
pub fn annotationRecordFor(
    module: *Module,
    a: Allocator,
    ann: *const ast.Annotation,
) Allocator.Error!runtime.AnnotationRecord {
    var args = try a.alloc(runtime.AnnotationArg, ann.args.len);
    for (ann.args, 0..) |*arg, i| {
        args[i] = switch (arg.*) {
            .StringTemplate => |st| blk: {
                if (st.parts.len == 0) break :blk .{ .Str = "" };
                if (st.parts.len == 1 and st.parts[0] == .Text) {
                    break :blk .{ .Str = st.parts[0].Text };
                }
                break :blk .Other;
            },
            .IntLit => |il| .{ .Int = il.value },
            .BoolLit => |bl| .{ .Bool = bl.value },
            .Path => |p| if (p.segments.len > 0)
                runtime.AnnotationArg{ .EnumEntry = p.segments[p.segments.len - 1].name }
            else
                .Other,
            .Member => |m| .{ .EnumEntry = m.name.name },
            // `Foo::class` names the declaration the annotation is about, not a value.
            .MemberRef => |mr| blk: {
                if (!std.mem.eql(u8, mr.name.name, "class")) break :blk .Other;
                const recv = mr.receiver;
                if (recv.* != .Path or recv.Path.segments.len == 0) break :blk .Other;
                break :blk runtime.AnnotationArg{ .ClassRef = recv.Path.segments[recv.Path.segments.len - 1].name };
            },
            else => .Other,
        };
    }
    const arg_names = try a.alloc(?[]const u8, ann.arg_names.len);
    @memcpy(arg_names, ann.arg_names);
    return .{
        .names = try ir.lower.resolveAnnotationNames(module, ann[0..1]),
        .args = args,
        .arg_names = arg_names,
    };
}

/// Anchors come from `@all:` expansion, an explicit use-site, or the LV 2.4 default.
pub fn buildPropertyAnchors(
    module: *Module,
    a: Allocator,
    file_classes: *const FileClasses,
    anns: []const ast.Annotation,
    shape: ast.annotation_targets.PropertyShape,
) Allocator.Error!runtime.PropertyAnchors {
    if (anns.len == 0) return .{};
    const at = ast.annotation_targets;
    var lists: [7]std.ArrayList(runtime.AnnotationRecord) = @splat(.empty);
    const anchor_fields = [_][]const u8{ "param", "property", "field", "get", "set", "setparam", "delegate" };
    for (anns) |*ann| {
        if (ann.path.len == 0) continue;
        const leaf = ann.path[ann.path.len - 1].name;
        var placement = at.Placement{};
        if (ann.use_site) |us| switch (us) {
            .All => {
                if (shape.is_delegated) continue;
                const u = at.useSiteSet(try annotationTargetEntries(a, file_classes, leaf));
                placement = at.expandAll(u, shape);
            },
            .Field => placement.field = true,
            .Property => placement.property = true,
            .Get => placement.get = true,
            .Set => placement.set = true,
            .Param => placement.param = true,
            .SetParam => placement.setparam = true,
            .Delegate => placement.delegate = true,
            .Receiver, .File => continue,
        } else {
            const u = at.useSiteSet(try annotationTargetEntries(a, file_classes, leaf));
            placement = at.defaultPlacement(u, shape);
        }
        if (placement.isEmpty()) continue;
        const rec = try annotationRecordFor(module, a, ann);
        inline for (anchor_fields, 0..) |fname, i| {
            if (@field(placement, fname)) try lists[i].append(a, rec);
        }
    }
    return .{
        .param = try lists[0].toOwnedSlice(a),
        .property = try lists[1].toOwnedSlice(a),
        .field = try lists[2].toOwnedSlice(a),
        .get = try lists[3].toOwnedSlice(a),
        .set = try lists[4].toOwnedSlice(a),
        .setparam = try lists[5].toOwnedSlice(a),
        .delegate = try lists[6].toOwnedSlice(a),
    };
}

/// Type head of an unannotated property whose initializer is a literal; null otherwise.
pub fn inferredPropTypeHead(p: *const ast.Property) ?[]const u8 {
    const init = if (p.init) |*e| e else return null;
    return switch (init.*) {
        .StringTemplate => "String",
        .IntLit => "Int",
        .BoolLit => "Boolean",
        .FloatLit => "Double",
        .CharLit => "Char",
        else => null,
    };
}

pub fn memberHasBackingField(p: *const ast.Property) bool {
    if (p.delegate != null or p.is_abstract or p.is_expect or p.receiver_type != null) return false;
    if (p.init != null or p.explicit_field != null) return true;
    if (p.getter == null) return true;
    if (p.mutable and p.setter == null) return true;
    if (p.getter) |g| if (ast.accessorUsesField(g)) return true;
    if (p.setter) |s| if (ast.accessorUsesField(s)) return true;
    return false;
}

pub fn spanNamesObject(object_spans: []const Span, target: Span) bool {
    for (object_spans) |s| {
        if (std.meta.eql(s, target)) return true;
    }
    return false;
}

pub fn fillNestedClassTables(a: Allocator, decls_in: []const Decl, classes: *const std.StringHashMap(ObjRef(ClassDef)), outer_fqn: []const u8) Allocator.Error!void {
    for (decls_in) |*d| {
        const members: []const Decl = switch (d.*) {
            .Class => |*c| c.members,
            .Object => |*o| o.members,
            else => continue,
        };
        const self_name: []const u8 = switch (d.*) {
            .Class => |*c| c.name.name,
            .Object => |*o| o.name.name,
            else => unreachable,
        };
        const self_fqn = if (outer_fqn.len == 0) self_name else try std.fmt.allocPrint(a, "{s}.{s}", .{ outer_fqn, self_name });
        const self_def: ?ObjRef(ClassDef) = classes.get(self_fqn) orelse classes.get(self_name);
        if (self_def) |sd| {
            var list: std.ArrayList(ClassDef.NestedClass) = .empty;
            for (members) |*m| {
                const nname: []const u8 = switch (m.*) {
                    .Class => |*c| if (c.is_companion) continue else c.name.name,
                    .Object => |*o| o.name.name,
                    else => continue,
                };
                const nfqn = try std.fmt.allocPrint(a, "{s}.{s}", .{ self_fqn, nname });
                const nd = classes.get(nfqn) orelse classes.get(nname) orelse continue;
                try list.append(a, .{ .name = nname, .class = nd.clone() });
            }
            if (list.items.len != 0) {
                const g = sd.borrowMut();
                if (g.get().nested_classes.len == 0) {
                    g.get().nested_classes = try list.toOwnedSlice(a);
                } else {
                    list.deinit(a);
                }
                g.deinit();
            } else {
                list.deinit(a);
            }
        }
        try fillNestedClassTables(a, members, classes, self_fqn);
    }
}

pub fn buildClassDef(
    module: *Module,
    a: Allocator,
    c: *const ast.Class,
    fqn_overrides: *const SpanStrMap,
    package_prefix: []const u8,
    object_spans: *const std.ArrayList(Span),
    globals_for_capture: ObjRef(Env),
    file_classes: *const FileClasses,
) Allocator.Error!ObjRef(ClassDef) {
    var primary_params = try a.alloc(ClassParamDef, c.primary_params.len);
    for (c.primary_params, 0..) |*p, i| {
        primary_params[i] = .{
            .property = p.property,
            .name = p.name.name,
            .default = if (p.default) |*e| FF(ast.Expr).fromPtr(e) else null,
            .declared_type = p.ty.name.name,
            .declared_shape = try TypeShape.fromTypeRef(a, &p.ty),
            .anchors = if (p.property) |is_var| try buildPropertyAnchors(module, a, file_classes, p.annotations, .{
                .is_ctor_property = true,
                .is_var = is_var,
                .has_backing_field = true,
                .in_annotation_class = c.is_annotation,
            }) else .{},
        };
    }
    var body_props: std.ArrayList(PropertyDef) = .empty;
    for (c.members) |*m| {
        if (m.* != .Property) continue;
        const p = m.Property;
        // A member-extension property belongs to the extension surface, not the class's own.
        if (p.receiver_type != null) continue;
        const storage_init: ?*const ast.Expr = if (p.init) |*e|
            e
        else if (p.explicit_field) |ef|
            (if (ef.init) |*finit| finit else null)
        else
            null;
        try body_props.append(a, .{
            .name = p.name.name,
            .mutable = p.mutable,
            .init = if (storage_init) |e| FF(ast.Expr).fromPtr(e) else null,
            .getter = if (p.getter) |g| FF(ast.Accessor).fromPtr(g) else null,
            .setter = if (p.setter) |s| FF(ast.Accessor).fromPtr(s) else null,
            .delegate = if (p.delegate) |e| FF(ast.Expr).fromPtr(e) else null,
            .is_abstract = p.is_abstract,
            .is_lateinit = p.is_lateinit,
            .primitive_zero = primitiveZeroFor(p),
            .anchors = try buildPropertyAnchors(module, a, file_classes, p.annotations, .{
                .is_var = p.mutable,
                .has_backing_field = memberHasBackingField(p),
                .is_delegated = p.delegate != null,
            }),
            .has_backing = memberHasBackingField(p),
            .type_head = if (p.ty) |*ty| ty.name.name else inferredPropTypeHead(p),
            .scalar_nn = scalarNonNullProp(p),
        });
    }

    // Matched by declaration span, never simple name: a same-named `object` elsewhere must not
    // mark this class an object.
    const is_object = spanNamesObject(object_spans.items, c.span);

    // init-block property positions: count `Property` decls in members[0..pos].
    var init_block_positions = try a.alloc(usize, c.init_block_positions.len);
    for (c.init_block_positions, 0..) |pos, i| {
        const upto = @min(pos, c.members.len);
        var count: usize = 0;
        for (c.members[0..upto]) |*m| {
            // Member-extension properties are not body properties, so they do not shift positions.
            if (m.* == .Property and m.Property.receiver_type == null) count += 1;
        }
        init_block_positions[i] = count;
    }

    var init_blocks_ast = try a.alloc(FF(ast.Block), c.init_blocks.len);
    for (c.init_blocks, 0..) |*blk, i| init_blocks_ast[i] = FF(ast.Block).fromPtr(blk);

    var secondary = try a.alloc(FF(ast.SecondaryCtor), c.secondary_ctors.len);
    for (c.secondary_ctors, 0..) |*sc, i| secondary[i] = FF(ast.SecondaryCtor).fromPtr(sc);

    // `@Serializer(forClass = C::class)` is written on a declaration with no supertype; the
    // kotlinx plugin makes it a `KSerializer<C>`, which `is`/`as KSerializer` read.
    const serializer_supertype = c.supertypes.len == 0 and serializerForClassAnnotated(c.annotations);
    // An annotation class implicitly implements `kotlin.Annotation`.
    const annotation_supertype = c.is_annotation;
    // A function-type supertype contributes erased `FunctionN` names, first in its own slot.
    var fn_extra: usize = 0;
    for (c.supertypes) |*t| if (t.function) |ft| {
        const tags = try ir.lower.decl.functionSupertypeTags(a, ft);
        fn_extra += tags.len - 1;
    };
    const extra: usize = @as(usize, @intFromBool(serializer_supertype)) + @as(usize, @intFromBool(annotation_supertype)) + fn_extra;
    var supertype_names = try a.alloc([]const u8, c.supertypes.len + extra);
    var supertype_paths = try a.alloc(?[]const u8, c.supertypes.len + extra);
    {
        var slot: usize = c.supertypes.len;
        if (serializer_supertype) {
            supertype_names[slot] = "KSerializer";
            supertype_paths[slot] = null;
            slot += 1;
        }
        if (annotation_supertype) {
            supertype_names[slot] = "Annotation";
            supertype_paths[slot] = null;
            slot += 1;
        }
        for (c.supertypes, 0..) |*t, i| if (t.function) |ft| {
            const tags = try ir.lower.decl.functionSupertypeTags(a, ft);
            supertype_names[i] = tags[0];
            supertype_paths[i] = null;
            for (tags[1..]) |tag| {
                supertype_names[slot] = tag;
                supertype_paths[slot] = null;
                slot += 1;
            }
        };
    }
    for (c.supertypes, 0..) |*t, i| {
        if (t.function != null) continue;
        // A renamed file-private supertype resolves to its mangled lift name, keyed by the
        // reference's own span file.
        supertype_names[i] = if (t.qualified_path == null)
            ir.build.fileOrPkgTypeRename(t.name.name, t.span.file.int()) orelse
                ir.lower.decl.importedPkgTypeRename(module, t.name.name, t.span.file) orelse
                t.name.name
        else
            t.name.name;
        supertype_paths[i] = t.qualified_path;
    }

    const fqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);

    return ObjRef(ClassDef).init(a, .{
        .name = c.name.name,
        .fqn = fqn,
        .annotation_names = try ir.lower.resolveAnnotationNames(module, c.annotations),
        .annotation_records = blk: {
            const recs = try a.alloc(runtime.AnnotationRecord, c.annotations.len);
            for (c.annotations, recs) |*ann, *rec| rec.* = try annotationRecordFor(module, a, ann);
            break :blk recs;
        },
        .type_params = blk: {
            const names = try a.alloc([]const u8, c.type_params.len);
            for (c.type_params, names) |*tp, *out| out.* = tp.name.name;
            break :blk names;
        },
        .type_param_bounds = try classTypeParamBoundHeads(a, c.type_params, c.where_bounds),
        .primary_params = primary_params,
        .methods = &.{},
        .body_properties = try body_props.toOwnedSlice(a),
        .init_blocks = init_blocks_ast,
        .init_block_property_positions = init_block_positions,
        .is_data = c.is_data,
        .is_value = c.is_value,
        .is_object = is_object,
        .is_enum = c.is_enum,
        .is_annotation = c.is_annotation,
        .is_sealed = c.is_sealed,
        .supertype_names = supertype_names,
        .supertype_paths = supertype_paths,
        .parent = null,
        .interfaces = &.{},
        .is_interface = c.is_interface,
        .is_fun_interface = c.is_fun_interface,
        .parent_ctor_args = &.{},
        .is_open = c.is_open,
        .has_primary_ctor = c.has_primary_ctor,
        .is_abstract = c.is_abstract,
        .is_inner = c.is_inner,
        .is_anonymous = false,
        .secondary_ctors = secondary,
        .enum_entries = &.{},
        .companion = try ObjRef(?ObjRef(InstanceData)).init(a, null),
        .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(a, null),
        .nested_classes = &.{},
        .captured_env = globals_for_capture.clone(),
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(a, null),
    });
}

/// Propagate supertype default-thunk slots onto an override lacking its own thunk.
pub fn propagateInheritedDefaults(a: Allocator, module: *Module, func_defaults: *std.AutoHashMap(u32, []?FuncId)) Allocator.Error!void {
    var by_id = std.AutoHashMap(u32, usize).init(a);
    defer by_id.deinit();
    for (module.classes.items, 0..) |*c, i| try by_id.put(c.id.int(), i);

    const Inherited = struct { fid: FuncId, slots: []?FuncId };
    var inherited: std.ArrayList(Inherited) = .empty;
    defer inherited.deinit(a);

    for (module.classes.items) |*c| {
        var anc: std.ArrayList(usize) = .empty;
        defer anc.deinit(a);
        var seen = std.AutoHashMap(u32, void).init(a);
        defer seen.deinit();
        // Ancestors in DECLARATION order, each direct supertype's chain in turn: the fold is
        // first-wins per slot, so `Impl : A2, B` with `A2 : A` takes A's default over B's.
        for (c.supertypes) |direct| {
            var stack: std.ArrayList(ClassId) = .empty;
            defer stack.deinit(a);
            try stack.append(a, direct);
            while (stack.pop()) |sid| {
                if ((try seen.getOrPut(sid.int())).found_existing) continue;
                if (by_id.get(sid.int())) |idx| {
                    try anc.append(a, idx);
                    // Push supertypes reversed so they pop in declaration order.
                    const supers = module.classes.items[idx].supertypes;
                    var i = supers.len;
                    while (i > 0) {
                        i -= 1;
                        try stack.append(a, supers[i]);
                    }
                }
            }
        }

        for (c.methods) |m| {
            const mf = module.funcById(m) orelse continue;
            const mname = mf.name;
            const marity = mf.params.len;

            var merged: ?std.ArrayList(?FuncId) = null;
            defer if (merged) |*ml| ml.deinit(a);
            if (func_defaults.get(m.int())) |existing| {
                var ml: std.ArrayList(?FuncId) = .empty;
                try ml.appendSlice(a, existing);
                merged = ml;
            }

            for (anc.items) |ai| {
                for (module.classes.items[ai].methods) |am| {
                    if (am.int() == m.int()) continue;
                    const af = module.funcById(am) orelse continue;
                    if (!std.mem.eql(u8, af.name, mname) or af.params.len != marity) continue;
                    const bslots = func_defaults.get(am.int()) orelse continue;
                    if (merged == null) {
                        var ml: std.ArrayList(?FuncId) = .empty;
                        try ml.appendNTimes(a, null, bslots.len);
                        merged = ml;
                    }
                    var ml = &merged.?;
                    if (ml.items.len < bslots.len) try ml.appendNTimes(a, null, bslots.len - ml.items.len);
                    for (bslots, 0..) |bs, i| {
                        if (ml.items[i] == null) ml.items[i] = bs;
                    }
                }
            }

            // Abstract and interface declarations consult the abstract-defaults table.
            const self_idx = by_id.get(c.id.int());
            var consult: std.ArrayList(usize) = .empty;
            defer consult.deinit(a);
            try consult.appendSlice(a, anc.items);
            if (self_idx) |si| try consult.append(a, si);
            for (consult.items) |ai| {
                const cn = module.classes.items[ai].name;
                const cn_simple = if (std.mem.findScalarLast(u8, cn, '.')) |dot| cn[dot + 1 ..] else cn;
                const bslots = module.registry.abstract_member_defaults.get(.{ .a = cn, .b = mname }) orelse
                    module.registry.abstract_member_defaults.get(.{ .a = cn_simple, .b = mname }) orelse continue;
                if (merged == null) {
                    var ml: std.ArrayList(?FuncId) = .empty;
                    try ml.appendNTimes(a, null, bslots.items.len);
                    merged = ml;
                }
                var ml = &merged.?;
                if (ml.items.len < bslots.items.len) try ml.appendNTimes(a, null, bslots.items.len - ml.items.len);
                for (bslots.items, 0..) |bs, i| {
                    if (ml.items[i] == null) ml.items[i] = bs;
                }
            }

            if (merged) |*ml| {
                const cur = func_defaults.get(m.int());
                const changed = cur == null or !slotsEql(cur.?, ml.items);
                if (changed) {
                    try inherited.append(a, .{ .fid = m, .slots = try a.dupe(?FuncId, ml.items) });
                }
            }
        }
    }

    for (inherited.items) |entry| {
        try func_defaults.put(entry.fid.int(), entry.slots);
    }
}

pub fn slotsEql(x: []const ?FuncId, y: []const ?FuncId) bool {
    if (x.len != y.len) return false;
    for (x, y) |xa, ya| {
        if (xa == null and ya == null) continue;
        if (xa == null or ya == null) return false;
        if (xa.?.int() != ya.?.int()) return false;
    }
    return true;
}

pub fn retainDecl(
    a: Allocator,
    d: *const Decl,
    fqn_overrides: *const SpanStrMap,
    func_fqn_overrides: *const SpanStrMap,
    package_prefix: []const u8,
    actual_func_names: *const StringSet,
    actual_class_names_set: *const StringSet,
    actual_object_names_set: *const StringSet,
    actual_prop_names: *const StringSet,
) Allocator.Error!bool {
    _ = fqn_overrides;
    switch (d.*) {
        .Function => |*f| {
            if (!f.is_expect and std.mem.eql(u8, f.name.name, "suspendCoroutineUninterceptedOrReturn") and f.is_inline and f.is_suspend) return false;
            // Intrinsic-backed declarations are RETAINED for a symbol table with no holes:
            // `linkResolvedForms` binds the executable form to the host implementation.
            if (!f.is_expect) return true;
            const fqn = try resolveFqn(a, func_fqn_overrides, f.span, package_prefix, f.name.name);
            // Superseded only by an `actual` in its OWN package: a same-named actual elsewhere
            // implements a different declaration.
            if (actual_func_names.contains(fqn)) return false;
            const receiver_name: ?[]const u8 = if (f.receiver_type) |*rt|
                rt.qualified_path orelse rt.name.name
            else
                null;
            // A declaration with an exact host ABI symbol survives with its ordinary FuncId identity.
            if (stdlib.declarationHostSymbol(fqn, receiver_name, f.name.name) != null) return true;
            if (f.receiver_type == null) {
                const kotlin_fqn = try std.fmt.allocPrint(a, "kotlin.{s}", .{f.name.name});
                if (stdlib.implementation(kotlin_fqn) != null) return false;
            }
            if (std.mem.startsWith(u8, fqn, "kotlin.coroutines.")) return false;
            return true;
        },
        .Class => |*c| return !(c.is_expect and actual_class_names_set.contains(c.name.name)),
        .Object => |*o| return !(o.is_expect and actual_object_names_set.contains(o.name.name)),
        .Property => |p| {
            if (std.mem.eql(u8, p.name.name, "coroutineContext") or std.mem.eql(u8, p.name.name, "isInitialized")) return false;
            return !(p.is_expect and actual_prop_names.contains(p.name.name));
        },
        else => return true,
    }
}

pub fn sameExpectActualTypeHead(a: *const ast.TypeRef, b: *const ast.TypeRef) bool {
    if (!std.mem.eql(u8, a.name.name, b.name.name) or a.nullable != b.nullable) return false;
    if ((a.function == null) != (b.function == null)) return false;
    if (a.function) |af| {
        const bf = b.function.?;
        if (af.params.len != bf.params.len or af.is_suspend != bf.is_suspend) return false;
        if ((af.receiver == null) != (bf.receiver == null)) return false;
    }
    return true;
}

/// True when the two have the same callable signature.
pub fn transplantExpectMemberDefaults(actual: *ast.Function, expected: *const ast.Function) bool {
    if (!std.mem.eql(u8, actual.name.name, expected.name.name)) return false;
    if (actual.params.len != expected.params.len) return false;
    if ((actual.receiver_type == null) != (expected.receiver_type == null)) return false;
    if (actual.receiver_type) |*ar| {
        if (!sameExpectActualTypeHead(ar, &expected.receiver_type.?)) return false;
    }
    for (actual.params, expected.params) |*ap, *ep| {
        if (!std.mem.eql(u8, ap.name.name, ep.name.name)) return false;
        if (!sameExpectActualTypeHead(&ap.ty, &ep.ty)) return false;
    }
    for (actual.params, expected.params) |*ap, *ep| {
        if (ap.default == null) ap.default = ep.default;
    }
    return true;
}
