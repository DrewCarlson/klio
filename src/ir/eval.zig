//! IR evaluator: runs a `Func`'s blocks over its register file and yields a
//! `Value`, trapping an `Inst` the lowering pass never emits as `EvalError.Unsupported`.
//!
//! This root re-exports the `eval/` submodules (state, frame, activation, enter,
//! exec, flow, inst, snapshot, diag, values, resolved, hand, host) and holds the process-wide counters and the hooks the host installs.

const std = @import("std");
const runtime = @import("runtime");


const Value = runtime.Value;


pub const fastIndexGet = @import("eval/values.zig").fastIndexGet;
pub const fastIndexSet = @import("eval/values.zig").fastIndexSet;

const ev_state = @import("eval/state.zig");

pub const EvalError = ev_state.EvalError;
pub const currentFrameFunc = ev_state.currentFrameFunc;
pub const fillCensusBump = ev_state.fillCensusBump;
pub const gcInstallFrameRoot = ev_state.gcInstallFrameRoot;
pub const gcUninstallFrameRoot = ev_state.gcUninstallFrameRoot;

pub var regs_fill_slots: u64 = 0;

const ev_diag = @import("eval/diag.zig");

pub const wallCapAbandon = ev_diag.wallCapAbandon;
pub const nowMonotonicMs = ev_diag.nowMonotonicMs;
pub const op_route_names = ev_diag.op_route_names;
pub const opProfDump = ev_diag.opProfDump;
pub const jitStatsDump = @import("eval/baseline.zig").statsDump;
pub const jitDefaultOn = @import("eval/baseline.zig").defaultOn;
pub const frameAuditSummary = @import("eval/state.zig").frameAuditSummary;
pub const extAuditRow = ev_diag.extAuditRow;
pub const extAuditTake = ev_diag.extAuditTake;
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

/// Set by a test that trips the wall cap on purpose: each fire throws or aborts as ever, without the
/// hang report it otherwise prints.
pub var wall_cap_quiet = std.atomic.Value(bool).init(false);

/// `KLIO_FRAME_COUNT`: `frame_count_total` counts `runFrameExec` entries, `frame_alloc_total` register-bank acquisitions (one per real frame). A flat call re-enters its caller's frame, so entries run higher.
pub var frame_count_total: u64 = 0;
pub var frame_alloc_total: u64 = 0;
pub var frame_count_on: bool = false;

/// Whether any diagnostic hook on the call path is on (the frame counts, KLIO_FN_PROF, the trace
/// and audit knobs a frame entry and teardown answer, KLIO_DUMP_FN, KLIO_CALL_STATS, fault
/// injection, KLIO_FLAT=0). The run's hooks settle it before the program; until then every
/// check runs.
pub var call_hooks_on: bool = true;

pub var frame_watch_want: []const u8 = "";

/// Executed-instruction total: the denominator that turns a sampled opcode profile into a per-instruction cost.
pub threadlocal var inst_count: u64 = 0;
pub var inst_count_all: std.atomic.Value(u64) = .init(0);

/// Delivery-route tag for `KLIO_RESUME_TRACE`: which host path drove the current resume (park slot, persisted take, adopt, inline claim).
pub threadlocal var resume_route: []const u8 = "?";


const ev_flow = @import("eval/flow.zig");

pub const EvalResult = ev_flow.EvalResult;
pub const Step = ev_flow.Step;
pub const FlatCallReq = ev_flow.FlatCallReq;
pub const flatEnabled = ev_flow.flatEnabled;
pub const missTraceWant = ev_flow.missTraceWant;
pub const cmgTraceWant = ev_flow.cmgTraceWant;
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

pub const Frame = ev_frame.Frame;

const ev_enter = @import("eval/enter.zig");

pub const eval = ev_enter.eval;
pub const evalWith = ev_enter.evalWith;
pub const boolThisTrap = ev_enter.boolThisTrap;
pub const dumpFnIfRequested = ev_enter.dumpFnIfRequested;
pub const evalWithCaptures = ev_enter.evalWithCaptures;
pub const evalWithCapturesIn = ev_enter.evalWithCapturesIn;
pub const evalClosure = ev_enter.evalClosure;
pub const evalSlices = ev_enter.evalSlices;

const ev_activation = @import("eval/activation.zig");

pub const takeInFlightSuspend = ev_activation.takeInFlightSuspend;
pub const resumeContinuation = ev_activation.resumeContinuation;
pub const resumeSingleLive = ev_activation.resumeSingleLive;



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
    testing.refAllDecls(@import("eval/diag.zig"));
    testing.refAllDecls(@import("eval/enter.zig"));
    testing.refAllDecls(@import("eval/exec.zig"));
    testing.refAllDecls(@import("eval/flow.zig"));
    testing.refAllDecls(@import("eval/frame.zig"));
    testing.refAllDecls(@import("eval/hand.zig"));
    testing.refAllDecls(@import("eval/host.zig"));
    testing.refAllDecls(@import("eval/inst.zig"));
    testing.refAllDecls(@import("eval/resolved.zig"));
    testing.refAllDecls(@import("eval/snapshot.zig"));
    testing.refAllDecls(@import("eval/state.zig"));
    testing.refAllDecls(@import("eval/stream.zig"));
    testing.refAllDecls(@import("eval/tests.zig"));
    testing.refAllDecls(@import("eval/baseline_test.zig"));
    testing.refAllDecls(@import("eval/intrinsics.zig"));
    testing.refAllDecls(@import("eval/kinds.zig"));
    testing.refAllDecls(@import("eval/opt/graph.zig"));
    testing.refAllDecls(@import("eval/opt/build.zig"));
    testing.refAllDecls(@import("eval/opt/regalloc.zig"));
    testing.refAllDecls(@import("eval/opt/passes.zig"));
    testing.refAllDecls(@import("eval/values.zig"));
}


