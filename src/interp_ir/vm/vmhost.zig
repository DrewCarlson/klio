//! The per-evaluation `VmHost` — the host type the IR evaluator
//! dispatches non-trivial operations through, plus the `VmIntrinsicHost`
//! adapter the stdlib reaches back through to invoke lambdas and the rest
//! of the runtime.
//!
//! The IR evaluator (`ir.eval`) is generic over its host type
//! (`comptime H`); `interp_ir` supplies `H = VmHost` at every
//! `ir.eval.evalWith(VmHost, ...)` call site, so `host.callValue(...)` and
//! the rest resolve as direct comptime-duck-typed method calls with no
//! `{ctx, vtable}` indirection. The per-operation methods are FREE
//! FUNCTIONS over `*VmHost` living in the sibling `host_*.zig` files; this
//! file owns the struct definitions and aliases each free function as a
//! `VmHost` method decl. `VmIntrinsicHost` still uses the
//! `runtime.IntrinsicHost` `{ctx, vtable}` pair, which is a separate seam.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const span = @import("span");
const stdlib = @import("stdlib");

const root = @import("../interp_ir.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const Env = runtime.Env;
const ClassDef = runtime.ClassDef;
const Output = runtime.Output;
const SharedOutput = root.SharedOutput;
const RuntimeError = runtime.RuntimeError;
const IntrinsicHost = runtime.IntrinsicHost;
const HostResultU64 = runtime.HostResultU64;
const InstanceData = runtime.InstanceData;

const Module = ir.Module;
const FuncId = ir.FuncId;
const ClassId = ir.ClassId;
const TypeRef = ir.TypeRef;
const EvalResult = ir.eval.EvalResult;
/// The stdlib `IntrinsicHost` callbacks carry `runtime.EvalResult`
/// (`Value` / `RuntimeError`), distinct from the IR evaluator's
/// `ir.eval.EvalResult` (`Value` / `EvalError`).
const RuntimeEvalResult = runtime.EvalResult;
const EvalError = ir.eval.EvalError;
const UnitResult = ir.eval.UnitResult;
const MaybeValueResult = ir.eval.MaybeValueResult;
const ReceiverShape = ir.eval.ReceiverShape;

const ProgramImage = root.ProgramImage;
const AnonMethods = root.AnonMethods;
const ClassTable = root.ClassTable;
const OuterTable = root.OuterTable;
const SharedClosures = root.SharedClosures;
const ThreadTable = root.ThreadTable;

// Sibling impl files. Each holds the free functions over `*VmHost` /
// `*VmIntrinsicHost` that fill in one slice of host behaviour.
pub const host_call_func = @import("host_call_func.zig");
pub const host_call_member = @import("host_call_member.zig");
pub const host_call_value = @import("host_call_value.zig");
pub const host_classes = @import("host_classes.zig");
pub const host_fields = @import("host_fields.zig");
pub const host_globals = @import("host_globals.zig");
pub const host_instances = @import("host_instances.zig");
pub const host_impl = @import("host_impl.zig");
pub const intrinsic_host = @import("intrinsic_host.zig");
pub const coroutines = @import("coroutines.zig");
pub const trace = @import("trace.zig");

/// Assert (Debug) that the process-wide receiver/coroutine thread-locals are
/// empty at a run boundary, then clear them. Run between programs so leaked
/// state is a loud failure rather than silently threaded into the next run.
pub fn resetReceiverThreadLocals() void {
    host_globals.resetReceiverTls();
    host_instances.resetReceiverTls();
    host_fields.resetReceiverTls();
    host_impl.resetReceiverTls();
    coroutines.resetReceiverTls();
}

/// A borrowed view over a `Vm`'s (or another host's) shared program-state
/// handles. The fields are plain value copies of `ObjRef`/`Shared*`
/// handles — copying them does NOT bump any refcount, so a `SharedHandles`
/// owns nothing and must never be `deinit`'d. The owner (`self`) keeps every
/// cell alive for the view's whole lifetime. Used to stamp out transient,
/// call-scoped `VmHost`/`VmIntrinsicHost`s without per-handle atomic traffic.
pub const SharedHandles = struct {
    globals: ObjRef(Env),
    module: ObjRef(Module),
    instance_id_counter: ObjRef(std.atomic.Value(u64)),
    classes: ObjRef(ClassTable),
    prog: ObjRef(ProgramImage),
    anon_methods: AnonMethods,
    class_default_outer: ObjRef(OuterTable),
    closures: SharedClosures,
    out_sink: SharedOutput,
    threads: ThreadTable,
    allocator: Allocator,

    /// Borrow the shared handles a live `VmHost` holds, without cloning.
    pub fn fromHost(host: *const VmHost) SharedHandles {
        return .{
            .globals = host.globals,
            .module = host.module,
            .instance_id_counter = host.instance_id_counter,
            .classes = host.classes,
            .prog = host.prog,
            .anon_methods = host.anon_methods,
            .class_default_outer = host.class_default_outer,
            .closures = host.closures,
            .out_sink = host.out_sink,
            .threads = host.threads,
            .allocator = host.allocator,
        };
    }

    /// Borrow the shared handles a live `VmIntrinsicHost` holds.
    pub fn fromIntrinsic(host: *const VmIntrinsicHost) SharedHandles {
        return .{
            .globals = host.globals,
            .module = host.module,
            .instance_id_counter = host.instance_id_counter,
            .classes = host.classes,
            .prog = host.prog,
            .anon_methods = host.anon_methods,
            .class_default_outer = host.class_default_outer,
            .closures = host.closures,
            .out_sink = host.out_sink,
            .threads = host.threads,
            .allocator = host.allocator,
        };
    }
};

/// IR Host implementation. Every method native to the Vm lives as a
/// free function over `*VmHost` in a sibling file; this struct holds the
/// shared state those functions read and write for the duration of one
/// evaluation.
pub const VmHost = struct {
    globals: ObjRef(Env),
    module: ObjRef(Module),
    out: Output,
    instance_id_counter: ObjRef(std.atomic.Value(u64)),
    classes: ObjRef(ClassTable),
    prog: ObjRef(ProgramImage),
    anon_methods: AnonMethods,
    class_default_outer: ObjRef(OuterTable),
    closures: SharedClosures,
    out_sink: SharedOutput,
    threads: ThreadTable,
    allocator: Allocator,

    /// Build a transient `VmHost` that BORROWS another host/Vm's shared
    /// handles by value, with no refcount bump. The view never outlives the
    /// owner, so it must not `deinit` any borrowed handle — the owner still
    /// holds each cell. `globals` and `out` are passed explicitly because a
    /// delegated closure body layers its own scoped env, and each call binds
    /// its own output sink.
    pub fn borrowed(state: SharedHandles, globals: ObjRef(Env), out: Output) VmHost {
        return .{
            .globals = globals,
            .module = state.module,
            .out = out,
            .instance_id_counter = state.instance_id_counter,
            .classes = state.classes,
            .prog = state.prog,
            .anon_methods = state.anon_methods,
            .class_default_outer = state.class_default_outer,
            .closures = state.closures,
            .out_sink = state.out_sink,
            .threads = state.threads,
            .allocator = state.allocator,
        };
    }

    // The IR evaluator is generic over its host type (`comptime H`) and
    // invokes these as plain methods (`host.callValue(...)`). Each is the
    // free function over `*VmHost` living in a sibling file; aliasing them
    // here as struct decls makes method-call syntax resolve directly, with
    // no `{ctx, vtable}` indirection. `interp_ir` supplies `H = VmHost` at
    // every `ir.eval.evalWith(VmHost, ...)` call site.
    pub const callValue = host_call_value.callValue;
    pub const callValueNamed = host_call_value.callValueNamed;
    pub const callValueWithThis = host_call_value.callValueWithThis;
    pub const callMember = host_call_member.callMember;
    pub const callMemberNamed = host_call_member.callMemberNamed;
    pub const callMemberOnly = host_call_member.callMemberOnly;
    pub const hostHasMember = host_call_member.hostHasMember;
    pub const memberRef = host_call_member.memberRef;
    pub const callSuper = host_call_member.callSuper;
    pub const qualifiedThis = host_call_member.qualifiedThis;
    pub const newInstance = host_instances.newInstance;
    pub const newInstanceNamed = host_instances.newInstanceNamed;
    pub const buildObject = host_instances.buildObject;
    pub const pushInnerOuterHint = host_instances.pushInnerOuterHint;
    pub const popInnerOuterHint = host_instances.popInnerOuterHint;
    pub const getField = host_fields.getField;
    pub const setField = host_fields.setField;
    pub const instanceOf = host_classes.instanceOf;
    pub const isConcreteCastTarget = host_classes.isConcreteCastTarget;
    pub const registerClass = host_classes.registerClass;
    pub const registerClassCaptured = host_classes.registerClassCaptured;
    pub const lookupGlobal = host_globals.lookupGlobal;
    pub const lookupGlobalThrowing = host_globals.lookupGlobalThrowing;
    pub const storeGlobal = host_globals.storeGlobal;
    pub const isShadowingCapture = host_globals.isShadowingCapture;
    pub const buildClosure = host_call_value.buildClosure;
    pub const buildAstLambdaWithFlagFuncid = host_call_value.buildAstLambdaWithFlagFuncid;
    pub const callableReceiverShape = host_call_value.callableReceiverShape;
    pub const closureNeedsThisCapture = host_call_value.closureNeedsThisCapture;
    pub const overrideClosureThis = host_call_value.overrideClosureThis;
    pub const callFunc = host_call_func.callFunc;
    pub const callFuncNamed = host_call_func.callFuncNamed;
    pub const callFuncTyped = host_call_func.callFuncTyped;
    pub const callNamedOverload = host_call_func.callNamedOverload;
};

/// Stdlib `CallCtx` host adapter for native Vm dispatch. HOF bindings
/// (`map`, `forEach`, scope fns, …) reach back through this adapter to
/// invoke the lambda they were passed.
pub const VmIntrinsicHost = struct {
    module: ObjRef(Module),
    closures: SharedClosures,
    globals: ObjRef(Env),
    classes: ObjRef(ClassTable),
    prog: ObjRef(ProgramImage),
    anon_methods: AnonMethods,
    class_default_outer: ObjRef(OuterTable),
    instance_id_counter: ObjRef(std.atomic.Value(u64)),
    out_sink: SharedOutput,
    threads: ThreadTable,
    allocator: Allocator,

    /// Build a transient `VmIntrinsicHost` that BORROWS another host's shared
    /// handles by value, with no refcount bump. Same non-owning contract as
    /// `VmHost.borrowed`: the view never outlives its owner and must not
    /// `deinit` any borrowed handle.
    pub fn borrowed(state: SharedHandles) VmIntrinsicHost {
        return .{
            .module = state.module,
            .closures = state.closures,
            .globals = state.globals,
            .classes = state.classes,
            .prog = state.prog,
            .anon_methods = state.anon_methods,
            .class_default_outer = state.class_default_outer,
            .instance_id_counter = state.instance_id_counter,
            .out_sink = state.out_sink,
            .threads = state.threads,
            .allocator = state.allocator,
        };
    }

    /// Build a `runtime.IntrinsicHost` `{ctx, vtable}` pair bound to this
    /// adapter.
    pub fn intrinsicHost(self: *VmIntrinsicHost) IntrinsicHost {
        return .{ .ctx = self, .vtable = &intrinsic_vtable };
    }
};

// -------------------------------------------------------------------------
// `runtime.IntrinsicHost` vtable wiring for `VmIntrinsicHost`.
// -------------------------------------------------------------------------

fn ip(ctx: *anyopaque) *VmIntrinsicHost {
    return @ptrCast(@alignCast(ctx));
}

fn ivInvokeCallable(ctx: *anyopaque, callable: *const Value, args: []const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return intrinsic_host.invokeCallable(ip(ctx), callable, args, out);
}
fn ivInvokeCallableWithThis(ctx: *anyopaque, callable: *const Value, args: []const Value, this_value: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return intrinsic_host.invokeCallableWithThis(ip(ctx), callable, args, this_value, out);
}
fn ivInvokeMethod(ctx: *anyopaque, receiver: *const Value, name: []const u8, args: []const Value, out: Output) Allocator.Error!?RuntimeEvalResult {
    return intrinsic_host.invokeMethod(ip(ctx), receiver, name, args, out);
}
fn ivLookupGlobal(ctx: *anyopaque, name: []const u8) ?Value {
    return intrinsic_host.lookupGlobal(ip(ctx), name);
}
fn ivAllocInstanceId(ctx: *anyopaque) u64 {
    return intrinsic_host.allocInstanceId(ip(ctx));
}
fn ivNewSynthInstance(ctx: *anyopaque, class_fqn: []const u8, identity: u64, fields: []const InstanceData.Field) Allocator.Error!Value {
    return intrinsic_host.newSynthInstance(ip(ctx), class_fqn, identity, fields);
}
fn ivRunBlocking(ctx: *anyopaque, block: *const Value, scope: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return intrinsic_host.runBlocking(ip(ctx), block, scope, out);
}
fn ivCoroutineRunRoot(ctx: *anyopaque, scope: ?*const Value, block: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return intrinsic_host.coroutineRunRoot(ip(ctx), scope, block, out);
}
fn ivCoroutineLaunch(ctx: *anyopaque, block: *const Value, scope: *const Value, out: Output) Allocator.Error!?RuntimeError {
    return intrinsic_host.coroutineLaunch(ip(ctx), block, scope, out);
}
fn ivCoroutineArmSlot(ctx: *anyopaque, slot: i64) void {
    intrinsic_host.coroutineArmSlot(ip(ctx), slot);
}
fn ivCoroutineDisarmSlot(ctx: *anyopaque) void {
    intrinsic_host.coroutineDisarmSlot(ip(ctx));
}
fn ivCoroutineResumeSlotValue(ctx: *anyopaque, slot: i64, value: Value) void {
    intrinsic_host.coroutineResumeSlotValue(ip(ctx), slot, value);
}
fn ivCoroutineCancelTimedParksWith(ctx: *anyopaque, cause: ?Value) void {
    intrinsic_host.coroutineCancelTimedParksWith(ip(ctx), cause);
}
fn ivCoroutineResumeExternal(ctx: *anyopaque, slot: i64, value: Value, out: Output) void {
    intrinsic_host.coroutineResumeExternal(ip(ctx), slot, value, out);
}
fn ivCoroutineDrainToIdle(ctx: *anyopaque, out: Output) Allocator.Error!?RuntimeError {
    return intrinsic_host.coroutineDrainToIdle(ip(ctx), out);
}
fn ivSpawnOsThread(ctx: *anyopaque, block: *const Value, out: Output) Allocator.Error!HostResultU64 {
    return intrinsic_host.spawnOsThread(ip(ctx), block, out);
}
fn ivJoinOsThread(ctx: *anyopaque, id: u64) Allocator.Error!?RuntimeError {
    return intrinsic_host.joinOsThread(ip(ctx), id);
}
fn ivOsThreadAlive(ctx: *anyopaque, id: u64) bool {
    return intrinsic_host.osThreadAlive(ip(ctx), id);
}

const intrinsic_vtable: IntrinsicHost.VTable = .{
    .invoke_callable = ivInvokeCallable,
    .invoke_callable_with_this = ivInvokeCallableWithThis,
    .invoke_method = ivInvokeMethod,
    .lookup_global = ivLookupGlobal,
    .alloc_instance_id = ivAllocInstanceId,
    .new_synth_instance = ivNewSynthInstance,
    .run_blocking = ivRunBlocking,
    .coroutine_run_root = ivCoroutineRunRoot,
    .coroutine_launch = ivCoroutineLaunch,
    .coroutine_arm_slot = ivCoroutineArmSlot,
    .coroutine_disarm_slot = ivCoroutineDisarmSlot,
    .coroutine_resume_slot_value = ivCoroutineResumeSlotValue,
    .coroutine_cancel_timed_parks_with = ivCoroutineCancelTimedParksWith,
    .coroutine_resume_external = ivCoroutineResumeExternal,
    .coroutine_drain_to_idle = ivCoroutineDrainToIdle,
    .spawn_os_thread = ivSpawnOsThread,
    .join_os_thread = ivJoinOsThread,
    .os_thread_alive = ivOsThreadAlive,
};

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    _ = host_call_func;
    _ = host_call_member;
    _ = host_call_value;
    _ = host_classes;
    _ = host_fields;
    _ = host_globals;
    _ = host_instances;
    _ = host_impl;
    _ = intrinsic_host;
    _ = coroutines;
    _ = trace;
}
