//! The side tables a built module carries: the shared key/value table
//! types, `BuiltModule` and its empty shell, and the span-keyed override
//! maps the per-file lowering driver threads through.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const FF = runtime.forest.ForestField;
const ast = @import("ast");
const span = @import("span");

const Allocator = std.mem.Allocator;
const Module = ir.Module;
const FuncId = ir.FuncId;
const ClassDef = runtime.ClassDef;
const ObjRef = runtime.ObjRef;

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
    /// Index of the `vararg` parameter, if the constructor declares one:
    /// it takes any number of trailing arguments, none included.
    vararg_index: ?usize = null,
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

pub fn emptyBuilt(allocator: Allocator, module: ObjRef(Module), main: ?FuncId) BuiltModule {
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

pub const Span = span.Span;
pub const SpanContext = struct {
    pub fn hash(_: SpanContext, key: Span) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&key));
        return h.final();
    }
    pub fn eql(_: SpanContext, x: Span, y: Span) bool {
        return std.meta.eql(x, y);
    }
};
pub const SpanStrMap = std.HashMap(Span, []const u8, SpanContext, std.hash_map.default_max_load_percentage);

/// File-scoped class registry: simple name → AST class.
pub const FileClasses = std.StringHashMap(FF(ast.Class));
