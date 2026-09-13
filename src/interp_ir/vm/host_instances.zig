//! `VmHost` instance construction: allocating a `Value.Instance` for a
//! `ClassId` (running primary/secondary ctors, init blocks, body-property
//! init, delegation), building anonymous-object instances, and selecting
//! the outer instance an inner-class instance captures.
//!
//! Free functions over `*VmHost`, aliased as `VmHost` methods by
//! `vmhost.zig` and invoked directly by the generic IR evaluator.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const stdlib = @import("stdlib");

const root = @import("../interp_ir.zig");
const vmhost = @import("vmhost.zig");
const host_globals = @import("host_globals.zig");
const host_classes = @import("host_classes.zig");
const host_call_func = @import("host_call_func.zig");
const host_call_member = @import("host_call_member.zig");
const host_fields = @import("host_fields.zig");
const host_call_value = @import("host_call_value.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const build = @import("../build.zig");
const FF = runtime.forest.ForestField;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const ClassDef = runtime.ClassDef;
const Env = runtime.Env;
const PropertyDef = runtime.PropertyDef;
const MethodDef = runtime.MethodDef;
const SupertypeDelegate = runtime.SupertypeDelegate;
const TypeShape = runtime.TypeShape;
const StdlibFn = runtime.StdlibFn;
const CallCtx = runtime.CallCtx;
const Module = ir.Module;
const ClassId = ir.ClassId;
const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;
const EvalResult = ir.eval.EvalResult;
const EvalError = ir.eval.EvalError;
const StrPair = ir.StrPair;
const StringSet = std.StringHashMap(void);
const AnonMethodEntry = root.AnonMethodEntry;
const NameValue = root.NameValue;

// -------------------------------------------------------------------------
// Instance construction is split across `host_instances/`; each import below
// is followed by the aliases that keep every call site addressing this file.
// -------------------------------------------------------------------------

const common = @import("host_instances/common.zig");
const unsupported = common.unsupported;
const typeErr = common.typeErr;
pub const EnumEntryPreset = common.EnumEntryPreset;
pub const setEnumUnderInit = common.setEnumUnderInit;
pub const setEnumEntryPreset = common.setEnumEntryPreset;
pub const resetReceiverTls = common.resetReceiverTls;
pub const ctorGuardContains = common.ctorGuardContains;
const ctorGuardPush = common.ctorGuardPush;
const ctorGuardPop = common.ctorGuardPop;
const CTOR_HEADS_MAX = common.CTOR_HEADS_MAX;
pub const setCtorArgStaticHeads = common.setCtorArgStaticHeads;
pub const clearCtorArgStaticHeads = common.clearCtorArgStaticHeads;
const CtorBounds = common.CtorBounds;
const installCtorBounds = common.installCtorBounds;
const boundHead = common.boundHead;
const takeCtorStaticHeads = common.takeCtorStaticHeads;
const anonSiteName = common.anonSiteName;
const AnonComplexInit = common.AnonComplexInit;
const AnonInitThunk = common.AnonInitThunk;
const AnonSuperArgThunk = common.AnonSuperArgThunk;
const AnonDelegateThunk = common.AnonDelegateThunk;
const AnonSiteThunks = common.AnonSiteThunks;
const gcMarkAnonSites = common.gcMarkAnonSites;
const anonSiteThunksGet = common.anonSiteThunksGet;
pub const resetAnonSiteCache = common.resetAnonSiteCache;
const anonSiteThunksPut = common.anonSiteThunksPut;
pub const anonLowerEnter = common.anonLowerEnter;
pub const anonLowerExit = common.anonLowerExit;
pub const anonSiteModule = common.anonSiteModule;

const ctor_select = @import("host_instances/ctor_select.zig");
const classDefByName = ctor_select.classDefByName;
const classDefByQualifiedSuffix = ctor_select.classDefByQualifiedSuffix;
const sideTableKey = ctor_select.sideTableKey;
const secondaryCtors = ctor_select.secondaryCtors;
pub const classSecondaryCtorCanBind = ctor_select.classSecondaryCtorCanBind;
const valueTypeHead = ctor_select.valueTypeHead;
const headInSet = ctor_select.headInSet;
const integral_heads = ctor_select.integral_heads;
const collectionish_heads = ctor_select.collectionish_heads;
const paramAcceptsArg = ctor_select.paramAcceptsArg;
const builtinTypeKind = ctor_select.builtinTypeKind;
const scoreCtorHeads = ctor_select.scoreCtorHeads;
const isCallableArg = ctor_select.isCallableArg;
const chooseSecondaryCtor = ctor_select.chooseSecondaryCtor;
const chooseSecondaryCtorDefaulted = ctor_select.chooseSecondaryCtorDefaulted;
const chooseSecondaryCtorArity = ctor_select.chooseSecondaryCtorArity;
const DeferredCtorBody = ctor_select.DeferredCtorBody;
const chooseOrdinarySecondaryCtor = ctor_select.chooseOrdinarySecondaryCtor;
const scoreCtorHeadsWidening = ctor_select.scoreCtorHeadsWidening;
const expandParentSecondaryThisArgs = ctor_select.expandParentSecondaryThisArgs;
const parentCtorArgThunks = ctor_select.parentCtorArgThunks;
const parentCtorArgNames = ctor_select.parentCtorArgNames;
const paramIndexByName = ctor_select.paramIndexByName;
const ctorThunkThisSlot = ctor_select.ctorThunkThisSlot;
const ctorThunkArgs = ctor_select.ctorThunkArgs;
const primaryDefaultThunks = ctor_select.primaryDefaultThunks;
const classDelegateThunks = ctor_select.classDelegateThunks;
const trivialInitServe = ctor_select.trivialInitServe;
const bodyPropInit = ctor_select.bodyPropInit;
const appendPrimaryCtorPropertyFields = ctor_select.appendPrimaryCtorPropertyFields;
const adoptDeclaredNumeric = ctor_select.adoptDeclaredNumeric;
const scalarRetagName = ctor_select.scalarRetagName;
const typeHeadOfName = ctor_select.typeHeadOfName;
const scalarRetag = ctor_select.scalarRetag;
pub const mintInstanceId = ctor_select.mintInstanceId;
const nextInstanceId = ctor_select.nextInstanceId;
const funcAt = ctor_select.funcAt;
const shadowFieldKey = ctor_select.shadowFieldKey;
const isPrivateShadowProp = ctor_select.isPrivateShadowProp;
const evalThunk = ctor_select.evalThunk;
pub const initLocalParentChain = ctor_select.initLocalParentChain;
const evalParentCtorThunk = ctor_select.evalParentCtorThunk;

const ctor_defaults = @import("host_instances/ctor_defaults.zig");
const simpleLiteral = ctor_defaults.simpleLiteral;
const emptyList = ctor_defaults.emptyList;
const emptySet = ctor_defaults.emptySet;
const emptyMap = ctor_defaults.emptyMap;
const defaultValueForPrimary = ctor_defaults.defaultValueForPrimary;
const pathConstDefault = ctor_defaults.pathConstDefault;
const primaryVarargParam = ctor_defaults.primaryVarargParam;
const primaryCanTake = ctor_defaults.primaryCanTake;
const scoreCtorHeadsVararg = ctor_defaults.scoreCtorHeadsVararg;
const packSecondaryVarargs = ctor_defaults.packSecondaryVarargs;
const packPrimaryCtorVarargs = ctor_defaults.packPrimaryCtorVarargs;

const super_chain = @import("host_instances/super_chain.zig");
const lookupIntrinsic = super_chain.lookupIntrinsic;
const dispatchIntrinsic = super_chain.dispatchIntrinsic;
const isBuiltinThrowableName = super_chain.isBuiltinThrowableName;
const hasNonNullField = super_chain.hasNonNullField;
const retainField = super_chain.retainField;
const pushField = super_chain.pushField;
const bindThrowableArgs = super_chain.bindThrowableArgs;
const UnitOrErr = super_chain.UnitOrErr;
const runSuperCtorChain = super_chain.runSuperCtorChain;
const ChainEntry = super_chain.ChainEntry;
const extendAnonymousParentCtorArgs = super_chain.extendAnonymousParentCtorArgs;
const chainEntryIs = super_chain.chainEntryIs;
const classDefForSuper = super_chain.classDefForSuper;
const SuperRef = super_chain.SuperRef;
const firstNonInterfaceSuper = super_chain.firstNonInterfaceSuper;
const runInitBlocksAt = super_chain.runInitBlocksAt;
pub const runAnonInitBlocksAt = super_chain.runAnonInitBlocksAt;

const new_instance = @import("host_instances/new_instance.zig");
pub const newInstanceNamed = new_instance.newInstanceNamed;
const findNamedFactory = new_instance.findNamedFactory;
const isIntrinsicClass = new_instance.isIntrinsicClass;
pub const newInstance = new_instance.newInstance;

const ctor_path = @import("host_instances/ctor_path.zig");
const classDefName = ctor_path.classDefName;
const classDefFqn = ctor_path.classDefFqn;
const classDefIsAbstract = ctor_path.classDefIsAbstract;
const classDefIsInterface = ctor_path.classDefIsInterface;
const classDefIsObject = ctor_path.classDefIsObject;
const classDefIsInner = ctor_path.classDefIsInner;
pub const samWrapForParamType = ctor_path.samWrapForParamType;
pub const paramTypeIsFunInterface = ctor_path.paramTypeIsFunInterface;
const classDefIsFunInterface = ctor_path.classDefIsFunInterface;
const classDefPrimaryParamCount = ctor_path.classDefPrimaryParamCount;
const throwInstantiation = ctor_path.throwInstantiation;
const interfaceConstruct = ctor_path.interfaceConstruct;
const isAllUpper = ctor_path.isAllUpper;
const funcParamHasDefault = ctor_path.funcParamHasDefault;
const dispatchSecondaryCtor = ctor_path.dispatchSecondaryCtor;
const superDelegation = ctor_path.superDelegation;
const isBuiltinThrowableNameNoCancel = ctor_path.isBuiltinThrowableNameNoCancel;
const primaryCtorPath = ctor_path.primaryCtorPath;
const reorderNamedSuperArgs = ctor_path.reorderNamedSuperArgs;
const padParentCtorDefaults = ctor_path.padParentCtorDefaults;
const companionInvoke = ctor_path.companionInvoke;
const pickFactory = ctor_path.pickFactory;
const enclosingClassNameOf = ctor_path.enclosingClassNameOf;
const instanceOfClassName = ctor_path.instanceOfClassName;
const classDefImplements = ctor_path.classDefImplements;
const instanceOuterOf = ctor_path.instanceOuterOf;
const outerWalkMatch = ctor_path.outerWalkMatch;
const selectInnerOuter = ctor_path.selectInnerOuter;

const materialize = @import("host_instances/materialize.zig");
const BuiltinBase = materialize.BuiltinBase;
const BuiltinBaseName = materialize.BuiltinBaseName;
const builtinCollectionBase = materialize.builtinCollectionBase;
const buildBuiltinBase = materialize.buildBuiltinBase;
const materializeInstance = materialize.materializeInstance;
const maybeProvideDelegate = materialize.maybeProvideDelegate;
const retainFieldList = materialize.retainFieldList;
const isThrowableDirectName = materialize.isThrowableDirectName;
const isThrowableChainName = materialize.isThrowableChainName;

const build_object = @import("host_instances/build_object.zig");
const anonKey = build_object.anonKey;
const buildCapturePairs = build_object.buildCapturePairs;
const findCapture = build_object.findCapture;
const snapshotCapture = build_object.snapshotCapture;
const bareCaptureResolvable = build_object.bareCaptureResolvable;
const capturedDelegateOf = build_object.capturedDelegateOf;
pub const synthSetterThunk = build_object.synthSetterThunk;
pub const synthThunk = build_object.synthThunk;
const inheritAnonTypeParams = build_object.inheritAnonTypeParams;
pub const buildObject = build_object.buildObject;
const runAnonThunk = build_object.runAnonThunk;
const evalSuperArg = build_object.evalSuperArg;

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    inline for (.{ common, ctor_select, ctor_defaults, super_chain, new_instance, ctor_path, materialize, build_object }) |m| testing.refAllDecls(m);
}

test "isIntrinsicClass / isBuiltinThrowableName classification" {
    try testing.expect(isIntrinsicClass("kotlin.text.StringBuilder"));
    try testing.expect(isIntrinsicClass("kotlin.Array"));
    try testing.expect(!isIntrinsicClass("com.example.Widget"));
    try testing.expect(isBuiltinThrowableName("CancellationException"));
    try testing.expect(isBuiltinThrowableNameNoCancel("IOException"));
    try testing.expect(!isBuiltinThrowableNameNoCancel("CancellationException"));
}

test "simpleLiteral resolves literal expr forms" {
    const a = testing.allocator;
    const span = @import("span");
    const f = span.FileId.from(0);
    const s = span.Span.init(f, 0, 1);
    var int_expr = ast.Expr{ .IntLit = .{ .value = 7, .kind = .Int, .span = s } };
    const iv = (try simpleLiteral(a, &int_expr)).?;
    try testing.expectEqual(@as(i64, 7), iv.asI64().?);
    var bool_expr = ast.Expr{ .BoolLit = .{ .value = true, .span = s } };
    const bv = (try simpleLiteral(a, &bool_expr)).?;
    try testing.expect(bv.Bool);
    var null_expr = ast.Expr{ .NullLit = .{ .span = s } };
    const nv = (try simpleLiteral(a, &null_expr)).?;
    try testing.expect(nv == .Null);
}

test "ctor guard stack push/contains/pop" {
    try testing.expect(!ctorGuardContains("Foo"));
    ctorGuardPush("Foo");
    try testing.expect(ctorGuardContains("Foo"));
    ctorGuardPop();
    try testing.expect(!ctorGuardContains("Foo"));
}
