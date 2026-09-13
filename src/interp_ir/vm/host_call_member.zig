//! `VmHost` member dispatch: a named member on a receiver (instance, class or
//! builtin), member references, `super.foo(...)`, `this@Outer`, the
//! enclosing-`this` chain, and the member-only probe Kotlin's
//! member-before-extension rule needs. Aliased as `VmHost` methods by
//! `vmhost.zig`.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const applicability = @import("applicability");

const vmhost = @import("vmhost.zig");
const host_classes = @import("host_classes.zig");
const ClassTable = @import("../build.zig").ClassTable;
const host_globals = @import("host_globals.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;
const trace = @import("trace.zig");
const persistent_map_eq = @import("persistent_map_eq.zig");
const persistent_list_eq = @import("persistent_list_eq.zig");
const persistent_list_mut = @import("persistent_list_mut.zig");
const persistent_map_mut = @import("persistent_map_mut.zig");
const overload_match = @import("overload_match.zig");
const host_call_func = @import("host_call_func.zig");
const host_call_value = @import("host_call_value.zig");
const host_fields = @import("host_fields.zig");
const compose = @import("compose.zig");
const builtin_members = @import("builtin_members.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const StringRef = runtime.StringRef;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const MapPair = runtime.MapPair;
const RangeKind = runtime.RangeKind;
const DelegateKind = runtime.DelegateKind;
const SeqOp = runtime.SeqOp;
const SequenceData = runtime.SequenceData;
const ComparatorStep = runtime.ComparatorStep;
const RuntimeError = runtime.RuntimeError;
const StdlibFn = runtime.StdlibFn;
const CallCtx = runtime.CallCtx;

const Module = ir.Module;
const Func = ir.Func;
const FuncId = ir.FuncId;
const MethodSlotId = ir.MethodSlotId;
const TypeRef = ir.TypeRef;
const EvalResult = ir.eval.EvalResult;
const EvalError = ir.eval.EvalError;

const Ordering = builtin_members.Ordering;
const arrayShapeOps = builtin_members.arrayShapeOps;
const builtinIterator = builtin_members.builtinIterator;
const captureModCount = builtin_members.captureModCount;
const collectionMutators = builtin_members.collectionMutators;
pub const collectionsEqualHostAware = builtin_members.collectionsEqualHostAware;
const comparatorMember = builtin_members.comparatorMember;
const compareValuesBuiltin = builtin_members.compareValuesBuiltin;
const componentMembers = builtin_members.componentMembers;
const dataClassAutoMembers = builtin_members.dataClassAutoMembers;
const dataValueInstanceEquals = builtin_members.dataValueInstanceEquals;
const annotationInstanceEquals = builtin_members.annotationInstanceEquals;
pub const deepValueEquals = builtin_members.deepValueEquals;
const drainIterableToList = builtin_members.drainIterableToList;
const hashWithDispatch = builtin_members.hashWithDispatch;
const isSequenceTerminal = builtin_members.isSequenceTerminal;
const iteratorMember = builtin_members.iteratorMember;
pub const kotlinHashCode = builtin_members.kotlinHashCode;
const mapContainsKeyEq = builtin_members.mapContainsKeyEq;
const materialiseRangeItems = builtin_members.materialiseRangeItems;
const materializeUserMap = builtin_members.materializeUserMap;
const rangeIterMember = builtin_members.rangeIterMember;
const seqIterMember = builtin_members.seqIterMember;
const sequenceMember = builtin_members.sequenceMember;
const sortedInstances = builtin_members.sortedInstances;
const valueStructuralHash = builtin_members.valueStructuralHash;

const receiver_probe = @import("host_call_member/receiver_probe.zig");
const isCallable = receiver_probe.isCallable;
const isFunctionTypeRef = receiver_probe.isFunctionTypeRef;
const resolveAliasName = receiver_probe.resolveAliasName;
const isFunctionTypeRefResolved = receiver_probe.isFunctionTypeRefResolved;
const packVarargArgs = receiver_probe.packVarargArgs;
const memberIsProperty = receiver_probe.memberIsProperty;
const receiverCompatibleWithParam = receiver_probe.receiverCompatibleWithParam;
const allUppercase = receiver_probe.allUppercase;
const builtinKindMismatch = receiver_probe.builtinKindMismatch;
pub const inheritedMemberDefaults = receiver_probe.inheritedMemberDefaults;
const fakeOverrideInheritedDefault = receiver_probe.fakeOverrideInheritedDefault;
const enclosingCallableProperty = receiver_probe.enclosingCallableProperty;
const isTopOrGenericType = receiver_probe.isTopOrGenericType;
const extReceiverSpecificity = receiver_probe.extReceiverSpecificity;
const strictReceiverProven = receiver_probe.strictReceiverProven;
const strictReceiverProvenName = receiver_probe.strictReceiverProvenName;
const mangledNestedKey = receiver_probe.mangledNestedKey;
pub const classHeadsMatch = receiver_probe.classHeadsMatch;
const bareHead = receiver_probe.bareHead;
pub const mangledClassKeyOf = receiver_probe.mangledClassKeyOf;
const staticReceiverApplicable = receiver_probe.staticReceiverApplicable;
pub const resetStaticApplicabilityCache = receiver_probe.resetStaticApplicabilityCache;
const declArityRefuses = receiver_probe.declArityRefuses;
const extArityApplicable = receiver_probe.extArityApplicable;
const extArityApplicableTL = receiver_probe.extArityApplicableTL;
const receiverIsFunctionShaped = receiver_probe.receiverIsFunctionShaped;
const instanceHierarchyHasInvoke = receiver_probe.instanceHierarchyHasInvoke;
const valueNominalFqn = receiver_probe.valueNominalFqn;
const closureParamsDisproveFnParam = receiver_probe.closureParamsDisproveFnParam;
const fnTypeValueParams = receiver_probe.fnTypeValueParams;
const fnParamHead = receiver_probe.fnParamHead;
const scalarHeadOf = receiver_probe.scalarHeadOf;
const knownClassHead = receiver_probe.knownClassHead;
const candidateArgsDisproven = receiver_probe.candidateArgsDisproven;
const receiverViolatesTypeParamBound = receiver_probe.receiverViolatesTypeParamBound;
const typeParamOf = receiver_probe.typeParamOf;
const paramTypeIsTypeVar = receiver_probe.paramTypeIsTypeVar;
const fidTypeVar = receiver_probe.fidTypeVar;
const applicTypeVarCbM = receiver_probe.applicTypeVarCbM;
const elementsProveArgs = receiver_probe.elementsProveArgs;
const isListHead = receiver_probe.isListHead;
const isSetHead = receiver_probe.isSetHead;
const elementSatisfies = receiver_probe.elementSatisfies;
const headNamesRegisteredClass = receiver_probe.headNamesRegisteredClass;
pub const receiverImplementsHead = receiver_probe.receiverImplementsHead;
pub const receiverImplementsType = receiver_probe.receiverImplementsType;
const receiverImplementsOwnerIdentity = receiver_probe.receiverImplementsOwnerIdentity;

const member_presence = @import("host_call_member/member_presence.zig");
const NameIdSlot = member_presence.NameIdSlot;
pub const memberNameIdentity = member_presence.memberNameIdentity;
pub const hostHasMember = member_presence.hostHasMember;
const cmgGlobalKey = member_presence.cmgGlobalKey;
pub const cmgGlobalSkip = member_presence.cmgGlobalSkip;
pub const cmgGlobalRecord = member_presence.cmgGlobalRecord;
const hostHasMemberUncached = member_presence.hostHasMemberUncached;
pub const hostHasProperty = member_presence.hostHasProperty;
pub const companionWithMember = member_presence.companionWithMember;
const companionChainProbe = member_presence.companionChainProbe;
const companionChainBuild = member_presence.companionChainBuild;
const classIsObjectDecl = member_presence.classIsObjectDecl;
pub const enclosingThis = member_presence.enclosingThis;
pub const enclosingThisChain = member_presence.enclosingThisChain;
pub const pushAccessEnclosing = member_presence.pushAccessEnclosing;
pub const pushAccessEnclosingSubject = member_presence.pushAccessEnclosingSubject;
pub const popAccessEnclosing = member_presence.popAccessEnclosing;
pub const pushOuterThis = member_presence.pushOuterThis;
pub const pushOuterSubject = member_presence.pushOuterSubject;
pub const popOuterThis = member_presence.popOuterThis;

const applicability_probe = @import("host_call_member/applicability_probe.zig");
const invokeMemberExtFuncId = applicability_probe.invokeMemberExtFuncId;
const instanceFunctionDistance = applicability_probe.instanceFunctionDistance;
const instanceSubtypeDistance = applicability_probe.instanceSubtypeDistance;
const shapeOfValueMember = applicability_probe.shapeOfValueMember;
const sigViewOfMember = applicability_probe.sigViewOfMember;
const applicRefineCbM = applicability_probe.applicRefineCbM;
const applicIdentityConflictCbM = applicability_probe.applicIdentityConflictCbM;
const applicExactHeadCbM = applicability_probe.applicExactHeadCbM;
const applicSubtypeCbM = applicability_probe.applicSubtypeCbM;
const applicFuncTypeCbM = applicability_probe.applicFuncTypeCbM;
const applicExtRecvMatchCb = applicability_probe.applicExtRecvMatchCb;
const applicExtSubtypeNameCb = applicability_probe.applicExtSubtypeNameCb;
const applicExtOwnerRankCb = applicability_probe.applicExtOwnerRankCb;
const rangeContainsArgKindMatches = applicability_probe.rangeContainsArgKindMatches;
const applicKnownPackageCb = applicability_probe.applicKnownPackageCb;
const appliedMemberScore = applicability_probe.appliedMemberScore;
const funcDefaults = applicability_probe.funcDefaults;
const runtimeMemberApplicability = applicability_probe.runtimeMemberApplicability;
const paramHasDefault = applicability_probe.paramHasDefault;
pub const instanceExtendsFunctionType = applicability_probe.instanceExtendsFunctionType;
pub const instanceHasInvokeSurface = applicability_probe.instanceHasInvokeSurface;
const companionOwnerName = applicability_probe.companionOwnerName;
const companionOwnerMismatch = applicability_probe.companionOwnerMismatch;
const classDefIsA = applicability_probe.classDefIsA;
const classDefIsAImpl = applicability_probe.classDefIsAImpl;
const receiverDefinitelyNotParam = applicability_probe.receiverDefinitelyNotParam;
const isDefinitelyNonFunctionTypeName = applicability_probe.isDefinitelyNonFunctionTypeName;
const isArrayRelatedIface = applicability_probe.isArrayRelatedIface;
const scalarKindName = applicability_probe.scalarKindName;
const isScalarKindName = applicability_probe.isScalarKindName;
const stripFileMangle = applicability_probe.stripFileMangle;
const anyFileMangledVariant = applicability_probe.anyFileMangledVariant;
const admArgKey = applicability_probe.admArgKey;
const TlAdmEntry = applicability_probe.TlAdmEntry;
pub const argDefinitelyNotParamType = applicability_probe.argDefinitelyNotParamType;
const argDefinitelyNotParamTypeUncached = applicability_probe.argDefinitelyNotParamTypeUncached;
const classChainHasInvokeIn = applicability_probe.classChainHasInvokeIn;
const pickArityForced = applicability_probe.pickArityForced;
const argsRelaxedAdjudicable = applicability_probe.argsRelaxedAdjudicable;
const pickMethodOverload = applicability_probe.pickMethodOverload;

const flat_call = @import("host_call_member/flat_call.zig");
pub const listOf = flat_call.listOf;
pub const cloneItemsList = flat_call.cloneItemsList;
const isArrayContentFn = flat_call.isArrayContentFn;
const prependReceiver = flat_call.prependReceiver;
const callCallableIndexed = flat_call.callCallableIndexed;
const dispatchWithReceiver = flat_call.dispatchWithReceiver;
const instanceInvokeWantsPair = flat_call.instanceInvokeWantsPair;
pub const provideDelegateFor = flat_call.provideDelegateFor;
pub const callMember = flat_call.callMember;
const callMemberInner = flat_call.callMemberInner;
pub const callableFieldArity = flat_call.callableFieldArity;
pub const debugClassNameOf = flat_call.debugClassNameOf;
const supertypeHead = flat_call.supertypeHead;
pub const valueCouldServeName = flat_call.valueCouldServeName;
const RecvFnGate = flat_call.RecvFnGate;
const recvFnPropsAny = flat_call.recvFnPropsAny;
const recvFnPropHeadOf = flat_call.recvFnPropHeadOf;
const recvFnReceiverFor = flat_call.recvFnReceiverFor;
pub const implicitReceiverForHead = flat_call.implicitReceiverForHead;
const recvFnFieldInvoke = flat_call.recvFnFieldInvoke;
const varargShadowedFieldInvoke = flat_call.varargShadowedFieldInvoke;
pub const prepareMemberFlatCallNamed = flat_call.prepareMemberFlatCallNamed;
pub const prepareMemberFlatCall = flat_call.prepareMemberFlatCall;
const receiverHasMemberNamed = flat_call.receiverHasMemberNamed;
const cacheServesExecutingFrame = flat_call.cacheServesExecutingFrame;
const prepareFlatFromFid = flat_call.prepareFlatFromFid;
const vflatTraceOn = flat_call.vflatTraceOn;
pub const memberSiteSig = flat_call.memberSiteSig;
pub const HostServeKind = flat_call.HostServeKind;
pub const hostMemberServeProbe = flat_call.hostMemberServeProbe;
pub const hostMemberServeKind = flat_call.hostMemberServeKind;
pub const prepareMemberFlatFromFid = flat_call.prepareMemberFlatFromFid;
const slotNameForTrace = flat_call.slotNameForTrace;
pub const prepareVirtualFlatCall = flat_call.prepareVirtualFlatCall;
pub const prepareResolvedFlatCall = flat_call.prepareResolvedFlatCall;
const routeTraceOn = flat_call.routeTraceOn;
const builtinIntrinsicReplay = flat_call.builtinIntrinsicReplay;
pub const replayHits = flat_call.replayHits;

const static_tail = @import("host_call_member/static_tail.zig");
const callMemberInnerStatic = static_tail.callMemberInnerStatic;
const receiverHasThreadedMember = static_tail.receiverHasThreadedMember;
const composeMemberPairRetry = static_tail.composeMemberPairRetry;
const missTraceMaybe = static_tail.missTraceMaybe;
pub const missDumpClassChain = static_tail.missDumpClassChain;
const missTraceEnv = static_tail.missTraceEnv;
const nuTraceEnv = static_tail.nuTraceEnv;
const samTraceOn = static_tail.samTraceOn;
const missTraceWant = static_tail.missTraceWant;
pub const freeDispatchMiss = static_tail.freeDispatchMiss;
pub const isDispatchMissFor = static_tail.isDispatchMissFor;

const binding_probe = @import("host_call_member/binding_probe.zig");
const delegateMember = binding_probe.delegateMember;
const classMethodParamNames = binding_probe.classMethodParamNames;
const instanceBindingNamedProbe = binding_probe.instanceBindingNamedProbe;
const instanceBindingProbe = binding_probe.instanceBindingProbe;
const receiverClassChain = binding_probe.receiverClassChain;
const isBuiltinScalar = binding_probe.isBuiltinScalar;
const eqIgnoreCase = binding_probe.eqIgnoreCase;
const isCallableOrIntrinsic = binding_probe.isCallableOrIntrinsic;
const extWithThisLongerThanArgs = binding_probe.extWithThisLongerThanArgs;
const lookupGlobalValue = binding_probe.lookupGlobalValue;
const extensionTargetsAny = binding_probe.extensionTargetsAny;
const classCompanionAndEnum = binding_probe.classCompanionAndEnum;
const samInstanceDispatch = binding_probe.samInstanceDispatch;
const enclosingAnonMemberExtDispatch = binding_probe.enclosingAnonMemberExtDispatch;
const enclosingNamedMemberExtDispatch = binding_probe.enclosingNamedMemberExtDispatch;
pub const delegateFieldAt = binding_probe.delegateFieldAt;
const samAbstractExtRecvType = binding_probe.samAbstractExtRecvType;
const enclosingSamInstanceHandles = binding_probe.enclosingSamInstanceHandles;
const samMemberExtOnCallable = binding_probe.samMemberExtOnCallable;
const enclosingSamMemberExtDispatch = binding_probe.enclosingSamMemberExtDispatch;
const enclosingSamLambdaDispatch = binding_probe.enclosingSamLambdaDispatch;
const samMemberCtxTypes = binding_probe.samMemberCtxTypes;
const samMemberExtRecvType = binding_probe.samMemberExtRecvType;
const isBoundReference = binding_probe.isBoundReference;

const reflect_anon = @import("host_call_member/reflect_anon.zig");
const boundRefDispatch = reflect_anon.boundRefDispatch;
const kclassMembers = reflect_anon.kclassMembers;
const kfunctionReflection = reflect_anon.kfunctionReflection;
const propertyRefDispatch = reflect_anon.propertyRefDispatch;
pub const topLevelPropertyGet = reflect_anon.topLevelPropertyGet;
pub const isIteratorNext = reflect_anon.isIteratorNext;
pub const funcAt = reflect_anon.funcAt;
const argsListFromSlice = reflect_anon.argsListFromSlice;
const anonMethodDispatch = reflect_anon.anonMethodDispatch;
pub const invokeLocalClassThunk = reflect_anon.invokeLocalClassThunk;
const anonMethodDisproven = reflect_anon.anonMethodDisproven;
const anonMethodDisprovenFn = reflect_anon.anonMethodDisprovenFn;
const localClassTypeParam = reflect_anon.localClassTypeParam;
const root_mod = reflect_anon.root_mod;
const NameValue = reflect_anon.NameValue;
const AnonMethodEntry = reflect_anon.AnonMethodEntry;
const anonKey = reflect_anon.anonKey;
const lookupAnonMethod = reflect_anon.lookupAnonMethod;
const lookupAnonMethodExact = reflect_anon.lookupAnonMethodExact;
const invokeAnonMethod = reflect_anon.invokeAnonMethod;
const invokeAnonMethodFrom = reflect_anon.invokeAnonMethodFrom;
const padArgsWithDefaults = reflect_anon.padArgsWithDefaults;
const padArgsWithDefaultsFor = reflect_anon.padArgsWithDefaultsFor;
pub const setTrailingMemberCall = reflect_anon.setTrailingMemberCall;
const ResolvedMethod = reflect_anon.ResolvedMethod;

const resolve_method = @import("host_call_member/resolve_method.zig");
pub const resolveMemberFuncId = resolve_method.resolveMemberFuncId;
const memberArgsDisprovenExtensionApplies = resolve_method.memberArgsDisprovenExtensionApplies;
const callableArgPrefersFunctionExtension = resolve_method.callableArgPrefersFunctionExtension;
const funcTypeParamCount = resolve_method.funcTypeParamCount;
const findClassInHierarchy = resolve_method.findClassInHierarchy;
const ancestorClosureFqns = resolve_method.ancestorClosureFqns;
const isOperatorConventionName = resolve_method.isOperatorConventionName;
const staticIsInterface = resolve_method.staticIsInterface;
const closureHasMethodNamed = resolve_method.closureHasMethodNamed;
const ClassByNameHit = resolve_method.ClassByNameHit;
const classByNamePreferring = resolve_method.classByNamePreferring;
const closureHasGenericMethod = resolve_method.closureHasGenericMethod;
const resolveInstanceMethod = resolve_method.resolveInstanceMethod;
const methodBindsWithoutDefaults = resolve_method.methodBindsWithoutDefaults;
const classTypeParamRefutes = resolve_method.classTypeParamRefutes;
const typeHeadLast = resolve_method.typeHeadLast;
pub const invokeResolvedMember = resolve_method.invokeResolvedMember;
pub const resolveVirtualFuncId = resolve_method.resolveVirtualFuncId;
const runtimeVirtualCacheGet = resolve_method.runtimeVirtualCacheGet;
const runtimeVirtualCachePut = resolve_method.runtimeVirtualCachePut;
const runtimeClassDef = resolve_method.runtimeClassDef;
const runtimeVirtualOverride = resolve_method.runtimeVirtualOverride;
const runtimeInheritedVirtualTarget = resolve_method.runtimeInheritedVirtualTarget;
const linkRuntimeVirtualTarget = resolve_method.linkRuntimeVirtualTarget;
const virtualTargetExecutable = resolve_method.virtualTargetExecutable;
const runtimeVirtualTarget = resolve_method.runtimeVirtualTarget;
const invokeRuntimeVirtualSide = resolve_method.invokeRuntimeVirtualSide;
const virtualSlotUnlinkedDiag = resolve_method.virtualSlotUnlinkedDiag;

const slot_ops = @import("host_call_member/slot_ops.zig");
pub const slotByNameFallbacks = slot_ops.slotByNameFallbacks;
pub const HostSlotOp = slot_ops.HostSlotOp;
const hostSlotOpFor = slot_ops.hostSlotOpFor;
pub const hostSlotOpOfFqn = slot_ops.hostSlotOpOfFqn;
pub const hostFreeMemberByName = slot_ops.hostFreeMemberByName;
pub const HostFreeAnswer = slot_ops.HostFreeAnswer;
pub const hostFreeMemberAnswer = slot_ops.hostFreeMemberAnswer;
pub const runHostFreeSlotOp = slot_ops.runHostFreeSlotOp;
const runHostSlotOp = slot_ops.runHostSlotOp;
const isIteratorProtocol = slot_ops.isIteratorProtocol;
const noteSlotByName2 = slot_ops.noteSlotByName2;
const isScalarValue = slot_ops.isScalarValue;
const noinstTraceOn = slot_ops.noinstTraceOn;
const BarrierKind = slot_ops.BarrierKind;
const barrierSpec = slot_ops.barrierSpec;
const typeSafeBarrierAnswer = slot_ops.typeSafeBarrierAnswer;
const stampVirtSite = slot_ops.stampVirtSite;
const slotOwnerSimpleName = slot_ops.slotOwnerSimpleName;
const rangeElemTypeName = slot_ops.rangeElemTypeName;
const slotNameOrNull = slot_ops.slotNameOrNull;

const virtual_tail = @import("host_call_member/virtual_tail.zig");
pub const invokeVirtualMember = virtual_tail.invokeVirtualMember;
const invokeMethodFuncId = virtual_tail.invokeMethodFuncId;
const methodArgSigRelaxed = virtual_tail.methodArgSigRelaxed;
const instanceMethodKeyRelaxed = virtual_tail.instanceMethodKeyRelaxed;
const methodArgSig = virtual_tail.methodArgSig;
const instanceMethodKey = virtual_tail.instanceMethodKey;
const instanceMethodKeyScoped = virtual_tail.instanceMethodKeyScoped;

const caches = @import("host_call_member/caches.zig");
const METHOD_MISS = caches.METHOD_MISS;
const TL_METHOD_CACHE_SIZE = caches.TL_METHOD_CACHE_SIZE;
const TlMethodEntry = caches.TlMethodEntry;
const TL_ABSENT = caches.TL_ABSENT;
const tlSlot = caches.tlSlot;
const TlProbe = caches.TlProbe;
const tlGet = caches.tlGet;
const tlPut = caches.tlPut;
const tlPutAbsent = caches.tlPutAbsent;
const TlPermEntry = caches.TlPermEntry;
const TlResolveEntry = caches.TlResolveEntry;
const tlResolveSlot = caches.tlResolveSlot;
const tlResolveMatch = caches.tlResolveMatch;
const tlResolveStore = caches.tlResolveStore;
const instanceMethodCacheGetRaw = caches.instanceMethodCacheGetRaw;
const instanceMethodCachePutRaw = caches.instanceMethodCachePutRaw;
const extMethodCacheGet = caches.extMethodCacheGet;
const extMethodCachePut = caches.extMethodCachePut;
const TlIntrinsicEntry = caches.TlIntrinsicEntry;
const instanceIntrinsicCacheGet = caches.instanceIntrinsicCacheGet;
const virtualSlotInterfaceMember = caches.virtualSlotInterfaceMember;
const resolvedMemberName = caches.resolvedMemberName;
pub const declaringClassSimpleName = caches.declaringClassSimpleName;
const instanceIntrinsicCachePut = caches.instanceIntrinsicCachePut;

const stdlib_tail = @import("host_call_member/stdlib_tail.zig");
const lambdaArgPrefersExtension = stdlib_tail.lambdaArgPrefersExtension;
const conventionSetCall = stdlib_tail.conventionSetCall;
const irMethodWalk = stdlib_tail.irMethodWalk;
const bridgeForReceiver = stdlib_tail.bridgeForReceiver;
const builtinBridgeDefault = stdlib_tail.builtinBridgeDefault;
const samIterableInstance = stdlib_tail.samIterableInstance;
const isKTypeSynth = stdlib_tail.isKTypeSynth;
const ktypeField = stdlib_tail.ktypeField;
const ktypeClassifierName = stdlib_tail.ktypeClassifierName;
const ktypeEquals = stdlib_tail.ktypeEquals;
const ktypeHash = stdlib_tail.ktypeHash;
const ktypeRender = stdlib_tail.ktypeRender;
const anyInstanceFallback = stdlib_tail.anyInstanceFallback;
const renderStructuralLocked = stdlib_tail.renderStructuralLocked;
const probeFqn = stdlib_tail.probeFqn;
const numericWidthKind = stdlib_tail.numericWidthKind;
const declaredLambdaOverloadWins = stdlib_tail.declaredLambdaOverloadWins;
const instanceImplementsCharSequence = stdlib_tail.instanceImplementsCharSequence;
const instanceImplementsSequence = stdlib_tail.instanceImplementsSequence;
const declaredSequenceExtBody = stdlib_tail.declaredSequenceExtBody;
const sequenceExtBodyFid = stdlib_tail.sequenceExtBodyFid;
const stdlibMemberDispatch = stdlib_tail.stdlibMemberDispatch;
const stdlibMemberDispatchUncached = stdlib_tail.stdlibMemberDispatchUncached;
const memberCachePut = stdlib_tail.memberCachePut;
const throwableStackMember = stdlib_tail.throwableStackMember;
const throwableSuppressedMember = stdlib_tail.throwableSuppressedMember;
pub const instanceSuppressedList = stdlib_tail.instanceSuppressedList;
pub const appendInstanceSuppressed = stdlib_tail.appendInstanceSuppressed;
pub const instanceIsThrowable = stdlib_tail.instanceIsThrowable;
const inheritedInstanceToString = stdlib_tail.inheritedInstanceToString;

const member_ext_visibility = @import("host_call_member/member_ext_visibility.zig");
const isMemberExtFid = member_ext_visibility.isMemberExtFid;
const isMemberExt = member_ext_visibility.isMemberExt;
const privateFnHiddenHere = member_ext_visibility.privateFnHiddenHere;
pub const boundRefFile = member_ext_visibility.boundRefFile;
const memberExtVisible = member_ext_visibility.memberExtVisible;
const implementsSupertypeMemberExt = member_ext_visibility.implementsSupertypeMemberExt;
const ownerIsObjectSingleton = member_ext_visibility.ownerIsObjectSingleton;
const memberExtOwnerObjectClass = member_ext_visibility.memberExtOwnerObjectClass;
const userMemberExtShadows = member_ext_visibility.userMemberExtShadows;
const PackExtShadow = member_ext_visibility.PackExtShadow;
const importedPackExtShadows = member_ext_visibility.importedPackExtShadows;
const userToplevelExtNamedExists = member_ext_visibility.userToplevelExtNamedExists;
const memberDeclArityMisfit = member_ext_visibility.memberDeclArityMisfit;
const userToplevelExtShadows = member_ext_visibility.userToplevelExtShadows;
const collectClassClosure = member_ext_visibility.collectClassClosure;
const MEXT_OVERRIDE_MAX = member_ext_visibility.MEXT_OVERRIDE_MAX;
const MextOverrideEntry = member_ext_visibility.MextOverrideEntry;
const MEXT_OVERRIDE_SLOTS = member_ext_visibility.MEXT_OVERRIDE_SLOTS;
pub const memberExtOverridesFor = member_ext_visibility.memberExtOverridesFor;
const memberExtOverrideLookup = member_ext_visibility.memberExtOverrideLookup;
const OwnerSet = member_ext_visibility.OwnerSet;
const OWNER_SIG_MAX = member_ext_visibility.OWNER_SIG_MAX;
const ClosureNamesEntry = member_ext_visibility.ClosureNamesEntry;
const ClosureNamesFront = member_ext_visibility.ClosureNamesFront;
const CLOSURE_NAMES_FRONT_SLOTS = member_ext_visibility.CLOSURE_NAMES_FRONT_SLOTS;
const classClosureNames = member_ext_visibility.classClosureNames;
const enclosingOwnerSet = member_ext_visibility.enclosingOwnerSet;
const enclosingOwnerSetWalk = member_ext_visibility.enclosingOwnerSetWalk;
const delegateForwardNamed = member_ext_visibility.delegateForwardNamed;
const delegateForward = member_ext_visibility.delegateForward;
pub const interfaceDelegateFor = member_ext_visibility.interfaceDelegateFor;
const anonClassDeclares = member_ext_visibility.anonClassDeclares;
const anonTableHasPrefix = member_ext_visibility.anonTableHasPrefix;
const concreteChainDeclares = member_ext_visibility.concreteChainDeclares;
pub const delegatedInterfaceDeclares = member_ext_visibility.delegatedInterfaceDeclares;

const ext_fallback = @import("host_call_member/ext_fallback.zig");
const Candidate = ext_fallback.Candidate;
pub const builtinReceiverDisproven = ext_fallback.builtinReceiverDisproven;
const resolveExtReceiverFqn = ext_fallback.resolveExtReceiverFqn;
const narrowSameNameExtensionTwins = ext_fallback.narrowSameNameExtensionTwins;
const serveCachedMemberExt = ext_fallback.serveCachedMemberExt;
pub const extFbCounts = ext_fallback.extFbCounts;
pub const extensionFnFallback = ext_fallback.extensionFnFallback;
const extensionFnFallbackWalk = ext_fallback.extensionFnFallbackWalk;
const maybeWarnLenientExtBind = ext_fallback.maybeWarnLenientExtBind;
pub const resetLenientWarned = ext_fallback.resetLenientWarned;
pub const memberExtOwnerInstance = ext_fallback.memberExtOwnerInstance;
const instanceOuterLink = ext_fallback.instanceOuterLink;
const ExtKey = ext_fallback.ExtKey;
const extKeyGreater = ext_fallback.extKeyGreater;
const scoreExtCandidates = ext_fallback.scoreExtCandidates;
const isSubtypeName = ext_fallback.isSubtypeName;
const enclosingChainClassOrder = ext_fallback.enclosingChainClassOrder;
const localClassCompanionForward = ext_fallback.localClassCompanionForward;
const classCompanionForward = ext_fallback.classCompanionForward;
const instanceCompanionFallback = ext_fallback.instanceCompanionFallback;

const named_call = @import("host_call_member/named_call.zig");
pub const callMemberNamed = named_call.callMemberNamed;
pub const callMemberNamedStatic = named_call.callMemberNamedStatic;
pub const callMemberStrictExt = named_call.callMemberStrictExt;
pub const committedExtReceiverDisproven = named_call.committedExtReceiverDisproven;
pub const committedExtReceiverProven = named_call.committedExtReceiverProven;
pub const callMemberMembersOnly = named_call.callMemberMembersOnly;
pub const callMemberMembersOnlyLenient = named_call.callMemberMembersOnlyLenient;
pub const callMemberNamedDeclared = named_call.callMemberNamedDeclared;
const callMemberNamedInner = named_call.callMemberNamedInner;
const copyNamed = named_call.copyNamed;
const stdlibNamedDispatch = named_call.stdlibNamedDispatch;
const userMethodNamed = named_call.userMethodNamed;
const resolveExtOverloadLocal = named_call.resolveExtOverloadLocal;
const memberApplicableForWalk = named_call.memberApplicableForWalk;
const memberApplicableForWalkNamed = named_call.memberApplicableForWalkNamed;
const unboundParamCount = named_call.unboundParamCount;
const scoreNamedMemberCandidate = named_call.scoreNamedMemberCandidate;
const lastParamIsFunctionShaped = named_call.lastParamIsFunctionShaped;
const receiverIdent = named_call.receiverIdent;
const walkActive = named_call.walkActive;
const namedOrderKey = named_call.namedOrderKey;
const namedWalkKey = named_call.namedWalkKey;
const namedMethodKey = named_call.namedMethodKey;
const namedBindPerm = named_call.namedBindPerm;
const serveNamedFid = named_call.serveNamedFid;
const invokeMethodNamedFid = named_call.invokeMethodNamedFid;
const instanceMethodWalkNamed = named_call.instanceMethodWalkNamed;

const member_ref_super = @import("host_call_member/member_ref_super.zig");
pub const syntheticClassFromFqn = member_ref_super.syntheticClassFromFqn;
const isUnsignedArrayName = member_ref_super.isUnsignedArrayName;
pub const memberRef = member_ref_super.memberRef;
pub const memberRefExact = member_ref_super.memberRefExact;
const boundRefArity = member_ref_super.boundRefArity;
const memberRefResolved = member_ref_super.memberRefResolved;
const firstSupertypeName = member_ref_super.firstSupertypeName;
const receiverPropCanHoldCallable = member_ref_super.receiverPropCanHoldCallable;
const classIsFunInterface = member_ref_super.classIsFunInterface;
const classIsInterface = member_ref_super.classIsInterface;
const supertypesClassFirst = member_ref_super.supertypesClassFirst;
const classIsRegistered = member_ref_super.classIsRegistered;
const ownerSupertypeBySuffix = member_ref_super.ownerSupertypeBySuffix;
const ownerHasSupertype = member_ref_super.ownerHasSupertype;
const emitSuperPath = member_ref_super.emitSuperPath;
pub const callSuper = member_ref_super.callSuper;
const qtTraceWant = member_ref_super.qtTraceWant;
pub const qualifiedThis = member_ref_super.qualifiedThis;
pub const serializerForClassTarget = member_ref_super.serializerForClassTarget;
const companionOwnerClassValue = member_ref_super.companionOwnerClassValue;


/// Guards `materializeUserMap` re-entry while the Map fallback runs.
pub threadlocal var map_fallback_active: bool = false;

/// Guards `drainIterableToList` re-entry while the Iterable fallback runs.
pub threadlocal var iterable_fallback_active: bool = false;

/// Run-boundary reset; a flag still set means a fallback leaked across runs.
pub fn resetReceiverTls() void {
    std.debug.assert(!map_fallback_active);
    std.debug.assert(!iterable_fallback_active);
    map_fallback_active = false;
    iterable_fallback_active = false;
}

fn unsupported(name: []const u8) EvalResult {
    return .{ .err = .{ .Unsupported = name } };
}

pub fn unimplemented(allocator: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!EvalResult {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    return .{ .err = .{ .Unimplemented = msg } };
}

pub fn typeErr(allocator: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!EvalError {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    return .{ .Type = msg };
}

pub fn throwExc(allocator: Allocator, fqn: []const u8, message: ?[]const u8) Allocator.Error!EvalError {
    return .{ .Throw = try Value.newException(allocator, .{
        .fqn = try runtime.strInit(allocator, fqn),
        .message = .from(if (message) |m| try runtime.strInit(allocator, m) else null),
        .cause = null,
    }) };
}

pub fn strVal(allocator: Allocator, s: []const u8) Allocator.Error!Value {
    return .{ .String = try runtime.strInit(allocator, s) };
}

pub fn boolVal(b: bool) Value {
    return .{ .Bool = b };
}

pub fn isNumericValue(v: *const Value) bool {
    return switch (v.*) {
        .Int, .Long, .Short, .Byte, .Double, .Float, .UInt, .ULong, .UShort, .UByte => true,
        else => false,
    };
}

/// The binary operator a numeric operator member maps to, `x.rem(y)` to `%`.
pub fn numericOpMethod(name: []const u8) ?ir.BinOp {
    const eql = std.mem.eql;
    if (eql(u8, name, "plus")) return .Add;
    if (eql(u8, name, "minus")) return .Sub;
    if (eql(u8, name, "times")) return .Mul;
    if (eql(u8, name, "div")) return .Div;
    if (eql(u8, name, "rem")) return .Mod;
    // `mod` stays on the stdlib implementation: for negative operands it takes
    // the divisor's sign and `rem` does not. Bitwise and shift members fall
    // through too, since `applyBinop` covers only arithmetic.
    return null;
}

pub fn simpleName(name: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

/// Declared receiver name minus nullability and type arguments, so it addresses
/// the host binding registered for the receiver's class.
pub fn staticReceiverBindingHead(name: []const u8) []const u8 {
    var head = std.mem.trim(u8, name, " ");
    head = std.mem.trimEnd(u8, head, "?");
    if (std.mem.findScalar(u8, head, '<')) |i| head = head[0..i];
    return std.mem.trim(u8, head, " ");
}

/// The name `toString` and `KClass.simpleName` report: a nested class lifts to
/// a flat `Outer$Data` but Kotlin shows `Data`, and `$` cannot occur in a
/// source class name, so the segment after the last `$` is that name.
pub fn classDisplayName(name: []const u8) []const u8 {
    var n = name;
    if (std.mem.findScalarLast(u8, n, '$')) |i| n = n[i + 1 ..];
    return simpleName(n);
}

// Dispatch invariants, gated on KLIO_TRACE_INVARIANTS (default off): they
// report a hazard as one `[INVARIANT]` tracer line and never repair it.

/// Candidate selection must have a unique winner; two distinct candidates tied
/// on the chosen score means declaration order broke the tie.
pub fn checkOverloadUnique(name: []const u8, winner: *const Func, tied: []const Func) void {
    if (!trace.invariantsEnabled()) return;
    var distinct: usize = 0;
    for (tied) |f| {
        if (@intFromEnum(f.id) != @intFromEnum(winner.id)) distinct += 1;
    }
    if (distinct == 0) return;
    trace.invariant(
        "kind=overload_tie site=pickMethodOverload name={s} chosen_fid={d} chosen_fqn={s} tied_count={d}",
        .{ name, @intFromEnum(winner.id), winner.fqn, distinct + 1 },
    );
}

/// A selected `FuncId` must index the module's func table.
pub fn checkFuncInRange(self: *VmHost, site: []const u8, fid: FuncId) void {
    if (!trace.invariantsEnabled()) return;
    const mg = self.module.borrow();
    defer mg.deinit();
    const n = mg.get().funcCount();
    if (@intFromEnum(fid) >= n) {
        trace.invariant(
            "kind=funcid_oob site={s} fid={d} func_count={d}",
            .{ site, @intFromEnum(fid), n },
        );
    }
}

fn instancePtr(v: *const Value) ?*const anyopaque {
    return switch (v.*) {
        .Instance => |i| @ptrCast(i.cell),
        else => null,
    };
}

/// A `"this"` param and a `"this"` capture must name the same `Instance`, and
/// an interior `Null`/`Unit` in the enclosing-`this` chain is a lost receiver.
pub fn checkReceiverChain(self: *VmHost, allocator: Allocator, site: []const u8, this_param: ?*const Value, this_capture: ?*const Value) void {
    if (!trace.invariantsEnabled()) return;
    if (this_param != null and this_capture != null) {
        const pp = instancePtr(this_param.?);
        const cp = instancePtr(this_capture.?);
        if (pp != null and cp != null and pp.? != cp.?) {
            trace.invariant(
                "kind=this_mismatch site={s} param_tag={s} capture_tag={s}",
                .{ site, @tagName(this_param.?.*), @tagName(this_capture.?.*) },
            );
        }
    }
    const chain = enclosingThisChain(self, allocator) catch return;
    defer allocator.free(chain);
    if (chain.len < 2) return;
    for (chain[0 .. chain.len - 1], 0..) |v, i| {
        switch (v) {
            .Null, .Unit => trace.invariant(
                "kind=chain_hole site={s} index={d} tag={s} depth={d}",
                .{ site, i, @tagName(v), chain.len },
            ),
            else => {},
        }
    }
}

pub fn callMemberRec(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!EvalResult {
    return callMember(self, allocator, receiver, name, args);
}

/// Whether the closure body is compose-threaded: its params end with the
/// synthetic `($composer, $changed)` pair. `callValue` completes that pair from
/// the ambient composer, so arity checks must also accept the pair-less shape.
pub fn closurePairTailed(self: *VmHost, info: anytype) bool {
    const module: *const Module = info.module orelse self.module.asPtr();
    const func = module.funcById(info.body_func) orelse return false;
    return func.params.len >= 2 and
        std.mem.eql(u8, func.params[func.params.len - 1].name, "$changed") and
        std.mem.eql(u8, func.params[func.params.len - 2].name, "$composer");
}

pub fn callValueRec(self: *VmHost, allocator: Allocator, callee: *const Value, args: []const Value) Allocator.Error!EvalResult {
    // A receiver-typed callable invoked function-style passes its receiver as
    // arg 0: one arg over the declared params plus a `this` capture is that
    // shape, so bind args[0] as the receiver rather than as param 0.
    if (callee.* == .IrClosure and args.len >= 1) {
        if (self.closures.get(@intCast(callee.IrClosure.asPtr().id))) |info| {
            if (args.len == info.n_params + 1 or
                (args.len + 2 == info.n_params + 1 and closurePairTailed(self, info)))
            {
                var has_this = false;
                for (info.capture_names) |n| {
                    if (std.mem.eql(u8, n, "this")) {
                        has_this = true;
                        break;
                    }
                }
                if (has_this) {
                    return self.callValueWithThis(allocator, callee, &args[0], args[1..], &.{});
                }
                // No `this` slot means the body never reads the receiver, but
                // it still scopes dispatch: push it as innermost subject.
                const pushed = args[0] == .Instance or args[0] == .Null;
                if (pushed) pushAccessEnclosingSubject(self, &args[0]);
                const r = self.callValue(allocator, callee, args[1..]);
                if (pushed) popAccessEnclosing(self);
                return r;
            }
        }
    }
    return self.callValue(allocator, callee, args);
}

fn callValueWithThisRec(self: *VmHost, allocator: Allocator, callee: *const Value, this_value: *const Value, args: []const Value) Allocator.Error!EvalResult {
    return self.callValueWithThis(allocator, callee, this_value, args, &.{});
}

pub fn newInstanceById(self: *VmHost, allocator: Allocator, class: ir.ClassId, args: []const Value, outer_hint: ?*const Value) Allocator.Error!EvalResult {
    return self.newInstance(allocator, class, args, outer_hint);
}

pub fn reconstructDataClass(self: *VmHost, allocator: Allocator, inst: ObjRef(InstanceData), args: []const Value) Allocator.Error!EvalResult {
    const class_def = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().class.clone();
    };
    var callee: Value = .{ .Class = class_def };
    defer callee.deinit(allocator);
    return host_call_value.callValue(self, allocator, &callee, args);
}

pub fn getFieldRec(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
    return self.getField(allocator, receiver, name);
}

pub fn callFuncRec(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value) Allocator.Error!EvalResult {
    // Every member route funnels here, so forwarding the trailing-lambda bit
    // makes `callFunc`'s default fill bind the lambda to the last param.
    if (reflect_anon.trailing_member_call) host_call_func.setTrailingLambdaCall(true);
    const r = self.callFunc(allocator, module, func, args);
    host_call_func.setTrailingLambdaCall(false);
    return r;
}

pub fn callFuncNamedRec(self: *VmHost, allocator: Allocator, module: *const Module, func: FuncId, args: []const Value, names: []const ?[]const u8) Allocator.Error!EvalResult {
    if (reflect_anon.trailing_member_call) host_call_func.setTrailingLambdaCall(true);
    const r = self.callFuncNamed(allocator, module, func, args, names);
    host_call_func.setTrailingLambdaCall(false);
    return r;
}

pub fn callFuncIndexedRec(
    self: *VmHost,
    allocator: Allocator,
    module: *const Module,
    func: FuncId,
    defaults_from: FuncId,
    receiver: *const Value,
    args: []const Value,
    arg_params: []const u32,
) Allocator.Error!EvalResult {
    if (reflect_anon.trailing_member_call) host_call_func.setTrailingLambdaCall(true);
    const r = host_call_func.callFuncIndexed(self, allocator, module, func, defaults_from, receiver, args, arg_params);
    host_call_func.setTrailingLambdaCall(false);
    return r;
}

/// A pack-installed binding shadows the shipped implementation.
pub fn lookupIntrinsic(self: *VmHost, fqn: []const u8) ?StdlibFn {
    // Post-link the bindings table is read-only, so the published link flag
    // gates an unguarded read instead of two shared reader locks per lookup.
    {
        const img = self.prog.asPtrConst();
        if (@atomicLoad(bool, &img.resolved_linked, .acquire)) {
            if (img.installed_bindings.asPtrConst().resolve(fqn)) |f| return f;
            return stdlib.implementation(fqn);
        }
    }
    const pg = self.prog.borrow();
    defer pg.deinit();
    const bg = pg.get().installed_bindings.borrow();
    defer bg.deinit();
    if (bg.get().resolve(fqn)) |f| return f;
    return stdlib.implementation(fqn);
}

pub fn dispatchIntrinsic(self: *VmHost, allocator: Allocator, fqn: []const u8, func: StdlibFn, args: []const Value) Allocator.Error!EvalResult {
    vmhost.emitPath(allocator, "intrinsic_call_member", fqn, null, null, args);
    const keepalive = self.ka.mark();
    defer self.ka.restore(keepalive);
    self.ka.pushSlice(args);
    var intrinsic = makeIntrinsicHost(self);
    defer deinitIntrinsicHost(&intrinsic);
    var ihost = intrinsic.intrinsicHost();
    _ = &ihost;
    stdlib.implementations.string.clearRecvMemo();
    var ctx = CallCtx{
        .args = args,
        .out = self.out,
        .host = intrinsic.intrinsicHost(),
        .allocator = allocator,
    };
    const prev_fqn = runtime.leaktrack.current_fqn;
    runtime.leaktrack.current_fqn = fqn;
    const r = try func(&ctx);
    runtime.leaktrack.current_fqn = prev_fqn;
    return mapRuntimeResult(allocator, r);
}

pub fn makeIntrinsicHost(self: *VmHost) VmIntrinsicHost {
    return .{
        .module = self.module.clone(),
        .closures = self.closures.clone(),
        .globals = self.globals.clone(),
        .classes = self.classes.clone(),
        .prog = self.prog.clone(),
        .anon_methods = self.anon_methods.clone(),
        .class_default_outer = self.class_default_outer.clone(),
        .instance_id_counter = self.instance_id_counter.clone(),
        .out_sink = self.out_sink.clone(),
        .threads = self.threads.clone(),
        .object_states = self.object_states.clone(),
        .singletons_by_id = self.singletons_by_id.clone(),
        .allocator = self.allocator,
    };
}

pub fn deinitIntrinsicHost(h: *VmIntrinsicHost) void {
    h.object_states.deinit();
    h.module.deinit();
    h.closures.deinit();
    h.globals.deinit();
    h.classes.deinit();
    h.prog.deinit();
    h.anon_methods.deinit();
    h.class_default_outer.deinit();
    h.instance_id_counter.deinit();
    h.out_sink.deinit();
    h.threads.deinit();
}

fn mapRuntimeResult(allocator: Allocator, r: runtime.EvalResult) Allocator.Error!EvalResult {
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = try mapRuntimeError(allocator, e) },
    };
}

pub fn mapRuntimeError(allocator: Allocator, e: RuntimeError) Allocator.Error!EvalError {
    return switch (e) {
        .Thrown => |v| .{ .Throw = v },
        .Return => |v| .{ .NonLocalReturn = v },
        .Suspend => |wake| blk: {
            const ss = try allocator.create(ir.eval.SuspendState);
            ss.* = .{ .token = 0, .frames = .empty, .wake_in_millis = wake, .pending_resume_reg = null };
            break :blk .{ .Suspended = ss };
        },
        .CalleeFailed => |m| .{ .CalleeFailed = m },
        // Each message-carrying variant keeps its text; collapsing to the tag
        // name would report "IR eval: Type" instead of the real diagnostic.
        .Type => |s| .{ .Type = s },
        .Unbound => |s| .{ .Unbound = s },
        .Unimplemented => |s| .{ .Unimplemented = s },
        .Arity => |s| .{ .Arity = s },
        else => |other| try typeErr(allocator, "unexpected intrinsic result: {s}", .{@tagName(other)}),
    };
}

/// Generation stamp for every process-global and thread-local dispatch cache.
/// A driver running many programs per process frees each program's module and
/// arena, and the next program reuses those pointer identities, so an entry
/// keyed on them would replay the earlier resolution or call into freed IR.
/// Such drivers bump the generation per program; older stamps never hit.
pub var dispatch_cache_gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(1);
pub fn dispatchCacheGen() u32 {
    return dispatch_cache_gen.load(.monotonic);
}

pub fn bumpDispatchCacheGen() void {
    _ = dispatch_cache_gen.fetchAdd(1, .monotonic);
}
pub inline fn cacheGen() u32 {
    return dispatch_cache_gen.load(.monotonic);
}

pub var ext_fb_total: u64 = 0;
pub var ext_fb_plain_hit: u64 = 0;
pub var ext_fb_chain_hit: u64 = 0;
pub var ext_fb_walk: u64 = 0;

const testing = std.testing;

test "unsigned prim-array kinds resolve to their ARRAY receiver name" {
    // builtinReceiverDisproven compares against simpleName(view.typeFqn());
    // the kind's own simpleName is the element name.
    const kinds = [_]runtime.PrimitiveArrayKind{ .UInt, .ULong, .UShort, .UByte };
    const names = [_][]const u8{ "UIntArray", "ULongArray", "UShortArray", "UByteArray" };
    for (kinds, names) |k, n| {
        try std.testing.expectEqualStrings(n, simpleName(k.typeFqn()));
        try std.testing.expect(!std.mem.eql(u8, k.simpleName(), n));
    }
}

test "simpleName returns the trailing dotted segment" {
    try testing.expectEqualStrings("C", simpleName("a.b.C"));
    try testing.expectEqualStrings("C", simpleName("C"));
    try testing.expectEqualStrings("", simpleName("a."));
}

test "static receiver binding head removes Kotlin type suffixes" {
    try testing.expectEqualStrings("kotlin.String", staticReceiverBindingHead("kotlin.String?"));
    try testing.expectEqualStrings("List", staticReceiverBindingHead(" List<String>? "));
}

test "allUppercase recognizes type-parameter-style names" {
    try testing.expect(allUppercase("T"));
    try testing.expect(allUppercase("K2"));
    try testing.expect(!allUppercase("Foo"));
    try testing.expect(!allUppercase("ab"));
}

test "kotlinHashCode matches Kotlin for builtins" {
    try testing.expectEqual(@as(i32, 0), kotlinHashCode(&.Null));
    try testing.expectEqual(@as(i32, 1231), kotlinHashCode(&.{ .Bool = true }));
    try testing.expectEqual(@as(i32, 1237), kotlinHashCode(&.{ .Bool = false }));
    // The unsigned value classes hash their signed storage: 65535u is -1.
    try testing.expectEqual(@as(i32, -1), kotlinHashCode(&.{ .UShort = 65535 }));
    try testing.expectEqual(@as(i32, -1), kotlinHashCode(&.{ .UByte = 255 }));
    try testing.expectEqual(@as(i32, 1), kotlinHashCode(&.{ .UShort = 1 }));
    try testing.expectEqual(@as(i32, 65), kotlinHashCode(&.{ .Char = 'A' }));
    try testing.expectEqual(@as(i32, 42), kotlinHashCode(&.{ .Int = 42 }));
}

test "kotlinHashCode of a String uses the polynomial hash" {
    const s = try runtime.strInit(testing.allocator, "ABC");
    defer s.deinit();
    // 'A'*31^2 + 'B'*31 + 'C' = 65*961 + 66*31 + 67 = 64578.
    try testing.expectEqual(@as(i32, 64578), kotlinHashCode(&.{ .String = s }));
}

test "isSequenceTerminal classifies terminal vs pipeline ops" {
    try testing.expect(isSequenceTerminal("toList"));
    try testing.expect(isSequenceTerminal("count"));
    try testing.expect(!isSequenceTerminal("map"));
    try testing.expect(!isSequenceTerminal("filter"));
}

test "materialiseRangeItems builds inclusive progressions" {
    var asc = try materialiseRangeItems(testing.allocator, 1, 5, 2, .Int);
    defer asc.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), asc.items.len);
    try testing.expectEqual(@as(i64, 1), asc.items[0].asI64().?);
    try testing.expectEqual(@as(i64, 5), asc.items[2].asI64().?);

    var desc = try materialiseRangeItems(testing.allocator, 3, 1, -1, .Int);
    defer desc.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), desc.items.len);
    try testing.expectEqual(@as(i64, 3), desc.items[0].asI64().?);
    try testing.expectEqual(@as(i64, 1), desc.items[2].asI64().?);
}

test "compareValuesBuiltin orders scalars and strings" {
    try testing.expectEqual(Ordering.lt, compareValuesBuiltin(&.{ .Int = 1 }, &.{ .Int = 2 }).?);
    try testing.expectEqual(Ordering.gt, compareValuesBuiltin(&.{ .Double = 2.5 }, &.{ .Int = 2 }).?);
    try testing.expectEqual(
        Ordering.gt,
        compareValuesBuiltin(
            &.{ .ULong = std.math.maxInt(u64) },
            &.{ .ULong = 0 },
        ).?,
    );
    const a = try runtime.strInit(testing.allocator, "abc");
    defer a.deinit();
    const b = try runtime.strInit(testing.allocator, "abd");
    defer b.deinit();
    try testing.expectEqual(Ordering.lt, compareValuesBuiltin(&.{ .String = a }, &.{ .String = b }).?);
}

test "discarded member probes release their owned miss message" {
    const msg = try testing.allocator.dupe(u8, "Vm::call_member `f` on `T`");
    freeDispatchMiss(testing.allocator, .{ .err = .{ .Unimplemented = msg } });
    freeDispatchMiss(testing.allocator, .{ .err = .{ .Unimplemented = "nested: Vm::call_member is static" } });
}

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(@import("host_call_member/applicability_probe.zig"));
    testing.refAllDecls(@import("host_call_member/binding_probe.zig"));
    testing.refAllDecls(@import("host_call_member/caches.zig"));
    testing.refAllDecls(@import("host_call_member/ext_fallback.zig"));
    testing.refAllDecls(@import("host_call_member/flat_call.zig"));
    testing.refAllDecls(@import("host_call_member/member_ext_visibility.zig"));
    testing.refAllDecls(@import("host_call_member/member_presence.zig"));
    testing.refAllDecls(@import("host_call_member/member_ref_super.zig"));
    testing.refAllDecls(@import("host_call_member/named_call.zig"));
    testing.refAllDecls(@import("host_call_member/receiver_probe.zig"));
    testing.refAllDecls(@import("host_call_member/reflect_anon.zig"));
    testing.refAllDecls(@import("host_call_member/resolve_method.zig"));
    testing.refAllDecls(@import("host_call_member/slot_ops.zig"));
    testing.refAllDecls(@import("host_call_member/static_tail.zig"));
    testing.refAllDecls(@import("host_call_member/stdlib_tail.zig"));
    testing.refAllDecls(@import("host_call_member/virtual_tail.zig"));
}
