const std = @import("std");
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
    companion_singletons: std.StringHashMap([]const u8),
    /// Fqns whose installed host binding outranks any interpreted body (a pack's stub declarations).
    host_shadowed_fqns: std.StringHashMap(void),
    /// Inner class -> outer class name; resolves `this@Outer` and outer-chain field reads.
    enclosing_class: std.StringHashMap([]const u8),
    /// Per-function type-parameter names in source order; reified dispatch binds each.
    func_type_params: std.AutoHashMap(FuncId, std.ArrayList([]const u8)),
    /// Declared upper bounds of a function's type parameters, one entry per (param, bound).
    func_type_param_bounds: std.AutoHashMap(FuncId, []const TypeParamBound),
    /// Declared upper bounds of each class's type parameters, keyed by class simple name.
    /// Dispatch disproves an argument whose type violates the bound on a class parameter.
    class_type_param_bounds: std.StringHashMap([]const TypeParamBound),
    /// Top-level properties declared `by`; reads and writes route through `getValue`/`setValue`.
    top_level_delegated_props: std.StringHashMap(void),
    /// Top-level `lateinit var` names: no binding until the first write, so a read that finds
    /// none throws `UninitializedPropertyAccessException` and `isInitialized` answers from it.
    top_level_lateinit_props: std.StringHashMap(void),
    /// Class -> member FUNCTION names declared or inherited transitively; Kotlin keeps the namespaces apart.
    hierarchy_methods: std.StringHashMap(std.StringHashMap(void)),
    /// Private stored properties that shadow a same-name supertype declaration, keyed
    /// "Class\x1fprop". Each gets its own cell, addressed owner-mangled. Lowering-only.
    private_shadow_props: std.StringHashMap(void),
    /// Initialized `override val/var` whose supertype also stores the name, keyed "Class\x1fprop".
    /// Each class keeps its own cell: a read takes the most-derived, `super.x` the base. Lowering-only.
    override_cell_props: std.StringHashMap(void),
    /// Per-class transitive member-name set for the member-shadow gate, plus whether the supertype
    /// chain resolved; an incomplete set cannot prove non-shadowability. Lowering-only.
    hierarchy_shadow_names: std.StringHashMap(HierarchyShadowSet),
    /// (declaring class, method) -> trailing-lambda shapes, collected from every member declaration
    /// before any body lowers, so receiver-lambda typing does not depend on source order.
    member_trailing_lambda_shapes: StrPairMap(std.ArrayList(MemberTrailingLambdaShape)),
    /// `"<class>\x00<method>\x00<userArity>"` -> the lowered method's FuncId, filled as each body
    /// lowers, so a body reaches a sibling member's signature before `Class.methods` is patched.
    member_method_fids: std.StringHashMap(FuncId),
    /// Every member name declared by any class: only these can be shadowed by a runtime receiver.
    class_member_names: std.StringHashMap(void),
    /// Class -> transitive supertype simple names, nearest first, recorded from the AST before body
    /// lowering so extension receivers rank while the `Class.supertypes` slots are still filling.
    class_super_names: std.StringHashMap([]const []const u8),
    /// Body-property `(class, prop)` pairs declared with `by`.
    delegated_body_props: StrPairSet,
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
    top_level_const_vals: std.StringHashMap(Const),
    /// Per-local-function default-arg thunks keyed by body `FuncId`; a null slot is a required parameter.
    local_fn_defaults: std.AutoHashMap(FuncId, std.ArrayList(?FuncId)),
    /// Default-arg thunks for bodyless members, keyed `(class, method)`.
    abstract_member_defaults: StrPairMap(std.ArrayList(?FuncId)),
    /// `typealias Name = Target` -> `Name` mapped to `Target`'s simple head name.
    type_aliases: std.StringHashMap([]const u8),
    /// Structural alias targets used by static applicability proofs.
    type_alias_types: std.StringHashMap(TypeAliasShape),
    /// Function-type aliases whose target declares an extension receiver -> the target's VALUE-parameter
    /// count. The `Function{N}` tag in `type_aliases` drops the receiver; a bare call still binds `this`.
    recv_fn_aliases: std.StringHashMap(u8),
    /// Per-file non-wildcard import leaf -> every import bound to that leaf, in declaration order:
    /// named imports are file-scoped, and same-leaf imports all stay in scope (ambiguity at the use site).
    import_aliases: std.AutoHashMap(FileId, std.StringHashMap(std.ArrayList(ImportPath))),
    /// Per-file wildcard-import packages, dotted and owned; `import pkg.*` outranks the built-ins.
    import_wildcards: std.AutoHashMap(FileId, std.ArrayList([]const u8)),
    /// Per-file declared package. A spliced inline body carries the DONOR file's spans, so bare-call
    /// scope follows the span's file and its imports, not the recipient function's package.
    file_packages: std.AutoHashMap(FileId, []const u8),
    /// Kotlin compilation-module identity per file: `internal` is visible only within one identity.
    file_modules: std.AutoHashMap(FileId, u32),
    /// Nested-object simple-name aliases, keyed by enclosing class name.
    nested_object_aliases: std.StringHashMap(std.StringHashMap([]const u8)),
    /// Qualified nested class (`Outer.Inner`) -> mangled lift name, for nested classes the lift renamed.
    /// A qualified type reference resolves through this, never to a same-simple-name top-level class.
    mangled_nested: std.StringHashMap([]const u8),
    /// `(class, member)` -> `Const` for a class or companion `const val`.
    class_const_inits: StrPairMap(Const),
    /// Top-level property simple name -> every declaration of it, with FQN and package. A bare read
    /// ranks scope tiers like a bare call: a declaration only in an unimported package is unresolved.
    top_level_prop_pkgs: std.StringHashMap(std.ArrayList(PropDecl)),
    /// Top-level property FQN -> declared type head, as annotated; unannotated declarations record none.
    top_level_prop_type_heads: std.StringHashMap([]const u8),
    /// Same key with the full declared type, which alone says what iterating or indexing yields.
    top_level_prop_type_refs: std.StringHashMap(TypeRef),
    /// Top-level property FQN -> the simple name its UNANNOTATED initializer calls, resolved to a head
    /// only at query time, when a same-named user function is visible and can instead make it ambiguous.
    top_level_prop_init_callees: std.StringHashMap([]const u8),
    /// Top-level extension properties whose values are callable: `recv.p(args)` is a read plus `invoke`.
    callable_extension_props: std.StringHashMap(std.ArrayList(CallableExtensionProp)),
    /// Top-level property -> 0-arg getter `FuncId`; a `LoadGlobal` of the name re-invokes it per read.
    top_level_prop_getters: std.StringHashMap(FuncId),
    /// Top-level `var` custom setters: a `StoreGlobal` invokes the thunk, whose own `field =` write
    /// lands on the `__klio_topfield__<name>` storage binding.
    top_level_prop_setters: std.StringHashMap(FuncId),

    allocator: Allocator,

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
        names: std.StringHashMap(void),
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
            .companion_singletons = std.StringHashMap([]const u8).init(allocator),
            .host_shadowed_fqns = std.StringHashMap(void).init(allocator),
            .enclosing_class = std.StringHashMap([]const u8).init(allocator),
            .func_type_params = std.AutoHashMap(FuncId, std.ArrayList([]const u8)).init(allocator),
            .func_type_param_bounds = std.AutoHashMap(FuncId, []const TypeParamBound).init(allocator),
            .class_type_param_bounds = std.StringHashMap([]const TypeParamBound).init(allocator),
            .top_level_delegated_props = std.StringHashMap(void).init(allocator),
            .top_level_lateinit_props = std.StringHashMap(void).init(allocator),
            .hierarchy_methods = std.StringHashMap(std.StringHashMap(void)).init(allocator),
            .hierarchy_shadow_names = std.StringHashMap(HierarchyShadowSet).init(allocator),
            .member_trailing_lambda_shapes = StrPairMap(std.ArrayList(MemberTrailingLambdaShape)).init(allocator),
            .private_shadow_props = std.StringHashMap(void).init(allocator),
            .override_cell_props = std.StringHashMap(void).init(allocator),
            .member_method_fids = std.StringHashMap(FuncId).init(allocator),
            .class_member_names = std.StringHashMap(void).init(allocator),
            .class_super_names = std.StringHashMap([]const []const u8).init(allocator),
            .delegated_body_props = StrPairSet.init(allocator),
            .recv_fn_props = StrPairMap([]const u8).init(allocator),
            .class_prop_type_heads = StrPairMap([]const u8).init(allocator),
            .class_prop_type_refs = StrPairMap(TypeRef).init(allocator),
            .ext_prop_type_heads = StrPairMap([]const u8).init(allocator),
            .member_ext_owner_class = std.AutoHashMap(FuncId, []const u8).init(allocator),
            .private_fn_files = std.AutoHashMap(FuncId, FileId).init(allocator),
            .iface_member_ext_recv = StrPairMap([]const u8).init(allocator),
            .iface_member_ctx_types = StrPairMap([]const u8).init(allocator),
            .abstract_member_arity = StrPairMap(u64).init(allocator),
            .top_level_const_vals = std.StringHashMap(Const).init(allocator),
            .local_fn_defaults = std.AutoHashMap(FuncId, std.ArrayList(?FuncId)).init(allocator),
            .abstract_member_defaults = StrPairMap(std.ArrayList(?FuncId)).init(allocator),
            .type_aliases = std.StringHashMap([]const u8).init(allocator),
            .type_alias_types = std.StringHashMap(TypeAliasShape).init(allocator),
            .recv_fn_aliases = std.StringHashMap(u8).init(allocator),
            .import_aliases = std.AutoHashMap(FileId, std.StringHashMap(std.ArrayList(ImportPath))).init(allocator),
            .import_wildcards = std.AutoHashMap(FileId, std.ArrayList([]const u8)).init(allocator),
            .file_packages = std.AutoHashMap(FileId, []const u8).init(allocator),
            .file_modules = std.AutoHashMap(FileId, u32).init(allocator),
            .nested_object_aliases = std.StringHashMap(std.StringHashMap([]const u8)).init(allocator),
            .mangled_nested = std.StringHashMap([]const u8).init(allocator),
            .class_const_inits = StrPairMap(Const).init(allocator),
            .top_level_prop_pkgs = std.StringHashMap(std.ArrayList(PropDecl)).init(allocator),
            .top_level_prop_type_heads = std.StringHashMap([]const u8).init(allocator),
            .top_level_prop_type_refs = std.StringHashMap(TypeRef).init(allocator),
            .top_level_prop_init_callees = std.StringHashMap([]const u8).init(allocator),
            .callable_extension_props = std.StringHashMap(std.ArrayList(CallableExtensionProp)).init(allocator),
            .top_level_prop_getters = std.StringHashMap(FuncId).init(allocator),
            .top_level_prop_setters = std.StringHashMap(FuncId).init(allocator),
            .allocator = allocator,
        };
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
            var it = self.member_method_fids.keyIterator();
            while (it.next()) |k| self.allocator.free(k.*);
            self.member_method_fids.deinit();
        }
        self.class_member_names.deinit();
        self.host_shadowed_fqns.deinit();
        {
            var it = self.class_super_names.valueIterator();
            while (it.next()) |names| a.free(names.*);
            self.class_super_names.deinit();
        }
        self.delegated_body_props.deinit();
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
        self.type_alias_types.deinit();
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
    }

    /// Clone for extension: outer container spines are copied onto `a`, while inner containers and
    /// value slices are SHARED with the original by value-copy. Sound because the extending build only
    /// inserts new keys and replaces whole entries, never appending into a container reached by an old key.
    pub fn cloneForExtend(self: *const ModuleRegistry, a: Allocator) Allocator.Error!ModuleRegistry {
        var out = ModuleRegistry.init(a);
        try out.object_names.appendSlice(a, self.object_names.items);
        {
            var it = self.companion_singletons.iterator();
            while (it.next()) |e| try out.companion_singletons.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.host_shadowed_fqns.iterator();
            while (it.next()) |e| try out.host_shadowed_fqns.put(e.key_ptr.*, {});
        }
        {
            var it = self.enclosing_class.iterator();
            while (it.next()) |e| try out.enclosing_class.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.func_type_params.iterator();
            while (it.next()) |e| {
                var list: std.ArrayList([]const u8) = .empty;
                try list.appendSlice(a, e.value_ptr.items);
                try out.func_type_params.put(e.key_ptr.*, list);
            }
        }
        {
            var it = self.func_type_param_bounds.iterator();
            while (it.next()) |e| try out.func_type_param_bounds.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.class_type_param_bounds.iterator();
            while (it.next()) |e| try out.class_type_param_bounds.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.top_level_delegated_props.keyIterator();
            while (it.next()) |k| try out.top_level_delegated_props.put(k.*, {});
        }
        {
            var it = self.top_level_lateinit_props.keyIterator();
            while (it.next()) |k| try out.top_level_lateinit_props.put(k.*, {});
        }
        {
            var it = self.hierarchy_methods.iterator();
            while (it.next()) |e| try out.hierarchy_methods.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.member_trailing_lambda_shapes.iterator();
            while (it.next()) |e| {
                var list: std.ArrayList(MemberTrailingLambdaShape) = .empty;
                try list.appendSlice(a, e.value_ptr.items);
                try out.member_trailing_lambda_shapes.put(e.key_ptr.*, list);
            }
        }
        {
            var it = self.member_method_fids.iterator();
            while (it.next()) |e| try out.member_method_fids.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.private_shadow_props.keyIterator();
            while (it.next()) |k| try out.private_shadow_props.put(k.*, {});
        }
        {
            var it = self.override_cell_props.keyIterator();
            while (it.next()) |k| try out.override_cell_props.put(k.*, {});
        }
        {
            var it = self.hierarchy_shadow_names.iterator();
            while (it.next()) |e| try out.hierarchy_shadow_names.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.class_member_names.keyIterator();
            while (it.next()) |k| try out.class_member_names.put(k.*, {});
        }
        {
            var it = self.class_super_names.iterator();
            while (it.next()) |e| try out.class_super_names.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.delegated_body_props.keyIterator();
            while (it.next()) |k| try out.delegated_body_props.put(k.*, {});
        }
        {
            var it = self.class_prop_type_heads.iterator();
            while (it.next()) |e| try out.class_prop_type_heads.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.class_prop_type_refs.iterator();
            while (it.next()) |e| try out.class_prop_type_refs.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.ext_prop_type_heads.iterator();
            while (it.next()) |e| try out.ext_prop_type_heads.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.member_ext_owner_class.iterator();
            while (it.next()) |e| try out.member_ext_owner_class.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.private_fn_files.iterator();
            while (it.next()) |e| try out.private_fn_files.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.iface_member_ext_recv.iterator();
            while (it.next()) |e| try out.iface_member_ext_recv.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.iface_member_ctx_types.iterator();
            while (it.next()) |e| try out.iface_member_ctx_types.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.top_level_const_vals.iterator();
            while (it.next()) |e| try out.top_level_const_vals.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.local_fn_defaults.iterator();
            while (it.next()) |e| {
                var list: std.ArrayList(?FuncId) = .empty;
                try list.appendSlice(a, e.value_ptr.items);
                try out.local_fn_defaults.put(e.key_ptr.*, list);
            }
        }
        {
            var it = self.abstract_member_defaults.iterator();
            while (it.next()) |e| {
                var list: std.ArrayList(?FuncId) = .empty;
                try list.appendSlice(a, e.value_ptr.items);
                try out.abstract_member_defaults.put(e.key_ptr.*, list);
            }
        }
        {
            var it = self.type_aliases.iterator();
            while (it.next()) |e| try out.type_aliases.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.type_alias_types.iterator();
            while (it.next()) |e| try out.type_alias_types.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.import_aliases.iterator();
            while (it.next()) |e| try out.import_aliases.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.import_wildcards.iterator();
            while (it.next()) |e| try out.import_wildcards.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.file_packages.iterator();
            while (it.next()) |e| try out.file_packages.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.file_modules.iterator();
            while (it.next()) |e| try out.file_modules.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.nested_object_aliases.iterator();
            while (it.next()) |e| try out.nested_object_aliases.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.mangled_nested.iterator();
            while (it.next()) |e| try out.mangled_nested.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.class_const_inits.iterator();
            while (it.next()) |e| try out.class_const_inits.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.top_level_prop_pkgs.iterator();
            while (it.next()) |e| {
                var list: std.ArrayList(PropDecl) = .empty;
                try list.appendSlice(a, e.value_ptr.items);
                try out.top_level_prop_pkgs.put(e.key_ptr.*, list);
            }
        }
        {
            var it = self.top_level_prop_type_heads.iterator();
            while (it.next()) |e| try out.top_level_prop_type_heads.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.top_level_prop_type_refs.iterator();
            while (it.next()) |e| try out.top_level_prop_type_refs.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.top_level_prop_init_callees.iterator();
            while (it.next()) |e| try out.top_level_prop_init_callees.put(e.key_ptr.*, e.value_ptr.*);
        }
        {
            var it = self.callable_extension_props.iterator();
            while (it.next()) |e| {
                var list: std.ArrayList(CallableExtensionProp) = .empty;
                try list.appendSlice(a, e.value_ptr.items);
                try out.callable_extension_props.put(e.key_ptr.*, list);
            }
        }
        {
            var it = self.top_level_prop_getters.iterator();
            while (it.next()) |e| try out.top_level_prop_getters.put(e.key_ptr.*, e.value_ptr.*);
            var sit = self.top_level_prop_setters.iterator();
            while (sit.next()) |e| try out.top_level_prop_setters.put(e.key_ptr.*, e.value_ptr.*);
        }
        return out;
    }
};
