const std = @import("std");
const runtime = @import("runtime");
const Allocator = std.mem.Allocator;
const root_ir = @import("../ir.zig");
const core_class = @import("class.zig");
const core_consts = @import("consts.zig");
const core_ids = @import("ids.zig");

const Const = core_consts.Const;
const FileId = root_ir.FileId;
const FuncId = core_ids.FuncId;
const StrPairMap = core_class.StrPairMap;
const StrPairSet = core_class.StrPairSet;
const TypeRef = core_ids.TypeRef;

/// Module-scoped side tables the Vm consults at dispatch time. Serialized into
/// pack files, so a pre-built pack ships its registry beside its frozen IR.
pub const ModuleRegistry = struct {
    /// Names of `object` singletons; the Vm publishes one instance of each as a global.
    object_names: std.ArrayList([]const u8) = .empty,
    /// Outer class -> companion-singleton global name; `Foo.X` falls through to it.
    companion_singletons: runtime.NameHashMap([]const u8),
    /// Fqns whose installed host binding outranks any interpreted body (a pack's stub declarations).
    host_shadowed_fqns: runtime.NameHashMap(void),
    /// Inner class -> outer class name; resolves `this@Outer` and outer-chain field reads.
    enclosing_class: runtime.NameHashMap([]const u8),
    /// Per-function type-parameter names in source order; reified dispatch binds each.
    func_type_params: std.AutoHashMap(FuncId, std.ArrayList([]const u8)),
    /// Declared upper bounds of a function's type parameters, one entry per (param, bound).
    func_type_param_bounds: std.AutoHashMap(FuncId, []const TypeParamBound),
    /// Declared upper bounds of each class's type parameters, keyed by class simple name.
    /// Dispatch disproves an argument whose type violates the bound on a class parameter.
    class_type_param_bounds: runtime.NameHashMap([]const TypeParamBound),
    /// Top-level properties declared `by`; reads and writes route through `getValue`/`setValue`.
    top_level_delegated_props: runtime.NameHashMap(void),
    /// Top-level `lateinit var` names: no binding until the first write, so a read that finds
    /// none throws `UninitializedPropertyAccessException` and `isInitialized` answers from it.
    top_level_lateinit_props: runtime.NameHashMap(void),
    /// Class -> member FUNCTION names declared or inherited transitively; Kotlin keeps the namespaces apart.
    hierarchy_methods: runtime.NameHashMap(runtime.NameHashMap(void)),
    /// Private stored properties that shadow a same-name supertype declaration, keyed
    /// "Class\x1fprop". Each gets its own cell, addressed owner-mangled. Lowering-only.
    private_shadow_props: runtime.NameHashMap(void),
    /// Initialized `override val/var` whose supertype also stores the name, keyed "Class\x1fprop".
    /// Each class keeps its own cell: a read takes the most-derived, `super.x` the base. Lowering-only.
    override_cell_props: runtime.NameHashMap(void),
    /// Per-class transitive member-name set for the member-shadow gate, plus whether the supertype
    /// chain resolved; an incomplete set cannot prove non-shadowability. Lowering-only.
    hierarchy_shadow_names: runtime.NameHashMap(HierarchyShadowSet),
    /// (declaring class, method) -> trailing-lambda shapes, collected from every member declaration
    /// before any body lowers, so receiver-lambda typing does not depend on source order.
    member_trailing_lambda_shapes: StrPairMap(std.ArrayList(MemberTrailingLambdaShape)),
    /// `"<class>\x00<method>\x00<userArity>"` -> the lowered method's FuncId, filled as each body
    /// lowers, so a body reaches a sibling member's signature before `Class.methods` is patched.
    member_method_fids: runtime.NameHashMap(FuncId),
    /// Keys of `member_method_fids` that more than one declaration claimed.
    /// The table's writer overwrites, so a key in here holds an arbitrary one
    /// of them and no consumer may bind through it. Same-arity overloads and
    /// two classes sharing a simple name both land here.
    member_method_ambiguous: runtime.NameHashMap(void),
    /// Simple member name -> every member declaration of that name, any class: the
    /// namesake set a trailing lambda's shape is agreed over when the call's
    /// receiver is decided at run time.
    member_fids_by_name: runtime.NameHashMap(std.ArrayList(FuncId)),
    /// Class name -> its `this@<Class>` label, one string per class for the
    /// module's life, so a builder record or a capture list can hold it.
    this_labels: runtime.NameHashMap([]const u8),
    /// Every member name declared by any class: only these can be shadowed by a runtime receiver.
    class_member_names: runtime.NameHashMap(void),
    /// Class -> transitive supertype simple names, nearest first, recorded from the AST before body
    /// lowering so extension receivers rank while the `Class.supertypes` slots are still filling.
    class_super_names: runtime.NameHashMap([]const []const u8),
    /// Bumped whenever `class_super_names` or `mangled_nested` change, so the
    /// supertype-name closures below are dropped rather than trusted.
    class_super_gen: u32 = 0,
    /// Per class name, every simple name the supertype-name walk reaches from
    /// it; `evidenceSubtype` builds each on first query. Keys are owned.
    evidence_supers: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty,
    evidence_supers_gen: u32 = 0,
    /// Body-property `(class, prop)` pairs declared with `by`.
    delegated_body_props: StrPairSet,
    /// `"<ancestor>\u{1f}<member>"` for every member name a STRICT subclass
    /// declares. A declared slot's index is the same in every subclass, so an
    /// open class's slot is still a valid index; what a subclass can change is
    /// whether the slot is the ANSWER, by overriding the property. Read from
    /// the AST members, which is the only complete record — a layout misses an
    /// accessor-only override, and so does the getter naming contract.
    subclass_declares_prop: runtime.NameHashMap(void),
    /// (class, property) pairs whose declared type is a receiver function type; the value is the
    /// receiver's simple head, so a bare invoke binds the innermost implicit receiver of that type.
    recv_fn_props: StrPairMap([]const u8),
    /// (class, property) -> declared type head, a class type parameter replaced by its bound's head.
    class_prop_type_heads: StrPairMap([]const u8),
    /// Same key with the FULL declared type (`List<Named>`, not `List`): a head alone cannot say what
    /// iterating or indexing yields. Borrowed from the lowering arena, like every registry string.
    class_prop_type_refs: StrPairMap(TypeRef),
    /// (ext receiver head, property) -> declared type head for top-level extension properties.
    ext_prop_type_heads: StrPairMap([]const u8),
    /// `FuncId` -> declaring class for MEMBER extension functions; empty for top-level ones.
    member_ext_owner_class: std.AutoHashMap(FuncId, []const u8),
    /// `FuncId` -> declaring file of a `private` top-level function, which Kotlin scopes to that file.
    private_fn_files: std.AutoHashMap(FuncId, FileId),
    /// (interface, method) -> declared extension-receiver head for ABSTRACT member extensions.
    /// The abstract slot lowers no func, so SAM dispatch binds the lambda's `this` from here.
    iface_member_ext_recv: StrPairMap([]const u8),
    /// (interface, method) -> the method's `context(...)` parameter type names joined by `|`; a SAM
    /// conversion supplies each from the call site's context scope as a leading argument.
    iface_member_ctx_types: StrPairMap([]const u8),
    /// (class, member) -> arity bitmask (bit n = declared with n params, capped at 63) for BODYLESS
    /// members, which lower no func and join no class method list but must still outrank extensions.
    abstract_member_arity: StrPairMap(u64),
    /// Top-level `const val` literals by FQN; Kotlin inlines constants, so lowering emits the literal.
    top_level_const_vals: runtime.NameHashMap(Const),
    /// Per-local-function default-arg thunks keyed by body `FuncId`; a null slot is a required parameter.
    local_fn_defaults: std.AutoHashMap(FuncId, std.ArrayList(?FuncId)),
    /// Default-arg thunks for bodyless members, keyed `(class, method)`.
    abstract_member_defaults: StrPairMap(std.ArrayList(?FuncId)),
    /// `typealias Name = Target` -> `Name` mapped to `Target`'s simple head name.
    type_aliases: runtime.NameHashMap([]const u8),
    /// Structural alias targets used by static applicability proofs.
    type_alias_types: runtime.NameHashMap(TypeAliasShape),
    /// The simple names `type_alias_types` holds, however each key is qualified.
    /// Every scoped lookup probes `<some prefix>.<simple name>` or the bare name,
    /// so a name absent here cannot match any key and the probes are skipped
    /// without building the qualified strings they would hash.
    type_alias_simple: runtime.NameHashMap(void),
    /// Function-type aliases whose target declares an extension receiver -> the target's VALUE-parameter
    /// count. The `Function{N}` tag in `type_aliases` drops the receiver; a bare call still binds `this`.
    recv_fn_aliases: runtime.NameHashMap(u8),
    /// Per-file non-wildcard import leaf -> every import bound to that leaf, in declaration order:
    /// named imports are file-scoped, and same-leaf imports all stay in scope (ambiguity at the use site).
    import_aliases: std.AutoHashMap(FileId, runtime.NameHashMap(std.ArrayList(ImportPath))),
    /// One bit per import leaf a file declares, so a name a file cannot have is
    /// refused without hashing it. A lookup asks about a name the file imports
    /// roughly once in three hundred, and the rest were paying a string hash to
    /// be told nothing.
    import_alias_bloom: std.AutoHashMap(FileId, u64),
    /// Per-file wildcard-import packages, dotted and owned; `import pkg.*` outranks the built-ins.
    import_wildcards: std.AutoHashMap(FileId, std.ArrayList([]const u8)),
    /// Per-file declared package. A spliced inline body carries the DONOR file's spans, so bare-call
    /// scope follows the span's file and its imports, not the recipient function's package.
    file_packages: std.AutoHashMap(FileId, []const u8),
    /// Kotlin compilation-module identity per file: `internal` is visible only within one identity.
    file_modules: std.AutoHashMap(FileId, u32),
    /// Nested-object simple-name aliases, keyed by enclosing class name.
    nested_object_aliases: runtime.NameHashMap(runtime.NameHashMap([]const u8)),
    /// Qualified nested class (`Outer.Inner`) -> mangled lift name, for nested classes the lift renamed.
    /// A qualified type reference resolves through this, never to a same-simple-name top-level class.
    mangled_nested: runtime.NameHashMap([]const u8),
    /// `(class, member)` -> `Const` for a class or companion `const val`.
    class_const_inits: StrPairMap(Const),
    /// Top-level property simple name -> every declaration of it, with FQN and package. A bare read
    /// ranks scope tiers like a bare call: a declaration only in an unimported package is unresolved.
    top_level_prop_pkgs: runtime.NameHashMap(std.ArrayList(PropDecl)),
    /// Top-level property FQN -> declared type head, as annotated; unannotated declarations record none.
    top_level_prop_type_heads: runtime.NameHashMap([]const u8),
    /// Same key with the full declared type, which alone says what iterating or indexing yields.
    top_level_prop_type_refs: runtime.NameHashMap(TypeRef),
    /// Top-level property FQN -> the simple name its UNANNOTATED initializer calls, resolved to a head
    /// only at query time, when a same-named user function is visible and can instead make it ambiguous.
    top_level_prop_init_callees: runtime.NameHashMap([]const u8),
    /// Top-level extension properties whose values are callable: `recv.p(args)` is a read plus `invoke`.
    callable_extension_props: runtime.NameHashMap(std.ArrayList(CallableExtensionProp)),
    /// Top-level property -> 0-arg getter `FuncId`; a `LoadGlobal` of the name re-invokes it per read.
    top_level_prop_getters: runtime.NameHashMap(FuncId),
    /// Top-level `var` custom setters: a `StoreGlobal` invokes the thunk, whose own `field =` write
    /// lands on the `__klio_topfield__<name>` storage binding.
    top_level_prop_setters: runtime.NameHashMap(FuncId),
    /// Top-level property -> its index in the root scope's slot table: every plain stored property
    /// (an initializer, no accessor, delegate or `lateinit`) declared once under its simple name.
    /// `ambiguous_slot` marks a name two declarations share, which no site binds.
    top_level_prop_slots: runtime.NameHashMap(u32),
    top_level_prop_slot_count: u32 = 0,

    allocator: Allocator,

    pub const ambiguous_slot: u32 = std.math.maxInt(u32);

    pub const TypeAliasShape = struct {
        type_params: []const []const u8,
        target: TypeRef,
    };

    pub const PropDecl = struct {
        fqn: []const u8,
        package: []const u8,
    };

    pub const CallableExtensionProp = struct {
        fqn: []const u8,
        package: []const u8,
        receiver: []const u8,
        file: FileId,
        value_arity: u16,
        is_private: bool,
    };

    /// One non-wildcard import: the full dotted path (owned by the registry allocator) and the same
    /// path as segments (an owned slice of name slices borrowed from the AST).
    pub const ImportPath = struct {
        fqn: []const u8,
        segs: []const []const u8,
    };

    pub const TypeParamBound = struct {
        param: []const u8,
        bound: []const u8,
        /// False when the string-only record dropped intersection or structural detail: no negative proof.
        complete: bool = true,
        /// True when `bound` still names the single classifier the parameter is bounded by, even with its
        /// type ARGUMENTS dropped: enough to answer which class owns a member call on the parameter.
        head_only: bool = true,
        /// The bound's type-argument heads, kept ONLY when every argument is concrete
        /// (`T : Iterable<String>` keeps ["String"]; `C : MutableCollection<in T>` keeps nothing).
        args: []const []const u8 = &.{},
    };

    pub const HierarchyShadowSet = struct {
        names: runtime.NameHashMap(void),
        complete: bool,
    };

    pub const MemberTrailingLambdaShape = struct {
        /// Bit `n` is set when `n` positional user arguments, trailing lambda included, can bind this.
        accepted_arities: u64,
        value_arity: i16,
        receiver_head: ?[]const u8,
    };

    pub fn init(allocator: Allocator) ModuleRegistry {
        return .{
            .companion_singletons = runtime.NameHashMap([]const u8).init(allocator),
            .host_shadowed_fqns = runtime.NameHashMap(void).init(allocator),
            .enclosing_class = runtime.NameHashMap([]const u8).init(allocator),
            .func_type_params = std.AutoHashMap(FuncId, std.ArrayList([]const u8)).init(allocator),
            .func_type_param_bounds = std.AutoHashMap(FuncId, []const TypeParamBound).init(allocator),
            .class_type_param_bounds = runtime.NameHashMap([]const TypeParamBound).init(allocator),
            .top_level_delegated_props = runtime.NameHashMap(void).init(allocator),
            .top_level_lateinit_props = runtime.NameHashMap(void).init(allocator),
            .hierarchy_methods = runtime.NameHashMap(runtime.NameHashMap(void)).init(allocator),
            .hierarchy_shadow_names = runtime.NameHashMap(HierarchyShadowSet).init(allocator),
            .member_trailing_lambda_shapes = StrPairMap(std.ArrayList(MemberTrailingLambdaShape)).init(allocator),
            .private_shadow_props = runtime.NameHashMap(void).init(allocator),
            .override_cell_props = runtime.NameHashMap(void).init(allocator),
            .member_method_fids = runtime.NameHashMap(FuncId).init(allocator),
            .member_method_ambiguous = runtime.NameHashMap(void).init(allocator),
            .member_fids_by_name = runtime.NameHashMap(std.ArrayList(FuncId)).init(allocator),
            .this_labels = runtime.NameHashMap([]const u8).init(allocator),
            .class_member_names = runtime.NameHashMap(void).init(allocator),
            .class_super_names = runtime.NameHashMap([]const []const u8).init(allocator),
            .delegated_body_props = StrPairSet.init(allocator),
            .subclass_declares_prop = runtime.NameHashMap(void).init(allocator),
            .recv_fn_props = StrPairMap([]const u8).init(allocator),
            .class_prop_type_heads = StrPairMap([]const u8).init(allocator),
            .class_prop_type_refs = StrPairMap(TypeRef).init(allocator),
            .ext_prop_type_heads = StrPairMap([]const u8).init(allocator),
            .member_ext_owner_class = std.AutoHashMap(FuncId, []const u8).init(allocator),
            .private_fn_files = std.AutoHashMap(FuncId, FileId).init(allocator),
            .iface_member_ext_recv = StrPairMap([]const u8).init(allocator),
            .iface_member_ctx_types = StrPairMap([]const u8).init(allocator),
            .abstract_member_arity = StrPairMap(u64).init(allocator),
            .top_level_const_vals = runtime.NameHashMap(Const).init(allocator),
            .local_fn_defaults = std.AutoHashMap(FuncId, std.ArrayList(?FuncId)).init(allocator),
            .abstract_member_defaults = StrPairMap(std.ArrayList(?FuncId)).init(allocator),
            .type_aliases = runtime.NameHashMap([]const u8).init(allocator),
            .type_alias_types = runtime.NameHashMap(TypeAliasShape).init(allocator),
            .type_alias_simple = runtime.NameHashMap(void).init(allocator),
            .recv_fn_aliases = runtime.NameHashMap(u8).init(allocator),
            .import_aliases = std.AutoHashMap(FileId, runtime.NameHashMap(std.ArrayList(ImportPath))).init(allocator),
            .import_alias_bloom = std.AutoHashMap(FileId, u64).init(allocator),
            .import_wildcards = std.AutoHashMap(FileId, std.ArrayList([]const u8)).init(allocator),
            .file_packages = std.AutoHashMap(FileId, []const u8).init(allocator),
            .file_modules = std.AutoHashMap(FileId, u32).init(allocator),
            .nested_object_aliases = runtime.NameHashMap(runtime.NameHashMap([]const u8)).init(allocator),
            .mangled_nested = runtime.NameHashMap([]const u8).init(allocator),
            .class_const_inits = StrPairMap(Const).init(allocator),
            .top_level_prop_pkgs = runtime.NameHashMap(std.ArrayList(PropDecl)).init(allocator),
            .top_level_prop_type_heads = runtime.NameHashMap([]const u8).init(allocator),
            .top_level_prop_type_refs = runtime.NameHashMap(TypeRef).init(allocator),
            .top_level_prop_init_callees = runtime.NameHashMap([]const u8).init(allocator),
            .callable_extension_props = runtime.NameHashMap(std.ArrayList(CallableExtensionProp)).init(allocator),
            .top_level_prop_getters = runtime.NameHashMap(FuncId).init(allocator),
            .top_level_prop_setters = runtime.NameHashMap(FuncId).init(allocator),
            .top_level_prop_slots = runtime.NameHashMap(u32).init(allocator),
            .allocator = allocator,
        };
    }

    /// The bit an import leaf claims in its file's bloom. Cheap on purpose: the
    /// point is to answer without hashing the name.
    pub fn importAliasBit(name: []const u8) u64 {
        if (name.len == 0) return 0;
        const first: u64 = name[0];
        const last: u64 = name[name.len - 1];
        const h = (@as(u64, name.len) *% 131) ^ (first *% 7) ^ (last *% 17);
        return @as(u64, 1) << @truncate(h & 63);
    }

    /// The one way to record an import leaf, so the bloom cannot fall behind the
    /// map it filters: a missing bit would hide an import that is really there.
    pub fn noteImportAliasName(self: *ModuleRegistry, file: FileId, name: []const u8) !void {
        const gop = try self.import_alias_bloom.getOrPut(file);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* |= importAliasBit(name);
    }

    /// The `this@<Class>` label for `class_name`, owned by the registry.
    pub fn thisLabelFor(self: *ModuleRegistry, class_name: []const u8) Allocator.Error![]const u8 {
        const gop = try self.this_labels.getOrPut(class_name);
        if (!gop.found_existing) gop.value_ptr.* = try std.fmt.allocPrint(self.allocator, "this@{s}", .{class_name});
        return gop.value_ptr.*;
    }

    /// The one way to register a structural alias, so the simple-name index
    /// cannot drift from the keys it indexes.
    pub fn putTypeAliasType(self: *ModuleRegistry, key: []const u8, shape: TypeAliasShape) !void {
        try self.type_alias_types.put(key, shape);
        const simple = if (std.mem.lastIndexOfScalar(u8, key, '.')) |dot| key[dot + 1 ..] else key;
        try self.type_alias_simple.put(simple, {});
    }

    pub fn deinit(self: *ModuleRegistry) void {
        const a = self.allocator;
        self.object_names.deinit(a);
        self.companion_singletons.deinit();
        self.enclosing_class.deinit();
        {
            var it = self.func_type_params.valueIterator();
            while (it.next()) |list| list.deinit(a);
            self.func_type_params.deinit();
        }
        {
            var it = self.func_type_param_bounds.valueIterator();
            while (it.next()) |list| a.free(list.*);
            self.func_type_param_bounds.deinit();
        }
        {
            var it = self.class_type_param_bounds.valueIterator();
            while (it.next()) |list| a.free(list.*);
            self.class_type_param_bounds.deinit();
        }
        self.top_level_delegated_props.deinit();
        self.top_level_lateinit_props.deinit();
        {
            self.private_shadow_props.deinit();
            self.override_cell_props.deinit();
        }
        {
            var itsn = self.hierarchy_shadow_names.valueIterator();
            while (itsn.next()) |v| v.names.deinit();
            self.hierarchy_shadow_names.deinit();
        }
        {
            var it = self.member_trailing_lambda_shapes.valueIterator();
            while (it.next()) |list| list.deinit(a);
            self.member_trailing_lambda_shapes.deinit();
        }
        {
            var it = self.hierarchy_methods.valueIterator();
            while (it.next()) |inner| inner.deinit();
            self.hierarchy_methods.deinit();
        }
        {
            self.member_method_ambiguous.deinit();
            var it = self.member_method_fids.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            self.member_method_fids.deinit();
        }
        {
            var it = self.member_fids_by_name.valueIterator();
            while (it.next()) |list| list.deinit(self.allocator);
            self.member_fids_by_name.deinit();
        }
        {
            var it = self.this_labels.valueIterator();
            while (it.next()) |v| self.allocator.free(v.*);
            self.this_labels.deinit();
        }
        self.class_member_names.deinit();
        self.host_shadowed_fqns.deinit();
        {
            var it = self.class_super_names.valueIterator();
            while (it.next()) |names| a.free(names.*);
            self.class_super_names.deinit();
        }
        self.dropEvidenceSupers();
        self.evidence_supers.deinit(self.allocator);
        self.delegated_body_props.deinit();
        self.subclass_declares_prop.deinit();
        self.recv_fn_props.deinit();
        self.class_prop_type_heads.deinit();
        self.class_prop_type_refs.deinit();
        self.ext_prop_type_heads.deinit();
        self.member_ext_owner_class.deinit();
        self.private_fn_files.deinit();
        self.iface_member_ext_recv.deinit();
        self.iface_member_ctx_types.deinit();
        self.abstract_member_arity.deinit();
        self.top_level_const_vals.deinit();
        {
            var it = self.local_fn_defaults.valueIterator();
            while (it.next()) |list| list.deinit(a);
            self.local_fn_defaults.deinit();
        }
        {
            var it = self.abstract_member_defaults.valueIterator();
            while (it.next()) |list| list.deinit(a);
            self.abstract_member_defaults.deinit();
        }
        self.type_aliases.deinit();
        self.import_alias_bloom.deinit();
        self.type_alias_types.deinit();
        self.type_alias_simple.deinit();
        self.recv_fn_aliases.deinit();
        {
            var it = self.import_aliases.valueIterator();
            while (it.next()) |inner| {
                var inner_it = inner.valueIterator();
                while (inner_it.next()) |paths| {
                    for (paths.items) |p| {
                        a.free(p.fqn);
                        a.free(p.segs);
                    }
                    paths.deinit(a);
                }
                inner.deinit();
            }
            self.import_aliases.deinit();
        }
        {
            var it = self.import_wildcards.valueIterator();
            while (it.next()) |list| {
                for (list.items) |path| a.free(path);
                list.deinit(a);
            }
            self.import_wildcards.deinit();
        }
        self.file_packages.deinit();
        self.file_modules.deinit();
        {
            var it = self.nested_object_aliases.valueIterator();
            while (it.next()) |inner| inner.deinit();
            self.nested_object_aliases.deinit();
        }
        self.mangled_nested.deinit();
        self.class_const_inits.deinit();
        {
            var it = self.top_level_prop_pkgs.valueIterator();
            while (it.next()) |list| list.deinit(a);
            self.top_level_prop_pkgs.deinit();
        }
        self.top_level_prop_type_heads.deinit();
        self.top_level_prop_type_refs.deinit();
        self.top_level_prop_init_callees.deinit();
        {
            var it = self.callable_extension_props.valueIterator();
            while (it.next()) |list| list.deinit(a);
            self.callable_extension_props.deinit();
        }
        self.top_level_prop_getters.deinit();
        self.top_level_prop_setters.deinit();
        self.top_level_prop_slots.deinit();
    }

    pub fn noteClassChainChange(self: *ModuleRegistry) void {
        self.class_super_gen +%= 1;
    }

    pub fn dropEvidenceSupers(self: *ModuleRegistry) void {
        var it = self.evidence_supers.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.allocator);
            self.allocator.free(e.key_ptr.*);
        }
        self.evidence_supers.clearRetainingCapacity();
    }
};
