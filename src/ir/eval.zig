//! IR evaluator.
//!
//! Walks a `Func`'s `[]Block` and produces a `Value`. Today
//! supports the subset of `Inst`s the lowering pass emits: `Const`,
//! `BinOp`, `UnOp`, `Not`, `Move`, plus `Goto` / `Branch` / `Return`
//! / `Throw` / `Unreachable` terminators. Other ops trap as
//! `EvalError.Unsupported`.
//!
//! The evaluator does not yet replace the tree-walking interpreter.
//! It exists so the IR shape can be exercised end-to-end on
//! hand-built or lowered modules; as the lowering pass grows, the
//! evaluator grows alongside it, and the cutover lands once parity
//! holds across the corpus.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("ir.zig");
const span = @import("span");
const jit_loop = @import("jit_loop.zig");
const bc = @import("bc.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;
const ObjRef = runtime.ObjRef;
const RangeKind = runtime.RangeKind;
const InstanceData = runtime.InstanceData;

const BinOp = ir.BinOp;
const BlockId = ir.BlockId;
const Const = ir.Const;
const Func = ir.Func;
const FuncId = ir.FuncId;
const ClassId = ir.ClassId;
const ConstId = ir.ConstId;
const Inst = ir.Inst;
const Module = ir.Module;
const Reg = ir.Reg;
const Terminator = ir.Terminator;
const TypeRef = ir.TypeRef;
const UnOp = ir.UnOp;

const exec_call = @import("exec_call.zig");

const argNamesAllNull = exec_call.argNamesAllNull;
const callerThisValue = exec_call.callerThisValue;
const constStr = exec_call.constStr;
const declaringClassName = exec_call.declaringClassName;
const envVarSet = exec_call.envVarSet;
const execArmAstLambda = exec_call.execArmAstLambda;
const execArmBuildObject = exec_call.execArmBuildObject;
const execArmCall = exec_call.execArmCall;
const execArmCallMemberOrValue = exec_call.execArmCallMemberOrValue;
const execArmCallSpread = exec_call.execArmCallSpread;
const execArmCallSuper = exec_call.execArmCallSuper;
const execArmCallValue = exec_call.execArmCallValue;
const execArmCallValueOrMember = exec_call.execArmCallValueOrMember;
const execArmCallVirtual = exec_call.execArmCallVirtual;
const execArmCast = exec_call.execArmCast;
const execArmCtxCall = exec_call.execArmCtxCall;
const execArmCtxScope = exec_call.execArmCtxScope;
const execArmIndex = exec_call.execArmIndex;
const execArmIndexSet = exec_call.execArmIndexSet;
const execArmInstanceOf = exec_call.execArmInstanceOf;
const execArmLambda = exec_call.execArmLambda;
const execArmLoadFromThisOrGlobal = exec_call.execArmLoadFromThisOrGlobal;
const execArmMemberRef = exec_call.execArmMemberRef;
const execArmNewInstance = exec_call.execArmNewInstance;
const execArmNewList = exec_call.execArmNewList;
const execArmPropertyRef = exec_call.execArmPropertyRef;
const execArmQualifiedThis = exec_call.execArmQualifiedThis;
const execArmRegisterClass = exec_call.execArmRegisterClass;
const execArmStoreToThisOrGlobal = exec_call.execArmStoreToThisOrGlobal;
const execCallMemberOrGlobal = exec_call.execCallMemberOrGlobal;
const fastIndexGet = exec_call.fastIndexGet;
const fastSubscript = exec_call.fastSubscript;
const freeArgNames = exec_call.freeArgNames;
const freeDispatchMissMsg = exec_call.freeDispatchMissMsg;
const nullSiteOk = exec_call.nullSiteOk;
const ownReceiverEntry = exec_call.ownReceiverEntry;
const primitiveMemberFast = exec_call.primitiveMemberFast;
const primitiveMemberOp = exec_call.primitiveMemberOp;
const rangeIterFast = exec_call.rangeIterFast;
const readArgRun = exec_call.readArgRun;
const resolveArgNames = exec_call.resolveArgNames;
const sameReceiver = exec_call.sameReceiver;

const ev_state = @import("eval/state.zig");

pub const EvalError = ev_state.EvalError;
pub const EnclosingEntry = ev_state.EnclosingEntry;
pub const currentCallSiteSpan = ev_state.currentCallSiteSpan;
pub const currentFramePackage = ev_state.currentFramePackage;
pub const ThisChainIter = ev_state.ThisChainIter;
pub const frameThisChainIter = ev_state.frameThisChainIter;
pub const frameThisChainAlloc = ev_state.frameThisChainAlloc;
pub const nearestFramePackage = ev_state.nearestFramePackage;
pub const RefSiteOverride = ev_state.RefSiteOverride;
pub const refSiteFile = ev_state.refSiteFile;
pub const pushRefSiteFile = ev_state.pushRefSiteFile;
pub const popRefSiteFile = ev_state.popRefSiteFile;
pub const currentFuncName = ev_state.currentFuncName;
pub const currentFrameParam = ev_state.currentFrameParam;
pub const currentFrameModule = ev_state.currentFrameModule;
pub const currentFrameFunc = ev_state.currentFrameFunc;
pub const currentFrameTypeParams = ev_state.currentFrameTypeParams;
pub const fillCensusBump = ev_state.fillCensusBump;
pub const acquireArgsCap = ev_state.acquireArgsCap;
pub const releaseArgs = ev_state.releaseArgs;
pub const releaseArgsIn = ev_state.releaseArgsIn;
pub const gcInstallFrameRoot = ev_state.gcInstallFrameRoot;
pub const gcUninstallFrameRoot = ev_state.gcUninstallFrameRoot;
pub const debugPrintFrames = ev_state.debugPrintFrames;

pub var regs_pool_hit: u64 = 0;
pub var regs_pool_miss: u64 = 0;
pub var regs_fill_slots: u64 = 0;

const ev_diag = @import("eval/diag.zig");

pub const wallCapAbandon = ev_diag.wallCapAbandon;
pub const evalDepthNow = ev_diag.evalDepthNow;
pub const dispatchCacheStable = ev_diag.dispatchCacheStable;
pub const nowMonotonicMs = ev_diag.nowMonotonicMs;
pub const op_route_names = ev_diag.op_route_names;
pub const opProfDump = ev_diag.opProfDump;
pub const callStatsProbe = ev_diag.callStatsProbe;
pub const probeStatsDump = ev_diag.probeStatsDump;
pub const DispatchKind = ev_diag.DispatchKind;
pub const dispatchBump = ev_diag.dispatchBump;
pub const dispatchNote = ev_diag.dispatchNote;
pub const dispatchStatsDump = ev_diag.dispatchStatsDump;
pub const callStatsDump = ev_diag.callStatsDump;
pub const frameCountInit = ev_diag.frameCountInit;
pub const frameCountDump = ev_diag.frameCountDump;
pub const fnProfDump = ev_diag.fnProfDump;
pub const errTraceOn = ev_diag.errTraceOn;
pub const dumpFrameChainForDiag = ev_diag.dumpFrameChainForDiag;
pub const FuncLoc = ev_diag.FuncLoc;
pub const funcFirstLoc = ev_diag.funcFirstLoc;
pub const installDebugFrameDump = ev_diag.installDebugFrameDump;
pub const dumpFrameChainForDiagAlways = ev_diag.dumpFrameChainForDiagAlways;
pub const dumpCurrentFrameParamsForDiag = ev_diag.dumpCurrentFrameParamsForDiag;
pub const formatStackTrace = ev_diag.formatStackTrace;
pub const stackTraceArray = ev_diag.stackTraceArray;
pub const formatThrowable = ev_diag.formatThrowable;
pub const attachStackTrace = ev_diag.attachStackTrace;

/// Per-test wall-clock deadline (monotonic milliseconds), 0 = disarmed.
/// The test runner arms it before each test phase and clears it after;
/// the eval loop's counter gate checks it on every thread, so a wedged
/// pump or a real-thread deadlock unwinds as a test failure instead of
/// hanging the whole class. Deliberately NOT cleared on fire: a lenient
/// dispatch arm that swallows the first error meets the deadline again
/// at the next gate, so retry ladders cannot absorb it.
pub var test_wall_deadline_ms = std.atomic.Value(i64).init(0);

/// Threads currently inside at least one interpreted activation (the
/// outermost `runFrame` entry). The test runner's wall-cap drain polls this
/// to know every abandoned cohort member has actually LEFT interpreted code
/// before it clears the abandonment flags — a straggler that outlives a
/// fixed grace window would otherwise keep running its dead test's loops
/// (with the flags cleared, forever) and contaminate every later test in
/// the class.
pub var threads_in_eval = std.atomic.Value(u32).init(0);

/// First wall-cap fire already threw the catchable timeout on some thread;
/// a second expiry (the extended unwind deadline) hard-aborts. Reset by the
/// test runner when it arms a fresh deadline.
pub var wall_cap_thrown = std.atomic.Value(bool).init(false);

/// Installed by the VM host so the stats dump can report how many named
/// member calls the builtin intrinsic replay served outright. `member_ladder`
/// counts the ROUTE a call took, not the work it did, so the two differ.
pub var dispatch_replay_hits: ?*const fn () u64 = null;

/// Set by the host so the dispatch report can name how the member-extension
/// fallback resolved: a plain-key hit, a chain-folded hit, or a full walk.
pub var ext_fb_counts: ?*const fn () [4]u64 = null;

/// KLIO_FN_PROF report: the sampler's per-id counts resolved to function
/// names through `module`. Ids fold into the table, so a name is reported
/// only when its id owns the slot; the fold is 1:1 for every program with
/// fewer functions than the table's slots.
/// KLIO_FRAME_COUNT / KLIO_FRAME_CENSUS: how many interpreted activations a
/// workload runs, and which functions they belong to. `activations` counts
/// register-bank acquisitions (one per real frame); `entries` counts
/// `runFrameExec` entries, which is higher because a flat call re-enters its
/// caller's frame. The frames-per-unit-of-work metric that separates "too
/// many frames" (splice work) from "frames too expensive" (activation cost).
pub var frame_count_total: u64 = 0;
pub var frame_alloc_total: u64 = 0;
pub var frame_count_on: bool = false;

pub var frame_watch_want: []const u8 = "";

/// Executed-instruction total (`KLIO_FRAME_COUNT` prints it): the denominator
/// that turns a sampled opcode profile into a per-instruction cost.
pub threadlocal var inst_count: u64 = 0;
pub var inst_count_all: std.atomic.Value(u64) = .init(0);

/// Delivery-route tag for KLIO_RESUME_TRACE: which host path drove the
/// current resume (park slot, persisted take, adopt, inline claim...).
pub threadlocal var resume_route: []const u8 = "?";

const ev_chain = @import("eval/chain.zig");

pub const EnclosingChainIter = ev_chain.EnclosingChainIter;
pub const enclosingChainIter = ev_chain.enclosingChainIter;
pub const pushEnclosing = ev_chain.pushEnclosing;
pub const pushEnclosingSubject = ev_chain.pushEnclosingSubject;
pub const pushEnclosingAccess = ev_chain.pushEnclosingAccess;
pub const popEnclosing = ev_chain.popEnclosing;
pub const enclosingThisLast = ev_chain.enclosingThisLast;
pub const enclosingThisChainAlloc = ev_chain.enclosingThisChainAlloc;
pub const enclosingChainClassHash = ev_chain.enclosingChainClassHash;
pub const enclosingEntriesAlloc = ev_chain.enclosingEntriesAlloc;
pub const captureChainAlloc = ev_chain.captureChainAlloc;

const ev_flow = @import("eval/flow.zig");

pub const EvalResult = ev_flow.EvalResult;
pub const Step = ev_flow.Step;
pub const FlatCallReq = ev_flow.FlatCallReq;
pub const flatEnabled = ev_flow.flatEnabled;
pub const vcallFlatEnabled = ev_flow.vcallFlatEnabled;
pub const missTraceWant = ev_flow.missTraceWant;
pub const cmgTraceWant = ev_flow.cmgTraceWant;
pub const nuTraceWant = ev_flow.nuTraceWant;
pub const armHostFlatReq = ev_flow.armHostFlatReq;
pub const takeHostFlatArm = ev_flow.takeHostFlatArm;
pub const stashHostFlatReq = ev_flow.stashHostFlatReq;
pub const takeHostFlatReq = ev_flow.takeHostFlatReq;
pub const raiseStep = ev_flow.raiseStep;
pub const ok = ev_flow.ok;
pub const errResult = ev_flow.errResult;
pub const lateinitThrow = ev_flow.lateinitThrow;

const ev_snapshot = @import("eval/snapshot.zig");

pub const TryFrame = ev_snapshot.TryFrame;
pub const FrameSnapshot = ev_snapshot.FrameSnapshot;
pub const SnapshotRegisters = ev_snapshot.SnapshotRegisters;
pub const resetSuspendLivenessCache = ev_snapshot.resetSuspendLivenessCache;
pub const TailSeg = ev_snapshot.TailSeg;
pub const SuspendState = ev_snapshot.SuspendState;
pub const gcMarkSuspendState = ev_snapshot.gcMarkSuspendState;
pub const gcMarkSuspendStateOpaque = ev_snapshot.gcMarkSuspendStateOpaque;
pub const freeSuspendStateOpaque = ev_snapshot.freeSuspendStateOpaque;

const ev_frame = @import("eval/frame.zig");

pub const RegMask = ev_frame.RegMask;
pub const Frame = ev_frame.Frame;

const ev_enter = @import("eval/enter.zig");

pub const eval = ev_enter.eval;
pub const leafExprServe = ev_enter.leafExprServe;
pub const evalWith = ev_enter.evalWith;
pub const boolThisTrap = ev_enter.boolThisTrap;
pub const dumpFnIfRequested = ev_enter.dumpFnIfRequested;
pub const evalWithCaptures = ev_enter.evalWithCaptures;
pub const evalWithCapturesIn = ev_enter.evalWithCapturesIn;
pub const evalWithCapturesChained = ev_enter.evalWithCapturesChained;

const ev_leaf = @import("eval/leaf.zig");

const ev_activation = @import("eval/activation.zig");

pub const pushNativePark = ev_activation.pushNativePark;
pub const takeInFlightSuspend = ev_activation.takeInFlightSuspend;
pub const resumeNativeContinuation = ev_activation.resumeNativeContinuation;
pub const resumeContinuation = ev_activation.resumeContinuation;

const ev_loop = @import("eval/loop.zig");

const ev_exec = @import("eval/exec.zig");

const ev_native = @import("eval/native.zig");

pub const NativeFn = ev_native.NativeFn;
pub const registerNative = ev_native.registerNative;
pub const NativeLeafFn = ev_native.NativeLeafFn;
pub const leaf_ctor_tail_genre = ev_native.leaf_ctor_tail_genre;
pub const CtorSite = ev_native.CtorSite;
pub const leafSigChar = ev_native.leafSigChar;
pub const leafKeyAlloc = ev_native.leafKeyAlloc;
pub const registerNativeLeafFqn = ev_native.registerNativeLeafFqn;
pub const registerNativeLeaf = ev_native.registerNativeLeaf;
pub const leafDiagDump = ev_native.leafDiagDump;
pub const LeafOutcome = ev_native.LeafOutcome;
pub const tryLeafValues = ev_native.tryLeafValues;
pub const tryLeafCall = ev_native.tryLeafCall;
pub const setNativeModuleCheck = ev_native.setNativeModuleCheck;
pub const NativeOutcome = ev_native.NativeOutcome;
pub const NativeCtx = ev_native.NativeCtx;
pub const nativeFrameRegs = ev_native.nativeFrameRegs;
pub const nativeOpTrace = ev_native.nativeOpTrace;
pub const nativeFrameSpanSlot = ev_native.nativeFrameSpanSlot;
pub const NativeEdgeView = ev_native.NativeEdgeView;
pub const nativeEdgeView = ev_native.nativeEdgeView;
pub const nativeOpEdgeRare = ev_native.nativeOpEdgeRare;
pub const nativeOpConstLoad = ev_native.nativeOpConstLoad;
pub const nativeOpConstInt = ev_native.nativeOpConstInt;
pub const nativeOpMove = ev_native.nativeOpMove;
pub const nativeOpLoadParam = ev_native.nativeOpLoadParam;
pub const nativeOpCellGet = ev_native.nativeOpCellGet;
pub const nativeOpBin = ev_native.nativeOpBin;
pub const nativeOpCall = ev_native.nativeOpCall;
pub const nativeOpFieldRoute = ev_native.nativeOpFieldRoute;
pub const nativeOpFieldWriteRoute = ev_native.nativeOpFieldWriteRoute;
pub const nativeOpEscape = ev_native.nativeOpEscape;
pub const nativeOpEdge = ev_native.nativeOpEdge;
pub const nativeOpBr = ev_native.nativeOpBr;
pub const nativeOpCmpBr = ev_native.nativeOpCmpBr;
pub const nativeOpRet = ev_native.nativeOpRet;
pub const nativeOpTerm = ev_native.nativeOpTerm;
pub const nativeOpGotoExit = ev_native.nativeOpGotoExit;

const ev_inst = @import("eval/inst.zig");

pub const armNow = ev_inst.armNow;
pub const armIsOn = ev_inst.armIsOn;

/// A field-read site that sees more than one receiver class re-asked the
/// host's (class, name) memo on every read, which interns the name and
/// probes a hash map. Remember the answer per (site, class) instead: the
/// route is a pure function of that pair.
pub var cm_calls: u64 = 0;
pub var cm_args_ns: u64 = 0;
pub var cm_prep_ns: u64 = 0;
pub var cm_replay_ns: u64 = 0;
pub var cm_pre_ns: u64 = 0;
pub var cm_probe_ns: u64 = 0;

pub var gf_mono: u64 = 0;
pub var gf_getter_ns: u64 = 0;
pub var gf_slow_ns: u64 = 0;

pub var gf_getter: u64 = 0;
pub var gf_poly: u64 = 0;
pub var gf_slow: u64 = 0;

const ev_values = @import("eval/values.zig");

pub const constToValue = ev_values.constToValue;
pub const applyBinop = ev_values.applyBinop;
pub const rangeValue = ev_values.rangeValue;

const ev_host = @import("eval/host.zig");

pub const MaybeValueResult = ev_host.MaybeValueResult;
pub const UnitResult = ev_host.UnitResult;
pub const ReceiverShape = ev_host.ReceiverShape;
pub const NullHost = ev_host.NullHost;
pub const nullHost = ev_host.nullHost;

const testing = std.testing;

const ev_tests = @import("eval/tests.zig");

test {
    testing.refAllDecls(@This());
    inline for (.{ ev_state, ev_diag, ev_chain, ev_flow, ev_snapshot, ev_frame, ev_enter, ev_leaf, ev_activation, ev_loop, ev_exec, ev_native, ev_inst, ev_values, ev_host, ev_tests, ev_fused }) |m| testing.refAllDecls(m);
}

const ev_fused = @import("eval/fused.zig");

pub const FUSED_MAX_REGS = ev_fused.FUSED_MAX_REGS;
pub const fusedEnabled = ev_fused.fusedEnabled;
pub const fusedExec = ev_fused.fusedExec;
pub const fusedExecOpt = ev_fused.fusedExecOpt;
