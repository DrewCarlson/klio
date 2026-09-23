//! The whole-file lowering pass: every top-level declaration of a file set is registered,
//! then each body lowers into its reserved slot through the per-declaration FQN overrides.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const FF = runtime.forest.ForestField;
const ast = @import("ast");
const compose_pass = @import("compose_pass");
const stdlib = @import("stdlib");
const lift = @import("lift.zig");
const prune = @import("../prune.zig");
const class_layout = @import("../class_layout.zig");
const body_pool = @import("body_pool.zig");
pub const lazy = @import("lazy.zig");
const image = @import("../image.zig");

const Allocator = std.mem.Allocator;
const Module = ir.Module;
const FuncId = ir.FuncId;
const Param = ir.Param;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const Env = runtime.Env;
const ObjRef = runtime.ObjRef;
const Value = runtime.Value;
const KotlinFile = ast.KotlinFile;
const Decl = ast.Decl;
const StringSet = runtime.NameHashMap(void);

const build_base = @import("base.zig");
const parentCtorParamExpected = build_base.parentCtorParamExpected;
const StdlibBase = build_base.StdlibBase;

const build_classes = @import("classes.zig");
const annotationRecordFor = build_classes.annotationRecordFor;
const buildClassDef = build_classes.buildClassDef;
const collectCompanionOwnMembers = build_classes.collectCompanionOwnMembers;
const collectConsts = build_classes.collectConsts;
const collectInline = build_classes.collectInline;
const fillNestedClassTables = build_classes.fillNestedClassTables;
const propagateInheritedDefaults = build_classes.propagateInheritedDefaults;
const registerClassSupertypes = build_classes.registerClassSupertypes;
const registerInlineMemberOwners = build_classes.registerInlineMemberOwners;
const registerMemberPropAsts = build_classes.registerMemberPropAsts;
const replaceDotWithDollar = build_classes.replaceDotWithDollar;
const resolveMangled = build_classes.resolveMangled;
const retainDecl = build_classes.retainDecl;
const spanNamesObject = build_classes.spanNamesObject;
const transplantExpectMemberDefaults = build_classes.transplantExpectMemberDefaults;

const build_clone = @import("clone.zig");
const classTableByQualifiedSuffix = build_clone.classTableByQualifiedSuffix;
const cloneBuiltForRun = build_clone.cloneBuiltForRun;
const adoptBuiltForRun = build_clone.adoptBuiltForRun;

const build_scan = @import("scan.zig");
const new_instance_mod = @import("../vm/host_instances/new_instance.zig");
const boundTypeRecordComplete = build_scan.boundTypeRecordComplete;
const classPropHead = build_scan.classPropHead;
const collectClassMemberNamesInto = build_scan.collectClassMemberNamesInto;
const collectClassTypeParamBounds = build_scan.collectClassTypeParamBounds;
const collectHierarchyCompanionMemberNames = build_scan.collectHierarchyCompanionMemberNames;
const collectHierarchyMemberNames = build_scan.collectHierarchyMemberNames;
const collectHierarchyMethodNames = build_scan.collectHierarchyMethodNames;
const collectHierarchyShadowNames = build_scan.collectHierarchyShadowNames;
const collectHierarchySuperNames = build_scan.collectHierarchySuperNames;
const collectMemberTrailingLambdaShapes = build_scan.collectMemberTrailingLambdaShapes;
const declFqnAt = build_scan.declFqnAt;
const declPackage = build_scan.declPackage;
const literalToConst = build_scan.literalToConst;
const literalTypeHead = build_scan.literalTypeHead;
const memberSizedInitHead = build_scan.memberSizedInitHead;
const noteExtPropTypeHead = build_scan.noteExtPropTypeHead;
const notePropScope = build_scan.notePropScope;
const notePropTypeRef = build_scan.notePropTypeRef;
const ownerSimplePath = build_scan.ownerSimplePath;
const packageOfFqn = build_scan.packageOfFqn;
const packagePrefix = build_scan.packagePrefix;
const propCtorHeadEvidence = build_scan.propCtorHeadEvidence;
const propHeadSourceExpr = build_scan.propHeadSourceExpr;
const putClassPropHead = build_scan.putClassPropHead;
const resolveFqn = build_scan.resolveFqn;
const simpleTypeHead = build_scan.simpleTypeHead;
const typedDefaultFor = build_scan.typedDefaultFor;
const typedDefaultForInit = build_scan.typedDefaultForInit;
const varargPropArrayHead = build_scan.varargPropArrayHead;

const build_types = @import("types.zig");
const BuiltModule = build_types.BuiltModule;
const ClassTable = build_types.ClassTable;
const EnumEntryArgInit = build_types.EnumEntryArgInit;
const EnumEntryMethod = build_types.EnumEntryMethod;
pub const FileClasses = build_types.FileClasses;
const NameFunc = build_types.NameFunc;
const PairFuncMap = build_types.PairFuncMap;
const PairStrMap = build_types.PairStrMap;
const SecondaryCtorEntry = build_types.SecondaryCtorEntry;
const Span = build_types.Span;
const SpanStrMap = build_types.SpanStrMap;
const StrFunc = build_types.StrFunc;
const StrPair = build_types.StrPair;
const StrPairContext = build_types.StrPairContext;
const StrPairSet = build_types.StrPairSet;

/// The alias a mangled pack-private object needs under every class declaring a namesake.
const PendingAlias = struct { cls: []const u8, simple: []const u8, mangled: []const u8 };

/// An extension property awaiting lowering; `owner` is null for a file-level one.
const ExtPropDecl = struct { p: *const ast.Property, owner: ?[]const u8, owner_type_params: []const ast.TypeParam = &.{} };

/// The state a whole-file lowering pass threads through its phases; a value lives here only
/// when more than one phase reads or writes it.
pub const BuildCtx = struct {
    /// The caller's allocator, which owns the returned `BuiltModule`.
    allocator: Allocator,
    /// The module registry's allocator, backing every build-scoped table.
    a: Allocator,
    module_ref: ObjRef(Module),
    module: *Module,
    file: *const KotlinFile,
    /// Set whenever a round of property-type inference learned a new head, so
    /// the pass can run again: one property's inferred type is another's
    /// evidence, and a single round stops at the first link of every chain.
    inferred_prop_heads_grew: bool = false,
    fqn_overrides: *const SpanStrMap,
    func_fqn_overrides: *const SpanStrMap,
    decl_pkg: *const SpanStrMap,
    base: ?*const StdlibBase,
    /// The base is this build's alone, extended in place and used once.
    own_base: bool,
    package_prefix: []const u8,
    /// Marks from the seed clone: registry materialisation appends only past these.
    base_funcs_len: usize,
    base_classes_len: usize,
    base_top_level_props: usize,
    base_object_names_len: usize,

    object_names: std.ArrayList([]const u8),
    object_spans: std.ArrayList(Span),
    nested_outer_members: lift.OuterMembers,
    nested_object_aliases: lift.AliasMap,
    mangled_nested: lift.MangledMap,
    all_decls: std.ArrayList(Decl),
    /// Superseded `expect class` shapes, kept for the default transplant.
    expect_class_ctor_params: runtime.NameHashMap([]const ast.ClassParam),
    expect_class_members: runtime.NameHashMap([]const Decl),

    decls: []Decl,
    /// Set for a build whose bodies are deferred; the context then outlives the call.
    lazy: ?*lazy.Plan = null,
    /// Every class in scope: the base's plus this file set's.
    file_classes: FileClasses,
    /// The phase-1 header slots in declaration order, consumed by phase 2.
    stub_ids: std.ArrayList(FuncId),
    /// Runtime class defs this build created, for the supertype backpatch.
    new_defs: std.ArrayList(ObjRef(ClassDef)),

    main_id: ?FuncId,
    classes: ClassTable,
    companion_singletons: runtime.NameHashMap([]const u8),
    enclosing_class: lift.EnclosingMap,
    body_prop_inits: PairFuncMap,
    instance_prop_getters: PairFuncMap,
    getter_prop_names: runtime.NameHashMap(void),
    instance_prop_setters: PairFuncMap,
    instance_prop_private: PairFuncMap,
    delegated_body_props: StrPairSet,
    primary_ctor_default_thunks: runtime.NameHashMap([]?FuncId),
    parent_ctor_args: runtime.NameHashMap([]FuncId),
    parent_ctor_arg_names: runtime.NameHashMap([]const ?[]const u8),
    init_blocks: runtime.NameHashMap([]FuncId),
    top_level_props: std.ArrayList(NameFunc),
    top_level_delegated_props: runtime.NameHashMap(void),
    extension_props: PairFuncMap,
    owner_keyed_ext_names: runtime.NameHashMap(void),
    nullable_ext_props: runtime.NameHashMap(?FuncId),
    extension_prop_setters: PairFuncMap,
    extension_prop_delegates: PairFuncMap,
    enum_entry_arg_inits: std.ArrayList(EnumEntryArgInit),
    enum_entry_methods: std.HashMap(StrPair, EnumEntryMethod, StrPairContext, runtime.nameMaxLoadPercentage),
    enum_entry_synth_class: PairStrMap,
    secondary_ctors: runtime.NameHashMap([]SecondaryCtorEntry),
    class_delegates: runtime.NameHashMap([]StrFunc),
    func_defaults: std.AutoHashMap(u32, []?FuncId),
    func_type_params: std.AutoHashMap(u32, [][]const u8),

    fn init(
        allocator: Allocator,
        file: *const KotlinFile,
        fqn_overrides: *const SpanStrMap,
        func_fqn_overrides: *const SpanStrMap,
        decl_pkg: *const SpanStrMap,
        file_packages: ?*const std.AutoHashMap(ir.FileId, []const u8),
        file_modules: ?*const std.AutoHashMap(ir.FileId, u32),
        base: ?*const StdlibBase,
        own_base: bool,
    ) Allocator.Error!BuildCtx {
        var seed: ?BuiltModule = if (base) |bs|
            (if (own_base) try adoptBuiltForRun(allocator, &bs.built) else try cloneBuiltForRun(allocator, &bs.built))
        else
            null;
        const module_ref = if (seed) |*s| s.module else try ObjRef(Module).init(allocator, Module.default(allocator));
        // The ObjRef holds the only handle during the build and nothing else borrows it, so a
        // raw pointer into the cell is a stable `*Module` for the lowering driver.
        const module: *Module = &module_ref.cell.data;
        // A cloned or fresh module took this thread's pending pick tables in
        // `Module.init`; an owned base is extended in place and takes them here.
        if (base != null and own_base) module.adoptPicks(ir.takePendingPicks());
        const a = module.registry.allocator;
        const base_funcs_len = module.funcs.items.len;
        const base_classes_len = module.classes.items.len;
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
        const object_names: std.ArrayList([]const u8) = if (seed) |*s| s.object_names else .empty;
        const base_object_names_len = object_names.items.len;
        var nested_object_aliases = lift.AliasMap.init(a);
        if (base != null) {
            // The lift-time alias context seeds from the cloned registry so user classes can extend base
            // nested shapes; inner maps are deep-copied, the lift appending per class key.
            var it = module.registry.nested_object_aliases.iterator();
            while (it.next()) |e| {
                var inner = runtime.NameHashMap([]const u8).init(a);
                var iit = e.value_ptr.iterator();
                while (iit.next()) |ie| try inner.put(ie.key_ptr.*, ie.value_ptr.*);
                try nested_object_aliases.put(e.key_ptr.*, inner);
            }
        }
        var mangled_nested = lift.MangledMap.init(a);
        if (base != null) {
            var it = module.registry.mangled_nested.iterator();
            while (it.next()) |e| try mangled_nested.put(e.key_ptr.*, e.value_ptr.*);
        }
        return .{
            .allocator = allocator,
            .a = a,
            .module_ref = module_ref,
            .module = module,
            .file = file,
            .fqn_overrides = fqn_overrides,
            .func_fqn_overrides = func_fqn_overrides,
            .decl_pkg = decl_pkg,
            .base = base,
            .own_base = own_base,
            .package_prefix = package_prefix,
            .base_funcs_len = base_funcs_len,
            .base_classes_len = base_classes_len,
            .base_top_level_props = if (seed) |*sd| sd.base_top_level_props else 0,
            .base_object_names_len = base_object_names_len,
            .object_names = object_names,
            .object_spans = .empty,
            .nested_outer_members = lift.OuterMembers.init(a),
            .nested_object_aliases = nested_object_aliases,
            .mangled_nested = mangled_nested,
            .all_decls = .empty,
            .expect_class_ctor_params = runtime.NameHashMap([]const ast.ClassParam).init(a),
            .expect_class_members = runtime.NameHashMap([]const Decl).init(a),
            .decls = &.{},
            .file_classes = FileClasses.init(a),
            .stub_ids = .empty,
            .new_defs = .empty,
            .main_id = null,
            .classes = if (seed) |*s| s.classes else ClassTable.init(a),
            .companion_singletons = if (seed) |*s| s.companion_singletons else runtime.NameHashMap([]const u8).init(a),
            .enclosing_class = if (seed) |*s| s.enclosing_class else lift.EnclosingMap.init(a),
            .body_prop_inits = if (seed) |*s| s.body_prop_inits else PairFuncMap.init(a),
            .instance_prop_getters = if (seed) |*s| s.instance_prop_getters else PairFuncMap.init(a),
            .getter_prop_names = if (seed) |*s| s.getter_prop_names else runtime.NameHashMap(void).init(a),
            .instance_prop_setters = if (seed) |*s| s.instance_prop_setters else PairFuncMap.init(a),
            .instance_prop_private = if (seed) |*s| s.instance_prop_private else PairFuncMap.init(a),
            .delegated_body_props = if (seed) |*s| s.delegated_body_props else StrPairSet.init(a),
            .primary_ctor_default_thunks = if (seed) |*s| s.primary_ctor_default_thunks else runtime.NameHashMap([]?FuncId).init(a),
            .parent_ctor_args = if (seed) |*s| s.parent_ctor_args else runtime.NameHashMap([]FuncId).init(a),
            .parent_ctor_arg_names = if (seed) |*s| s.parent_ctor_arg_names else runtime.NameHashMap([]const ?[]const u8).init(a),
            .init_blocks = if (seed) |*s| s.init_blocks else runtime.NameHashMap([]FuncId).init(a),
            .top_level_props = if (seed) |*s| s.top_level_props else .empty,
            .top_level_delegated_props = if (seed) |*s| s.top_level_delegated_props else runtime.NameHashMap(void).init(a),
            .extension_props = if (seed) |*s| s.extension_props else PairFuncMap.init(a),
            .owner_keyed_ext_names = if (seed) |*s| s.owner_keyed_ext_names else runtime.NameHashMap(void).init(a),
            .nullable_ext_props = if (seed) |*s| s.nullable_ext_props else runtime.NameHashMap(?FuncId).init(a),
            .extension_prop_setters = if (seed) |*s| s.extension_prop_setters else PairFuncMap.init(a),
            .extension_prop_delegates = if (seed) |*s| s.extension_prop_delegates else PairFuncMap.init(a),
            .enum_entry_arg_inits = if (seed) |*s| s.enum_entry_arg_inits else .empty,
            .enum_entry_methods = if (seed) |*s| s.enum_entry_methods else std.HashMap(StrPair, EnumEntryMethod, StrPairContext, runtime.nameMaxLoadPercentage).init(a),
            .enum_entry_synth_class = if (seed) |*s| s.enum_entry_synth_class else PairStrMap.init(a),
            .secondary_ctors = if (seed) |*s| s.secondary_ctors else runtime.NameHashMap([]SecondaryCtorEntry).init(a),
            .class_delegates = if (seed) |*s| s.class_delegates else runtime.NameHashMap([]StrFunc).init(a),
            .func_defaults = if (seed) |*s| s.func_defaults else std.AutoHashMap(u32, []?FuncId).init(a),
            .func_type_params = if (seed) |*s| s.func_type_params else std.AutoHashMap(u32, [][]const u8).init(a),
        };
    }

    /// Release what exists only for the build; every table the `BuiltModule` carries survives.
    fn deinitScratch(self: *BuildCtx) void {
        self.object_spans.deinit(self.a);
        self.mangled_nested.deinit();
        self.expect_class_ctor_params.deinit();
        self.expect_class_members.deinit();
        self.file_classes.deinit();
        self.stub_ids.deinit(self.a);
        self.new_defs.deinit(self.a);
    }

    fn finish(self: *BuildCtx) BuiltModule {
        return .{
            .module = self.module_ref,
            .classes = self.classes,
            .body_prop_inits = self.body_prop_inits,
            .instance_prop_getters = self.instance_prop_getters,
            .getter_prop_names = self.getter_prop_names,
            .instance_prop_private = self.instance_prop_private,
            .instance_prop_setters = self.instance_prop_setters,
            .parent_ctor_args = self.parent_ctor_args,
            .parent_ctor_arg_names = self.parent_ctor_arg_names,
            .init_blocks = self.init_blocks,
            .top_level_props = self.top_level_props,
            .base_top_level_props = self.base_top_level_props,
            .extension_props = self.extension_props,
            .owner_keyed_ext_names = self.owner_keyed_ext_names,
            .nullable_ext_props = self.nullable_ext_props,
            .extension_prop_delegates = self.extension_prop_delegates,
            .extension_prop_setters = self.extension_prop_setters,
            .main = self.main_id,
            .object_names = self.object_names,
            .companion_singletons = self.companion_singletons,
            .enum_entry_arg_inits = self.enum_entry_arg_inits,
            .secondary_ctors = self.secondary_ctors,
            .primary_ctor_default_thunks = self.primary_ctor_default_thunks,
            .class_delegates = self.class_delegates,
            .func_defaults = self.func_defaults,
            .enclosing_class = self.enclosing_class,
            .enum_entry_methods = self.enum_entry_methods,
            .enum_entry_synth_class = self.enum_entry_synth_class,
            .func_type_params = self.func_type_params,
            .top_level_delegated_props = self.top_level_delegated_props,
            .delegated_body_props = self.delegated_body_props,
            .allocator = self.allocator,
        };
    }
};

const phase = @import("module.zig").phase;

/// A stage the driver hands the build to run beside its table passes: the
/// checker's picks for the bodies. It starts once the passes that rewrite
/// the syntax are done and is joined before the first body lowers, so it
/// reads the syntax the bodies see and nothing reads its results early.
pub const StageJob = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque, []const KotlinFile) void,
};

/// Consumed by the next build; the driver sets both before calling in.
pub var stage_job: ?StageJob = null;
/// The files, after their transforms, the stage checks.
pub var stage_files: []const KotlinFile = &.{};

fn runStageJob(job: StageJob, files: []const KotlinFile) void {
    job.run(job.ctx, files);
}

pub fn buildModuleWithOverrides(
    allocator: Allocator,
    file: *const KotlinFile,
    fqn_overrides: *const SpanStrMap,
    func_fqn_overrides: *const SpanStrMap,
    decl_pkg: *const SpanStrMap,
    file_packages: ?*const std.AutoHashMap(ir.FileId, []const u8),
    file_modules: ?*const std.AutoHashMap(ir.FileId, u32),
    base: ?*const StdlibBase,
    out_lifted: ?*[]Decl,
    own_base: bool,
) Allocator.Error!BuiltModule {
    // A lazy plan keeps the context past this call: the program runs with
    // the bodies deferred and the completion lowers them into it.
    const plan = lazy.take();
    const ctx = try allocator.create(BuildCtx);
    ctx.* = try BuildCtx.init(
        allocator,
        file,
        fqn_overrides,
        func_fqn_overrides,
        decl_pkg,
        file_packages,
        file_modules,
        base,
        own_base,
    );
    ctx.lazy = plan;
    if (plan) |p| p.ctx = ctx;
    defer if (plan == null) {
        ctx.deinitScratch();
        allocator.destroy(ctx);
    };
    phase.mark("build-ctx-init");

    try liftFileDecls(ctx);
    phase.mark("liftFileDecls");
    try repointMangledSupertypes(ctx);
    phase.mark("repointMangledSupertypes");
    try repointAliasedNestedSupertypes(ctx);
    phase.mark("repointAliasedNestedSupertypes");
    try applyExpectActualSubstitutions(ctx, out_lifted);
    phase.mark("applyExpectActualSubstitutions");

    // The syntax is final from here; the stage runs on its own thread while
    // the tables below register from the same syntax.
    var stage_thread: ?std.Thread = null;
    var stage_pending: ?StageJob = null;
    if (stage_job) |job| {
        stage_job = null;
        stage_pending = job;
        // `KLIO_STAGE_SERIAL=1` runs it here instead, on this thread, to tell
        // an ordering effect from a concurrency one.
        if (runtime.envOnce("KLIO_STAGE_SERIAL") == null) {
            stage_thread = std.Thread.spawn(.{ .stack_size = 64 << 20 }, runStageJob, .{ job, stage_files }) catch null;
        }
    }

    // Register every declaration's identity and metadata. Nothing here lowers a body, so a
    // body lowered below sees complete tables however its declaration is ordered in source.
    try collectFileClasses(ctx);
    phase.mark("collectFileClasses");
    try registerConstInitializers(ctx);
    phase.mark("registerConstInitializers");
    try registerHierarchyMethodNames(ctx);
    phase.mark("registerHierarchyMethodNames");
    try registerHierarchyShadowNames(ctx);
    phase.mark("registerHierarchyShadowNames");
    try registerMemberNameUniverse(ctx);
    phase.mark("registerMemberNameUniverse");
    try registerPropertyTypeHeads(ctx);
    phase.mark("registerPropertyTypeHeads");
    try registerClassSuperNameChains(ctx);
    phase.mark("registerClassSuperNameChains");
    try registerShadowedStorageProps(ctx);
    phase.mark("registerShadowedStorageProps");
    try installLiftedNameTables(ctx);
    phase.mark("installLiftedNameTables");
    try installMemberAstTables(ctx);
    phase.mark("installMemberAstTables");
    try installInlineFnTables(ctx);
    phase.mark("installInlineFnTables");
    try installTopLevelPropNames(ctx);
    phase.mark("installTopLevelPropNames");
    try registerFileImports(ctx);
    phase.mark("registerFileImports");
    try reserveClassShells(ctx);
    phase.mark("reserveClassShells");
    try linkReservedClassSupertypes(ctx);
    phase.mark("linkReservedClassSupertypes");
    try reserveClassMemberHeaders(ctx);
    phase.mark("reserveClassMemberHeaders");
    try registerTypeAliasShapes(ctx);
    phase.mark("registerTypeAliasShapes");
    try registerClassTypeAliasShapes(ctx);
    phase.mark("registerClassTypeAliasShapes");
    // Member signatures need the same source-order independence as top-level headers: the
    // trailing receiver-lambda portion is recorded before any class body lowers.
    // A base's classes carry their shapes in its registry; only this build's
    // own classes are collected, so no base class is decoded for it.
    if (ctx.base != null) {
        var own = FileClasses.init(ctx.a);
        defer own.deinit();
        for (ctx.decls) |*d| {
            if (d.* == .Class) try own.put(d.Class.name.name, FF(ast.Class).fromPtr(&d.Class));
        }
        try collectMemberTrailingLambdaShapes(ctx.module, &own);
    } else {
        try collectMemberTrailingLambdaShapes(ctx.module, &ctx.file_classes);
    }
    phase.mark("collectMemberTrailingLambdaShapes");
    try fillReservedClassPrimaryParams(ctx);
    phase.mark("fillReservedClassPrimaryParams");
    try registerTopLevelFuncHeaders(ctx);
    phase.mark("registerTopLevelFuncHeaders");
    phase.mark("registerTopLevelFuncHeaders");
    try registerMemberExtPropHeaders(ctx);
    phase.mark("registerMemberExtPropHeaders");
    try registerTopLevelAccessorHeaders(ctx);
    phase.mark("registerTopLevelAccessorHeaders");
    try registerCallableExtensionProps(ctx);
    phase.mark("registerCallableExtensionProps");
    try registerReceiverFnPropHeads(ctx);
    phase.mark("registerReceiverFnPropHeads");
    try registerInferredPropertyTypeHeads(ctx);
    phase.mark("registerInferredPropertyTypeHeads");

    // The bodies read the stage's picks, so it finishes first and the module
    // takes its tables, which the stage left in the shared hand-off.
    if (stage_thread) |t| t.join() else if (stage_pending) |job| runStageJob(job, stage_files);
    if (stage_pending != null) {
        if (ir.staged_picks) |p| {
            ir.staged_picks = null;
            ctx.module.adoptPicks(p);
        }
    }

    // The runtime class defs are built before any body lowers, not after. They
    // are a function of the declarations, which are final here, and the field
    // layout is read off them: a `GetField` can only carry a slot if the
    // layout table exists at the moment the read is emitted.
    try buildRuntimeClassDefs(ctx);
    phase.mark("buildRuntimeClassDefs");
    try registerEnumEntries(ctx);
    phase.mark("registerEnumEntries");
    try linkRuntimeSupertypes(ctx);
    phase.mark("linkRuntimeSupertypes");
    // With every class registered and every supertype linked, each class can
    // say what it adds to its superclass's slots and the chains compose. This
    // runs BEFORE any body lowers so a field read can carry its slot; the
    // classes lowering itself creates are published by the pass at the end.
    try publishFieldLayoutsAndLink(ctx);
    phase.mark("publishFieldLayouts");

    // Lower every body and thunk against the now-complete header set.
    try lowerClassBodies(ctx);
    phase.mark("lowerClassBodies");
    phase.mark("lowerClassBodies");
    try lowerTopLevelFunctionBodies(ctx);
    phase.mark("lowerTopLevelFunctionBodies");
    phase.mark("lowerTopLevelFunctionBodies");
    try lowerClassMemberThunks(ctx);
    phase.mark("lowerClassMemberThunks");
    phase.mark("lowerClassMemberThunks");
    try lowerParentCtorArgThunks(ctx);
    phase.mark("lowerParentCtorArgThunks");
    try lowerInitBlockThunks(ctx);
    phase.mark("lowerInitBlockThunks");
    try lowerClassDelegateThunks(ctx);
    phase.mark("lowerClassDelegateThunks");
    try lowerSecondaryCtors(ctx);
    phase.mark("lowerSecondaryCtors");
    try lowerTopLevelConstProps(ctx);
    phase.mark("lowerTopLevelConstProps");
    try lowerTopLevelProps(ctx);
    phase.mark("lowerTopLevelProps");
    try lowerExtensionProps(ctx);
    phase.mark("lowerExtensionProps");

    // Settle the cross-declaration links runtime dispatch reads.
    try settleDefaultArgThunks(ctx);
    phase.mark("settleDefaultArgThunks");
    try registerTypeAliasTags(ctx);
    phase.mark("registerTypeAliasTags");
    try rewriteAliasedParamTypes(ctx);
    phase.mark("rewriteAliasedParamTypes");
    try materialiseRegistry(ctx);
    phase.mark("materialiseRegistry");
    try finishModule(ctx);
    phase.mark("finishModule");
    phase.mark("finishModule");
    const r = ctx.finish();
    phase.mark("finish");
    if (plan) |p| lazy.active_build = p;
    return r;
}

/// Flatten nested declarations into `all_decls`, mangling pack-private objects that collide.
fn liftFileDecls(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const file = ctx.file;
    const base = ctx.base;
    const fqn_overrides = ctx.fqn_overrides;
    const all_decls = &ctx.all_decls;
    const nested_object_aliases = &ctx.nested_object_aliases;

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
    var pack_pkg_types = runtime.NameHashMap(StringSet).init(a);
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
                if (std.mem.findScalarLast(u8, f, '.')) |dot| {
                    const pkg = f[0..dot];
                    const gop = try pack_pkg_types.getOrPut(pkg);
                    if (!gop.found_existing) gop.value_ptr.* = StringSet.init(a);
                    try gop.value_ptr.put(ss.simple, {});
                }
            }
        }
    }

    // True top-level type names in any package, used to mangle colliding nested types.
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
    var dup_nested_names = StringSet.init(a);
    defer dup_nested_names.deinit();
    try lift.collectDupNestedNames(a, file.decls, &dup_nested_names);
    var lift_ctx = lift.LiftCtx{
        .allocator = a,
        .out_decls = all_decls,
        .object_names = &ctx.object_names,
        .object_spans = &ctx.object_spans,
        .companion_singletons = &ctx.companion_singletons,
        .nested_outer_members = &ctx.nested_outer_members,
        .enclosing_class = &ctx.enclosing_class,
        .nested_object_aliases = nested_object_aliases,
        .top_level_type_names = &top_level_type_names,
        .mangled_nested = &ctx.mangled_nested,
        .used_qualified_supertypes = &used_qualified_supertypes,
        .dup_nested_names = &dup_nested_names,
    };

    var pending_object_aliases: std.ArrayList(PendingAlias) = .empty;
    defer pending_object_aliases.deinit(a);

    for (file.decls) |*d| {
        switch (d.*) {
            .Object => |*o| try liftTopLevelObject(
                ctx,
                &lift_ctx,
                o,
                &actual_object_names,
                &user_top_type_names,
                &pack_pkg_types,
                &pending_object_aliases,
            ),
            .Class => |*c| try liftTopLevelClass(ctx, &lift_ctx, d, c, &actual_class_names),
            else => try all_decls.append(a, d.*),
        }
    }

    for (pending_object_aliases.items) |pa| {
        const gop = try nested_object_aliases.getOrPut(pa.cls);
        if (!gop.found_existing) gop.value_ptr.* = runtime.NameHashMap([]const u8).init(a);
        try gop.value_ptr.put(pa.simple, pa.mangled);
    }
}

fn liftTopLevelObject(
    ctx: *BuildCtx,
    lift_ctx: *lift.LiftCtx,
    o: *ast.ObjectDecl,
    actual_object_names: *const StringSet,
    user_top_type_names: *const StringSet,
    pack_pkg_types: *const runtime.NameHashMap(StringSet),
    pending_object_aliases: *std.ArrayList(PendingAlias),
) Allocator.Error!void {
    const a = ctx.a;
    const fqn_overrides = ctx.fqn_overrides;
    const object_names = &ctx.object_names;
    const object_spans = &ctx.object_spans;
    const all_decls = &ctx.all_decls;
    if (o.is_expect and actual_object_names.contains(o.name.name)) return;
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
        if (std.mem.findScalarLast(u8, fqn, '.')) |dot| {
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
        return;
    }
    try object_names.append(a, o.name.name);
    try object_spans.append(a, o.span);
    const synth = try lift.synthesizeClassFromObject(a, o);
    try lift.liftClassRecursive(lift_ctx, &synth, &.{});
    try all_decls.append(a, .{ .Class = synth });
}

/// Lift one top-level `class`, recording the defaults of an `expect` its `actual` supersedes.
fn liftTopLevelClass(
    ctx: *BuildCtx,
    lift_ctx: *lift.LiftCtx,
    d: *Decl,
    c: *ast.Class,
    actual_class_names: *const StringSet,
) Allocator.Error!void {
    const a = ctx.a;
    const all_decls = &ctx.all_decls;
    const expect_class_ctor_params = &ctx.expect_class_ctor_params;
    const expect_class_members = &ctx.expect_class_members;
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
        return;
    }
    try lift.liftClassRecursive(lift_ctx, c, &.{});
    try all_decls.append(a, d.*);
}

fn repointMangledSupertypes(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const all_decls = &ctx.all_decls;
    const mangled_nested = &ctx.mangled_nested;
    if (mangled_nested.count() != 0) {
        for (all_decls.items) |*d| {
            if (d.* == .Class) {
                for (d.Class.supertypes) |*t| {
                    if (resolveMangled(a, mangled_nested, t)) |mangled| {
                        t.name.name = mangled;
                    }
                }
            }
        }
    }
}

fn repointAliasedNestedSupertypes(ctx: *BuildCtx) Allocator.Error!void {
    const all_decls = &ctx.all_decls;
    const enclosing_class = &ctx.enclosing_class;
    const nested_object_aliases = &ctx.nested_object_aliases;
    // A lifted member whose enclosing chain reaches the aliasing outer sees the alias.
    if (nested_object_aliases.count() != 0) {
        for (all_decls.items) |*d| {
            if (d.* != .Class) continue;
            for (d.Class.supertypes) |*t| {
                if (t.x().qualified_path != null) continue;
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
}

/// Transplant each `expect`'s defaults onto the `actual` that supersedes it, then drop it.
fn applyExpectActualSubstitutions(ctx: *BuildCtx, out_lifted: ?*[]Decl) Allocator.Error!void {
    const a = ctx.a;
    const package_prefix = ctx.package_prefix;
    const fqn_overrides = ctx.fqn_overrides;
    const func_fqn_overrides = ctx.func_fqn_overrides;
    const all_decls = &ctx.all_decls;
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
            // An `actual` supersedes the `expect` it implements, which Kotlin requires to share its
            // package, so the set is keyed by FQN, not by simple name.
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

    try inheritExpectFunctionDefaults(ctx);
    try inheritExpectClassCtorDefaults(ctx);
    try inheritExpectClassMemberDefaults(ctx);

    // Drop superseded `expect` decls + the upstream stubs klio overrides.
    var decls_list: std.ArrayList(Decl) = .empty;
    for (all_decls.items) |*d| {
        if (try retainDecl(a, d, fqn_overrides, func_fqn_overrides, package_prefix, &actual_func_names, &actual_class_names_set, &actual_object_names_set, &actual_prop_names)) {
            try decls_list.append(a, d.*);
        }
    }
    ctx.decls = decls_list.items;
    if (out_lifted) |out| out.* = ctx.decls;
    // Every later pass reads `ctx.decls`; the pre-filter copies are dead.
    all_decls.clearAndFree(a);
}

fn inheritExpectFunctionDefaults(ctx: *BuildCtx) Allocator.Error!void {
    const all_decls = &ctx.all_decls;
    // Kotlin declares default parameter values on the `expect` ONLY. The retain pass drops the
    // superseded expect, so its defaults transplant first; an actual re-declaring one keeps its own.
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
            if (!expectActualParamsMatch(af.params, ef.params)) continue;
            for (af.params, ef.params) |*ap, *ep| {
                if (ap.default == null) ap.default = ep.default;
            }
        }
    }
}

/// Whether an `actual`'s parameter list is the one this `expect` declares. Kotlin
/// requires the pair to agree on parameter names and types, so they identify each
/// other among same-arity overloads: `Paragraph` ships four nine-parameter
/// overloads, and matching on arity alone transplants one's defaults onto another's
/// slots.
fn expectActualParamsMatch(ap: []const ast.Param, ep: []const ast.Param) bool {
    if (ap.len != ep.len) return false;
    for (ap, ep) |*a, *e| {
        if (!std.mem.eql(u8, a.name.name, e.name.name)) return false;
        if (!std.mem.eql(u8, a.ty.name.name, e.ty.name.name)) return false;
    }
    return true;
}

fn inheritExpectClassCtorDefaults(ctx: *BuildCtx) Allocator.Error!void {
    const all_decls = &ctx.all_decls;
    const expect_class_ctor_params = &ctx.expect_class_ctor_params;
    // The superseded expect was dropped during collection, its parameter list recorded, so its
    // defaults transplant onto the matching `actual class` here.
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
}

fn inheritExpectClassMemberDefaults(ctx: *BuildCtx) Allocator.Error!void {
    const all_decls = &ctx.all_decls;
    const expect_class_members = &ctx.expect_class_members;
    // The expect class is absent from `all_decls`, so its member defaults copy onto the actual
    // before class lowering builds thunks and arity metadata.
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
}

fn collectFileClasses(ctx: *BuildCtx) Allocator.Error!void {
    const base = ctx.base;
    const decls = ctx.decls;
    const file_classes = &ctx.file_classes;
    // In an extending build the base's lifted classes join the universe first, so hierarchy walks
    // and inline splicing for USER classes reach through base supertypes; base decls never re-lower.
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
}

fn registerConstInitializers(ctx: *BuildCtx) Allocator.Error!void {
    const module = ctx.module;
    const decls = ctx.decls;
    {
        for (decls) |*d| {
            switch (d.*) {
                .Class => |*c| try collectConsts(module, c.name.name, c.members),
                .Property => |p| if (p.is_const) {
                    if (p.init) |init| {
                        if (literalToConst(init)) |cst| {
                            try module.registry.class_const_inits.put(.{ .a = "", .b = p.name.name }, cst);
                        }
                    }
                },
                else => {},
            }
        }
    }
}

fn registerHierarchyMethodNames(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const file_classes = &ctx.file_classes;
    // Per-class transitive member-function-name set. A base's classes carry
    // theirs, so only this build's own classes are walked: touching a base
    // class here would decode its declaration from the image for nothing.
    var own = OwnClasses.of(ctx);
    while (own.next()) |oc| {
        const cname = oc.name;
        const c = oc.class;
        // A class also records its hierarchy's method names under its qualified name, so a reader
        // holding the fqn gets an exact answer when two packages share a simple name.
        const cfqn = try resolveFqn(a, fqn_overrides, c.name.span, package_prefix, cname);
        const fqn_wanted = !std.mem.eql(u8, cfqn, cname) and
            !module.registry.hierarchy_methods.contains(cfqn);
        const simple_wanted = !module.registry.hierarchy_methods.contains(cname);
        if (!fqn_wanted and !simple_wanted) continue;
        var methods = StringSet.init(a);
        var seen = StringSet.init(a);
        defer seen.deinit();
        try collectHierarchyMethodNames(cname, file_classes, &methods, &seen);
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

/// The classes a pass registers per class: every class in scope for a
/// fresh build, and only the build's own top-level classes over a base,
/// whose classes registered theirs in the build that made the base.
const OwnClasses = struct {
    decls: []Decl,
    file_classes: ?FileClasses.Iterator,
    i: usize = 0,

    const Entry = struct { name: []const u8, class: *const ast.Class };

    fn of(ctx: *BuildCtx) OwnClasses {
        if (ctx.base != null) return .{ .decls = ctx.decls, .file_classes = null };
        return .{ .decls = &.{}, .file_classes = ctx.file_classes.iterator() };
    }

    fn next(self: *OwnClasses) ?Entry {
        if (self.file_classes) |*it| {
            const kv = it.next() orelse return null;
            return .{ .name = kv.key_ptr.*, .class = kv.value_ptr.get() };
        }
        while (self.i < self.decls.len) {
            const d = &self.decls[self.i];
            self.i += 1;
            if (d.* == .Class) return .{ .name = d.Class.name.name, .class = &d.Class };
        }
        return null;
    }
};

fn registerHierarchyShadowNames(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const file_classes = &ctx.file_classes;
    // The completeness bit keeps an unresolvable supertype chain conservative; a class with no
    // entry falls back to the program-wide set.
    {
        var it = file_classes.keyIterator();
        while (it.next()) |cname| {
            if (module.registry.hierarchy_shadow_names.contains(cname.*)) continue;
            var names = StringSet.init(a);
            var seen = StringSet.init(a);
            defer seen.deinit();
            const complete = try collectHierarchyShadowNames(cname.*, file_classes, &names, &seen);
            try module.registry.hierarchy_shadow_names.put(cname.*, .{ .names = names, .complete = complete });
        }
    }
    try registerSubclassDeclaredNames(ctx);
    if (runtime.envOnce("KLIO_SHADOW_PROBE") != null) {
        var complete: usize = 0;
        var incomplete: usize = 0;
        var it = module.registry.hierarchy_shadow_names.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.complete) complete += 1 else incomplete += 1;
        }
        std.debug.print("[shadow-probe] classes={d} complete={d} incomplete={d}\n", .{ module.registry.hierarchy_shadow_names.count(), complete, incomplete });
    }
}

/// `(ancestor, member name)` for every name a STRICT subclass declares, read
/// from the AST members — the authoritative record, and the only one.
///
/// A published layout misses an accessor-only override, which contributes no
/// slot; the `__get_<Class>_<prop>` contract misses one too, because an
/// `override var x get() = ... set(...) = ...` produces no function under it.
/// Both proxies were tried and both let `TransparentObserverMutableSnapshot`'s
/// `invalid` through, where an open-class slot claim then served a stale cell.
fn registerSubclassDeclaredNames(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const file_classes = &ctx.file_classes;
    var it = file_classes.iterator();
    while (it.next()) |e| {
        const ref = e.value_ptr.*;
        const c = ref.get();
        var own = StringSet.init(a);
        defer own.deinit();
        try collectClassMemberNamesInto(&own, c.primary_params, c.members);
        if (own.count() == 0) continue;
        var seen = StringSet.init(a);
        defer seen.deinit();
        var ancestors = StringSet.init(a);
        defer ancestors.deinit();
        try collectAncestorNames(c, file_classes, &ancestors, &seen);
        var ait = ancestors.keyIterator();
        while (ait.next()) |anc| {
            var oit = own.keyIterator();
            while (oit.next()) |nm| {
                const key = try std.fmt.allocPrint(a, "{s}\u{1f}{s}", .{ anc.*, nm.* });
                if (module.registry.subclass_declares_prop.contains(key)) {
                    a.free(key);
                    continue;
                }
                try module.registry.subclass_declares_prop.put(key, {});
            }
        }
    }
}

/// Every transitive supertype simple name of `c`, itself excluded.
fn collectAncestorNames(c: *const ast.Class, by_name: *const FileClasses, out: *StringSet, seen: *StringSet) Allocator.Error!void {
    for (c.supertypes) |*st| {
        const nm = st.name.name;
        const gop = try seen.getOrPut(nm);
        if (gop.found_existing) continue;
        try out.put(nm, {});
        const ref = by_name.get(nm) orelse continue;
        try collectAncestorNames(ref.get(), by_name, out, seen);
    }
}

fn registerMemberNameUniverse(ctx: *BuildCtx) Allocator.Error!void {
    const module = ctx.module;
    const decls = ctx.decls;
    // A bare name in a receiver context is shadowable at runtime only when it appears in this
    // program-wide universe, so lowering keeps every other name static.
    for (decls) |*d| {
        if (d.* == .Class) {
            try collectClassMemberNamesInto(&module.registry.class_member_names, d.Class.primary_params, d.Class.members);
        } else if (d.* == .Object) {
            try collectClassMemberNamesInto(&module.registry.class_member_names, &.{}, d.Object.members);
        }
    }
    // Builtin value-class members no user class declares: the unsigned types' backing `val data`.
    // A bare `data` in an unsigned extension is `this.data`, so it must shadow a same-named
    // cross-package top-level the way a declared member would.
    try module.registry.class_member_names.put("data", {});
    // A host classifier's members are declared nowhere this walk can see them,
    // and a universe missing them answers "no receiver has this name" about
    // names `String`, `KClass` and the array families all serve. The natives
    // table is where those declarations are, keyed `pkg.Classifier.member`, so
    // a capitalized owner segment is what marks one.
    var fqn_it = stdlib.implementations.allFqns();
    while (fqn_it.next()) |fqn| {
        const last_dot = std.mem.findScalarLast(u8, fqn, '.') orelse continue;
        const owner = fqn[0..last_dot];
        const owner_dot = std.mem.findScalarLast(u8, owner, '.');
        const owner_simple = if (owner_dot) |d| owner[d + 1 ..] else owner;
        if (owner_simple.len == 0 or !std.ascii.isUpper(owner_simple[0])) continue;
        try module.registry.class_member_names.put(fqn[last_dot + 1 ..], {});
    }
}

fn registerPropertyTypeHeads(ctx: *BuildCtx) Allocator.Error!void {
    const decls = ctx.decls;
    // Per-class property DECLARED type heads, class type-parameter names substituted by their
    // bound's head, so a call on the property resolves against the STATIC type, as kotlinc does.
    for (decls) |*d| {
        if (d.* == .Class) {
            try registerClassPropTypeHeads(ctx, &d.Class);
        } else if (d.* == .Object) {
            try registerObjectPropTypeHeads(ctx, &d.Object);
        }
    }
}

fn registerClassPropTypeHeads(ctx: *BuildCtx, c: *ast.Class) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const cfqn = try declFqnAt(a, module, fqn_overrides, c.span, package_prefix, c.name.name);
    for (c.primary_params) |*pp| {
        if (pp.property == null) continue;
        // A `vararg val` property's OBSERVED type is the materialized array, never the element head.
        if (pp.is_vararg) {
            try putClassPropHead(module, c.name.name, cfqn, pp.name.name, varargPropArrayHead(pp.ty.name.name));
        } else if (classPropHead(c, &pp.ty)) |head| {
            try putClassPropHead(module, c.name.name, cfqn, pp.name.name, head);
            try notePropTypeRef(a, module, c, pp.name.name, &pp.ty);
        }
    }
    try registerClassMemberPropTypeHeads(ctx, c, cfqn);
    try registerNestedClassPropTypeHeads(ctx, c);
    try registerCompanionPropTypeHeads(ctx, c);
}

/// The type a class body property states, annotated or inferred from its initializer.
fn declaredMemberPropType(c: *const ast.Class, prop: *const ast.Property) ?*const ast.TypeRef {
    if (prop.ty) |t| return t;
    const src = propHeadSourceExpr(prop) orelse return null;
    // `private val _start = start` beside `class R(start: Double)` is the parameter's type.
    if (src.* == .Path and src.Path.segments.len == 1 and
        !std.mem.eql(u8, runtime.envOnce("KLIO_FACTORY_PROP") orelse "1", "0"))
    {
        const pname = src.Path.segments[0].name;
        for (c.primary_params) |*pp| {
            if (std.mem.eql(u8, pp.name.name, pname)) return &pp.ty;
        }
        return null;
    }
    if (src.* != .Call) return null;
    const callee = src.Call.callee;
    if (callee.* != .Path or callee.Path.segments.len != 1) return null;
    const fname = callee.Path.segments[0].name;
    for (c.members) |*fm| {
        if (fm.* != .Function) continue;
        if (!std.mem.eql(u8, fm.Function.name.name, fname)) continue;
        if (fm.Function.return_type) |rt| return rt;
        return null;
    }
    // A FUNCTION-TYPED ctor property invoked as the initializer takes the function type's return.
    for (c.primary_params) |*pp| {
        if (!std.mem.eql(u8, pp.name.name, fname)) continue;
        if (pp.ty.function) |ft| return &ft.ret;
        return null;
    }
    return null;
}

fn registerClassMemberPropTypeHeads(ctx: *BuildCtx, c: *ast.Class, cfqn: []const u8) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    for (c.members) |*m| {
        if (m.* != .Property) continue;
        const prop = m.Property;
        const ty_opt: ?*const ast.TypeRef = declaredMemberPropType(c, prop);
        if (ty_opt) |ty| {
            if (classPropHead(c, ty)) |head| {
                try putClassPropHead(module, c.name.name, cfqn, prop.name.name, head);
                try notePropTypeRef(a, module, c, prop.name.name, ty);
            }
        } else if (propCtorHeadEvidence(prop, decls, module, c)) |head| {
            try putClassPropHead(module, c.name.name, cfqn, prop.name.name, head);
        } else if (prop.init != null and memberSizedInitHead(c, prop.init.?) != null) {
            try putClassPropHead(module, c.name.name, cfqn, prop.name.name, memberSizedInitHead(c, prop.init.?).?);
        } else if (prop.init) |init| {
            if (literalTypeHead(init)) |head| {
                try putClassPropHead(module, c.name.name, cfqn, prop.name.name, head);
            }
        }
    }
}

fn registerNestedClassPropTypeHeads(ctx: *BuildCtx, c: *ast.Class) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    // A NESTED class's own properties register under its simple name; the walk above reaches only
    // top-level classes.
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
            if (nprop.ty) |ty| {
                if (classPropHead(nested, ty)) |head| {
                    try module.registry.class_prop_type_heads.put(.{ .a = nested.name.name, .b = nprop.name.name }, head);
                    try notePropTypeRef(a, module, nested, nprop.name.name, ty);
                }
            } else if (nprop.init) |init| {
                if (literalTypeHead(init)) |head| {
                    try module.registry.class_prop_type_heads.put(.{ .a = nested.name.name, .b = nprop.name.name }, head);
                }
            }
        }
    }
}

fn registerCompanionPropTypeHeads(ctx: *BuildCtx, c: *ast.Class) Allocator.Error!void {
    const allocator = ctx.allocator;
    const module = ctx.module;
    const decls = ctx.decls;
    // COMPANION property heads register under the companion's lifted name (`Byte$Companion`).
    for (c.members) |*cm| {
        if (cm.* != .Class) continue;
        const cobj = &cm.Class;
        if (!cobj.is_companion) continue;
        const ckey = try std.fmt.allocPrint(allocator, "{s}$Companion", .{c.name.name});
        for (cobj.members) |*om| {
            if (om.* != .Property) continue;
            const cprop = om.Property;
            if (cprop.ty) |ty| {
                try module.registry.class_prop_type_heads.put(.{ .a = ckey, .b = cprop.name.name }, ty.x().qualified_path orelse ty.name.name);
            } else if (cprop.init) |init| {
                if (literalTypeHead(init)) |head| {
                    try module.registry.class_prop_type_heads.put(.{ .a = ckey, .b = cprop.name.name }, head);
                } else if (propCtorHeadEvidence(cprop, decls, module, c)) |head| {
                    try module.registry.class_prop_type_heads.put(.{ .a = ckey, .b = cprop.name.name }, head);
                }
            }
        }
    }
}

fn registerObjectPropTypeHeads(ctx: *BuildCtx, o: *ast.ObjectDecl) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const ofqn = try declFqnAt(a, module, fqn_overrides, o.span, package_prefix, o.name.name);
    for (o.members) |*m| {
        if (m.* != .Property) continue;
        const prop = m.Property;
        if (prop.ty) |ty| {
            try putClassPropHead(module, o.name.name, ofqn, prop.name.name, ty.x().qualified_path orelse ty.name.name);
        } else if (propCtorHeadEvidence(prop, decls, module, null)) |head| {
            try putClassPropHead(module, o.name.name, ofqn, prop.name.name, head);
        }
    }
}

/// Property type heads that a declaration does not state and the early table
/// pass cannot infer.
///
/// That pass runs before any class shell is reserved, so its constructor-call
/// channel asks a module that knows none of this build's classes: a property
/// initialised from a class declared alongside it goes untyped, and every call
/// on it dispatches by name. In one compose program that is 729 member-call
/// sites with no receiver type, `changeListWriter` alone accounting for 148.
///
/// This runs after the class shells and the file import scopes exist, and
/// resolves the initializer's callee the way Kotlin resolves a name: the file's
/// named imports, then its own package, then a module-wide simple name only
/// when it denotes one class. The head recorded is the class's FQN, because two
/// packages declare `ComposerChangeListWriter` and a simple head would bind
/// whichever the class list happened to hold first.
///
/// Additive: a head the earlier pass recorded is never replaced.
fn registerInferredPropertyTypeHeads(ctx: *BuildCtx) Allocator.Error!void {
    // Iterate to stability. A property's inferred head is evidence for the next
    // property's initializer, so one round settles only the first link of every
    // chain; the census showed the rest of them as receivers with no type. The
    // cap is a guard, not a budget — the corpus settles in a handful of rounds.
    var round: usize = 0;
    while (round < 8) : (round += 1) {
        ctx.inferred_prop_heads_grew = false;
        for (ctx.decls) |*d| {
            switch (d.*) {
                .Class => |*c| try inferClassPropHeads(ctx, c),
                .Object => |*o| try inferObjectPropHeads(ctx, o),
                else => {},
            }
        }
        if (!ctx.inferred_prop_heads_grew) break;
    }
    if (runtime.envOnce("KLIO_INFER_ROUNDS") != null)
        std.debug.print("[infer-rounds] {d}\n", .{round + 1});
}

fn inferClassPropHeads(ctx: *BuildCtx, c: *ast.Class) Allocator.Error!void {
    const cfqn = try declFqnAt(ctx.a, ctx.module, ctx.fqn_overrides, c.span, ctx.package_prefix, c.name.name);
    for (c.members) |*m| {
        switch (m.*) {
            .Property => |prop| {
                if (declaredMemberPropType(c, prop) != null) continue;
                try fillPropHead(ctx, c.name.name, cfqn, prop);
            },
            // A companion registers under `{Owner}$Companion`, the key the
            // declared-type pass and `barePathSelfTypeRef` both use.
            //
            // A nested class does NOT recurse. Lowering keys a nested owner by
            // its lifted name (`Outer$Nested`), so a row under the nested
            // class's simple name is never read for it — and that simple name
            // is the key of any top-level class spelled the same, whose own
            // property of that name would then resolve to the nested class's
            // type. The declared-type pass has the same key, but it records
            // far fewer rows; filling every gap turned a latent collision into
            // an observable one.
            .Class => |*nested| {
                if (!nested.is_companion) continue;
                var ckey_buf: [192]u8 = undefined;
                const ckey = std.fmt.bufPrint(&ckey_buf, "{s}$Companion", .{c.name.name}) catch continue;
                const owned = try ctx.a.dupe(u8, ckey);
                for (nested.members) |*cm| {
                    if (cm.* != .Property) continue;
                    if (declaredMemberPropType(nested, cm.Property) != null) continue;
                    try fillPropHead(ctx, owned, owned, cm.Property);
                }
            },
            else => {},
        }
    }
}

fn inferObjectPropHeads(ctx: *BuildCtx, o: *ast.ObjectDecl) Allocator.Error!void {
    const ofqn = try declFqnAt(ctx.a, ctx.module, ctx.fqn_overrides, o.span, ctx.package_prefix, o.name.name);
    for (o.members) |*m| {
        if (m.* != .Property) continue;
        const prop = m.Property;
        if (prop.ty != null) continue;
        try fillPropHead(ctx, o.name.name, ofqn, prop);
    }
}

fn fillPropHead(ctx: *BuildCtx, simple: []const u8, fqn: []const u8, prop: *const ast.Property) Allocator.Error!void {
    const module = ctx.module;
    if (module.registry.class_prop_type_heads.get(.{ .a = simple, .b = prop.name.name }) != null) return;
    const head = inferredPropHead(module, simple, prop) orelse return;
    try putClassPropHead(module, simple, fqn, prop.name.name, head);
    ctx.inferred_prop_heads_grew = true;
}

/// The type head of an unannotated property, from whichever channel its
/// initializer offers. A constructor call names its class; a literal or an
/// arithmetic fold over literals names a builtin; a call to a function with a
/// DECLARED return type names that. Each is a fact the declaration already
/// carries, so none of them waits on a resolution.
fn inferredPropHead(module: *ir.Module, owner: []const u8, prop: *const ast.Property) ?[]const u8 {
    if (inferredCtorHead(module, prop)) |h| return h;
    const src = build_scan.propHeadSourceExpr(prop) orelse return null;
    if (build_scan.constExprTypeHead(module, src)) |h| return h;
    if (declaredReturnHead(module, src)) |h| return h;
    return classifierMemberHead(module, owner, src, 0);
}

/// `val x = Owner.prop`, where `Owner` names a class or object: the head is
/// whatever that class records for `prop`. The dominant shape by a wide margin
/// — 5 012 of 6 972 initializers the inference could not type on a compose
/// program are a `Member` — and the one the iteration is for, since the head it
/// reads may itself have been inferred on an earlier round.
fn classifierMemberHead(module: *ir.Module, owner: []const u8, src: *const ast.Expr, depth: u8) ?[]const u8 {
    if (depth > 4) return null;
    if (src.* != .Member) return null;
    const m = src.Member;
    if (m.safe) return null;
    const recv_head = classifierHeadOf(module, owner, m.receiver, depth) orelse return null;
    // Under the FQN first: a lifted twin (`SlotTable` in two packages) records
    // its rows under its mangled name and its FQN, and never under the bare
    // tail, which would be the other twin's key if it were anyone's.
    if (module.registry.class_prop_type_heads.get(.{ .a = recv_head, .b = m.name.name })) |h| return h;
    const simple = if (std.mem.findScalarLast(u8, recv_head, '.')) |d| recv_head[d + 1 ..] else recv_head;
    return module.registry.class_prop_type_heads.get(.{ .a = simple, .b = m.name.name });
}

/// The class a receiver expression names: a bare classifier, the declaring
/// class's own property whose head is recorded (`table` in `private val
/// addressSpace = table.addressSpace`, the constructor property beside it),
/// or a member read whose own head is recorded. A package segment or an
/// unrecorded local stops the walk.
fn classifierHeadOf(module: *ir.Module, owner: []const u8, e: *const ast.Expr, depth: u8) ?[]const u8 {
    switch (e.*) {
        .Path => |p| {
            if (p.segments.len != 1) return null;
            const nm = p.segments[0].name;
            if (nm.len == 0) return null;
            if (!std.ascii.isUpper(nm[0])) {
                // The recorded head is the declaration's spelling, `SlotTable`
                // for `val table: SlotTable`; the rows it keys are under the
                // class's row name and FQN, so resolve it where it was written.
                const h = module.registry.class_prop_type_heads.get(.{ .a = owner, .b = nm }) orelse return null;
                if (std.mem.findScalar(u8, h, '.') != null) return h;
                const cid = classIdInFileScope(module, h, p.segments[0].span.file) orelse return h;
                if (cid.int() >= module.classes.items.len) return h;
                const c = &module.classes.items[cid.int()];
                return if (c.fqn.len == 0) h else c.fqn;
            }
            const cid = classIdInFileScope(module, nm, p.segments[0].span.file) orelse return null;
            if (cid.int() >= module.classes.items.len) return null;
            const c = &module.classes.items[cid.int()];
            return if (c.fqn.len == 0) null else c.fqn;
        },
        .Member => return classifierMemberHead(module, owner, e, depth + 1),
        else => return null,
    }
}

/// The declared return head of `f(...)` where `f` is a plain single-name callee
/// and every visible declaration of that name agrees. An inferred return is no
/// answer: `return_ty` is a `Unit` placeholder until `return_ty_declared`.
fn declaredReturnHead(module: *ir.Module, src: *const ast.Expr) ?[]const u8 {
    if (src.* != .Call) return null;
    const callee = src.Call.callee;
    if (callee.* != .Path or callee.Path.segments.len != 1) return null;
    const nm = callee.Path.segments[0].name;
    if (nm.len == 0 or std.ascii.isUpper(nm[0])) return null;
    var head: ?[]const u8 = null;
    for (module.funcsBySimpleName(nm)) |fid| {
        const f = module.funcById(fid) orelse return null;
        if (!f.return_ty_declared) return null;
        const h = std.mem.trimEnd(u8, f.return_ty.name, "?");
        if (h.len == 0) return null;
        if (head) |prev| {
            if (!std.mem.eql(u8, prev, h)) return null;
        } else head = h;
    }
    const h = head orelse return null;
    // Only a head that names a real class: a type parameter or a builtin the
    // class table does not carry is no receiver type.
    if (module.classId(h) == null and module.classIdByFqn(h) == null) return null;
    return h;
}

/// The FQN of the class a property's initializer constructs, resolved in the
/// file that declares the property. Only a name that IS a class counts: a
/// same-shaped factory call may return something else entirely.
fn inferredCtorHead(module: *ir.Module, prop: *const ast.Property) ?[]const u8 {
    const src = propHeadSourceExpr(prop) orelse return null;
    if (src.* != .Call) return null;
    const callee = src.Call.callee;
    if (callee.* != .Path or callee.Path.segments.len != 1) return null;
    const seg = callee.Path.segments[0];
    const nm = seg.name;
    if (nm.len == 0 or !std.ascii.isUpper(nm[0])) return null;
    // A short all-caps head is a type parameter, not a class.
    if (nm.len <= 2) return null;
    const cid = classIdInFileScope(module, nm, seg.span.file) orelse return null;
    if (cid.int() >= module.classes.items.len) return null;
    // A capitalised callee that names a class is not always its constructor:
    // Kotlin resolves `Boxy(5)` to `fun Boxy(n: Int)` when `class Boxy` has no
    // one-argument constructor, and the class's head would name the wrong type.
    if (build_scan.ctorHeadOutrankedByFactory(module, nm, src.Call.args.len, cid)) return null;
    const cls = &module.classes.items[cid.int()];
    // An interface head is kept deliberately: a `fun interface` constructor
    // call names exactly that type.
    if (cls.fqn.len == 0) return null;
    return cls.fqn;
}

/// Kotlin's resolution order for an unqualified classifier: the file's named
/// imports, its own package, then a module-wide simple name only when one class
/// answers to it.
fn classIdInFileScope(module: *ir.Module, name: []const u8, file: ir.FileId) ?ir.ClassId {
    if (module.classIdExactImport(name, file)) |cid| return cid;
    if (module.packageOfFile(file)) |pkg| {
        if (pkg.len != 0) {
            var buf: [256]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{s}.{s}", .{ pkg, name })) |fqn| {
                if (module.classIdByFqn(fqn)) |cid| return cid;
            } else |_| {}
        }
    }
    return module.uniqueClassIdBySimpleName(name);
}

fn registerClassSuperNameChains(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const file_classes = &ctx.file_classes;
    // Nearest first, so body lowering can rank extension receivers against the enclosing class.
    {
        var it = file_classes.iterator();
        while (it.next()) |e| {
            if (module.registry.class_super_names.contains(e.key_ptr.*)) continue;
            var chain: std.ArrayList([]const u8) = .empty;
            var seen = StringSet.init(a);
            defer seen.deinit();
            try seen.put(e.key_ptr.*, {});
            try collectHierarchySuperNames(a, e.value_ptr.get(), file_classes, &chain, &seen);
            // Every enum class IS-A `kotlin.Enum` implicitly, so the relation is recorded.
            if (e.value_ptr.get().is_enum and !seen.contains("Enum")) {
                try chain.append(a, "Enum");
            }
            const super_chain = try chain.toOwnedSlice(a);
            try module.registry.class_super_names.put(e.key_ptr.*, super_chain);
            module.registry.noteClassChainChange();
            // Also keyed by fqn, so a receiver whose simple name collides across packs resolves its OWN chain.
            {
                const cfqn = try resolveFqn(a, fqn_overrides, e.value_ptr.get().name.span, package_prefix, e.key_ptr.*);
                if (!std.mem.eql(u8, cfqn, e.key_ptr.*) and
                    !module.registry.class_super_names.contains(cfqn))
                {
                    try module.registry.class_super_names.put(cfqn, super_chain);
                }
            }
            // Declared upper bounds of the class's type parameters, for the collection-stub bridge disproof
            // at dispatch. Unbounded params record an inert `Any` bound: dispatch needs the complete NAME
            // list to tell a class-type-param-typed method parameter from an unrelated same-named class.
            if (!module.registry.class_type_param_bounds.contains(e.key_ptr.*)) {
                const class = e.value_ptr.get();
                if (try collectClassTypeParamBounds(a, class)) |bounds| {
                    try module.registry.class_type_param_bounds.put(e.key_ptr.*, bounds);
                }
            }
        }
    }
}

fn registerShadowedStorageProps(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const file_classes = &ctx.file_classes;
    // Kotlin gives a private stored property shadowing a supertype's same-named declaration its own
    // cell, so construction and the accessors use the owner-mangled key. A base's
    // classes carry their entries, so only this build's own classes are walked.
    {
        var own = OwnClasses.of(ctx);
        while (own.next()) |oc| {
            const cname = oc.name;
            const chain = module.registry.class_super_names.get(cname) orelse continue;
            if (chain.len == 0) continue;
            const c = oc.class;
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
                            // Only a STORED supertype property forces distinct cells.
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
                    try record(module, a, cname, chain, file_classes, p.name.name, false);
                } else {
                    // A non-private ctor-param property matching a stored supertype property is necessarily an
                    // `override`: kotlinc rejects the shadow form, and the parser drops the modifier on params.
                    try record(module, a, cname, chain, file_classes, p.name.name, true);
                }
            }
            for (c.members) |*m| {
                if (m.* != .Property) continue;
                const pr = m.Property;
                if (pr.getter != null or pr.delegate != null) continue;
                if (pr.visibility == .Private) {
                    try record(module, a, cname, chain, file_classes, pr.name.name, false);
                } else if (pr.is_override and pr.init != null) {
                    try record(module, a, cname, chain, file_classes, pr.name.name, true);
                }
            }
        }
    }
}

/// Install the lift-time alias, mangle, enclosing-class and companion-singleton tables.
fn installLiftedNameTables(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const nested_object_aliases = &ctx.nested_object_aliases;
    const mangled_nested = &ctx.mangled_nested;
    const enclosing_class = &ctx.enclosing_class;
    const companion_singletons = &ctx.companion_singletons;
    {
        var it = nested_object_aliases.iterator();
        while (it.next()) |e| {
            var inner = runtime.NameHashMap([]const u8).init(a);
            var iit = e.value_ptr.iterator();
            while (iit.next()) |ie| try inner.put(ie.key_ptr.*, ie.value_ptr.*);
            try module.registry.nested_object_aliases.put(e.key_ptr.*, inner);
        }
    }
    // Mangled nested-class names, so `x is Outer.Inner` binds the lifted class.
    {
        var it = mangled_nested.iterator();
        while (it.next()) |e| try module.registry.mangled_nested.put(e.key_ptr.*, e.value_ptr.*);
        module.registry.noteClassChainChange();
    }
    // The enclosing-class chain backs the scope-true alias walk; both tables install before lowering.
    {
        var it = enclosing_class.iterator();
        while (it.next()) |e| try module.registry.enclosing_class.put(e.key_ptr.*, e.value_ptr.*);
    }
    {
        var it = companion_singletons.iterator();
        while (it.next()) |e| try module.registry.companion_singletons.put(e.key_ptr.*, e.value_ptr.*);
    }
}

/// Register the member ASTs the lowerer resolves against: inline-member owners, member property
/// ASTs, and class supertype references.
fn installMemberAstTables(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const file_classes = &ctx.file_classes;
    // The owner class of every inline member fn, keyed by AST pointer, so a bare call to a name
    // declared inline in several unrelated classes binds the enclosing class's overload.
    {
        // A base built in this process, on this thread, and extended once in
        // place still has every base class registered from its own build:
        // this build adds its declarations to those tables. Any other base
        // starts the tables over, since what they held points into a build
        // that is gone or into an image's decoded declarations.
        const live = if (ctx.base) |bs| bs.tables_live and ctx.own_base else false;
        if (live) {
            @constCast(ctx.base.?).tables_live = false;
            for (decls) |*d| {
                if (d.* != .Class) continue;
                const c = &d.Class;
                registerInlineMemberOwners(c.members, c.name.name);
                registerMemberPropAsts(a, c.members, c.name.name, resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name) catch null);
                ir.lower.registerClassSupertypeRefs(c.name.name, c.supertypes);
                registerClassSupertypes(c.members);
            }
        } else {
            ir.lower.resetInlineMemberOwners();
            ir.lower.resetMemberPropAsts();
            ir.lower.resetClassSupertypeRefs();
            ir.lower.resetMemberExtPropRecv();
            // Same lifetime rule: the registered expression-body member ASTs point into the previous build's arena.
            ir.lower.resetExprBodyMembers();
            ir.lower.resetExprBodyFnIds();
            var fcit = file_classes.iterator();
            while (fcit.next()) |e| {
                registerInlineMemberOwners(e.value_ptr.get().members, e.value_ptr.get().name.name);
                registerMemberPropAsts(a, e.value_ptr.get().members, e.value_ptr.get().name.name, resolveFqn(a, fqn_overrides, e.value_ptr.get().span, package_prefix, e.value_ptr.get().name.name) catch null);
                ir.lower.registerClassSupertypeRefs(e.value_ptr.get().name.name, e.value_ptr.get().supertypes);
                registerClassSupertypes(e.value_ptr.get().members);
            }
        }
        for (decls) |*d| {
            switch (d.*) {
                .Object => |*o| registerMemberPropAsts(a, o.members, o.name.name, declFqnAt(a, module, fqn_overrides, o.span, package_prefix, o.name.name) catch null),
                .Class => |*c| registerMemberPropAsts(a, c.members, c.name.name, declFqnAt(a, module, fqn_overrides, c.span, package_prefix, c.name.name) catch null),
                else => {},
            }
        }
        registerClassSupertypes(decls);
    }
}

fn installInlineFnTables(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const base = ctx.base;
    const decls = ctx.decls;
    // Every `inline fun` body, available to the lowerer by simple name. The three tables install
    // into build-scoped thread-locals, each `deinit`ing the table left by the PREVIOUS build, whose
    // `a` is typically an already-torn-down per-run arena, so the containers are backed by the
    // process heap while keys and value slices stay in the build arena.
    const tl = runtime.slab.allocator;
    {
        var inline_fns = runtime.NameHashMap(std.ArrayList(FF(ast.Function))).init(a);
        // Base inline fns first, preserving whole-program declaration order per overload list.
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
        var frozen = runtime.NameHashMap([]const FF(ast.Function)).init(tl);
        var it = inline_fns.iterator();
        while (it.next()) |e| {
            try frozen.put(e.key_ptr.*, try e.value_ptr.toOwnedSlice(a));
        }
        inline_fns.deinit();
        ir.lower.setInlineFnAsts(frozen);
        // setInlineFnAsts dropped the previous build's FuncId-keyed registrations; replaying the base's
        // keeps user calls resolving to a base inline fn splicing.
        if (base) |bs| {
            for (bs.inline_ids) |entry| try ir.lower.registerInlineFnId(entry.id, entry.f);
            // Inline bodies in a loaded base are deferred markers, so the section and decoder install
            // here, decoded into the base's process-lifetime arena.
            ir.lower.setDeferredSection(bs.deferred_bodies, bs.arena, image.decodeDeferredBody);
        }

        // Default-import host bindings shadow same-simple-name inline fns. The name domain comes from
        // `stdlib.noteBareNameMapping`, so the answer has one source.
        var owned = runtime.NameHashMap([]const u8).init(a);
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
}

fn installTopLevelPropNames(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const base = ctx.base;
    const module = ctx.module;
    const decls = ctx.decls;
    const func_fqn_overrides = ctx.func_fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const tl = runtime.slab.allocator;
    // Top-level property names with each declaration's scoping identity, so a bare read ranks under
    // Kotlin scoping exactly as a bare call does.
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
}

/// Record the file's imports, keyed by declaring file: non-wildcard paths by leaf name,
/// wildcard imports as dotted packages.
fn registerFileImports(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const file = ctx.file;
    for (file.imports) |*imp| {
        if (imp.path.len == 0) continue;
        if (imp.wildcard) {
            // `import pkg.*`: the package is recorded per file so the symbol index can rank
            // wildcard-imported candidates above the implicitly-imported built-ins.
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
        if (!fgop.found_existing) fgop.value_ptr.* = runtime.NameHashMap(std.ArrayList(ir.ModuleRegistry.ImportPath)).init(a);
        try module.registry.noteImportAliasName(imp.span.file, leaf);
        const lgop = try fgop.value_ptr.getOrPut(leaf);
        if (!lgop.found_existing) lgop.value_ptr.* = .empty;
        // Kotlin keeps every same-leaf import in scope, a second one being an ambiguity at the use site
        // rather than a shadow, so the leaf maps to ALL its paths.
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
}

fn reserveClassShells(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const object_spans = &ctx.object_spans;
    // Every class is pre-registered by its FULLY-QUALIFIED name, so resolution is
    // order-independent and same-simple-name classes in different packages keep separate slots.
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
        const cls_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
        const cid = try module.reserveClassFqn(a, c.name.name, cfqn, cls_pkg, c.is_inner);
        module.classes.items[cid.int()].is_object = module.classes.items[cid.int()].is_object or
            spanNamesObject(object_spans.items, c.span);
    }
}

fn linkReservedClassSupertypes(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    // Linked before any method body lowers, so static applicability can prove subtype arguments
    // for calls into forward top-level declarations.
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
        const cls_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
        try ir.lower.decl.populateClassSupertypes(module, c, cfqn, cls_pkg);
    }
}

fn reserveClassMemberHeaders(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    // Reserved after every class shell exists but before any method body lowers, so forward
    // references, inherited calls and same-arity overloads share stable identities.
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
        const cls_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
        try ir.lower.decl.reserveMemberHeaders(module, c, cfqn, cls_pkg);
    }
}

fn registerTypeAliasShapes(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    // Typealias head tags register BEFORE body lowering, so lambda-arity detection resolves an
    // aliased function-typed parameter to its `Function{N}` tag at the call site.
    for (decls) |*d| {
        if (d.* != .TypeAlias) continue;
        const ta = &d.TypeAlias;
        const type_params = try a.alloc([]const u8, ta.type_params.len);
        for (ta.type_params, type_params) |*param, *out| out.* = param.name.name;
        const alias_shape = ir.ModuleRegistry.TypeAliasShape{
            .type_params = type_params,
            .target = try ir.lower.decl.loweredTypeRef(a, &ta.target, true),
        };
        try module.registry.putTypeAliasType(ta.name.name, alias_shape);
        const alias_fqn = try resolveFqn(
            a,
            fqn_overrides,
            ta.span,
            package_prefix,
            ta.name.name,
        );
        try module.registry.putTypeAliasType(alias_fqn, alias_shape);
        if (ta.target.function) |ft| {
            const tag = try std.fmt.allocPrint(a, "Function{d}", .{ft.params.len});
            try module.registry.type_aliases.put(ta.name.name, tag);
            if (ft.receiver != null) {
                try module.registry.recv_fn_aliases.put(ta.name.name, @intCast(@min(ft.params.len, 255)));
            }
        }
    }
}

fn registerClassTypeAliasShapes(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const file_classes = &ctx.file_classes;
    // A `typealias` in a class body is in scope inside that class and reachable as `Owner.Alias`;
    // its target is written in the class's own scope, so it can name a nested class.
    var alias_class_it = file_classes.valueIterator();
    while (alias_class_it.next()) |fc| {
        const c: *const ast.Class = fc.get();
        for (c.members) |*m| {
            if (m.* != .TypeAlias) continue;
            const ta = &m.TypeAlias;
            const type_params = try a.alloc([]const u8, ta.type_params.len);
            for (ta.type_params, type_params) |*param, *out| out.* = param.name.name;
            var target = try ir.lower.decl.loweredTypeRef(a, &ta.target, true);
            if (std.mem.findScalar(u8, target.name, '.') == null) {
                if (module.classId(c.name.name)) |owner_id| {
                    if (module.classIdNestedIn(owner_id, target.name)) |nested_id| {
                        if (nested_id.int() < module.classes.items.len) target.name = module.classes.items[nested_id.int()].name;
                    }
                }
            }
            const alias_shape = ir.ModuleRegistry.TypeAliasShape{ .type_params = type_params, .target = target };
            const qualified = try std.fmt.allocPrint(a, "{s}.{s}", .{ c.name.name, ta.name.name });
            try module.registry.putTypeAliasType(qualified, alias_shape);
            if (!module.registry.type_alias_types.contains(ta.name.name)) {
                try module.registry.putTypeAliasType(ta.name.name, alias_shape);
            }
        }
    }
    ir.lower.setTypeAliasTags(&module.registry.type_aliases);
}

fn fillReservedClassPrimaryParams(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    // Filled BEFORE any class method body lowers: bodies lower in declaration order, so a
    // constructor call to a class declared later must already see its parameter types.
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
}

fn registerTopLevelFuncHeaders(ctx: *BuildCtx) Allocator.Error!void {
    const decls = ctx.decls;
    // Phase 1 of two-phase consumption: every top-level function's HEADER registers before any body
    // lowers, so phase-2 lowering resolves bare calls against the full package-qualified set.
    var n: usize = 0;
    for (decls) |*d| {
        if (d.* == .Function) n += 1;
    }
    // The tables grow once for the whole pass rather than doubling through it.
    const m = ctx.module;
    try m.funcs.ensureUnusedCapacity(ctx.a, n);
    try m.func_index.ensureUnusedCapacity(ctx.a, n);
    try m.func_name_index.ensureUnusedCapacity(@intCast(n));
    try m.decl_user_params.ensureUnusedCapacity(@intCast(n));
    try m.decl_user_arity.ensureUnusedCapacity(@intCast(n));
    try m.decl_user_sig.ensureUnusedCapacity(@intCast(n));
    try m.decl_span.ensureUnusedCapacity(@intCast(n));
    try m.decl_sigs.ensureUnusedCapacity(@intCast(n));
    for (decls) |*d| {
        if (d.* == .Function) try registerTopLevelFuncHeader(ctx, &d.Function);
    }
}

/// Reserve one top-level function's identity: FQN, package, receiver, signature, bounds.
fn registerTopLevelFuncHeader(ctx: *BuildCtx, f: *ast.Function) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const func_fqn_overrides = ctx.func_fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const stub_ids = &ctx.stub_ids;
    const id = module.nextFuncId();
    const fqn = try resolveFqn(a, func_fqn_overrides, f.span, package_prefix, f.name.name);
    const receiver_ty: ?ir.TypeRef = if (f.receiver_type) |rt|
        try ir.lower.decl.loweredTypeRef(a, rt, true)
    else
        null;
    const receiver_abi_name: ?[]const u8 = if (f.receiver_type) |rt|
        rt.x().qualified_path orelse rt.name.name
    else
        null;
    const host_symbol = stdlib.declarationHostSymbol(
        fqn,
        receiver_abi_name,
        f.name.name,
    );
    const stub_params = try headerStubParams(ctx, f, receiver_ty);
    // A top-level expression body with no declared return is derivable from
    // its AST by a caller lowered before it, under the id no call site can
    // misname the way it can a per-file owner.
    try ir.lower.registerExprBodyFn(id.int(), f);
    try module.funcs.append(a, .{
        .id = id,
        .name = f.name.name,
        .fqn = fqn,
        .package = decl_pkg.get(f.span) orelse packageOfFqn(fqn, f.name.name),
        .params = stub_params,
        .return_ty = if (f.return_type) |rt|
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
        .low_priority = ir.lower.decl.isLowPriorityOverload(f),
        .deprecated_error = ir.lower.decl.annotationsAreDeprecatedError(f.annotations),
        .is_expect = f.is_expect,
            .extra = try ir.lower.decl.headerCtxExtra(a, f),
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
        // Declared parameter types at full structural granularity, rendered by the same `loweredTypeRef`
        // body params use, so the symbol index judges signature identity identically for a forward
        // reference and for its later-lowered body.
        const sig = try a.alloc(ir.TypeRef, f.params.len);
        for (f.params, 0..) |*p, i| {
            sig[i] = try ir.lower.decl.loweredTypeRef(a, &p.ty, true);
        }
        try module.decl_user_sig.put(id.int(), sig);
        decl_sig = sig;
    }
    const pn = try ir.lower.decl.declParamNames(a, f);
    try module.decl_sigs.put(id.int(), .{
        .receiver_ty = receiver_ty,
        .arity = arity,
        .sig = decl_sig,
        .param_names = pn.names,
        .param_defaults = pn.defaults,
        .return_ty = if (f.return_type) |rt| try ir.lower.decl.loweredTypeRef(a, rt, true) else null,
        .kind = if (f.receiver_type != null) .top_level_extension else .plain,
        .visibility = f.visibility,
        .is_inline = f.is_inline,
        .is_suspend = f.is_suspend,
        .has_body = f.body != null,
        .host_symbol = host_symbol,
    });
    try module.decl_span.put(id.int(), f.span);
    if (f.body != null) try module.decl_ast_body.put(id.int(), {});
    try registerHeaderTypeParams(ctx, f, id);
    // The inline-fn AST is keyed by the header stub's FuncId, so a bare call splices exactly the
    // declaration the symbol index resolved.
    if (f.is_inline and f.body != null) {
        try ir.lower.registerInlineFnId(id.int(), FF(ast.Function).fromPtr(f));
    }
    // An expression body with no declared return is the only shape whose type
    // a caller has to derive, and the id is how a top-level one is reached:
    // its owner is the synthesized per-file class, which no call site names.
    if (f.return_type == null) {
        if (f.body) |*fb| {
            if (fb.* == .Expr) try ir.lower.registerExprBodyFnId(id.int(), FF(ast.Function).fromPtr(f));
        }
    }
    try stub_ids.append(a, id);
}

fn headerStubParams(ctx: *BuildCtx, f: *const ast.Function, receiver_ty: ?ir.TypeRef) Allocator.Error![]Param {
    const a = ctx.a;
    // The header stub carries the full declared parameter list, not a receiver placeholder: class
    // methods lower between phase 1 and phase 2 and read `Func.params` for their call-site shapes.
    var stub_params: []Param = &.{};
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
    return stub_params;
}

fn registerHeaderTypeParams(ctx: *BuildCtx, f: *const ast.Function, id: FuncId) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    // Type-parameter names register at header time, so a body lowered before this declaration's own
    // already sees the generic signature.
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
            const w = runtime.envOnce("KLIO_HDR_BOUNDS_SKIP") orelse break :blk false;
            break :blk std.mem.find(u8, w, f.name.name) != null;
        };
        // `KLIO_HDR_BOUNDS=0` disables this; `KLIO_HDR_BOUNDS_SKIP` bisects by name.
        const hdr_on = blk: {
            const w = runtime.envOnce("KLIO_HDR_BOUNDS") orelse break :blk true;
            break :blk !std.mem.eql(u8, w, "0");
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
}

fn registerCallableExtensionProps(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    // Registered before any body lowers. Kotlin permits `receiver.property(args)` when the property's
    // value is a function; without this shape the call is indistinguishable from a member call.
    for (decls) |*d| {
        if (d.* != .Property) continue;
        const p = d.Property;
        const recv = p.receiver_type orelse continue;
        const prop_ty = p.ty orelse continue;
        const fn_ty = prop_ty.function orelse continue;
        const recv_name: []const u8 = if (recv.x().qualified_path) |qp|
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
}

fn registerReceiverFnPropHeads(ctx: *BuildCtx) Allocator.Error!void {
    const module = ctx.module;
    const file_classes = &ctx.file_classes;
    // Recorded BEFORE any body lowering, since method bodies consult the registry as they lower.
    // Walks `file_classes`, not `decls`, which in an extending build holds only user declarations.
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
}

fn lowerClassBodies(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const file_classes = &ctx.file_classes;
    const nested_outer_members = &ctx.nested_outer_members;
    // Classes lower after the top-level function headers register, so a method body's bare call to a
    // sibling top-level function resolves against the complete header set.
    // Jobs point at the empty set; a lazy build's outlive this call.
    const empty_set = try a.create(StringSet);
    empty_set.* = StringSet.init(a);
    defer if (ctx.lazy == null) {
        empty_set.deinit();
        a.destroy(empty_set);
    };
    // Every class's shell and member sets first, then every member body, then
    // each class sealed in declaration order: a member sees the same module
    // whichever class it belongs to and whichever thread lowers it.
    const Begun = struct { state: *ir.lower.decl.ClassState, first_job: usize, n_members: usize, fqn: []const u8, pkg: []const u8 };
    var begun: std.ArrayList(Begun) = .empty;
    defer begun.deinit(a);
    var jobs: std.ArrayList(body_pool.Job) = .empty;
    defer jobs.deinit(a);
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        const extras: *const StringSet = nested_outer_members.getPtr(c.name.name) orelse empty_set;
        const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
        const cls_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
        const prev = ir.lower.decl.enterClassContext(cfqn, cls_pkg);
        const state = try ir.lower.decl.beginClass(module, c, file_classes, extras);
        ir.lower.decl.leaveClassContext(prev);
        try begun.append(a, .{ .state = state, .first_job = jobs.items.len, .n_members = c.members.len, .fqn = cfqn, .pkg = cls_pkg });
        for (c.members) |*m| {
            if (m.* != .Function or m.Function.body == null) continue;
            try jobs.append(a, .{
                .f = &m.Function,
                .id = FuncId.from(0),
                .pkg = cls_pkg,
                .member = .{
                    .owner_class = c.name.name,
                    .own_members = state.own_member_names,
                    .enclosing = extras,
                    .own_member_arity = state.own_member_arity,
                    .class_fqn = cfqn,
                    .class_pkg = cls_pkg,
                },
            });
        }
    }
    const lowered = if (ctx.lazy) |p| try deferMemberJobs(ctx, p, jobs.items) else try lowerJobs(ctx, jobs.items);
    defer a.free(lowered);
    for (begun.items) |b| {
        const c = b.state.c;
        const per_member = try a.alloc(?ir.Func, b.n_members);
        defer a.free(per_member);
        @memset(per_member, null);
        var next = b.first_job;
        for (c.members, per_member) |*m, *slot| {
            if (m.* != .Function or m.Function.body == null) continue;
            slot.* = lowered[next];
            next += 1;
        }
        const prev = ir.lower.decl.enterClassContext(b.fqn, b.pkg);
        defer ir.lower.decl.leaveClassContext(prev);
        _ = try ir.lower.decl.finishClassOpts(b.state, per_member, ctx.lazy != null);
    }
}

/// A lazy build's member bodies: each reserved slot's header stands in for
/// its body and the job is recorded under the slot's id. A member without a
/// reserved slot lowers now, as its placement would allocate its id.
fn deferMemberJobs(ctx: *BuildCtx, p: *lazy.Plan, jobs: []const body_pool.Job) Allocator.Error![]ir.Func {
    const a = ctx.a;
    const out = try a.alloc(ir.Func, jobs.len);
    errdefer a.free(out);
    for (jobs, out) |job, *slot| {
        if (!bodyWritesRegistry(job)) {
            if (ctx.module.funcByDeclSpan(job.f.name.span)) |id| {
                const header = ctx.module.funcByIdMut(id).?;
                header.lazy_deferred = true;
                slot.* = header.*;
                try p.deferBody(id, job);
                continue;
            }
        }
        slot.* = try body_pool.lowerJob(ctx.module, job, &ctx.file_classes);
    }
    return out;
}

/// A lazy build's top-level bodies: the reserved header stands in and the
/// job is recorded under its id.
fn deferTopLevelJobs(ctx: *BuildCtx, p: *lazy.Plan, jobs: []const body_pool.Job) Allocator.Error![]ir.Func {
    const a = ctx.a;
    const out = try a.alloc(ir.Func, jobs.len);
    errdefer a.free(out);
    for (jobs, out) |job, *slot| {
        if (bodyWritesRegistry(job)) {
            slot.* = try body_pool.lowerJob(ctx.module, job, &ctx.file_classes);
            continue;
        }
        const header = ctx.module.funcByIdMut(job.id).?;
        header.lazy_deferred = true;
        slot.* = header.*;
        try p.deferBody(job.id, job);
    }
    return out;
}

/// A body that declares a class or object registers it in the module while
/// lowering; it lowers in the build, on its thread, never on demand.
fn bodyWritesRegistry(job: body_pool.Job) bool {
    return if (job.f.body) |*b| prune.fnBodyDeclaresClass(b) else false;
}

/// The pool over a job list, for a lazy build's completion.
pub fn lowerJobsFor(ctx: *BuildCtx, jobs: []const body_pool.Job) Allocator.Error![]ir.Func {
    return lowerJobs(ctx, jobs);
}

fn lowerTopLevelFunctionBodies(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const stub_ids = &ctx.stub_ids;
    // Phase 2: each function body lowers into its reserved slot against the phase-1 header set.
    var jobs: std.ArrayList(body_pool.Job) = .empty;
    defer jobs.deinit(a);
    var stub_cursor: usize = 0;
    for (decls) |*d| {
        if (d.* != .Function) continue;
        const f = &d.Function;
        // A header-only declaration (a retained `expect`) keeps its phase-1 stub, so `hasBody()` stays
        // false and `linkBodyless` settles its executable form; lowering it would manufacture a
        // `return Unit` body that shadows the real dispatch.
        if (f.body == null) {
            stub_cursor += 1;
            continue;
        }
        const id = stub_ids.items[stub_cursor];
        stub_cursor += 1;
        try jobs.append(a, .{ .f = f, .id = id, .pkg = module.funcByIdMut(id).?.package });
    }
    const lowered = if (ctx.lazy) |p| try deferTopLevelJobs(ctx, p, jobs.items) else try lowerJobs(ctx, jobs.items);
    defer a.free(lowered);
    for (jobs.items, lowered) |job, func| try placeBody(ctx, job, func);
    phase.reportBodies();
    if (runtime.envOnce("KLIO_LOWER_FINGERPRINT") != null) {
        std.debug.print("[fn-block] {d} functions\n", .{module.funcs.items.len});
        for (module.funcs.items) |*fnc| {
            var n: usize = 0;
            for (fnc.blocks) |blk| n += blk.insts.len;
            std.debug.print("[fn] {d} {s} blocks={d} insts={d} hash={x}\n", .{ fnc.id.int(), fnc.fqn, fnc.blocks.len, n, ir.remap.semanticHash(fnc) });
        }
    }
    if (phase.on()) {
        if (ctx.module.extResolveCache()) |c| std.debug.print("[lower] ext-resolve cache hits {d} misses {d}\n", .{ c.hits, c.misses });
        if (ctx.module.recvVerdictCache()) |c| std.debug.print("[lower] recv-verdict cache hits {d} misses {d} entries {d}\n", .{ c.hits, c.misses, c.map.count() });
    }
}

/// Every job's body, on the pool when it runs and serially otherwise. Bodies
/// lower against the header set alone and are placed by the caller after, so
/// what a call resolves to does not depend on where its callee is declared.
/// The caller frees the slice.
fn lowerJobs(ctx: *BuildCtx, jobs: []const body_pool.Job) Allocator.Error![]ir.Func {
    const a = ctx.a;
    if (try body_pool.lower(ctx, jobs)) |lowered| return lowered;
    const lowered = try a.alloc(ir.Func, jobs.len);
    errdefer a.free(lowered);
    for (jobs, lowered) |job, *out| {
        const t_fn = if (phase.on()) runtime.clockMonotonicNanos() else 0;
        out.* = try body_pool.lowerJob(ctx.module, job, &ctx.file_classes);
        if (phase.on()) phase.noteBody(job.f.name.name, runtime.clockMonotonicNanos() - t_fn);
    }
    return lowered;
}

/// Files a lowered body in its reserved slot and records what the module keeps per body.
pub fn placeBody(ctx: *BuildCtx, job: body_pool.Job, func: ir.Func) Allocator.Error!void {
    const module = ctx.module;
    const f = job.f;
    const id = job.id;
    var placed = func;
    placed.id = id;
    placed.fqn = module.funcByIdMut(id).?.fqn;
    placed.package = module.funcByIdMut(id).?.package;
    if (runtime.envOnce("KLIO_FUNC_TRACE") != null) std.debug.print("[place-top] id={d} was={s} now={s}\n", .{ id.int(), module.funcByIdMut(id).?.fqn, placed.fqn });
        module.funcByIdMut(id).?.* = placed;
    // Kotlin scopes a private top-level declaration to its FILE, so dispatch never binds a private
    // extension from another file.
    if (f.visibility == .Private) {
        try module.registry.private_fn_files.put(id, f.name.span.file);
    }
    if (std.mem.eql(u8, f.name.name, "main")) ctx.main_id = id;
    try module.top_level.append(ctx.a, id);
    try registerBodyFuncTypeParams(ctx, f, id);
    try lowerFunctionDefaultThunks(ctx, f, id);
}

fn registerBodyFuncTypeParams(ctx: *BuildCtx, f: *const ast.Function, id: FuncId) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const func_type_params = &ctx.func_type_params;
    if (f.type_params.len != 0) {
        var names: std.ArrayList([]const u8) = .empty;
        for (f.type_params) |*tp| try names.append(a, tp.name.name);
        try func_type_params.put(id.int(), try names.toOwnedSlice(a));
        // Declared upper bounds (`<T : Number>` and `where`) for the extension-receiver prover.
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
}

fn lowerFunctionDefaultThunks(ctx: *BuildCtx, f: *const ast.Function, id: FuncId) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const func_defaults = &ctx.func_defaults;
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
                // A default referencing a CONTEXT parameter resolves as the body does: the thunk runs at call
                // time with the context on the stack, so the params are stashed for its `consumePendingCtx`.
                if (f.context_params.len != 0) {
                    module.pending_ctx = .{ .params = f.context_params, .type_params = f.type_params };
                }
                const thunk_name = try std.fmt.allocPrint(a, "__default_{s}_{s}", .{ f.name.name, p.name.name });
                const target_expr: *const ast.Expr = if (widened) |*w| w else default_expr;
                module.pending_thunk_expected = p.ty;
                const fid = try ir.lower.lowerExprAsParamThunk(module, name_refs.items[0..bind_upto], target_expr, thunk_name);
                try slots.append(a, fid);
            } else {
                try slots.append(a, null);
            }
        }
        try func_defaults.put(id.int(), try slots.toOwnedSlice(a));
    }
}

fn lowerClassMemberThunks(ctx: *BuildCtx) Allocator.Error!void {
    const decls = ctx.decls;
    for (decls) |*d| {
        if (d.* != .Class) continue;
        try lowerClassMemberThunksFor(ctx, &d.Class);
    }
}

/// Lower one class's member thunks, in the package scope the class declares.
fn lowerClassMemberThunksFor(ctx: *BuildCtx, c: *ast.Class) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const nested_outer_members = &ctx.nested_outer_members;
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
    // Companion members, enum entries and nested-class names are visible bare in a primary-ctor
    // default value, as inside a method body.
    try ir.lower.decl.addVisibleMemberNames(c, &own_members);
    var prop_init_params: std.ArrayList([]const u8) = .empty;
    defer prop_init_params.deinit(a);
    try prop_init_params.append(a, "this");
    for (c.primary_params) |*p| try prop_init_params.append(a, p.name.name);
    try lowerPrimaryCtorDefaultThunks(ctx, c, &own_members);

    const body_prop_cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
    const body_prop_dual = !std.mem.eql(u8, body_prop_cfqn, c.name.name);
    const body_prop_class_id = module.classIdByFqn(body_prop_cfqn);
    const body_prop_param_types: []const ir.Param = if (body_prop_class_id) |cid|
        module.classes.items[cid.int()].primary_params
    else blk: {
        // A LOCAL class has no module class entry, but its initializers still see the primary ctor params.
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
    // For a nested class the enclosing class's and its companion's members are visible bare inside
    // body-property initializers, so a bare `Default` binds the enclosing companion.
    const body_enclosing: ?*const StringSet = nested_outer_members.getPtr(c.name.name);
    for (c.members) |*m| {
        if (m.* != .Property) continue;
        const p = m.Property;
        // A MEMBER-EXTENSION property belongs to the extension surface, never an instance property:
        // registering its accessor as an instance getter makes the walk treat every subtype as shadowed.
        if (p.receiver_type != null) continue;
        try lowerBodyPropertyThunks(ctx, c, p, &own_members, .{
            .prop_init_params = prop_init_params.items,
            .param_types = body_prop_param_types,
            .enclosing = body_enclosing,
            .cfqn = body_prop_cfqn,
            .dual = body_prop_dual,
        });
    }
}

fn lowerPrimaryCtorDefaultThunks(ctx: *BuildCtx, c: *ast.Class, own_members: *StringSet) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const nested_outer_members = &ctx.nested_outer_members;
    const primary_ctor_default_thunks = &ctx.primary_ctor_default_thunks;
    var any_ctor_default = false;
    for (c.primary_params) |*p| {
        if (p.default != null) any_ctor_default = true;
    }
    if (any_ctor_default) {
        // A ctor default runs before `this` exists and the runtime passes a null receiver, so the receiver
        // slot takes a non-`this` name and a bare companion member resolves against the companion object.
        // An INNER class's defaults DO have a lexical receiver, so its slot is named `this`.
        var ctor_default_params: std.ArrayList([]const u8) = .empty;
        defer ctor_default_params.deinit(a);
        try ctor_default_params.append(a, if (c.is_inner) "this" else "$ctor_default_recv");
        for (c.primary_params) |*p| try ctor_default_params.append(a, p.name.name);
        var slots = try a.alloc(?FuncId, c.primary_params.len);
        // Parallel to `ctor_default_params`, whose first slot is the synthesized receiver.
        const ctor_default_types = try a.alloc(?ast.TypeRef, c.primary_params.len + 1);
        ctor_default_types[0] = null;
        for (c.primary_params, 0..) |*p, i| ctor_default_types[i + 1] = p.ty;
        const ctor_enclosing: ?*const StringSet = nested_outer_members.getPtr(c.name.name);
        for (c.primary_params, 0..) |*p, i| {
            if (p.default) |*e| {
                const nm = try std.fmt.allocPrint(a, "__ctor_default_{s}_{s}", .{ c.name.name, p.name.name });
                module.pending_param_types = ctor_default_types;
                module.pending_this_is_outer = c.is_inner;
                module.pending_thunk_expected = p.ty;
                slots[i] = try ir.lower.lowerExprAsParamThunkScopedEnclosing(module, ctor_default_params.items, e, nm, c.name.name, own_members, ctor_enclosing);
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
}

const BodyPropScope = struct {
    /// The thunk's parameter names: `this`, then the ctor parameters.
    prop_init_params: []const []const u8,
    param_types: []const ir.Param,
    enclosing: ?*const StringSet,
    /// The class's FQN, and whether it differs from the simple name, which then aliases.
    cfqn: []const u8,
    dual: bool,
};

fn lowerBodyPropertyThunks(
    ctx: *BuildCtx,
    c: *ast.Class,
    p: *const ast.Property,
    own_members: *StringSet,
    scope: BodyPropScope,
) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const body_prop_inits = &ctx.body_prop_inits;
    const instance_prop_private = &ctx.instance_prop_private;
    const delegated_body_props = &ctx.delegated_body_props;
    const prop_init_params = scope.prop_init_params;
    const body_prop_param_types = scope.param_types;
    const body_enclosing = scope.enclosing;
    const body_prop_cfqn = scope.cfqn;
    const body_prop_dual = scope.dual;
    // An explicit backing field's initializer IS the property's storage initializer.
    const storage_init: ?*const ast.Expr = if (p.init) |init|
        init
    else if (p.explicit_field) |ef|
        (if (ef.init) |finit| finit else null)
    else
        null;
    const storage_init_ty: ?ast.TypeRef = if (p.init != null)
        ast.unbox(p.ty)
    else if (p.explicit_field) |ef|
        ast.unbox(ef.ty orelse p.ty)
    else
        ast.unbox(p.ty);
    // A PRIVATE stored property never participates in override dispatch, so the virtual property walk
    // can skip a foreign class's private field.
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
        const fid = try ir.lower.lowerPropertyInitExpr(module, c.name.name, own_members, body_enclosing, prop_init_params, body_prop_param_types, init, nm, storage_init_ty);
        try body_prop_inits.put(.{ .a = c.name.name, .b = p.name.name }, fid);
        if (body_prop_dual) try body_prop_inits.put(.{ .a = body_prop_cfqn, .b = p.name.name }, fid);
    } else if (p.delegate) |delegate| {
        // The delegation marker registers under the FQN, and under the bare simple name only when it IS
        // the FQN: a simple-name alias lets a foreign namesake intercept an unrelated class's field read.
        try delegated_body_props.put(.{ .a = body_prop_cfqn, .b = p.name.name }, {});
        const nm = try std.fmt.allocPrint(a, "__delegate_prop_{s}_{s}", .{ c.name.name, p.name.name });
        const fid = try ir.lower.lowerPropertyInitExpr(module, c.name.name, own_members, body_enclosing, prop_init_params, body_prop_param_types, delegate, nm, null);
        try body_prop_inits.put(.{ .a = c.name.name, .b = p.name.name }, fid);
        if (body_prop_dual) try body_prop_inits.put(.{ .a = body_prop_cfqn, .b = p.name.name }, fid);
    }
    try lowerBodyPropertyGetter(ctx, c, p, own_members);
    try lowerBodyPropertySetter(ctx, c, p, own_members);
}

fn lowerBodyPropertyGetter(ctx: *BuildCtx, c: *ast.Class, p: *const ast.Property, own_members: *StringSet) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const instance_prop_getters = &ctx.instance_prop_getters;
    const getter_prop_names = &ctx.getter_prop_names;
    const instance_prop_private = &ctx.instance_prop_private;
    if (p.getter) |getter| {
        const nm = try std.fmt.allocPrint(a, "__get_{s}_{s}", .{ c.name.name, p.name.name });
        const fid = switch (getter.body) {
            .Expr => |body| blk: {
                const rewritten = try lift.substituteFieldWithThis(a, p.name.name, &body, c.name.name);
                // The property's declared type is the expression body's expected type, which a getter returning a
                // lambda needs to prove the lambda's parameter shape.
                break :blk try ir.lower.lowerAccessorExprWithExpected(module, c.name.name, own_members, &.{"this"}, rewritten, nm, ast.unbox(p.ty));
            },
            .Block => |blk_body| blk: {
                const rewritten = try lift.rewriteBlockField(a, &blk_body, p.name.name, c.name.name);
                break :blk try ir.lower.lowerAccessorBlock(module, c.name.name, own_members, &.{"this"}, &rewritten, nm);
            },
        };
        // The accessor's own visibility, which a bare read of the property
        // binds by: a private accessor is the declaring class's alone, and a
        // same-named private property in a subclass is another declaration.
        if (module.decl_sigs.getPtr(fid.int())) |sig| {
            sig.visibility = p.visibility;
        } else {
            try module.decl_sigs.put(fid.int(), .{
                .arity = .{ .required = 0, .total = 0, .has_vararg = false },
                .kind = .instance_method,
                .visibility = p.visibility,
                .has_body = true,
            });
        }
        // A PRIVATE class's accessors register under the FQN key only: the simple slot is shared
        // program-wide, and a private namesake must never capture dispatch for an unrelated public class.
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
}

fn lowerBodyPropertySetter(ctx: *BuildCtx, c: *ast.Class, p: *const ast.Property, own_members: *StringSet) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const instance_prop_setters = &ctx.instance_prop_setters;
    if (p.setter) |setter| {
        const setter_param_name = if (setter.params.len != 0) setter.params[0].name else "value";
        const nm = try std.fmt.allocPrint(a, "__set_{s}_{s}", .{ c.name.name, p.name.name });
        // The value parameter's type is the property's declared type, so `value` resolves statically.
        const vty_head: ?[]const u8 = if (p.ty) |t| t.name.name else null;
        const vty_nullable = if (p.ty) |t| t.nullable else false;
        const fid = switch (setter.body) {
            .Expr => |body| blk: {
                const rewritten = try lift.substituteFieldWithThis(a, p.name.name, &body, c.name.name);
                break :blk try ir.lower.lowerSetterExprTyped(module, c.name.name, own_members, &.{ "this", setter_param_name }, setter_param_name, vty_head, vty_nullable, rewritten, nm);
            },
            .Block => |blk_body| blk: {
                const rewritten = try lift.rewriteBlockField(a, &blk_body, p.name.name, c.name.name);
                break :blk try ir.lower.lowerSetterBlockTyped(module, c.name.name, own_members, &.{ "this", setter_param_name }, setter_param_name, vty_head, vty_nullable, &rewritten, nm);
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

fn buildRuntimeClassDefs(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const object_spans = &ctx.object_spans;
    const file_classes = &ctx.file_classes;
    const classes = &ctx.classes;
    const new_defs = &ctx.new_defs;
    // The class table is FQN-keyed: every class registers under its fully-qualified name (which IS the
    // simple name for a root-package class), and those entries are authoritative, never displaced by
    // an alias. The simple-name view serves callers holding no resolved identity.
    const globals_for_capture = try ObjRef(Env).init(a, Env.init(a));
    // Defs created by THIS build: the backpatch links only these, seeded base defs arriving linked.
    var simple_aliases: std.ArrayList(struct { name: []const u8, def: ObjRef(ClassDef) }) = .empty;
    defer simple_aliases.deinit(a);
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        const def = try buildClassDef(module, a, c, fqn_overrides, package_prefix, object_spans, globals_for_capture, file_classes);
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
        // An authoritative entry is never displaced. Among aliases a user-package class outranks a shipped
        // one, and equally-ranked aliases keep the first declaration.
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
}

fn registerEnumEntries(ctx: *BuildCtx) Allocator.Error!void {
    const base = ctx.base;
    const decls = ctx.decls;
    // An extending build continues the base's identity sequence so default toString/hashCode match.
    var next_id: u64 = if (base) |bs| bs.enum_id_next else 1;
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        if (!c.is_enum) continue;
        try registerEnumClassEntries(ctx, c, &next_id);
    }
}

/// Populate one enum class's entries, in the package scope it declares.
fn registerEnumClassEntries(ctx: *BuildCtx, c: *ast.Class, next_id: *u64) Allocator.Error!void {
    const a = ctx.a;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const classes = &ctx.classes;
    const enum_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
    const prev_enum_pkg = ir.lower.decl.setLowerSelfPackage(enum_pkg);
    defer _ = ir.lower.decl.setLowerSelfPackage(prev_enum_pkg);
    const enum_key = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
    const class_def = classes.get(enum_key) orelse classes.get(c.name.name) orelse return;
    var entries: std.ArrayList(ClassDef.EnumEntry) = .empty;
    for (c.x().enum_entries, 0..) |*entry, ordinal| {
        try lowerEnumEntry(ctx, c, entry, ordinal, class_def, next_id, &entries);
    }
    const g = class_def.borrowMut();
    g.get().enum_entries = try entries.toOwnedSlice(a);
    g.deinit();
}

fn lowerEnumEntry(
    ctx: *BuildCtx,
    c: *ast.Class,
    entry: *ast.EnumEntry,
    ordinal: usize,
    class_def: ObjRef(ClassDef),
    next_id: *u64,
    entries: *std.ArrayList(ClassDef.EnumEntry),
) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const enum_entry_arg_inits = &ctx.enum_entry_arg_inits;
    const id = next_id.*;
    next_id.* += 1;
    var fields: std.ArrayList(InstanceData.Field) = .empty;
    try fields.append(a, .{ .name = "name", .value = .{ .String = try runtime.strInit(a, entry.name.name) } });
    try fields.append(a, .{ .name = "ordinal", .value = Value.newInt(@intCast(ordinal)) });

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

    // One init thunk per constructor slot: the entry's explicit args, then defaults for any trailing
    // primary-ctor params it omits. Kotlin requires the args to be a prefix, so defaults fill the
    // suffix index-aligned; a named argument binds its parameter, a positional one the next slot.
    const n_slots = @max(c.primary_params.len, entry.args.len);
    const slot_exprs = try a.alloc(?*const ast.Expr, n_slots);
    for (slot_exprs) |*se| se.* = null;
    mapEnumEntryArgSlots(c, entry, slot_exprs);
    var slot_count: usize = 0;
    while (slot_count < n_slots and
        (slot_exprs[slot_count] != null or
            (slot_count < c.primary_params.len and c.primary_params[slot_count].default != null))) : (slot_count += 1)
    {}
    if (slot_count != 0) {
        var fids = try a.alloc(FuncId, slot_count);
        // The arguments sit in the enum's static scope, where an entry name or companion member is visible
        // bare, so the thunks take the enum class as `this`.
        var enum_scope = StringSet.init(a);
        defer enum_scope.deinit();
        try ir.lower.decl.addVisibleMemberNames(c, &enum_scope);
        const enum_this = [_][]const u8{"this"};
        for (0..slot_count) |idx| {
            const nm = try std.fmt.allocPrint(a, "__enum_arg_{s}_{s}_{d}", .{ c.name.name, entry.name.name, idx });
            const arg_expr = slot_exprs[idx] orelse &c.primary_params[idx].default.?;
            if (idx < c.primary_params.len) module.pending_thunk_expected = c.primary_params[idx].ty;
            fids[idx] = try ir.lower.lowerExprAsParamThunkScoped(module, &enum_this, arg_expr, nm, c.name.name, &enum_scope);
        }
        try enum_entry_arg_inits.append(a, .{ .class_name = c.name.name, .entry_name = entry.name.name, .funcs = fids });
    }
}

fn mapEnumEntryArgSlots(c: *const ast.Class, entry: *const ast.EnumEntry, slot_exprs: []?*const ast.Expr) void {
    var next_slot: usize = 0;
    for (entry.args, 0..) |*arg, ai| {
        const label: ?[]const u8 = if (ai < entry.arg_names.len) entry.arg_names[ai] else null;
        var slot: ?usize = null;
        if (label) |nm| {
            for (c.primary_params, 0..) |*pp, pi| {
                if (std.mem.eql(u8, pp.name.name, nm)) {
                    slot = pi;
                    break;
                }
            }
        }
        if (slot == null) {
            while (next_slot < slot_exprs.len and slot_exprs[next_slot] != null) next_slot += 1;
            slot = next_slot;
        }
        const si = slot.?;
        if (si < slot_exprs.len) {
            slot_exprs[si] = arg;
            if (si == next_slot) next_slot += 1;
        }
    }
}

/// Backpatch every new class def's runtime parent and interface slots, then fill the nested-class
/// tables.
fn linkRuntimeSupertypes(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const decls = ctx.decls;
    const classes = &ctx.classes;
    const new_defs = &ctx.new_defs;
    // The second linker phase backpatches each `parent`/`interfaces` slot once; afterwards the fields
    // are immutable for the rest of the process and read lock-free on dispatch.
    {
        for (new_defs.items) |def| {
            const dg = def.borrow();
            const supertype_names = dg.get().supertype_names;
            const supertype_paths = dg.get().supertype_paths;
            const def_pkg = packageOfFqn(dg.get().fqn, dg.get().name);
            dg.deinit();
            var ifaces: std.ArrayList(ObjRef(ClassDef)) = .empty;
            for (supertype_names, 0..) |sup_name, si| {
                // A supertype name is written simple in source and resolves Kotlin-style, the subclass's own
                // package before the cross-package simple-name view. A qualified reference resolves by FQN suffix.
                const qp: ?[]const u8 = if (si < supertype_paths.len) supertype_paths[si] else null;
                const sup_def = blk: {
                    if (qp) |p| {
                        if (classTableByQualifiedSuffix(classes, p)) |sd| break :blk sd;
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
        // A class's `nested_classes` names every class, object and interface declared in its body, or a
        // reified `typeOf<Nested>()` inside the outer class cannot reach the nested def.
        try fillNestedClassTables(a, decls, classes, "");
    }
}

fn lowerParentCtorArgThunks(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const nested_outer_members = &ctx.nested_outer_members;
    const parent_ctor_args = &ctx.parent_ctor_args;
    const parent_ctor_arg_names = &ctx.parent_ctor_arg_names;
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
        // Argument labels parallel to `parent_args`, null where the call is all positional.
        const parent_names: ?[]const ?[]const u8 =
            if (first_idx < c.x().supertype_arg_names.len) c.x().supertype_arg_names[first_idx] else null;
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
            module.pending_this_is_outer = c.is_inner;
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
}

fn lowerInitBlockThunks(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const file_classes = &ctx.file_classes;
    const init_blocks = &ctx.init_blocks;
    // Init blocks as thunks taking `this` plus the ctor params.
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        if (c.x().init_blocks.len == 0) continue;
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
            for (c.supertypes) |*st| try collectHierarchyMemberNames(st.name.name, file_classes, &own_members, &seen_sup);
        }
        var local_params: std.ArrayList([]const u8) = .empty;
        defer local_params.deinit(a);
        try local_params.append(a, "this");
        for (c.primary_params) |*p| try local_params.append(a, p.name.name);
        var fids = try a.alloc(FuncId, c.x().init_blocks.len);
        const ib_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
        const prev_ib_pkg = ir.lower.decl.setLowerSelfPackage(ib_pkg);
        defer _ = ir.lower.decl.setLowerSelfPackage(prev_ib_pkg);
        // Parallel to `local_params`, whose first slot is the receiver.
        const ib_types = try a.alloc(?ast.TypeRef, local_params.items.len);
        ib_types[0] = null;
        for (c.primary_params, 0..) |*p, i| {
            if (i + 1 < ib_types.len) ib_types[i + 1] = p.ty;
        }
        // The same typed signature the body-property thunks compile against: an init block reads the
        // constructor's parameters, and a consumer reading `Func.params` has no other source.
        const ib_cid = module.classIdByFqn(try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name));
        const ib_param_types: []const ir.Param = if (ib_cid) |cid|
            module.classes.items[cid.int()].primary_params
        else
            &.{};
        for (c.x().init_blocks, 0..) |*blk, idx| {
            const nm = try std.fmt.allocPrint(a, "__init_block_{s}_{d}", .{ c.name.name, idx });
            module.pending_param_types = ib_types;
            fids[idx] = try ir.lower.lowerInitBlockWithParams(module, c.name.name, &own_members, local_params.items, ib_param_types, blk, nm);
        }
        try init_blocks.put(c.name.name, fids);
        const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
        if (!std.mem.eql(u8, cfqn, c.name.name)) try init_blocks.put(cfqn, fids);
    }
}

fn lowerClassDelegateThunks(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const class_delegates = &ctx.class_delegates;
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
                // The delegate expression is written in the CLASS's scope, so a nested class's `by X.shared` names
                // a sibling nested object only the enclosing walk resolves.
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
}

fn lowerSecondaryCtors(ctx: *BuildCtx) Allocator.Error!void {
    const decls = ctx.decls;
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        if (c.x().secondary_ctors.len == 0) continue;
        try lowerClassSecondaryCtors(ctx, c);
    }
}

/// Lower one class's secondary constructors, in its own package scope.
fn lowerClassSecondaryCtors(ctx: *BuildCtx, c: *ast.Class) Allocator.Error!void {
    const a = ctx.a;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const file_classes = &ctx.file_classes;
    const secondary_ctors = &ctx.secondary_ctors;
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
    // A delegation or default thunk names a superclass companion's member bare and has no `this` to
    // walk at runtime, so it resolves statically as a companion access.
    {
        var seen_sup = StringSet.init(a);
        defer seen_sup.deinit();
        for (c.supertypes) |*st| try collectHierarchyCompanionMemberNames(st.name.name, file_classes, &own_members, &seen_sup);
    }
    // Which of those names such a thunk may CALL: every function contributes its arity mask, and a
    // name that is only ever a property gets mask 0, so a call beside a same-named `val` still binds
    // the top-level function.
    var own_arity = runtime.NameHashMap(u64).init(a);
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
    var entries = try a.alloc(SecondaryCtorEntry, c.x().secondary_ctors.len);
    for (c.x().secondary_ctors, 0..) |*sc, sc_idx| {
        entries[sc_idx] = try lowerSecondaryCtor(ctx, c, sc, sc_idx, &own_members, &own_arity);
    }
    try secondary_ctors.put(c.name.name, entries);
    const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
    if (!std.mem.eql(u8, cfqn, c.name.name)) try secondary_ctors.put(cfqn, entries);
}

fn lowerSecondaryCtor(
    ctx: *BuildCtx,
    c: *ast.Class,
    sc: *ast.SecondaryCtor,
    sc_idx: usize,
    own_members: *StringSet,
    own_arity: *runtime.NameHashMap(u64),
) Allocator.Error!SecondaryCtorEntry {
    const a = ctx.a;
    const module = ctx.module;
    const nested_outer_members = &ctx.nested_outer_members;
    // The entry outlives the declaration's AST, a pack's sources being released once their bindings
    // are extracted, so its strings are the module's own copies.
    var param_names = try a.alloc([]const u8, sc.params.len);
    for (sc.params, 0..) |*p, i| param_names[i] = try a.dupe(u8, p.name.name);
    var param_type_heads = try a.alloc([]const u8, sc.params.len);
    for (sc.params, 0..) |*p, i| {
        // A function-typed parameter's name field is empty, so the arity-tagged head is recorded and ctor
        // overload selection can prefer this slot for a lambda over a SAM-class slot.
        param_type_heads[i] = if (p.ty.function != null)
            try ir.lower.decl.loweredTypeName(a, &p.ty)
        else
            try a.dupe(u8, simpleTypeHead(p.ty.name.name));
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
    // The delegation arguments and defaults are expressions over the secondary constructor's OWN
    // parameters, so they lower with the types those parameters declare.
    const sc_param_types = try a.alloc(?ast.TypeRef, sc.params.len);
    for (sc.params, 0..) |*p, i| sc_param_types[i] = p.ty;
    // An inner class's thunks take the enclosing instance as a leading receiver slot; any other
    // class's see only the parameters, so a companion member named in a delegation stays a static call.
    var sc_thunk_params: []const []const u8 = param_names;
    var sc_thunk_types: []const ?ast.TypeRef = sc_param_types;
    if (c.is_inner) {
        const with_recv = try a.alloc([]const u8, param_names.len + 1);
        with_recv[0] = "this";
        for (param_names, 0..) |pn, i| with_recv[i + 1] = pn;
        sc_thunk_params = with_recv;
        const with_recv_types = try a.alloc(?ast.TypeRef, sc.params.len + 1);
        with_recv_types[0] = null;
        for (sc.params, 0..) |*p, i| with_recv_types[i + 1] = p.ty;
        sc_thunk_types = with_recv_types;
    }
    // Named delegation arguments bind by NAME, and the thunks run in the target's declared order.
    const order = try secondaryCtorDelegationOrder(a, c, sc, delegation_args, is_this);
    // An inner class's delegation arguments and defaults see the enclosing instance's members.
    const sc_enclosing: ?*const StringSet = nested_outer_members.getPtr(c.name.name);
    var arg_fids = try a.alloc(FuncId, delegation_args.len);
    for (order, 0..) |src_idx, arg_idx| {
        const e = &delegation_args[src_idx];
        const nm = try std.fmt.allocPrint(a, "__sec_ctor_{s}_{d}_arg{d}", .{ c.name.name, sc_idx, arg_idx });
        module.pending_param_types = sc_thunk_types;
        module.pending_this_is_outer = c.is_inner;
        module.pending_own_member_arity = own_arity;
        arg_fids[arg_idx] = try ir.lower.lowerExprAsParamThunkScopedEnclosing(module, sc_thunk_params, e, nm, c.name.name, own_members, sc_enclosing);
    }
    var default_arg_thunks = try a.alloc(?FuncId, sc.params.len);
    for (sc.params, 0..) |*p, p_idx| {
        if (p.default) |e| {
            const nm = try std.fmt.allocPrint(a, "__sec_ctor_{s}_{d}_def{d}", .{ c.name.name, sc_idx, p_idx });
            module.pending_param_types = sc_thunk_types;
            module.pending_this_is_outer = c.is_inner;
            module.pending_own_member_arity = own_arity;
            module.pending_thunk_expected = p.ty;
            default_arg_thunks[p_idx] = try ir.lower.lowerExprAsParamThunkScopedEnclosing(module, sc_thunk_params, e, nm, c.name.name, own_members, sc_enclosing);
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
        body_fid = try ir.lower.lowerAccessorBlock(module, c.name.name, own_members, locals.items, blk, nm);
    }
    return .{
        .param_count = sc.params.len,
        .param_names = param_names,
        .param_type_heads = param_type_heads,
        .is_super = is_super,
        .is_this = is_this,
        .delegation_arg_thunks = arg_fids,
        .default_arg_thunks = default_arg_thunks,
        .body = body_fid,
        .low_priority = ir.lower.decl.annotationsAreLowPriority(sc.annotations),
        .vararg_index = blk: {
            for (sc.params, 0..) |*p, i| if (p.is_vararg) break :blk i;
            break :blk null;
        },
    };
}

/// The order a `this(...)` delegation's arguments bind the target's parameters in: a named argument
/// takes the parameter it names, and only a call filling every primary parameter is reordered.
fn secondaryCtorDelegationOrder(
    a: Allocator,
    c: *const ast.Class,
    sc: *const ast.SecondaryCtor,
    delegation_args: []const ast.Expr,
    is_this: bool,
) Allocator.Error![]usize {
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
    return order;
}

/// Lower the top-level `const val` initialisers, which run first.
fn lowerTopLevelConstProps(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const func_fqn_overrides = ctx.func_fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const top_level_props = &ctx.top_level_props;
    for (decls) |*d| {
        if (d.* != .Property) continue;
        const p = d.Property;
        if (p.receiver_type != null or !p.is_const) continue;
        const tp_pkg = try declPackage(a, decl_pkg, func_fqn_overrides, p.span, package_prefix, p.name.name);
        const prev_tp_pkg = ir.lower.decl.setLowerSelfPackage(tp_pkg);
        defer _ = ir.lower.decl.setLowerSelfPackage(prev_tp_pkg);
        if (p.init) |init| {
            const nm = try std.fmt.allocPrint(a, "__top_prop_init_{s}", .{p.name.name});
            const fid = try ir.lower.lowerExprAsThunkTyped(module, init, nm, ast.unbox(p.ty));
            try top_level_props.append(a, .{ .name = p.name.name, .func = fid, .file = p.span.file.int() });
        }
    }
}

fn lowerTopLevelProps(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const func_fqn_overrides = ctx.func_fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const top_level_props = &ctx.top_level_props;
    const top_level_delegated_props = &ctx.top_level_delegated_props;
    for (decls) |*d| {
        if (d.* != .Property) continue;
        const p = d.Property;
        if (p.receiver_type != null or p.is_const) continue;
        const tp_pkg = try declPackage(a, decl_pkg, func_fqn_overrides, p.span, package_prefix, p.name.name);
        const prev_tp_pkg = ir.lower.decl.setLowerSelfPackage(tp_pkg);
        defer _ = ir.lower.decl.setLowerSelfPackage(prev_tp_pkg);
        const storage_init: ?*const ast.Expr = if (p.init) |init|
            init
        else if (p.explicit_field) |ef|
            (if (ef.init) |finit| finit else null)
        else
            null;
        // A custom accessor next to real storage moves the storage binding to the raw
        // `__klio_topfield__<name>` key: a plain-name read misses and re-runs the getter, a plain-name
        // write dispatches the setter, and the accessor bodies target the raw key.
        const accessorized = p.setter != null or (p.getter != null and storage_init != null);
        const storage_name = if (accessorized)
            try std.fmt.allocPrint(a, "__klio_topfield__{s}", .{p.name.name})
        else
            p.name.name;
        if (storage_init) |init| {
            const nm = try std.fmt.allocPrint(a, "__top_prop_init_{s}", .{p.name.name});
            const fid = try ir.lower.lowerExprAsThunkTyped(module, init, nm, ast.unbox(p.ty));
            // Annotated: default from the declared type. Unannotated: infer from a trivially-typed literal
            // initializer so a forward read observes the typed field default, as kotlinc does.
            const dflt = if (p.ty) |t| typedDefaultFor(t) else typedDefaultForInit(init);
            try top_level_props.append(a, .{ .name = storage_name, .func = fid, .default = dflt, .file = p.span.file.int() });
        } else if (p.delegate) |delegate| {
            try top_level_delegated_props.put(p.name.name, {});
            const nm = try std.fmt.allocPrint(a, "__top_prop_delegate_{s}", .{p.name.name});
            const fid = try ir.lower.lowerDelegateExprAsThunk(module, delegate, nm, p.name.name);
            try top_level_props.append(a, .{ .name = p.name.name, .func = fid, .file = p.span.file.int() });
        } else if (p.is_lateinit) {
            try module.registry.top_level_lateinit_props.put(p.name.name, {});
        }
        if (p.delegate == null) {
            if (p.getter) |getter| {
                // With storage the getter re-runs on each plain-name read and its `field` reads the raw key;
                // without storage it is the field-less computed-property form.
                if (p.context_params.len != 0)
                    module.pending_ctx = .{ .params = p.context_params, .type_params = &.{} };
                const nm = try std.fmt.allocPrint(a, "__top_prop_get_{s}", .{p.name.name});
                module.pending_accessor_place_id = module.funcByDeclSpan(getter.span);
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
                module.pending_accessor_place_id = null;
                try module.registry.top_level_prop_getters.put(p.name.name, fid);
            }
            if (p.setter) |setter| {
                const value_param = if (setter.params.len != 0) setter.params[0].name else "value";
                if (p.context_params.len != 0)
                    module.pending_ctx = .{ .params = p.context_params, .type_params = &.{} };
                const nm = try std.fmt.allocPrint(a, "__top_prop_set_{s}", .{p.name.name});
                module.pending_accessor_place_id = module.funcByDeclSpan(setter.span);
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
                module.pending_accessor_place_id = null;
                try module.registry.top_level_prop_setters.put(p.name.name, fid);
            }
        }
    }
}

/// Lower every extension property: file-level, and the member extensions a class owns.
/// Every extension property the file declares, top-level and member, with the
/// declaring class of a member one.
fn collectExtPropDecls(ctx: *BuildCtx, out: *std.ArrayList(ExtPropDecl)) Allocator.Error!void {
    const a = ctx.a;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const ext_prop_decls = out;
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
}

/// Class-typed typealiases, the shared `type_aliases` map recording only function-typed
/// ones, so an extension receiver named by an alias expands to the class.
fn collectClassAliases(ctx: *BuildCtx) Allocator.Error!runtime.NameHashMap([]const u8) {
    var class_aliases = runtime.NameHashMap([]const u8).init(ctx.a);
    for (ctx.decls) |*d| {
        if (d.* != .TypeAlias) continue;
        const ta = &d.TypeAlias;
        if (ta.target.function != null) continue;
        try class_aliases.put(ta.name.name, ta.target.name.name);
    }
    return class_aliases;
}

/// The receiver head an extension property keys and names its accessors by: a
/// typealias expands to its class, a member extension on the owner's type
/// parameter keys on the parameter's upper bound, a function type on `Function`.
fn extPropReceiverName(epd: ExtPropDecl, class_aliases: *const runtime.NameHashMap([]const u8)) []const u8 {
    const recv = epd.p.receiver_type orelse return "";
    var recv_name = recv.name.name;
    {
        var hops: usize = 0;
        while (class_aliases.get(recv_name)) |t| : (hops += 1) {
            if (hops > 8 or std.mem.eql(u8, t, recv_name)) break;
            recv_name = t;
        }
    }
    for (epd.owner_type_params) |*tp| {
        if (!std.mem.eql(u8, tp.name.name, recv_name)) continue;
        recv_name = if (tp.upper_bound) |ub| ub.name.name else "Any";
        break;
    }
    if (recv.function != null) recv_name = "Function";
    return recv_name;
}

/// Reserve every member-extension property getter's identity before any body
/// lowers: a read the enclosing class resolves to its own extension property
/// binds the getter's FuncId, and a class body lowers before the accessor does.
fn registerMemberExtPropHeaders(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    var ext_prop_decls: std.ArrayList(ExtPropDecl) = .empty;
    defer ext_prop_decls.deinit(a);
    try collectExtPropDecls(ctx, &ext_prop_decls);
    var class_aliases = try collectClassAliases(ctx);
    defer class_aliases.deinit();
    for (ext_prop_decls.items) |epd| {
        const owner = epd.owner orelse continue;
        const p = epd.p;
        if (p.getter == null) continue;
        const recv = p.receiver_type orelse continue;
        const recv_name = extPropReceiverName(epd, &class_aliases);
        const nm = try std.fmt.allocPrint(a, "__ext_get_{s}_{s}", .{ recv_name, p.name.name });
        const params = try a.alloc(Param, 1);
        params[0] = .{
            .name = "this",
            .ty = try ir.lower.decl.loweredTypeRef(a, recv, true),
            .default = null,
            .is_property = false,
            .is_vararg = false,
            .has_default = false,
        };
        const id = try reserveAccessorHeader(ctx, nm, params, p, p.name.span, .member_extension);
        try module.registry.member_ext_owner_class.put(id, owner);
    }
}

/// Reserve a top-level custom accessor's identity before the bodies lower: a
/// read of a property with a getter is a call to it and a write to one with a
/// setter a call to that, and the sites need the FuncId while the class bodies
/// and top-level functions lower, before `lowerTopLevelProps` places the thunk.
/// A property the host implements under its FQN keeps its by-name protocol:
/// the host's binding is what every read of that name finds, and the source
/// accessor never runs. A contextual accessor's header carries its context
/// types so a reader hands them over.
fn registerTopLevelAccessorHeaders(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    for (ctx.decls) |*d| {
        if (d.* != .Property) continue;
        const p = d.Property;
        if (p.receiver_type != null or p.is_const) continue;
        const fqn = try resolveFqn(a, ctx.func_fqn_overrides, p.span, ctx.package_prefix, p.name.name);
        if (stdlib.declarationHostSymbol(fqn, null, p.name.name) != null) continue;
        if (p.getter) |getter| {
            const nm = try std.fmt.allocPrint(a, "__top_prop_get_{s}", .{p.name.name});
            const id = try reserveAccessorHeader(ctx, nm, &.{}, p, getter.span, .plain);
            try module.registry.top_level_prop_getters.put(p.name.name, id);
        }
        if (p.setter) |setter| {
            const nm = try std.fmt.allocPrint(a, "__top_prop_set_{s}", .{p.name.name});
            const params = try a.alloc(Param, 1);
            params[0] = .{
                .name = if (setter.params.len != 0) setter.params[0].name else "value",
                .ty = if (p.ty) |pt| try ir.lower.decl.loweredTypeRef(a, pt, true) else ir.build.typeUnit(),
                .default = null,
                .is_property = false,
                .is_vararg = false,
                .has_default = false,
            };
            const id = try reserveAccessorHeader(ctx, nm, params, p, setter.span, .plain);
            try module.registry.top_level_prop_setters.put(p.name.name, id);
        }
    }
}

/// Append a bodyless header for an accessor thunk named `nm`, indexed under the
/// name and keyed by `decl_span` so `pushFunc` places the lowered body into it.
fn reserveAccessorHeader(ctx: *BuildCtx, nm: []const u8, params: []Param, p: *const ast.Property, decl_span: ast.Span, kind: ir.FuncKind) Allocator.Error!FuncId {
    const a = ctx.a;
    const module = ctx.module;
    const id = module.nextFuncId();
    try module.appendFunc(.{
        .id = id,
        .name = nm,
        .fqn = nm,
        .package = try declPackage(a, ctx.decl_pkg, ctx.func_fqn_overrides, p.span, ctx.package_prefix, p.name.name),
        .params = params,
        .return_ty = if (p.ty) |pt| try ir.lower.decl.loweredTypeRef(a, pt, true) else ir.build.typeUnit(),
        .return_ty_declared = p.ty != null,
        .n_locals = 0,
        .blocks = &.{},
        .entry = ir.BlockId.from(0),
        .is_suspend = false,
        .is_tailrec = false,
        .is_lambda = false,
        .is_inline = false,
        .low_priority = false,
        .deprecated_error = false,
        .is_expect = false,
        .kind = kind,
        .extra = try ir.lower.decl.ctxExtraFor(a, p.context_params),
    });
    try module.func_index.append(a, .{ .name = nm, .id = id });
    const gop = try module.func_name_index.getOrPut(nm);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(a, id);
    try module.recordFuncDeclSpan(a, decl_span, id);
    try module.decl_ast_body.put(id.int(), {});
    return id;
}

fn lowerExtensionProps(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    var ext_prop_decls: std.ArrayList(ExtPropDecl) = .empty;
    defer ext_prop_decls.deinit(a);
    try collectExtPropDecls(ctx, &ext_prop_decls);
    var class_aliases = try collectClassAliases(ctx);
    defer class_aliases.deinit();
    for (ext_prop_decls.items) |epd| {
        try lowerExtensionProp(ctx, epd, &class_aliases);
    }
}

fn lowerExtensionProp(ctx: *BuildCtx, epd: ExtPropDecl, class_aliases: *const runtime.NameHashMap([]const u8)) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decl_pkg = ctx.decl_pkg;
    const extension_prop_delegates = &ctx.extension_prop_delegates;
    const func_fqn_overrides = ctx.func_fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const p = epd.p;
    const recv = p.receiver_type orelse return;
    const recv_name = extPropReceiverName(epd, class_aliases);
    // A `val X.Companion.foo` records `qualified_path = "X.Companion"` and is keyed under that path,
    // so it never collides with a plain `val X.foo`.
    const recv_key: []const u8 = if (recv.x().qualified_path) |qp|
        (if (std.mem.endsWith(u8, qp, ".Companion")) qp else recv_name)
    else
        recv_name;
    const ep_pkg = try declPackage(a, decl_pkg, func_fqn_overrides, p.span, package_prefix, p.name.name);

    const prev_ep_pkg = ir.lower.decl.setLowerSelfPackage(ep_pkg);
    defer _ = ir.lower.decl.setLowerSelfPackage(prev_ep_pkg);
    // The accessor's receiver answers to `this@<prop>`, and a local class in the body reaches the
    // declaring class as `this@<Owner>`.
    const dispatch_owner: ?[]const u8 = if (epd.owner) |o|
        (if (std.mem.findScalarLast(u8, o, '.')) |dot| o[dot + 1 ..] else o)
    else
        null;
    if (p.getter) |getter| {
        try lowerExtensionPropGetter(ctx, epd, p, getter, recv.*, recv_name, recv_key, ep_pkg, dispatch_owner);
    }
    if (p.delegate) |delegate| {
        // `val R.x by expr` has no accessor bodies: the delegate object, produced once by this thunk and
        // cached per property, serves reads and writes through getValue/setValue.
        const nm = try std.fmt.allocPrint(a, "__ext_prop_delegate_{s}_{s}", .{ recv_name, p.name.name });
        // The delegate expression reads the declaring class's scope: `by d::y` names a
        // member of the owner, so a member extension lowers it as an accessor over that
        // class and takes the instance as its receiver. A top-level one needs none.
        const fid = if (dispatch_owner) |owner_simple| blk: {
            var owner_members = StringSet.init(a);
            defer owner_members.deinit();
            break :blk try ir.lower.lowerAccessorExprWithExpected(module, owner_simple, &owner_members, &.{"this"}, delegate, nm, null);
        } else try ir.lower.lowerExprAsThunk(module, delegate, nm);
        try extension_prop_delegates.put(.{ .a = recv_key, .b = p.name.name }, fid);
        if (epd.owner) |owner| {
            try module.registry.member_ext_owner_class.put(fid, owner);
        }
    }
    if (p.setter) |setter| {
        try lowerExtensionPropSetter(ctx, epd, p, setter, recv_name, recv_key, dispatch_owner);
    }
}

fn lowerExtensionPropGetter(
    ctx: *BuildCtx,
    epd: ExtPropDecl,
    p: *const ast.Property,
    getter: *ast.Accessor,
    recv: ast.TypeRef,
    recv_name: []const u8,
    recv_key: []const u8,
    ep_pkg: []const u8,
    dispatch_owner: ?[]const u8,
) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const extension_props = &ctx.extension_props;
    const owner_keyed_ext_names = &ctx.owner_keyed_ext_names;
    const nullable_ext_props = &ctx.nullable_ext_props;
    var empty_members = StringSet.init(a);
    defer empty_members.deinit();
    const nm = try std.fmt.allocPrint(a, "__ext_get_{s}_{s}", .{ recv_name, p.name.name });
    module.pending_accessor_this_label = p.name.name;
    module.pending_accessor_dispatch_owner = dispatch_owner;
    module.pending_accessor_place_id = if (epd.owner != null) module.funcByDeclSpan(p.name.span) else null;
    const fid = switch (getter.body) {
        .Expr => |body| try ir.lower.lowerAccessorExprWithExpected(module, recv_name, &empty_members, &.{"this"}, &body, nm, ast.unbox(p.ty)),
        .Block => |blk| try ir.lower.lowerAccessorBlockRet(module, recv_name, &empty_members, &.{"this"}, &blk, nm, ast.unbox(p.ty)),
    };
    module.pending_accessor_place_id = null;
    // A member-extension accessor runs as a member extension: its dispatch
    // receiver is the declaring instance, seeded on the enclosing chain, and
    // the flat activation that serves a plain method cannot carry one.
    if (epd.owner != null) {
        if (module.funcByIdMut(fid)) |gf| gf.kind = .member_extension;
    }
    if (runtime.envOnce("KLIO_MISS_TRACE")) |w| {
        if (std.mem.eql(u8, w, p.name.name))
            std.debug.print("[extprop-reg] key=({s},{s}) fid={d} owner={s}\n", .{ recv_key, p.name.name, fid.int(), epd.owner orelse "<top>" });
    }
    // A PRIVATE member-extension property is visible only where its owner class is a dispatch receiver,
    // so it registers ONLY under the owner-qualified key; a plain pair would resolve it program-wide,
    // which kotlinc rejects. A non-private one keeps the plain pair, the tower emulation not yet
    // seeing every legal frame.
    if (epd.owner) |owner| {
        const okey = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ owner, recv_key });
        try extension_props.put(.{ .a = okey, .b = p.name.name }, fid);
        // The receiver-tower probe reaches an owner through a frame class's supertype_names, which are
        // SOURCE-WRITTEN simple names, so the classifier path without its package is keyed as an alias.
        if (ownerSimplePath(owner)) |short| {
            const skey = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ short, recv_key });
            try extension_props.put(.{ .a = skey, .b = p.name.name }, fid);
        }
        try owner_keyed_ext_names.put(p.name.name, {});
        // kotlinc-exact scoping: a member extension is visible only where its owner is a receiver or via
        // import, so there is NO plain (recv, name) pair.
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
        // A second, package-qualified key: same-name nullable extension properties in different packages
        // blank the bare-name entry, but the executing frame's package still disambiguates.
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
    // A member-extension accessor body has its declaring class's `this` in lexical scope, so dispatch
    // seeds the accessor frame with the owner instance.
    if (epd.owner) |owner| {
        try module.registry.member_ext_owner_class.put(fid, owner);
    }
}

fn lowerExtensionPropSetter(
    ctx: *BuildCtx,
    epd: ExtPropDecl,
    p: *const ast.Property,
    setter: *ast.Accessor,
    recv_name: []const u8,
    recv_key: []const u8,
    dispatch_owner: ?[]const u8,
) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const classes = &ctx.classes;
    const companion_singletons = &ctx.companion_singletons;
    const extension_prop_setters = &ctx.extension_prop_setters;
    const owner_keyed_ext_names = &ctx.owner_keyed_ext_names;
    const setter_param_name = if (setter.params.len != 0) setter.params[0].name else "value";
    var recv_members = StringSet.init(a);
    defer recv_members.deinit();
    if (classes.get(recv_name)) |rdef| {
        const rg = rdef.borrow();
        for (rg.get().primary_params) |*pp| try recv_members.put(pp.name, {});
        for (rg.get().body_properties) |*pp| try recv_members.put(pp.name, {});
        rg.deinit();
    }
    // A `var X.Companion.x` setter's bare-name writes target the companion's own members, so they lower
    // as `this` field writes rather than top-level bindings.
    if (companion_singletons.get(recv_name)) |comp_name| {
        if (classes.get(comp_name)) |cdef| {
            const cgm = cdef.borrow();
            for (cgm.get().primary_params) |*pp| try recv_members.put(pp.name, {});
            for (cgm.get().body_properties) |*pp| try recv_members.put(pp.name, {});
            cgm.deinit();
        }
    }
    const nm = try std.fmt.allocPrint(a, "__ext_set_{s}_{s}", .{ recv_name, p.name.name });
    module.pending_accessor_this_label = p.name.name;
    module.pending_accessor_dispatch_owner = dispatch_owner;
    const fid = switch (setter.body) {
        .Expr => |body| try ir.lower.lowerAccessorExpr(module, recv_name, &recv_members, &.{ "this", setter_param_name }, &body, nm),
        .Block => |blk| try ir.lower.lowerAccessorBlock(module, recv_name, &recv_members, &.{ "this", setter_param_name }, &blk, nm),
    };
    // Same private-only gating as the getter above.
    if (epd.owner) |owner| {
        const okey = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ owner, recv_key });
        try extension_prop_setters.put(.{ .a = okey, .b = p.name.name }, fid);
        if (ownerSimplePath(owner)) |short| {
            const skey = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ short, recv_key });
            try extension_prop_setters.put(.{ .a = skey, .b = p.name.name }, fid);
        }
        try owner_keyed_ext_names.put(p.name.name, {});
        try module.registry.member_ext_owner_class.put(fid, owner);
    } else {
        try extension_prop_setters.put(.{ .a = recv_key, .b = p.name.name }, fid);
    }
}

/// Fold the local-fn default thunks into `func_defaults`, then propagate supertype member defaults
/// onto the overrides that lack their own.
fn settleDefaultArgThunks(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const func_defaults = &ctx.func_defaults;
    {
        var it = module.registry.local_fn_defaults.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*.int();
            if (!func_defaults.contains(key)) {
                try func_defaults.put(key, try a.dupe(?FuncId, e.value_ptr.items));
            }
        }
    }

    try propagateInheritedDefaults(a, module, func_defaults, ctx.base_classes_len);
}

fn registerTypeAliasTags(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    // `typealias Name = Target` maps Name to Target's simple head; a function-type target maps to its
    // `Function{N}` tag so applicability sees an aliased parameter as function-typed.
    for (decls) |*d| {
        if (d.* != .TypeAlias) continue;
        const ta = &d.TypeAlias;
        if (ta.target.function) |ft| {
            // Match the direct function-type lowering, which tags by VALUE-parameter count and tracks the
            // receiver separately: a `T.() -> R` alias is `Function0`, not `Function1`.
            const arity = ft.params.len;
            const tag = try std.fmt.allocPrint(a, "Function{d}", .{arity});
            try module.registry.type_aliases.put(ta.name.name, tag);
            if (ft.receiver != null) {
                try module.registry.recv_fn_aliases.put(ta.name.name, @intCast(@min(arity, 255)));
            }
            continue;
        }
        const full = ta.target.name.name;
        const target = if (std.mem.findScalarLast(u8, full, '.')) |dot| full[dot + 1 ..] else full;
        if (target.len != 0 and !std.mem.eql(u8, target, ta.name.name)) {
            try module.registry.type_aliases.put(ta.name.name, target);
        }
    }
}

/// Rewrite function-type and scalar alias names in this build's lowered parameter types, so
/// applicability and scoring see the target.
fn rewriteAliasedParamTypes(ctx: *BuildCtx) Allocator.Error!void {
    const module = ctx.module;
    const base_funcs_len = ctx.base_funcs_len;
    // In an extending build only this build's funcs rewrite: base param slices are shared with the
    // immutable base, and a user alias matching a base param type name fails `canExtendBase`.
    for (module.funcs.items[base_funcs_len..]) |*f| {
        for (f.params) |*p| {
            const resolved = module.registry.type_aliases.get(p.ty.name) orelse continue;
            // A function-typed alias becomes its `Function{N}` tag for trailing-lambda alignment; a SCALAR
            // alias becomes its primitive target, since the alias is transparent to the strict scorer.
            if (std.mem.startsWith(u8, resolved, "Function")) {
                p.ty.name = resolved;
            } else if (@import("../vm/overload_match.zig").builtinParamKind(resolved) != null) {
                p.ty.name = resolved;
            }
        }
    }
}

fn materialiseRegistry(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const object_names = &ctx.object_names;
    const base_object_names_len = ctx.base_object_names_len;
    const companion_singletons = &ctx.companion_singletons;
    const enclosing_class = &ctx.enclosing_class;
    const func_type_params = &ctx.func_type_params;
    const top_level_delegated_props = &ctx.top_level_delegated_props;
    const delegated_body_props = &ctx.delegated_body_props;
    // Object names, companion singletons, enclosing-class, func type params and delegated props; the
    // lowering-only registry fields stay in place. Only this build's object names append.
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
            // Header-time registration already put this build's entries; only seed-carried ones land here.
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
}

/// Write each class's own field slots onto its `ir.Class`, so the layout stops
/// being a runtime discovery and becomes a property of the declaration that the
/// image carries and the lowering can read.
///
/// Only a class with no layout yet is described: a base image's classes arrive
/// with theirs, and re-deriving them would walk the whole class table.
/// Fill every unpublished class's own slots and compose the chains.
///
/// Runs twice: once with the declarations final and before any body lowers, so
/// a field read can carry its slot, and once at the end for the classes
/// lowering itself creates. The second pass skips what the first published.
fn publishFieldLayoutsAndLink(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    markIntrinsicBackedClasses(module);
    // Staleness is read before the publish, which is what would erase it.
    const first_class = if (ctx.base != null) ctx.base_classes_len else 0;
    const base_stale = first_class != 0 and module.baseFieldLayoutsStale(first_class);
    try publishFieldLayouts(ctx);
    if (first_class != 0 and !base_stale) {
        try module.linkFieldSlotsFrom(a, first_class);
    } else {
        try module.linkFieldSlots(a);
    }
    if (class_layout.auditOn()) {
        std.debug.print("[layout-link] classes={d} first={d} base_stale={}\n", .{
            module.classes.items.len, first_class, base_stale,
        });
    }
}

/// Answer, once per class, whether construction routes through a host
/// intrinsic. The runtime asked this by scanning a thirty-entry name table on
/// every construction, for every class; it is a function of the FQN and never
/// changes.
fn markIntrinsicBackedClasses(module: *ir.Module) void {
    for (module.classes.items) |*c| {
        if (c.is_intrinsic_backed) continue;
        if (c.fqn.len == 0) continue;
        c.is_intrinsic_backed = new_instance_mod.isIntrinsicClass(c.fqn);
    }
}

fn publishFieldLayouts(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const lctx = class_layout.Ctx{
        .allocator = a,
        .shadow_key = &publishShadowKey,
        .shadow_ctx = @ptrCast(module),
        .delegate_keys = &publishDelegateKeys,
        .delegate_ctx = @ptrCast(ctx),
    };
    var slots: std.ArrayList(class_layout.Slot) = .empty;
    defer slots.deinit(a);
    for (module.classes.items) |*c| {
        if (c.field_layout.state != .unpublished) continue;
        slots.clearRetainingCapacity();
        c.field_layout = try classOwnFieldLayout(ctx, &lctx, c, &slots);
    }
}

fn classOwnFieldLayout(
    ctx: *BuildCtx,
    lctx: *const class_layout.Ctx,
    c: *const ir.Class,
    slots: *std.ArrayList(class_layout.Slot),
) Allocator.Error!ir.FieldLayout {
    const a = ctx.a;
    const module = ctx.module;
    const def = ctx.classes.get(c.fqn) orelse ctx.classes.get(c.name) orelse
        return .{ .state = .unavailable };
    const g = def.borrow();
    defer g.deinit();
    const d = g.get();
    // An alias entry can answer for a different declaration; only the class's
    // own definition may describe it.
    if (!std.mem.eql(u8, d.fqn, c.fqn)) return .{ .state = .unavailable };
    if (d.is_interface) return .{ .state = .interface };
    if (d.is_anonymous) return .{ .state = .anonymous };
    if (d.is_local_runtime) return .{ .state = .local_runtime };

    // Everything that can refuse runs before anything is allocated, so a class
    // the table cannot describe costs nothing and keeps the runtime's walk.
    var super: ?ir.ClassId = null;
    if (d.parent) |parent| {
        const pg = parent.borrow();
        const pfqn = pg.get().fqn;
        pg.deinit();
        super = module.classIdByFqn(pfqn) orelse return .{ .state = .unavailable };
    }
    try class_layout.appendOwnSlots(lctx, d, slots);
    for (slots.items) |slot| {
        if (class_layout.seedKind(slot.seed) == null) return .{ .state = .unavailable };
    }

    const own = try a.alloc(ir.FieldSlot, slots.items.len);
    for (slots.items, own) |slot, *out| {
        out.* = .{ .name = slot.name, .seed = class_layout.seedKind(slot.seed).?, .plain = slot.plain, .ctor = slot.ctor, .plain_write = slot.plain_write, .type_head = slot.type_head };
    }

    // A plain constructor parameter this class's own body shadows with a
    // property of the same name never becomes a field; whether one of the rest
    // does depends on the whole chain, which the composition decides.
    var captures: std.ArrayList([]const u8) = .empty;
    errdefer captures.deinit(a);
    next: for (d.primary_params) |p| {
        if (p.property != null) continue;
        for (d.body_properties) |*bp| {
            if (std.mem.eql(u8, bp.name, p.name)) continue :next;
        }
        try captures.append(a, p.name);
    }
    return .{
        .own = own,
        .captures = try captures.toOwnedSlice(a),
        .super = super,
        .state = .ok,
    };
}

/// `ctor_select.shadowFieldKey` against the module alone: the same two registry
/// sets decide the storage key, with no program image to hand.
fn publishShadowKey(ctx: ?*anyopaque, cls: []const u8, prop: []const u8) []const u8 {
    const module: *const Module = @ptrCast(@alignCast(ctx orelse return prop));
    var buf: [256]u8 = undefined;
    const probe = std.fmt.bufPrint(&buf, "{s}\x1f{s}", .{ cls, prop }) catch return prop;
    if (module.registry.private_shadow_props.getKey(probe)) |k| return k;
    return module.registry.override_cell_props.getKey(probe) orelse prop;
}

fn publishDelegateKeys(
    ctx_in: ?*anyopaque,
    def: *const ClassDef,
    out: *std.ArrayList(class_layout.Slot),
    a: Allocator,
) Allocator.Error!void {
    const ctx: *BuildCtx = @ptrCast(@alignCast(ctx_in orelse return));
    next: for (classDelegates(ctx, def)) |sf| {
        const field_key = try std.fmt.allocPrint(ctx.a, "__delegate__{s}", .{sf.name});
        // A class delegating one interface from two levels stores one field, the
        // most derived expression's, so the layout holds one slot. The walk
        // dedups against the whole chain it has accumulated; here the chain's
        // levels are described one at a time, so the ancestors are consulted.
        for (out.items) |e| {
            if (std.mem.eql(u8, e.name, field_key)) {
                ctx.a.free(field_key);
                continue :next;
            }
        }
        if (ancestorDelegatesInterface(ctx, def, sf.name)) {
            ctx.a.free(field_key);
            continue :next;
        }
        try out.append(a, .{ .name = field_key, .seed = .Null });
    }
}

fn classDelegates(ctx: *BuildCtx, def: *const ClassDef) []const StrFunc {
    const key = if (def.fqn.len != 0) def.fqn else def.name;
    return ctx.class_delegates.get(key) orelse &.{};
}

fn ancestorDelegatesInterface(ctx: *BuildCtx, def: *const ClassDef, iface: []const u8) bool {
    var depth: usize = 0;
    var cur: ?ObjRef(ClassDef) = if (def.parent) |p| p.clone() else null;
    defer if (cur) |c| c.deinit();
    while (cur) |c| : (depth += 1) {
        if (depth >= ClassDef.MAX_WALK) return false;
        const g = c.borrow();
        const d = g.get();
        for (classDelegates(ctx, d)) |sf| {
            if (std.mem.eql(u8, sf.name, iface)) {
                g.deinit();
                return true;
            }
        }
        const next = if (d.parent) |p| p.clone() else null;
        g.deinit();
        c.deinit();
        cur = next;
    }
    return false;
}

/// `KLIO_INTRINSIC_PROBE=1`: how many member-call sites name a host intrinsic
/// that a stable id could point at.
///
/// This is the question the whole resolution campaign arrives at. 84% of what
/// the member-call gate leaves unresolved has a KNOWN receiver and no
/// `FuncId` to name, because the target is Zig behind an FQN-keyed table.
/// Nothing can bind those until the table has ids; this counts how many sites
/// would take one.
fn probeIntrinsicMembers(module: *ir.Module) void {
    if (runtime.envOnce("KLIO_INTRINSIC_PROBE") == null) return;
    var sites: usize = 0;
    var with_head: usize = 0;
    var hit_qualified: usize = 0;
    var hit_simple: usize = 0;
    var miss: usize = 0;
    var buf: [512]u8 = undefined;
    for (module.funcs.items) |*f| {
        for (f.blocks) |*b| {
            for (b.insts) |*inst| {
                if (inst.* != .CallMember) continue;
                const cm = &inst.CallMember;
                sites += 1;
                if (cm.x().resolved != null) continue;
                // A proven site is already answered without a name; what this
                // counts is what an intrinsic INDEX would still have to cover.
                if (cm.builtin_proven) continue;
                const sr = cm.x().static_recv orelse continue;
                const head = switch (module.consts.items[sr.int()]) {
                    .String => |str| str,
                    else => continue,
                };
                const name = switch (module.consts.items[cm.name.int()]) {
                    .String => |str| str,
                    else => continue,
                };
                with_head += 1;
                // The table keys members as `<package>.<Class>.<member>`. A
                // site's head is sometimes written out and sometimes simple,
                // so both spellings are tried before calling it a miss.
                const q = std.fmt.bufPrint(&buf, "{s}.{s}", .{ head, name }) catch continue;
                if (stdlib.implementation(q) != null) {
                    hit_qualified += 1;
                    continue;
                }
                const simple = if (std.mem.findScalarLast(u8, head, '.')) |i| head[i + 1 ..] else head;
                const q2 = std.fmt.bufPrint(&buf, "kotlin.{s}.{s}", .{ simple, name }) catch continue;
                if (stdlib.implementation(q2) != null) {
                    hit_simple += 1;
                    continue;
                }
                const q3 = std.fmt.bufPrint(&buf, "kotlin.collections.{s}.{s}", .{ simple, name }) catch continue;
                if (stdlib.implementation(q3) != null) {
                    hit_simple += 1;
                    continue;
                }
                miss += 1;
                if (runtime.envOnce("KLIO_INTRINSIC_NAMES") != null)
                    std.debug.print("[intrinsic-miss] {s}.{s}\n", .{ head, name });
            }
        }
    }
    std.debug.print("[intrinsic-probe] member_sites={d} unresolved_with_head={d} hit_as_written={d} hit_by_simple_name={d} miss={d}\n", .{
        sites, with_head, hit_qualified, hit_simple, miss,
    });
}

/// Whether `indices` and `lastIndex` still mean the stdlib extension
/// properties everywhere in this build.
///
/// The runtime asks the same question once per dispatch-cache generation and
/// over the same three records; asking it here instead is what lets a read of
/// either name on an array carry a proven builtin rather than a name.
///
/// A declaration outside the stdlib packages answers no. Scoping would in fact
/// keep a user's extension out of a stdlib body, but nothing here records
/// which scope a site was lowered in, so the verdict stays name-global and
/// over-declines.
fn indexPropsUnshadowed(ctx: *BuildCtx) bool {
    const names = [_][]const u8{ "indices", "lastIndex" };
    for (names) |n| {
        if (ctx.owner_keyed_ext_names.contains(n)) return false;
        if (ctx.nullable_ext_props.contains(n)) return false;
    }
    var it = ctx.extension_props.iterator();
    while (it.next()) |e| {
        const b = e.key_ptr.b;
        if (!std.mem.eql(u8, b, "indices") and !std.mem.eql(u8, b, "lastIndex")) continue;
        const f = ctx.module.funcById(e.value_ptr.*) orelse return false;
        if (!stdlib.isKnownPackage(f.package)) return false;
    }
    return true;
}

fn finishModule(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    // Rebuild the name index so funcId lookups see every registered stub.
    try module.rebuildFuncNameIndex(a);

    // Virtual override families settle after every class and member header is complete, so runtime
    // member dispatch can use class and slot ids alone.
    // Extending a base keeps the dispatch entries that came with it.
    if (ctx.base != null) {
        try module.linkMethodSlotsFrom(a, ctx.base_classes_len);
    } else {
        try module.linkMethodSlots(a);
    }

    // Again for the classes lowering created: a function-local class, an object
    // expression. A class the earlier pass published is skipped.
    try publishFieldLayoutsAndLink(ctx);

    // Every property accessor now exists, which is the earliest a field read
    // whose answer is a getter can name it.
    // The property table first: the site pass below reads it, and it needs
    // only the accessors the bodies created and the layouts the publish above
    // composed.
    if (!std.mem.eql(u8, runtime.envOnce("KLIO_PROP_SLOT") orelse "1", "0"))
        try module.linkPropertySlots();

    // Two rounds, because each pass is the other's input: the register pass
    // names a read's receiver so the route pass can bind it, and a bound read
    // is a getter call whose declared return names the next register.
    {
        const route_on = !std.mem.eql(u8, runtime.envOnce("KLIO_GETTER_ROUTE") orelse "1", "0");
        var round: usize = 0;
        while (round < 2) : (round += 1) {
            module.linkReceiverClasses(a);
            if (route_on) module.linkGetterRoutes();
            module.linkSuperMembers();
        }
        module.linkBuiltinFields(a, indexPropsUnshadowed(ctx));
    }
    if (runtime.envOnce("KLIO_SCOPE_WHY") != null) {
        // How much of the member-method table the ambiguity set withdraws.
        std.debug.print("[member-table] keys={d} ambiguous={d}\n", .{
            module.registry.member_method_fids.count(),
            module.registry.member_method_ambiguous.count(),
        });
        if (runtime.envOnce("KLIO_FUNC_FIND")) |fwant| {
            var n2: usize = 0;
            for (module.funcs.items) |*ff| {
                if (std.mem.find(u8, ff.name, fwant) == null) continue;
                n2 += 1;
                if (n2 <= 10)
                    std.debug.print("[func-find] {s} id={d} hasBody={} params={d} fqn={s}\n", .{ ff.name, ff.id.int(), ff.hasBody(), ff.params.len, ff.fqn });
            }
            std.debug.print("[func-find] total={d}\n", .{n2});
        }
        if (runtime.envOnce("KLIO_MEMBER_TABLE_FIND")) |want| {
            var it = module.registry.member_method_fids.iterator();
            var n: usize = 0;
            while (it.next()) |e| {
                if (std.mem.find(u8, e.key_ptr.*, want) == null) continue;
                n += 1;
                if (n > 8) continue;
                var pretty: [256]u8 = undefined;
                const len = @min(e.key_ptr.len, pretty.len);
                @memcpy(pretty[0..len], e.key_ptr.*[0..len]);
                for (pretty[0..len]) |*ch| {
                    if (ch.* == 0) ch.* = '|';
                }
                const tf = module.funcById(e.value_ptr.*);
                const sig = module.decl_sigs.get(e.value_ptr.*.int());
                std.debug.print("[member-table-find] {s}  fid={d} hasBody={} sigBody={?} fqn={s}\n", .{
                    pretty[0..len],
                    e.value_ptr.*.int(),
                    tf != null and tf.?.hasBody(),
                    if (sig) |sg| sg.has_body else null,
                    if (tf) |t| t.fqn else "?",
                });
            }
            std.debug.print("[member-table-find] total={d}\n", .{n});
        }
    }

    try module.linkClassAncestors(a);
    if (!std.mem.eql(u8, runtime.envOnce("KLIO_ISCHECK") orelse "1", "0"))
        module.linkInstanceOfTargets();
    module.linkCtorPicks();
    module.probeCtorArity();
    module.probeInstanceOf();
    module.probeClassGraph();
    module.probeThisOrGlobal();
    module.linkBuiltinMembers();
    module.linkBuiltinMemberRegs(a);
    module.probeBuiltinMembers();
    module.linkMemberOrGlobal();
    module.linkConstGlobals(a);
    module.linkGlobalIdentities();
    module.probeRegisterClasses(a);
    module.probeMemberByName(a);
    module.probeMemberOrGlobal();
    ir.Module.getterRejectDump();
    probeIntrinsicMembers(module);

    // Debug-only frame-dump hook for intrinsics below the ir layer.
    ir.eval.installDebugFrameDump();
}
