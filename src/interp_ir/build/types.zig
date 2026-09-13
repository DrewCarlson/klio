//! The side tables a built module carries: the shared key/value table types,
//! `BuiltModule` and its empty shell, and the span-keyed override maps.

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

// Shared table types, used by both BuiltModule and the Vm's ProgramImage.

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

pub const PairFuncMap = std.HashMap(StrPair, FuncId, StrPairContext, std.hash_map.default_max_load_percentage);
pub const StrPairSet = std.HashMap(StrPair, void, StrPairContext, std.hash_map.default_max_load_percentage);

pub const ClassTable = std.StringHashMap(ObjRef(ClassDef));

/// `(supertype simple name, thunk FuncId)` class-delegation entry.
pub const StrFunc = struct { name: []const u8, func: FuncId };

/// JVM static-field default for a top-level property's declared type. Startup runs
/// initializers in file order, so a forward read of a not-yet-initialized annotated property
/// observes this default; `.none` (unannotated, `const`, delegated) drives on demand.
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
pub const NameFunc = struct { name: []const u8, func: FuncId, default: TypedDefault = .none, file: u32 = 0 };

pub const EnumEntryArgInit = struct {
    class_name: []const u8,
    entry_name: []const u8,
    funcs: []FuncId,
};

pub const EnumEntryMethod = struct {
    module: ObjRef(Module),
    func: FuncId,
};

/// One secondary constructor. `delegation_arg_thunks` evaluate the `: this(...)` /
/// `: super(...)` arguments against the secondary's positional params, and the Vm dispatches
/// the results to the primary ctor.
pub const SecondaryCtorEntry = struct {
    param_count: usize,
    param_names: [][]const u8,
    /// Simple type-name head per parameter, disambiguating same-arity ctor overloads.
    param_type_heads: [][]const u8,
    is_super: bool,
    is_this: bool,
    delegation_arg_thunks: []FuncId,
    default_arg_thunks: []?FuncId,
    /// Optional body block lowered as a 1-arg fn taking `this`.
    body: ?FuncId,
    /// `@Deprecated(level = ERROR|HIDDEN)` / `@LowPriorityInOverloadResolution`: kotlinc
    /// never offers such a constructor to source, so it must not win over an ordinary one.
    low_priority: bool = false,
    /// Index of the `vararg` parameter, which takes any number of trailing arguments.
    vararg_index: ?usize = null,
};

pub const BuiltModule = struct {
    module: ObjRef(Module),
    /// Per-class runtime metadata, keyed by simple class name.
    classes: ClassTable,
    /// `(class name, property name)` → `FuncId` for literal-initialised body properties.
    body_prop_inits: PairFuncMap,
    /// `(class name, property name)` → `FuncId` for body properties with a custom getter.
    instance_prop_getters: PairFuncMap,
    getter_prop_names: std.StringHashMap(void),
    instance_prop_setters: PairFuncMap,
    /// Getter-backed `private` body properties, keyed as getters are. A private property never
    /// overrides, so the scope-qualified walk skips it off its lexical owner.
    instance_prop_private: PairFuncMap,
    parent_ctor_args: std.StringHashMap([]FuncId),
    /// Argument labels parallel to `parent_ctor_args`, binding a named super-ctor argument
    /// (`: Base(objects = 2)`) to the base parameter of that name.
    parent_ctor_arg_names: std.StringHashMap([]const ?[]const u8),
    /// `init { ... }` blocks per class. Each `FuncId` takes `this`.
    init_blocks: std.StringHashMap([]FuncId),
    top_level_props: std.ArrayList(NameFunc),
    /// Top-level extension properties, keyed by `(receiver type, prop)`.
    extension_props: PairFuncMap,
    /// Names having at least one owner-qualified key; see the Prog field.
    owner_keyed_ext_names: std.StringHashMap(void),
    /// Getters of extension properties on a NULLABLE receiver, keyed by property name: the only
    /// dispatch key left when the receiver is null. A name on several nullable receivers is null.
    nullable_ext_props: std.StringHashMap(?FuncId),
    extension_prop_setters: PairFuncMap,
    /// Delegated extension properties (`val R.x by expr`) keyed by `(receiver type, prop)`; the
    /// `FuncId` is the 0-arg thunk producing the delegate, and reads and writes route through its
    /// `getValue`/`setValue` with the delegate cached per property.
    extension_prop_delegates: PairFuncMap,
    main: ?FuncId,
    object_names: std.ArrayList([]const u8),
    companion_singletons: std.StringHashMap([]const u8),
    enum_entry_arg_inits: std.ArrayList(EnumEntryArgInit),
    secondary_ctors: std.StringHashMap([]SecondaryCtorEntry),
    primary_ctor_default_thunks: std.StringHashMap([]?FuncId),
    /// Class delegation entries: `class W(g) : Greeter by g`.
    class_delegates: std.StringHashMap([]StrFunc),
    /// Per-function default-arg thunks, keyed by target `FuncId.int()`.
    func_defaults: std.AutoHashMap(u32, []?FuncId),
    enclosing_class: std.StringHashMap([]const u8),
    /// Pre-lowered per-entry `override fun` bodies, keyed by `(synth class, method)`.
    enum_entry_methods: std.HashMap(StrPair, EnumEntryMethod, StrPairContext, std.hash_map.default_max_load_percentage),
    /// `(enum class, entry)` → synth class name for entries with methods.
    enum_entry_synth_class: PairStrMap,
    func_type_params: std.AutoHashMap(u32, [][]const u8),
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

pub const PairStrMap = std.HashMap(StrPair, []const u8, StrPairContext, std.hash_map.default_max_load_percentage);

/// Public for the image loader, which fills the shell table-by-table from decoded data.
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
// Span-keyed override maps: per-declaration FQN overrides for pack files.

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

pub const FileClasses = std.StringHashMap(FF(ast.Class));
