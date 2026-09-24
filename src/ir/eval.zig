//! IR evaluator: runs a `Func`'s blocks over its register file and yields a
//! `Value`, trapping an `Inst` the lowering pass never emits as `EvalError.Unsupported`.
//!
//! This root re-exports the `eval/` submodules (state, frame, activation, enter,
//! exec, flow, inst, fused, leaf, loop, native, snapshot, chain, diag, values,
//! host) and holds the process-wide counters and the hooks the host installs.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("ir.zig");
const span = @import("span");
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

const callerThisValue = exec_call.callerThisValue;
const constStr = exec_call.constStr;
const declaringClassName = exec_call.declaringClassName;
const envVarSet = exec_call.envVarSet;
const fastIndexGet = exec_call.fastIndexGet;
const freeDispatchMissMsg = exec_call.freeDispatchMissMsg;
const ownReceiverEntry = exec_call.ownReceiverEntry;
const readArgRun = exec_call.readArgRun;
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
pub const dispatchCacheStable = ev_diag.dispatchCacheStable;
pub const nowMonotonicMs = ev_diag.nowMonotonicMs;
pub const op_route_names = ev_diag.op_route_names;
pub const opProfDump = ev_diag.opProfDump;
pub const callStatsProbe = ev_diag.callStatsProbe;
pub const DispatchKind = ev_diag.DispatchKind;
pub const dispatchBump = ev_diag.dispatchBump;
pub const extAuditArmed = ev_diag.extAuditArmed;
pub const extAuditRow = ev_diag.extAuditRow;
pub const extAuditServed = ev_diag.extAuditServed;
pub const extAuditTake = ev_diag.extAuditTake;
pub const requireResolvedRaises = ev_diag.requireResolvedRaises;
pub const unresolvedNoteSlow = ev_diag.unresolvedNoteSlow;
pub const unresolvedCount = ev_diag.unresolvedCount;
pub const dispatchNote = ev_diag.dispatchNote;
pub const callStatsDump = ev_diag.callStatsDump;
pub const frameCountInit = ev_diag.frameCountInit;
pub const frameCountDump = ev_diag.frameCountDump;
pub const fnProfDump = ev_diag.fnProfDump;
pub const errTraceOn = ev_diag.errTraceOn;
pub const dumpFrameChainForDiag = ev_diag.dumpFrameChainForDiag;
pub const FuncLoc = ev_diag.FuncLoc;
pub const funcFirstLoc = ev_diag.funcFirstLoc;
pub const dumpFrameChainForDiagAlways = ev_diag.dumpFrameChainForDiagAlways;
pub const dumpCurrentFrameParamsForDiag = ev_diag.dumpCurrentFrameParamsForDiag;
pub const stackTraceArray = ev_diag.stackTraceArray;
pub const formatThrowable = ev_diag.formatThrowable;
pub const formatThrowableWith = ev_diag.formatThrowableWith;
pub const HeaderRenderer = ev_diag.HeaderRenderer;
pub const attachStackTrace = ev_diag.attachStackTrace;

/// Per-test wall-clock deadline in monotonic milliseconds, 0 = disarmed; the eval loop's counter gate checks it on every thread.
/// Deliberately not cleared when it fires, so a dispatch arm that swallows the first error meets it again at the next gate.
pub var test_wall_deadline_ms = std.atomic.Value(i64).init(0);

/// Threads currently inside an outermost `runFrame`. The wall-cap drain polls this to know every abandoned thread
/// has left interpreted code before it clears the abandonment flags, so no straggler runs on into a later test.
pub var threads_in_eval = std.atomic.Value(u32).init(0);

/// How many times the wall cap has fired for the current test, on any thread. The first `wall_cap_catchable_fires`
/// throw a catchable timeout; the next hard-aborts. The test runner resets it when it arms a deadline.
pub var wall_cap_fires = std.atomic.Value(u32).init(0);

/// Fires that throw a catchable timeout before the wall cap hard-aborts. A test may catch the first and go on
/// (a harness that runs the body once per configuration records the failure and starts the next run), and only
/// a throw unwinds through the program's `finally` blocks, which restore the state its classmates run against.
pub const wall_cap_catchable_fires: u32 = 3;

/// How far each catchable fire moves the deadline: the time the program has to unwind through its handlers
/// before the next fire.
pub var wall_cap_unwind_ms = std.atomic.Value(i64).init(20_000);

/// `KLIO_FRAME_COUNT`: `frame_count_total` counts `runFrameExec` entries, `frame_alloc_total` register-bank acquisitions (one per real frame). A flat call re-enters its caller's frame, so entries run higher.
pub var frame_count_total: u64 = 0;
pub var frame_alloc_total: u64 = 0;
pub var frame_count_on: bool = false;

pub var frame_watch_want: []const u8 = "";

/// Executed-instruction total: the denominator that turns a sampled opcode profile into a per-instruction cost.
pub threadlocal var inst_count: u64 = 0;
pub var inst_count_all: std.atomic.Value(u64) = .init(0);

/// Delivery-route tag for `KLIO_RESUME_TRACE`: which host path drove the current resume (park slot, persisted take, adopt, inline claim).
pub threadlocal var resume_route: []const u8 = "?";

const ev_chain = @import("eval/chain.zig");

pub const EnclosingChainIter = ev_chain.EnclosingChainIter;
pub const enclosingChainIter = ev_chain.enclosingChainIter;
pub const pushEnclosing = ev_chain.pushEnclosing;
pub const pushEnclosingSubject = ev_chain.pushEnclosingSubject;
pub const pushDispatch = ev_chain.pushDispatch;
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
pub const missTraceWant = ev_flow.missTraceWant;
pub const cmgTraceWant = ev_flow.cmgTraceWant;
pub const takeHostFlatArm = ev_flow.takeHostFlatArm;
pub const stashHostFlatReq = ev_flow.stashHostFlatReq;
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
pub const fuseGateDump = ev_enter.fuseGateDump;
pub const boolThisTrap = ev_enter.boolThisTrap;
pub const dumpFnIfRequested = ev_enter.dumpFnIfRequested;
pub const evalWithCaptures = ev_enter.evalWithCaptures;
pub const evalWithCapturesIn = ev_enter.evalWithCapturesIn;
pub const evalWithCapturesChained = ev_enter.evalWithCapturesChained;

const ev_leaf = @import("eval/leaf.zig");

const ev_activation = @import("eval/activation.zig");

pub const takeInFlightSuspend = ev_activation.takeInFlightSuspend;
pub const resumeContinuation = ev_activation.resumeContinuation;

const ev_loop = @import("eval/loop.zig");

const ev_exec = @import("eval/exec.zig");

const ev_inst = @import("eval/inst.zig");

pub const binopValue = ev_inst.binopValue;

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

/// Hand-built modules of code lowered from sema, for the VM's tests.
pub const hand = @import("eval/hand.zig");

/// The arms of the resolved instructions, for the host's reads outside a
/// frame (`staticValue`).
pub const resolved_ops = @import("eval/resolved.zig");

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    testing.refAllDecls(@import("eval/activation.zig"));
    testing.refAllDecls(@import("eval/chain.zig"));
    testing.refAllDecls(@import("eval/diag.zig"));
    testing.refAllDecls(@import("eval/enter.zig"));
    testing.refAllDecls(@import("eval/exec.zig"));
    testing.refAllDecls(@import("eval/flow.zig"));
    testing.refAllDecls(@import("eval/frame.zig"));
    testing.refAllDecls(@import("eval/fused.zig"));
    testing.refAllDecls(@import("eval/hand.zig"));
    testing.refAllDecls(@import("eval/host.zig"));
    testing.refAllDecls(@import("eval/inst.zig"));
    testing.refAllDecls(@import("eval/leaf.zig"));
    testing.refAllDecls(@import("eval/loop.zig"));
    testing.refAllDecls(@import("eval/resolved.zig"));
    testing.refAllDecls(@import("eval/snapshot.zig"));
    testing.refAllDecls(@import("eval/state.zig"));
    testing.refAllDecls(@import("eval/tests.zig"));
    testing.refAllDecls(@import("eval/values.zig"));
}

const ev_fused = @import("eval/fused.zig");

pub const FUSED_MAX_REGS = ev_fused.FUSED_MAX_REGS;
pub const fusedEnabled = ev_fused.fusedEnabled;
pub const fused = ev_fused;
pub const fusedExec = ev_fused.fusedExec;
pub const fusedExecOpt = ev_fused.fusedExecOpt;
