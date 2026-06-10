//! Front-end-to-IR module builder for the IR-native interpreter.
//!
//! This module owns the AST → IR lowering driver: it takes a parsed
//! Kotlin file and produces an `ir.Module` ready for `Vm.run`, along
//! with the synthesised runtime `ClassDef` table and the side tables the
//! Vm consults at dispatch time. Classes are lowered first so
//! `Inst.NewInstance` lookups resolve, then a pre-pass registers stub
//! Funcs for every top-level function so forward references and mutual
//! recursion lower cleanly, then each function body lowers into its
//! reserved slot.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const span = @import("span");
const stdlib = @import("stdlib");

pub const lift = @import("build/lift.zig");

const Allocator = std.mem.Allocator;
const Module = ir.Module;
const FuncId = ir.FuncId;
const ClassId = ir.ClassId;
const Func = ir.Func;
const Param = ir.Param;
const Const = ir.Const;
const ClassDef = runtime.ClassDef;
const ClassParamDef = runtime.ClassParamDef;
const PropertyDef = runtime.PropertyDef;
const TypeShape = runtime.TypeShape;
const InstanceData = runtime.InstanceData;
const Env = runtime.Env;
const ObjRef = runtime.ObjRef;
const Value = runtime.Value;
const KotlinFile = ast.KotlinFile;
const Decl = ast.Decl;
const StringSet = std.StringHashMap(void);

// -------------------------------------------------------------------------
// Shared key/value table types (used by both BuiltModule and the Vm's
// ProgramImage so they agree on shape).
// -------------------------------------------------------------------------

pub const StrPair = struct { a: []const u8, b: []const u8 };

pub const StrPairContext = struct {
    pub fn hash(_: StrPairContext, key: StrPair) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(key.a);
        h.update(&.{0});
        h.update(key.b);
        return h.final();
    }
    pub fn eql(_: StrPairContext, x: StrPair, y: StrPair) bool {
        return std.mem.eql(u8, x.a, y.a) and std.mem.eql(u8, x.b, y.b);
    }
};

/// `(class, member)` → `FuncId` registry table.
pub const PairFuncMap = std.HashMap(StrPair, FuncId, StrPairContext, std.hash_map.default_max_load_percentage);
pub const StrPairSet = std.HashMap(StrPair, void, StrPairContext, std.hash_map.default_max_load_percentage);

pub const ClassTable = std.StringHashMap(ObjRef(ClassDef));

/// `(supertype simple name, thunk FuncId)` class-delegation entry.
pub const StrFunc = struct { name: []const u8, func: FuncId };

/// `(name, FuncId)` top-level property initializer entry.
pub const NameFunc = struct { name: []const u8, func: FuncId };

/// Per enum-entry constructor-arg thunks.
pub const EnumEntryArgInit = struct {
    class_name: []const u8,
    entry_name: []const u8,
    funcs: []FuncId,
};

/// One pre-lowered anon-object / enum-entry override method body.
pub const EnumEntryMethod = struct {
    module: ObjRef(Module),
    func: FuncId,
};

/// Pre-lowered metadata for one secondary constructor. Each entry's
/// `delegation_arg_thunks` evaluate the delegation arguments
/// (`: this(...)` / `: super(...)`) against the secondary's positional
/// params; the Vm then dispatches the resulting args to the primary
/// ctor.
pub const SecondaryCtorEntry = struct {
    param_count: usize,
    /// Declared parameter names, in order.
    param_names: [][]const u8,
    is_super: bool,
    /// `true` for an explicit `: this(...)` delegation.
    is_this: bool,
    delegation_arg_thunks: []FuncId,
    /// Per-parameter default-value thunks (`null` when no default).
    default_arg_thunks: []?FuncId,
    /// Optional body block lowered as a 1-arg fn taking `this`.
    body: ?FuncId,
};

/// Result of building an IR module from a single Kotlin file.
pub const BuiltModule = struct {
    /// The frozen IR module ready for `Vm.run`.
    module: ObjRef(Module),
    /// Per-class runtime metadata, keyed by simple class name.
    classes: ClassTable,
    /// `(class name, property name)` → `FuncId` for body properties
    /// with a literal-style initialiser.
    body_prop_inits: PairFuncMap,
    /// `(class name, property name)` → `FuncId` for body properties
    /// with a custom getter.
    instance_prop_getters: PairFuncMap,
    /// Custom-setter `FuncIds`, keyed the same as getters.
    instance_prop_setters: PairFuncMap,
    /// Parent-ctor argument thunks per class.
    parent_ctor_args: std.StringHashMap([]FuncId),
    /// `init { ... }` blocks per class. Each `FuncId` takes `this`.
    init_blocks: std.StringHashMap([]FuncId),
    /// Top-level property initialisers, in declaration order.
    top_level_props: std.ArrayList(NameFunc),
    /// Top-level extension properties, keyed by `(receiver type, prop)`.
    extension_props: PairFuncMap,
    /// Extension-property setters keyed by `(receiver type, prop)`.
    extension_prop_setters: PairFuncMap,
    /// `FuncId` of the file's `main`, or `null` when there is none.
    main: ?FuncId,
    /// Names of `object Foo { … }` singleton declarations, in source order.
    object_names: std.ArrayList([]const u8),
    /// Outer-class name → synthesised companion singleton global name.
    companion_singletons: std.StringHashMap([]const u8),
    /// Per enum-entry constructor-arg thunks.
    enum_entry_arg_inits: std.ArrayList(EnumEntryArgInit),
    /// Secondary-ctor dispatch table: class name → entries.
    secondary_ctors: std.StringHashMap([]SecondaryCtorEntry),
    /// Per-class primary-constructor default-value thunks.
    primary_ctor_default_thunks: std.StringHashMap([]?FuncId),
    /// Class delegation entries: `class W(g) : Greeter by g`.
    class_delegates: std.StringHashMap([]StrFunc),
    /// Per-function default-arg thunks, keyed by target `FuncId.int()`.
    func_defaults: std.AutoHashMap(u32, []?FuncId),
    /// Inner class → outer class name.
    enclosing_class: std.StringHashMap([]const u8),
    /// Pre-lowered method bodies for enum entries with per-entry
    /// `override fun …` blocks, keyed by `(synth class, method)`.
    enum_entry_methods: std.HashMap(StrPair, EnumEntryMethod, StrPairContext, std.hash_map.default_max_load_percentage),
    /// `(enum class, entry)` → synth class name for entries with methods.
    enum_entry_synth_class: PairStrMap,
    /// Per-function type parameter names, keyed by `FuncId.int()`.
    func_type_params: std.AutoHashMap(u32, [][]const u8),
    /// Top-level property names declared `var/val X by <delegate>`.
    top_level_delegated_props: std.StringHashMap(void),
    /// Body-property `(class, prop)` pairs declared as `by <delegate>`.
    delegated_body_props: StrPairSet,
    allocator: Allocator,

    pub fn deinit(self: *BuiltModule) void {
        self.module.deinit();
        self.classes.deinit();
        self.body_prop_inits.deinit();
        self.instance_prop_getters.deinit();
        self.instance_prop_setters.deinit();
        self.parent_ctor_args.deinit();
        self.init_blocks.deinit();
        self.top_level_props.deinit(self.allocator);
        self.extension_props.deinit();
        self.extension_prop_setters.deinit();
        self.object_names.deinit(self.allocator);
        self.companion_singletons.deinit();
        self.enum_entry_arg_inits.deinit(self.allocator);
        self.secondary_ctors.deinit();
        self.primary_ctor_default_thunks.deinit();
        self.class_delegates.deinit();
        self.func_defaults.deinit();
        self.enclosing_class.deinit();
        self.enum_entry_methods.deinit();
        self.enum_entry_synth_class.deinit();
        self.func_type_params.deinit();
        self.top_level_delegated_props.deinit();
        self.delegated_body_props.deinit();
    }
};

/// `(class, entry)` → synth class name.
pub const PairStrMap = std.HashMap(StrPair, []const u8, StrPairContext, std.hash_map.default_max_load_percentage);

/// Build an empty `BuiltModule` shell around `module`.
fn emptyBuilt(allocator: Allocator, module: ObjRef(Module), main: ?FuncId) BuiltModule {
    return .{
        .module = module,
        .classes = ClassTable.init(allocator),
        .body_prop_inits = PairFuncMap.init(allocator),
        .instance_prop_getters = PairFuncMap.init(allocator),
        .instance_prop_setters = PairFuncMap.init(allocator),
        .parent_ctor_args = std.StringHashMap([]FuncId).init(allocator),
        .init_blocks = std.StringHashMap([]FuncId).init(allocator),
        .top_level_props = .empty,
        .extension_props = PairFuncMap.init(allocator),
        .extension_prop_setters = PairFuncMap.init(allocator),
        .main = main,
        .object_names = .empty,
        .companion_singletons = std.StringHashMap([]const u8).init(allocator),
        .enum_entry_arg_inits = .empty,
        .secondary_ctors = std.StringHashMap([]SecondaryCtorEntry).init(allocator),
        .primary_ctor_default_thunks = std.StringHashMap([]?FuncId).init(allocator),
        .class_delegates = std.StringHashMap([]StrFunc).init(allocator),
        .func_defaults = std.AutoHashMap(u32, []?FuncId).init(allocator),
        .enclosing_class = std.StringHashMap([]const u8).init(allocator),
        .enum_entry_methods = std.HashMap(StrPair, EnumEntryMethod, StrPairContext, std.hash_map.default_max_load_percentage).init(allocator),
        .enum_entry_synth_class = PairStrMap.init(allocator),
        .func_type_params = std.AutoHashMap(u32, [][]const u8).init(allocator),
        .top_level_delegated_props = std.StringHashMap(void).init(allocator),
        .delegated_body_props = StrPairSet.init(allocator),
        .allocator = allocator,
    };
}

// -------------------------------------------------------------------------
// Span-keyed override maps (per-declaration FQN overrides for pack files).
// -------------------------------------------------------------------------

const Span = span.Span;
const SpanContext = struct {
    pub fn hash(_: SpanContext, key: Span) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key));
        return h.final();
    }
    pub fn eql(_: SpanContext, x: Span, y: Span) bool {
        return std.meta.eql(x, y);
    }
};
const SpanStrMap = std.HashMap(Span, []const u8, SpanContext, std.hash_map.default_max_load_percentage);

/// File-scoped class registry: simple name → AST class.
const FileClasses = std.StringHashMap(*const ast.Class);

/// Lower a single file's declarations into an IR module.
pub fn buildModule(allocator: Allocator, file: *const KotlinFile) Allocator.Error!BuiltModule {
    var fqn = SpanStrMap.init(allocator);
    defer fqn.deinit();
    var func_fqn = SpanStrMap.init(allocator);
    defer func_fqn.deinit();
    return buildModuleWithOverrides(allocator, file, &fqn, &func_fqn);
}

/// Drive `buildModule` against multiple parsed files. All declarations
/// from every file are concatenated into one synthesised file and
/// lowered as a single program.
pub fn buildModuleFiles(allocator: Allocator, files: []const KotlinFile) Allocator.Error!BuiltModule {
    var decls: std.ArrayList(Decl) = .empty;
    defer decls.deinit(allocator);
    var imports: std.ArrayList(ast.ImportDecl) = .empty;
    defer imports.deinit(allocator);

    var fqn_overrides = SpanStrMap.init(allocator);
    defer fqn_overrides.deinit();
    var func_fqn_overrides = SpanStrMap.init(allocator);
    defer func_fqn_overrides.deinit();

    for (files) |*f| {
        const prefix = try packagePrefix(allocator, f.package);
        for (f.decls) |*d| {
            try collectClassFqns(allocator, d, prefix, &fqn_overrides);
            if (d.* == .Function and prefix.len != 0) {
                try func_fqn_overrides.put(d.Function.span, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, d.Function.name.name }));
            }
        }
        try decls.appendSlice(allocator, f.decls);
        try imports.appendSlice(allocator, f.imports);
    }

    const combined = KotlinFile{
        .package = null,
        .imports = try imports.toOwnedSlice(allocator),
        .decls = try decls.toOwnedSlice(allocator),
        .span = Span.init(span.FileId.from(0), 0, 0),
    };
    return buildModuleWithOverrides(allocator, &combined, &fqn_overrides, &func_fqn_overrides);
}

fn packagePrefix(allocator: Allocator, pkg: ?ast.PackageHeader) Allocator.Error![]const u8 {
    const p = pkg orelse return "";
    return joinIdents(allocator, p.path, ".");
}

fn joinIdents(allocator: Allocator, idents: []const ast.Ident, sep: []const u8) Allocator.Error![]const u8 {
    if (idents.len == 0) return "";
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (idents, 0..) |id, i| {
        if (i != 0) try buf.appendSlice(allocator, sep);
        try buf.appendSlice(allocator, id.name);
    }
    return buf.toOwnedSlice(allocator);
}

fn collectClassFqns(allocator: Allocator, d: *const Decl, pkg: []const u8, out: *SpanStrMap) Allocator.Error!void {
    if (d.* == .Class) {
        const c = &d.Class;
        if (pkg.len != 0) {
            try out.put(c.span, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ pkg, c.name.name }));
        }
        const inner_pkg = if (pkg.len == 0)
            c.name.name
        else
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ pkg, c.name.name });
        for (c.members) |*m| try collectClassFqns(allocator, m, inner_pkg, out);
    }
    if (d.* == .Object and pkg.len != 0) {
        try out.put(d.Object.span, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ pkg, d.Object.name.name }));
    }
}

/// Resolve a declaration's FQN: the per-span override if present, else
/// the package-qualified name, else the bare simple name.
fn resolveFqn(allocator: Allocator, overrides: *const SpanStrMap, decl_span: Span, package_prefix: []const u8, simple: []const u8) Allocator.Error![]const u8 {
    if (overrides.get(decl_span)) |f| return f;
    if (package_prefix.len == 0) return simple;
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ package_prefix, simple });
}

const packageOfFqn = ir.packageOfFqn;

// -------------------------------------------------------------------------
// AST-walk helpers (member-name collection across the class hierarchy).
// -------------------------------------------------------------------------

fn collectHierarchyMethodNames(start: []const u8, by_name: *const FileClasses, out: *StringSet, seen: *StringSet) Allocator.Error!void {
    const gop = try seen.getOrPut(start);
    if (gop.found_existing) return;
    const c = by_name.get(start) orelse return;
    for (c.members) |*m| {
        if (m.* == .Function) try out.put(m.Function.name.name, {});
    }
    for (c.supertypes) |*st| try collectHierarchyMethodNames(st.name.name, by_name, out, seen);
}

fn collectHierarchyMemberNames(start: []const u8, by_name: *const FileClasses, out: *StringSet, seen: *StringSet) Allocator.Error!void {
    const gop = try seen.getOrPut(start);
    if (gop.found_existing) return;
    const c = by_name.get(start) orelse return;
    for (c.primary_params) |*p| {
        if (p.property != null) try out.put(p.name.name, {});
    }
    for (c.members) |*m| {
        switch (m.*) {
            .Function => |*f| try out.put(f.name.name, {}),
            .Property => |*p| try out.put(p.name.name, {}),
            else => {},
        }
    }
    for (c.supertypes) |*st| try collectHierarchyMemberNames(st.name.name, by_name, out, seen);
}

/// Int literals narrow to i32 and Double literals narrow to f32, matching
/// Kotlin's Int/Float literal types.
fn literalToConst(e: *const ast.Expr) ?Const {
    return switch (e.*) {
        .IntLit => |lit| switch (lit.kind) {
            .Int, .UInt => Const{ .Int = @truncate(lit.value) },
            .Long, .ULong => Const{ .Long = lit.value },
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
pub fn primitiveZeroFor(p: *const ast.Property) ?Value {
    if (p.init != null or p.is_abstract or p.is_lateinit or p.getter != null or p.delegate != null) return null;
    const ty = p.ty orelse return null;
    if (ty.nullable) return null;
    const n = ty.name.name;
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

// -------------------------------------------------------------------------
// The whole-file lowering pass.
// -------------------------------------------------------------------------

fn buildModuleWithOverrides(
    allocator: Allocator,
    file: *const KotlinFile,
    fqn_overrides: *const SpanStrMap,
    func_fqn_overrides: *const SpanStrMap,
) Allocator.Error!BuiltModule {
    const module_ref = try ObjRef(Module).init(allocator, Module.default(allocator));
    // The ObjRef holds the only handle during the build and nothing else
    // borrows it, so a raw pointer into the cell is a stable `*Module` for
    // the lowering driver (mirrors Rust owning `module` then `Arc::new`).
    const module: *Module = &module_ref.cell.data;
    const a = module.registry.allocator;

    const package_prefix = try packagePrefix(a, file.package);

    var object_names: std.ArrayList([]const u8) = .empty;
    var companion_singletons = std.StringHashMap([]const u8).init(a);
    var nested_outer_members = lift.OuterMembers.init(a);
    var enclosing_class = lift.EnclosingMap.init(a);
    var nested_object_aliases = lift.AliasMap.init(a);

    // `actual object`/`actual class` names supersede a matching `expect`.
    var actual_object_names = StringSet.init(a);
    defer actual_object_names.deinit();
    var actual_class_names = StringSet.init(a);
    defer actual_class_names.deinit();
    for (file.decls) |*d| {
        switch (d.*) {
            .Object => |*o| if (o.is_actual) try actual_object_names.put(o.name.name, {}),
            .Class => |*c| if (c.is_actual) try actual_class_names.put(c.name.name, {}),
            else => {},
        }
    }

    // User (package-less) top-level type names, used to detect pack-private
    // object name collisions.
    var user_top_type_names = StringSet.init(a);
    defer user_top_type_names.deinit();
    for (file.decls) |*d| {
        switch (d.*) {
            .Class => |*c| if (fqn_overrides.get(c.span) == null) try user_top_type_names.put(c.name.name, {}),
            .Object => |*o| if (fqn_overrides.get(o.span) == null) try user_top_type_names.put(o.name.name, {}),
            else => {},
        }
    }

    // package -> set of pack class/object simple names declared in it.
    var pack_pkg_types = std.StringHashMap(StringSet).init(a);
    defer {
        var it = pack_pkg_types.valueIterator();
        while (it.next()) |s| s.deinit();
        pack_pkg_types.deinit();
    }
    for (file.decls) |*d| {
        const sp_simple: ?struct { sp: Span, simple: []const u8 } = switch (d.*) {
            .Class => |*c| .{ .sp = c.span, .simple = c.name.name },
            .Object => |*o| .{ .sp = o.span, .simple = o.name.name },
            else => null,
        };
        if (sp_simple) |ss| {
            if (fqn_overrides.get(ss.sp)) |f| {
                if (std.mem.lastIndexOfScalar(u8, f, '.')) |dot| {
                    const pkg = f[0..dot];
                    const gop = try pack_pkg_types.getOrPut(pkg);
                    if (!gop.found_existing) gop.value_ptr.* = StringSet.init(a);
                    try gop.value_ptr.put(ss.simple, {});
                }
            }
        }
    }

    // True top-level type names (any package), used to mangle nested types
    // that would collide.
    var top_level_type_names = StringSet.init(a);
    defer top_level_type_names.deinit();
    for (file.decls) |*d| {
        switch (d.*) {
            .Class => |*c| try top_level_type_names.put(c.name.name, {}),
            .Object => |*o| try top_level_type_names.put(o.name.name, {}),
            else => {},
        }
    }

    var used_qualified_supertypes = StringSet.init(a);
    defer used_qualified_supertypes.deinit();
    try lift.collectUsedQualifiedSupertypes(a, file.decls, &used_qualified_supertypes);

    var mangled_nested = lift.MangledMap.init(a);
    defer mangled_nested.deinit();

    var all_decls: std.ArrayList(Decl) = .empty;

    var lift_ctx = lift.LiftCtx{
        .allocator = a,
        .out_decls = &all_decls,
        .object_names = &object_names,
        .companion_singletons = &companion_singletons,
        .nested_outer_members = &nested_outer_members,
        .enclosing_class = &enclosing_class,
        .nested_object_aliases = &nested_object_aliases,
        .top_level_type_names = &top_level_type_names,
        .mangled_nested = &mangled_nested,
        .used_qualified_supertypes = &used_qualified_supertypes,
    };

    // Pending aliases for mangled pack-private objects.
    const PendingAlias = struct { cls: []const u8, simple: []const u8, mangled: []const u8 };
    var pending_object_aliases: std.ArrayList(PendingAlias) = .empty;
    defer pending_object_aliases.deinit(a);

    for (file.decls) |*d| {
        switch (d.*) {
            .Object => |*o| {
                if (o.is_expect and actual_object_names.contains(o.name.name)) continue;
                const is_pack_private = o.visibility == .Private and fqn_overrides.get(o.span) != null;
                const collides = user_top_type_names.contains(o.name.name);
                if (is_pack_private and collides) {
                    const fqn = fqn_overrides.get(o.span) orelse "";
                    const mangled = try replaceDotWithDollar(a, fqn);
                    try object_names.append(a, mangled);
                    var synth = try lift.synthesizeClassFromObject(a, o);
                    synth.name = .{ .name = mangled, .span = o.name.span };
                    try all_decls.append(a, .{ .Class = synth });
                    if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |dot| {
                        const pkg = fqn[0..dot];
                        if (pack_pkg_types.get(pkg)) |types| {
                            var it = types.keyIterator();
                            while (it.next()) |cls| {
                                if (!std.mem.eql(u8, cls.*, o.name.name)) {
                                    try pending_object_aliases.append(a, .{ .cls = cls.*, .simple = o.name.name, .mangled = mangled });
                                }
                            }
                        }
                    }
                    continue;
                }
                try object_names.append(a, o.name.name);
                const synth = try lift.synthesizeClassFromObject(a, o);
                try lift.liftClassRecursive(&lift_ctx, &synth, &.{});
                try all_decls.append(a, .{ .Class = synth });
            },
            .Class => |*c| {
                if (c.is_expect and actual_class_names.contains(c.name.name)) continue;
                try lift.liftClassRecursive(&lift_ctx, c, &.{});
                try all_decls.append(a, d.*);
            },
            else => try all_decls.append(a, d.*),
        }
    }

    for (pending_object_aliases.items) |pa| {
        const gop = try nested_object_aliases.getOrPut(pa.cls);
        if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap([]const u8).init(a);
        try gop.value_ptr.put(pa.simple, pa.mangled);
    }

    // Repoint supertype references to a nested class that was mangled.
    if (mangled_nested.count() != 0) {
        for (all_decls.items) |*d| {
            if (d.* == .Class) {
                for (d.Class.supertypes) |*t| {
                    if (resolveMangled(a, &mangled_nested, t)) |mangled| {
                        t.name.name = mangled;
                    }
                }
            }
        }
    }

    // Pre-collect actual-name sets to drop superseded `expect` decls.
    var actual_func_names = StringSet.init(a);
    defer actual_func_names.deinit();
    var actual_class_names_set = StringSet.init(a);
    defer actual_class_names_set.deinit();
    var actual_object_names_set = StringSet.init(a);
    defer actual_object_names_set.deinit();
    var actual_prop_names = StringSet.init(a);
    defer actual_prop_names.deinit();
    for (all_decls.items) |*d| {
        switch (d.*) {
            .Function => |*f| if (f.is_actual) try actual_func_names.put(f.name.name, {}),
            .Class => |*c| if (c.is_actual) try actual_class_names_set.put(c.name.name, {}),
            .Object => |*o| if (o.is_actual) try actual_object_names_set.put(o.name.name, {}),
            .Property => |*p| if (p.is_actual) try actual_prop_names.put(p.name.name, {}),
            else => {},
        }
    }

    // Drop superseded `expect` decls + the upstream stubs klio overrides.
    var decls_list: std.ArrayList(Decl) = .empty;
    for (all_decls.items) |*d| {
        if (try retainDecl(a, d, fqn_overrides, func_fqn_overrides, package_prefix, &actual_func_names, &actual_class_names_set, &actual_object_names_set, &actual_prop_names)) {
            try decls_list.append(a, d.*);
        }
    }
    const decls = decls_list.items;

    // Map every class declaration by simple name.
    var file_classes = FileClasses.init(a);
    defer file_classes.deinit();
    for (decls) |*d| {
        if (d.* == .Class) try file_classes.put(d.Class.name.name, &d.Class);
    }

    // Collect class / companion / top-level `const val name = <literal>`.
    {
        for (decls) |*d| {
            switch (d.*) {
                .Class => |*c| try collectConsts(module, c.name.name, c.members),
                .Property => |*p| if (p.is_const) {
                    if (p.init) |*init| {
                        if (literalToConst(init)) |cst| {
                            try module.registry.class_const_inits.put(.{ .a = "", .b = p.name.name }, cst);
                        }
                    }
                },
                else => {},
            }
        }
    }

    // Per-class transitive member-function-name set.
    {
        var it = file_classes.keyIterator();
        while (it.next()) |cname| {
            var methods = StringSet.init(a);
            var seen = StringSet.init(a);
            defer seen.deinit();
            try collectHierarchyMethodNames(cname.*, &file_classes, &methods, &seen);
            try module.registry.hierarchy_methods.put(cname.*, methods);
        }
    }
    // `nested_object_aliases` is needed by the lowerer; install on registry.
    {
        var it = nested_object_aliases.iterator();
        while (it.next()) |e| {
            var inner = std.StringHashMap([]const u8).init(a);
            var iit = e.value_ptr.iterator();
            while (iit.next()) |ie| try inner.put(ie.key_ptr.*, ie.value_ptr.*);
            try module.registry.nested_object_aliases.put(e.key_ptr.*, inner);
        }
    }

    // Make every `inline fun` body available to the lowerer by simple name.
    //
    // The three tables below are installed into the lowerer's
    // build-scoped thread-locals (`setInlineFnAsts` &c.), each of which
    // `deinit`s the table left by the *previous* build before storing the
    // new one. A managed `StringHashMap` captures its allocator, so that
    // teardown runs through whatever allocator backed the container — and
    // the previous build's `a` is typically a per-run arena that has
    // already been torn down by the time the next build installs its
    // tables. Backing the *containers* with the process-lifetime page
    // allocator keeps that cross-build teardown sound: the next build's
    // `deinit` frees a still-valid block. Keys and value slices stay in
    // the build arena `a` (only their inline slice headers live in the
    // container; `deinit` never dereferences the freed contents), so the
    // arena reclaims them and no growing leak accumulates.
    const tl = std.heap.page_allocator;
    {
        var inline_fns = std.StringHashMap(std.ArrayList(*const ast.Function)).init(a);
        for (decls) |*d| try collectInline(a, d, &inline_fns);
        var frozen = std.StringHashMap([]const *const ast.Function).init(tl);
        var it = inline_fns.iterator();
        while (it.next()) |e| {
            try frozen.put(e.key_ptr.*, try e.value_ptr.toOwnedSlice(a));
        }
        inline_fns.deinit();
        ir.lower.setInlineFnAsts(frozen);

        // Default-import host bindings shadow same-simple-name inline fns.
        var shadowed = StringSet.init(tl);
        var fqn_it = stdlib.implementations.allFqns();
        while (fqn_it.next()) |fqn| {
            if (std.mem.lastIndexOfScalar(u8, fqn, '.')) |dot| {
                const scope = fqn[0..dot];
                const simple = fqn[dot + 1 ..];
                if (stdlib.isImplicitlyImportedPackage(scope)) {
                    try shadowed.put(simple, {});
                }
            }
        }
        ir.lower.setShadowedInlineNames(shadowed);
    }

    // Top-level (file-scope) property names.
    {
        var top_props = StringSet.init(tl);
        for (decls) |*d| {
            if (d.* == .Property and d.Property.receiver_type == null) {
                try top_props.put(d.Property.name.name, {});
            }
        }
        ir.lower.setTopLevelPropNames(top_props);
    }

    // Non-wildcard imports keyed by declaring file then bound leaf name.
    for (file.imports) |*imp| {
        if (imp.wildcard or imp.path.len == 0) continue;
        var segs: std.ArrayList([]const u8) = .empty;
        for (imp.path) |id| try segs.append(a, id.name);
        const leaf = if (imp.alias) |al| al.name else imp.path[imp.path.len - 1].name;
        const fgop = try module.registry.import_aliases.getOrPut(imp.span.file);
        if (!fgop.found_existing) fgop.value_ptr.* = std.StringHashMap(std.ArrayList([]const u8)).init(a);
        try fgop.value_ptr.put(leaf, segs);
    }

    // Pre-register every class name so `classId` resolves order-independently.
    for (decls) |*d| {
        if (d.* == .Class) _ = try module.reserveClass(a, d.Class.name.name, d.Class.is_inner);
    }
    // Lower each class.
    var empty_set = StringSet.init(a);
    defer empty_set.deinit();
    for (decls) |*d| {
        if (d.* == .Class) {
            const c = &d.Class;
            const extras: *const StringSet = nested_outer_members.getPtr(c.name.name) orelse &empty_set;
            const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
            _ = try ir.lower.lowerClassWithExtrasFqn(module, c, &file_classes, extras, cfqn);
        }
    }

    // Phase 1 of two-phase consumption: register every top-level
    // function's HEADER — its package-qualified FQN, declaring package,
    // and receiver type — into the complete header set BEFORE any body is
    // lowered. Classes were reserved just above; together these phase-1
    // headers span every pack, feature, and user file, so phase-2 body
    // lowering resolves bare calls against the full package-qualified set
    // through the symbol index rather than a partially-populated table.
    var stub_ids: std.ArrayList(FuncId) = .empty;
    defer stub_ids.deinit(a);
    for (decls) |*d| {
        if (d.* == .Function) {
            const f = &d.Function;
            const id = FuncId.from(@intCast(module.funcs.items.len));
            const fqn = try resolveFqn(a, func_fqn_overrides, f.span, package_prefix, f.name.name);
            var stub_params: []Param = &.{};
            if (f.receiver_type) |rt| {
                const ps = try a.alloc(Param, 1);
                ps[0] = .{
                    .name = "this",
                    .ty = .{ .name = rt.name.name, .nullable = rt.nullable, .args = &.{} },
                    .default = null,
                    .is_property = false,
                    .is_vararg = false,
                    .has_default = false,
                };
                stub_params = ps;
            }
            try module.funcs.append(a, .{
                .id = id,
                .name = f.name.name,
                .fqn = fqn,
                .package = packageOfFqn(fqn, f.name.name),
                .params = stub_params,
                .return_ty = ir.build.typeUnit(),
                .n_locals = 0,
                .blocks = &.{},
                .entry = ir.BlockId.from(0),
                .is_suspend = false,
                .is_tailrec = f.is_tailrec,
                .is_lambda = false,
                .is_inline = f.is_inline,
                .capture_order = &.{},
                .implicit_label = null,
                .low_priority = false,
            });
            try module.func_index.append(a, .{ .name = f.name.name, .id = id });
            const gop = try module.func_name_index.getOrPut(f.name.name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, id);
            if (f.is_tailrec) try module.tailrec_fn_names.append(a, f.name.name);
            try module.decl_user_params.put(id.int(), @intCast(f.params.len));
            {
                const has_vararg = f.params.len != 0 and f.params[f.params.len - 1].is_vararg;
                var required: u32 = 0;
                for (f.params) |*p| {
                    if (p.default == null and !p.is_vararg) required += 1;
                }
                try module.decl_user_arity.put(id.int(), .{ .required = required, .total = @intCast(f.params.len), .trailing_vararg = has_vararg });
            }
            try stub_ids.append(a, id);
        }
    }

    // Phase 2 of two-phase consumption: lower each function body into its
    // reserved slot, resolving bodies and extension-receiver bindings
    // against the now-complete phase-1 header set (above).
    var main_id: ?FuncId = null;
    var func_defaults = std.AutoHashMap(u32, []?FuncId).init(a);
    var func_type_params = std.AutoHashMap(u32, [][]const u8).init(a);
    var stub_cursor: usize = 0;
    for (decls) |*d| {
        if (d.* == .Function) {
            const f = &d.Function;
            const stub_pkg = module.funcs.items[stub_ids.items[stub_cursor].int()].package;
            const prev_pkg = ir.lower.decl.setLowerSelfPackage(stub_pkg);
            const func = try ir.lower.lowerFunctionBodyInto(module, f, &file_classes);
            _ = ir.lower.decl.setLowerSelfPackage(prev_pkg);
            const id = stub_ids.items[stub_cursor];
            stub_cursor += 1;
            var placed = func;
            placed.id = id;
            // Preserve the stub's FQN + package (carry the package prefix).
            placed.fqn = module.funcs.items[id.int()].fqn;
            placed.package = module.funcs.items[id.int()].package;
            module.funcs.items[id.int()] = placed;
            if (std.mem.eql(u8, f.name.name, "main")) main_id = id;
            try module.top_level.append(a, id);

            if (f.type_params.len != 0) {
                var names: std.ArrayList([]const u8) = .empty;
                for (f.type_params) |*tp| try names.append(a, tp.name.name);
                try func_type_params.put(id.int(), try names.toOwnedSlice(a));
            }

            var any_default = false;
            for (f.params) |*p| {
                if (p.default != null) any_default = true;
            }
            if (any_default) {
                const lowered_names = module.funcs.items[id.int()].params;
                const offset = if (lowered_names.len > f.params.len) lowered_names.len - f.params.len else 0;
                var name_refs: std.ArrayList([]const u8) = .empty;
                defer name_refs.deinit(a);
                for (lowered_names) |*p| try name_refs.append(a, p.name);
                var slots: std.ArrayList(?FuncId) = .empty;
                var i: usize = 0;
                while (i < offset) : (i += 1) try slots.append(a, null);
                for (f.params, 0..) |*p, idx| {
                    if (p.default) |*default_expr| {
                        const bind_upto = @min(offset + idx, name_refs.items.len);
                        const widened = ir.lower.widenNumericLiteral(default_expr, &p.ty);
                        const thunk_name = try std.fmt.allocPrint(a, "__default_{s}_{s}", .{ f.name.name, p.name.name });
                        const target_expr: *const ast.Expr = if (widened) |*w| w else default_expr;
                        const fid = try ir.lower.lowerExprAsParamThunk(module, name_refs.items[0..bind_upto], target_expr, thunk_name);
                        try slots.append(a, fid);
                    } else {
                        try slots.append(a, null);
                    }
                }
                try func_defaults.put(id.int(), try slots.toOwnedSlice(a));
            }
        }
    }

    // Body-property initialisers, getters, setters, ctor defaults.
    var body_prop_inits = PairFuncMap.init(a);
    var instance_prop_getters = PairFuncMap.init(a);
    var instance_prop_setters = PairFuncMap.init(a);
    var delegated_body_props = StrPairSet.init(a);
    var primary_ctor_default_thunks = std.StringHashMap([]?FuncId).init(a);
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        var own_members = StringSet.init(a);
        defer own_members.deinit();
        for (c.primary_params) |*p| {
            if (p.property != null) try own_members.put(p.name.name, {});
        }
        for (c.members) |*m| {
            switch (m.*) {
                .Property => |*p| try own_members.put(p.name.name, {}),
                .Function => |*f| try own_members.put(f.name.name, {}),
                else => {},
            }
        }
        var prop_init_params: std.ArrayList([]const u8) = .empty;
        defer prop_init_params.deinit(a);
        try prop_init_params.append(a, "this");
        for (c.primary_params) |*p| try prop_init_params.append(a, p.name.name);

        var any_ctor_default = false;
        for (c.primary_params) |*p| {
            if (p.default != null) any_ctor_default = true;
        }
        if (any_ctor_default) {
            var slots = try a.alloc(?FuncId, c.primary_params.len);
            for (c.primary_params, 0..) |*p, i| {
                if (p.default) |*e| {
                    const nm = try std.fmt.allocPrint(a, "__ctor_default_{s}_{s}", .{ c.name.name, p.name.name });
                    slots[i] = try ir.lower.lowerAccessorExpr(module, c.name.name, &own_members, prop_init_params.items, e, nm);
                } else {
                    slots[i] = null;
                }
            }
            try primary_ctor_default_thunks.put(c.name.name, slots);
        }

        for (c.members) |*m| {
            if (m.* != .Property) continue;
            const p = &m.Property;
            if (p.init) |*init| {
                const nm = try std.fmt.allocPrint(a, "__init_prop_{s}_{s}", .{ c.name.name, p.name.name });
                const fid = try ir.lower.lowerAccessorExprWithExpected(module, c.name.name, &own_members, prop_init_params.items, init, nm, p.ty);
                try body_prop_inits.put(.{ .a = c.name.name, .b = p.name.name }, fid);
            } else if (p.delegate) |*delegate| {
                try delegated_body_props.put(.{ .a = c.name.name, .b = p.name.name }, {});
                const nm = try std.fmt.allocPrint(a, "__delegate_prop_{s}_{s}", .{ c.name.name, p.name.name });
                const fid = try ir.lower.lowerAccessorExpr(module, c.name.name, &own_members, prop_init_params.items, delegate, nm);
                try body_prop_inits.put(.{ .a = c.name.name, .b = p.name.name }, fid);
            }
            if (p.getter) |*getter| {
                const nm = try std.fmt.allocPrint(a, "__get_{s}_{s}", .{ c.name.name, p.name.name });
                const fid = switch (getter.body) {
                    .Expr => |body| blk: {
                        const rewritten = try lift.substituteFieldWithThis(a, p.name.name, &body);
                        break :blk try ir.lower.lowerAccessorExpr(module, c.name.name, &own_members, &.{"this"}, rewritten, nm);
                    },
                    .Block => |blk_body| blk: {
                        const rewritten = try lift.rewriteBlockField(a, &blk_body, p.name.name);
                        break :blk try ir.lower.lowerAccessorBlock(module, c.name.name, &own_members, &.{"this"}, &rewritten, nm);
                    },
                };
                try instance_prop_getters.put(.{ .a = c.name.name, .b = p.name.name }, fid);
                const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
                if (!std.mem.eql(u8, cfqn, c.name.name)) {
                    try instance_prop_getters.put(.{ .a = cfqn, .b = p.name.name }, fid);
                }
            }
            if (p.setter) |*setter| {
                const setter_param_name = if (setter.params.len != 0) setter.params[0].name else "value";
                const nm = try std.fmt.allocPrint(a, "__set_{s}_{s}", .{ c.name.name, p.name.name });
                const fid = switch (setter.body) {
                    .Expr => |body| blk: {
                        const rewritten = try lift.substituteFieldWithThis(a, p.name.name, &body);
                        break :blk try ir.lower.lowerAccessorExpr(module, c.name.name, &own_members, &.{ "this", setter_param_name }, rewritten, nm);
                    },
                    .Block => |blk_body| blk: {
                        const rewritten = try lift.rewriteBlockField(a, &blk_body, p.name.name);
                        break :blk try ir.lower.lowerAccessorBlock(module, c.name.name, &own_members, &.{ "this", setter_param_name }, &rewritten, nm);
                    },
                };
                try instance_prop_setters.put(.{ .a = c.name.name, .b = p.name.name }, fid);
            }
        }
    }

    // Synthesise a runtime ClassDef for every class in the file.
    const globals_for_capture = try ObjRef(Env).init(a, Env.init(a));
    var classes = ClassTable.init(a);
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        const def = try buildClassDef(a, c, fqn_overrides, package_prefix, &object_names, globals_for_capture);
        const fqn_g = def.borrow();
        const def_fqn = fqn_g.get().fqn;
        fqn_g.deinit();
        if (def_fqn.len != 0 and !std.mem.eql(u8, def_fqn, c.name.name)) {
            try classes.put(def_fqn, def.clone());
        }
        try classes.put(c.name.name, def);
    }

    // Populate enum entries + per-entry overrides + ctor-arg thunks.
    var next_id: u64 = 1;
    var enum_entry_arg_inits: std.ArrayList(EnumEntryArgInit) = .empty;
    var enum_entry_methods = std.HashMap(StrPair, EnumEntryMethod, StrPairContext, std.hash_map.default_max_load_percentage).init(a);
    var enum_entry_synth_class = PairStrMap.init(a);
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        if (!c.is_enum) continue;
        const class_def = classes.get(c.name.name) orelse continue;
        var entries: std.ArrayList(ClassDef.EnumEntry) = .empty;
        for (c.enum_entries, 0..) |*entry, ordinal| {
            const id = next_id;
            next_id += 1;
            var fields: std.ArrayList(InstanceData.Field) = .empty;
            try fields.append(a, .{ .name = "name", .value = .{ .String = try ObjRef([]const u8).init(a, entry.name.name) } });
            try fields.append(a, .{ .name = "ordinal", .value = Value.newInt(@intCast(ordinal)) });

            if (entry.body_members.len != 0) {
                const synth_class_name = try std.fmt.allocPrint(a, "{s}${s}", .{ c.name.name, entry.name.name });
                try enum_entry_synth_class.put(.{ .a = c.name.name, .b = entry.name.name }, synth_class_name);
                for (entry.body_members) |*em| {
                    if (em.* != .Function) continue;
                    const f = &em.Function;
                    if (f.body == null) continue;
                    var sub_module = Module.default(a);
                    var own = StringSet.init(a);
                    defer own.deinit();
                    const sub_func = try ir.lower.lowerMethod(&sub_module, f, synth_class_name, &own);
                    const fid = sub_func.id;
                    const module_rc = try ObjRef(Module).init(a, sub_module);
                    try enum_entry_methods.put(.{ .a = synth_class_name, .b = f.name.name }, .{ .module = module_rc, .func = fid });
                }
                try fields.append(a, .{ .name = "__enum_entry_class__", .value = .{ .String = try ObjRef([]const u8).init(a, synth_class_name) } });
            }

            const inst = try ObjRef(InstanceData).init(a, .{
                .class = class_def.clone(),
                .fields = fields,
                .outer = null,
                .identity = id,
                .native_state = null,
            });
            try entries.append(a, .{ .name = entry.name.name, .value = .{ .Instance = inst } });

            if (entry.args.len != 0) {
                var fids = try a.alloc(FuncId, entry.args.len);
                for (entry.args, 0..) |*arg, idx| {
                    const nm = try std.fmt.allocPrint(a, "__enum_arg_{s}_{s}_{d}", .{ c.name.name, entry.name.name, idx });
                    fids[idx] = try ir.lower.lowerExprAsThunk(module, arg, nm);
                }
                try enum_entry_arg_inits.append(a, .{ .class_name = c.name.name, .entry_name = entry.name.name, .funcs = fids });
            }
        }
        const g = class_def.borrowMut();
        g.get().enum_entries = try entries.toOwnedSlice(a);
        g.deinit();
    }

    // Resolve runtime parent + interface references. The class headers are
    // already registered; this is the second linker phase that backpatches
    // each `parent`/`interfaces` slot once. After it returns the fields are
    // immutable for the rest of the process and read lock-free on dispatch.
    {
        var vit = classes.valueIterator();
        while (vit.next()) |def_ptr| {
            const def = def_ptr.*;
            const dg = def.borrow();
            const supertype_names = dg.get().supertype_names;
            dg.deinit();
            var ifaces: std.ArrayList(ObjRef(ClassDef)) = .empty;
            for (supertype_names) |sup_name| {
                const sup_def = classes.get(sup_name) orelse continue;
                if (def.cell == sup_def.cell) continue;
                const sg = sup_def.borrow();
                const sup_is_interface = sg.get().is_interface;
                sg.deinit();
                if (sup_is_interface) {
                    try ifaces.append(a, sup_def.clone());
                } else {
                    const dg2 = def.borrowMut();
                    if (dg2.get().parent == null) dg2.get().parent = sup_def.clone();
                    dg2.deinit();
                }
            }
            if (ifaces.items.len != 0) {
                const dg2 = def.borrowMut();
                dg2.get().interfaces = try ifaces.toOwnedSlice(a);
                dg2.deinit();
            } else {
                ifaces.deinit(a);
            }
        }
    }

    // Parent-ctor argument thunks.
    var parent_ctor_args = std.StringHashMap([]FuncId).init(a);
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        var first_parent_args: ?[]const ast.Expr = null;
        for (c.supertype_args) |sa| {
            if (sa) |args| {
                first_parent_args = args;
                break;
            }
        }
        const parent_args = first_parent_args orelse continue;
        var param_refs: std.ArrayList([]const u8) = .empty;
        defer param_refs.deinit(a);
        for (c.primary_params) |*p| try param_refs.append(a, p.name.name);
        var own = StringSet.init(a);
        defer own.deinit();
        try collectCompanionOwnMembers(c, &own);
        var fids = try a.alloc(FuncId, parent_args.len);
        for (parent_args, 0..) |*e, idx| {
            const nm = try std.fmt.allocPrint(a, "__parent_ctor_arg_{s}_{d}", .{ c.name.name, idx });
            fids[idx] = try ir.lower.lowerExprAsParamThunkScoped(module, param_refs.items, e, nm, c.name.name, &own);
        }
        try parent_ctor_args.put(c.name.name, fids);
    }

    // Init blocks as 1-arg thunks taking `this` plus ctor params.
    var init_blocks = std.StringHashMap([]FuncId).init(a);
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        if (c.init_blocks.len == 0) continue;
        var own_members = StringSet.init(a);
        defer own_members.deinit();
        for (c.primary_params) |*p| {
            if (p.property != null) try own_members.put(p.name.name, {});
        }
        for (c.members) |*m| {
            switch (m.*) {
                .Property => |*p| try own_members.put(p.name.name, {}),
                .Function => |*f| try own_members.put(f.name.name, {}),
                else => {},
            }
        }
        {
            var seen_sup = StringSet.init(a);
            defer seen_sup.deinit();
            for (c.supertypes) |*st| try collectHierarchyMemberNames(st.name.name, &file_classes, &own_members, &seen_sup);
        }
        var local_params: std.ArrayList([]const u8) = .empty;
        defer local_params.deinit(a);
        try local_params.append(a, "this");
        for (c.primary_params) |*p| try local_params.append(a, p.name.name);
        var fids = try a.alloc(FuncId, c.init_blocks.len);
        for (c.init_blocks, 0..) |*blk, idx| {
            const nm = try std.fmt.allocPrint(a, "__init_block_{s}_{d}", .{ c.name.name, idx });
            fids[idx] = try ir.lower.lowerAccessorBlock(module, c.name.name, &own_members, local_params.items, blk, nm);
        }
        try init_blocks.put(c.name.name, fids);
    }

    // Per-class delegation expressions.
    var class_delegates = std.StringHashMap([]StrFunc).init(a);
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        if (c.supertype_delegates.len == 0) continue;
        var param_refs: std.ArrayList([]const u8) = .empty;
        defer param_refs.deinit(a);
        for (c.primary_params) |*p| try param_refs.append(a, p.name.name);
        var entries: std.ArrayList(StrFunc) = .empty;
        for (c.supertype_delegates, 0..) |delegate_opt, sup_idx| {
            if (delegate_opt) |delegate_expr| {
                const sup_name = if (sup_idx < c.supertypes.len) c.supertypes[sup_idx].name.name else "";
                const nm = try std.fmt.allocPrint(a, "__class_delegate_{s}_{d}", .{ c.name.name, sup_idx });
                const fid = try ir.lower.lowerExprAsParamThunk(module, param_refs.items, &delegate_expr, nm);
                try entries.append(a, .{ .name = sup_name, .func = fid });
            }
        }
        if (entries.items.len != 0) {
            try class_delegates.put(c.name.name, try entries.toOwnedSlice(a));
        } else {
            entries.deinit(a);
        }
    }

    // Per-class secondary-ctor lowering.
    var secondary_ctors = std.StringHashMap([]SecondaryCtorEntry).init(a);
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        if (c.secondary_ctors.len == 0) continue;
        var own_members = StringSet.init(a);
        defer own_members.deinit();
        for (c.primary_params) |*p| {
            if (p.property != null) try own_members.put(p.name.name, {});
        }
        for (c.members) |*m| {
            switch (m.*) {
                .Property => |*p| try own_members.put(p.name.name, {}),
                .Function => |*f| try own_members.put(f.name.name, {}),
                .Class => |*inner| if (inner.is_companion) {
                    try own_members.put(inner.name.name, {});
                    for (inner.members) |*cm| {
                        switch (cm.*) {
                            .Function => |*f| try own_members.put(f.name.name, {}),
                            .Property => |*p| try own_members.put(p.name.name, {}),
                            else => {},
                        }
                    }
                    for (inner.primary_params) |*p| {
                        if (p.property != null) try own_members.put(p.name.name, {});
                    }
                },
                else => {},
            }
        }
        var entries = try a.alloc(SecondaryCtorEntry, c.secondary_ctors.len);
        for (c.secondary_ctors, 0..) |*sc, sc_idx| {
            var param_names = try a.alloc([]const u8, sc.params.len);
            for (sc.params, 0..) |*p, i| param_names[i] = p.name.name;

            var delegation_args: []const ast.Expr = &.{};
            var is_super = false;
            var is_this = false;
            switch (sc.delegation) {
                .This => |args| {
                    delegation_args = args;
                    is_this = true;
                },
                .Super => |args| {
                    delegation_args = args;
                    is_super = true;
                },
                .None => {},
            }
            var arg_fids = try a.alloc(FuncId, delegation_args.len);
            for (delegation_args, 0..) |*e, arg_idx| {
                const nm = try std.fmt.allocPrint(a, "__sec_ctor_{s}_{d}_arg{d}", .{ c.name.name, sc_idx, arg_idx });
                arg_fids[arg_idx] = try ir.lower.lowerExprAsParamThunkScoped(module, param_names, e, nm, c.name.name, &own_members);
            }
            var default_arg_thunks = try a.alloc(?FuncId, sc.params.len);
            for (sc.params, 0..) |*p, p_idx| {
                if (p.default) |*e| {
                    const nm = try std.fmt.allocPrint(a, "__sec_ctor_{s}_{d}_def{d}", .{ c.name.name, sc_idx, p_idx });
                    default_arg_thunks[p_idx] = try ir.lower.lowerExprAsParamThunkScoped(module, param_names, e, nm, c.name.name, &own_members);
                } else {
                    default_arg_thunks[p_idx] = null;
                }
            }
            var body_fid: ?FuncId = null;
            if (sc.body) |*blk| {
                var locals: std.ArrayList([]const u8) = .empty;
                defer locals.deinit(a);
                try locals.append(a, "this");
                for (param_names) |pn| try locals.append(a, pn);
                const nm = try std.fmt.allocPrint(a, "__sec_ctor_body_{s}_{d}", .{ c.name.name, sc_idx });
                body_fid = try ir.lower.lowerAccessorBlock(module, c.name.name, &own_members, locals.items, blk, nm);
            }
            entries[sc_idx] = .{
                .param_count = sc.params.len,
                .param_names = param_names,
                .is_super = is_super,
                .is_this = is_this,
                .delegation_arg_thunks = arg_fids,
                .default_arg_thunks = default_arg_thunks,
                .body = body_fid,
            };
        }
        try secondary_ctors.put(c.name.name, entries);
    }

    // Top-level property initialisers — const first, then the rest.
    var top_level_props: std.ArrayList(NameFunc) = .empty;
    var top_level_delegated_props = std.StringHashMap(void).init(a);
    for (decls) |*d| {
        if (d.* != .Property) continue;
        const p = &d.Property;
        if (p.receiver_type != null or !p.is_const) continue;
        if (p.init) |*init| {
            const nm = try std.fmt.allocPrint(a, "__top_prop_init_{s}", .{p.name.name});
            const fid = try ir.lower.lowerExprAsThunk(module, init, nm);
            try top_level_props.append(a, .{ .name = p.name.name, .func = fid });
        }
    }
    for (decls) |*d| {
        if (d.* != .Property) continue;
        const p = &d.Property;
        if (p.receiver_type != null or p.is_const) continue;
        if (p.init) |*init| {
            const nm = try std.fmt.allocPrint(a, "__top_prop_init_{s}", .{p.name.name});
            const fid = try ir.lower.lowerExprAsThunk(module, init, nm);
            try top_level_props.append(a, .{ .name = p.name.name, .func = fid });
        } else if (p.delegate) |*delegate| {
            try top_level_delegated_props.put(p.name.name, {});
            const nm = try std.fmt.allocPrint(a, "__top_prop_delegate_{s}", .{p.name.name});
            const fid = try ir.lower.lowerExprAsThunk(module, delegate, nm);
            try top_level_props.append(a, .{ .name = p.name.name, .func = fid });
        }
    }

    // Top-level + companion/object extension properties.
    var extension_props = PairFuncMap.init(a);
    var extension_prop_setters = PairFuncMap.init(a);
    var ext_prop_decls: std.ArrayList(*const ast.Property) = .empty;
    defer ext_prop_decls.deinit(a);
    for (decls) |*d| {
        switch (d.*) {
            .Property => |*p| if (p.receiver_type != null) try ext_prop_decls.append(a, p),
            .Class => |*c| {
                for (c.members) |*m| {
                    if (m.* == .Property and m.Property.receiver_type != null) try ext_prop_decls.append(a, &m.Property);
                }
            },
            .Object => |*o| {
                for (o.members) |*m| {
                    if (m.* == .Property and m.Property.receiver_type != null) try ext_prop_decls.append(a, &m.Property);
                }
            },
            else => {},
        }
    }
    for (ext_prop_decls.items) |p| {
        const recv = p.receiver_type orelse continue;
        if (p.getter) |*getter| {
            var empty_members = StringSet.init(a);
            defer empty_members.deinit();
            const nm = try std.fmt.allocPrint(a, "__ext_get_{s}_{s}", .{ recv.name.name, p.name.name });
            const fid = switch (getter.body) {
                .Expr => |body| try ir.lower.lowerAccessorExpr(module, recv.name.name, &empty_members, &.{"this"}, &body, nm),
                .Block => |blk| try ir.lower.lowerAccessorBlock(module, recv.name.name, &empty_members, &.{"this"}, &blk, nm),
            };
            try extension_props.put(.{ .a = recv.name.name, .b = p.name.name }, fid);
        }
        if (p.setter) |*setter| {
            const setter_param_name = if (setter.params.len != 0) setter.params[0].name else "value";
            var recv_members = StringSet.init(a);
            defer recv_members.deinit();
            if (classes.get(recv.name.name)) |rdef| {
                const rg = rdef.borrow();
                for (rg.get().primary_params) |*pp| try recv_members.put(pp.name, {});
                for (rg.get().body_properties) |*pp| try recv_members.put(pp.name, {});
                rg.deinit();
            }
            const nm = try std.fmt.allocPrint(a, "__ext_set_{s}_{s}", .{ recv.name.name, p.name.name });
            const fid = switch (setter.body) {
                .Expr => |body| try ir.lower.lowerAccessorExpr(module, recv.name.name, &recv_members, &.{ "this", setter_param_name }, &body, nm),
                .Block => |blk| try ir.lower.lowerAccessorBlock(module, recv.name.name, &recv_members, &.{ "this", setter_param_name }, &blk, nm),
            };
            try extension_prop_setters.put(.{ .a = recv.name.name, .b = p.name.name }, fid);
        }
    }

    // Fold local-fn default thunks into func_defaults.
    {
        var it = module.registry.local_fn_defaults.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*.int();
            if (!func_defaults.contains(key)) {
                try func_defaults.put(key, try a.dupe(?FuncId, e.value_ptr.items));
            }
        }
    }

    // Inherited default arguments: propagate supertype member default
    // thunks onto overriding members lacking their own thunk.
    try propagateInheritedDefaults(a, module, &func_defaults);

    // typealias Name = Target → Name ↦ Target's simple head name.
    for (decls) |*d| {
        if (d.* != .TypeAlias) continue;
        const ta = &d.TypeAlias;
        const full = ta.target.name.name;
        const target = if (std.mem.lastIndexOfScalar(u8, full, '.')) |dot| full[dot + 1 ..] else full;
        if (target.len != 0 and !std.mem.eql(u8, target, ta.name.name)) {
            try module.registry.type_aliases.put(ta.name.name, target);
        }
    }

    // Materialise the module-scoped registry the Vm reads at dispatch time.
    // Object names, companion singletons, enclosing-class, func type params,
    // delegated props (the lowering-only registry fields stay in place).
    for (object_names.items) |n| try module.registry.object_names.append(a, n);
    {
        var it = companion_singletons.iterator();
        while (it.next()) |e| try module.registry.companion_singletons.put(e.key_ptr.*, e.value_ptr.*);
    }
    {
        var it = enclosing_class.iterator();
        while (it.next()) |e| try module.registry.enclosing_class.put(e.key_ptr.*, e.value_ptr.*);
    }
    {
        var it = func_type_params.iterator();
        while (it.next()) |e| {
            var list: std.ArrayList([]const u8) = .empty;
            try list.appendSlice(a, e.value_ptr.*);
            try module.registry.func_type_params.put(FuncId.from(e.key_ptr.*), list);
        }
    }
    {
        var it = top_level_delegated_props.keyIterator();
        while (it.next()) |k| try module.registry.top_level_delegated_props.put(k.*, {});
    }
    {
        var it = delegated_body_props.keyIterator();
        while (it.next()) |k| try module.registry.delegated_body_props.put(.{ .a = k.a, .b = k.b }, {});
    }

    // Rebuild the name index so funcId lookups see every registered stub.
    try module.rebuildFuncNameIndex(a);

    return .{
        .module = module_ref,
        .classes = classes,
        .body_prop_inits = body_prop_inits,
        .instance_prop_getters = instance_prop_getters,
        .instance_prop_setters = instance_prop_setters,
        .parent_ctor_args = parent_ctor_args,
        .init_blocks = init_blocks,
        .top_level_props = top_level_props,
        .extension_props = extension_props,
        .extension_prop_setters = extension_prop_setters,
        .main = main_id,
        .object_names = object_names,
        .companion_singletons = companion_singletons,
        .enum_entry_arg_inits = enum_entry_arg_inits,
        .secondary_ctors = secondary_ctors,
        .primary_ctor_default_thunks = primary_ctor_default_thunks,
        .class_delegates = class_delegates,
        .func_defaults = func_defaults,
        .enclosing_class = enclosing_class,
        .enum_entry_methods = enum_entry_methods,
        .enum_entry_synth_class = enum_entry_synth_class,
        .func_type_params = func_type_params,
        .top_level_delegated_props = top_level_delegated_props,
        .delegated_body_props = delegated_body_props,
        .allocator = allocator,
    };
}

// -------------------------------------------------------------------------
// buildModuleWithOverrides sub-helpers.
// -------------------------------------------------------------------------

fn replaceDotWithDollar(allocator: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, out) |ch, *dst| dst.* = if (ch == '.') '$' else ch;
    return out;
}

/// Resolve a supertype reference to its mangled top-level name when the
/// nested type it names was mangled on a top-level collision. Matches the
/// `qualified_path`'s last two segments against `mangled_nested`.
fn resolveMangled(allocator: Allocator, mangled_nested: *const lift.MangledMap, t: *const ast.TypeRef) ?[]const u8 {
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

fn collectConsts(module: *Module, cls_name: []const u8, members: []const Decl) Allocator.Error!void {
    for (members) |*m| {
        switch (m.*) {
            .Property => |*p| if (p.is_const) {
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

fn collectInline(allocator: Allocator, d: *const Decl, out: *std.StringHashMap(std.ArrayList(*const ast.Function))) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| if (f.is_inline and f.body != null) {
            const gop = try out.getOrPut(f.name.name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, f);
        },
        .Class => |*c| for (c.members) |*m| try collectInline(allocator, m, out),
        .Object => |*o| for (o.members) |*m| try collectInline(allocator, m, out),
        else => {},
    }
}

fn collectCompanionOwnMembers(c: *const ast.Class, own: *StringSet) Allocator.Error!void {
    for (c.members) |*m| {
        if (m.* == .Class and m.Class.is_companion) {
            const inner = &m.Class;
            try own.put(inner.name.name, {});
            for (inner.members) |*cm| {
                switch (cm.*) {
                    .Function => |*f| try own.put(f.name.name, {}),
                    .Property => |*p| try own.put(p.name.name, {}),
                    else => {},
                }
            }
            for (inner.primary_params) |*p| {
                if (p.property != null) try own.put(p.name.name, {});
            }
        }
    }
}

fn buildClassDef(
    a: Allocator,
    c: *const ast.Class,
    fqn_overrides: *const SpanStrMap,
    package_prefix: []const u8,
    object_names: *const std.ArrayList([]const u8),
    globals_for_capture: ObjRef(Env),
) Allocator.Error!ObjRef(ClassDef) {
    var primary_params = try a.alloc(ClassParamDef, c.primary_params.len);
    for (c.primary_params, 0..) |*p, i| {
        primary_params[i] = .{
            .property = p.property,
            .name = p.name.name,
            .default = if (p.default) |*e| e else null,
            .declared_type = p.ty.name.name,
            .declared_shape = try TypeShape.fromTypeRef(a, &p.ty),
        };
    }
    var body_props: std.ArrayList(PropertyDef) = .empty;
    for (c.members) |*m| {
        if (m.* != .Property) continue;
        const p = &m.Property;
        try body_props.append(a, .{
            .name = p.name.name,
            .mutable = p.mutable,
            .init = if (p.init) |*e| e else null,
            .getter = if (p.getter) |*g| g else null,
            .setter = if (p.setter) |*s| s else null,
            .delegate = if (p.delegate) |*e| e else null,
            .is_abstract = p.is_abstract,
            .is_lateinit = p.is_lateinit,
            .primitive_zero = primitiveZeroFor(p),
        });
    }

    var is_object = false;
    for (object_names.items) |n| {
        if (std.mem.eql(u8, n, c.name.name)) {
            is_object = true;
            break;
        }
    }

    // init-block property positions: count `Property` decls in members[0..pos].
    var init_block_positions = try a.alloc(usize, c.init_block_positions.len);
    for (c.init_block_positions, 0..) |pos, i| {
        const upto = @min(pos, c.members.len);
        var count: usize = 0;
        for (c.members[0..upto]) |*m| {
            if (m.* == .Property) count += 1;
        }
        init_block_positions[i] = count;
    }

    var init_blocks_ast = try a.alloc(*const ast.Block, c.init_blocks.len);
    for (c.init_blocks, 0..) |*blk, i| init_blocks_ast[i] = blk;

    var secondary = try a.alloc(*const ast.SecondaryCtor, c.secondary_ctors.len);
    for (c.secondary_ctors, 0..) |*sc, i| secondary[i] = sc;

    var supertype_names = try a.alloc([]const u8, c.supertypes.len);
    for (c.supertypes, 0..) |*t, i| supertype_names[i] = t.name.name;

    const fqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);

    return ObjRef(ClassDef).init(a, .{
        .name = c.name.name,
        .fqn = fqn,
        .annotation_names = &.{},
        .primary_params = primary_params,
        .methods = &.{},
        .body_properties = try body_props.toOwnedSlice(a),
        .init_blocks = init_blocks_ast,
        .init_block_property_positions = init_block_positions,
        .is_data = c.is_data,
        .is_value = c.is_value,
        .is_object = is_object,
        .is_enum = c.is_enum,
        .is_sealed = c.is_sealed,
        .supertype_names = supertype_names,
        .parent = null,
        .interfaces = &.{},
        .is_interface = c.is_interface,
        .is_fun_interface = c.is_fun_interface,
        .parent_ctor_args = &.{},
        .is_open = c.is_open,
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

/// Propagate each supertype member's default-thunk slots onto an overriding
/// member that lacks its own thunk for that parameter.
fn propagateInheritedDefaults(a: Allocator, module: *Module, func_defaults: *std.AutoHashMap(u32, []?FuncId)) Allocator.Error!void {
    // by_id: ClassId.int() -> index in module.classes.
    var by_id = std.AutoHashMap(u32, usize).init(a);
    defer by_id.deinit();
    for (module.classes.items, 0..) |*c, i| try by_id.put(c.id.int(), i);

    const Inherited = struct { fid: FuncId, slots: []?FuncId };
    var inherited: std.ArrayList(Inherited) = .empty;
    defer inherited.deinit(a);

    for (module.classes.items) |*c| {
        // Transitive supertype closure.
        var anc: std.ArrayList(usize) = .empty;
        defer anc.deinit(a);
        var queue: std.ArrayList(ClassId) = .empty;
        defer queue.deinit(a);
        try queue.appendSlice(a, c.supertypes);
        var seen = std.AutoHashMap(u32, void).init(a);
        defer seen.deinit();
        while (queue.pop()) |sid| {
            if ((try seen.getOrPut(sid.int())).found_existing) continue;
            if (by_id.get(sid.int())) |idx| {
                try anc.append(a, idx);
                try queue.appendSlice(a, module.classes.items[idx].supertypes);
            }
        }

        for (c.methods) |m| {
            if (m.int() >= module.funcs.items.len) continue;
            const mf = &module.funcs.items[m.int()];
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
                    if (am.int() >= module.funcs.items.len) continue;
                    const af = &module.funcs.items[am.int()];
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

            // Abstract/interface declarations: consult the abstract-defaults
            // table keyed by (class name / simple name, method name).
            const self_idx = by_id.get(c.id.int());
            var consult: std.ArrayList(usize) = .empty;
            defer consult.deinit(a);
            try consult.appendSlice(a, anc.items);
            if (self_idx) |si| try consult.append(a, si);
            for (consult.items) |ai| {
                const cn = module.classes.items[ai].name;
                const cn_simple = if (std.mem.lastIndexOfScalar(u8, cn, '.')) |dot| cn[dot + 1 ..] else cn;
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

fn slotsEql(x: []const ?FuncId, y: []const ?FuncId) bool {
    if (x.len != y.len) return false;
    for (x, y) |xa, ya| {
        if (xa == null and ya == null) continue;
        if (xa == null or ya == null) return false;
        if (xa.?.int() != ya.?.int()) return false;
    }
    return true;
}

/// Decide whether a declaration survives the `expect`/stub-drop retain
/// pass. Mirrors the Rust `all_decls.retain(...)` closure.
fn retainDecl(
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
            if (!f.is_expect and f.params.len == 0 and
                (std.mem.eql(u8, f.name.name, "emptyList") or std.mem.eql(u8, f.name.name, "emptySet") or std.mem.eql(u8, f.name.name, "emptyMap"))) return false;
            if (!f.is_expect and isSequenceFactoryName(f.name.name)) {
                const expected = try std.fmt.allocPrint(a, "kotlin.sequences.{s}", .{f.name.name});
                const fqn = func_fqn_overrides.get(f.span);
                if (fqn != null and std.mem.eql(u8, fqn.?, expected)) return false;
            }
            if (!f.is_expect and isCollectionFactoryName(f.name.name)) {
                const expected = try std.fmt.allocPrint(a, "kotlin.collections.{s}", .{f.name.name});
                const fqn = try resolveFqn(a, func_fqn_overrides, f.span, package_prefix, f.name.name);
                if (std.mem.eql(u8, fqn, expected) and stdlib.implementation(expected) != null) return false;
            }
            if (!f.is_expect) return true;
            if (actual_func_names.contains(f.name.name)) return false;
            const fqn = try resolveFqn(a, func_fqn_overrides, f.span, package_prefix, f.name.name);
            if (stdlib.implementation(fqn) != null) return false;
            if (f.receiver_type == null) {
                const kotlin_fqn = try std.fmt.allocPrint(a, "kotlin.{s}", .{f.name.name});
                if (stdlib.implementation(kotlin_fqn) != null) return false;
            }
            if (std.mem.startsWith(u8, fqn, "kotlin.coroutines.")) return false;
            return true;
        },
        .Class => |*c| return !(c.is_expect and actual_class_names_set.contains(c.name.name)),
        .Object => |*o| return !(o.is_expect and actual_object_names_set.contains(o.name.name)),
        .Property => |*p| {
            if (std.mem.eql(u8, p.name.name, "coroutineContext") or std.mem.eql(u8, p.name.name, "isInitialized")) return false;
            return !(p.is_expect and actual_prop_names.contains(p.name.name));
        },
        else => return true,
    }
}

fn isSequenceFactoryName(n: []const u8) bool {
    return std.mem.eql(u8, n, "generateSequence") or std.mem.eql(u8, n, "sequenceOf") or
        std.mem.eql(u8, n, "emptySequence") or std.mem.eql(u8, n, "sequence") or std.mem.eql(u8, n, "iterator");
}

fn isCollectionFactoryName(n: []const u8) bool {
    const names = [_][]const u8{
        "linkedMapOf",    "hashMapOf",   "linkedStringMapOf", "hashSetOf",
        "linkedSetOf",    "sortedSetOf", "sortedMapOf",       "arrayListOf",
        "listOfNotNull",  "setOfNotNull",
    };
    for (names) |k| {
        if (std.mem.eql(u8, n, k)) return true;
    }
    return false;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    _ = lift;
}

test "build_module produces an owned empty module shell" {
    // The driver allocates many transient lowering tables (lift accumulators,
    // the module registry, the process-global inline-state installs) from the
    // build allocator; an arena frees them all at once, matching the CLI's
    // per-run gpa whose memory is reclaimed on process exit.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file: KotlinFile = .{
        .package = null,
        .imports = &.{},
        .decls = &.{},
        .span = span.Span.init(span.FileId.from(0), 0, 0),
    };
    var built = try buildModule(a, &file);
    defer built.deinit();
    try testing.expect(built.main == null);
    try testing.expectEqual(@as(usize, 0), built.top_level_props.items.len);
}
