//! Evaluator control-flow types: results, steps, flat-call requests,
//! activations, and the environment-driven feature gates.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
const bc = @import("../bc.zig");
const span = @import("span");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const BlockId = ir.BlockId;
const Func = ir.Func;
const Module = ir.Module;
const Reg = ir.Reg;

const ev_frame = @import("frame.zig");
const ev_snapshot = @import("snapshot.zig");
const ev_state = @import("state.zig");

const EvalError = ev_state.EvalError;
const Frame = ev_frame.Frame;
const VsMark = ev_state.VsMark;
const TryFrame = ev_snapshot.TryFrame;

/// `Result<Value, EvalError>` as data; OOM stays a Zig `error`.
pub const EvalResult = union(enum) {
    ok: Value,
    err: EvalError,
};

/// Per-instruction control signal from `execInst`: `cont` completed, `raised` left an `EvalError` in
/// the thread's `step_err`, `flat_call` left a request in its `flat_call` for the driver to push.
pub const Step = enum { cont, raised, flat_call };

/// A direct interpreted call the flat driver runs by pushing an activation instead of recursing. The
/// parameters are a run of the caller's registers or an argument area on the value stack at `area`,
/// which the callee's frame then owns and pops.
pub const FlatCallReq = struct {
    func: *const Func,
    /// The module the body resolves against (a closure body's creation module); null = the caller's module.
    run_module: ?*const Module = null,
    /// Owning sub-module for a body lowered into one, kept as the frame's `module_arc` so a suspension resumes there.
    owning: ?*const Module = null,
    params: []const Value,
    captures: []const Value = &.{},
    /// Where the value stack stood before the call pushed an argument area; null when it pushed none.
    area: ?VsMark = null,
    closure: ?runtime.IrClosureRef = null,
    dst: Reg,
};

/// A `FlatCallReq` plus the caller's resume point: where the caller continues once the result lands in `req.dst`.
pub const FlatCallSite = struct {
    req: FlatCallReq,
    ret_block: BlockId,
    ret_idx: usize,
};

/// Where the frame a `Suspended` escape left resumes, and which register receives the resume value.
pub const ParkPoint = struct {
    block: BlockId,
    inst_idx: usize,
    resume_reg: ?Reg,
};

/// One interpreted activation on the flat driver's call stack, held by pointer so the Frame's address
/// stays stable on the GC frame chain. `ret_*` is the resume point in the CALLER frame.
pub const Activation = struct {
    frame: Frame,
    try_stack: std.ArrayList(TryFrame),
    /// The activation below this one in the driver that opened it; null for the driver's first.
    caller: ?*Activation,
    /// The caller's streams when it called from a stream it can go on in at `ret_pc`: a return
    /// then lands in the caller's stream directly. Null sends it through the frame loop.
    ret_streams: ?*const bc.FuncStreams,
    // Four words a call writes as two.
    ret_block: BlockId,
    ret_idx: u32,
    ret_pc: u32,
    ret_dst: Reg,
    /// Where the return goes on in the caller's compiled code, and that code, when compiled
    /// code made the call (`bc.DirectSite.back`): the return goes there without reading the
    /// caller's streams. 0 sends it through the caller's entry table.
    ret_code: usize,
    ret_codeptr: [*]const u32,
};

/// `KLIO_FLAT=0` falls back to native recursion for every call.
var flat_enabled_cached: ?bool = null;

pub inline fn flatEnabled() bool {
    if (flat_enabled_cached) |b| return b;
    return flatEnabledInit();
}

fn flatEnabledInit() bool {
    const raw = runtime.envOnce("KLIO_FLAT");
    const b = !(raw != null and std.mem.eql(u8, raw.?, "0"));
    flat_enabled_cached = b;
    return b;
}

/// Trace gates cached once: `getenvSlice` locks and probes a hashmap per consult, and the env never changes mid-run.
var cv_trace_cached: ?bool = null;

pub inline fn cvTraceOn() bool {
    if (cv_trace_cached) |b| return b;
    return cvTraceInit();
}

fn cvTraceInit() bool {
    const b = runtime.envOnce("KLIO_CALLVALUE_TRACE") != null;
    cv_trace_cached = b;
    return b;
}

var lr_trace_cached: ?bool = null;

var chain_trace_init: bool = false;

var chain_trace_on: bool = false;

pub fn lrTraceOn() bool {
    if (lr_trace_cached) |b| return b;
    const b = runtime.envOnce("KLIO_LR_TRACE") != null;
    lr_trace_cached = b;
    return b;
}

var resume_trace_cached: ?bool = null;

pub fn resumeTraceOn() bool {
    if (resume_trace_cached) |b| return b;
    const b = runtime.envOnce("KLIO_RESUME_TRACE") != null;
    resume_trace_cached = b;
    return b;
}

var miss_trace_init: bool = false;

var miss_trace_val: ?[]const u8 = null;

pub inline fn missTraceWant() ?[]const u8 {
    if (!miss_trace_init) missTraceInit();
    return miss_trace_val;
}

fn missTraceInit() void {
    miss_trace_val = runtime.envOnce("KLIO_MISS_TRACE");
    miss_trace_init = true;
}

var cmg_trace_init: bool = false;

var cmg_trace_val: ?[]const u8 = null;

pub inline fn cmgTraceWant() ?[]const u8 {
    if (!cmg_trace_init) cmgTraceInit();
    return cmg_trace_val;
}

fn cmgTraceInit() void {
    cmg_trace_val = runtime.envOnce("KLIO_CMG_TRACE");
    cmg_trace_init = true;
}

var nu_trace_init: bool = false;

var nu_trace_val: ?[]const u8 = null;

/// Stash a control-flow `EvalError` on the thread's state and signal `Step.raised`.
pub inline fn raiseStep(frame: *Frame, e: EvalError) Step {
    frame.tls.step_err = e;
    return .raised;
}

pub inline fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

pub inline fn errResult(e: EvalError) EvalResult {
    return .{ .err = e };
}

/// Reading a `lateinit` before its first assignment: `UninitializedPropertyAccessException`, kotlinc's message.
pub fn lateinitThrow(allocator: Allocator, name: []const u8) Allocator.Error!EvalError {
    const m = try std.fmt.allocPrint(allocator, "lateinit property {s} has not been initialized", .{name});
    return .{ .Throw = try Value.newException(allocator, .{
        .fqn = try runtime.strInit(allocator, "kotlin.UninitializedPropertyAccessException"),
        .message = .from(try runtime.strInitOwned(allocator, m)),
        .cause = null,
    }) };
}

/// Free a discarded member-dispatch-miss message. The host allocPrints a
/// `Vm::`-prefixed string on a miss; a static literal never carries that prefix.
pub fn freeDispatchMissMsg(allocator: Allocator, msg: []const u8) void {
    if (!runtime.freeScratch()) return;
    if (std.mem.startsWith(u8, msg, "Vm::")) allocator.free(msg);
}
