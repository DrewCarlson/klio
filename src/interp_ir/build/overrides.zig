//! The whole-file lowering pass: registers every top-level declaration of
//! a file set, then lowers each body into its reserved slot, resolving
//! declarations through the per-declaration FQN override maps.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const FF = runtime.forest.ForestField;
const ast = @import("ast");
const compose_pass = @import("compose_pass");
const stdlib = @import("stdlib");
const lift = @import("lift.zig");
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
const StringSet = std.StringHashMap(void);

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

const build_scan = @import("scan.zig");
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
const FileClasses = build_types.FileClasses;
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

// -------------------------------------------------------------------------
// The whole-file lowering pass.
// -------------------------------------------------------------------------

/// The alias a mangled pack-private object needs under every class that
/// declares a namesake in the object's own package.
const PendingAlias = struct { cls: []const u8, simple: []const u8, mangled: []const u8 };

/// An extension property awaiting lowering, with the declaration that
/// owns it (`null` for a file-level one).
const ExtPropDecl = struct { p: *const ast.Property, owner: ?[]const u8, owner_type_params: []const ast.TypeParam = &.{} };

/// The state one whole-file lowering pass threads through its phases.
///
/// The driver builds one of these and hands every phase a pointer to it.
/// A value lives here only when more than one phase reads or writes it;
/// scratch that a single phase owns stays a local of that phase.
const BuildCtx = struct {
    /// The caller's allocator, which owns the returned `BuiltModule`.
    allocator: Allocator,
    /// The module registry's allocator: the backing of every build-scoped
    /// table, typically a per-run arena.
    a: Allocator,
    module_ref: ObjRef(Module),
    module: *Module,
    file: *const KotlinFile,
    fqn_overrides: *const SpanStrMap,
    func_fqn_overrides: *const SpanStrMap,
    decl_pkg: *const SpanStrMap,
    base: ?*const StdlibBase,
    package_prefix: []const u8,
    /// Funcs and object names the seed clone already carried; the registry
    /// materialisation appends only past these marks.
    base_funcs_len: usize,
    base_object_names_len: usize,

    // The lift-time universe, settled before any registration.
    object_names: std.ArrayList([]const u8),
    object_spans: std.ArrayList(Span),
    nested_outer_members: lift.OuterMembers,
    nested_object_aliases: lift.AliasMap,
    mangled_nested: lift.MangledMap,
    all_decls: std.ArrayList(Decl),
    /// Superseded `expect class` shapes, kept for the default transplant.
    expect_class_ctor_params: std.StringHashMap([]const ast.ClassParam),
    expect_class_members: std.StringHashMap([]const Decl),

    /// The retained declarations every registration and lowering phase walks.
    decls: []Decl,
    /// Every class in scope: the base's plus this file set's.
    file_classes: FileClasses,
    /// The phase-1 header slots in declaration order, consumed by phase 2.
    stub_ids: std.ArrayList(FuncId),
    /// Runtime class defs this build created, for the supertype backpatch.
    new_defs: std.ArrayList(ObjRef(ClassDef)),

    // The side tables the built module carries.
    main_id: ?FuncId,
    classes: ClassTable,
    companion_singletons: std.StringHashMap([]const u8),
    enclosing_class: lift.EnclosingMap,
    body_prop_inits: PairFuncMap,
    instance_prop_getters: PairFuncMap,
    getter_prop_names: std.StringHashMap(void),
    instance_prop_setters: PairFuncMap,
    instance_prop_private: PairFuncMap,
    delegated_body_props: StrPairSet,
    primary_ctor_default_thunks: std.StringHashMap([]?FuncId),
    parent_ctor_args: std.StringHashMap([]FuncId),
    parent_ctor_arg_names: std.StringHashMap([]const ?[]const u8),
    init_blocks: std.StringHashMap([]FuncId),
    top_level_props: std.ArrayList(NameFunc),
    top_level_delegated_props: std.StringHashMap(void),
    extension_props: PairFuncMap,
    owner_keyed_ext_names: std.StringHashMap(void),
    nullable_ext_props: std.StringHashMap(?FuncId),
    extension_prop_setters: PairFuncMap,
    extension_prop_delegates: PairFuncMap,
    enum_entry_arg_inits: std.ArrayList(EnumEntryArgInit),
    enum_entry_methods: std.HashMap(StrPair, EnumEntryMethod, StrPairContext, std.hash_map.default_max_load_percentage),
    enum_entry_synth_class: PairStrMap,
    secondary_ctors: std.StringHashMap([]SecondaryCtorEntry),
    class_delegates: std.StringHashMap([]StrFunc),
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
    ) Allocator.Error!BuildCtx {
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
        const object_names: std.ArrayList([]const u8) = if (seed) |*s| s.object_names else .empty;
        const base_object_names_len = object_names.items.len;
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
            .package_prefix = package_prefix,
            .base_funcs_len = base_funcs_len,
            .base_object_names_len = base_object_names_len,
            .object_names = object_names,
            .object_spans = .empty,
            .nested_outer_members = lift.OuterMembers.init(a),
            .nested_object_aliases = nested_object_aliases,
            .mangled_nested = mangled_nested,
            .all_decls = .empty,
            .expect_class_ctor_params = std.StringHashMap([]const ast.ClassParam).init(a),
            .expect_class_members = std.StringHashMap([]const Decl).init(a),
            .decls = &.{},
            .file_classes = FileClasses.init(a),
            .stub_ids = .empty,
            .new_defs = .empty,
            .main_id = null,
            .classes = if (seed) |*s| s.classes else ClassTable.init(a),
            .companion_singletons = if (seed) |*s| s.companion_singletons else std.StringHashMap([]const u8).init(a),
            .enclosing_class = if (seed) |*s| s.enclosing_class else lift.EnclosingMap.init(a),
            .body_prop_inits = if (seed) |*s| s.body_prop_inits else PairFuncMap.init(a),
            .instance_prop_getters = if (seed) |*s| s.instance_prop_getters else PairFuncMap.init(a),
            .getter_prop_names = if (seed) |*s| s.getter_prop_names else std.StringHashMap(void).init(a),
            .instance_prop_setters = if (seed) |*s| s.instance_prop_setters else PairFuncMap.init(a),
            .instance_prop_private = if (seed) |*s| s.instance_prop_private else PairFuncMap.init(a),
            .delegated_body_props = if (seed) |*s| s.delegated_body_props else StrPairSet.init(a),
            .primary_ctor_default_thunks = if (seed) |*s| s.primary_ctor_default_thunks else std.StringHashMap([]?FuncId).init(a),
            .parent_ctor_args = if (seed) |*s| s.parent_ctor_args else std.StringHashMap([]FuncId).init(a),
            .parent_ctor_arg_names = if (seed) |*s| s.parent_ctor_arg_names else std.StringHashMap([]const ?[]const u8).init(a),
            .init_blocks = if (seed) |*s| s.init_blocks else std.StringHashMap([]FuncId).init(a),
            .top_level_props = if (seed) |*s| s.top_level_props else .empty,
            .top_level_delegated_props = if (seed) |*s| s.top_level_delegated_props else std.StringHashMap(void).init(a),
            .extension_props = if (seed) |*s| s.extension_props else PairFuncMap.init(a),
            .owner_keyed_ext_names = if (seed) |*s| s.owner_keyed_ext_names else std.StringHashMap(void).init(a),
            .nullable_ext_props = if (seed) |*s| s.nullable_ext_props else std.StringHashMap(?FuncId).init(a),
            .extension_prop_setters = if (seed) |*s| s.extension_prop_setters else PairFuncMap.init(a),
            .extension_prop_delegates = if (seed) |*s| s.extension_prop_delegates else PairFuncMap.init(a),
            .enum_entry_arg_inits = if (seed) |*s| s.enum_entry_arg_inits else .empty,
            .enum_entry_methods = if (seed) |*s| s.enum_entry_methods else std.HashMap(StrPair, EnumEntryMethod, StrPairContext, std.hash_map.default_max_load_percentage).init(a),
            .enum_entry_synth_class = if (seed) |*s| s.enum_entry_synth_class else PairStrMap.init(a),
            .secondary_ctors = if (seed) |*s| s.secondary_ctors else std.StringHashMap([]SecondaryCtorEntry).init(a),
            .class_delegates = if (seed) |*s| s.class_delegates else std.StringHashMap([]StrFunc).init(a),
            .func_defaults = if (seed) |*s| s.func_defaults else std.AutoHashMap(u32, []?FuncId).init(a),
            .func_type_params = if (seed) |*s| s.func_type_params else std.AutoHashMap(u32, [][]const u8).init(a),
        };
    }

    /// Release what exists only for the length of the build; every table
    /// the returned `BuiltModule` carries survives.
    fn deinitScratch(self: *BuildCtx) void {
        self.object_spans.deinit(self.a);
        self.mangled_nested.deinit();
        self.expect_class_ctor_params.deinit();
        self.expect_class_members.deinit();
        self.file_classes.deinit();
        self.stub_ids.deinit(self.a);
        self.new_defs.deinit(self.a);
    }

    /// Hand the finished module and its side tables to the caller.
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
) Allocator.Error!BuiltModule {
    var ctx = try BuildCtx.init(
        allocator,
        file,
        fqn_overrides,
        func_fqn_overrides,
        decl_pkg,
        file_packages,
        file_modules,
        base,
    );
    defer ctx.deinitScratch();

    // Lift nested declarations to the top level, then settle the
    // expect/actual substitutions; what survives is the declaration set
    // every pass below walks.
    try liftFileDecls(&ctx);
    try repointMangledSupertypes(&ctx);
    try repointAliasedNestedSupertypes(&ctx);
    try applyExpectActualSubstitutions(&ctx, out_lifted);

    // Register every declaration's identity and metadata. Nothing here
    // lowers a body, so a body lowered below sees complete tables however
    // its declaration is ordered in the source.
    try collectFileClasses(&ctx);
    try registerConstInitializers(&ctx);
    try registerHierarchyMethodNames(&ctx);
    try registerHierarchyShadowNames(&ctx);
    try registerMemberNameUniverse(&ctx);
    try registerPropertyTypeHeads(&ctx);
    try registerClassSuperNameChains(&ctx);
    try registerShadowedStorageProps(&ctx);
    try installLiftedNameTables(&ctx);
    try installMemberAstTables(&ctx);
    try installInlineFnTables(&ctx);
    try installTopLevelPropNames(&ctx);
    try registerFileImports(&ctx);
    try reserveClassShells(&ctx);
    try linkReservedClassSupertypes(&ctx);
    try reserveClassMemberHeaders(&ctx);
    try registerTypeAliasShapes(&ctx);
    try registerClassTypeAliasShapes(&ctx);
    // Member signatures need the same source-order independence as top-level
    // headers. Record the trailing receiver-lambda portion now, before any
    // class body lowers, so inherited calls in earlier source files still
    // receive their declaration-site lambda shape.
    try collectMemberTrailingLambdaShapes(ctx.module, &ctx.file_classes);
    try fillReservedClassPrimaryParams(&ctx);
    try registerTopLevelFuncHeaders(&ctx);
    try registerCallableExtensionProps(&ctx);
    try registerReceiverFnPropHeads(&ctx);

    // Lower every body and thunk against the now-complete header set.
    try lowerClassBodies(&ctx);
    try lowerTopLevelFunctionBodies(&ctx);
    try lowerClassMemberThunks(&ctx);
    try buildRuntimeClassDefs(&ctx);
    try registerEnumEntries(&ctx);
    try linkRuntimeSupertypes(&ctx);
    try lowerParentCtorArgThunks(&ctx);
    try lowerInitBlockThunks(&ctx);
    try lowerClassDelegateThunks(&ctx);
    try lowerSecondaryCtors(&ctx);
    try lowerTopLevelConstProps(&ctx);
    try lowerTopLevelProps(&ctx);
    try lowerExtensionProps(&ctx);

    // Settle the cross-declaration links runtime dispatch reads.
    try settleDefaultArgThunks(&ctx);
    try registerTypeAliasTags(&ctx);
    try rewriteAliasedParamTypes(&ctx);
    try materialiseRegistry(&ctx);
    try finishModule(&ctx);
    return ctx.finish();
}

// -------------------------------------------------------------------------
// Lifting and expect/actual substitution.
// -------------------------------------------------------------------------

/// Flatten the file set's nested declarations into `all_decls`, mangling
/// the pack-private objects whose simple names collide with a user type.
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
                if (std.mem.findScalarLast(u8, f, '.')) |dot| {
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

    // Pending aliases for mangled pack-private objects.
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
        if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap([]const u8).init(a);
        try gop.value_ptr.put(pa.simple, pa.mangled);
    }
}

/// Lift one top-level `object`, synthesising the class that backs it.
fn liftTopLevelObject(
    ctx: *BuildCtx,
    lift_ctx: *lift.LiftCtx,
    o: *ast.ObjectDecl,
    actual_object_names: *const StringSet,
    user_top_type_names: *const StringSet,
    pack_pkg_types: *const std.StringHashMap(StringSet),
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

/// Lift one top-level `class`, recording the defaults of an `expect` the
/// file's own `actual` supersedes.
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

/// Repoint supertype references onto the mangled name a nested class took.
fn repointMangledSupertypes(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const all_decls = &ctx.all_decls;
    const mangled_nested = &ctx.mangled_nested;
    // Repoint supertype references to a nested class that was mangled.
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

/// Repoint a bare supertype reference onto the alias its declaring
/// class's subtree sees for a mangled private nested class.
fn repointAliasedNestedSupertypes(ctx: *BuildCtx) Allocator.Error!void {
    const all_decls = &ctx.all_decls;
    const enclosing_class = &ctx.enclosing_class;
    const nested_object_aliases = &ctx.nested_object_aliases;
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
}

/// Transplant every `expect` declaration's defaults onto the `actual`
/// that supersedes it, then drop the superseded declarations.
fn applyExpectActualSubstitutions(ctx: *BuildCtx, out_lifted: ?*[]Decl) Allocator.Error!void {
    const a = ctx.a;
    const package_prefix = ctx.package_prefix;
    const fqn_overrides = ctx.fqn_overrides;
    const func_fqn_overrides = ctx.func_fqn_overrides;
    const all_decls = &ctx.all_decls;
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
}

/// Carry an `expect fun`'s parameter defaults onto its `actual`.
fn inheritExpectFunctionDefaults(ctx: *BuildCtx) Allocator.Error!void {
    const all_decls = &ctx.all_decls;
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
}

/// Carry a superseded `expect class`'s primary-constructor defaults onto
/// the matching `actual class`.
fn inheritExpectClassCtorDefaults(ctx: *BuildCtx) Allocator.Error!void {
    const all_decls = &ctx.all_decls;
    const expect_class_ctor_params = &ctx.expect_class_ctor_params;
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
}

/// Carry a superseded `expect class`'s member defaults onto the
/// signature-matching members of the `actual class`.
fn inheritExpectClassMemberDefaults(ctx: *BuildCtx) Allocator.Error!void {
    const all_decls = &ctx.all_decls;
    const expect_class_members = &ctx.expect_class_members;
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
}

// -------------------------------------------------------------------------
// Declaration registration: every table a body consults is filled here,
// before the first body lowers.
// -------------------------------------------------------------------------

/// Map every class in scope by simple name: the base's first, then this
/// file set's.
fn collectFileClasses(ctx: *BuildCtx) Allocator.Error!void {
    const base = ctx.base;
    const decls = ctx.decls;
    const file_classes = &ctx.file_classes;
    // Map every class declaration by simple name. In an extending build the
    // base's lifted classes join the universe first: hierarchy walks, init
    // own-member collection and inline splicing for USER classes reach
    // through base supertypes, while base decls themselves are never
    // re-lowered (their lowered forms arrived via the seed clone).
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

/// Record every class, companion and top-level `const val` literal.
fn registerConstInitializers(ctx: *BuildCtx) Allocator.Error!void {
    const module = ctx.module;
    const decls = ctx.decls;
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
}

/// Record each class's transitive member-function-name set.
fn registerHierarchyMethodNames(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const file_classes = &ctx.file_classes;
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
}

/// Record each class's transitive shadow-name set, with the completeness
/// bit an unresolvable supertype chain leaves clear.
fn registerHierarchyShadowNames(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const file_classes = &ctx.file_classes;
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
            const complete = try collectHierarchyShadowNames(cname.*, file_classes, &names, &seen);
            try module.registry.hierarchy_shadow_names.put(cname.*, .{ .names = names, .complete = complete });
        }
    }
}

/// Record the program-wide set of names some class declares as a member.
fn registerMemberNameUniverse(ctx: *BuildCtx) Allocator.Error!void {
    const module = ctx.module;
    const decls = ctx.decls;
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
}

/// Record every declaration's property type heads, the static types a
/// member access on that property resolves against.
fn registerPropertyTypeHeads(ctx: *BuildCtx) Allocator.Error!void {
    const decls = ctx.decls;
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
            try registerClassPropTypeHeads(ctx, &d.Class);
        } else if (d.* == .Object) {
            try registerObjectPropTypeHeads(ctx, &d.Object);
        }
    }
}

/// Record one class's own, nested and companion property type heads.
fn registerClassPropTypeHeads(ctx: *BuildCtx, c: *ast.Class) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const cfqn = try declFqnAt(a, module, fqn_overrides, c.span, package_prefix, c.name.name);
    for (c.primary_params) |*pp| {
        if (pp.property == null) continue;
        // A `vararg val` property's OBSERVED type is the materialized
        // array (`vararg val elements: T` is an `Array<out T>`), never
        // the element head — recording the element (or its bound)
        // made `elements.any { ... }` resolve against the wrong
        // receiver and decline the Array extension.
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

/// The type a class body property states, whether annotated or inferred
/// from the shape of its initializer.
fn declaredMemberPropType(c: *const ast.Class, prop: *const ast.Property) ?*const ast.TypeRef {
    if (prop.ty) |*t| return t;
    const src = propHeadSourceExpr(prop) orelse return null;
    // `private val _start = start` beside `class R(start: Double)`
    // is the parameter's type. The stdlib's ranges and `Lazy`
    // are written this way, and it was the whole of the
    // enclosing-member bucket.
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
        if (fm.Function.return_type) |*rt| return rt;
        return null;
    }
    // A FUNCTION-TYPED ctor property invoked as the
    // initializer: `val data = createFrom(...)` beside
    // `class C<T>(val createFrom: (...) -> T)` is the
    // function type's declared return — with the class's
    // own parameter substituted by its bound below, the
    // same rule an annotated `T` property already gets.
    for (c.primary_params) |*pp| {
        if (!std.mem.eql(u8, pp.name.name, fname)) continue;
        if (pp.ty.function) |ft| return &ft.ret;
        return null;
    }
    return null;
}

/// Record the type heads of one class's body properties.
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
        } else if (prop.init != null and memberSizedInitHead(c, &prop.init.?) != null) {
            try putClassPropHead(module, c.name.name, cfqn, prop.name.name, memberSizedInitHead(c, &prop.init.?).?);
        } else if (prop.init) |*init| {
            // An unannotated property states its type through a
            // literal initializer — `private var index = 0` in the
            // array iterators — and a bare read of one was the whole
            // enclosing-member block of the unbound census.
            if (literalTypeHead(init)) |head| {
                try putClassPropHead(module, c.name.name, cfqn, prop.name.name, head);
            }
        }
    }
}

/// Record the type heads a nested class's own properties register under.
fn registerNestedClassPropTypeHeads(ctx: *BuildCtx, c: *ast.Class) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
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
}

/// Record the type heads a companion's properties register under.
fn registerCompanionPropTypeHeads(ctx: *BuildCtx, c: *ast.Class) Allocator.Error!void {
    const allocator = ctx.allocator;
    const module = ctx.module;
    const decls = ctx.decls;
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
                } else if (propCtorHeadEvidence(cprop, decls, module, c)) |head| {
                    // `val iso = LongParser(MAX_MILLIS, allowSign = true)`
                    // inside LongParser's own companion states the head
                    // exactly as a top-level object's would.
                    try module.registry.class_prop_type_heads.put(.{ .a = ckey, .b = cprop.name.name }, head);
                }
            }
        }
    }
}

/// Record the type heads a top-level object's properties register under.
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
        if (prop.ty) |*ty| {
            try putClassPropHead(module, o.name.name, ofqn, prop.name.name, ty.qualified_path orelse ty.name.name);
        } else if (propCtorHeadEvidence(prop, decls, module, null)) |head| {
            try putClassPropHead(module, o.name.name, ofqn, prop.name.name, head);
        }
    }
}

/// Record each class's transitive supertype-name chain and the declared
/// bounds of its type parameters.
fn registerClassSuperNameChains(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const file_classes = &ctx.file_classes;
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
            try collectHierarchySuperNames(a, e.value_ptr.get(), file_classes, &chain, &seen);
            // Every enum class IS-A `kotlin.Enum` implicitly; record it so
            // Enum-receiver ranking and enum recognition see the relation.
            if (e.value_ptr.get().is_enum and !seen.contains("Enum")) {
                try chain.append(a, "Enum");
            }
            const super_chain = try chain.toOwnedSlice(a);
            try module.registry.class_super_names.put(e.key_ptr.*, super_chain);
            // Also key by fqn so a receiver whose simple name collides
            // across packs (kotlinx.io.Buffer vs an okio stand-in named
            // Buffer) resolves its OWN super chain (Buffer : Sink, Source)
            // when the extension-receiver compatibility check walks it.
            {
                const cfqn = try resolveFqn(a, fqn_overrides, e.value_ptr.get().name.span, package_prefix, e.key_ptr.*);
                if (!std.mem.eql(u8, cfqn, e.key_ptr.*) and
                    !module.registry.class_super_names.contains(cfqn))
                {
                    try module.registry.class_super_names.put(cfqn, super_chain);
                }
            }
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
}

/// Record the stored properties that shadow (or override) a supertype's
/// same-named storage and so need their own cell.
fn registerShadowedStorageProps(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const file_classes = &ctx.file_classes;
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
                    try record(module, a, cname, chain, file_classes, p.name.name, false);
                } else {
                    // A non-private ctor-param property matching a STORED
                    // supertype property is necessarily an `override`
                    // (kotlinc rejects the shadow form) — the parser does
                    // not carry the modifier on params.
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

/// Install the lift-time alias, mangle, enclosing-class and
/// companion-singleton tables the lowerer reads.
fn installLiftedNameTables(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const nested_object_aliases = &ctx.nested_object_aliases;
    const mangled_nested = &ctx.mangled_nested;
    const enclosing_class = &ctx.enclosing_class;
    const companion_singletons = &ctx.companion_singletons;
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
}

/// Register the member ASTs the lowerer resolves against: inline-member
/// owners, member property ASTs, and class supertype references.
fn installMemberAstTables(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const file_classes = &ctx.file_classes;
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
            registerMemberPropAsts(a, e.value_ptr.get().members, e.value_ptr.get().name.name, resolveFqn(a, fqn_overrides, e.value_ptr.get().span, package_prefix, e.value_ptr.get().name.name) catch null);
            ir.lower.registerClassSupertypeRefs(e.value_ptr.get().name.name, e.value_ptr.get().supertypes);
            registerClassSupertypes(e.value_ptr.get().members);
        }
        // Top-level objects (and any class the map above missed) from this
        // build's decls — user files plus re-parsed pack sources.
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

/// Make every `inline fun` body available to the lowerer by simple name.
fn installInlineFnTables(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const base = ctx.base;
    const decls = ctx.decls;
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
}

/// Register the top-level property names and each declaration's scoping
/// identity, so a bare read ranks the way a bare call does.
fn installTopLevelPropNames(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const base = ctx.base;
    const module = ctx.module;
    const decls = ctx.decls;
    const func_fqn_overrides = ctx.func_fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const tl = std.heap.page_allocator;
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
}

/// Record the file's imports: leaf-keyed non-wildcard paths and the
/// wildcard packages, both keyed by declaring file.
fn registerFileImports(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const file = ctx.file;
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
}

/// Reserve a class shell per declaration, keyed by fully-qualified name.
fn reserveClassShells(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const object_spans = &ctx.object_spans;
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
}

/// Link every reserved shell to its exact superclass identities.
fn linkReservedClassSupertypes(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
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
}

/// Reserve complete member headers for every class.
fn reserveClassMemberHeaders(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
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
}

/// Register the file-level typealias shapes and function-type tags.
fn registerTypeAliasShapes(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
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
}

/// Register the typealias shapes declared inside a class body, which are
/// written in that class's own scope.
fn registerClassTypeAliasShapes(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const file_classes = &ctx.file_classes;
    // A `typealias` declared in a class body is in scope inside that class
    // (and reachable as `Owner.Alias`); its target is written in the
    // class's own scope, so `typealias TAtoInner = Inner` names the nested
    // class.
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
                // The target is written in the class's scope: a nested class
                // of the owner resolves to that class's index name.
                if (module.classId(c.name.name)) |owner_id| {
                    if (module.classIdNestedIn(owner_id, target.name)) |nested_id| {
                        if (nested_id.int() < module.classes.items.len) target.name = module.classes.items[nested_id.int()].name;
                    }
                }
            }
            const alias_shape = ir.ModuleRegistry.TypeAliasShape{ .type_params = type_params, .target = target };
            const qualified = try std.fmt.allocPrint(a, "{s}.{s}", .{ c.name.name, ta.name.name });
            try module.registry.type_alias_types.put(qualified, alias_shape);
            if (!module.registry.type_alias_types.contains(ta.name.name)) {
                try module.registry.type_alias_types.put(ta.name.name, alias_shape);
            }
        }
    }
    ir.lower.setTypeAliasTags(&module.registry.type_aliases);
}

/// Fill every reserved class's primary-constructor parameters, which a
/// constructor call in an earlier-lowered body already reads.
fn fillReservedClassPrimaryParams(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
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
}

/// Register every top-level function's header before any body lowers.
fn registerTopLevelFuncHeaders(ctx: *BuildCtx) Allocator.Error!void {
    const decls = ctx.decls;
    // Phase 1 of two-phase consumption: register every top-level
    // function's HEADER — its package-qualified FQN, declaring package,
    // and receiver type — into the complete header set BEFORE any body is
    // lowered. Classes were reserved just above; together these phase-1
    // headers span every pack, feature, and user file, so phase-2 body
    // lowering resolves bare calls against the full package-qualified set
    // through the symbol index rather than a partially-populated table.
    for (decls) |*d| {
        if (d.* == .Function) try registerTopLevelFuncHeader(ctx, &d.Function);
    }
}

/// Reserve one top-level function's declaration identity: its FQN,
/// package, receiver, declared signature and type-parameter bounds.
fn registerTopLevelFuncHeader(ctx: *BuildCtx, f: *ast.Function) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const func_fqn_overrides = ctx.func_fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const stub_ids = &ctx.stub_ids;
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
    const stub_params = try headerStubParams(ctx, f, receiver_ty);
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
    try registerHeaderTypeParams(ctx, f, id);
    // Key the inline-fn AST by the header stub's FuncId, so a
    // bare call the symbol index resolves to this declaration
    // splices exactly this declaration.
    if (f.is_inline and f.body != null) {
        try ir.lower.registerInlineFnId(id.int(), FF(ast.Function).fromPtr(f));
    }
    try stub_ids.append(a, id);
}

/// The declared parameter list a header stub carries.
fn headerStubParams(ctx: *BuildCtx, f: *const ast.Function, receiver_ty: ?ir.TypeRef) Allocator.Error![]Param {
    const a = ctx.a;
    // The header stub carries the full declared parameter list (the
    // same `loweredTypeRef` rendering the phase-2 body install uses),
    // not just a receiver placeholder: class methods lower between
    // phase 1 and phase 2, and their call-site shape decisions — a
    // trailing lambda's expected arity, default-gap checks — read
    // `Func.params` and must see the declared signature, not an
    // empty stub.
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

/// Register a header's type-parameter names and declared upper bounds.
fn registerHeaderTypeParams(ctx: *BuildCtx, f: *const ast.Function, id: FuncId) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
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
            break :blk std.mem.find(u8, std.mem.span(w), f.name.name) != null;
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
}

/// Register the callable extension-property headers, so
/// `receiver.property(args)` keeps the extension getter.
fn registerCallableExtensionProps(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
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
}

/// Record the receiver-function-typed property heads, which method
/// bodies consult while they lower.
fn registerReceiverFnPropHeads(ctx: *BuildCtx) Allocator.Error!void {
    const module = ctx.module;
    const file_classes = &ctx.file_classes;
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
}

// -------------------------------------------------------------------------
// Body and thunk lowering.
// -------------------------------------------------------------------------

/// Lower every class body against the complete top-level header set.
fn lowerClassBodies(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const file_classes = &ctx.file_classes;
    const nested_outer_members = &ctx.nested_outer_members;
    // Lower each class after the top-level function headers are registered,
    // so a class method body's bare call to a sibling top-level function
    // resolves against the complete header set. The receiver-type member
    // gate keeps a same-named implicit-receiver member preferred over the
    // now-visible global.
    var empty_set = StringSet.init(a);
    defer empty_set.deinit();
    for (decls) |*d| {
        if (d.* == .Class) {
            const c = &d.Class;
            const extras: *const StringSet = nested_outer_members.getPtr(c.name.name) orelse &empty_set;
            const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
            const cls_pkg = try declPackage(a, decl_pkg, fqn_overrides, c.span, package_prefix, c.name.name);
            _ = try ir.lower.lowerClassWithExtrasFqnPkg(module, c, file_classes, extras, cfqn, cls_pkg);
        }
    }
}

/// Lower each top-level function body into the slot phase 1 reserved.
fn lowerTopLevelFunctionBodies(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const file_classes = &ctx.file_classes;
    const stub_ids = &ctx.stub_ids;
    // Phase 2 of two-phase consumption: lower each function body into its
    // reserved slot, resolving bodies and extension-receiver bindings
    // against the now-complete phase-1 header set (above).
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
            const func = try ir.lower.lowerFunctionBodyInto(module, f, file_classes);
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
            if (std.mem.eql(u8, f.name.name, "main")) ctx.main_id = id;
            try module.top_level.append(a, id);

            try registerBodyFuncTypeParams(ctx, f, id);

            try lowerFunctionDefaultThunks(ctx, f, id);
        }
    }
}

/// Record a lowered function's type-parameter names and declared bounds.
fn registerBodyFuncTypeParams(ctx: *BuildCtx, f: *const ast.Function, id: FuncId) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const func_type_params = &ctx.func_type_params;
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
}

/// Lower one default-argument thunk per parameter that declares a default.
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
                // A default that references a CONTEXT parameter
                // (`context(a: C) fun f(b: C = a)`) resolves it the
                // way the body does: the thunk runs at call time with
                // the context on the stack, so stash the context
                // params for the thunk's `consumePendingCtx` to bind
                // via `CtxLoad` (cleared per thunk after it consumes).
                if (f.context_params.len != 0) {
                    module.has_context_decls = true;
                    module.pending_ctx = .{ .params = f.context_params, .type_params = f.type_params };
                }
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

/// Lower every class's body-property initialisers, accessors and
/// primary-constructor default thunks.
fn lowerClassMemberThunks(ctx: *BuildCtx) Allocator.Error!void {
    const decls = ctx.decls;
    // Body-property initialisers, getters, setters, ctor defaults.
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
    // Companion-object members, enum entries, and nested-class names are
    // visible under their bare names in a primary-ctor default value
    // (`class Stroke(cap: StrokeCap = DefaultCap)` reads the companion's
    // `DefaultCap`), the same as inside a method body.
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
        try lowerBodyPropertyThunks(ctx, c, p, &own_members, .{
            .prop_init_params = prop_init_params.items,
            .param_types = body_prop_param_types,
            .enclosing = body_enclosing,
            .cfqn = body_prop_cfqn,
            .dual = body_prop_dual,
        });
    }
}

/// Lower one primary-constructor default thunk per parameter that
/// declares a default value.
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

/// The per-class context a body property's thunks lower against.
const BodyPropScope = struct {
    /// The thunk's parameter names: `this`, then the ctor parameters.
    prop_init_params: []const []const u8,
    /// The declared types parallel to the primary-ctor parameters.
    param_types: []const ir.Param,
    /// A nested class's lexically-enclosing member names.
    enclosing: ?*const StringSet,
    /// The class's fully-qualified name, and whether it differs from the
    /// simple name (which then takes a second, aliasing key).
    cfqn: []const u8,
    dual: bool,
};

/// Lower one body property's storage initialiser, delegate and accessors.
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
        const fid = try ir.lower.lowerPropertyInitExpr(module, c.name.name, own_members, body_enclosing, prop_init_params, body_prop_param_types, init, nm, storage_init_ty);
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
        const fid = try ir.lower.lowerPropertyInitExpr(module, c.name.name, own_members, body_enclosing, prop_init_params, body_prop_param_types, delegate, nm, null);
        try body_prop_inits.put(.{ .a = c.name.name, .b = p.name.name }, fid);
        if (body_prop_dual) try body_prop_inits.put(.{ .a = body_prop_cfqn, .b = p.name.name }, fid);
    }
    try lowerBodyPropertyGetter(ctx, c, p, own_members);
    try lowerBodyPropertySetter(ctx, c, p, own_members);
}

/// Lower a body property's custom getter and register its dispatch keys.
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
                // The property's declared type is the expression body's
                // expected type: a getter returning a lambda
                // (`get() = { collectTo(it) }` typed `suspend (P) -> Unit`)
                // needs it to prove the lambda's parameter shape.
                break :blk try ir.lower.lowerAccessorExprWithExpected(module, c.name.name, own_members, &.{"this"}, rewritten, nm, p.ty);
            },
            .Block => |blk_body| blk: {
                const rewritten = try lift.rewriteBlockField(a, &blk_body, p.name.name, c.name.name);
                break :blk try ir.lower.lowerAccessorBlock(module, c.name.name, own_members, &.{"this"}, &rewritten, nm);
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
}

/// Lower a body property's custom setter and register its dispatch keys.
fn lowerBodyPropertySetter(ctx: *BuildCtx, c: *ast.Class, p: *const ast.Property, own_members: *StringSet) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const instance_prop_setters = &ctx.instance_prop_setters;
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

/// Synthesise the runtime `ClassDef` of every class, FQN-keyed, with a
/// simple-name view for callers holding no resolved identity.
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
    // Defs created by THIS build: the parent/interface backpatch below
    // links only these — seeded base defs arrive fully linked.
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
}

/// Populate every enum's entries, per-entry overrides and ctor-arg thunks.
fn registerEnumEntries(ctx: *BuildCtx) Allocator.Error!void {
    const base = ctx.base;
    const decls = ctx.decls;
    // Populate enum entries + per-entry overrides + ctor-arg thunks. An
    // extending build continues the base's identity sequence so default
    // toString/hashCode renderings match the whole-program numbering.
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
    for (c.enum_entries, 0..) |*entry, ordinal| {
        try lowerEnumEntry(ctx, c, entry, ordinal, class_def, next_id, &entries);
    }
    const g = class_def.borrowMut();
    g.get().enum_entries = try entries.toOwnedSlice(a);
    g.deinit();
}

/// Build one enum entry's singleton instance and its ctor-arg thunks.
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

    // Lower an init thunk per constructor slot: the entry's explicit
    // args, then default values for any trailing primary-ctor params
    // the entry omits (`enum E(val n:Int, val f:Boolean=false){A(1)}`
    // must still initialize `f`). Kotlin requires the provided args to
    // be a prefix, so defaults fill the suffix and stay index-aligned.
    // A named entry argument binds its parameter (`B(b = 1, a = 0)`);
    // a positional one takes the next unfilled slot. Every slot up to
    // the last provided or defaulted parameter gets a thunk.
    // An enum without a primary constructor passes its entry
    // arguments to a secondary constructor: they stay positional.
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
        // The arguments sit in the enum's static scope: an entry name
        // or companion member is visible by its bare name (`FOO("O",
        // { FOO.x })`), so the thunks take the enum class as `this`.
        var enum_scope = StringSet.init(a);
        defer enum_scope.deinit();
        try ir.lower.decl.addVisibleMemberNames(c, &enum_scope);
        const enum_this = [_][]const u8{"this"};
        for (0..slot_count) |idx| {
            const nm = try std.fmt.allocPrint(a, "__enum_arg_{s}_{s}_{d}", .{ c.name.name, entry.name.name, idx });
            const arg_expr = slot_exprs[idx] orelse &c.primary_params[idx].default.?;
            fids[idx] = try ir.lower.lowerExprAsParamThunkScoped(module, &enum_this, arg_expr, nm, c.name.name, &enum_scope);
        }
        try enum_entry_arg_inits.append(a, .{ .class_name = c.name.name, .entry_name = entry.name.name, .funcs = fids });
    }
}

/// Bind each entry argument to its constructor slot: a named argument to
/// the parameter it names, a positional one to the next unfilled slot.
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

/// Backpatch every new class def's runtime parent and interface slots,
/// then fill the nested-class tables.
fn linkRuntimeSupertypes(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const decls = ctx.decls;
    const classes = &ctx.classes;
    const new_defs = &ctx.new_defs;
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
        // Nested-class tables: a class's `nested_classes` names every class
        // / object / interface declared in its body, resolved to the runtime
        // defs registered above. The image loader restores this table for
        // baked classes; a freshly built program must fill it the same way,
        // or a reified `typeOf<Nested>()` inside the outer class cannot
        // reach the nested def.
        try fillNestedClassTables(a, decls, classes, "");
    }
}

/// Lower each class's parent-constructor argument thunks.
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
    // Parent-ctor argument thunks.
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
}

/// Lower each class's `init { … }` blocks as thunks over `this` and the
/// constructor parameters.
fn lowerInitBlockThunks(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const file_classes = &ctx.file_classes;
    const init_blocks = &ctx.init_blocks;
    // Init blocks as 1-arg thunks taking `this` plus ctor params.
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
            for (c.supertypes) |*st| try collectHierarchyMemberNames(st.name.name, file_classes, &own_members, &seen_sup);
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
        // The same typed signature the body-property thunks compile against:
        // an init block reads the constructor's parameters, and a consumer
        // reading `Func.params` has nowhere else to learn their types.
        const ib_cid = module.classIdByFqn(try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name));
        const ib_param_types: []const ir.Param = if (ib_cid) |cid|
            module.classes.items[cid.int()].primary_params
        else
            &.{};
        for (c.init_blocks, 0..) |*blk, idx| {
            const nm = try std.fmt.allocPrint(a, "__init_block_{s}_{d}", .{ c.name.name, idx });
            module.pending_param_types = ib_types;
            fids[idx] = try ir.lower.lowerInitBlockWithParams(module, c.name.name, &own_members, local_params.items, ib_param_types, blk, nm);
        }
        try init_blocks.put(c.name.name, fids);
        const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
        if (!std.mem.eql(u8, cfqn, c.name.name)) try init_blocks.put(cfqn, fids);
    }
}

/// Lower each class's supertype delegation expressions.
fn lowerClassDelegateThunks(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const decl_pkg = ctx.decl_pkg;
    const package_prefix = ctx.package_prefix;
    const class_delegates = &ctx.class_delegates;
    // Per-class delegation expressions.
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
}

/// Lower every class's secondary constructors.
fn lowerSecondaryCtors(ctx: *BuildCtx) Allocator.Error!void {
    const decls = ctx.decls;
    // Per-class secondary-ctor lowering.
    for (decls) |*d| {
        if (d.* != .Class) continue;
        const c = &d.Class;
        if (c.secondary_ctors.len == 0) continue;
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
    // Inherited companion members: a delegation/default thunk references a
    // superclass companion's constant/function by its bare name (`MinId`
    // inside `Rgb`, from `ColorSpace.Companion`), and has no `this` to walk
    // at runtime — resolve it statically as a companion access.
    {
        var seen_sup = StringSet.init(a);
        defer seen_sup.deinit();
        for (c.supertypes) |*st| try collectHierarchyCompanionMemberNames(st.name.name, file_classes, &own_members, &seen_sup);
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
        entries[sc_idx] = try lowerSecondaryCtor(ctx, c, sc, sc_idx, &own_members, &own_arity);
    }
    try secondary_ctors.put(c.name.name, entries);
    const cfqn = try resolveFqn(a, fqn_overrides, c.span, package_prefix, c.name.name);
    if (!std.mem.eql(u8, cfqn, c.name.name)) try secondary_ctors.put(cfqn, entries);
}

/// Lower one secondary constructor: its parameter metadata, delegation
/// argument thunks, parameter defaults and body.
fn lowerSecondaryCtor(
    ctx: *BuildCtx,
    c: *ast.Class,
    sc: *ast.SecondaryCtor,
    sc_idx: usize,
    own_members: *StringSet,
    own_arity: *std.StringHashMap(u64),
) Allocator.Error!SecondaryCtorEntry {
    const a = ctx.a;
    const module = ctx.module;
    const nested_outer_members = &ctx.nested_outer_members;
    // The entry outlives the declaration's AST (a pack's sources are
    // released once their bindings are extracted), so its strings are
    // the module's own copies, never slices into the parse.
    var param_names = try a.alloc([]const u8, sc.params.len);
    for (sc.params, 0..) |*p, i| param_names[i] = try a.dupe(u8, p.name.name);
    var param_type_heads = try a.alloc([]const u8, sc.params.len);
    for (sc.params, 0..) |*p, i| {
        // A function-typed parameter's name field is empty; record
        // the arity-tagged head (`FunctionN`) so ctor overload
        // selection can prefer this slot for a lambda argument over
        // a same-arity sibling's SAM-class slot.
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
    // The delegation arguments and the defaults are expressions over
    // the secondary constructor's OWN parameters, so they lower with
    // the declared types those parameters carry.
    const sc_param_types = try a.alloc(?ast.TypeRef, sc.params.len);
    for (sc.params, 0..) |*p, i| sc_param_types[i] = p.ty;
    // An inner class's thunks take the enclosing instance as a
    // leading receiver slot, like its primary constructor's default
    // thunks; any other class's thunks see only the parameters, so a
    // companion member named in a delegation stays a static call.
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
    // Named delegation arguments (`this(message = m, cause = c,
    // missingFields = f, serialName = null)`) bind the target's
    // parameters by NAME; the thunks run in the target's declared
    const order = try secondaryCtorDelegationOrder(a, c, sc, delegation_args, is_this);
    // An inner class's delegation arguments and defaults see the
    // enclosing instance's members the way its primary defaults do
    // (`constructor() : super({ ok })` reads `this@Outer.ok`).
    const sc_enclosing: ?*const StringSet = nested_outer_members.getPtr(c.name.name);
    var arg_fids = try a.alloc(FuncId, delegation_args.len);
    for (order, 0..) |src_idx, arg_idx| {
        const e = &delegation_args[src_idx];
        const nm = try std.fmt.allocPrint(a, "__sec_ctor_{s}_{d}_arg{d}", .{ c.name.name, sc_idx, arg_idx });
        module.pending_param_types = sc_thunk_types;
        module.pending_own_member_arity = own_arity;
        arg_fids[arg_idx] = try ir.lower.lowerExprAsParamThunkScopedEnclosing(module, sc_thunk_params, e, nm, c.name.name, own_members, sc_enclosing);
    }
    var default_arg_thunks = try a.alloc(?FuncId, sc.params.len);
    for (sc.params, 0..) |*p, p_idx| {
        if (p.default) |e| {
            const nm = try std.fmt.allocPrint(a, "__sec_ctor_{s}_{d}_def{d}", .{ c.name.name, sc_idx, p_idx });
            module.pending_param_types = sc_thunk_types;
            module.pending_own_member_arity = own_arity;
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

/// The order a `this(...)` delegation's arguments bind the target's
/// parameters in: named arguments take the parameter they name, and only
/// a call that fills every primary parameter is reordered.
fn secondaryCtorDelegationOrder(
    a: Allocator,
    c: *const ast.Class,
    sc: *const ast.SecondaryCtor,
    delegation_args: []const ast.Expr,
    is_this: bool,
) Allocator.Error![]usize {
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
    // Top-level property initialisers — const first, then the rest.
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
}

/// Lower the remaining top-level property initialisers, delegates and
/// accessors.
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
            const fid = try ir.lower.lowerDelegateExprAsThunk(module, delegate, nm, p.name.name);
            try top_level_props.append(a, .{ .name = p.name.name, .func = fid, .file = p.span.file.int() });
        } else if (p.is_lateinit) {
            try module.registry.top_level_lateinit_props.put(p.name.name, {});
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
}

/// Lower every extension property: file-level, and the member extensions
/// a class or object owns.
fn lowerExtensionProps(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const decls = ctx.decls;
    const fqn_overrides = ctx.fqn_overrides;
    const package_prefix = ctx.package_prefix;
    // Top-level + companion/object extension properties.
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
        try lowerExtensionProp(ctx, epd, &class_aliases);
    }
}

/// Lower one extension property's accessors under the receiver key its
/// declaration resolves to.
fn lowerExtensionProp(ctx: *BuildCtx, epd: ExtPropDecl, class_aliases: *const std.StringHashMap([]const u8)) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decl_pkg = ctx.decl_pkg;
    const extension_prop_delegates = &ctx.extension_prop_delegates;
    const func_fqn_overrides = ctx.func_fqn_overrides;
    const package_prefix = ctx.package_prefix;
    const p = epd.p;
    const recv = p.receiver_type orelse return;
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
    // A function-type receiver (`val (Int.() -> String).twice`) is keyed
    // under `Function`, the runtime name of every callable value, so the
    // walk from a closure receiver finds it.
    if (recv.function != null) recv_name = "Function";
    const recv_key: []const u8 = if (recv.qualified_path) |qp|
        (if (std.mem.endsWith(u8, qp, ".Companion")) qp else recv_name)
    else
        recv_name;
    const ep_pkg = try declPackage(a, decl_pkg, func_fqn_overrides, p.span, package_prefix, p.name.name);

    const prev_ep_pkg = ir.lower.decl.setLowerSelfPackage(ep_pkg);
    defer _ = ir.lower.decl.setLowerSelfPackage(prev_ep_pkg);
    // The accessor's receiver answers to `this@<prop>`, and a local
    // class declared in the body reaches the declaring class as
    // `this@<Owner>`.
    const dispatch_owner: ?[]const u8 = if (epd.owner) |o|
        (if (std.mem.findScalarLast(u8, o, '.')) |dot| o[dot + 1 ..] else o)
    else
        null;
    if (p.getter) |getter| {
        try lowerExtensionPropGetter(ctx, epd, p, getter, recv, recv_name, recv_key, ep_pkg, dispatch_owner);
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
        try lowerExtensionPropSetter(ctx, epd, p, setter, recv_name, recv_key, dispatch_owner);
    }
}

/// Lower an extension property's getter and register every key it
/// dispatches under.
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

/// Lower an extension property's setter and register every key it
/// dispatches under.
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

// -------------------------------------------------------------------------
// Finalisation: the cross-declaration links runtime dispatch reads.
// -------------------------------------------------------------------------

/// Fold the local-fn default thunks into `func_defaults`, then propagate
/// supertype member defaults onto the overrides that lack their own.
fn settleDefaultArgThunks(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const func_defaults = &ctx.func_defaults;
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
    try propagateInheritedDefaults(a, module, func_defaults);
}

/// Map every typealias name to its target's head tag.
fn registerTypeAliasTags(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    const decls = ctx.decls;
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
        const target = if (std.mem.findScalarLast(u8, full, '.')) |dot| full[dot + 1 ..] else full;
        if (target.len != 0 and !std.mem.eql(u8, target, ta.name.name)) {
            try module.registry.type_aliases.put(ta.name.name, target);
        }
    }
}

/// Rewrite the function-type and scalar alias names in this build's
/// lowered parameter types, so applicability and scoring see the target.
fn rewriteAliasedParamTypes(ctx: *BuildCtx) Allocator.Error!void {
    const module = ctx.module;
    const base_funcs_len = ctx.base_funcs_len;
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
            } else if (@import("../vm/overload_match.zig").builtinParamKind(resolved) != null) {
                p.ty.name = resolved;
            }
        }
    }
}

/// Materialise the module-scoped registry the Vm reads at dispatch time.
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
}

/// Settle the name index, the virtual override families, and the
/// debug-only frame-dump hook.
fn finishModule(ctx: *BuildCtx) Allocator.Error!void {
    const a = ctx.a;
    const module = ctx.module;
    // Rebuild the name index so funcId lookups see every registered stub.
    try module.rebuildFuncNameIndex(a);

    // Settle virtual override families after every class/member header is
    // complete. Runtime member dispatch can then use only class + slot ids.
    try module.linkMethodSlots(a);

    // Debug-only frame-dump hook for intrinsics below the ir layer.
    ir.eval.installDebugFrameDump();
}
