//! Front-end-to-IR module builder: a parsed Kotlin file becomes an `ir.Module`
//! ready for `Vm.run`, with the synthesised runtime `ClassDef` table and the side
//! tables the Vm consults at dispatch time. Phase order is load-bearing: classes
//! lower first so `Inst.NewInstance` lookups resolve, then a pre-pass registers a
//! stub Func per top-level function so forward references and mutual recursion
//! lower cleanly, then each body lowers into its reserved slot.

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

// The builder is split across `build/`; every declaration keeps its name and
// visibility here so call sites read `build.<name>` unchanged.

const build_types = @import("build/types.zig");
pub const StrPair = build_types.StrPair;
pub const StrPairContext = build_types.StrPairContext;
pub const PairFuncMap = build_types.PairFuncMap;
pub const StrPairSet = build_types.StrPairSet;
pub const ClassTable = build_types.ClassTable;
pub const StrFunc = build_types.StrFunc;
pub const TypedDefault = build_types.TypedDefault;
pub const NameFunc = build_types.NameFunc;
pub const EnumEntryArgInit = build_types.EnumEntryArgInit;
pub const EnumEntryMethod = build_types.EnumEntryMethod;
pub const SecondaryCtorEntry = build_types.SecondaryCtorEntry;
pub const BuiltModule = build_types.BuiltModule;
pub const PairStrMap = build_types.PairStrMap;
pub const emptyBuiltShell = build_types.emptyBuiltShell;
const emptyBuilt = build_types.emptyBuilt;
const Span = build_types.Span;
const SpanContext = build_types.SpanContext;
const SpanStrMap = build_types.SpanStrMap;
const FileClasses = build_types.FileClasses;

const build_scan = @import("build/scan.zig");
const boundTypeRecordComplete = build_scan.boundTypeRecordComplete;
const collectClassTypeParamBounds = build_scan.collectClassTypeParamBounds;
pub const classTypeParamBoundHeads = build_scan.classTypeParamBoundHeads;
const simpleTypeHead = build_scan.simpleTypeHead;
pub const typedDefaultFor = build_scan.typedDefaultFor;
pub const typedDefaultForInit = build_scan.typedDefaultForInit;
const packagePrefix = build_scan.packagePrefix;
const joinIdents = build_scan.joinIdents;
const collectClassifierFqns = build_scan.collectClassifierFqns;
const collectDeclPkgs = build_scan.collectDeclPkgs;
const noteExtPropTypeHead = build_scan.noteExtPropTypeHead;
const notePropScope = build_scan.notePropScope;
const memberSizedInitHead = build_scan.memberSizedInitHead;
const promoteConstHeads = build_scan.promoteConstHeads;
const constExprTypeHead = build_scan.constExprTypeHead;
const literalTypeHead = build_scan.literalTypeHead;
const initCalleeName = build_scan.initCalleeName;
const constLiteralOf = build_scan.constLiteralOf;
const ownerSimplePath = build_scan.ownerSimplePath;
const declPackage = build_scan.declPackage;
const resolveFqn = build_scan.resolveFqn;
const packageOfFqn = build_scan.packageOfFqn;
const collectClassMemberNamesInto = build_scan.collectClassMemberNamesInto;
const collectHierarchyMethodNames = build_scan.collectHierarchyMethodNames;
const memberTrailingLambdaShape = build_scan.memberTrailingLambdaShape;
const collectMemberTrailingLambdaShapes = build_scan.collectMemberTrailingLambdaShapes;
const collectHierarchyShadowNames = build_scan.collectHierarchyShadowNames;
const propHeadSourceExpr = build_scan.propHeadSourceExpr;
const propCtorHeadEvidence = build_scan.propCtorHeadEvidence;
const varargPropArrayHead = build_scan.varargPropArrayHead;
const declFqnAt = build_scan.declFqnAt;
const putClassPropHead = build_scan.putClassPropHead;
const notePropTypeRef = build_scan.notePropTypeRef;
const classPropHead = build_scan.classPropHead;
const collectHierarchySuperNames = build_scan.collectHierarchySuperNames;
const collectHierarchyMemberNames = build_scan.collectHierarchyMemberNames;
const collectHierarchyCompanionMemberNames = build_scan.collectHierarchyCompanionMemberNames;
const literalToConst = build_scan.literalToConst;
pub const scalarNonNullProp = build_scan.scalarNonNullProp;
pub const primitiveZeroFor = build_scan.primitiveZeroFor;
const zeroForScalarName = build_scan.zeroForScalarName;

const build_module = @import("build/module.zig");
pub const buildModule = build_module.buildModule;
pub const buildModuleFiles = build_module.buildModuleFiles;
pub const buildModuleFilesExtend = build_module.buildModuleFilesExtend;
const collectUserComposableFiles = build_module.collectUserComposableFiles;
const buildModuleFilesInner = build_module.buildModuleFilesInner;

const build_overrides = @import("build/overrides.zig");
const buildModuleWithOverrides = build_overrides.buildModuleWithOverrides;

const build_classes = @import("build/classes.zig");
const replaceDotWithDollar = build_classes.replaceDotWithDollar;
const resolveMangled = build_classes.resolveMangled;
const collectConsts = build_classes.collectConsts;
const registerMemberPropAsts = build_classes.registerMemberPropAsts;
const nestedQualified = build_classes.nestedQualified;
const registerClassSupertypes = build_classes.registerClassSupertypes;
const registerInlineMemberOwners = build_classes.registerInlineMemberOwners;
pub const collectInline = build_classes.collectInline;
const collectCompanionOwnMembers = build_classes.collectCompanionOwnMembers;
const annotationTargetEntries = build_classes.annotationTargetEntries;
const serializerForClassAnnotated = build_classes.serializerForClassAnnotated;
const annotationRecordFor = build_classes.annotationRecordFor;
const buildPropertyAnchors = build_classes.buildPropertyAnchors;
const inferredPropTypeHead = build_classes.inferredPropTypeHead;
const memberHasBackingField = build_classes.memberHasBackingField;
const spanNamesObject = build_classes.spanNamesObject;
const fillNestedClassTables = build_classes.fillNestedClassTables;
const buildClassDef = build_classes.buildClassDef;
const propagateInheritedDefaults = build_classes.propagateInheritedDefaults;
const slotsEql = build_classes.slotsEql;
const retainDecl = build_classes.retainDecl;
const sameExpectActualTypeHead = build_classes.sameExpectActualTypeHead;
const transplantExpectMemberDefaults = build_classes.transplantExpectMemberDefaults;

const build_base = @import("build/base.zig");
pub const StdlibBase = build_base.StdlibBase;
pub const buildStdlibBase = build_base.buildStdlibBase;
const parentCtorParamExpected = build_base.parentCtorParamExpected;
const irTypeToAstInstantiated = build_base.irTypeToAstInstantiated;
pub const buildProgramBase = build_base.buildProgramBase;
const buildBaseInner = build_base.buildBaseInner;
const composeBaseDecls = build_base.composeBaseDecls;
const composeBaseNames = build_base.composeBaseNames;
const composeBaseNameDecl = build_base.composeBaseNameDecl;
const composeBaseSinks = build_base.composeBaseSinks;
const composeBaseInlineFns = build_base.composeBaseInlineFns;
const composeBaseComposableGetterProps = build_base.composeBaseComposableGetterProps;
const composeBaseFactoryDecl = build_base.composeBaseFactoryDecl;
const composeBaseSinkDecl = build_base.composeBaseSinkDecl;
const noteBaseDeclNames = build_base.noteBaseDeclNames;
pub const canExtendBase = build_base.canExtendBase;
const extendRefused = build_base.extendRefused;

const build_clone = @import("build/clone.zig");
const cloneBuiltForRun = build_clone.cloneBuiltForRun;
const copyPairMap = build_clone.copyPairMap;
const copyStrMap = build_clone.copyStrMap;
const classTableByQualifiedSuffix = build_clone.classTableByQualifiedSuffix;
const cloneClassTableForRun = build_clone.cloneClassTableForRun;
const cloneBuildValue = build_clone.cloneBuildValue;


const testing = std.testing;

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(@import("build/base.zig"));
    testing.refAllDecls(@import("build/classes.zig"));
    testing.refAllDecls(@import("build/clone.zig"));
    testing.refAllDecls(@import("build/lift.zig"));
    testing.refAllDecls(@import("build/module.zig"));
    testing.refAllDecls(@import("build/overrides.zig"));
    testing.refAllDecls(@import("build/scan.zig"));
    testing.refAllDecls(@import("build/types.zig"));
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
    // The driver allocates many transient lowering tables from the build allocator;
    // an arena frees them at once, matching the CLI's per-run gpa.
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
