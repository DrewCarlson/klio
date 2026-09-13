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

/// Module-scoped side tables consumed by the Vm at dispatch time.
/// Populated by `interp_ir`'s build pass; serialized into pack files
/// so a pre-built pack can ship its registry alongside the frozen IR
/// module.
pub const ModuleRegistry = struct {
    /// Names of `object` singletons. The Vm allocates one instance
    /// per name at startup and publishes it as a global so bare-name
    /// reads resolve.
    object_names: std.ArrayList([]const u8) = .empty,
    /// Outer-class → companion-singleton global name. Reads on
    /// `Foo.X` fall through to the companion instance when `X` is
    /// not a member of `Foo` itself.
    companion_singletons: std.StringHashMap([]const u8),
    /// Fqns whose installed HOST BINDING is authoritative over any
    /// interpreted body (a pack's stub declarations — atomicfu's atomics).
    /// Populated at bindings install from the non-stdlib overlay keys; a
    /// static member bind must not commit a BODY-BEARING target listed
    /// here — the runtime walk's binding preference arbitrates instead.
    host_shadowed_fqns: std.StringHashMap(void),
    /// Inner class → outer class name. Resolves `this@Outer` and
    /// outer-chain field reads for nested classes lifted to top level.
    enclosing_class: std.StringHashMap([]const u8),
    /// Per-function type-parameter names (in source order). Used by
    /// reified-call dispatch to bind `T` → `Value.Class(arg)` as a
    /// global for the call's lifetime.
    func_type_params: std.AutoHashMap(FuncId, std.ArrayList([]const u8)),
    /// Declared upper bounds of a function's type parameters (`<T : Number>`
    /// inline bounds plus `where` clauses), one entry per (param, bound)
    /// pair. The strict extension-receiver prover consults these: a
    /// bounded type-parameter receiver is proven only when the actual
    /// receiver satisfies every bound; an unbounded one accepts anything.
    func_type_param_bounds: std.AutoHashMap(FuncId, []const TypeParamBound),
    /// Declared upper bounds of each CLASS's type parameters
    /// (`class EnumEntriesList<T : Enum<T>>`), keyed by class simple name.
    /// Method dispatch disproves a wrong-typed argument against a param
    /// declared as the class type param (the Kotlin collection-stub
    /// bridge: `indexOf(nonEnum)` on an `EnumEntries` answers -1 through
    /// the inherited implementation instead of running the override).
    class_type_param_bounds: std.StringHashMap([]const TypeParamBound),
    /// Top-level property names declared with `by <delegate>`.
    /// Reads/writes route through the stored delegate's `getValue` /
    /// `setValue` methods.
    top_level_delegated_props: std.StringHashMap(void),
    /// Top-level `lateinit var` names. Such a property has no initializer
    /// and no global binding until its first write; a read that finds no
    /// binding throws `UninitializedPropertyAccessException`, and
    /// `::name.isInitialized` answers from the binding's presence.
    top_level_lateinit_props: std.StringHashMap(void),
    /// Class simple name → the set of member *function* names it
    /// declares or inherits (transitively over supertypes). Lets the
    /// lowerer honor Kotlin's separate function/property namespaces.
    hierarchy_methods: std.StringHashMap(std.StringHashMap(void)),
    /// Private stored properties that SHADOW a same-name declaration in a
    /// strict supertype, keyed "Class\x1fprop". Kotlin gives a shadow its
    /// own storage cell (a private base field and a private derived field
    /// are distinct); construction stores these under the owner-mangled
    /// key and the scope-qualified read/write paths address exactly that
    /// cell, so the base class's cell is never clobbered. Lowering-only.
    private_shadow_props: std.StringHashMap(void),
    /// Initialized `override val/var` properties whose supertype STORES the
    /// same name, keyed "Class\x1fprop". Each class keeps its own backing
    /// cell (JVM semantics): reads dispatch to the most-derived cell,
    /// `super.x` reads the base's plain cell. Lowering-only.
    override_cell_props: std.StringHashMap(void),
    /// Per-class transitive member-NAME set for the member-shadow gate —
    /// every kind a bare name could bind through the implicit receiver —
    /// plus whether the supertype chain fully resolved (`complete`). An
    /// incomplete set must not prove non-shadowability. Lowering-only.
    hierarchy_shadow_names: std.StringHashMap(HierarchyShadowSet),
    /// `(declaring class, method name)` → trailing-lambda shapes collected
    /// from every member declaration before any body lowers. This keeps
    /// receiver-lambda typing independent of source order when a subclass
    /// calls an inherited method whose body has not produced a `FuncId` yet.
    /// Lowering-only; installed packs use their serialized lowered methods.
    member_trailing_lambda_shapes: StrPairMap(std.ArrayList(MemberTrailingLambdaShape)),
    /// `"<class>\x00<method>\x00<userArity>"` → the lowered method's FuncId,
    /// populated incrementally as each class's method bodies are lowered. Lets
    /// a method body statically reach a SIBLING member method's lowered
    /// signature (e.g. the declared parameter types of `testPlus`) at lower
    /// time, when `Class.methods` is not yet patched and members are absent
    /// from the simple-name / fqn indexes. Owner-scoped, so a same-named member
    /// in an unrelated class is never confused for it.
    member_method_fids: std.StringHashMap(FuncId),
    /// Every member name (function, property, primary-ctor property,
    /// companion member) declared by ANY class in the program. A bare
    /// name in a receiver context can only be shadowed by a runtime
    /// receiver when some class declares a member of that name, so
    /// lowering keeps the static classification for everything else.
    class_member_names: std.StringHashMap(void),
    /// Class simple name → its transitive supertype simple names,
    /// nearest first (each direct supertype followed by its own chain).
    /// Recorded from the AST hierarchy before body lowering, so a
    /// method body can rank extension receivers against the enclosing
    /// class — including extensions declared on a base class — while
    /// the IR-side `Class.supertypes` slots are still being filled.
    class_super_names: std.StringHashMap([]const []const u8),
    /// Body-property `(class, prop)` pairs declared with `by`.
    delegated_body_props: StrPairSet,
    /// (class, property) pairs whose declared type is a RECEIVER function
    /// type (`suspend Scope.() -> Unit`): a bare invocation of the stored
    /// value inside a receiver context binds the implicit `this` as the
    /// lambda's receiver (`_deprecatedPointerInputHandler!!()` inside the
    /// pointer-input node runs the handler on the node's scope). The value
    /// is the DECLARED receiver type's simple head (`Scope`), so dispatch
    /// binds the innermost implicit receiver of that type — the owning
    /// instance when it implements the head, an enclosing receiver
    /// otherwise (`block()` inside `with(cacheDrawScope) { … }` where
    /// `block: CacheDrawScope.() -> DrawResult` lives on the node).
    recv_fn_props: StrPairMap([]const u8),
    /// `(class simple name, property name)` → the property's DECLARED
    /// type head, with a class type-parameter name substituted by its
    /// bound's head (`data: T` in `IterableTests<T : Iterable<String>>`
    /// records `Iterable`). Consumed by the binop/member lowering so a
    /// call on the property resolves against the static type, as
    /// kotlinc does.
    class_prop_type_heads: StrPairMap([]const u8),
    /// The same key, carrying the property's FULL declared type rather than
    /// its head — `val items: List<Named>` records `List<Named>`, not `List`.
    /// A head alone cannot answer what iterating or indexing the property
    /// yields, which left `items[0].tag()`, `for (i in items)` and
    /// `items.map { it.tag() }` with no receiver type in ordinary code.
    /// Borrowed from the lowering arena, like every other registry string.
    class_prop_type_refs: StrPairMap(TypeRef),
    /// `(extension-receiver head, property name)` -> declared type head for
    /// TOP-LEVEL extension properties (`val IntArray.indices: IntRange`
    /// records `(IntArray, indices) -> IntRange`). Recorded in the decl
    /// scan, before any body lowers, so a bare `indices` read inside an
    /// array extension body types statically even while the stdlib itself
    /// is still lowering.
    ext_prop_type_heads: StrPairMap([]const u8),
    /// `FuncId` → declaring-class simple name for *member extension
    /// functions* (`class C { fun R.f(...) { … } }`). Empty for
    /// top-level extensions.
    member_ext_owner_class: std.AutoHashMap(FuncId, []const u8),
    /// `FuncId` → declaring FILE of a `private` top-level function. Kotlin
    /// scopes a private top-level declaration to its file, so a dispatch
    /// walk must never pick a private extension from another file (a
    /// file-private `Rect.size()` capturing `LongSparseArray.size()`).
    private_fn_files: std.AutoHashMap(FuncId, FileId),
    /// (interface, method) → declared extension-receiver type head for
    /// ABSTRACT member-extension declarations (`fun interface
    /// MeasurePolicy { fun MeasureScope.measure(...) }`). The abstract
    /// slot lowers no func, so the SAM dispatch reads the receiver type
    /// here to bind the lambda's implicit `this`.
    iface_member_ext_recv: StrPairMap([]const u8),
    /// (interface, method) -> the method's declared `context(...)` parameter
    /// type names joined by `|`: a SAM conversion of the fun interface supplies
    /// each context from the call site's context scope as a leading argument.
    iface_member_ctx_types: StrPairMap([]const u8),
    /// (class simple name, member name) → arity BITMASK (bit n = declared
    /// with n params, capped at 63) for BODYLESS member declarations
    /// (abstract interface/class members). The abstract slot lowers no
    /// func and joins no class-row method list, so overload picks that
    /// must rank members above extensions (a bare `respond(a, b)` inside
    /// an `ApplicationCall` extension binding the interface's
    /// `respond(message, typeInfo)` member, never a reified 2-arg
    /// extension splice) consult this record.
    abstract_member_arity: StrPairMap(u64),
    /// Top-level `const val` literal values keyed by declaration FQN.
    /// Kotlin inlines compile-time constants at every reference, so the
    /// lowering reads the value here and emits the literal directly — a
    /// bare `Empty` inside androidx.collection can never be captured by a
    /// same-simple-name global another module published.
    top_level_const_vals: std.StringHashMap(Const),
    /// Per-local-function default-arg thunks. Keyed by the local fn's
    /// lowered body `FuncId`; each slot holds the `FuncId` of a 0-arg
    /// thunk producing that parameter's default, or `null` for a
    /// required param.
    local_fn_defaults: std.AutoHashMap(FuncId, std.ArrayList(?FuncId)),
    /// Default-arg thunks for *bodyless* (abstract / interface) member
    /// declarations, keyed by `(class simple name, method name)`.
    abstract_member_defaults: StrPairMap(std.ArrayList(?FuncId)),
    /// `typealias Name = Target` → `Name` ↦ `Target`'s simple head
    /// name.
    type_aliases: std.StringHashMap([]const u8),
    /// Structural alias targets used by static applicability proofs.
    type_alias_types: std.StringHashMap(TypeAliasShape),
    /// Function-type aliases whose target declares an extension RECEIVER
    /// (`typealias Workflow = suspend WScope.() -> Unit`) → the target's
    /// VALUE-parameter count. The `Function{N}` tag in `type_aliases`
    /// deliberately drops the receiver; a bare call through a param of
    /// such an alias must still bind the enclosing `this`.
    recv_fn_aliases: std.StringHashMap(u8),
    /// Per-file (`FileId`) non-wildcard import leaf → every import in
    /// the file bound to that leaf, in declaration order. Keyed by file
    /// because a Kotlin named import is file-scoped; a list because
    /// Kotlin keeps every same-leaf import in scope (a second import of
    /// the same leaf is an ambiguity at the use site, not a shadow).
    import_aliases: std.AutoHashMap(FileId, std.StringHashMap(std.ArrayList(ImportPath))),
    /// Per-file (`FileId`) wildcard-import package paths (dotted,
    /// owned). A `import pkg.*` makes every `pkg` declaration visible
    /// to the file, outranking the implicitly-imported built-ins in
    /// bare-call preference.
    import_wildcards: std.AutoHashMap(FileId, std.ArrayList([]const u8)),
    /// Per-file (`FileId`) declared package path. A spliced inline body
    /// carries the DONOR file's spans, so bare-call scope judgments must
    /// follow the span's file — its package and imports — not the
    /// recipient function's package.
    file_packages: std.AutoHashMap(FileId, []const u8),
    /// Kotlin compilation-module identity for each source file. `internal`
    /// declarations are visible across files carrying the same identity and
    /// inaccessible across dependency/program boundaries.
    file_modules: std.AutoHashMap(FileId, u32),
    /// Nested-object simple-name aliases, keyed by enclosing class
    /// name.
    nested_object_aliases: std.StringHashMap(std.StringHashMap([]const u8)),
    /// Qualified nested-class name (`Outer.Inner`) → mangled lift name,
    /// for nested classes the lift renamed (private, or colliding with
    /// a top-level type). A qualified type reference (`x is
    /// Outer.Inner`, `x as Outer.Inner`) resolves through this so it
    /// binds the lifted class, never a same-simple-name top-level one.
    mangled_nested: std.StringHashMap([]const u8),
    /// `(class_name, member_name) → Const` for class / companion
    /// `const val name = <literal>`.
    class_const_inits: StrPairMap(Const),
    /// Top-level (file-scope) property simple name → every declaration of
    /// that name, each carrying its FQN and declaring package. A bare read
    /// of such a property resolves under Kotlin scoping, so the lowerer
    /// ranks the read's tier the same way it ranks a bare call: a read
    /// whose only declaration is in an unimported package is unresolved.
    top_level_prop_pkgs: std.StringHashMap(std.ArrayList(PropDecl)),
    /// Top-level property FQN -> declared type head, so a bare read used as
    /// a RECEIVER (`asserter.assertEquals(...)`) types statically. Only
    /// annotated declarations record; the head is the annotation as written.
    top_level_prop_type_heads: std.StringHashMap([]const u8),
    /// The same key, carrying the FULL declared type where it has arguments
    /// (`val topItems: List<Named>`). The head alone cannot say what
    /// iterating or indexing the property yields.
    top_level_prop_type_refs: std.StringHashMap(TypeRef),
    /// Top-level property FQN -> the simple name its UNANNOTATED initializer
    /// calls (`private val base64EncodeMap = byteArrayOf(...)`). Resolved to
    /// a head only at query time, when every declaration is registered: a
    /// user function of the same name is then visible and either agrees or
    /// makes the answer ambiguous, so a shadowed factory cannot mistype the
    /// property.
    top_level_prop_init_callees: std.StringHashMap([]const u8),
    /// Top-level extension properties whose values are directly callable.
    /// Registered before body lowering so `receiver.property(args)` can be
    /// classified as a property read followed by `invoke`.
    callable_extension_props: std.StringHashMap(std.ArrayList(CallableExtensionProp)),
    /// Top-level property simple name → 0-arg getter `FuncId`, for a
    /// `val`/`var` declared with only a custom getter (no initializer,
    /// no backing field, no delegate). A `LoadGlobal` of such a name
    /// re-invokes the getter on every read.
    top_level_prop_getters: std.StringHashMap(FuncId),
    /// Top-level `var` custom setters. A `StoreGlobal` of the property
    /// name invokes the setter thunk; the thunk's own `field =` write
    /// lands on the `__klio_topfield__<name>` storage binding.
    top_level_prop_setters: std.StringHashMap(FuncId),

    allocator: Allocator,

    pub const TypeAliasShape = struct {
        type_params: []const []const u8,
        target: TypeRef,
    };

    /// One top-level property declaration's scoping identity.
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

    /// One non-wildcard import: its full dotted path (owned by the
    /// registry allocator) and the same path as segments (an owned
    /// slice of name slices borrowed from the AST).
    pub const ImportPath = struct {
        fqn: []const u8,
        segs: []const []const u8,
    };

    pub const TypeParamBound = struct {
        param: []const u8,
        bound: []const u8,
        /// False when the string-only record dropped intersection or
        /// structural type information and cannot support a negative proof.
        complete: bool = true,
        /// True when `bound` still names the single classifier the parameter
        /// is bounded by, even if the record dropped its type ARGUMENTS. That
        /// is enough to answer "which class owns a member call on this
        /// parameter", which is all the receiver-owner lookup asks.
        head_only: bool = true,
        /// The bound's type-argument heads, kept ONLY when every argument is
        /// concrete (`T : Iterable<String>` keeps ["String"];
        /// `C : MutableCollection<in T>` keeps nothing — an argument naming
        /// another parameter substitutes nothing). Lets a receiver typed by
        /// the parameter instantiate a generic callee's lambda params.
        args: []const []const u8 = &.{},
    };

    /// One class's transitive shadow-name set + chain completeness.
    pub const HierarchyShadowSet = struct {
        names: std.StringHashMap(void),
        complete: bool,
    };

    pub const MemberTrailingLambdaShape = struct {
        /// Bit `n` is set when `n` positional user arguments, including the
        /// trailing lambda, can bind this declaration.
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

    /// Clone for extension (see `Module.cloneForExtend`). Outer container
    /// spines are copied onto `a`; inner containers and value slices are
    /// SHARED with the original by value-copy. That is sound because the
    /// extending build only ever inserts NEW keys (new files, new classes,
    /// new FuncIds — cross-boundary name collisions fall back to a full
    /// rebuild) and replaces whole entries; it never appends into an inner
    /// container reached through an existing key.
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
