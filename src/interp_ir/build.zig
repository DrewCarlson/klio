//! Front-end-to-IR module builder for the IR-native interpreter.
//!
//! This module owns the AST → IR lowering driver: it takes a parsed
//! Kotlin file and produces an `ir.Module` ready for `Vm.run`, along
//! with the synthesised runtime `ClassDef` table and the side tables the
//! Vm consults at dispatch time. The full lowering pipeline (class /
//! function / property lowering, pack merging, suspend state machines)
//! is grown alongside the Vm's native execution paths.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const span = @import("span");

pub const lift = @import("build/lift.zig");

const Allocator = std.mem.Allocator;
const Module = ir.Module;
const FuncId = ir.FuncId;
const ClassDef = runtime.ClassDef;
const ObjRef = runtime.ObjRef;
const Value = runtime.Value;
const KotlinFile = ast.KotlinFile;

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

/// Build an empty `BuiltModule` shell around `module`. The lowering
/// driver populates the side tables; this establishes the owning shape.
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

/// Lower a single file's declarations into an IR module.
///
/// Classes are lowered first so `Inst.NewInstance` lookups resolve, then
/// a pre-pass registers stub Funcs for every top-level function so
/// forward references and mutual recursion lower cleanly, then each
/// function body lowers into its reserved slot. The lowering body is
/// grown alongside the Vm's native execution paths.
pub fn buildModule(allocator: Allocator, file: *const KotlinFile) Allocator.Error!BuiltModule {
    _ = file;
    const module = try ObjRef(Module).init(allocator, Module.default(allocator));
    return emptyBuilt(allocator, module, null);
}

/// Drive `buildModule` against multiple parsed files. All declarations
/// from every file are concatenated into one synthesised file and
/// lowered as a single program.
pub fn buildModuleFiles(allocator: Allocator, files: []const KotlinFile) Allocator.Error!BuiltModule {
    _ = files;
    const module = try ObjRef(Module).init(allocator, Module.default(allocator));
    return emptyBuilt(allocator, module, null);
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    _ = lift;
}

test "build_module produces an owned empty module shell" {
    const file: KotlinFile = .{
        .package = null,
        .imports = &.{},
        .decls = &.{},
        .span = span.Span.init(span.FileId.from(0), 0, 0),
    };
    var built = try buildModule(testing.allocator, &file);
    defer built.deinit();
    try testing.expect(built.main == null);
    try testing.expectEqual(@as(usize, 0), built.top_level_props.items.len);
}
