//! Evaluator control-flow types: results, steps, flat-call requests,
//! activations, and the environment-driven feature gates.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");
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

const EnclosingEntry = ev_state.EnclosingEntry;
const EvalError = ev_state.EvalError;
const Frame = ev_frame.Frame;
const TryFrame = ev_snapshot.TryFrame;

/// `Result<Value, EvalError>` as data; OOM stays a Zig `error`.
pub const EvalResult = union(enum) {
    ok: Value,
    err: EvalError,
};

/// Per-instruction control signal from `execInst`: `cont` completed, `raised` left an `EvalError` in
/// `frame.step_err`, `flat_call` left a request in `frame.flat_call` for the driver to push.
pub const Step = enum { cont, raised, flat_call };

/// A direct interpreted call the flat driver runs by pushing an activation instead of recursing. Arg-buffer
/// ownership passes to the new frame's params; a closure also carries its captures, chain, module and id.
pub const FlatCallReq = struct {
    func: *const Func,
    /// The module the body resolves against (a closure body's creation module); null = the caller's module.
    run_module: ?*const Module = null,
    /// Owning sub-module for a body lowered into one, kept as the frame's `module_arc` so a suspension resumes there.
    owning: ?*const Module = null,
    args: std.ArrayList(Value),
    captures: std.ArrayList(Value) = .empty,
    /// Creation-time receiver-chain seed, borrowed; copied into the frame's chain at activation open.
    chain: []const EnclosingEntry = &.{},
    closure_id: ?u64 = null,
    /// The host pushed an ambient composer for this call; the activation's teardown must pop it.
    composer_pushed: bool = false,
    /// Access-enclosing entries the dispatch pushed; teardown pops them LIFO once the caller's chain is active again.
    pop_enclosing_n: u8 = 0,
    /// A value the activation must keep alive for its whole life (the receiver-bound closure whose capture
    /// vector the frame's captures borrow). Released at teardown or parked-drop, GC-marked while live-parked.
    keepalive: ?Value = null,
    /// Undispatched-start boundary: a suspension crossing this activation parks the segment into the pump
    /// through the host hook, and the CALLER continues with the hook's value instead of unwinding.
    suspend_barrier: bool = false,
    /// Active-scope depth captured BEFORE the prepare's scope push; the barrier park hands it to the pump.
    barrier_scope_base: usize = 0,
    /// Identity of the active-scope entry the prepare pushed (0 = none); teardown removes it, a park hands it on.
    scope_guard_ident: usize = 0,
    /// This barrier activation owns a fresh pump; its completion or suspension runs the pump loop.
    root_pump: bool = false,
    /// Reified type-name globals bound for the call's duration; the host hook restores them at teardown or park.
    typed_saved: ?*anyopaque = null,
    /// The call site's type arguments (module-owned strings) for `attachDeclaredElemTypes` at the frame boundary.
    type_args: []const []const u8 = &.{},
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

/// One interpreted activation on the flat driver's call stack, heap-allocated so the Frame's address stays
/// stable on the GC frame chain while the stack list grows. `ret_*` is the resume point in the CALLER frame.
pub const Activation = struct {
    frame: Frame,
    try_stack: std.ArrayList(TryFrame),
    composer_pushed: bool,
    pop_enclosing_n: u8,
    keepalive: ?Value,
    suspend_barrier: bool,
    barrier_scope_base: usize,
    scope_guard_ident: usize,
    root_pump: bool,
    typed_saved: ?*anyopaque,
    type_args: []const []const u8,
    ret_block: BlockId,
    ret_idx: usize,
    ret_dst: Reg,
};

/// `KLIO_FLAT=0` falls back to native recursion for every call.
var flat_enabled_cached: ?bool = null;

pub fn flatEnabled() bool {
    if (flat_enabled_cached) |b| return b;
    const raw = runtime.envOnce("KLIO_FLAT");
    const b = !(raw != null and std.mem.eql(u8, raw.?, "0"));
    flat_enabled_cached = b;
    return b;
}

/// Trace gates cached once: `getenvSlice` locks and probes a hashmap per consult, and the env never changes mid-run.
var cv_trace_cached: ?bool = null;

pub fn cvTraceOn() bool {
    if (cv_trace_cached) |b| return b;
    const b = runtime.envOnce("KLIO_CALLVALUE_TRACE") != null;
    cv_trace_cached = b;
    return b;
}

var lr_trace_cached: ?bool = null;

var chain_trace_init: bool = false;

var chain_trace_on: bool = false;

pub fn chainTraceOn() bool {
    if (!chain_trace_init) {
        chain_trace_on = runtime.envOnce("KLIO_CHAIN_TRACE") != null;
        chain_trace_init = true;
    }
    return chain_trace_on;
}

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

pub fn missTraceWant() ?[]const u8 {
    if (!miss_trace_init) {
        miss_trace_val = runtime.envOnce("KLIO_MISS_TRACE");
        miss_trace_init = true;
    }
    return miss_trace_val;
}

var cmg_trace_init: bool = false;

var cmg_trace_val: ?[]const u8 = null;

pub fn cmgTraceWant() ?[]const u8 {
    if (!cmg_trace_init) {
        cmg_trace_val = runtime.envOnce("KLIO_CMG_TRACE");
        cmg_trace_init = true;
    }
    return cmg_trace_val;
}

var nu_trace_init: bool = false;

var nu_trace_val: ?[]const u8 = null;

pub fn takeHostFlatArm() bool {
    const a = ev_state.evtlsPtr().host_flat_armed;
    ev_state.evtlsPtr().host_flat_armed = false;
    return a;
}

pub fn stashHostFlatReq(req: FlatCallReq) void {
    ev_state.evtlsPtr().host_flat_req = req;
}

/// Stash a control-flow `EvalError` on the frame and signal `Step.raised`.
pub inline fn raiseStep(frame: *Frame, e: EvalError) Step {
    frame.step_err = e;
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

/// Restore the frame's enclosing-receiver chain to its try-entry length: an unwind into a catch or finally
/// skipped every `EnclosingPop` inside the try body, and the stale subject would shadow later reads.
pub fn truncChainTo(frame: *Frame, chain_len: usize) void {
    if (frame.enclosing_this.items.len > chain_len) {
        frame.enclosing_this.shrinkRetainingCapacity(chain_len);
    }
}
