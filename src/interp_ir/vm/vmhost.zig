//! The per-evaluation `VmHost` the IR evaluator dispatches non-trivial operations
//! through, plus the `VmIntrinsicHost` adapter the stdlib reaches back through to
//! invoke lambdas. `ir.eval` is generic over its host type, so `host.callNative(...)`
//! resolves as a direct comptime call with no vtable indirection: the per-operation
//! methods are free functions over `*VmHost` in the sibling `host_*.zig` files,
//! aliased here as decls. `VmIntrinsicHost` keeps the `{ctx, vtable}` pair instead.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const root = @import("../interp_ir.zig");

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const Output = runtime.Output;
const SharedOutput = root.SharedOutput;
const RuntimeError = runtime.RuntimeError;
const IntrinsicHost = runtime.IntrinsicHost;
const HostResultU64 = runtime.HostResultU64;
const InstanceData = runtime.InstanceData;

const Module = ir.Module;
const FuncId = ir.FuncId;
const EvalResult = ir.eval.EvalResult;
/// The stdlib callbacks carry `runtime.EvalResult`, not the evaluator's.
const RuntimeEvalResult = runtime.EvalResult;

const SharedClosures = root.SharedClosures;
const ThreadTable = root.ThreadTable;

pub const host_call_func = @import("host_call_func.zig");
pub const host_call_value = @import("host_call_value.zig");
const builtin_members = @import("builtin_members.zig");
const host_util = @import("host_util.zig");
pub const host_impl = @import("host_impl.zig");
pub const host_resolved = @import("host_resolved.zig");
pub const intrinsic_host = @import("intrinsic_host.zig");
pub const coroutines = @import("coroutines.zig");
pub const compose = @import("compose.zig");
pub const scheduler = @import("scheduler.zig");
pub const trace = @import("trace.zig");

/// Emit one `[PATH]` record (`KLIO_TRACE_PATH`): `path_tag` names the site,
/// `decl_fqn`/`fid` the chosen declaration (`fid` null for a native intrinsic).
pub fn emitPath(
    allocator: Allocator,
    path_tag: []const u8,
    decl_fqn: []const u8,
    fid: ?FuncId,
    receiver: ?*const Value,
    args: []const Value,
) void {
    if (!trace.pathEnabled()) return;
    const recv_label: []const u8 = if (receiver) |r|
        trace.recvLabel(allocator, r.*) catch return
    else
        "none";
    defer if (receiver) |r| trace.freeLabel(allocator, r.*, recv_label);
    emitPathLabeled(allocator, path_tag, decl_fqn, fid, recv_label, args);
}

/// Super-qualified dispatch labels the record with the static target class
/// (`super(Base)`), since keying on the runtime class would collide with `recv.f()`.
pub fn emitPathLabeled(
    allocator: Allocator,
    path_tag: []const u8,
    decl_fqn: []const u8,
    fid: ?FuncId,
    recv_label: []const u8,
    args: []const Value,
) void {
    if (!trace.pathEnabled()) return;
    // One runtime-type label per argument, `-` for a zero-arg call.
    var tags: std.ArrayList(u8) = .empty;
    defer tags.deinit(allocator);
    if (args.len == 0) {
        tags.appendSlice(allocator, "-") catch return;
    }
    for (args, 0..) |a, i| {
        if (i != 0) tags.append(allocator, ',') catch return;
        const label = trace.recvLabel(allocator, a) catch return;
        defer trace.freeLabel(allocator, a, label);
        tags.appendSlice(allocator, label) catch return;
    }
    const fn_name = pathSimpleName(decl_fqn);
    const caller: []const u8 = if (ir.eval.currentFrameFunc()) |cf|
        (if (cf.fqn.len != 0) cf.fqn else cf.name)
    else
        "-";
    if (fid) |f| {
        trace.path("fn={s} recv={s} argc={d} args={s} decl={s}#{d} path={s} caller={s}", .{
            fn_name, recv_label, args.len, tags.items, decl_fqn, f.int(), path_tag, caller,
        });
    } else {
        trace.path("fn={s} recv={s} argc={d} args={s} decl={s} path={s} caller={s}", .{
            fn_name, recv_label, args.len, tags.items, decl_fqn, path_tag, caller,
        });
    }
}

fn pathSimpleName(fqn: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, fqn, '.')) |i| return fqn[i + 1 ..];
    return fqn;
}

/// Assert (Debug) the receiver/coroutine thread-locals are empty at a run boundary.
pub fn resetReceiverThreadLocals() void {
    coroutines.resetReceiverTls();
    compose.resetAtRunBoundary();
}

/// Drop the process-global caches that belong to the finished run. PROGRAM boundary
/// only, never a Vm deinit.
pub fn resetRunGlobalCaches() void {
    // Invalidate every pointer-keyed dispatch cache in one stroke: entries carry a
    // generation stamp, so stale ones never hit, including on parked pool workers a
    // per-thread clear cannot reach, and a reused cell address cannot replay a
    // resolution into freed IR.
    host_util.bumpDispatchCacheGen();
    // The bytecode stream cache keys on blocks-pointer identity, so a reused address
    // must not replay it.
    ir.bc.resetCacheForTest();
    ir.eval.resetSuspendLivenessCache();
    stdlib.resetEmptyCollectionSingletons();
    stdlib.resetEmptySequenceSingleton();
}

/// A borrowed view over another host's shared program-state handles. The fields are
/// value copies that bump no refcount, so a `SharedHandles` owns nothing and must never
/// be `deinit`'d; the owner keeps every cell alive for the view's lifetime.
pub const SharedHandles = struct {
    module: ObjRef(Module),
    instance_id_counter: ObjRef(std.atomic.Value(u64)),
    closures: SharedClosures,
    out_sink: SharedOutput,
    threads: ThreadTable,
    /// The run state of code lowered from sema, null for a module lowered
    /// the other way.
    resolved_state: ?ir.resolved.StateRef,
    allocator: Allocator,

    pub fn fromHost(host: *const VmHost) SharedHandles {
        return .{
            .module = host.module,
            .instance_id_counter = host.instance_id_counter,
            .closures = host.closures,
            .out_sink = host.out_sink,
            .threads = host.threads,
            .resolved_state = host.resolved_state,
            .allocator = host.allocator,
        };
    }

    pub fn fromIntrinsic(host: *const VmIntrinsicHost) SharedHandles {
        return .{
            .module = host.module,
            .instance_id_counter = host.instance_id_counter,
            .closures = host.closures,
            .out_sink = host.out_sink,
            .threads = host.threads,
            .resolved_state = host.resolved_state,
            .allocator = host.allocator,
        };
    }
};

/// The shared state the sibling free functions read and write for one evaluation.
pub const VmHost = struct {
    module: ObjRef(Module),
    out: Output,
    instance_id_counter: ObjRef(std.atomic.Value(u64)),
    closures: SharedClosures,
    out_sink: SharedOutput,
    threads: ThreadTable,
    /// The run state of code lowered from sema, null for a module lowered
    /// the other way.
    resolved_state: ?ir.resolved.StateRef,
    allocator: Allocator,
    /// This thread's keepalive handle; every member call pins across a host re-entry.
    ka: runtime.KeepaliveHandle,

    /// Transient `VmHost` BORROWING another host's handles by value, with no refcount
    /// bump: it never outlives the owner and must not `deinit` a borrowed handle.
    pub fn borrowed(state: SharedHandles, out: Output) VmHost {
        return .{
            .module = state.module,
            .out = out,
            .instance_id_counter = state.instance_id_counter,
            .closures = state.closures,
            .out_sink = state.out_sink,
            .threads = state.threads,
            .resolved_state = state.resolved_state,
            .allocator = state.allocator,
            .ka = runtime.keepaliveHandle(),
        };
    }

    pub const resolvedState = host_resolved.resolvedState;
    pub const callNative = host_resolved.callNative;
    pub const callNativeSite = host_resolved.callNativeSite;
    pub const tryNative = host_resolved.tryNative;
    pub const callWellKnown = host_resolved.callWellKnown;
    pub const wellKnownObject = host_resolved.wellKnownObject;
    pub const constructWellKnown = host_resolved.constructWellKnown;
    pub const wellKnownStatic = host_resolved.wellKnownStatic;
    pub const caughtValue = host_resolved.caughtValue;
    pub const runResolved = host_resolved.runResolved;
    pub const makeResolvedClosure = host_resolved.makeResolvedClosure;
    pub const resolvedClosure = host_resolved.resolvedClosure;
    pub const resumeValue = host_resolved.resumeValue;
    pub const deepValueEquals = builtin_members.deepValueEquals;
    pub const funcRunsItsBody = host_resolved.funcRunsItsBody;
    pub const ownerModuleForFunc = host_resolved.ownerModuleForFunc;
    /// The fused tier runs a body for a host that declares this.
    pub const fieldSiteRoute = {};
};

/// Stdlib `CallCtx` host adapter: HOF bindings reach through it to invoke a lambda.
pub const VmIntrinsicHost = struct {
    /// Methods, so a compiled program can present its own host.
    pub fn evalClosureRaw(self: *VmIntrinsicHost, block: *const Value, args: []const Value, scope: ?*const Value, out: Output) Allocator.Error!intrinsic_host.RawResult {
        return intrinsic_host.evalClosureRaw(self, block, args, scope, out);
    }

    pub fn resumeRaw(self: *VmIntrinsicHost, state: *ir.eval.SuspendState, value: Value, out: Output) Allocator.Error!intrinsic_host.RawResult {
        return intrinsic_host.resumeRaw(self, state, value, out);
    }

    pub fn invokeCallable(self: *VmIntrinsicHost, block: *const Value, args: []const Value, out: Output) Allocator.Error!runtime.EvalResult {
        return intrinsic_host.invokeCallable(self, block, args, out);
    }

    module: ObjRef(Module),
    closures: SharedClosures,
    instance_id_counter: ObjRef(std.atomic.Value(u64)),
    out_sink: SharedOutput,
    threads: ThreadTable,
    /// The run state of code lowered from sema, null for a module lowered
    /// the other way.
    resolved_state: ?ir.resolved.StateRef,
    allocator: Allocator,

    /// Borrows handles by value, under `VmHost.borrowed`'s non-owning contract.
    pub fn borrowed(state: SharedHandles) VmIntrinsicHost {
        return .{
            .module = state.module,
            .closures = state.closures,
            .instance_id_counter = state.instance_id_counter,
            .out_sink = state.out_sink,
            .threads = state.threads,
            .resolved_state = state.resolved_state,
            .allocator = state.allocator,
        };
    }

    /// A view of `host`'s handles, under `borrowed`'s contract.
    pub fn borrowedFrom(host: *const VmHost) VmIntrinsicHost {
        return borrowed(SharedHandles.fromHost(host));
    }

    /// A host over `host`'s handles holding a reference to each, for a
    /// caller that keeps it past the call (a coroutine pump, a sequence
    /// builder's cursor). `release` gives them back.
    pub fn owning(host: *const VmHost) VmIntrinsicHost {
        return .{
            .module = host.module.clone(),
            .closures = host.closures.clone(),
            .instance_id_counter = host.instance_id_counter.clone(),
            .out_sink = host.out_sink.clone(),
            .threads = host.threads.clone(),
            .resolved_state = host.resolved_state,
            .allocator = host.allocator,
        };
    }

    pub fn release(self: *VmIntrinsicHost) void {
        self.module.deinit();
        self.closures.deinit();
        self.instance_id_counter.deinit();
        self.out_sink.deinit();
        self.threads.deinit();
    }

    pub fn intrinsicHost(self: *VmIntrinsicHost) IntrinsicHost {
        return .{ .ctx = self, .vtable = &intrinsic_vtable };
    }
};

fn ip(ctx: *anyopaque) *VmIntrinsicHost {
    return @ptrCast(@alignCast(ctx));
}

fn ivInvokeCallable(ctx: *anyopaque, callable: *const Value, args: []const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return intrinsic_host.invokeCallable(ip(ctx), callable, args, out);
}
fn ivInvokeCallableWithThis(ctx: *anyopaque, callable: *const Value, args: []const Value, this_value: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return intrinsic_host.invokeCallableWithThis(ip(ctx), callable, args, this_value, out);
}
fn ivWellKnownObject(ctx: *anyopaque, object: runtime.WellKnownObject) Allocator.Error!?Value {
    return intrinsic_host.wellKnownObject(ip(ctx), object);
}
fn ivCallWellKnown(ctx: *anyopaque, receiver: *const Value, member: runtime.WellKnown, args: []const Value, out: Output) Allocator.Error!?RuntimeEvalResult {
    return intrinsic_host.callWellKnown(ip(ctx), receiver, member, args, out);
}
fn ivAllocInstanceId(ctx: *anyopaque) u64 {
    return intrinsic_host.allocInstanceId(ip(ctx));
}
fn ivNewHostInstance(ctx: *anyopaque, kind: runtime.HostInstance, identity: u64, fields: []const InstanceData.Field) Allocator.Error!Value {
    return intrinsic_host.newHostInstance(ip(ctx), kind, identity, fields);
}
fn ivConstructWellKnown(ctx: *anyopaque, class: runtime.WellKnownClass, args: []const Value, out: Output) Allocator.Error!?RuntimeEvalResult {
    return intrinsic_host.constructWellKnown(ip(ctx), class, args, out);
}
fn ivRunBlocking(ctx: *anyopaque, block: *const Value, scope: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return intrinsic_host.runBlocking(ip(ctx), block, scope, out);
}
fn ivCoroutineRunRoot(ctx: *anyopaque, scope: ?*const Value, block: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return intrinsic_host.coroutineRunRoot(ip(ctx), scope, block, out);
}
fn ivCoroutineStartRootOrSuspended(ctx: *anyopaque, scope: ?*const Value, block: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return intrinsic_host.coroutineStartRootOrSuspended(ip(ctx), scope, block, out);
}
fn ivCoroutineHasDriver(ctx: *anyopaque) bool {
    _ = ctx;
    return coroutines.coroutineHasDriver();
}
fn ivCoroutineOnEventLoop(ctx: *anyopaque) bool {
    _ = ctx;
    return coroutines.coroutineOnEventLoop();
}
fn ivCoroutineOwnerRoute(ctx: *anyopaque, on: bool) void {
    _ = ctx;
    coroutines.coroutineOwnerRoute(on);
}
fn ivCoroutinePostMain(ctx: *anyopaque, block: *const Value) Allocator.Error!bool {
    _ = ctx;
    return coroutines.mainPost(block.*);
}
fn ivCoroutineLaunch(ctx: *anyopaque, block: *const Value, scope: *const Value, out: Output) Allocator.Error!?RuntimeError {
    return intrinsic_host.coroutineLaunch(ip(ctx), block, scope, out);
}
fn ivCoroutineSpawnTimeout(ctx: *anyopaque, block: *const Value, out: Output) Allocator.Error!?RuntimeError {
    return intrinsic_host.coroutineSpawnTimeout(ip(ctx), block, out);
}
fn ivCoroutinePoolNew(ctx: *anyopaque, n_threads: usize, name: []const u8) Allocator.Error!i64 {
    _ = ctx;
    return scheduler.newDispatcherPool(n_threads, name);
}
fn ivCoroutinePoolDispatch(ctx: *anyopaque, pool: i64, block: *const Value) Allocator.Error!bool {
    return intrinsic_host.coroutineDispatchToPool(ip(ctx), pool, block);
}
fn ivCoroutinePoolClose(ctx: *anyopaque, pool: i64) void {
    _ = ctx;
    scheduler.closeDispatcherPool(pool);
}
fn ivCoroutineSpawnTimer(ctx: *anyopaque, block: *const Value, out: Output) Allocator.Error!?RuntimeError {
    return intrinsic_host.coroutineSpawnTimer(ip(ctx), block, out);
}
fn ivCoroutineArmSlot(ctx: *anyopaque, slot: i64) void {
    intrinsic_host.coroutineArmSlot(ip(ctx), slot);
}
fn ivCoroutineDisarmSlot(ctx: *anyopaque) void {
    intrinsic_host.coroutineDisarmSlot(ip(ctx));
}
fn ivCoroutineLastRootParkedOnce(ctx: *anyopaque) bool {
    return intrinsic_host.coroutineLastRootParkedOnce(ip(ctx));
}
fn ivCoroutineNoteSuspensionHit(ctx: *anyopaque) void {
    intrinsic_host.coroutineNoteSuspensionHit(ip(ctx));
}
fn ivCoroutinePushScope(ctx: *anyopaque, scope: *const Value) void {
    intrinsic_host.coroutinePushScope(ip(ctx), scope);
}
fn ivCoroutinePopScope(ctx: *anyopaque) void {
    intrinsic_host.coroutinePopScope(ip(ctx));
}
fn ivCoroutineResumeSlotValue(ctx: *anyopaque, slot: i64, value: Value) void {
    intrinsic_host.coroutineResumeSlotValue(ip(ctx), slot, value);
}
fn ivMarkSlotOwnerSchedulerBacked(ctx: *anyopaque, slot: i64) void {
    _ = ctx;
    intrinsic_host.markSlotOwnerSchedulerBacked(slot);
}
fn ivActiveCoroScope(ctx: *anyopaque) ?Value {
    return intrinsic_host.activeCoroScope(ip(ctx));
}
fn ivCoroutineResumeExternal(ctx: *anyopaque, slot: i64, value: Value, out: Output) void {
    intrinsic_host.coroutineResumeExternal(ip(ctx), slot, value, out);
}
fn ivCoroutineResumeContinuation(ctx: *anyopaque, slot: i64, value: Value, out: Output) ?Value {
    return intrinsic_host.coroutineResumeContinuation(ip(ctx), slot, value, out);
}
fn ivCoroutineDrainToIdle(ctx: *anyopaque, out: Output) Allocator.Error!?RuntimeError {
    return intrinsic_host.coroutineDrainToIdle(ip(ctx), out);
}
fn ivCoroutineDispatchPooled(ctx: *anyopaque, block: *const Value, io_kind: bool, out: Output) Allocator.Error!?RuntimeError {
    return intrinsic_host.coroutineDispatchPooled(ip(ctx), block, io_kind, out);
}
fn ivSpawnOsThread(ctx: *anyopaque, block: *const Value, name: []const u8, out: Output) Allocator.Error!HostResultU64 {
    return intrinsic_host.spawnOsThread(ip(ctx), block, name, out);
}
fn ivJoinOsThread(ctx: *anyopaque, id: u64) Allocator.Error!?RuntimeError {
    return intrinsic_host.joinOsThread(ip(ctx), id);
}
fn ivOsThreadAlive(ctx: *anyopaque, id: u64) bool {
    return intrinsic_host.osThreadAlive(ip(ctx), id);
}
fn ivBuilderStep(ctx: *anyopaque, state: runtime.BuilderStateRef, out: Output) Allocator.Error!runtime.BuilderStepResult {
    return @import("coroutines.zig").builderStep(ip(ctx), state, out);
}
fn ivPersist(ctx: *anyopaque) IntrinsicHost {
    const src = ip(ctx);
    // Clone the handles into an allocator-owned host so it outlives the `main`
    // activation whose transient host this was. The copy is never released; an
    // OS-driven frame loop owns it until the process exits.
    const p = src.allocator.create(VmIntrinsicHost) catch return .{ .ctx = src, .vtable = &intrinsic_vtable };
    p.* = .{
        .module = src.module.clone(),
        .closures = src.closures.clone(),
        .instance_id_counter = src.instance_id_counter.clone(),
        .out_sink = src.out_sink.clone(),
        .threads = src.threads.clone(),
        .resolved_state = if (src.resolved_state) |rs| rs.clone() else null,
        .allocator = src.allocator,
    };
    return .{ .ctx = p, .vtable = &intrinsic_vtable };
}
fn ivCallableReturnTy(ctx: *anyopaque, callable: *const Value) ?[]const u8 {
    const self = ip(ctx);
    if (callable.* != .IrClosure) return null;
    const info = self.closures.get(@intCast(callable.IrClosure.asPtrConst().id)) orelse return null;
    const module_ref = self.module.clone();
    defer module_ref.deinit();
    const module = info.module orelse module_ref.asPtr();
    const func = module.funcById(info.body_func) orelse return null;
    const name = func.return_ty.name;
    if (name.len == 0 or std.mem.eql(u8, name, "Unit") or std.mem.eql(u8, name, "kotlin.Unit")) return null;
    return name;
}

const intrinsic_vtable: IntrinsicHost.VTable = .{
    .invoke_callable = ivInvokeCallable,
    .invoke_callable_with_this = ivInvokeCallableWithThis,
    .call_well_known = ivCallWellKnown,
    .well_known_object = ivWellKnownObject,
    .alloc_instance_id = ivAllocInstanceId,
    .new_host_instance = ivNewHostInstance,
    .construct_well_known = ivConstructWellKnown,
    .run_blocking = ivRunBlocking,
    .coroutine_run_root = ivCoroutineRunRoot,
    .coroutine_start_root_or_suspended = ivCoroutineStartRootOrSuspended,
    .coroutine_has_driver = ivCoroutineHasDriver,
    .coroutine_on_event_loop = ivCoroutineOnEventLoop,
    .coroutine_owner_route = ivCoroutineOwnerRoute,
    .coroutine_post_main = ivCoroutinePostMain,
    .coroutine_launch = ivCoroutineLaunch,
    .coroutine_spawn_timeout = ivCoroutineSpawnTimeout,
    .coroutine_spawn_timer = ivCoroutineSpawnTimer,
    .coroutine_arm_slot = ivCoroutineArmSlot,
    .coroutine_disarm_slot = ivCoroutineDisarmSlot,
    .coroutine_last_root_parked_once = ivCoroutineLastRootParkedOnce,
    .coroutine_note_suspension_hit = ivCoroutineNoteSuspensionHit,
    .coroutine_push_scope = ivCoroutinePushScope,
    .coroutine_pop_scope = ivCoroutinePopScope,
    .coroutine_resume_slot_value = ivCoroutineResumeSlotValue,
    .mark_slot_owner_scheduler_backed = ivMarkSlotOwnerSchedulerBacked,
    .active_coro_scope = ivActiveCoroScope,
    .coroutine_resume_external = ivCoroutineResumeExternal,
    .coroutine_dispatch_pooled = ivCoroutineDispatchPooled,
    .coroutine_pool_new = ivCoroutinePoolNew,
    .coroutine_pool_dispatch = ivCoroutinePoolDispatch,
    .coroutine_pool_close = ivCoroutinePoolClose,
    .coroutine_resume_continuation = ivCoroutineResumeContinuation,
    .coroutine_drain_to_idle = ivCoroutineDrainToIdle,
    .spawn_os_thread = ivSpawnOsThread,
    .join_os_thread = ivJoinOsThread,
    .os_thread_alive = ivOsThreadAlive,
    .builder_step = ivBuilderStep,
    .callable_return_ty = ivCallableReturnTy,
    .persist = ivPersist,
};

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    _ = host_call_func;
    _ = host_call_value;
    _ = host_impl;
    _ = host_resolved;
    _ = intrinsic_host;
    _ = coroutines;
    _ = trace;
}
