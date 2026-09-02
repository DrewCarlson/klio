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
const FF = runtime.forest.ForestField;
const ast = @import("ast");
const compose_pass = @import("compose_pass");
const serialization_pass = @import("serialization_pass");
const span = @import("span");
const stdlib = @import("stdlib");

pub const lift = @import("build/lift.zig");
const prune = @import("prune.zig");
const image = @import("image.zig");

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

fn boundTypeRecordComplete(bound: *const ast.TypeRef) bool {
    return !bound.nullable and bound.type_args.len == 0 and
        bound.function == null and !bound.definitely_non_null and
        bound.qualified_path == null;
}

fn collectClassTypeParamBounds(
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

/// JVM static-field default category for a top-level property's declared
/// type. While the startup pass runs initializers in file order, a forward
/// read of a not-yet-initialized annotated property observes this default
/// (the field's pre-<clinit> value on the JVM) instead of driving the
/// initializer out of order. `.none` marks a property with no usable
/// declared type (unannotated, `const`, or delegated); those keep the
/// drive-on-demand path.
pub const TypedDefault = enum(u8) {
    none,
    int,
    long,
    short,
    byte,
    uint,
    ulong,
    ushort,
    ubyte,
    boolean,
    char,
    float,
    double,
    null_ref,
};

/// Map a declared property type annotation to its static-field default
/// category. Nullable, function, and non-primitive heads are references
/// (default null); a qualified head only counts as a builtin primitive
/// when the qualifier is exactly `kotlin`.
/// Simple type-name head for ctor-overload disambiguation: drop any package
/// qualifier, generic arguments, and trailing nullability.
fn simpleTypeHead(name: []const u8) []const u8 {
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

/// `(name, FuncId)` top-level property initializer entry, plus the
/// declared type's pre-init default category.
pub const NameFunc = struct { name: []const u8, func: FuncId, default: TypedDefault = .none, file: u32 = 0 };

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
    /// Simple type-name head of each parameter (`IntArray`, `Int`), used to
    /// disambiguate same-arity constructor overloads by argument type.
    param_type_heads: [][]const u8,
    is_super: bool,
    /// `true` for an explicit `: this(...)` delegation.
    is_this: bool,
    delegation_arg_thunks: []FuncId,
    /// Per-parameter default-value thunks (`null` when no default).
    default_arg_thunks: []?FuncId,
    /// Optional body block lowered as a 1-arg fn taking `this`.
    body: ?FuncId,
    /// `@Deprecated(level = ERROR|HIDDEN)` / `@LowPriorityInOverloadResolution`.
    /// kotlinc does not offer such a constructor to source at all — HIDDEN exists
    /// only for binary compatibility — so it must never win over an ordinary one.
    low_priority: bool = false,
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
    getter_prop_names: std.StringHashMap(void),
    /// Custom-setter `FuncIds`, keyed the same as getters.
    instance_prop_setters: PairFuncMap,
    /// Getter-backed body properties declared `private`, keyed the same as
    /// getters. A private property never participates in override dispatch,
    /// so the scope-qualified property walk skips these on any class other
    /// than the lexical owner.
    instance_prop_private: PairFuncMap,
    /// Parent-ctor argument thunks per class.
    parent_ctor_args: std.StringHashMap([]FuncId),
    /// Argument labels parallel to `parent_ctor_args`, when the super-ctor
    /// call named any argument (`: Base(objects = 2)`); absent when all
    /// arguments are positional. Used to bind a named super-ctor argument
    /// to the base parameter of that name.
    parent_ctor_arg_names: std.StringHashMap([]const ?[]const u8),
    /// `init { ... }` blocks per class. Each `FuncId` takes `this`.
    init_blocks: std.StringHashMap([]FuncId),
    /// Top-level property initialisers, in declaration order.
    top_level_props: std.ArrayList(NameFunc),
    /// Top-level extension properties, keyed by `(receiver type, prop)`.
    extension_props: PairFuncMap,
    /// Names having at least one owner-qualified key; see the Prog field.
    owner_keyed_ext_names: std.StringHashMap(void),
    /// Getter FuncIds of extension properties declared on a NULLABLE receiver
    /// (`val RowColumnParentData?.weight`), keyed by property name — the only
    /// dispatch key available when the receiver evaluates to null. A name
    /// declared on several nullable receivers is ambiguous and maps to null.
    nullable_ext_props: std.StringHashMap(?FuncId),
    /// Extension-property setters keyed by `(receiver type, prop)`.
    extension_prop_setters: PairFuncMap,
    /// Delegated extension properties (`val R.x by expr`), keyed by
    /// `(receiver type, prop)` — the `FuncId` is the 0-arg thunk producing
    /// the delegate object; reads/writes route through its
    /// `getValue`/`setValue` with the delegate cached per property.
    extension_prop_delegates: PairFuncMap,
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
        self.getter_prop_names.deinit();
        self.instance_prop_setters.deinit();
        self.instance_prop_private.deinit();
        self.parent_ctor_args.deinit();
        self.parent_ctor_arg_names.deinit();
        self.init_blocks.deinit();
        self.top_level_props.deinit(self.allocator);
        self.extension_props.deinit();
        self.owner_keyed_ext_names.deinit();
        self.nullable_ext_props.deinit();
        self.extension_prop_setters.deinit();
        self.extension_prop_delegates.deinit();
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

/// Build an empty `BuiltModule` shell around `module`. Public for the
/// image loader, which fills the shell table-by-table from decoded data.
pub fn emptyBuiltShell(allocator: Allocator, module: ObjRef(Module), main: ?FuncId) BuiltModule {
    return emptyBuilt(allocator, module, main);
}

fn emptyBuilt(allocator: Allocator, module: ObjRef(Module), main: ?FuncId) BuiltModule {
    return .{
        .module = module,
        .classes = ClassTable.init(allocator),
        .body_prop_inits = PairFuncMap.init(allocator),
        .instance_prop_getters = PairFuncMap.init(allocator),
        .getter_prop_names = std.StringHashMap(void).init(allocator),
        .instance_prop_setters = PairFuncMap.init(allocator),
        .instance_prop_private = PairFuncMap.init(allocator),
        .parent_ctor_args = std.StringHashMap([]FuncId).init(allocator),
        .parent_ctor_arg_names = std.StringHashMap([]const ?[]const u8).init(allocator),
        .init_blocks = std.StringHashMap([]FuncId).init(allocator),
        .top_level_props = .empty,
        .extension_props = PairFuncMap.init(allocator),
        .owner_keyed_ext_names = std.StringHashMap(void).init(allocator),
        .nullable_ext_props = std.StringHashMap(?FuncId).init(allocator),
        .extension_prop_setters = PairFuncMap.init(allocator),
        .extension_prop_delegates = PairFuncMap.init(allocator),
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
const FileClasses = std.StringHashMap(FF(ast.Class));

/// Lower a single file's declarations into an IR module.
pub fn buildModule(allocator: Allocator, file: *const KotlinFile) Allocator.Error!BuiltModule {
    var fqn = SpanStrMap.init(allocator);
    defer fqn.deinit();
    var func_fqn = SpanStrMap.init(allocator);
    defer func_fqn.deinit();
    var decl_pkg = SpanStrMap.init(allocator);
    defer decl_pkg.deinit();
    return buildModuleWithOverrides(
        allocator,
        file,
        &fqn,
        &func_fqn,
        &decl_pkg,
        null,
        null,
        null,
        null,
    );
}

/// Drive `buildModule` against multiple parsed files. All declarations
/// from every file are concatenated into one synthesised file and
/// lowered as a single program.
pub fn buildModuleFiles(allocator: Allocator, files: []const KotlinFile) Allocator.Error!BuiltModule {
    return buildModuleFilesInner(allocator, files, null, null);
}

/// Extend an immutable dependency base with `user_files` only: the base's
/// lowered module/tables are cloned onto `allocator` and just the user
/// declarations are lifted and lowered on top. Callers must have verified
/// `canExtendBase` first.
pub fn buildModuleFilesExtend(allocator: Allocator, base: *const StdlibBase, user_files: []const KotlinFile) Allocator.Error!BuiltModule {
    return buildModuleFilesInner(allocator, user_files, base, null);
}

fn buildModuleFilesInner(allocator: Allocator, files_in: []const KotlinFile, base: ?*const StdlibBase, out_lifted: ?*[]Decl) Allocator.Error!BuiltModule {
    const ComposeMaps = struct {
        names: std.StringHashMap(void),
        sinks: std.StringHashMap(void),
        comp_getter_props: std.StringHashMap(void),
        inline_fns: std.StringHashMap(void),
        stability: std.StringHashMap(compose_pass.Stability),

        fn deinit(self: *@This()) void {
            self.names.deinit();
            self.sinks.deinit();
            self.comp_getter_props.deinit();
            self.inline_fns.deinit();
            self.stability.deinit();
        }
    };
    var compose_maps: ?ComposeMaps = null;
    defer {
        compose_pass.active_composable_names = null;
        compose_pass.active_composable_sinks = null;
        compose_pass.active_composable_getter_props = null;
        compose_pass.active_inline_fns = null;
        compose_pass.active_stability = null;
        if (compose_maps) |*maps| maps.deinit();
    }
    var decls: std.ArrayList(Decl) = .empty;
    defer decls.deinit(allocator);
    var imports: std.ArrayList(ast.ImportDecl) = .empty;
    defer imports.deinit(allocator);

    var fqn_overrides = SpanStrMap.init(allocator);
    defer fqn_overrides.deinit();
    var func_fqn_overrides = SpanStrMap.init(allocator);
    defer func_fqn_overrides.deinit();
    var decl_pkg = SpanStrMap.init(allocator);
    defer decl_pkg.deinit();

    var file_pkgs = std.AutoHashMap(ir.FileId, []const u8).init(allocator);
    defer file_pkgs.deinit();
    var file_modules = std.AutoHashMap(ir.FileId, u32).init(allocator);
    defer file_modules.deinit();
    const compilation_module: u32 = if (base) |bs| blk: {
        const module_guard = bs.built.module.borrow();
        defer module_guard.deinit();
        var next: u32 = 0;
        var module_it = module_guard.get().registry.file_modules.valueIterator();
        while (module_it.next()) |module_id| {
            next = @max(next, module_id.* +| 1);
        }
        break :blk next;
    } else 0;
    // `@Serializable` lowering plugin: synthesize each serializable class's
    // generated serializer declarations (the companion `serializer()`, the
    // `$serializer` object, sealed/enum/object/value-class forms) as ordinary
    // Kotlin before anything reads the decls, so packs and programs alike
    // carry real generated serializers.
    const files: []KotlinFile = try serialization_pass.transformFiles(allocator, files_in);
    for (files) |*f| {
        try file_modules.put(f.span.file, compilation_module);
        const prefix = try packagePrefix(allocator, f.package);
        if (prefix.len != 0) {
            try file_pkgs.put(f.span.file, prefix);
        }
        for (f.decls) |*d| {
            try collectClassifierFqns(allocator, d, prefix, &fqn_overrides);
            try collectDeclPkgs(allocator, d, prefix, &decl_pkg);
            if (d.* == .Function and prefix.len != 0) {
                try func_fqn_overrides.put(d.Function.span, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, d.Function.name.name }));
            }
            if (d.* == .Property and prefix.len != 0) {
                try func_fqn_overrides.put(d.Property.span, try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, d.Property.name.name }));
            }
        }
        try decls.appendSlice(allocator, f.decls);
        try imports.appendSlice(allocator, f.imports);
    }

    // `@Composable` lowering plugin: rewrite composable functions to thread the
    // composer per the Compose plugin ABI, so upstream's real Composer/SlotTable
    // runs. This is the only compose path. The oracle spans this module's decls
    // plus the baked base (pack composables the user calls, e.g. `Text`).
    {
        var names = try compose_pass.collectComposableNames(allocator, decls.items);
        defer names.deinit();
        var sinks = try compose_pass.collectComposableLambdaSinks(allocator, decls.items);
        defer sinks.deinit();
        var comp_getter_props = try compose_pass.collectComposableGetterProps(allocator, decls.items);
        defer comp_getter_props.deinit();
        var inline_fns = try compose_pass.collectInlineFnNames(allocator, decls.items);
        defer inline_fns.deinit();
        if (base) |bsp| {
            // Decode once: an image-loaded base leaves `lifted_decls` empty, so
            // every collector below must read the decoded section instead.
            const base_decls = try composeBaseDecls(allocator, bsp);
            try composeBaseNames(&names, base_decls);
            try composeBaseSinks(&sinks, base_decls);
            try composeBaseComposableGetterProps(&comp_getter_props, base_decls);
            try composeBaseInlineFns(&inline_fns, base_decls);
        }
        if (runtime.envOnce("KLIO_COMPOSE_DBG") != null) {
            compose_pass.dbg_groups = true;
            std.debug.print("[compose-pass] enabled, {d} composable names, {d} lambda sinks, {d} decls\n", .{ names.count(), sinks.count(), decls.items.len });
            if (std.mem.eql(u8, runtime.envOnce("KLIO_COMPOSE_DBG").?, "sinks")) {
                var sit = sinks.keyIterator();
                while (sit.next()) |k| std.debug.print("[compose-sink] {s}\n", .{k.*});
            }
        }
        compose_pass.active_composable_getter_props = &comp_getter_props;
        defer compose_pass.active_composable_getter_props = null;
        compose_pass.active_inline_fns = &inline_fns;
        defer compose_pass.active_inline_fns = null;
        var stability = try compose_pass.collectClassStability(
            allocator,
            decls.items,
            if (base) |bsp| bsp.lifted_decls else &.{},
        );
        defer stability.deinit();
        compose_pass.active_stability = &stability;
        defer compose_pass.active_stability = null;
        var comp_params = try compose_pass.collectComposableParamNames(allocator, decls.items);
        defer comp_params.deinit();
        compose_pass.active_composable_params = &comp_params;
        defer compose_pass.active_composable_params = null;
        compose_pass.memo_trace_enabled = runtime.envOnce("KLIO_MEMO_TRACE") != null;
        var memo_lifts: std.ArrayList(ast.Decl) = .empty;
        defer memo_lifts.deinit(allocator);
        compose_pass.pending_memo_lifts = &memo_lifts;
        compose_pass.pending_lift_alloc = allocator;
        defer {
            compose_pass.pending_memo_lifts = null;
            compose_pass.pending_lift_alloc = null;
        }
        try compose_pass.transformDecls(allocator, decls.items, &names, &sinks);
        try decls.appendSlice(allocator, memo_lifts.items);
        compose_maps = .{
            .names = names,
            .sinks = sinks,
            .comp_getter_props = comp_getter_props,
            .inline_fns = inline_fns,
            .stability = stability,
        };
        names = std.StringHashMap(void).init(allocator);
        sinks = std.StringHashMap(void).init(allocator);
        comp_getter_props = std.StringHashMap(void).init(allocator);
        inline_fns = std.StringHashMap(void).init(allocator);
        stability = std.StringHashMap(compose_pass.Stability).init(allocator);
    }
    if (compose_maps) |*maps| {
        compose_pass.active_composable_names = &maps.names;
        compose_pass.active_composable_sinks = &maps.sinks;
        compose_pass.active_composable_getter_props = &maps.comp_getter_props;
        compose_pass.active_inline_fns = &maps.inline_fns;
        compose_pass.active_stability = &maps.stability;
    }

    // Kotlin gives same-named top-level properties distinct storage per
    // declaration — a `private` one is scoped to its declaring file, and
    // non-private ones in different packages are distinct declarations —
    // but the lowered globals table is flat. Rename colliding declarations
    // (per-file mangle for `private`, the declaring FQN for cross-package
    // non-private slots) and install the per-file rename table the
    // bare-name lowering consults through the reference's span file (an
    // inline-spliced body keeps its declaring file's spans, so a splice
    // still reads the right file's property). A bare reference resolves
    // Kotlin's scope order: own-file private > own package > named import
    // > wildcard import.
    var private_prop_renames = ir.build.FilePrivateRenames.init(allocator);
    defer {
        var it = private_prop_renames.valueIterator();
        while (it.next()) |inner| inner.deinit();
        private_prop_renames.deinit();
    }
    var private_func_renames = ir.build.FilePrivateRenames.init(allocator);
    defer {
        var it = private_func_renames.valueIterator();
        while (it.next()) |inner| inner.deinit();
        private_func_renames.deinit();
    }
    {
        var name_files = std.StringHashMap(u32).init(allocator);
        defer name_files.deinit();
        var name_counts = std.StringHashMap(u32).init(allocator);
        defer name_counts.deinit();
        for (decls.items) |*d| {
            if (d.* != .Property) continue;
            const p = d.Property;
            if (p.receiver_type != null) continue;
            const fid = p.span.file.int();
            const gop = try name_counts.getOrPut(p.name.name);
            if (!gop.found_existing) {
                gop.value_ptr.* = 1;
                try name_files.put(p.name.name, fid);
            } else if (name_files.get(p.name.name).? != fid) {
                gop.value_ptr.* += 1;
            }
        }
        // Private decls: per-file mangled slots; bare reads in the
        // declaring file rewrite to them.
        for (decls.items) |*d| {
            if (d.* != .Property) continue;
            const p = d.Property;
            if (p.receiver_type != null) continue;
            if (p.visibility != .Private or p.is_expect or p.is_actual) continue;
            const count = name_counts.get(p.name.name) orelse 0;
            if (count < 2) continue;
            const fid = p.span.file.int();
            const mangled = try std.fmt.allocPrint(allocator, "{s}$f{d}", .{ p.name.name, fid });
            const gop = try private_prop_renames.getOrPut(fid);
            if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap([]const u8).init(allocator);
            try gop.value_ptr.put(p.name.name, mangled);
            p.name = .{ .name = mangled, .span = p.name.span };
        }
        // File-private top-level FUNCTIONS: same story as private properties.
        // Two files each declaring `private fun debugLog(...)` are file-scoped
        // in Kotlin, but klio's function namespace is flat, so identical
        // signatures read as conflicting overloads. Mangle each per file and
        // record the rename so the declaring file's bare calls rewrite to it.
        {
            var fn_files = std.StringHashMap(u32).init(allocator);
            defer fn_files.deinit();
            var fn_counts = std.StringHashMap(u32).init(allocator);
            defer fn_counts.deinit();
            for (decls.items) |*d| {
                if (d.* != .Function) continue;
                const fdec = d.Function;
                if (fdec.receiver_type != null) continue;
                const fid = fdec.span.file.int();
                const gop = try fn_counts.getOrPut(fdec.name.name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = 1;
                    try fn_files.put(fdec.name.name, fid);
                } else if (fn_files.get(fdec.name.name).? != fid) {
                    gop.value_ptr.* += 1;
                }
            }
            for (decls.items) |*d| {
                if (d.* != .Function) continue;
                const fdec = &d.Function;
                if (fdec.receiver_type != null) continue;
                if (fdec.visibility != .Private or fdec.is_expect or fdec.is_actual) continue;
                const count = fn_counts.get(fdec.name.name) orelse 0;
                if (count < 2) continue;
                const fid = fdec.span.file.int();
                const mangled = try std.fmt.allocPrint(allocator, "{s}$f{d}", .{ fdec.name.name, fid });
                const gop = try private_func_renames.getOrPut(fid);
                if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap([]const u8).init(allocator);
                try gop.value_ptr.put(fdec.name.name, mangled);
                fdec.name = .{ .name = mangled, .span = fdec.name.span };
            }
        }
        // Non-private decls of one simple name declared by two or more
        // packages: each gets its declaring-FQN slot.
        const FqnCand = struct { pkg: []const u8, fqn: []const u8 };
        var fqn_renamed = std.StringHashMap(std.ArrayList(FqnCand)).init(allocator);
        defer {
            var it = fqn_renamed.valueIterator();
            while (it.next()) |list| list.deinit(allocator);
            fqn_renamed.deinit();
        }
        for (decls.items) |*d| {
            if (d.* != .Property) continue;
            const p = d.Property;
            if (p.receiver_type != null) continue;
            if (p.visibility == .Private or p.is_expect or p.is_actual) continue;
            const count = name_counts.get(p.name.name) orelse 0;
            if (count < 2) continue;
            const pkg = decl_pkg.get(p.span) orelse "";
            if (pkg.len == 0) continue;
            // Rename only when another package also declares the name
            // non-privately: same-package duplicates are a kotlinc
            // redeclaration error, and a private-only collision is
            // already file-scoped above.
            var other_pkg = false;
            for (decls.items) |*d2| {
                if (d2.* != .Property) continue;
                const q = d2.Property;
                if (q.receiver_type != null or q.is_expect or q.is_actual) continue;
                if (q.visibility == .Private) continue;
                if (!std.mem.eql(u8, q.name.name, p.name.name)) continue;
                const qpkg = decl_pkg.get(q.span) orelse "";
                if (!std.mem.eql(u8, qpkg, pkg)) other_pkg = true;
            }
            if (!other_pkg) continue;
            const simple = p.name.name;
            const fqn = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ pkg, simple });
            const fid = p.span.file.int();
            const gop = try private_prop_renames.getOrPut(fid);
            if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap([]const u8).init(allocator);
            // A file-private decl of the same name in this file wins for
            // the file's own references; only add when absent.
            if (gop.value_ptr.get(simple) == null) try gop.value_ptr.put(simple, fqn);
            const lgop = try fqn_renamed.getOrPut(simple);
            if (!lgop.found_existing) lgop.value_ptr.* = .empty;
            try lgop.value_ptr.append(allocator, .{ .pkg = pkg, .fqn = fqn });
            p.name = .{ .name = fqn, .span = p.name.span };
        }
        // Resolve bare references from every other file: own package
        // first, then a named import of a declaring FQN, then a wildcard
        // import of a declaring package. A file with no visible
        // declaration keeps the name-keyed read (Kotlin would reject the
        // reference outright; klio's lenient pick stays unchanged).
        if (fqn_renamed.count() != 0) {
            for (files) |*f| {
                const fid = f.span.file.int();
                const fpkg = try packagePrefix(allocator, f.package);
                var it = fqn_renamed.iterator();
                while (it.next()) |e| {
                    const simple = e.key_ptr.*;
                    {
                        const fgop = try private_prop_renames.getOrPut(fid);
                        if (!fgop.found_existing) fgop.value_ptr.* = std.StringHashMap([]const u8).init(allocator);
                        if (fgop.value_ptr.get(simple) != null) continue;
                    }
                    var pick: ?[]const u8 = null;
                    for (e.value_ptr.items) |cand| {
                        if (std.mem.eql(u8, cand.pkg, fpkg)) pick = cand.fqn;
                    }
                    if (pick == null) {
                        for (f.imports) |*imp| {
                            if (imp.wildcard or imp.path.len == 0) continue;
                            if (imp.alias != null) continue;
                            if (!std.mem.eql(u8, imp.path[imp.path.len - 1].name, simple)) continue;
                            const imp_fqn = try joinIdents(allocator, imp.path, ".");
                            for (e.value_ptr.items) |cand| {
                                if (std.mem.eql(u8, cand.fqn, imp_fqn)) pick = cand.fqn;
                            }
                        }
                    }
                    if (pick == null) {
                        for (f.imports) |*imp| {
                            if (!imp.wildcard) continue;
                            const imp_pkg = try joinIdents(allocator, imp.path, ".");
                            for (e.value_ptr.items) |cand| {
                                if (std.mem.eql(u8, cand.pkg, imp_pkg) and pick == null) pick = cand.fqn;
                            }
                        }
                    }
                    if (pick) |fqn| {
                        const fgop = try private_prop_renames.getOrPut(fid);
                        if (!fgop.found_existing) fgop.value_ptr.* = std.StringHashMap([]const u8).init(allocator);
                        try fgop.value_ptr.put(simple, fqn);
                    }
                }
            }
        }
    }
    const prev_renames = ir.build.setLowerFilePrivateRenames(&private_prop_renames);
    defer _ = ir.build.setLowerFilePrivateRenames(prev_renames);
    const prev_fn_renames = ir.build.setLowerFilePrivateFuncRenames(&private_func_renames);
    defer _ = ir.build.setLowerFilePrivateFuncRenames(prev_fn_renames);

    // Kotlin scopes a file-`private` top-level class or typealias to its
    // declaring file; the lowered type namespace is flat. Mangle a private
    // class/typealias whose simple name another file also claims as a type
    // (class, object, or typealias — the coroutines pack's file-private
    // `typealias Node` must not capture another file's `Node` class), and
    // install the per-file rename table; the reference sites (bare heads,
    // `as`/`is`, supertypes) rewrite through the reference's span file.
    var file_type_renames = ir.build.FileTypeRenames.init(allocator);
    defer {
        var it = file_type_renames.valueIterator();
        while (it.next()) |inner| inner.deinit();
        file_type_renames.deinit();
    }
    var pkg_type_renames = ir.build.PkgTypeRenames.init(allocator);
    defer {
        var it = pkg_type_renames.valueIterator();
        while (it.next()) |inner| inner.deinit();
        pkg_type_renames.deinit();
    }
    {
        var name_files = std.StringHashMap(u32).init(allocator);
        defer name_files.deinit();
        var name_counts = std.StringHashMap(u32).init(allocator);
        defer name_counts.deinit();
        // A name any expect/actual declaration claims is shared by design
        // (the pair resolves as one classifier); it never participates in
        // collision mangling.
        var ea_names = StringSet.init(allocator);
        defer ea_names.deinit();
        for (decls.items) |*d| {
            const claim: ?struct { name: []const u8, fid: u32, ea: bool } = switch (d.*) {
                .Class => |*c| .{ .name = c.name.name, .fid = c.span.file.int(), .ea = c.is_expect or c.is_actual },
                .Object => |*o| .{ .name = o.name.name, .fid = o.span.file.int(), .ea = o.is_expect or o.is_actual },
                .TypeAlias => |*t| .{ .name = t.name.name, .fid = t.span.file.int(), .ea = false },
                else => null,
            };
            const cl = claim orelse continue;
            if (cl.ea) try ea_names.put(cl.name, {});
            const gop = try name_counts.getOrPut(cl.name);
            if (!gop.found_existing) {
                gop.value_ptr.* = 1;
                try name_files.put(cl.name, cl.fid);
            } else if (name_files.get(cl.name).? != cl.fid) {
                gop.value_ptr.* += 1;
            }
        }
        for (decls.items) |*d| {
            const target: ?struct { name: *ast.Ident, vis: ast.Visibility, is_ea: bool, fid: u32 } = switch (d.*) {
                .Class => |*c| .{ .name = &c.name, .vis = c.visibility, .is_ea = c.is_expect or c.is_actual, .fid = c.span.file.int() },
                .TypeAlias => |*t| .{ .name = &t.name, .vis = t.visibility, .is_ea = false, .fid = t.span.file.int() },
                else => null,
            };
            const tg = target orelse continue;
            if ((tg.vis != .Private and tg.vis != .Internal) or tg.is_ea) continue;
            if (ea_names.contains(tg.name.name)) continue;
            if ((name_counts.get(tg.name.name) orelse 0) < 2) continue;
            // A file-`private` classifier is file-scoped: the per-file map
            // serves every legal reference. An `internal` one cannot be
            // named from another pack (module) at all, so its legal
            // references are the declaring file (file map), same-package
            // files (package map), and imports — which resolve by FQN and
            // keep the source name via the fqn override. Without the
            // mangle the combined image keeps ONE of the same-named
            // top-levels: foundation's `text.input.internal.Node`
            // displaced the ui pointer-dispatch `Node` and
            // `super.buildCache` walked a parentless class.
            const mangled = try std.fmt.allocPrint(allocator, "{s}$f{d}", .{ tg.name.name, tg.fid });
            const gop = try file_type_renames.getOrPut(tg.fid);
            if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap([]const u8).init(allocator);
            try gop.value_ptr.put(tg.name.name, mangled);
            if (tg.vis == .Internal) {
                if (file_pkgs.get(span.FileId.from(tg.fid))) |pkg| {
                    const pgop = try pkg_type_renames.getOrPut(pkg);
                    if (!pgop.found_existing) pgop.value_ptr.* = std.StringHashMap([]const u8).init(allocator);
                    try pgop.value_ptr.put(tg.name.name, mangled);
                }
            }
            tg.name.* = .{ .name = mangled, .span = tg.name.span };
        }
    }
    const prev_ty_renames = ir.build.setLowerFileTypeRenames(&file_type_renames);
    defer _ = ir.build.setLowerFileTypeRenames(prev_ty_renames);
    const prev_pkg_renames = ir.build.setLowerPkgTypeRenames(&pkg_type_renames);
    defer _ = ir.build.setLowerPkgTypeRenames(prev_pkg_renames);
    const prev_file_pkgs = ir.build.setLowerFilePkgs(&file_pkgs);
    defer _ = ir.build.setLowerFilePkgs(prev_file_pkgs);

    const combined = KotlinFile{
        .package = null,
        .imports = try imports.toOwnedSlice(allocator),
        .decls = try decls.toOwnedSlice(allocator),
        .span = Span.init(span.FileId.from(0), 0, 0),
    };
    const built = try buildModuleWithOverrides(
        allocator,
        &combined,
        &fqn_overrides,
        &func_fqn_overrides,
        &decl_pkg,
        &file_pkgs,
        &file_modules,
        base,
        out_lifted,
    );
    if (compose_pass.composeAuditOn()) {
        const ca = &compose_pass.compose_audit;
        std.debug.print(
            "[KLIO_RESOLVE_AUDIT] compose summary (cumulative): agree={d} pair-stripped={d} pair-completed={d} lambda-arity={d} disagreements={d}\n",
            .{ ca.threaded_agree, ca.pair_stripped, ca.pair_completed, ca.lambda_arity_mismatch, ca.disagreements() },
        );
    }
    return built;
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

fn collectClassifierFqns(allocator: Allocator, d: *const Decl, pkg: []const u8, out: *SpanStrMap) Allocator.Error!void {
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
fn collectDeclPkgs(allocator: Allocator, d: *const Decl, pkg: []const u8, out: *SpanStrMap) Allocator.Error!void {
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
fn noteExtPropTypeHead(module: *Module, p: *const ast.Property) Allocator.Error!void {
    const recv = &(p.receiver_type orelse return);
    const ty = &(p.ty orelse return);
    if (ty.function != null or ty.name.name.len == 0) return;
    if (recv.name.name.len == 0) return;
    try module.registry.ext_prop_type_heads.put(
        .{ .a = recv.name.name, .b = p.name.name },
        ty.name.name,
    );
}

fn notePropScope(
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
fn memberSizedInitHead(c: *const ast.Class, init: *const ast.Expr) ?[]const u8 {
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

fn promoteConstHeads(l: []const u8, r: []const u8) ?[]const u8 {
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
fn constExprTypeHead(module: *Module, e: *const ast.Expr) ?[]const u8 {
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

fn literalTypeHead(e: *const ast.Expr) ?[]const u8 {
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
fn initCalleeName(e: *const ast.Expr) ?[]const u8 {
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

fn constLiteralOf(e: *const ast.Expr) ?ir.Const {
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
fn ownerSimplePath(owner: []const u8) ?[]const u8 {
    var rest = owner;
    while (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
        const seg = rest[0..dot];
        if (seg.len == 0 or !std.ascii.isLower(seg[0])) break;
        rest = rest[dot + 1 ..];
    }
    if (rest.len == owner.len or rest.len == 0) return null;
    return rest;
}

fn declPackage(a: Allocator, decl_pkg: *const SpanStrMap, overrides: *const SpanStrMap, decl_span: Span, package_prefix: []const u8, simple: []const u8) Allocator.Error![]const u8 {
    if (decl_pkg.get(decl_span)) |p| return p;
    const fqn = try resolveFqn(a, overrides, decl_span, package_prefix, simple);
    return packageOfFqn(fqn, simple);
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

/// Record every member name a class/object declares — functions,
/// properties, primary-ctor properties — recursing into nested classes
/// and objects (companions included) so the flat program-wide
/// member-name universe is complete.
fn collectClassMemberNamesInto(out: *StringSet, primary_params: []const ast.ClassParam, members: []const ast.Decl) Allocator.Error!void {
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

fn collectHierarchyMethodNames(start: []const u8, by_name: *const FileClasses, out: *StringSet, seen: *StringSet) Allocator.Error!void {
    const gop = try seen.getOrPut(start);
    if (gop.found_existing) return;
    const c = (by_name.get(start) orelse return).get();
    for (c.members) |*m| {
        if (m.* == .Function) try out.put(m.Function.name.name, {});
    }
    for (c.supertypes) |*st| try collectHierarchyMethodNames(st.name.name, by_name, out, seen);
}

fn memberTrailingLambdaShape(module: *const ir.Module, f: *const ast.Function) ?ir.ModuleRegistry.MemberTrailingLambdaShape {
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

fn collectMemberTrailingLambdaShapes(module: *ir.Module, by_name: *const FileClasses) Allocator.Error!void {
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
fn collectHierarchyShadowNames(start: []const u8, by_name: *const FileClasses, out: *StringSet, seen: *StringSet) Allocator.Error!bool {
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
fn propHeadSourceExpr(prop: *const ast.Property) ?*const ast.Expr {
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
fn propCtorHeadEvidence(prop: *const ast.Property, decls: []const ast.Decl, module: *const ir.Module) ?[]const u8 {
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
fn varargPropArrayHead(elem: []const u8) []const u8 {
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
fn notePropTypeRef(
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

fn classPropHead(c: *const ast.Class, ty: *const ast.TypeRef) ?[]const u8 {
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

fn collectHierarchySuperNames(a: Allocator, c: *const ast.Class, by_name: *const FileClasses, out: *std.ArrayList([]const u8), seen: *StringSet) Allocator.Error!void {
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

fn collectHierarchyMemberNames(start: []const u8, by_name: *const FileClasses, out: *StringSet, seen: *StringSet) Allocator.Error!void {
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
fn collectHierarchyCompanionMemberNames(start: []const u8, by_name: *const FileClasses, out: *StringSet, seen: *StringSet) Allocator.Error!void {
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
fn literalToConst(e: *const ast.Expr) ?Const {
    return switch (e.*) {
        .IntLit => |lit| switch (lit.kind) {
            // A suffix-less integer literal whose magnitude exceeds the `Int`
            // range is a `Long` in Kotlin; mirror the IntLit-lowering widening
            // in `ir/lower/expr.zig` so `const val` folding does not truncate.
            .Int => if (lit.value >= std.math.minInt(i32) and lit.value <= std.math.maxInt(i32))
                Const{ .Int = @truncate(lit.value) }
            else
                Const{ .Long = lit.value },
            .UInt => Const{ .Int = @truncate(lit.value) },
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
    decl_pkg: *const SpanStrMap,
    file_packages: ?*const std.AutoHashMap(ir.FileId, []const u8),
    file_modules: ?*const std.AutoHashMap(ir.FileId, u32),
    base: ?*const StdlibBase,
    out_lifted: ?*[]Decl,
) Allocator.Error!BuiltModule {
    // Extending build: start from a per-run clone of the base's lowered
    // module and side tables; `file` then carries ONLY the user decls and
    // every pass below appends on top of the seeded state.
    var seed: ?BuiltModule = if (base) |bs| try cloneBuiltForRun(allocator, &bs.built) else null;
    const module_ref = if (seed) |*s| s.module else try ObjRef(Module).init(allocator, Module.default(allocator));
    // The ObjRef holds the only handle during the build and nothing else
    // borrows it, so a raw pointer into the cell is a stable `*Module` for
    // the lowering driver.
    const module: *Module = &module_ref.cell.data;
    const a = module.registry.allocator;
    const base_funcs_len = module.funcs.items.len;
    if (file_packages) |packages| {
        var package_it = packages.iterator();
        while (package_it.next()) |entry| {
            try module.registry.file_packages.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
    if (file_modules) |modules| {
        var module_it = modules.iterator();
        while (module_it.next()) |entry| {
            try module.registry.file_modules.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    }

    const package_prefix = try packagePrefix(a, file.package);

    var object_names: std.ArrayList([]const u8) = if (seed) |*s| s.object_names else .empty;
    const base_object_names_len = object_names.items.len;
    var object_spans: std.ArrayList(Span) = .empty;
    defer object_spans.deinit(a);
    var companion_singletons = if (seed) |*s| s.companion_singletons else std.StringHashMap([]const u8).init(a);
    var nested_outer_members = lift.OuterMembers.init(a);
    var enclosing_class = if (seed) |*s| s.enclosing_class else lift.EnclosingMap.init(a);
    var nested_object_aliases = lift.AliasMap.init(a);
    if (base != null) {
        // Seed the lift-time alias/mangle context from the cloned registry
        // so user classes can extend base nested/mangled shapes. Inner maps
        // are deep-copied: the lift loop appends into them per class key.
        var it = module.registry.nested_object_aliases.iterator();
        while (it.next()) |e| {
            var inner = std.StringHashMap([]const u8).init(a);
            var iit = e.value_ptr.iterator();
            while (iit.next()) |ie| try inner.put(ie.key_ptr.*, ie.value_ptr.*);
            try nested_object_aliases.put(e.key_ptr.*, inner);
        }
    }

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
    if (base) |bs| {
        var it = bs.type_names.keyIterator();
        while (it.next()) |k| try top_level_type_names.put(k.*, {});
    }
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
    if (base != null) {
        var it = module.registry.mangled_nested.iterator();
        while (it.next()) |e| try mangled_nested.put(e.key_ptr.*, e.value_ptr.*);
    }

    var all_decls: std.ArrayList(Decl) = .empty;

    var dup_nested_names = StringSet.init(a);
    defer dup_nested_names.deinit();
    try lift.collectDupNestedNames(a, file.decls, &dup_nested_names);
    var lift_ctx = lift.LiftCtx{
        .allocator = a,
        .out_decls = &all_decls,
        .object_names = &object_names,
        .object_spans = &object_spans,
        .companion_singletons = &companion_singletons,
        .nested_outer_members = &nested_outer_members,
        .enclosing_class = &enclosing_class,
        .nested_object_aliases = &nested_object_aliases,
        .top_level_type_names = &top_level_type_names,
        .mangled_nested = &mangled_nested,
        .used_qualified_supertypes = &used_qualified_supertypes,
        .dup_nested_names = &dup_nested_names,
    };

    // Pending aliases for mangled pack-private objects.
    const PendingAlias = struct { cls: []const u8, simple: []const u8, mangled: []const u8 };
    var pending_object_aliases: std.ArrayList(PendingAlias) = .empty;
    defer pending_object_aliases.deinit(a);

    // Primary-constructor parameter lists of superseded `expect` classes
    // that carry defaults, keyed by class simple name. Kotlin declares
    // defaults on the `expect` only; the dropped expect's defaults
    // transplant onto the matching actual after the collection loop.
    var expect_class_ctor_params = std.StringHashMap([]const ast.ClassParam).init(a);
    defer expect_class_ctor_params.deinit();
    var expect_class_members = std.StringHashMap([]const Decl).init(a);
    defer expect_class_members.deinit();

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
                    try object_spans.append(a, o.span);
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
                try object_spans.append(a, o.span);
                const synth = try lift.synthesizeClassFromObject(a, o);
                try lift.liftClassRecursive(&lift_ctx, &synth, &.{});
                try all_decls.append(a, .{ .Class = synth });
            },
            .Class => |*c| {
                if (c.is_expect and actual_class_names.contains(c.name.name)) {
                    var any_ctor_default = false;
                    for (c.primary_params) |*pp| {
                        if (pp.default != null) any_ctor_default = true;
                    }
                    if (any_ctor_default) {
                        try expect_class_ctor_params.put(c.name.name, c.primary_params);
                    }
                    var any_member_default = false;
                    for (c.members) |*m| {
                        if (m.* != .Function) continue;
                        for (m.Function.params) |*p| {
                            if (p.default != null) any_member_default = true;
                        }
                    }
                    if (any_member_default) {
                        try expect_class_members.put(c.name.name, c.members);
                    }
                    continue;
                }
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
    // Repoint bare supertype references to a mangled private nested class
    // from inside its declaring class's subtree: a lifted member whose
    // enclosing chain reaches the aliasing outer sees the alias, exactly
    // the scope Kotlin gives the private nested declaration.
    if (nested_object_aliases.count() != 0) {
        for (all_decls.items) |*d| {
            if (d.* != .Class) continue;
            for (d.Class.supertypes) |*t| {
                if (t.qualified_path != null) continue;
                var owner: ?[]const u8 = d.Class.name.name;
                var hops: usize = 0;
                while (owner) |o| : (hops += 1) {
                    if (hops > 32) break;
                    if (nested_object_aliases.get(o)) |m| {
                        if (m.get(t.name.name)) |renamed| {
                            t.name.name = renamed;
                            break;
                        }
                    }
                    owner = enclosing_class.get(o);
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
            // An `actual` supersedes the `expect` it implements, which Kotlin
            // requires to share its package: key the function set by FQN, not
            // by simple name. Keyed by name, ANY actual killed EVERY same-named
            // expect in the program — `foundation.text.getString`'s actual
            // dropped `material3.internal.getString`'s unrelated expect, and
            // material3's own calls then saw no candidate but foundation's, in
            // a package they do not import.
            .Function => |*f| if (f.is_actual) {
                const fqn = try resolveFqn(a, func_fqn_overrides, f.span, package_prefix, f.name.name);
                try actual_func_names.put(fqn, {});
            },
            .Class => |*c| if (c.is_actual) try actual_class_names_set.put(c.name.name, {}),
            .Object => |*o| if (o.is_actual) try actual_object_names_set.put(o.name.name, {}),
            .Property => |p| if (p.is_actual) try actual_prop_names.put(p.name.name, {}),
            else => {},
        }
    }

    // Kotlin declares default parameter values on the `expect` fn ONLY —
    // the `actual` may not re-declare them and inherits them instead. The
    // retain pass below drops the superseded expect wholesale, so first
    // transplant its parameter defaults onto the matching actual (same
    // name, user arity, and receiver shape); an actual that re-declares a
    // default keeps its own.
    for (all_decls.items) |*d| {
        if (d.* != .Function) continue;
        const ef = &d.Function;
        if (!ef.is_expect) continue;
        var any_default = false;
        for (ef.params) |*pp| {
            if (pp.default != null) any_default = true;
        }
        if (!any_default) continue;
        for (all_decls.items) |*cand| {
            if (cand.* != .Function) continue;
            const af = &cand.Function;
            if (!af.is_actual) continue;
            if (!std.mem.eql(u8, af.name.name, ef.name.name)) continue;
            if (af.params.len != ef.params.len) continue;
            if ((af.receiver_type == null) != (ef.receiver_type == null)) continue;
            if (af.receiver_type != null and
                !std.mem.eql(u8, af.receiver_type.?.name.name, ef.receiver_type.?.name.name)) continue;
            for (af.params, ef.params) |*ap, *ep| {
                if (ap.default == null) ap.default = ep.default;
            }
        }
    }

    // The same inheritance applies to an `expect class`'s primary
    // constructor: the superseded expect was dropped during collection
    // (recording its parameter list when it carried defaults), so
    // transplant those defaults onto the matching `actual class` here
    // (e.g. ktor's `expect class ConcurrentMap(initialCapacity: Int =
    // INITIAL_CAPACITY)` makes the no-arg `ConcurrentMap()` shape
    // construct through the actual).
    if (expect_class_ctor_params.count() != 0) {
        for (all_decls.items) |*d| {
            if (d.* != .Class) continue;
            const ac = &d.Class;
            if (!ac.is_actual) continue;
            const eparams = expect_class_ctor_params.get(ac.name.name) orelse continue;
            if (ac.primary_params.len != eparams.len) continue;
            for (ac.primary_params, eparams) |*ap, *ep| {
                if (ap.default == null) ap.default = ep.default;
            }
        }
    }

    // Member defaults follow the same expect/actual rule as top-level
    // functions and constructors. The expect class is absent from
    // `all_decls`, so copy its defaults onto the signature-matching actual
    // member before class lowering builds default thunks and arity metadata.
    if (expect_class_members.count() != 0) {
        for (all_decls.items) |*d| {
            if (d.* != .Class) continue;
            const ac = &d.Class;
            if (!ac.is_actual) continue;
            const emembers = expect_class_members.get(ac.name.name) orelse continue;
            for (ac.members) |*am| {
                if (am.* != .Function) continue;
                for (emembers) |*em| {
                    if (em.* != .Function) continue;
                    const matched = transplantExpectMemberDefaults(&am.Function, &em.Function);
                    if (runtime.envOnce("KLIO_NU_TRACE")) |want| {
                        if (std.mem.eql(u8, want, am.Function.name.name)) {
                            std.debug.print("[expect-default] class={s} actual={s}/{d} expect={s}/{d} matched={}\n", .{
                                ac.name.name,
                                am.Function.name.name,
                                am.Function.params.len,
                                em.Function.name.name,
                                em.Function.params.len,
                                matched,
                            });
                        }
                    }
                    if (matched) break;
                }
            }
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
    if (out_lifted) |out| out.* = decls;

    // Map every class declaration by simple name. In an extending build the
    // base's lifted classes join the universe first: hierarchy walks, init
    // own-member collection and inline splicing for USER classes reach
    // through base supertypes, while base decls themselves are never
    // re-lowered (their lowered forms arrived via the seed clone).
    var file_classes = FileClasses.init(a);
    defer file_classes.deinit();
    if (base) |bs| {
        if (bs.file_classes.len != 0) {
            for (bs.file_classes) |kv| try file_classes.put(kv.k, FF(ast.Class).fromRef(kv.v));
        } else {
            for (bs.lifted_decls) |*d| {
                if (d.* == .Class) try file_classes.put(d.Class.name.name, FF(ast.Class).fromPtr(&d.Class));
            }
        }
    }
    for (decls) |*d| {
        if (d.* == .Class) try file_classes.put(d.Class.name.name, FF(ast.Class).fromPtr(&d.Class));
    }

    // Collect class / companion / top-level `const val name = <literal>`.
    {
        for (decls) |*d| {
            switch (d.*) {
                .Class => |*c| try collectConsts(module, c.name.name, c.members),
                .Property => |p| if (p.is_const) {
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

    // Per-class transitive member-function-name set. Seeded base classes
    // already carry theirs in the cloned registry; only new keys compute.
    {
        // A top-level class also records its hierarchy's method names
        // under its qualified name, so a reader holding the fqn gets an
        // exact answer when two packages share a simple name (geometry's
        // `Size` value class and the `androidx.annotation.Size`
        // annotation). The simple-name entry keeps its first registration.
        var it = file_classes.iterator();
        while (it.next()) |kv| {
            const cname = kv.key_ptr.*;
            const c = kv.value_ptr.get();
            const cfqn = try resolveFqn(a, fqn_overrides, c.name.span, package_prefix, cname);
            const fqn_wanted = !std.mem.eql(u8, cfqn, cname) and
                module.classIdByFqn(cfqn) != null and
                !module.registry.hierarchy_methods.contains(cfqn);
            const simple_wanted = !module.registry.hierarchy_methods.contains(cname);
            if (!fqn_wanted and !simple_wanted) continue;
            var methods = StringSet.init(a);
            var seen = StringSet.init(a);
            defer seen.deinit();
            try collectHierarchyMethodNames(cname, &file_classes, &methods, &seen);
            if (simple_wanted and fqn_wanted) {
                try module.registry.hierarchy_methods.put(cname, try methods.clone());
                try module.registry.hierarchy_methods.put(cfqn, methods);
            } else if (simple_wanted) {
                try module.registry.hierarchy_methods.put(cname, methods);
            } else {
                try module.registry.hierarchy_methods.put(cfqn, methods);
            }
        }
    }
    // Per-class transitive shadow-name set (all member kinds) for the
    // receiver-type-precise member-shadow gate, with the completeness bit
    // that keeps an unresolvable supertype chain conservative. Lookups fall
    // back to the program-wide set when a class has no entry (image-loaded
    // base classes: their method bodies' emissions were baked with the full
    // tables, so they never consult this).
    {
        var it = file_classes.keyIterator();
        while (it.next()) |cname| {
            if (module.registry.hierarchy_shadow_names.contains(cname.*)) continue;
            var names = StringSet.init(a);
            var seen = StringSet.init(a);
            defer seen.deinit();
            const complete = try collectHierarchyShadowNames(cname.*, &file_classes, &names, &seen);
            try module.registry.hierarchy_shadow_names.put(cname.*, .{ .names = names, .complete = complete });
        }
    }
    // Program-wide member-name universe: every name some class declares
    // as a member (function, property, primary-ctor property, companion /
    // nested-object member). A bare name in a receiver context is only
    // shadowable at runtime when it appears here, so lowering keeps the
    // static classification for every other name.
    for (decls) |*d| {
        if (d.* == .Class) {
            try collectClassMemberNamesInto(&module.registry.class_member_names, d.Class.primary_params, d.Class.members);
        } else if (d.* == .Object) {
            try collectClassMemberNamesInto(&module.registry.class_member_names, &.{}, d.Object.members);
        }
    }
    // Builtin value-class members no user class declares: the unsigned types'
    // backing `val data` (UByte/UShort/UInt/ULong). A bare `data` inside an
    // unsigned extension (`UByte.toHexString = data.toHexString(...)`) is
    // `this.data`, so it must shadow a same-named cross-package top-level the
    // way a declared member would — otherwise the stdlib file fails to resolve
    // whenever a test package happens to declare a top-level `data`.
    try module.registry.class_member_names.put("data", {});
    // Per-class property DECLARED type heads, with class type-parameter
    // names substituted by their bound's head (`data: T` in
    // `IterableTests<T : Iterable<String>>` records `Iterable`; an
    // init-inferred property takes the declared return type of the member
    // function its initializer calls, or the constructed class's head when
    // the initializer / getter single-expression is a constructor call —
    // `object Nodes { inline val Traversable get() = NodeKind<T>(...) }`
    // records `NodeKind`). A call on the property then resolves against
    // the STATIC type, as kotlinc does.
    for (decls) |*d| {
        if (d.* == .Class) {
            const c = &d.Class;
            for (c.primary_params) |*pp| {
                if (pp.property == null) continue;
                // A `vararg val` property's OBSERVED type is the materialized
                // array (`vararg val elements: T` is an `Array<out T>`), never
                // the element head — recording the element (or its bound)
                // made `elements.any { ... }` resolve against the wrong
                // receiver and decline the Array extension.
                if (pp.is_vararg) {
                    try module.registry.class_prop_type_heads.put(
                        .{ .a = c.name.name, .b = pp.name.name },
                        varargPropArrayHead(pp.ty.name.name),
                    );
                } else if (classPropHead(c, &pp.ty)) |head| {
                    try module.registry.class_prop_type_heads.put(.{ .a = c.name.name, .b = pp.name.name }, head);
                    try notePropTypeRef(a, module, c, pp.name.name, &pp.ty);
                }
            }
            for (c.members) |*m| {
                if (m.* != .Property) continue;
                const prop = m.Property;
                const ty_opt: ?*const ast.TypeRef = if (prop.ty) |*t| t else blk: {
                    const src = propHeadSourceExpr(prop) orelse break :blk null;
                    // `private val _start = start` beside `class R(start: Double)`
                    // is the parameter's type. The stdlib's ranges and `Lazy`
                    // are written this way, and it was the whole of the
                    // enclosing-member bucket.
                    if (src.* == .Path and src.Path.segments.len == 1 and
                        !std.mem.eql(u8, runtime.envOnce("KLIO_FACTORY_PROP") orelse "1", "0"))
                    {
                        const pname = src.Path.segments[0].name;
                        for (c.primary_params) |*pp| {
                            if (std.mem.eql(u8, pp.name.name, pname)) break :blk &pp.ty;
                        }
                        break :blk null;
                    }
                    if (src.* != .Call) break :blk null;
                    const callee = src.Call.callee;
                    if (callee.* != .Path or callee.Path.segments.len != 1) break :blk null;
                    const fname = callee.Path.segments[0].name;
                    for (c.members) |*fm| {
                        if (fm.* != .Function) continue;
                        if (!std.mem.eql(u8, fm.Function.name.name, fname)) continue;
                        if (fm.Function.return_type) |*rt| break :blk rt;
                        break :blk null;
                    }
                    // A FUNCTION-TYPED ctor property invoked as the
                    // initializer: `val data = createFrom(...)` beside
                    // `class C<T>(val createFrom: (...) -> T)` is the
                    // function type's declared return — with the class's
                    // own parameter substituted by its bound below, the
                    // same rule an annotated `T` property already gets.
                    for (c.primary_params) |*pp| {
                        if (!std.mem.eql(u8, pp.name.name, fname)) continue;
                        if (pp.ty.function) |ft| break :blk &ft.ret;
                        break :blk null;
                    }
                    break :blk null;
                };
                if (ty_opt) |ty| {
                    if (classPropHead(c, ty)) |head| {
                        try module.registry.class_prop_type_heads.put(.{ .a = c.name.name, .b = prop.name.name }, head);
                        try notePropTypeRef(a, module, c, prop.name.name, ty);
                    }
                } else if (propCtorHeadEvidence(prop, decls, module)) |head| {
                    try module.registry.class_prop_type_heads.put(.{ .a = c.name.name, .b = prop.name.name }, head);
                } else if (prop.init != null and memberSizedInitHead(c, &prop.init.?) != null) {
                    try module.registry.class_prop_type_heads.put(
                        .{ .a = c.name.name, .b = prop.name.name },
                        memberSizedInitHead(c, &prop.init.?).?,
                    );
                } else if (prop.init) |*init| {
                    // An unannotated property states its type through a
                    // literal initializer — `private var index = 0` in the
                    // array iterators — and a bare read of one was the whole
                    // enclosing-member block of the unbound census.
                    if (literalTypeHead(init)) |head| {
                        try module.registry.class_prop_type_heads.put(.{ .a = c.name.name, .b = prop.name.name }, head);
                    }
                }
            }
            // A NESTED class's own properties register under its simple
            // name, which is the head a receiver typed `HexFormat.BytesHexFormat`
            // resolves to. The walk above only reaches top-level classes, so
            // every nested declaration's properties were unknown — and the
            // stdlib puts its option records there
            // (`bytesFormat.byteSeparator`).
            for (c.members) |*nm| {
                if (nm.* != .Class) continue;
                const nested = &nm.Class;
                if (nested.is_companion) continue;
                for (nested.primary_params) |*pp| {
                    if (pp.property == null) continue;
                    if (pp.is_vararg) continue;
                    if (classPropHead(nested, &pp.ty)) |head| {
                        try module.registry.class_prop_type_heads.put(.{ .a = nested.name.name, .b = pp.name.name }, head);
                        try notePropTypeRef(a, module, nested, pp.name.name, &pp.ty);
                    }
                }
                for (nested.members) |*nmem| {
                    if (nmem.* != .Property) continue;
                    const nprop = nmem.Property;
                    if (nprop.ty) |*ty| {
                        if (classPropHead(nested, ty)) |head| {
                            try module.registry.class_prop_type_heads.put(.{ .a = nested.name.name, .b = nprop.name.name }, head);
                            try notePropTypeRef(a, module, nested, nprop.name.name, ty);
                        }
                    } else if (nprop.init) |*init| {
                        if (literalTypeHead(init)) |head| {
                            try module.registry.class_prop_type_heads.put(.{ .a = nested.name.name, .b = nprop.name.name }, head);
                        }
                    }
                }
            }
            // COMPANION property heads register under the companion's
            // lifted name (`Byte$Companion`) — the key a class-named read
            // (`Byte.MAX_VALUE.toLong()`) consults.
            for (c.members) |*cm| {
                if (cm.* != .Class) continue;
                const cobj = &cm.Class;
                if (!cobj.is_companion) continue;
                const ckey = try std.fmt.allocPrint(allocator, "{s}$Companion", .{c.name.name});
                for (cobj.members) |*om| {
                    if (om.* != .Property) continue;
                    const cprop = om.Property;
                    if (cprop.ty) |*ty| {
                        try module.registry.class_prop_type_heads.put(.{ .a = ckey, .b = cprop.name.name }, ty.qualified_path orelse ty.name.name);
                    } else if (cprop.init) |*init| {
                        if (literalTypeHead(init)) |head| {
                            try module.registry.class_prop_type_heads.put(.{ .a = ckey, .b = cprop.name.name }, head);
                        } else if (propCtorHeadEvidence(cprop, decls, module)) |head| {
                            // `val iso = LongParser(MAX_MILLIS, allowSign = true)`
                            // inside LongParser's own companion states the head
                            // exactly as a top-level object's would.
                            try module.registry.class_prop_type_heads.put(.{ .a = ckey, .b = cprop.name.name }, head);
                        }
                    }
                }
            }
        } else if (d.* == .Object) {
            const o = &d.Object;
            for (o.members) |*m| {
                if (m.* != .Property) continue;
                const prop = m.Property;
                if (prop.ty) |*ty| {
                    try module.registry.class_prop_type_heads.put(.{ .a = o.name.name, .b = prop.name.name }, ty.qualified_path orelse ty.name.name);
                } else if (propCtorHeadEvidence(prop, decls, module)) |head| {
                    try module.registry.class_prop_type_heads.put(.{ .a = o.name.name, .b = prop.name.name }, head);
                }
            }
        }
    }
    // Per-class transitive supertype-name chain, nearest first, so body
    // lowering can rank extension receivers against the enclosing class
    // before the IR-side supertype slots are filled.
    {
        var it = file_classes.iterator();
        while (it.next()) |e| {
            if (module.registry.class_super_names.contains(e.key_ptr.*)) continue;
            var chain: std.ArrayList([]const u8) = .empty;
            var seen = StringSet.init(a);
            defer seen.deinit();
            try seen.put(e.key_ptr.*, {});
            try collectHierarchySuperNames(a, e.value_ptr.get(), &file_classes, &chain, &seen);
            // Every enum class IS-A `kotlin.Enum` implicitly; record it so
            // Enum-receiver ranking and enum recognition see the relation.
            if (e.value_ptr.get().is_enum and !seen.contains("Enum")) {
                try chain.append(a, "Enum");
            }
            try module.registry.class_super_names.put(e.key_ptr.*, try chain.toOwnedSlice(a));
            // Declared upper bounds of the class's type parameters, for
            // the collection-stub bridge disproof at method dispatch.
            // Unbounded params are recorded with an `Any` bound (inert for
            // the refute pass): dispatch needs the complete NAME list to
            // tell a class-type-param-typed method param (`put(key: Key)`
            // on `ConcurrentMap<Key, Value>`) from a nominal reference to
            // an unrelated same-named class.
            if (!module.registry.class_type_param_bounds.contains(e.key_ptr.*)) {
                const class = e.value_ptr.get();
                if (try collectClassTypeParamBounds(a, class)) |bounds| {
                    try module.registry.class_type_param_bounds.put(e.key_ptr.*, bounds);
                }
            }
        }
    }
    // Private stored properties shadowing a strict supertype's same-name
    // declaration get their own storage cell (Kotlin semantics): record
    // them so construction and the scope-qualified accessors use the
    // owner-mangled key.
    {
        var it = file_classes.iterator();
        while (it.next()) |e| {
            const cname = e.key_ptr.*;
            const chain = module.registry.class_super_names.get(cname) orelse continue;
            if (chain.len == 0) continue;
            const c = e.value_ptr.get();
            var prop_i: usize = 0;
            _ = &prop_i;
            const record = struct {
                fn f(mod: *ir.Module, al: Allocator, cls: []const u8, sups: []const []const u8, fc: *const FileClasses, pname: []const u8, as_override: bool) Allocator.Error!void {
                    for (sups) |sup| {
                        const sref = fc.get(sup) orelse continue;
                        const sc = sref.get();
                        var declares = false;
                        for (sc.primary_params) |*sp| {
                            if (sp.property != null and std.mem.eql(u8, sp.name.name, pname)) declares = true;
                        }
                        for (sc.members) |*sm| {
                            if (sm.* != .Property) continue;
                            const sp = sm.Property;
                            // Only a STORED supertype property forces distinct
                            // cells; an abstract or getter-only declaration has
                            // no backing field to protect.
                            if (sp.getter != null or sp.delegate != null or sp.is_abstract) continue;
                            if (sp.init == null) continue;
                            if (std.mem.eql(u8, sp.name.name, pname)) declares = true;
                        }
                        if (declares) {
                            const key = try std.fmt.allocPrint(al, "{s}\x1f{s}", .{ cls, pname });
                            if (as_override) {
                                try mod.registry.override_cell_props.put(key, {});
                            } else {
                                try mod.registry.private_shadow_props.put(key, {});
                            }
                            return;
                        }
                    }
                }
            }.f;
            for (c.primary_params) |*p| {
                if (p.property == null) continue;
                if (p.visibility == .Private) {
                    try record(module, a, cname, chain, &file_classes, p.name.name, false);
                } else {
                    // A non-private ctor-param property matching a STORED
                    // supertype property is necessarily an `override`
                    // (kotlinc rejects the shadow form) — the parser does
                    // not carry the modifier on params.
                    try record(module, a, cname, chain, &file_classes, p.name.name, true);
                }
            }
            for (c.members) |*m| {
                if (m.* != .Property) continue;
                const pr = m.Property;
                if (pr.getter != null or pr.delegate != null) continue;
                if (pr.visibility == .Private) {
                    try record(module, a, cname, chain, &file_classes, pr.name.name, false);
                } else if (pr.is_override and pr.init != null) {
                    try record(module, a, cname, chain, &file_classes, pr.name.name, true);
                }
            }
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
    // Mangled nested-class names, for qualified type references
    // (`x is Outer.Inner` must bind the lifted class, not a
    // same-simple-name top-level one).
    {
        var it = mangled_nested.iterator();
        while (it.next()) |e| try module.registry.mangled_nested.put(e.key_ptr.*, e.value_ptr.*);
    }
    // The enclosing-class chain backs the lowerer's scope-true alias walk
    // (a private nested class is visible throughout its declaring class's
    // subtree), and the companion-singleton map backs the companion-
    // receiver reified-inline splice gate; install both before any body
    // lowers. The registry materialisation below re-puts the same entries.
    {
        var it = enclosing_class.iterator();
        while (it.next()) |e| try module.registry.enclosing_class.put(e.key_ptr.*, e.value_ptr.*);
    }
    {
        var it = companion_singletons.iterator();
        while (it.next()) |e| try module.registry.companion_singletons.put(e.key_ptr.*, e.value_ptr.*);
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
    // Record the owner class of every inline member fn, keyed by AST pointer,
    // so a bare call to a name declared as an inline member in several
    // unrelated classes binds the enclosing class's own-hierarchy overload
    // (`file_classes` here spans user + base classes, materialised to the same
    // AST pointers `candidatesFor` returns).
    {
        ir.lower.resetInlineMemberOwners();
        ir.lower.resetMemberPropAsts();
        ir.lower.resetClassSupertypeRefs();
        ir.lower.resetMemberExtPropRecv();
        // Same lifetime rule as the two above: the registered expression-body
        // member ASTs point into the PREVIOUS build's arena.
        ir.lower.resetExprBodyMembers();
        var fcit = file_classes.iterator();
        while (fcit.next()) |e| {
            registerInlineMemberOwners(e.value_ptr.get().members, e.value_ptr.get().name.name);
            registerMemberPropAsts(a, e.value_ptr.get().members, e.value_ptr.get().name.name);
            ir.lower.registerClassSupertypeRefs(e.value_ptr.get().name.name, e.value_ptr.get().supertypes);
            registerClassSupertypes(e.value_ptr.get().members);
        }
        // Top-level objects (and any class the map above missed) from this
        // build's decls — user files plus re-parsed pack sources.
        for (decls) |*d| {
            switch (d.*) {
                .Object => |*o| registerMemberPropAsts(a, o.members, o.name.name),
                .Class => |*c| registerMemberPropAsts(a, c.members, c.name.name),
                else => {},
            }
        }
        registerClassSupertypes(decls);
    }
    {
        var inline_fns = std.StringHashMap(std.ArrayList(FF(ast.Function))).init(a);
        // Base inline fns first, preserving the whole-program declaration
        // order of each overload list (base decls precede user decls). A loaded
        // base carries the lazy `inline_by_name` refs (its `lifted_decls` may be
        // empty); a freshly-built base walks its decls.
        if (base) |bs| {
            if (bs.inline_by_name.len != 0) {
                for (bs.inline_by_name) |kv| {
                    const gop = try inline_fns.getOrPut(kv.k);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    for (kv.v) |r| try gop.value_ptr.append(a, FF(ast.Function).fromRef(r));
                }
            } else {
                for (bs.lifted_decls) |*d| try collectInline(a, d, &inline_fns);
            }
        }
        for (decls) |*d| try collectInline(a, d, &inline_fns);
        var frozen = std.StringHashMap([]const FF(ast.Function)).init(tl);
        var it = inline_fns.iterator();
        while (it.next()) |e| {
            try frozen.put(e.key_ptr.*, try e.value_ptr.toOwnedSlice(a));
        }
        inline_fns.deinit();
        ir.lower.setInlineFnAsts(frozen);
        // setInlineFnAsts dropped the previous build's FuncId-keyed inline
        // registrations; replay the base's so user calls the symbol index
        // resolves to a base inline fn still splice its declaration.
        if (base) |bs| {
            for (bs.inline_ids) |entry| try ir.lower.registerInlineFnId(entry.id, entry.f);
            // Inline bodies in a loaded base are deferred markers; install the
            // section + decoder so a splice materialises the real body on first
            // use. Decoded into the base's own process-lifetime arena, since the
            // patched `lifted_decls` are reused across per-program builds.
            ir.lower.setDeferredSection(bs.deferred_bodies, bs.arena, image.decodeDeferredBody);
        }

        // Default-import host bindings shadow same-simple-name inline
        // fns. The name domain comes from the same constructor the
        // link-time bare-name maps use (`stdlib.noteBareNameMapping`),
        // restricted to the implicitly imported packages, so the
        // "default-import owns this bare name" answer has one source.
        var owned = std.StringHashMap([]const u8).init(a);
        defer owned.deinit();
        var fqn_it = stdlib.implementations.allFqns();
        while (fqn_it.next()) |fqn| {
            try stdlib.noteBareNameMapping(&owned, &stdlib.IMPLICITLY_IMPORTED_PACKAGES, fqn);
        }
        var shadowed = StringSet.init(tl);
        var owned_it = owned.keyIterator();
        while (owned_it.next()) |k| try shadowed.put(k.*, {});
        ir.lower.setShadowedInlineNames(shadowed);
    }

    // Top-level (file-scope) property names, plus each declaration's
    // scoping identity (FQN + package) so a bare read ranks under Kotlin
    // scoping exactly as a bare call does.
    {
        var top_props = StringSet.init(tl);
        if (base) |bs| {
            if (bs.top_props.len != 0) {
                for (bs.top_props) |tp| {
                    try top_props.put(tp.name, {});
                    const gop = try module.registry.top_level_prop_pkgs.getOrPut(tp.name);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    var dup = false;
                    for (gop.value_ptr.items) |existing| {
                        if (std.mem.eql(u8, existing.fqn, tp.fqn)) dup = true;
                    }
                    if (!dup) try gop.value_ptr.append(a, .{ .fqn = tp.fqn, .package = tp.package });
                    if (tp.type_head.len != 0) {
                        try module.registry.top_level_prop_type_heads.put(tp.fqn, tp.type_head);
                    }
                }
            } else {
                for (bs.lifted_decls) |*d| {
                    if (d.* == .Property and d.Property.receiver_type == null) {
                        try top_props.put(d.Property.name.name, {});
                        try notePropScope(a, module, func_fqn_overrides, decl_pkg, package_prefix, d.Property);
                    }
                    if (d.* == .Property) try noteExtPropTypeHead(module, d.Property);
                }
            }
        }
        for (decls) |*d| {
            if (d.* == .Property and d.Property.receiver_type == null) {
                try top_props.put(d.Property.name.name, {});
                try notePropScope(a, module, func_fqn_overrides, decl_pkg, package_prefix, d.Property);
            }
            if (d.* == .Property) try noteExtPropTypeHead(module, d.Property);
        }
        ir.lower.setTopLevelPropNames(top_props);
    }

    // Non-wildcard imports keyed by declaring file then bound leaf name;
    // wildcard imports keyed by declaring file as dotted package paths.
    for (file.imports) |*imp| {
        if (imp.path.len == 0) continue;
        if (imp.wildcard) {
            // `import pkg.*`: record the package per file so the symbol
            // index can rank wildcard-imported candidates above the
            // implicitly-imported built-ins.
            var dotted: std.ArrayList(u8) = .empty;
            defer dotted.deinit(a);
            for (imp.path, 0..) |id, i| {
                if (i != 0) try dotted.append(a, '.');
                try dotted.appendSlice(a, id.name);
            }
            const wgop = try module.registry.import_wildcards.getOrPut(imp.span.file);
            if (!wgop.found_existing) wgop.value_ptr.* = .empty;
            try wgop.value_ptr.append(a, try a.dupe(u8, dotted.items));
            continue;
        }
        var dotted: std.ArrayList(u8) = .empty;
        defer dotted.deinit(a);
        const segs = try a.alloc([]const u8, imp.path.len);
        for (imp.path, 0..) |id, i| {
            segs[i] = id.name;
            if (i != 0) try dotted.append(a, '.');
            try dotted.appendSlice(a, id.name);
        }
        const leaf = if (imp.alias) |al| al.name else imp.path[imp.path.len - 1].name;
        const fgop = try module.registry.import_aliases.getOrPut(imp.span.file);
        if (!fgop.found_existing) fgop.value_ptr.* = std.StringHashMap(std.ArrayList(ir.ModuleRegistry.ImportPath)).init(a);
        const lgop = try fgop.value_ptr.getOrPut(leaf);
        if (!lgop.found_existing) lgop.value_ptr.* = .empty;
        // Kotlin keeps every same-leaf import in scope (the second one
        // is an ambiguity at the use site, not a shadow), so the leaf
        // maps to ALL its import paths; only an exact repeat collapses.
        var already = false;
        for (lgop.value_ptr.items) |p| {
            if (std.mem.eql(u8, p.fqn, dotted.items)) {
                already = true;
                break;
            }
        }
        if (already) {
            a.free(segs);
        } else {
            try lgop.value_ptr.append(a, .{ .fqn = try a.dupe(u8, dotted.items), .segs = segs });
        }
    }

    // Pre-register every class by its FULLY-QUALIFIED name so resolution is
    // order-independent AND a same-simple-name class in another package (an
    // `internal` `kotlinx.coroutines...Segment` vs a public `kotlinx.io.Segment`)
    // does not collapse onto a single slot — each keeps its own stub before any
    // body lowers, so a bare `Name(args)` at its own construction site resolves
    // to the package-local class through the scope-tiered index.
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
        const cls_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
        const cid = try module.reserveClassFqn(a, c.name.name, cfqn, cls_pkg, c.is_inner);
        module.classes.items[cid.int()].is_object = module.classes.items[cid.int()].is_object or
            spanNamesObject(object_spans.items, c.span);
    }
    // Link every reserved class shell to its exact superclass identities
    // before any method body lowers. Static applicability can then prove
    // subtype arguments for calls into forward top-level declarations.
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
        const cls_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
        try ir.lower.decl.populateClassSupertypes(module, c, cfqn, cls_pkg);
    }
    // Reserve complete member headers globally after every class shell exists
    // but before any method body lowers. Forward references, inherited calls,
    // and same-arity overloads then share stable declaration identities.
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
        const cls_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
        try ir.lower.decl.reserveMemberHeaders(module, c, cfqn, cls_pkg);
    }
    // Register typealias → head tags BEFORE phase-2 body lowering so the
    // lambda-arity detection (`argFnArities`) resolves an aliased
    // function-typed parameter (`RoutingHandler = RoutingContext.() -> Unit`)
    // to its `Function{N}` tag while lowering the call site. The later pass
    // (after lowering) re-registers and rewrites param-type names for the
    // applicability/score consumers.
    for (decls) |*d| {
        if (d.* != .TypeAlias) continue;
        const ta = &d.TypeAlias;
        const type_params = try a.alloc([]const u8, ta.type_params.len);
        for (ta.type_params, type_params) |*param, *out| out.* = param.name.name;
        const alias_shape = ir.ModuleRegistry.TypeAliasShape{
            .type_params = type_params,
            .target = try ir.lower.decl.loweredTypeRef(a, &ta.target, true),
        };
        try module.registry.type_alias_types.put(ta.name.name, alias_shape);
        const alias_fqn = try resolveFqn(
            a,
            fqn_overrides,
            ta.span,
            package_prefix,
            ta.name.name,
        );
        try module.registry.type_alias_types.put(alias_fqn, alias_shape);
        if (ta.target.function) |ft| {
            const tag = try std.fmt.allocPrint(a, "Function{d}", .{ft.params.len});
            try module.registry.type_aliases.put(ta.name.name, tag);
            if (ft.receiver != null) {
                try module.registry.recv_fn_aliases.put(ta.name.name, @intCast(@min(ft.params.len, 255)));
            }
        }
    }
    ir.lower.setTypeAliasTags(&module.registry.type_aliases);
    // Member signatures need the same source-order independence as top-level
    // headers. Record the trailing receiver-lambda portion now, before any
    // class body lowers, so inherited calls in earlier source files still
    // receive their declaration-site lambda shape.
    try collectMemberTrailingLambdaShapes(module, &file_classes);
    // Fill every reserved class's primary-constructor parameters BEFORE any
    // class method body is lowered. Class method bodies lower inside the loop
    // below in declaration order, so a constructor call to a class declared
    // later (`class A { fun f() = B("x") {} }; class B(d, flag, block)`) must
    // already see B's parameter types for the argument-lambda arity and the
    // trailing-lambda realignment (otherwise the lambda binds the wrong slot).
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
        if (module.classIdByFqn(cfqn)) |cid| {
            if (cid.int() < module.classes.items.len and module.classes.items[cid.int()].primary_params.len == 0) {
                module.classes.items[cid.int()].primary_params = try ir.lower.decl.classPrimaryParams(a, c);
            }
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
            const id = module.nextFuncId();
            const fqn = try resolveFqn(a, func_fqn_overrides, f.span, package_prefix, f.name.name);
            const receiver_ty: ?ir.TypeRef = if (f.receiver_type) |*rt|
                try ir.lower.decl.loweredTypeRef(a, rt, true)
            else
                null;
            const receiver_abi_name: ?[]const u8 = if (f.receiver_type) |*rt|
                rt.qualified_path orelse rt.name.name
            else
                null;
            const host_symbol = stdlib.declarationHostSymbol(
                fqn,
                receiver_abi_name,
                f.name.name,
            );
            // The header stub carries the full declared parameter list (the
            // same `loweredTypeRef` rendering the phase-2 body install uses),
            // not just a receiver placeholder: class methods lower between
            // phase 1 and phase 2, and their call-site shape decisions — a
            // trailing lambda's expected arity, default-gap checks — read
            // `Func.params` and must see the declared signature, not an
            // empty stub.
            var stub_params: []Param = &.{};
            {
                const has_recv = f.receiver_type != null;
                const n = f.params.len + @intFromBool(has_recv);
                if (n != 0) {
                    const ps = try a.alloc(Param, n);
                    var pi: usize = 0;
                    if (receiver_ty) |rt| {
                        ps[0] = .{
                            .name = "this",
                            .ty = rt,
                            .default = null,
                            .is_property = false,
                            .is_vararg = false,
                            .has_default = false,
                        };
                        pi = 1;
                    }
                    for (f.params) |*p| {
                        ps[pi] = .{
                            .name = p.name.name,
                            .ty = ir.lower.decl.renameParamHead(try ir.lower.decl.loweredTypeRef(a, &p.ty, true), &p.ty),
                            .default = null,
                            .composable_arity = compose_pass.composableFunctionArity(&p.ty),
                            .is_property = false,
                            .is_vararg = p.is_vararg,
                            .has_default = p.default != null,
                        };
                        pi += 1;
                    }
                    stub_params = ps;
                }
            }
            try module.funcs.append(a, .{
                .id = id,
                .name = f.name.name,
                .fqn = fqn,
                .package = decl_pkg.get(f.span) orelse packageOfFqn(fqn, f.name.name),
                .params = stub_params,
                .return_ty = if (f.return_type) |*rt|
                    ir.lower.decl.renameParamHead(try ir.lower.decl.loweredTypeRef(a, rt, true), rt)
                else
                    ir.build.typeUnit(),
                .return_ty_declared = f.return_type != null,
                .n_locals = 0,
                .blocks = &.{},
                .entry = ir.BlockId.from(0),
                .is_suspend = false,
                .is_tailrec = f.is_tailrec,
                .is_lambda = false,
                .is_inline = f.is_inline,
                .capture_order = &.{},
                .implicit_label = null,
                .low_priority = ir.lower.decl.isLowPriorityOverload(f),
                .deprecated_error = ir.lower.decl.annotationsAreDeprecatedError(f.annotations),
                .is_expect = f.is_expect,
            });
            try module.func_index.append(a, .{ .name = f.name.name, .id = id });
            try module.recordFuncDeclSpan(a, f.name.span, id);
            if (f.visibility == .Private) {
                try module.registry.private_fn_files.put(id, f.name.span.file);
            }
            const gop = try module.func_name_index.getOrPut(f.name.name);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, id);
            if (f.is_tailrec) try module.tailrec_fn_names.append(a, f.name.name);
            try module.decl_user_params.put(id.int(), @intCast(f.params.len));
            var arity: ir.Module.DeclArity = undefined;
            {
                var has_vararg = false;
                var required: u32 = 0;
                for (f.params) |*p| {
                    if (p.is_vararg) has_vararg = true;
                    if (p.default == null and !p.is_vararg) required += 1;
                }
                arity = .{ .required = required, .total = @intCast(f.params.len), .has_vararg = has_vararg };
                try module.decl_user_arity.put(id.int(), arity);
            }
            var decl_sig: []ir.TypeRef = &.{};
            {
                // Declared parameter types at full structural
                // granularity, rendered by the SAME lowering body params
                // use (`loweredTypeRef`), so the symbol index proves or
                // refutes signature identity identically for a forward
                // reference and for its later-lowered body.
                const sig = try a.alloc(ir.TypeRef, f.params.len);
                for (f.params, 0..) |*p, i| {
                    sig[i] = try ir.lower.decl.loweredTypeRef(a, &p.ty, true);
                }
                try module.decl_user_sig.put(id.int(), sig);
                decl_sig = sig;
            }
            try module.decl_sigs.put(id.int(), .{
                .receiver_ty = receiver_ty,
                .arity = arity,
                .sig = decl_sig,
                .kind = if (f.receiver_type != null) .top_level_extension else .plain,
                .visibility = f.visibility,
                .is_inline = f.is_inline,
                .is_suspend = f.is_suspend,
                .has_body = f.body != null,
                .host_symbol = host_symbol,
            });
            try module.decl_span.put(id.int(), f.span);
            if (f.body != null) try module.decl_ast_body.put(id.int(), {});
            // Type-parameter names, registered at header time so a body
            // lowered before this declaration's own (a forward reference,
            // or any earlier decl calling into it) already sees the
            // generic signature through the registry.
            if (f.type_params.len != 0) {
                var tp_names: std.ArrayList([]const u8) = .empty;
                for (f.type_params) |*tp| try tp_names.append(a, tp.name.name);
                try module.registry.func_type_params.put(id, tp_names);
                var hdr_bounds: std.ArrayList(ir.ModuleRegistry.TypeParamBound) = .empty;
                for (f.type_params) |*tp| {
                    const first = hdr_bounds.items.len;
                    if (tp.upper_bound) |*ub| {
                        try hdr_bounds.append(a, .{
                            .param = tp.name.name,
                            .bound = ub.name.name,
                            .complete = boundTypeRecordComplete(ub),
                        });
                    }
                    for (f.where_bounds) |*wb| {
                        if (!std.mem.eql(u8, wb.name.name, tp.name.name)) continue;
                        try hdr_bounds.append(a, .{
                            .param = tp.name.name,
                            .bound = wb.bound.name.name,
                            .complete = boundTypeRecordComplete(&wb.bound),
                        });
                    }
                    if (hdr_bounds.items.len - first > 1) {
                        for (hdr_bounds.items[first..]) |*bd| bd.complete = false;
                    }
                }
                const hdr_skip = blk: {
                    const w = std.c.getenv("KLIO_HDR_BOUNDS_SKIP") orelse break :blk false;
                    break :blk std.mem.indexOf(u8, std.mem.span(w), f.name.name) != null;
                };
                // Default ON. The armed roll-out list is empty: the
                // contains loop was the smart-cast `this`-narrow being
                // invisible to bare-call resolution, ArrayDeque's was the
                // enclosing method's `this` decl leaking through a
                // receiver-less lambda, and the DeepRecursive slowdown was
                // the same over-broad consult — all fixed by the genuine-
                // narrow gate. Full armed sweep: 117/0 at 1:03 wall on the
                // heaviest file. `KLIO_HDR_BOUNDS=0` disables for
                // single-binary A/B; KLIO_HDR_BOUNDS_SKIP bisects by name.
                const hdr_on = blk: {
                    const w = std.c.getenv("KLIO_HDR_BOUNDS") orelse break :blk true;
                    break :blk !std.mem.eql(u8, std.mem.span(w), "0");
                };
                if (hdr_on and hdr_bounds.items.len != 0 and !hdr_skip) {
                    if (runtime.envSetOnce("KLIO_HDR_BOUNDS_LIST")) {
                        std.debug.print("[hdrb] {s}", .{f.name.name});
                        for (hdr_bounds.items) |bd| std.debug.print(" {s}<:{s}", .{ bd.param, bd.bound });
                        std.debug.print("\n", .{});
                    }
                    try module.registry.func_type_param_bounds.put(id, try hdr_bounds.toOwnedSlice(a));
                } else {
                    hdr_bounds.deinit(a);
                }
            }
            // Key the inline-fn AST by the header stub's FuncId, so a
            // bare call the symbol index resolves to this declaration
            // splices exactly this declaration.
            if (f.is_inline and f.body != null) {
                try ir.lower.registerInlineFnId(id.int(), FF(ast.Function).fromPtr(f));
            }
            try stub_ids.append(a, id);
        }
    }

    // Register callable extension-property headers before any body lowers.
    // Kotlin permits `receiver.property(args)` when the property's value is a
    // function. Without this declaration shape, the call is indistinguishable
    // from a member call until runtime and loses the extension getter.
    for (decls) |*d| {
        if (d.* != .Property) continue;
        const p = d.Property;
        const recv = p.receiver_type orelse continue;
        const prop_ty = p.ty orelse continue;
        const fn_ty = prop_ty.function orelse continue;
        const recv_name: []const u8 = if (recv.qualified_path) |qp|
            (if (std.mem.endsWith(u8, qp, ".Companion")) qp else recv.name.name)
        else
            recv.name.name;
        const fqn = try resolveFqn(
            a,
            fqn_overrides,
            p.span,
            package_prefix,
            p.name.name,
        );
        const pkg = try declPackage(
            a,
            decl_pkg,
            fqn_overrides,
            p.span,
            package_prefix,
            p.name.name,
        );
        const gop = try module.registry.callable_extension_props.getOrPut(p.name.name);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, .{
            .fqn = fqn,
            .package = pkg,
            .receiver = recv_name,
            .file = p.name.span.file,
            .value_arity = @intCast(fn_ty.params.len),
            .is_private = p.visibility == .Private,
        });
    }

    // Lower each class after the top-level function headers are registered,
    // so a class method body's bare call to a sibling top-level function
    // resolves against the complete header set. The receiver-type member
    // gate keeps a same-named implicit-receiver member preferred over the
    // now-visible global.
    var empty_set = StringSet.init(a);
    defer empty_set.deinit();
    // Receiver-function-typed property heads, recorded BEFORE any body
    // lowering: method bodies (and their lambdas) consult the registry
    // while they lower, so the entries must exist first.
    //
    // Walk `file_classes`, not `decls`: an EXTENDING build (a user program on
    // top of a baked stdlib+packs base) only carries the user's declarations in
    // `decls`, so registering from those alone left every PACK class out — the
    // map came back empty for a compose program and every receiver-fn-property
    // lookup silently missed. `file_classes` is the base's classes plus the
    // user's, which is the universe the sibling registry tables already use.
    {
        var fc_it = file_classes.iterator();
        while (fc_it.next()) |e| {
            const c = e.value_ptr.get();
            for (c.primary_params) |*pp| {
                if (pp.ty.function) |ft| {
                    if (ft.receiver) |rt| {
                        try module.registry.recv_fn_props.put(.{ .a = c.name.name, .b = pp.name.name }, rt.name.name);
                    }
                }
            }
            for (c.members) |*m| {
                if (m.* != .Property) continue;
                const p = m.Property;
                if (p.ty) |pt| {
                    if (pt.function) |ft| {
                        if (ft.receiver) |rt| {
                            try module.registry.recv_fn_props.put(.{ .a = c.name.name, .b = p.name.name }, rt.name.name);
                        }
                    }
                }
            }
        }
    }
    for (decls) |*d| {
        if (d.* == .Class) {
            const c = &d.Class;
            const extras: *const StringSet = nested_outer_members.getPtr(c.name.name) orelse &empty_set;
            const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
            const cls_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
            _ = try ir.lower.lowerClassWithExtrasFqnPkg(module, c, &file_classes, extras, cfqn, cls_pkg);
        }
    }

    // Phase 2 of two-phase consumption: lower each function body into its
    // reserved slot, resolving bodies and extension-receiver bindings
    // against the now-complete phase-1 header set (above).
    var main_id: ?FuncId = null;
    var func_defaults = if (seed) |*s| s.func_defaults else std.AutoHashMap(u32, []?FuncId).init(a);
    var func_type_params = if (seed) |*s| s.func_type_params else std.AutoHashMap(u32, [][]const u8).init(a);
    var stub_cursor: usize = 0;
    for (decls) |*d| {
        if (d.* == .Function) {
            const f = &d.Function;
            // A header-only declaration (a retained `expect`) keeps its
            // phase-1 stub — declared params, empty blocks — so
            // `hasBody()` stays false and `linkBodyless` settles its
            // executable form (native binding or body-sibling redirect).
            // Lowering it would manufacture a one-block `return Unit`
            // body that shadows the real dispatch.
            if (f.body == null) {
                stub_cursor += 1;
                continue;
            }
            const stub_pkg = module.funcByIdMut(stub_ids.items[stub_cursor]).?.package;
            const prev_pkg = ir.lower.decl.setLowerSelfPackage(stub_pkg);
            const func = try ir.lower.lowerFunctionBodyInto(module, f, &file_classes);
            _ = ir.lower.decl.setLowerSelfPackage(prev_pkg);
            const id = stub_ids.items[stub_cursor];
            stub_cursor += 1;
            var placed = func;
            placed.id = id;
            // Preserve the stub's FQN + package (carry the package prefix).
            placed.fqn = module.funcByIdMut(id).?.fqn;
            placed.package = module.funcByIdMut(id).?.package;
            module.funcByIdMut(id).?.* = placed;
            // Kotlin scopes a private top-level declaration to its FILE:
            // record it so dispatch never binds a private extension from
            // another file.
            if (f.visibility == .Private) {
                try module.registry.private_fn_files.put(id, f.name.span.file);
            }
            if (std.mem.eql(u8, f.name.name, "main")) main_id = id;
            try module.top_level.append(a, id);

            if (f.type_params.len != 0) {
                var names: std.ArrayList([]const u8) = .empty;
                for (f.type_params) |*tp| try names.append(a, tp.name.name);
                try func_type_params.put(id.int(), try names.toOwnedSlice(a));
                // Declared upper bounds (`<T : Number>` and `where` clauses)
                // for the strict extension-receiver prover.
                var bounds: std.ArrayList(ir.ModuleRegistry.TypeParamBound) = .empty;
                for (f.type_params) |*tp| {
                    const first = bounds.items.len;
                    if (tp.upper_bound) |*ub| {
                        try bounds.append(a, .{
                            .param = tp.name.name,
                            .bound = ub.name.name,
                            .complete = boundTypeRecordComplete(ub),
                        });
                    }
                    for (f.where_bounds) |*where_bound| {
                        if (!std.mem.eql(u8, where_bound.name.name, tp.name.name)) continue;
                        try bounds.append(a, .{
                            .param = tp.name.name,
                            .bound = where_bound.bound.name.name,
                            .complete = boundTypeRecordComplete(&where_bound.bound),
                        });
                    }
                    if (bounds.items.len - first > 1) {
                        for (bounds.items[first..]) |*bound| bound.complete = false;
                    }
                }
                if (bounds.items.len != 0) {
                    try module.registry.func_type_param_bounds.put(id, try bounds.toOwnedSlice(a));
                } else {
                    bounds.deinit(a);
                }
            }

            var any_default = false;
            for (f.params) |*p| {
                if (p.default != null) any_default = true;
            }
            if (any_default) {
                const thunk_pkg = ir.lower.decl.setLowerSelfPackage(module.funcByIdMut(id).?.package);
                defer _ = ir.lower.decl.setLowerSelfPackage(thunk_pkg);
                const lowered_names = module.funcByIdMut(id).?.params;
                const offset = if (lowered_names.len > f.params.len) lowered_names.len - f.params.len else 0;
                var name_refs: std.ArrayList([]const u8) = .empty;
                defer name_refs.deinit(a);
                for (lowered_names) |*p| try name_refs.append(a, p.name);
                var slots: std.ArrayList(?FuncId) = .empty;
                var i: usize = 0;
                while (i < offset) : (i += 1) try slots.append(a, null);
                for (f.params, 0..) |*p, idx| {
                    if (p.default) |default_expr| {
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
    var body_prop_inits = if (seed) |*s| s.body_prop_inits else PairFuncMap.init(a);
    var instance_prop_getters = if (seed) |*s| s.instance_prop_getters else PairFuncMap.init(a);
    var getter_prop_names = if (seed) |*s| s.getter_prop_names else std.StringHashMap(void).init(a);
    var instance_prop_setters = if (seed) |*s| s.instance_prop_setters else PairFuncMap.init(a);
    var instance_prop_private = if (seed) |*s| s.instance_prop_private else PairFuncMap.init(a);
    var delegated_body_props = if (seed) |*s| s.delegated_body_props else StrPairSet.init(a);
    var primary_ctor_default_thunks = if (seed) |*s| s.primary_ctor_default_thunks else std.StringHashMap([]?FuncId).init(a);
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        const body_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
        const prev_body_pkg = ir.lower.decl.setLowerSelfPackage(body_pkg);
        defer _ = ir.lower.decl.setLowerSelfPackage(prev_body_pkg);
        var own_members = StringSet.init(a);
        defer own_members.deinit();
        for (c.primary_params) |*p| {
            if (p.property != null) try own_members.put(p.name.name, {});
        }
        for (c.members) |*m| {
            switch (m.*) {
                .Property => |p| try own_members.put(p.name.name, {}),
                .Function => |*f| try own_members.put(f.name.name, {}),
                else => {},
            }
        }
        // Companion-object members, enum entries, and nested-class names are
        // visible under their bare names in a primary-ctor default value
        // (`class Stroke(cap: StrokeCap = DefaultCap)` reads the companion's
        // `DefaultCap`), the same as inside a method body.
        try ir.lower.decl.addVisibleMemberNames(c, &own_members);
        var prop_init_params: std.ArrayList([]const u8) = .empty;
        defer prop_init_params.deinit(a);
        try prop_init_params.append(a, "this");
        for (c.primary_params) |*p| try prop_init_params.append(a, p.name.name);

        var any_ctor_default = false;
        for (c.primary_params) |*p| {
            if (p.default != null) any_ctor_default = true;
        }
        if (any_ctor_default) {
            // A ctor default runs before `this` exists — the runtime passes a
            // null receiver. Give the receiver slot a non-`this` name so a bare
            // companion member (`cap = DefaultCap`) resolves against the
            // companion object (the param-thunk path) rather than a null-`this`
            // field read. Previous params still resolve by their own names.
            //
            // An INNER class's defaults DO have a lexical receiver: the
            // enclosing instance (`val maxIndex: Int = size` reads the outer
            // `size`; Kotlin forbids reading the class's own members here,
            // and an inner class cannot declare a companion). The slot is
            // named `this` so a bare name lowers through the method-body
            // member-or-global walk, and the runtime passes the OUTER
            // instance in that slot.
            var ctor_default_params: std.ArrayList([]const u8) = .empty;
            defer ctor_default_params.deinit(a);
            try ctor_default_params.append(a, if (c.is_inner) "this" else "$ctor_default_recv");
            for (c.primary_params) |*p| try ctor_default_params.append(a, p.name.name);
            var slots = try a.alloc(?FuncId, c.primary_params.len);
            // Parallel to `ctor_default_params`, whose first slot is the
            // synthesized receiver and has no declared type.
            const ctor_default_types = try a.alloc(?ast.TypeRef, c.primary_params.len + 1);
            ctor_default_types[0] = null;
            for (c.primary_params, 0..) |*p, i| ctor_default_types[i + 1] = p.ty;
            const ctor_enclosing: ?*const StringSet = nested_outer_members.getPtr(c.name.name);
            for (c.primary_params, 0..) |*p, i| {
                if (p.default) |*e| {
                    const nm = try std.fmt.allocPrint(a, "__ctor_default_{s}_{s}", .{ c.name.name, p.name.name });
                    module.pending_param_types = ctor_default_types;
                    slots[i] = try ir.lower.lowerExprAsParamThunkScopedEnclosing(module, ctor_default_params.items, e, nm, c.name.name, &own_members, ctor_enclosing);
                } else {
                    slots[i] = null;
                }
            }
            try primary_ctor_default_thunks.put(c.name.name, slots);
            const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
            if (!std.mem.eql(u8, cfqn, c.name.name)) {
                try primary_ctor_default_thunks.put(cfqn, slots);
            }
        }

        const body_prop_cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
        const body_prop_dual = !std.mem.eql(u8, body_prop_cfqn, c.name.name);
        const body_prop_class_id = module.classIdByFqn(body_prop_cfqn);
        const body_prop_param_types: []const ir.Param = if (body_prop_class_id) |cid|
            module.classes.items[cid.int()].primary_params
        else blk: {
            // A LOCAL class (declared in a function body) has no module class
            // entry, but its body-property initializers still see the primary
            // ctor params (`class N(property: String) { var property =
            // property }` reads the PARAM). Derive the param list from the
            // AST so the initializer thunks declare them.
            if (c.primary_params.len == 0) break :blk &.{};
            const ps = try a.alloc(ir.Param, c.primary_params.len);
            for (c.primary_params, 0..) |*pp, pi| {
                ps[pi] = .{
                    .name = pp.name.name,
                    .ty = .{ .name = pp.ty.name.name, .nullable = pp.ty.nullable, .args = &.{} },
                    .default = null,
                    .is_property = pp.property != null,
                    .is_vararg = pp.is_vararg,
                };
            }
            break :blk ps;
        };
        // For a nested class the lexically-enclosing class's (and its
        // companion's) members are visible bare inside its body-property
        // initializers; thread them so a bare `Default` referencing the
        // enclosing companion does not bind a foreign global class.
        const body_enclosing: ?*const StringSet = nested_outer_members.getPtr(c.name.name);
        for (c.members) |*m| {
            if (m.* != .Property) continue;
            const p = m.Property;
            // A MEMBER-EXTENSION property (`private val Any?.exceptionOrNull`
            // inside JobSupport) is part of the extension surface (registered
            // with its owner below), never an instance property of the class:
            // registering its accessor as an instance getter made the walk
            // treat every subtype instance as shadowed by a "member" the
            // private-inheritance rule then skipped, so the read missed.
            if (p.receiver_type != null) continue;
            // An explicit backing field's initializer IS the property's
            // storage initializer.
            const storage_init: ?*const ast.Expr = if (p.init) |*init|
                init
            else if (p.explicit_field) |ef|
                (if (ef.init) |*finit| finit else null)
            else
                null;
            const storage_init_ty: ?ast.TypeRef = if (p.init != null)
                p.ty
            else if (p.explicit_field) |ef|
                (ef.ty orelse p.ty)
            else
                p.ty;
            // A PRIVATE stored property never participates in override
            // dispatch (same rule as private accessors below): record it so
            // the virtual property walk can skip a foreign class's private
            // field — ktor's `HttpClientEngineBase.closed = atomic(false)`
            // must never answer the HttpClientEngine interface's own
            // private computed `closed`.
            if (p.visibility == .Private and p.getter == null) {
                const priv_fid = FuncId.from(0);
                try instance_prop_private.put(.{ .a = c.name.name, .b = p.name.name }, priv_fid);
                const cfqn_priv = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
                if (!std.mem.eql(u8, cfqn_priv, c.name.name)) {
                    try instance_prop_private.put(.{ .a = cfqn_priv, .b = p.name.name }, priv_fid);
                }
            }
            if (storage_init) |init| {
                const nm = try std.fmt.allocPrint(a, "__init_prop_{s}_{s}", .{ c.name.name, p.name.name });
                const fid = try ir.lower.lowerPropertyInitExpr(module, c.name.name, &own_members, body_enclosing, prop_init_params.items, body_prop_param_types, init, nm, storage_init_ty);
                try body_prop_inits.put(.{ .a = c.name.name, .b = p.name.name }, fid);
                if (body_prop_dual) try body_prop_inits.put(.{ .a = body_prop_cfqn, .b = p.name.name }, fid);
            } else if (p.delegate) |delegate| {
                // Register the delegation marker under the FQN; the bare
                // simple name only when it IS the FQN (a local/packageless
                // class). A simple-name alias for a packaged class let a
                // foreign namesake intercept an unrelated class's field read
                // (ModelViewTests' \`Person { var name by mutableStateOf }\`
                // routed a local test \`Person(val name, ...)\`'s plain field
                // through delegate getValue on the stored String).
                try delegated_body_props.put(.{ .a = body_prop_cfqn, .b = p.name.name }, {});
                const nm = try std.fmt.allocPrint(a, "__delegate_prop_{s}_{s}", .{ c.name.name, p.name.name });
                const fid = try ir.lower.lowerPropertyInitExpr(module, c.name.name, &own_members, body_enclosing, prop_init_params.items, body_prop_param_types, delegate, nm, null);
                try body_prop_inits.put(.{ .a = c.name.name, .b = p.name.name }, fid);
                if (body_prop_dual) try body_prop_inits.put(.{ .a = body_prop_cfqn, .b = p.name.name }, fid);
            }
            if (p.getter) |getter| {
                const nm = try std.fmt.allocPrint(a, "__get_{s}_{s}", .{ c.name.name, p.name.name });
                const fid = switch (getter.body) {
                    .Expr => |body| blk: {
                        const rewritten = try lift.substituteFieldWithThis(a, p.name.name, &body);
                        // The property's declared type is the expression body's
                        // expected type: a getter returning a lambda
                        // (`get() = { collectTo(it) }` typed `suspend (P) -> Unit`)
                        // needs it to prove the lambda's parameter shape.
                        break :blk try ir.lower.lowerAccessorExprWithExpected(module, c.name.name, &own_members, &.{"this"}, rewritten, nm, p.ty);
                    },
                    .Block => |blk_body| blk: {
                        const rewritten = try lift.rewriteBlockField(a, &blk_body, p.name.name);
                        break :blk try ir.lower.lowerAccessorBlock(module, c.name.name, &own_members, &.{"this"}, &rewritten, nm);
                    },
                };
                // A PRIVATE class's accessors register under the FQN key
                // only: the SIMPLE slot is shared program-wide, and a
                // private namesake (kotlinx-coroutines-test's `private
                // class AtomicBoolean`) must never capture dispatch for an
                // unrelated public class. Instances of the private class
                // itself resolve through the FQN-first probe.
                const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
                const class_private = c.visibility == .Private and !std.mem.eql(u8, cfqn, c.name.name);
                if (!class_private) {
                    try instance_prop_getters.put(.{ .a = c.name.name, .b = p.name.name }, fid);
                }
                try getter_prop_names.put(p.name.name, {});
                if (!std.mem.eql(u8, cfqn, c.name.name)) {
                    try instance_prop_getters.put(.{ .a = cfqn, .b = p.name.name }, fid);
                }
                if (p.visibility == .Private) {
                    try instance_prop_private.put(.{ .a = c.name.name, .b = p.name.name }, fid);
                    if (!std.mem.eql(u8, cfqn, c.name.name)) {
                        try instance_prop_private.put(.{ .a = cfqn, .b = p.name.name }, fid);
                    }
                }
            }
            if (p.setter) |setter| {
                const setter_param_name = if (setter.params.len != 0) setter.params[0].name else "value";
                const nm = try std.fmt.allocPrint(a, "__set_{s}_{s}", .{ c.name.name, p.name.name });
                // The value parameter's type is the property's declared
                // type: `set(value) { if (value <= 0) ... }` resolves
                // `value` statically.
                const vty_head: ?[]const u8 = if (p.ty) |*t| t.name.name else null;
                const vty_nullable = if (p.ty) |*t| t.nullable else false;
                const fid = switch (setter.body) {
                    .Expr => |body| blk: {
                        const rewritten = try lift.substituteFieldWithThis(a, p.name.name, &body);
                        break :blk try ir.lower.lowerSetterExprTyped(module, c.name.name, &own_members, &.{ "this", setter_param_name }, setter_param_name, vty_head, vty_nullable, rewritten, nm);
                    },
                    .Block => |blk_body| blk: {
                        const rewritten = try lift.rewriteBlockField(a, &blk_body, p.name.name);
                        break :blk try ir.lower.lowerSetterBlockTyped(module, c.name.name, &own_members, &.{ "this", setter_param_name }, setter_param_name, vty_head, vty_nullable, &rewritten, nm);
                    },
                };
                const set_cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
                const set_class_private = c.visibility == .Private and !std.mem.eql(u8, set_cfqn, c.name.name);
                if (!set_class_private) {
                    try instance_prop_setters.put(.{ .a = c.name.name, .b = p.name.name }, fid);
                }
                if (!std.mem.eql(u8, set_cfqn, c.name.name)) {
                    try instance_prop_setters.put(.{ .a = set_cfqn, .b = p.name.name }, fid);
                }
            }
        }
    }

    // Synthesise a runtime ClassDef for every class in the file. The
    // table is FQN-keyed: every class registers under its fully-qualified
    // name (which IS the simple name for a root-package class), and those
    // entries are authoritative — they are written first and a simple-name
    // alias can never displace one. The simple-name view exists only for
    // callers that hold no resolved identity; where two packages declare
    // the same simple name the first declaration claims the alias, so the
    // view is declaration-order deterministic, and every identity-carrying
    // path (NewInstance ClassId, `::Ctor`, copy) resolves by FQN instead.
    const globals_for_capture = try ObjRef(Env).init(a, Env.init(a));
    var classes = if (seed) |*s| s.classes else ClassTable.init(a);
    // Defs created by THIS build: the parent/interface backpatch below
    // links only these — seeded base defs arrive fully linked.
    var new_defs: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer new_defs.deinit(a);
    var simple_aliases: std.ArrayList(struct { name: []const u8, def: ObjRef(ClassDef) }) = .empty;
    defer simple_aliases.deinit(a);
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        const def = try buildClassDef(module, a, c, fqn_overrides, package_prefix, &object_spans, globals_for_capture, &file_classes);
        try new_defs.append(a, def);
        const fqn_g = def.borrow();
        const def_fqn = fqn_g.get().fqn;
        fqn_g.deinit();
        if (def_fqn.len != 0 and !std.mem.eql(u8, def_fqn, c.name.name)) {
            try simple_aliases.append(a, .{ .name = c.name.name, .def = def.clone() });
            try classes.put(def_fqn, def);
        } else {
            try classes.put(c.name.name, def);
        }
    }
    for (simple_aliases.items) |alias| {
        const gop = try classes.getOrPut(alias.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = alias.def;
            continue;
        }
        // An authoritative entry (a root-package class whose FQN is the
        // key) is never displaced. Among aliases, a user-package class
        // outranks a shipped one — decl concatenation puts shipped
        // sources first, so this preserves the binding user programs
        // always had — and equally-ranked aliases keep the first
        // declaration.
        const existing_fqn = blk: {
            const g = gop.value_ptr.borrow();
            defer g.deinit();
            break :blk g.get().fqn;
        };
        const alias_fqn = blk: {
            const g = alias.def.borrow();
            defer g.deinit();
            break :blk g.get().fqn;
        };
        const existing_authoritative = std.mem.eql(u8, existing_fqn, alias.name);
        if (!existing_authoritative and
            ir.shippedFqnHead(existing_fqn) and !ir.shippedFqnHead(alias_fqn))
        {
            gop.value_ptr.deinit();
            gop.value_ptr.* = alias.def;
        } else {
            alias.def.deinit();
        }
    }

    // Populate enum entries + per-entry overrides + ctor-arg thunks. An
    // extending build continues the base's identity sequence so default
    // toString/hashCode renderings match the whole-program numbering.
    var next_id: u64 = if (base) |bs| bs.enum_id_next else 1;
    var enum_entry_arg_inits: std.ArrayList(EnumEntryArgInit) = if (seed) |*s| s.enum_entry_arg_inits else .empty;
    var enum_entry_methods = if (seed) |*s| s.enum_entry_methods else std.HashMap(StrPair, EnumEntryMethod, StrPairContext, std.hash_map.default_max_load_percentage).init(a);
    var enum_entry_synth_class = if (seed) |*s| s.enum_entry_synth_class else PairStrMap.init(a);
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        if (!c.is_enum) continue;
        const enum_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
        const prev_enum_pkg = ir.lower.decl.setLowerSelfPackage(enum_pkg);
        defer _ = ir.lower.decl.setLowerSelfPackage(prev_enum_pkg);
        const enum_key = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
        const class_def = classes.get(enum_key) orelse classes.get(c.name.name) orelse continue;
        var entries: std.ArrayList(ClassDef.EnumEntry) = .empty;
        for (c.enum_entries, 0..) |*entry, ordinal| {
            const id = next_id;
            next_id += 1;
            var fields: std.ArrayList(InstanceData.Field) = .empty;
            try fields.append(a, .{ .name = "name", .value = .{ .String = try runtime.strInit(a, entry.name.name) } });
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
                try fields.append(a, .{ .name = "__enum_entry_class__", .value = .{ .String = try runtime.strInit(a, synth_class_name) } });
            }

            const inst = try ObjRef(InstanceData).init(a, .{
                .class = class_def.clone(),
                .fields = fields,
                .outer = null,
                .identity = id,
                .native_state = null,
            });
            const entry_annotations = blk: {
                const recs = try a.alloc(runtime.AnnotationRecord, entry.annotations.len);
                for (entry.annotations, recs) |*ann, *rec| rec.* = try annotationRecordFor(module, a, ann);
                break :blk recs;
            };
            try entries.append(a, .{
                .name = entry.name.name,
                .value = .{ .Instance = inst },
                .annotation_records = entry_annotations,
            });

            // Lower an init thunk per constructor slot: the entry's explicit
            // args, then default values for any trailing primary-ctor params
            // the entry omits (`enum E(val n:Int, val f:Boolean=false){A(1)}`
            // must still initialize `f`). Kotlin requires the provided args to
            // be a prefix, so defaults fill the suffix and stay index-aligned.
            var slot_count: usize = entry.args.len;
            while (slot_count < c.primary_params.len and c.primary_params[slot_count].default != null) : (slot_count += 1) {}
            if (slot_count != 0) {
                var fids = try a.alloc(FuncId, slot_count);
                for (0..slot_count) |idx| {
                    const nm = try std.fmt.allocPrint(a, "__enum_arg_{s}_{s}_{d}", .{ c.name.name, entry.name.name, idx });
                    const arg_expr = if (idx < entry.args.len) &entry.args[idx] else &c.primary_params[idx].default.?;
                    fids[idx] = try ir.lower.lowerExprAsThunk(module, arg_expr, nm);
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
    // Only defs created by this build link here; seeded base defs arrived
    // fully linked from the per-run clone.
    {
        for (new_defs.items) |def| {
            const dg = def.borrow();
            const supertype_names = dg.get().supertype_names;
            const supertype_paths = dg.get().supertype_paths;
            const def_pkg = packageOfFqn(dg.get().fqn, dg.get().name);
            dg.deinit();
            var ifaces: std.ArrayList(ObjRef(ClassDef)) = .empty;
            for (supertype_names, 0..) |sup_name, si| {
                // A supertype name is written as a simple name in source;
                // resolve it Kotlin-style — the subclass's own package
                // before the cross-package simple-name view — so a
                // same-simple-name class from another package cannot
                // become the parent. A qualified reference (`Outer.Inner`)
                // resolves by FQN suffix first, disambiguating a nested base
                // from a same-simple-name class in scope (including a subtype
                // named like its base).
                const qp: ?[]const u8 = if (si < supertype_paths.len) supertype_paths[si] else null;
                const sup_def = blk: {
                    if (qp) |p| {
                        if (classTableByQualifiedSuffix(&classes, p)) |sd| break :blk sd;
                    }
                    if (def_pkg.len != 0) {
                        const qualified = try std.fmt.allocPrint(a, "{s}.{s}", .{ def_pkg, sup_name });
                        defer a.free(qualified);
                        if (classes.get(qualified)) |sd| break :blk sd;
                    }
                    break :blk classes.get(sup_name) orelse continue;
                };
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
        // Nested-class tables: a class's `nested_classes` names every class
        // / object / interface declared in its body, resolved to the runtime
        // defs registered above. The image loader restores this table for
        // baked classes; a freshly built program must fill it the same way,
        // or a reified `typeOf<Nested>()` inside the outer class cannot
        // reach the nested def.
        try fillNestedClassTables(a, decls, &classes, "");
    }

    // Parent-ctor argument thunks.
    var parent_ctor_args = if (seed) |*s| s.parent_ctor_args else std.StringHashMap([]FuncId).init(a);
    var parent_ctor_arg_names = if (seed) |*s| s.parent_ctor_arg_names else std.StringHashMap([]const ?[]const u8).init(a);
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        var first_parent_args: ?[]const ast.Expr = null;
        var first_idx: usize = 0;
        for (c.supertype_args, 0..) |sa, si| {
            if (sa) |args| {
                first_parent_args = args;
                first_idx = si;
                break;
            }
        }
        const parent_args = first_parent_args orelse continue;
        // The argument labels for the same supertype (`: Base(objects = 2)`),
        // parallel to `parent_args`; empty/`null` where all positional.
        const parent_names: ?[]const ?[]const u8 =
            if (first_idx < c.supertype_arg_names.len) c.supertype_arg_names[first_idx] else null;
        var param_refs: std.ArrayList([]const u8) = .empty;
        defer param_refs.deinit(a);
        if (c.is_inner) try param_refs.append(a, "this");
        for (c.primary_params) |*p| try param_refs.append(a, p.name.name);
        var own = StringSet.init(a);
        defer own.deinit();
        try collectCompanionOwnMembers(c, &own);
        const parent_enclosing: ?*const StringSet = nested_outer_members.getPtr(c.name.name);
        var fids = try a.alloc(FuncId, parent_args.len);
        // Parallel to `param_refs`, which leads with `this` for an inner class.
        const parent_arg_types = try a.alloc(?ast.TypeRef, param_refs.items.len);
        {
            const off: usize = if (c.is_inner) 1 else 0;
            if (c.is_inner) parent_arg_types[0] = null;
            for (c.primary_params, 0..) |*p, i| {
                if (off + i < parent_arg_types.len) parent_arg_types[off + i] = p.ty;
            }
        }
        const pca_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
        const prev_pca_pkg = ir.lower.decl.setLowerSelfPackage(pca_pkg);
        defer _ = ir.lower.decl.setLowerSelfPackage(prev_pca_pkg);
        for (parent_args, 0..) |*e, idx| {
            const nm = try std.fmt.allocPrint(a, "__parent_ctor_arg_{s}_{d}", .{ c.name.name, idx });
            module.pending_param_types = parent_arg_types;
            module.pending_thunk_expected = parentCtorParamExpected(a, module, c, first_idx, idx);
            fids[idx] = try ir.lower.lowerExprAsParamThunkScopedEnclosing(
                module,
                param_refs.items,
                e,
                nm,
                c.name.name,
                &own,
                parent_enclosing,
            );
        }
        try parent_ctor_args.put(c.name.name, fids);
        const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
        if (!std.mem.eql(u8, cfqn, c.name.name)) try parent_ctor_args.put(cfqn, fids);
        // Record labels only when at least one argument is named — a fully
        // positional call keeps the empty default and binds by position.
        if (parent_names) |names| {
            var any_named = false;
            for (names) |n| {
                if (n != null) {
                    any_named = true;
                    break;
                }
            }
            if (any_named) {
                const dup = try a.dupe(?[]const u8, names);
                try parent_ctor_arg_names.put(c.name.name, dup);
                if (!std.mem.eql(u8, cfqn, c.name.name)) try parent_ctor_arg_names.put(cfqn, dup);
            }
        }
    }

    // Init blocks as 1-arg thunks taking `this` plus ctor params.
    var init_blocks = if (seed) |*s| s.init_blocks else std.StringHashMap([]FuncId).init(a);
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
                .Property => |p| try own_members.put(p.name.name, {}),
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
        const ib_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
        const prev_ib_pkg = ir.lower.decl.setLowerSelfPackage(ib_pkg);
        defer _ = ir.lower.decl.setLowerSelfPackage(prev_ib_pkg);
        // Parallel to `local_params`, whose first slot is the receiver.
        const ib_types = try a.alloc(?ast.TypeRef, local_params.items.len);
        ib_types[0] = null;
        for (c.primary_params, 0..) |*p, i| {
            if (i + 1 < ib_types.len) ib_types[i + 1] = p.ty;
        }
        for (c.init_blocks, 0..) |*blk, idx| {
            const nm = try std.fmt.allocPrint(a, "__init_block_{s}_{d}", .{ c.name.name, idx });
            module.pending_param_types = ib_types;
            fids[idx] = try ir.lower.lowerInitBlockWithParams(module, c.name.name, &own_members, local_params.items, blk, nm);
        }
        try init_blocks.put(c.name.name, fids);
        const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
        if (!std.mem.eql(u8, cfqn, c.name.name)) try init_blocks.put(cfqn, fids);
    }

    // Per-class delegation expressions.
    var class_delegates = if (seed) |*s| s.class_delegates else std.StringHashMap([]StrFunc).init(a);
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        if (c.supertype_delegates.len == 0) continue;
        var param_refs: std.ArrayList([]const u8) = .empty;
        defer param_refs.deinit(a);
        for (c.primary_params) |*p| try param_refs.append(a, p.name.name);
        var entries: std.ArrayList(StrFunc) = .empty;
        const cd_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
        const prev_cd_pkg = ir.lower.decl.setLowerSelfPackage(cd_pkg);
        defer _ = ir.lower.decl.setLowerSelfPackage(prev_cd_pkg);
        for (c.supertype_delegates, 0..) |delegate_opt, sup_idx| {
            if (delegate_opt) |delegate_expr| {
                const sup_name = if (sup_idx < c.supertypes.len) c.supertypes[sup_idx].name.name else "";
                const nm = try std.fmt.allocPrint(a, "__class_delegate_{s}_{d}", .{ c.name.name, sup_idx });
                // The delegate expression is written in the CLASS's scope: a
                // nested class's `by StaticHolder.shared` names a sibling
                // nested object that only the enclosing-class walk resolves.
                const fid = try ir.lower.lowerExprAsParamThunkScoped(module, param_refs.items, &delegate_expr, nm, c.name.name, null);
                try entries.append(a, .{ .name = sup_name, .func = fid });
            }
        }
        if (entries.items.len != 0) {
            const owned = try entries.toOwnedSlice(a);
            try class_delegates.put(c.name.name, owned);
            const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
            if (!std.mem.eql(u8, cfqn, c.name.name)) try class_delegates.put(cfqn, owned);
        } else {
            entries.deinit(a);
        }
    }

    // Per-class secondary-ctor lowering.
    var secondary_ctors = if (seed) |*s| s.secondary_ctors else std.StringHashMap([]SecondaryCtorEntry).init(a);
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        if (c.secondary_ctors.len == 0) continue;
        const sc_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
        const prev_sc_pkg = ir.lower.decl.setLowerSelfPackage(sc_pkg);
        defer _ = ir.lower.decl.setLowerSelfPackage(prev_sc_pkg);
        var own_members = StringSet.init(a);
        defer own_members.deinit();
        for (c.primary_params) |*p| {
            if (p.property != null) try own_members.put(p.name.name, {});
        }
        for (c.members) |*m| {
            switch (m.*) {
                .Property => |p| try own_members.put(p.name.name, {}),
                .Function => |*f| try own_members.put(f.name.name, {}),
                .Class => |*inner| if (inner.is_companion) {
                    try own_members.put(inner.name.name, {});
                    for (inner.members) |*cm| {
                        switch (cm.*) {
                            .Function => |*f| try own_members.put(f.name.name, {}),
                            .Property => |p| try own_members.put(p.name.name, {}),
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
        // Inherited companion members: a delegation/default thunk references a
        // superclass companion's constant/function by its bare name (`MinId`
        // inside `Rgb`, from `ColorSpace.Companion`), and has no `this` to walk
        // at runtime — resolve it statically as a companion access.
        {
            var seen_sup = StringSet.init(a);
            defer seen_sup.deinit();
            for (c.supertypes) |*st| try collectHierarchyCompanionMemberNames(st.name.name, &file_classes, &own_members, &seen_sup);
        }
        // Which of those names a delegation/default thunk may CALL. Every
        // function contributes its arity mask; a name that is only ever a
        // property gets mask 0, so `: this(totalMonths(y, m), d)` next to a
        // `val totalMonths` keeps binding the top-level `totalMonths(Int, Int)`
        // instead of routing to a companion member that does not exist.
        var own_arity = std.StringHashMap(u64).init(a);
        defer own_arity.deinit();
        {
            var prop_names = StringSet.init(a);
            defer prop_names.deinit();
            for (c.primary_params) |*p| {
                if (p.property != null) try prop_names.put(p.name.name, {});
            }
            for (c.members) |*m| {
                switch (m.*) {
                    .Property => |p| try prop_names.put(p.name.name, {}),
                    .Function => |*f| try ir.lower.decl.mergeMemberArity(&own_arity, f.name.name, ir.lower.decl.funcArityMask(f)),
                    .Class => |*inner| if (inner.is_companion) {
                        for (inner.members) |*cm| {
                            if (cm.* == .Function) try ir.lower.decl.mergeMemberArity(&own_arity, cm.Function.name.name, ir.lower.decl.funcArityMask(&cm.Function));
                        }
                    },
                    else => {},
                }
            }
            var pit = prop_names.keyIterator();
            while (pit.next()) |pn| {
                if (!own_arity.contains(pn.*)) try own_arity.put(pn.*, 0);
            }
        }
        var entries = try a.alloc(SecondaryCtorEntry, c.secondary_ctors.len);
        for (c.secondary_ctors, 0..) |*sc, sc_idx| {
            var param_names = try a.alloc([]const u8, sc.params.len);
            for (sc.params, 0..) |*p, i| param_names[i] = p.name.name;
            var param_type_heads = try a.alloc([]const u8, sc.params.len);
            for (sc.params, 0..) |*p, i| {
                // A function-typed parameter's name field is empty; record
                // the arity-tagged head (`FunctionN`) so ctor overload
                // selection can prefer this slot for a lambda argument over
                // a same-arity sibling's SAM-class slot.
                param_type_heads[i] = if (p.ty.function != null)
                    try ir.lower.decl.loweredTypeName(a, &p.ty)
                else
                    simpleTypeHead(p.ty.name.name);
            }

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
            // The delegation arguments and the defaults are expressions over
            // the secondary constructor's OWN parameters, so they lower with
            // the declared types those parameters carry.
            const sc_param_types = try a.alloc(?ast.TypeRef, sc.params.len);
            for (sc.params, 0..) |*p, i| sc_param_types[i] = p.ty;
            // Named delegation arguments (`this(message = m, cause = c,
            // missingFields = f, serialName = null)`) bind the target's
            // parameters by NAME; the thunks run in the target's declared
            // order. Only a `this(...)` that fills every primary parameter
            // is reordered; anything else stays positional.
            var order = try a.alloc(usize, delegation_args.len);
            for (order, 0..) |*o, i| o.* = i;
            if (is_this and sc.delegation_arg_names.len == delegation_args.len and
                delegation_args.len == c.primary_params.len)
            reorder: {
                var placed = try a.alloc(bool, delegation_args.len);
                for (placed) |*x| x.* = false;
                var slot: usize = 0;
                for (sc.delegation_arg_names, 0..) |an, ai| {
                    const name = an orelse {
                        while (slot < placed.len and placed[slot]) slot += 1;
                        if (slot >= placed.len) break :reorder;
                        order[slot] = ai;
                        placed[slot] = true;
                        slot += 1;
                        continue;
                    };
                    var idx: ?usize = null;
                    for (c.primary_params, 0..) |*pp, pi| {
                        if (std.mem.eql(u8, pp.name.name, name)) {
                            idx = pi;
                            break;
                        }
                    }
                    const pi = idx orelse break :reorder;
                    if (placed[pi]) break :reorder;
                    order[pi] = ai;
                    placed[pi] = true;
                }
                for (placed) |x| if (!x) break :reorder;
            }
            var arg_fids = try a.alloc(FuncId, delegation_args.len);
            for (order, 0..) |src_idx, arg_idx| {
                const e = &delegation_args[src_idx];
                const nm = try std.fmt.allocPrint(a, "__sec_ctor_{s}_{d}_arg{d}", .{ c.name.name, sc_idx, arg_idx });
                module.pending_param_types = sc_param_types;
                module.pending_own_member_arity = &own_arity;
                arg_fids[arg_idx] = try ir.lower.lowerExprAsParamThunkScoped(module, param_names, e, nm, c.name.name, &own_members);
            }
            var default_arg_thunks = try a.alloc(?FuncId, sc.params.len);
            for (sc.params, 0..) |*p, p_idx| {
                if (p.default) |e| {
                    const nm = try std.fmt.allocPrint(a, "__sec_ctor_{s}_{d}_def{d}", .{ c.name.name, sc_idx, p_idx });
                    module.pending_param_types = sc_param_types;
                    module.pending_own_member_arity = &own_arity;
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
                module.pending_own_member_arity = null;
                const nm = try std.fmt.allocPrint(a, "__sec_ctor_body_{s}_{d}", .{ c.name.name, sc_idx });
                const body_types = try a.alloc(?ast.TypeRef, locals.items.len);
                body_types[0] = null;
                for (sc.params, 0..) |*p, i| {
                    if (i + 1 < body_types.len) body_types[i + 1] = p.ty;
                }
                module.pending_param_types = body_types;
                body_fid = try ir.lower.lowerAccessorBlock(module, c.name.name, &own_members, locals.items, blk, nm);
            }
            entries[sc_idx] = .{
                .param_count = sc.params.len,
                .param_names = param_names,
                .param_type_heads = param_type_heads,
                .is_super = is_super,
                .is_this = is_this,
                .delegation_arg_thunks = arg_fids,
                .default_arg_thunks = default_arg_thunks,
                .body = body_fid,
                .low_priority = ir.lower.decl.annotationsAreLowPriority(sc.annotations),
            };
        }
        try secondary_ctors.put(c.name.name, entries);
        const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
        if (!std.mem.eql(u8, cfqn, c.name.name)) try secondary_ctors.put(cfqn, entries);
    }

    // Top-level property initialisers — const first, then the rest.
    var top_level_props: std.ArrayList(NameFunc) = if (seed) |*s| s.top_level_props else .empty;
    var top_level_delegated_props = if (seed) |*s| s.top_level_delegated_props else std.StringHashMap(void).init(a);
    for (decls) |*d| {
        if (d.* != .Property) continue;
        const p = d.Property;
        if (p.receiver_type != null or !p.is_const) continue;
        const tp_pkg = try declPackage(a, decl_pkg, func_fqn_overrides, p.span, package_prefix, p.name.name);
        const prev_tp_pkg = ir.lower.decl.setLowerSelfPackage(tp_pkg);
        defer _ = ir.lower.decl.setLowerSelfPackage(prev_tp_pkg);
        if (p.init) |*init| {
            const nm = try std.fmt.allocPrint(a, "__top_prop_init_{s}", .{p.name.name});
            const fid = try ir.lower.lowerExprAsThunkTyped(module, init, nm, p.ty);
            try top_level_props.append(a, .{ .name = p.name.name, .func = fid, .file = p.span.file.int() });
        }
    }
    for (decls) |*d| {
        if (d.* != .Property) continue;
        const p = d.Property;
        if (p.receiver_type != null or p.is_const) continue;
        const tp_pkg = try declPackage(a, decl_pkg, func_fqn_overrides, p.span, package_prefix, p.name.name);
        const prev_tp_pkg = ir.lower.decl.setLowerSelfPackage(tp_pkg);
        defer _ = ir.lower.decl.setLowerSelfPackage(prev_tp_pkg);
        const storage_init: ?*const ast.Expr = if (p.init) |*init|
            init
        else if (p.explicit_field) |ef|
            (if (ef.init) |*finit| finit else null)
        else
            null;
        // A custom accessor next to real storage moves the storage binding
        // to the raw `__klio_topfield__<name>` key: a plain-name read then
        // misses and re-runs the getter, and a plain-name write dispatches
        // the setter; the accessor bodies' `field` reads/writes target the
        // raw key directly.
        const accessorized = p.setter != null or (p.getter != null and storage_init != null);
        const storage_name = if (accessorized)
            try std.fmt.allocPrint(a, "__klio_topfield__{s}", .{p.name.name})
        else
            p.name.name;
        if (storage_init) |init| {
            const nm = try std.fmt.allocPrint(a, "__top_prop_init_{s}", .{p.name.name});
            const fid = try ir.lower.lowerExprAsThunkTyped(module, init, nm, p.ty);
            // Annotated: default from the declared type. Unannotated: infer
            // from a trivially-typed literal initializer so a forward read
            // observes the typed field default (matching kotlinc) instead of
            // driving the initializer out of order; non-literal unannotated
            // initializers keep the on-demand path (`.none`).
            const dflt = if (p.ty) |*t| typedDefaultFor(t) else typedDefaultForInit(init);
            try top_level_props.append(a, .{ .name = storage_name, .func = fid, .default = dflt, .file = p.span.file.int() });
        } else if (p.delegate) |delegate| {
            try top_level_delegated_props.put(p.name.name, {});
            const nm = try std.fmt.allocPrint(a, "__top_prop_delegate_{s}", .{p.name.name});
            const fid = try ir.lower.lowerExprAsThunk(module, delegate, nm);
            try top_level_props.append(a, .{ .name = p.name.name, .func = fid, .file = p.span.file.int() });
        }
        if (p.delegate == null) {
            if (p.context_params.len != 0) module.has_context_decls = true;
            if (p.getter) |getter| {
                // With storage, the getter re-runs on each plain-name read
                // (the miss path) and its `field` reads the raw key; without
                // storage it is the field-less computed-property form.
                if (p.context_params.len != 0)
                    module.pending_ctx = .{ .params = p.context_params, .type_params = &.{} };
                const nm = try std.fmt.allocPrint(a, "__top_prop_get_{s}", .{p.name.name});
                const fid = switch (getter.body) {
                    .Expr => |body| blk: {
                        const rewritten = try lift.substituteFieldWithGlobal(a, p.name.name, &body);
                        break :blk try ir.lower.lowerExprAsThunk(module, rewritten, nm);
                    },
                    .Block => |blk_body| blk: {
                        var wrapped = ast.Expr{ .Block = blk_body };
                        const rewritten = try lift.substituteFieldWithGlobal(a, p.name.name, &wrapped);
                        break :blk try ir.lower.lowerBlockAsThunk(module, &rewritten.Block, nm);
                    },
                };
                try module.registry.top_level_prop_getters.put(p.name.name, fid);
            }
            if (p.setter) |setter| {
                const value_param = if (setter.params.len != 0) setter.params[0].name else "value";
                if (p.context_params.len != 0)
                    module.pending_ctx = .{ .params = p.context_params, .type_params = &.{} };
                const nm = try std.fmt.allocPrint(a, "__top_prop_set_{s}", .{p.name.name});
                const fid = switch (setter.body) {
                    .Expr => |body| blk: {
                        const rewritten = try lift.substituteFieldWithGlobal(a, p.name.name, &body);
                        break :blk try ir.lower.lowerExprAsParamThunk(module, &.{value_param}, rewritten, nm);
                    },
                    .Block => |blk_body| blk: {
                        var wrapped = ast.Expr{ .Block = blk_body };
                        const rewritten = try lift.substituteFieldWithGlobal(a, p.name.name, &wrapped);
                        break :blk try ir.lower.lowerBlockAsUnaryThunk(module, value_param, &rewritten.Block, nm);
                    },
                };
                try module.registry.top_level_prop_setters.put(p.name.name, fid);
            }
        }
    }

    // Top-level + companion/object extension properties.
    var extension_props = if (seed) |*s| s.extension_props else PairFuncMap.init(a);
    var owner_keyed_ext_names = if (seed) |*s| s.owner_keyed_ext_names else std.StringHashMap(void).init(a);
    var nullable_ext_props = if (seed) |*s| s.nullable_ext_props else std.StringHashMap(?FuncId).init(a);
    var extension_prop_setters = if (seed) |*s| s.extension_prop_setters else PairFuncMap.init(a);
    var extension_prop_delegates = if (seed) |*s| s.extension_prop_delegates else PairFuncMap.init(a);
    const ExtPropDecl = struct { p: *const ast.Property, owner: ?[]const u8, owner_type_params: []const ast.TypeParam = &.{} };
    var ext_prop_decls: std.ArrayList(ExtPropDecl) = .empty;
    defer ext_prop_decls.deinit(a);
    for (decls) |*d| {
        switch (d.*) {
            .Property => |p| if (p.receiver_type != null) try ext_prop_decls.append(a, .{ .p = p, .owner = null }),
            .Class => |*c| {
                const owner_fqn = try resolveFqn(
                    a,
                    fqn_overrides,
                    c.span,
                    package_prefix,
                    c.name.name,
                );
                for (c.members) |*m| {
                    if (m.* == .Property and m.Property.receiver_type != null) {
                        try ext_prop_decls.append(a, .{
                            .p = m.Property,
                            .owner = owner_fqn,
                            .owner_type_params = c.type_params,
                        });
                    }
                }
            },
            .Object => |*o| {
                const owner_fqn = try resolveFqn(
                    a,
                    fqn_overrides,
                    o.span,
                    package_prefix,
                    o.name.name,
                );
                for (o.members) |*m| {
                    if (m.* == .Property and m.Property.receiver_type != null) {
                        try ext_prop_decls.append(a, .{
                            .p = m.Property,
                            .owner = owner_fqn,
                        });
                    }
                }
            },
            else => {},
        }
    }
    // Class-typed typealiases (`typealias Point = FloatFloatPair`). The shared
    // `type_aliases` map records only function-typed aliases (for arity), so
    // collect the class ones here to expand an extension receiver named by an
    // alias to its underlying class — otherwise a `val Point.x` extension is
    // keyed on `Point` and never dispatches on a `FloatFloatPair` value.
    var class_aliases = std.StringHashMap([]const u8).init(a);
    defer class_aliases.deinit();
    for (decls) |*d| {
        if (d.* != .TypeAlias) continue;
        const ta = &d.TypeAlias;
        if (ta.target.function != null) continue;
        try class_aliases.put(ta.name.name, ta.target.name.name);
    }
    for (ext_prop_decls.items) |epd| {
        const p = epd.p;
        const recv = p.receiver_type orelse continue;
        // Expand a typealias receiver (`typealias Point = FloatFloatPair`; then
        // `val Point.x`) to the underlying type so the extension keys and
        // dispatches on the concrete class, not the alias name — a member
        // access on a `FloatFloatPair` value otherwise never finds `.x`.
        var recv_name = recv.name.name;
        {
            var hops: usize = 0;
            while (class_aliases.get(recv_name)) |t| : (hops += 1) {
                if (hops > 8 or std.mem.eql(u8, t, recv_name)) break;
                recv_name = t;
            }
        }
        // A member-extension property on the enclosing class's TYPE PARAMETER
        // (`class LazyLayoutItemAnimator<T : LazyLayoutMeasuredItem> { private
        // val T.hasAnimations }`) keys on the parameter's UPPER BOUND — every
        // receiver it can dispatch on is a subtype of the bound, and the
        // lookup walks the receiver's supertype chain by simple name.
        for (epd.owner_type_params) |*tp| {
            if (!std.mem.eql(u8, tp.name.name, recv_name)) continue;
            recv_name = if (tp.upper_bound) |ub| ub.name.name else "Any";
            break;
        }
        // A `val X.Companion.foo` records `qualified_path = "X.Companion"`; key
        // it under that path so it never collides with a plain `val X.foo` type
        // extension (which applies to instances of `X`, not its companion).
        const recv_key: []const u8 = if (recv.qualified_path) |qp|
            (if (std.mem.endsWith(u8, qp, ".Companion")) qp else recv_name)
        else
            recv_name;
        const ep_pkg = try declPackage(a, decl_pkg, func_fqn_overrides, p.span, package_prefix, p.name.name);

        const prev_ep_pkg = ir.lower.decl.setLowerSelfPackage(ep_pkg);
        defer _ = ir.lower.decl.setLowerSelfPackage(prev_ep_pkg);
        if (p.getter) |getter| {
            var empty_members = StringSet.init(a);
            defer empty_members.deinit();
            const nm = try std.fmt.allocPrint(a, "__ext_get_{s}_{s}", .{ recv_name, p.name.name });
            const fid = switch (getter.body) {
                .Expr => |body| try ir.lower.lowerAccessorExprWithExpected(module, recv_name, &empty_members, &.{"this"}, &body, nm, p.ty),
                .Block => |blk| try ir.lower.lowerAccessorBlockRet(module, recv_name, &empty_members, &.{"this"}, &blk, nm, p.ty),
            };
            if (runtime.envOnce("KLIO_MISS_TRACE")) |w| {
                if (std.mem.eql(u8, w, p.name.name))
                    std.debug.print("[extprop-reg] key=({s},{s}) fid={d} owner={s}\n", .{ recv_key, p.name.name, fid.int(), epd.owner orelse "<top>" });
            }
            // A PRIVATE member-extension property is visible only where its
            // owner class is a dispatch receiver, so it registers ONLY under
            // the owner-qualified key — the plain pair would resolve it
            // program-wide (`private val String.decorated` in one class
            // served a bystander's `s.decorated`, which kotlinc rejects).
            // The owner-keyed resolvers cover the legal scopes: the lexical
            // receiver tower and the importing file (companion members).
            // A NON-private member extension keeps the plain pair as well:
            // kotlinc scopes those to the tower too, but the interpreter's
            // tower emulation does not yet see every legal frame (lambda and
            // inline splices inside the owner) — gating them cost the
            // compose suite ~400 tests. Tightening that is recorded work.
            if (epd.owner) |owner| {
                const okey = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ owner, recv_key });
                try extension_props.put(.{ .a = okey, .b = p.name.name }, fid);
                // The receiver-tower probe reaches an owner through a frame
                // class's supertype_names, which are SOURCE-WRITTEN simple
                // names — an fqn-keyed entry alone is unreachable through an
                // implemented interface (PersistentCompositionLocalMap's
                // `CompositionLocal<T>.currentValue`). Key the classifier
                // path without its package as an alias.
                if (ownerSimplePath(owner)) |short| {
                    const skey = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ short, recv_key });
                    try extension_props.put(.{ .a = skey, .b = p.name.name }, fid);
                }
                try owner_keyed_ext_names.put(p.name.name, {});
                // kotlinc-exact scoping: a member extension — private or
                // not — is visible only where its owner is a receiver (the
                // tower) or via import, never program-wide, so NO plain
                // (recv, name) pair. The legal scopes resolve through the
                // owner-keyed entries: the receiver tower (fqn and
                // simple-owner keys) and the importing file.
            } else {
                try extension_props.put(.{ .a = recv_key, .b = p.name.name }, fid);
            }
            if (recv.nullable) {
                const gop2 = try nullable_ext_props.getOrPut(p.name.name);
                if (gop2.found_existing) {
                    if (gop2.value_ptr.*) |prev| {
                        if (prev != fid) gop2.value_ptr.* = null;
                    }
                } else {
                    gop2.value_ptr.* = fid;
                }
                // A second, package-qualified key: same-name nullable
                // extension properties in different packages (an internal
                // `RowColumnParentData?.weight` and an internal
                // `ButtonGroupParentData?.weight`) blank the bare-name
                // entry, but the reading code sits in the declaring
                // package, so the executing frame's package still
                // disambiguates at the null-receiver dispatch.
                const pkg_key = try std.fmt.allocPrint(a, "{s}\x1f{s}", .{ ep_pkg, p.name.name });
                const gop3 = try nullable_ext_props.getOrPut(pkg_key);
                if (gop3.found_existing) {
                    if (gop3.value_ptr.*) |prev| {
                        if (prev != fid) gop3.value_ptr.* = null;
                    }
                } else {
                    gop3.value_ptr.* = fid;
                }
            }
            // A member-extension property's accessor body has its
            // declaring class's `this` in lexical scope; tag the owner so
            // dispatch seeds the accessor frame with the owner instance.
            if (epd.owner) |owner| {
                try module.registry.member_ext_owner_class.put(fid, owner);
            }
        }
        if (p.delegate) |delegate| {
            // `val R.x by expr`: no accessor bodies — the delegate object
            // (produced once by this thunk, cached per property) serves
            // reads and writes through its getValue/setValue.
            const nm = try std.fmt.allocPrint(a, "__ext_prop_delegate_{s}_{s}", .{ recv_name, p.name.name });
            const fid = try ir.lower.lowerExprAsThunk(module, delegate, nm);
            try extension_prop_delegates.put(.{ .a = recv_key, .b = p.name.name }, fid);
        }
        if (p.setter) |setter| {
            const setter_param_name = if (setter.params.len != 0) setter.params[0].name else "value";
            var recv_members = StringSet.init(a);
            defer recv_members.deinit();
            if (classes.get(recv_name)) |rdef| {
                const rg = rdef.borrow();
                for (rg.get().primary_params) |*pp| try recv_members.put(pp.name, {});
                for (rg.get().body_properties) |*pp| try recv_members.put(pp.name, {});
                rg.deinit();
            }
            // A `var X.Companion.x` setter's bare-name writes target the
            // companion's own members; fold them in so they lower as `this`
            // field writes rather than top-level bindings.
            if (companion_singletons.get(recv_name)) |comp_name| {
                if (classes.get(comp_name)) |cdef| {
                    const cgm = cdef.borrow();
                    for (cgm.get().primary_params) |*pp| try recv_members.put(pp.name, {});
                    for (cgm.get().body_properties) |*pp| try recv_members.put(pp.name, {});
                    cgm.deinit();
                }
            }
            const nm = try std.fmt.allocPrint(a, "__ext_set_{s}_{s}", .{ recv_name, p.name.name });
            const fid = switch (setter.body) {
                .Expr => |body| try ir.lower.lowerAccessorExpr(module, recv_name, &recv_members, &.{ "this", setter_param_name }, &body, nm),
                .Block => |blk| try ir.lower.lowerAccessorBlock(module, recv_name, &recv_members, &.{ "this", setter_param_name }, &blk, nm),
            };
            // Same private-only gating as the getter above.
            if (epd.owner) |owner| {
                const okey = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ owner, recv_key });
                try extension_prop_setters.put(.{ .a = okey, .b = p.name.name }, fid);
                // Same simple-owner alias as the getter above.
                if (ownerSimplePath(owner)) |short| {
                    const skey = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ short, recv_key });
                    try extension_prop_setters.put(.{ .a = skey, .b = p.name.name }, fid);
                }
                try owner_keyed_ext_names.put(p.name.name, {});
                try module.registry.member_ext_owner_class.put(fid, owner);
                // Same kotlinc-exact scoping as the getter: owner-keyed
                // only, no program-wide plain pair.
            } else {
                try extension_prop_setters.put(.{ .a = recv_key, .b = p.name.name }, fid);
            }
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

    // typealias Name = Target → Name ↦ Target's simple head name. A
    // function-type target (`typealias CompletionHandler = (Throwable?) ->
    // Unit`) maps to its `Function{N}` tag so applicability checks
    // recognise an aliased parameter as function-typed.
    for (decls) |*d| {
        if (d.* != .TypeAlias) continue;
        const ta = &d.TypeAlias;
        if (ta.target.function) |ft| {
            // Match the direct function-type lowering (`loweredTypeRef`),
            // which tags by the VALUE-parameter count and tracks the
            // receiver separately: a `T.() -> R` alias is `Function0`, not
            // `Function1`. Counting the receiver here made an aliased
            // receiver-lambda parameter (`RoutingHandler = RoutingContext.()
            // -> Unit`) look like arity 1, so the trailing lambda kept a
            // spurious `it` and its receiver never bound on invocation.
            const arity = ft.params.len;
            const tag = try std.fmt.allocPrint(a, "Function{d}", .{arity});
            try module.registry.type_aliases.put(ta.name.name, tag);
            if (ft.receiver != null) {
                try module.registry.recv_fn_aliases.put(ta.name.name, @intCast(@min(arity, 255)));
            }
            continue;
        }
        const full = ta.target.name.name;
        const target = if (std.mem.lastIndexOfScalar(u8, full, '.')) |dot| full[dot + 1 ..] else full;
        if (target.len != 0 and !std.mem.eql(u8, target, ta.name.name)) {
            try module.registry.type_aliases.put(ta.name.name, target);
        }
    }
    // Rewrite function-type alias names in lowered param types so every
    // applicability/score consumer sees the `Function{N}` tag — a param
    // declared `handler: CompletionHandler` is function-typed for
    // trailing-lambda alignment and overload scoring. In an extending build
    // only this build's funcs rewrite: base params were settled at base
    // build time, and their slices are shared with the immutable base (a
    // user alias that WOULD match a base param type name is screened out by
    // `canExtendBase`, which falls back to the whole-program build).
    for (module.funcs.items[base_funcs_len..]) |*f| {
        for (f.params) |*p| {
            const resolved = module.registry.type_aliases.get(p.ty.name) orelse continue;
            // A function-typed alias becomes its `Function{N}` tag (trailing-lambda
            // alignment); a SCALAR alias (`typealias SnapshotId = Long`) becomes its
            // primitive target so overload applicability matches a scalar argument
            // against it (a `Long` arg fits a `SnapshotId` param, since the alias is
            // transparent). Without this the strict multi-candidate scorer sees an
            // opaque `SnapshotId` param and rejects the Long, so a class with two
            // same-named overloads (one taking the alias) resolves to none.
            if (std.mem.startsWith(u8, resolved, "Function")) {
                p.ty.name = resolved;
            } else if (@import("vm/overload_match.zig").builtinParamKind(resolved) != null) {
                p.ty.name = resolved;
            }
        }
    }

    // Materialise the module-scoped registry the Vm reads at dispatch time.
    // Object names, companion singletons, enclosing-class, func type params,
    // delegated props (the lowering-only registry fields stay in place).
    // Seeded base object names are already in the cloned registry; append
    // only this build's.
    for (object_names.items[base_object_names_len..]) |n| try module.registry.object_names.append(a, n);
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
            const fid = FuncId.from(e.key_ptr.*);
            // Header-time registration (the phase-1 stub loop) already put
            // this build's entries; only seed-carried ones land here.
            if (module.registry.func_type_params.contains(fid)) continue;
            var list: std.ArrayList([]const u8) = .empty;
            try list.appendSlice(a, e.value_ptr.*);
            try module.registry.func_type_params.put(fid, list);
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

    // Settle virtual override families after every class/member header is
    // complete. Runtime member dispatch can then use only class + slot ids.
    try module.linkMethodSlots(a);

    // Debug-only frame-dump hook for intrinsics below the ir layer.
    ir.eval.installDebugFrameDump();

    return .{
        .module = module_ref,
        .classes = classes,
        .body_prop_inits = body_prop_inits,
        .instance_prop_getters = instance_prop_getters,
        .getter_prop_names = getter_prop_names,
        .instance_prop_private = instance_prop_private,
        .instance_prop_setters = instance_prop_setters,
        .parent_ctor_args = parent_ctor_args,
        .parent_ctor_arg_names = parent_ctor_arg_names,
        .init_blocks = init_blocks,
        .top_level_props = top_level_props,
        .extension_props = extension_props,
        .owner_keyed_ext_names = owner_keyed_ext_names,
        .nullable_ext_props = nullable_ext_props,
        .extension_prop_delegates = extension_prop_delegates,
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

/// Register each property AST in `members` under its owner class/object,
/// recursing into nested types, so reified-type-argument inference can
/// resolve a property-access argument's generic type.
fn registerMemberPropAsts(a: Allocator, members: []const Decl, owner: []const u8) void {
    for (members) |*m| {
        switch (m.*) {
            .Property => |p| {
                ir.lower.registerMemberPropAst(a, owner, p);
                // A member-EXTENSION property (`private val Composition.parent`)
                // is recorded under a dedicated key so a same-named plain member
                // of the same class does not hide it: a read whose static
                // receiver type matches the extension receiver resolves to the
                // extension getter, not an accidental runtime stored field.
                if (p.receiver_type) |rt| {
                    ir.lower.registerMemberExtPropRecv(a, owner, p.name.name, rt.name.name);
                }
            },
            .Class => |*c| registerMemberPropAsts(a, c.members, c.name.name),
            .Object => |*o| registerMemberPropAsts(a, o.members, o.name.name),
            else => {},
        }
    }
}

/// Register the declared supertypes of every class/object in `decls`,
/// recursing into nested types, so reified-type-argument inference can read
/// an argument declaration's own type arguments.
fn registerClassSupertypes(members: []const Decl) void {
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

/// Register each inline member fn in `members` as owned by class `owner`,
/// recursing into nested classes/objects (whose members belong to the nested
/// type). Mirrors `collectInline`'s recursion so the owner map covers exactly
/// the member inline fns the candidate table holds.
fn registerInlineMemberOwners(members: []const Decl, owner: []const u8) void {
    for (members) |*m| {
        switch (m.*) {
            .Function => |*f| {
                if (f.is_inline and f.body != null) {
                    ir.lower.registerInlineMemberOwner(f, owner);
                }
                // Un-annotated expression bodies register for on-demand
                // return derivation: a caller lowered before this member's
                // own pass still types its locals from the inferred return.
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

fn collectCompanionOwnMembers(c: *const ast.Class, own: *StringSet) Allocator.Error!void {
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

/// Resolve the `@Target` entry names of the annotation class `leaf` from
/// the build's class universe (user files plus base/pack classes). `null`
/// when the class is unknown or declares no `@Target` — both admit the
/// default use-site set.
fn annotationTargetEntries(
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

/// Whether these annotations include `@Serializer(forClass = …)`.
fn serializerForClassAnnotated(annotations: []const ast.Annotation) bool {
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

/// Lower one source annotation entry to a runtime record: resolved FQN
/// candidates plus resolved constructor arguments.
fn annotationRecordFor(
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
            // `Foo::class` names the declaration the annotation is about
            // (`@Serializer(forClass = Foo::class)`), not a value.
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

/// Assign every annotation entry of one property declaration to its final
/// anchors (`@all:` expansion, explicit use-site, or the LV 2.4 defaulting
/// rule) and collect the per-anchor records.
fn buildPropertyAnchors(
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

/// Backing-field presence for a body property, as target assignment sees
/// it: an initializer, an explicit `field` clause, or any defaulted
/// accessor supplies one; delegated / abstract properties and properties
/// with only custom accessor bodies have none.
/// Type head of an unannotated property whose initializer is a literal —
/// the shapes where inference is unambiguous. Null for anything else.
fn inferredPropTypeHead(p: *const ast.Property) ?[]const u8 {
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

fn memberHasBackingField(p: *const ast.Property) bool {
    if (p.delegate != null or p.is_abstract or p.is_expect or p.receiver_type != null) return false;
    if (p.init != null or p.explicit_field != null) return true;
    if (p.getter == null) return true;
    if (p.mutable and p.setter == null) return true;
    if (p.getter) |g| if (ast.accessorUsesField(g)) return true;
    if (p.setter) |s| if (ast.accessorUsesField(s)) return true;
    return false;
}

fn spanNamesObject(object_spans: []const Span, target: Span) bool {
    for (object_spans) |s| {
        if (std.meta.eql(s, target)) return true;
    }
    return false;
}

/// See the nested-class-table comment at the link site.
fn fillNestedClassTables(a: Allocator, decls_in: []const Decl, classes: *const std.StringHashMap(ObjRef(ClassDef)), outer_fqn: []const u8) Allocator.Error!void {
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

fn buildClassDef(
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
        // A MEMBER-EXTENSION property belongs to the extension surface,
        // never to the class's own property set (see the accessor
        // registration loop's matching skip).
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
        });
    }

    // Matched by declaration span, never by simple name: a same-named
    // `object` from another package must not mark this class an object.
    const is_object = spanNamesObject(object_spans.items, c.span);

    // init-block property positions: count `Property` decls in members[0..pos].
    var init_block_positions = try a.alloc(usize, c.init_block_positions.len);
    for (c.init_block_positions, 0..) |pos, i| {
        const upto = @min(pos, c.members.len);
        var count: usize = 0;
        for (c.members[0..upto]) |*m| {
            // Mirror the body_props collection: member-extension properties
            // are not body properties, so they do not shift init positions.
            if (m.* == .Property and m.Property.receiver_type == null) count += 1;
        }
        init_block_positions[i] = count;
    }

    var init_blocks_ast = try a.alloc(FF(ast.Block), c.init_blocks.len);
    for (c.init_blocks, 0..) |*blk, i| init_blocks_ast[i] = FF(ast.Block).fromPtr(blk);

    var secondary = try a.alloc(FF(ast.SecondaryCtor), c.secondary_ctors.len);
    for (c.secondary_ctors, 0..) |*sc, i| secondary[i] = FF(ast.SecondaryCtor).fromPtr(sc);

    // `@Serializer(forClass = C::class)` is written on a declaration with no
    // supertype at all; the kotlinx plugin makes it a `KSerializer<C>`. That
    // supertype is what `is KSerializer` and `as KSerializer` read, and what
    // a serializer lookup casts its answer to.
    const serializer_supertype = c.supertypes.len == 0 and serializerForClassAnnotated(c.annotations);
    // An annotation class implicitly implements `kotlin.Annotation`: an
    // instance passes an `Annotation`-typed parameter and `is Annotation`.
    const annotation_supertype = c.is_annotation;
    const extra: usize = @as(usize, @intFromBool(serializer_supertype)) + @as(usize, @intFromBool(annotation_supertype));
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
        }
    }
    for (c.supertypes, 0..) |*t, i| {
        // A supertype naming a renamed file-private class resolves to the
        // mangled lift name; the rename is keyed by the reference's own
        // span file, matching the file scope of the declaration.
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
        .supertype_paths = supertype_paths,
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
/// pass.
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
            // Intrinsic-backed declarations are RETAINED (the no-holes
            // symbol table): the declaration lowers like any other source
            // and `linkResolvedForms` binds its executable form to the
            // host implementation (`resolved_native`), so resolution sees
            // one complete declaration table and never needs to know the
            // body is native.
            if (!f.is_expect) return true;
            const fqn = try resolveFqn(a, func_fqn_overrides, f.span, package_prefix, f.name.name);
            // Superseded only by an `actual` in its OWN package (see the set's
            // construction): a same-named actual elsewhere implements a
            // different declaration.
            if (actual_func_names.contains(fqn)) return false;
            const receiver_name: ?[]const u8 = if (f.receiver_type) |*rt|
                rt.qualified_path orelse rt.name.name
            else
                null;
            // A declaration with an exact host ABI symbol survives with its
            // ordinary FuncId identity, including receiver-formed expects.
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

fn sameExpectActualTypeHead(a: *const ast.TypeRef, b: *const ast.TypeRef) bool {
    if (!std.mem.eql(u8, a.name.name, b.name.name) or a.nullable != b.nullable) return false;
    if ((a.function == null) != (b.function == null)) return false;
    if (a.function) |af| {
        const bf = b.function.?;
        if (af.params.len != bf.params.len or af.is_suspend != bf.is_suspend) return false;
        if ((af.receiver == null) != (bf.receiver == null)) return false;
    }
    return true;
}

/// Copy defaults from an expect-class member to its matching actual member.
/// Returns true when the declarations have the same callable signature.
fn transplantExpectMemberDefaults(actual: *ast.Function, expected: *const ast.Function) bool {
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

// -------------------------------------------------------------------------
// Once-per-process dependency base: the stdlib (+ pack) files are lowered
// one time into an immutable snapshot; each program then extends an
// arena-backed clone with just its own declarations. The snapshot's
// BuiltModule is NEVER run — every runtime-mutable structure (the Vm's
// ClassDefs, enum-entry instances, companion/object cells) is deep-cloned
// per program, so nothing a run mutates is shared across programs.
// -------------------------------------------------------------------------

/// Immutable lowered snapshot of a program's dependency files. Owned by a
/// process-lifetime arena managed by the caller; safe to read from many
/// threads once built.
pub const StdlibBase = struct {
    /// The lowered dependency program. Cloned (never consumed) per run.
    built: BuiltModule,
    /// Post-lift, post-retain dependency decls: the context universe the
    /// extending build scans (file_classes, inline fns, top-level prop
    /// names) without re-lowering.
    lifted_decls: []const Decl,
    /// Every top-level simple name the base declares (functions,
    /// properties, classes, objects, typealiases — raw and post-lift).
    /// A user program redeclaring any of these falls back to the full
    /// whole-program build, because cross-boundary renames/mangles and
    /// resolution could differ from the snapshot's.
    decl_names: StringSet,
    /// The subset of `decl_names` declared in the ROOT package (files with
    /// no package header) plus every lifted/mangled decl. Only these can
    /// collide with a root-package user declaration under Kotlin scoping —
    /// a named-package base decl is invisible to bare references in other
    /// packages, so a user namesake cannot change any decision the base
    /// build settled and the extend gate lets it through.
    root_decl_names: StringSet,
    /// Packages the base files declare; a user file sharing one falls back
    /// (pack-private object aliasing scans sibling types per package).
    packages: StringSet,
    /// Every lowered base Func param type name. A user function-type
    /// typealias matching one would rewrite base param types in the
    /// whole-program build; the extend build falls back instead.
    param_type_names: StringSet,
    /// Top-level type simple names (post-lift), seeded into the extending
    /// build's nested-mangle collision universe.
    type_names: StringSet,
    /// (FuncId, AST) pairs replayed into the per-build inline-fn registry
    /// so user calls resolving to base inline fns still splice.
    inline_ids: []const InlineId,
    /// Simple-name -> base inline-fn forest refs (overloads in declaration
    /// order), the lazy replacement for walking `lifted_decls` with
    /// `collectInline` at load. Empty for a freshly-built base (which walks its
    /// own decls); populated only when loaded from an image. Includes class /
    /// object member inline fns, which carry no `inline_ids` stub.
    inline_by_name: []const InlineNames = &.{},
    /// Class simple-name -> base class forest ref, the lazy replacement for
    /// walking `lifted_decls` to seed `file_classes` at load. Empty for a
    /// freshly-built base. Used for hierarchy walks when a USER class reaches
    /// into a base class.
    file_classes: []const ClassRef = &.{},
    /// Base top-level (file-scope) property scope data — the lazy replacement for
    /// re-running `notePropScope` over `lifted_decls` at load. Empty for a
    /// freshly-built base. Strings only (no AST).
    top_props: []const TopProp = &.{},
    /// Baked top-level function return class heads (see `FnReturn`).
    fn_returns: []const FnReturn = &.{},
    /// Baked extension return class heads (see `ExtReturn`).
    ext_returns: []const ExtReturn = &.{},
    /// Baked eager call resolutions inside the base (see `EagerCall`).
    eager_calls: []const EagerCall = &.{},
    /// Base SourceMap files occupy ids [0..user_file_start).
    user_file_start: u32,
    /// Next enum-entry identity, continuing the base build's sequence so
    /// default toString/hashCode match the whole-program numbering.
    enum_id_next: u64,
    /// Side section holding the self-contained encodings of `inline`,
    /// object-free function bodies, decoded lazily on first splice. Empty for a
    /// freshly-built base (its `lifted_decls` keep full bodies); populated only
    /// when loaded from an image, where those bodies are markers. Borrows the
    /// image buffer.
    deferred_bodies: []const u8 = &.{},
    /// Per-decl self-contained encodings of `lifted_decls` and their byte
    /// offsets (decl `i` at `lifted_decl_offsets[i]`). Borrow the image buffer.
    /// Back the lazy forest: a decl decodes on first touch from here instead of
    /// the whole forest materialising at load. Empty for a freshly-built base.
    lifted_decl_section: []const u8 = &.{},
    lifted_decl_offsets: []const u32 = &.{},
    /// The process-lifetime allocator the base (and its `lifted_decls`) live in.
    /// A lazily-decoded deferred body must persist across per-program builds, so
    /// it is decoded here, not into a per-build arena.
    arena: Allocator = undefined,

    pub const InlineId = struct { id: u32, f: FF(ast.Function) };
    /// One simple name's base inline-fn forest refs (overloads in order).
    pub const InlineNames = struct { k: []const u8, v: []const runtime.forest.ForestRef };
    /// One class simple name -> its base-class forest ref.
    pub const ClassRef = struct { k: []const u8, v: runtime.forest.ForestRef };
    /// One base top-level property's scope identity.
    pub const TopProp = struct { name: []const u8, fqn: []const u8, package: []const u8, type_head: []const u8 = "" };
    /// A top-level function's simple name paired with the class head it
    /// returns. Baked because the funcs themselves are lazy in an image:
    /// nothing else can answer "what class does `listOf` return" without
    /// decoding the whole stdlib.
    pub const FnReturn = struct { name: []const u8, head: []const u8 };
    /// An EXTENSION's return class head, keyed `<receiver head>\x00<name>`.
    /// Declaration signatures keep parameters and no return type, so without
    /// this a chained call loses its receiver class at the first link.
    pub const ExtReturn = struct { key: []const u8, head: []const u8 };
    /// A call site inside the BASE and the declaration the checker picked
    /// for it. Collected while the base's sources exist (image bake) and
    /// replayed at load, because a cached run never parses them.
    pub const EagerCall = struct { call: span.Span, fid: u32 };
};

/// Build the dependency snapshot from already-parsed base files. The
/// allocator must be the process-lifetime base arena. Returns null when the
/// base program is not snapshot-safe (it has resolve diagnostics or a
/// `main`), in which case callers must use the full per-program build.
pub fn buildStdlibBase(allocator: Allocator, files: []const KotlinFile) Allocator.Error!?*StdlibBase {
    return buildBaseInner(allocator, files, false);
}

/// Whole-program variant of `buildStdlibBase` for `klio bundle`: the same
/// lowered snapshot, but `files` includes the user program so `main` is
/// present (and serialized). Boot then runs the loaded module directly —
/// no parse, no extend.
/// The declared type of the parent class's primary parameter at `idx`,
/// instantiated by the supertype's written type arguments
/// (`JsonTransformingSerializer<String>(serializer())` expects
/// `KSerializer<String>`). Null when the parent or its parameter is unknown.
fn parentCtorParamExpected(a: Allocator, module: *ir.Module, c: *const ast.Class, sup_idx: usize, idx: usize) ?ast.TypeRef {
    if (sup_idx >= c.supertypes.len) return null;
    const sup = &c.supertypes[sup_idx];
    const file = sup.name.span.file;
    const pkg = module.packageOfFile(file) orelse "";
    const cid = (if (sup.qualified_path) |qp| module.classIdByQualifiedSuffix(qp) else null) orelse
        module.classIdIndexed(sup.name.name, pkg, file) orelse module.classId(sup.name.name) orelse return null;
    if (cid.int() >= module.classes.items.len) return null;
    const pc = &module.classes.items[cid.int()];
    if (idx >= pc.primary_params.len) return null;
    const pty = pc.primary_params[idx].ty;
    return irTypeToAstInstantiated(a, pty, pc.type_params, sup.type_args, sup.name.span) catch null;
}

fn irTypeToAstInstantiated(a: Allocator, ty: ir.TypeRef, tps: []const []const u8, written: []const ast.TypeArg, sp: ast.Span) Allocator.Error!ast.TypeRef {
    var nm = std.mem.trimEnd(u8, ty.name, "?");
    if (std.mem.startsWith(u8, nm, "in#")) nm = nm[3..];
    if (std.mem.startsWith(u8, nm, "out#")) nm = nm[4..];
    if (std.mem.indexOfScalar(u8, nm, '<')) |lt| nm = nm[0..lt];
    // The parent's own type parameter: the written argument at its position.
    for (tps, 0..) |tp, i| {
        if (std.mem.eql(u8, tp, nm) and i < written.len and !written[i].is_star) {
            var out = written[i].ty;
            out.nullable = out.nullable or ty.nullable;
            return out;
        }
    }
    const args = try a.alloc(ast.TypeArg, ty.args.len);
    for (ty.args, args) |arg, *out| {
        out.* = .{ .variance = .Invariant, .is_star = false, .ty = try irTypeToAstInstantiated(a, arg, tps, written, sp), .span = sp };
    }
    return .{
        .name = .{ .name = try a.dupe(u8, nm), .span = sp },
        .nullable = ty.nullable,
        .span = sp,
        .type_args = args,
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
}

pub fn buildProgramBase(allocator: Allocator, files: []const KotlinFile) Allocator.Error!?*StdlibBase {
    return buildBaseInner(allocator, files, true);
}

fn buildBaseInner(allocator: Allocator, files: []const KotlinFile, allow_main: bool) Allocator.Error!?*StdlibBase {
    var lifted: []Decl = &.{};
    var built = try buildModuleFilesInner(allocator, files, null, &lifted);
    {
        const mg = built.module.borrow();
        defer mg.deinit();
        const main_ok = if (allow_main) built.main != null else built.main == null;
        if (mg.get().resolve_diags.items.len != 0 or !main_ok) {
            built.deinit();
            return null;
        }
    }

    const base = try allocator.create(StdlibBase);
    base.* = .{
        .built = built,
        .lifted_decls = lifted,
        .decl_names = StringSet.init(allocator),
        .root_decl_names = StringSet.init(allocator),
        .packages = StringSet.init(allocator),
        .param_type_names = StringSet.init(allocator),
        .type_names = StringSet.init(allocator),
        .inline_ids = &.{},
        .user_file_start = 0,
        .enum_id_next = 1,
        .arena = allocator,
    };

    // Name universes for the reuse gate, over raw AND lifted decls (a
    // lifted/mangled name is a real top-level slot too).
    for (files) |*f| {
        if (f.package) |p| {
            var dotted: std.ArrayList(u8) = .empty;
            for (p.path, 0..) |id, i| {
                if (i != 0) try dotted.append(allocator, '.');
                try dotted.appendSlice(allocator, id.name);
            }
            try base.packages.put(try dotted.toOwnedSlice(allocator), {});
        }
        for (f.decls) |*d| try noteBaseDeclNames(base, d, f.package == null);
    }
    // Lifted decls: mangled names carry `$` (never a legal user identifier,
    // so never collidable), and plain-named lifts (member extensions and
    // company) originate from the named-package files noted above — their
    // bare-name visibility follows the same package scoping. They join the
    // general universe only; the root universe keeps the files-loop truth.
    for (base.lifted_decls) |*d| try noteBaseDeclNames(base, d, false);

    {
        const mg = base.built.module.borrow();
        defer mg.deinit();
        const module = mg.get();
        var inline_ids: std.ArrayList(StdlibBase.InlineId) = .empty;
        for (module.funcs.items) |*f| {
            for (f.params) |*p| try base.param_type_names.put(p.ty.name, {});
            if (f.is_inline) {
                if (ir.lower.inline_state.inlineAstById(f.id.int())) |fn_ast| {
                    try inline_ids.append(allocator, .{ .id = f.id.int(), .f = FF(ast.Function).fromPtr(fn_ast) });
                }
            }
        }
        base.inline_ids = try inline_ids.toOwnedSlice(allocator);
    }

    // Continue the enum-entry identity sequence after the base's: identities
    // were assigned 1..N in build order over the base's unique class defs.
    {
        var counted = std.AutoHashMap(usize, void).init(allocator);
        defer counted.deinit();
        var n: u64 = 0;
        var it = base.built.classes.valueIterator();
        while (it.next()) |def| {
            const gop = try counted.getOrPut(@intFromPtr(def.cell));
            if (gop.found_existing) continue;
            const g = def.borrow();
            n += g.get().enum_entries.len;
            g.deinit();
        }
        base.enum_id_next = 1 + n;
    }

    // A non-inline base function never runs from its AST body (its lowered IR
    // does); strip those bodies so the baked image and the resident forest drop
    // the dead statement trees while keeping the metadata dispatch reads.
    prune.stripDeadBodies(@constCast(base.lifted_decls), true);

    return base;
}

/// Add the simple names of every `@Composable` function in the baked base
/// (pack composables the user calls) to the plugin oracle set.
/// The base's lifted decls for the compose-plugin collectors. A freshly-built
/// base carries the full forest in `lifted_decls`; an image-loaded base leaves
/// that empty (the forest decodes lazily per-decl) and holds the per-decl
/// `lifted_decl_section`/`lifted_decl_offsets` instead. The plugin collectors
/// below need the whole base surface, so decode every section decl here — an
/// image-loaded base otherwise reports zero base composables/sinks, and a
/// composable lambda passed to a base sink (`setContent { … }`, `key(…) { … }`)
/// never gets `$composer` threaded (`startRestartGroup on Nothing`). Returns
/// `base.lifted_decls` unchanged for a fresh base (no allocation).
fn composeBaseDecls(allocator: Allocator, base: *const StdlibBase) Allocator.Error![]const Decl {
    if (base.lifted_decls.len != 0) return base.lifted_decls;
    if (base.lifted_decl_section.len == 0 or base.lifted_decl_offsets.len == 0) return &.{};
    const out = try allocator.alloc(Decl, base.lifted_decl_offsets.len);
    var n: usize = 0;
    for (base.lifted_decl_offsets) |off| {
        if (image.decodeLiftedDecl(allocator, base.lifted_decl_section, off)) |d| {
            out[n] = d;
            n += 1;
        }
    }
    return out[0..n];
}

fn composeBaseNames(names: *std.StringHashMap(void), base_decls: []const Decl) Allocator.Error!void {
    for (base_decls) |*d| try composeBaseNameDecl(names, d);
}

fn composeBaseNameDecl(names: *std.StringHashMap(void), d: *const Decl) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| if (compose_pass.isComposable(f.annotations)) try names.put(f.name.name, {}),
        .Class => |*c| for (c.members) |*m| try composeBaseNameDecl(names, m),
        .Object => |*o| for (o.members) |*m| try composeBaseNameDecl(names, m),
        else => {},
    }
}

/// Add the names of baked-base functions with a `@Composable`-typed lambda
/// parameter (composable-lambda sinks the user's composable calls pass into).
fn composeBaseSinks(sinks: *std.StringHashMap(void), base_decls: []const Decl) Allocator.Error!void {
    for (base_decls) |*d| try composeBaseSinkDecl(sinks, d);
}

fn composeBaseInlineFns(set: *std.StringHashMap(void), base_decls: []const Decl) Allocator.Error!void {
    for (base_decls) |*d| {
        try compose_pass.collectInlineFnNamesInto(set, @as([*]const Decl, @ptrCast(d))[0..1]);
    }
}

fn composeBaseComposableGetterProps(props: *std.StringHashMap(void), base_decls: []const Decl) Allocator.Error!void {
    for (base_decls) |*d| {
        try compose_pass.collectComposableGetterPropsInto(props, @as([*]const Decl, @ptrCast(d))[0..1]);
    }
}

fn composeBaseFactoryDecl(factories: *std.StringHashMap(void), d: *const Decl) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| {
            if (f.return_type) |*rt| {
                if (rt.function != null and compose_pass.isComposable(rt.annotations)) {
                    try factories.put(f.name.name, {});
                }
            }
        },
        .Class => |*c| for (c.members) |*m| try composeBaseFactoryDecl(factories, m),
        .Object => |*o| for (o.members) |*m| try composeBaseFactoryDecl(factories, m),
        else => {},
    }
}

fn composeBaseSinkDecl(sinks: *std.StringHashMap(void), d: *const Decl) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| for (f.params) |*p| {
            if (p.ty.function != null and compose_pass.isComposable(p.ty.annotations)) {
                try sinks.put(f.name.name, {});
                break;
            }
        },
        .Class => |*c| {
            // A class constructor taking a `@Composable` lambda is a sink
            // under the class name (`MovableContent({ … })`).
            for (c.primary_params) |*p| {
                if (p.ty.function != null and compose_pass.isComposable(p.ty.annotations)) {
                    try sinks.put(c.name.name, {});
                    break;
                }
            }
            for (c.members) |*m| try composeBaseSinkDecl(sinks, m);
        },
        .Object => |*o| for (o.members) |*m| try composeBaseSinkDecl(sinks, m),
        else => {},
    }
}

fn noteBaseDeclNames(base: *StdlibBase, d: *const Decl, root_pkg: bool) Allocator.Error!void {
    switch (d.*) {
        .Function => |*f| try base.decl_names.put(f.name.name, {}),
        .Property => |p| try base.decl_names.put(p.name.name, {}),
        .Class => |*c| {
            try base.decl_names.put(c.name.name, {});
            try base.type_names.put(c.name.name, {});
        },
        .Object => |*o| {
            try base.decl_names.put(o.name.name, {});
            try base.type_names.put(o.name.name, {});
        },
        .TypeAlias => |*t| {
            try base.decl_names.put(t.name.name, {});
            try base.type_names.put(t.name.name, {});
        },
    }
    if (root_pkg) {
        switch (d.*) {
            .Function => |*f| try base.root_decl_names.put(f.name.name, {}),
            .Property => |p| try base.root_decl_names.put(p.name.name, {}),
            .Class => |*c| try base.root_decl_names.put(c.name.name, {}),
            .Object => |*o| try base.root_decl_names.put(o.name.name, {}),
            .TypeAlias => |*t| try base.root_decl_names.put(t.name.name, {}),
        }
    }
}

/// Whether `user_files` can extend `base` without changing any decision the
/// base build already settled. Conservative: any top-level simple-name
/// overlap (either namespace), any expect/actual decl, any package overlap,
/// or a function-type alias matching a base param type forces the full
/// whole-program build.
pub fn canExtendBase(base: *const StdlibBase, user_files: []const KotlinFile) bool {
    for (user_files) |*f| {
        if (f.package) |p| {
            var buf: [256]u8 = undefined;
            var n: usize = 0;
            for (p.path, 0..) |id, i| {
                if (i != 0) {
                    if (n >= buf.len) return false;
                    buf[n] = '.';
                    n += 1;
                }
                if (n + id.name.len > buf.len) return false;
                @memcpy(buf[n .. n + id.name.len], id.name);
                n += id.name.len;
            }
            if (base.packages.contains(buf[0..n])) return extendRefused("package overlap", buf[0..n]);
        }
        // A root-package user FUNCTION or PROPERTY can only collide with a
        // base callable that is itself reachable from the root package
        // (root-package base files): named-package base callables are
        // invisible to bare references outside their package under Kotlin
        // scoping, and the callable dispatch tails are visibility-filtered,
        // so the user namesake cannot change any base decision. The TYPE
        // namespace (classes, objects, typealiases) stays on the whole-set
        // refusal: runtime casts / `is` checks / reified probes resolve
        // type names WITHOUT package scoping (a user `Node` broke the
        // kotlinx.coroutines-internal `as Node` cast), so a user type
        // namesake of ANY base type forces the full build. A user file
        // that DECLARES a package keeps the conservative whole-set refusal
        // for callables too.
        const callable_names: *const StringSet = if (f.package == null) &base.root_decl_names else &base.decl_names;
        for (f.decls) |*d| {
            switch (d.*) {
                .Function => |*fd| {
                    if (fd.is_expect or fd.is_actual) return extendRefused("expect/actual fn", fd.name.name);
                    if (callable_names.contains(fd.name.name)) return extendRefused("fn name", fd.name.name);
                },
                .Property => |pd| {
                    if (pd.is_expect or pd.is_actual) return extendRefused("expect/actual prop", pd.name.name);
                    if (callable_names.contains(pd.name.name)) return extendRefused("prop name", pd.name.name);
                },
                .Class => |*cd| {
                    if (cd.is_expect or cd.is_actual) return extendRefused("expect/actual class", cd.name.name);
                    if (base.decl_names.contains(cd.name.name)) return extendRefused("class name", cd.name.name);
                },
                .Object => |*od| {
                    if (od.is_expect or od.is_actual) return extendRefused("expect/actual object", od.name.name);
                    if (base.decl_names.contains(od.name.name)) return extendRefused("object name", od.name.name);
                },
                .TypeAlias => |*td| {
                    if (base.decl_names.contains(td.name.name)) return extendRefused("alias name", td.name.name);
                    if (td.target.function != null and base.param_type_names.contains(td.name.name)) return extendRefused("fn alias vs base param type", td.name.name);
                },
            }
        }
    }
    return true;
}

/// Named refusal for the extend gate, surfaced under `KLIO_TRACE_STDLIB_IMAGE`
/// so a silent image fallback (a full source re-lower costing seconds) is
/// attributable to the exact colliding declaration.
fn extendRefused(reason: []const u8, name: []const u8) bool {
    if (runtime.envOnce("KLIO_TRACE_STDLIB_IMAGE")) |v| {
        if (v.len != 0 and !std.mem.eql(u8, v, "0")) {
            std.debug.print("[stdlib-image] extend refused: {s} `{s}`\n", .{ reason, name });
        }
    }
    return false;
}

/// Per-run clone of the base's BuiltModule onto `a`. Spines are copied;
/// lowered leaf data (instructions, strings, thunk-id slices) is shared
/// with the immutable base. Runtime-mutable graphs (the ClassDef table,
/// enum-entry instances, companion/object/captured-env cells) are deep
/// cloned so a run can never write through to the base.
fn cloneBuiltForRun(a: Allocator, base: *const BuiltModule) Allocator.Error!BuiltModule {
    const module_clone = blk: {
        const mg = base.module.borrow();
        defer mg.deinit();
        break :blk try mg.get().cloneForExtend(a);
    };
    const module_ref = try ObjRef(Module).init(a, module_clone);
    var out = emptyBuilt(a, module_ref, base.main);

    out.classes.deinit();
    out.classes = try cloneClassTableForRun(a, &base.classes);

    try copyPairMap(&out.body_prop_inits, &base.body_prop_inits);
    try copyPairMap(&out.instance_prop_getters, &base.instance_prop_getters);
    {
        var it = base.getter_prop_names.keyIterator();
        while (it.next()) |k| try out.getter_prop_names.put(k.*, {});
    }
    try copyPairMap(&out.instance_prop_setters, &base.instance_prop_setters);
    try copyPairMap(&out.instance_prop_private, &base.instance_prop_private);
    try copyStrMap([]FuncId, &out.parent_ctor_args, &base.parent_ctor_args);
    // Parallel to `parent_ctor_args`: without this a class inherited from the
    // base loses its super-constructor argument labels, so a named super-ctor
    // argument that skips an earlier defaulted parameter (`Operation(objects =
    // 2)`) binds positionally onto the wrong parameter.
    try copyStrMap([]const ?[]const u8, &out.parent_ctor_arg_names, &base.parent_ctor_arg_names);
    try copyStrMap([]FuncId, &out.init_blocks, &base.init_blocks);
    try out.top_level_props.appendSlice(a, base.top_level_props.items);
    try copyPairMap(&out.extension_props, &base.extension_props);
    {
        var it = base.owner_keyed_ext_names.keyIterator();
        while (it.next()) |k| try out.owner_keyed_ext_names.put(k.*, {});
    }
    {
        var it = base.nullable_ext_props.iterator();
        while (it.next()) |e| try out.nullable_ext_props.put(e.key_ptr.*, e.value_ptr.*);
    }
    try copyPairMap(&out.extension_prop_delegates, &base.extension_prop_delegates);
    try copyPairMap(&out.extension_prop_setters, &base.extension_prop_setters);
    try out.object_names.appendSlice(a, base.object_names.items);
    try copyStrMap([]const u8, &out.companion_singletons, &base.companion_singletons);
    try out.enum_entry_arg_inits.appendSlice(a, base.enum_entry_arg_inits.items);
    try copyStrMap([]SecondaryCtorEntry, &out.secondary_ctors, &base.secondary_ctors);
    try copyStrMap([]?FuncId, &out.primary_ctor_default_thunks, &base.primary_ctor_default_thunks);
    try copyStrMap([]StrFunc, &out.class_delegates, &base.class_delegates);
    {
        var it = base.func_defaults.iterator();
        while (it.next()) |e| try out.func_defaults.put(e.key_ptr.*, e.value_ptr.*);
    }
    try copyStrMap([]const u8, &out.enclosing_class, &base.enclosing_class);
    {
        var it = base.enum_entry_methods.iterator();
        while (it.next()) |e| try out.enum_entry_methods.put(e.key_ptr.*, e.value_ptr.*);
    }
    {
        var it = base.enum_entry_synth_class.iterator();
        while (it.next()) |e| try out.enum_entry_synth_class.put(e.key_ptr.*, e.value_ptr.*);
    }
    {
        var it = base.func_type_params.iterator();
        while (it.next()) |e| try out.func_type_params.put(e.key_ptr.*, e.value_ptr.*);
    }
    {
        var it = base.top_level_delegated_props.keyIterator();
        while (it.next()) |k| try out.top_level_delegated_props.put(k.*, {});
    }
    {
        var it = base.delegated_body_props.keyIterator();
        while (it.next()) |k| try out.delegated_body_props.put(k.*, {});
    }
    return out;
}

fn copyPairMap(dst: *PairFuncMap, src: *const PairFuncMap) Allocator.Error!void {
    var it = src.iterator();
    while (it.next()) |e| try dst.put(e.key_ptr.*, e.value_ptr.*);
}

fn copyStrMap(comptime V: type, dst: *std.StringHashMap(V), src: *const std.StringHashMap(V)) Allocator.Error!void {
    var it = src.iterator();
    while (it.next()) |e| try dst.put(e.key_ptr.*, e.value_ptr.*);
}

/// Resolve a class written with a dotted qualifier (`Outer.Inner`) by matching
/// it as a `.`-aligned suffix of a registered class's FQN, preferring the
/// shortest (least-nested) match. The table holds each class under both its
/// simple name and FQN, so scanning values (not keys) avoids double-counting.
fn classTableByQualifiedSuffix(classes: *const ClassTable, qualified: []const u8) ?ObjRef(ClassDef) {
    if (std.mem.indexOfScalar(u8, qualified, '.') == null) return null;
    var best: ?ObjRef(ClassDef) = null;
    var best_len: usize = std.math.maxInt(usize);
    var it = classes.valueIterator();
    while (it.next()) |d| {
        const dg = d.borrow();
        const fqn = dg.get().fqn;
        const ok = std.mem.endsWith(u8, fqn, qualified) and
            (fqn.len == qualified.len or fqn[fqn.len - qualified.len - 1] == '.');
        const flen = fqn.len;
        dg.deinit();
        if (ok and flen < best_len) {
            best_len = flen;
            best = d.*;
        }
    }
    return best;
}

/// Deep-clone the runtime ClassDef graph: a run mutates ClassDefs (startup
/// patches enum-entry instance fields; companions and object singletons
/// fill lazily), so per-run defs must be private. Lowered/AST leaf slices
/// (methods, properties, ctor metadata) stay shared with the base.
fn cloneClassTableForRun(a: Allocator, src: *const ClassTable) Allocator.Error!ClassTable {
    var remap = std.AutoHashMap(usize, ObjRef(ClassDef)).init(a);
    defer remap.deinit();

    // Pass 1: shells for every unique def cell.
    {
        var it = src.valueIterator();
        while (it.next()) |def| {
            const key = @intFromPtr(def.cell);
            if (remap.contains(key)) continue;
            const g = def.borrow();
            var copy: ClassDef = g.get().*;
            g.deinit();
            copy.companion = try ObjRef(?ObjRef(InstanceData)).init(a, null);
            copy.object_singleton = try ObjRef(?ObjRef(InstanceData)).init(a, null);
            copy.enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(a, null);
            copy.captured_env = try ObjRef(Env).init(a, Env.init(a));
            copy.parent = null;
            copy.interfaces = &.{};
            copy.nested_classes = &.{};
            copy.enum_entries = &.{};
            try remap.put(key, try ObjRef(ClassDef).init(a, copy));
        }
    }

    // Pass 2: re-link the graph through the remap and deep-clone the
    // runtime-mutable payloads.
    {
        var it = src.valueIterator();
        while (it.next()) |def| {
            const key = @intFromPtr(def.cell);
            const cloned = remap.get(key).?;
            const sg = def.borrow();
            defer sg.deinit();
            const s = sg.get();
            const cg = cloned.borrowMut();
            defer cg.deinit();
            const c = cg.get();

            if (s.parent) |p| {
                if (remap.get(@intFromPtr(p.cell))) |np| c.parent = np.clone();
            }
            if (s.interfaces.len != 0) {
                const ifaces = try a.alloc(ObjRef(ClassDef), s.interfaces.len);
                for (s.interfaces, 0..) |iface, i| {
                    ifaces[i] = if (remap.get(@intFromPtr(iface.cell))) |ni| ni.clone() else iface.clone();
                }
                c.interfaces = ifaces;
            }
            if (s.nested_classes.len != 0) {
                const nested = try a.alloc(ClassDef.NestedClass, s.nested_classes.len);
                for (s.nested_classes, 0..) |nc, i| {
                    nested[i] = .{
                        .name = nc.name,
                        .class = if (remap.get(@intFromPtr(nc.class.cell))) |nn| nn.clone() else nc.class.clone(),
                    };
                }
                c.nested_classes = nested;
            }
            {
                const eg = s.enclosing_class.borrow();
                const enc = eg.get().*;
                eg.deinit();
                if (enc) |ec| {
                    const mapped = if (remap.get(@intFromPtr(ec.cell))) |ne| ne.clone() else ec.clone();
                    const cgi = c.enclosing_class.borrowMut();
                    cgi.get().* = mapped;
                    cgi.deinit();
                }
            }
            if (s.enum_entries.len != 0) {
                const entries = try a.alloc(ClassDef.EnumEntry, s.enum_entries.len);
                for (s.enum_entries, 0..) |entry, i| {
                    entries[i] = .{ .name = entry.name, .value = try cloneBuildValue(a, &remap, entry.value) };
                }
                c.enum_entries = entries;
            }
        }
    }

    var out = ClassTable.init(a);
    var kit = src.iterator();
    while (kit.next()) |e| {
        try out.put(e.key_ptr.*, remap.get(@intFromPtr(e.value_ptr.cell)).?.clone());
    }
    // Drop the construction handles; the table's clones keep the cells live.
    var rit = remap.valueIterator();
    while (rit.next()) |r| r.deinit();
    return out;
}

/// Clone a build-time Value reachable from an enum entry. Instances are
/// deep-cloned (their fields are patched at startup); every other variant
/// is shared — at build time those are immutable payloads (entry-name
/// strings, ordinals) the run never writes through.
fn cloneBuildValue(a: Allocator, remap: *const std.AutoHashMap(usize, ObjRef(ClassDef)), v: Value) Allocator.Error!Value {
    switch (v) {
        .Instance => |inst| {
            const g = inst.borrow();
            defer g.deinit();
            const s = g.get();
            var fields: std.ArrayList(InstanceData.Field) = .empty;
            for (s.fields.items) |f| {
                try fields.append(a, .{ .name = f.name, .value = try cloneBuildValue(a, remap, f.value) });
            }
            const cls = if (remap.get(@intFromPtr(s.class.cell))) |nc| nc.clone() else s.class.clone();
            const copy = try ObjRef(InstanceData).init(a, .{
                .class = cls,
                .fields = fields,
                .outer = s.outer,
                .identity = s.identity,
                .native_state = s.native_state,
            });
            return .{ .Instance = copy };
        },
        else => return v,
    }
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    _ = lift;
}

test "symbol-index default-import list matches the stdlib's canonical one" {
    // `ir` cannot depend on `stdlib`, so the index carries a mirror of
    // `IMPLICITLY_IMPORTED_PACKAGES`; this pins the two in lockstep.
    try testing.expectEqual(
        stdlib.IMPLICITLY_IMPORTED_PACKAGES.len,
        ir.Module.default_import_packages.len,
    );
    for (stdlib.IMPLICITLY_IMPORTED_PACKAGES, ir.Module.default_import_packages) |a, b| {
        try testing.expectEqualStrings(a, b);
    }
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

test "multi-file assembly retains packaged typealias identities" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = span.Span.init(span.FileId.from(7), 0, 1);
    var package_path = [_]ast.Ident{
        .{ .name = "sample", .span = s },
        .{ .name = "types", .span = s },
    };
    const target = ast.TypeRef{
        .name = .{ .name = "Long", .span = s },
        .nullable = false,
        .span = s,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    var decls = [_]ast.Decl{.{ .TypeAlias = .{
        .name = .{ .name = "Counter", .span = s },
        .type_params = &.{},
        .target = target,
        .visibility = .Internal,
        .annotations = &.{},
        .span = s,
    } }};
    const file = ast.KotlinFile{
        .package = .{ .path = &package_path, .span = s },
        .imports = &.{},
        .decls = &decls,
        .span = s,
    };

    var built = try buildModuleFiles(a, &.{file});
    defer built.deinit();
    const mg = built.module.borrow();
    defer mg.deinit();
    const shape = mg.get().registry.type_alias_types.get(
        "sample.types.Counter",
    );
    try testing.expect(shape != null);
    try testing.expectEqualStrings("Long", shape.?.target.name);
    try testing.expectEqual(
        @as(u32, 0),
        mg.get().registry.file_modules.get(s.file).?,
    );
}

test "dependency extension assigns a distinct compilation module" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dep_span = span.Span.init(span.FileId.from(20), 0, 0);
    const user_span = span.Span.init(span.FileId.from(21), 0, 0);
    const dep_file = KotlinFile{
        .package = null,
        .imports = &.{},
        .decls = &.{},
        .span = dep_span,
    };
    const user_file = KotlinFile{
        .package = null,
        .imports = &.{},
        .decls = &.{},
        .span = user_span,
    };
    const base = (try buildStdlibBase(a, &.{dep_file})).?;
    var extended = try buildModuleFilesExtend(a, base, &.{user_file});
    defer extended.deinit();

    const mg = extended.module.borrow();
    defer mg.deinit();
    try testing.expectEqual(
        @as(u32, 0),
        mg.get().registry.file_modules.get(dep_span.file).?,
    );
    try testing.expectEqual(
        @as(u32, 1),
        mg.get().registry.file_modules.get(user_span.file).?,
    );
}

test "class type-parameter metadata includes where bounds and unbounded identities" {
    const s = span.Span.init(span.FileId.from(0), 0, 1);
    const number_ty = ast.TypeRef{
        .name = .{ .name = "Number", .span = s },
        .nullable = false,
        .span = s,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const comparable_ty = ast.TypeRef{
        .name = .{ .name = "Comparable", .span = s },
        .nullable = false,
        .span = s,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const string_ty = ast.TypeRef{
        .name = .{ .name = "String", .span = s },
        .nullable = false,
        .span = s,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const comparable_args = [_]ast.TypeArg{.{
        .variance = .Invariant,
        .is_star = false,
        .ty = string_ty,
        .span = s,
    }};
    const comparable_string_ty = ast.TypeRef{
        .name = .{ .name = "Comparable", .span = s },
        .nullable = false,
        .span = s,
        .type_args = @constCast(&comparable_args),
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    const params = [_]ast.TypeParam{
        .{
            .name = .{ .name = "T", .span = s },
            .variance = .Out,
            .upper_bound = number_ty,
            .is_reified = false,
            .annotations = &.{},
            .span = s,
        },
        .{
            .name = .{ .name = "V", .span = s },
            .variance = .Invariant,
            .upper_bound = comparable_string_ty,
            .is_reified = false,
            .annotations = &.{},
            .span = s,
        },
        .{
            .name = .{ .name = "U", .span = s },
            .variance = .Invariant,
            .upper_bound = null,
            .is_reified = false,
            .annotations = &.{},
            .span = s,
        },
    };
    const where_bounds = [_]ast.WhereBound{.{
        .name = .{ .name = "T", .span = s },
        .bound = comparable_ty,
        .span = s,
    }};
    var class: ast.Class = undefined;
    class.type_params = @constCast(&params);
    class.where_bounds = @constCast(&where_bounds);

    const bounds = (try collectClassTypeParamBounds(testing.allocator, &class)).?;
    defer testing.allocator.free(bounds);
    defer for (bounds) |tb| testing.allocator.free(tb.args);
    try testing.expectEqual(@as(usize, 4), bounds.len);
    try testing.expectEqualStrings("T", bounds[0].param);
    try testing.expectEqualStrings("Number", bounds[0].bound);
    try testing.expect(!bounds[0].complete);
    try testing.expectEqualStrings("T", bounds[1].param);
    try testing.expectEqualStrings("Comparable", bounds[1].bound);
    try testing.expect(!bounds[1].complete);
    try testing.expectEqualStrings("V", bounds[2].param);
    try testing.expectEqualStrings("Comparable", bounds[2].bound);
    try testing.expect(!bounds[2].complete);
    try testing.expectEqualStrings("U", bounds[3].param);
    try testing.expectEqualStrings("kotlin.Any", bounds[3].bound);
    try testing.expect(bounds[3].complete);
}

test "expect class member defaults transplant to the matching actual signature" {
    const s = span.Span.init(span.FileId.from(0), 0, 1);
    const int_ty: ast.TypeRef = .{
        .name = .{ .name = "Int", .span = s },
        .nullable = false,
        .span = s,
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
    var default_expr = ast.Expr{ .IntLit = .{ .value = 7, .kind = .Int, .span = s } };
    var expected_param: ast.Param = undefined;
    expected_param.name = .{ .name = "value", .span = s };
    expected_param.ty = int_ty;
    expected_param.default = &default_expr;
    var actual_param: ast.Param = expected_param;
    actual_param.default = null;

    var expected: ast.Function = undefined;
    expected.name = .{ .name = "run", .span = s };
    expected.receiver_type = null;
    var expected_params = [_]ast.Param{expected_param};
    expected.params = &expected_params;
    var actual: ast.Function = undefined;
    actual.name = expected.name;
    actual.receiver_type = null;
    var actual_params = [_]ast.Param{actual_param};
    actual.params = &actual_params;

    try testing.expect(transplantExpectMemberDefaults(&actual, &expected));
    try testing.expect(actual.params[0].default == &default_expr);

    actual.params[0].default = null;
    actual.params[0].ty.name.name = "String";
    try testing.expect(!transplantExpectMemberDefaults(&actual, &expected));
    try testing.expect(actual.params[0].default == null);
}

test "member receiver-lambda shape records omitted leading defaults" {
    var module = ir.Module.init(testing.allocator);
    defer module.deinit(testing.allocator);
    const s = span.Span.init(span.FileId.from(0), 0, 1);
    var default_expr = ast.Expr{ .NullLit = .{ .span = s } };
    var scope_ty: ast.TypeRef = undefined;
    scope_ty.name = .{ .name = "CoroutineScope", .span = s };
    var unit_ty: ast.TypeRef = undefined;
    unit_ty.name = .{ .name = "Unit", .span = s };
    var fn_ty: ast.FunctionTypeRef = .{
        .receiver = scope_ty,
        .params = &.{},
        .ret = unit_ty,
        .is_suspend = true,
        .context_params = &.{},
        .span = s,
    };
    var block_ty: ast.TypeRef = undefined;
    block_ty.name = .{ .name = "<function>", .span = s };
    block_ty.function = &fn_ty;

    var params: [3]ast.Param = undefined;
    params[0].default = &default_expr;
    params[0].is_vararg = false;
    params[1].default = &default_expr;
    params[1].is_vararg = false;
    params[2].ty = block_ty;
    params[2].default = null;
    params[2].is_vararg = false;
    var f: ast.Function = undefined;
    f.params = &params;

    const shape = memberTrailingLambdaShape(&module, &f).?;
    try testing.expectEqual(@as(i16, 0), shape.value_arity);
    try testing.expectEqualStrings("CoroutineScope", shape.receiver_head.?);
    try testing.expect(shape.accepted_arities & (@as(u64, 1) << 1) != 0);
    try testing.expect(shape.accepted_arities & (@as(u64, 1) << 2) != 0);
    try testing.expect(shape.accepted_arities & (@as(u64, 1) << 3) != 0);
}
