//! The per-evaluation `VmHost` — the `ir.eval.Host` implementation the
//! IR evaluator dispatches non-trivial operations through, plus the
//! `VmIntrinsicHost` adapter the stdlib reaches back through to invoke
//! lambdas and the rest of the runtime.
//!
//! In Rust these were inherent `impl VmHost` blocks split across the
//! `host_*.rs` files plus the `impl Host for VmHost` glue in
//! `host_impl.rs`. Here the per-operation methods are FREE FUNCTIONS
//! over `*VmHost` living in the sibling files, and this file owns the
//! struct definitions plus the `{ctx, vtable}` wiring that turns them
//! into an `ir.eval.Host` / `runtime.IntrinsicHost`.

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
const Scheduler = runtime.Scheduler;
const SharedOutput = root.SharedOutput;
const RuntimeError = runtime.RuntimeError;
const IntrinsicHost = runtime.IntrinsicHost;
const HostResultU64 = runtime.HostResultU64;
const InstanceData = runtime.InstanceData;

const Module = ir.Module;
const FuncId = ir.FuncId;
const ClassId = ir.ClassId;
const TypeRef = ir.TypeRef;
const Host = ir.eval.Host;
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

/// IR Host implementation. Every method native to the Vm lives as a
/// free function over `*VmHost` in a sibling file; this struct holds the
/// shared state those functions read and write for the duration of one
/// evaluation.
pub const VmHost = struct {
    globals: ObjRef(Env),
    module: ObjRef(Module),
    scheduler: *runtime.InProcessScheduler,
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

    /// Build an `ir.eval.Host` `{ctx, vtable}` pair bound to this host.
    pub fn hostInterface(self: *VmHost) Host {
        return .{ .ctx = self, .vtable = &host_vtable };
    }
};

/// Stdlib `CallCtx` host adapter for native Vm dispatch. HOF bindings
/// (`map`, `forEach`, scope fns, …) reach back through this adapter to
/// invoke the lambda they were passed.
pub const VmIntrinsicHost = struct {
    scheduler: *runtime.InProcessScheduler,
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

    /// Build a `runtime.IntrinsicHost` `{ctx, vtable}` pair bound to this
    /// adapter.
    pub fn intrinsicHost(self: *VmIntrinsicHost) IntrinsicHost {
        return .{ .ctx = self, .vtable = &intrinsic_vtable };
    }
};

// -------------------------------------------------------------------------
// `ir.eval.Host` vtable wiring.
//
// Each slot casts the opaque ctx back to `*VmHost` and forwards to the
// matching free function in a sibling file (mirroring `host_impl.rs`'s
// `impl Host for VmHost`). The sibling functions are stubs for now;
// filling them in does not touch this wiring.
// -------------------------------------------------------------------------

fn hp(ctx: *anyopaque) *VmHost {
    return @ptrCast(@alignCast(ctx));
}

fn vtCallValue(ctx: *anyopaque, a: Allocator, callee: *const Value, args: []const Value) Allocator.Error!EvalResult {
    return host_call_value.callValue(hp(ctx), a, callee, args);
}
fn vtCallValueNamed(ctx: *anyopaque, a: Allocator, callee: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    return host_call_value.callValueNamed(hp(ctx), a, callee, args, arg_names);
}
fn vtCallValueWithThis(ctx: *anyopaque, a: Allocator, callee: *const Value, this_value: *const Value, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    return host_call_value.callValueWithThis(hp(ctx), a, callee, this_value, args, arg_names);
}
fn vtCallMember(ctx: *anyopaque, a: Allocator, receiver: *const Value, name: []const u8, args: []const Value) Allocator.Error!EvalResult {
    return host_call_member.callMember(hp(ctx), a, receiver, name, args);
}
fn vtCallMemberNamed(ctx: *anyopaque, a: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    return host_call_member.callMemberNamed(hp(ctx), a, receiver, name, args, arg_names);
}
fn vtCallMemberOnly(ctx: *anyopaque, a: Allocator, receiver: *const Value, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    return host_call_member.callMemberOnly(hp(ctx), a, receiver, name, args, arg_names);
}
fn vtHostHasMember(ctx: *anyopaque, receiver: *const Value, name: []const u8) bool {
    return host_call_member.hostHasMember(hp(ctx), receiver, name);
}
fn vtMemberRef(ctx: *anyopaque, a: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
    return host_call_member.memberRef(hp(ctx), a, receiver, name);
}
fn vtNewInstance(ctx: *anyopaque, a: Allocator, class: ClassId, args: []const Value) Allocator.Error!EvalResult {
    return host_instances.newInstance(hp(ctx), a, class, args);
}
fn vtNewInstanceNamed(ctx: *anyopaque, a: Allocator, class: ClassId, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    return host_instances.newInstanceNamed(hp(ctx), a, class, args, arg_names);
}
fn vtGetField(ctx: *anyopaque, a: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
    return host_fields.getField(hp(ctx), a, receiver, name);
}
fn vtSetField(ctx: *anyopaque, a: Allocator, receiver: *const Value, name: []const u8, value: Value) Allocator.Error!UnitResult {
    return host_fields.setField(hp(ctx), a, receiver, name, value);
}
fn vtInstanceOf(ctx: *anyopaque, value: *const Value, ty: TypeRef) bool {
    return host_classes.instanceOf(hp(ctx), value, ty);
}
fn vtIsConcreteCastTarget(ctx: *anyopaque, name: []const u8) bool {
    return host_classes.isConcreteCastTarget(hp(ctx), name);
}
fn vtLookupGlobal(ctx: *anyopaque, name: []const u8) ?Value {
    return host_globals.lookupGlobal(hp(ctx), name);
}
fn vtLookupGlobalThrowing(ctx: *anyopaque, a: Allocator, name: []const u8) Allocator.Error!MaybeValueResult {
    return host_globals.lookupGlobalThrowing(hp(ctx), a, name);
}
fn vtStoreGlobal(ctx: *anyopaque, a: Allocator, name: []const u8, value: Value) Allocator.Error!UnitResult {
    return host_globals.storeGlobal(hp(ctx), a, name, value);
}
fn vtRegisterClass(ctx: *anyopaque, a: Allocator, class: *const ast.Class) Allocator.Error!UnitResult {
    return host_classes.registerClass(hp(ctx), a, class);
}
fn vtRegisterClassCaptured(ctx: *anyopaque, a: Allocator, class: *const ast.Class, captured_names: []const []const u8, captures: []const Value) Allocator.Error!UnitResult {
    return host_classes.registerClassCaptured(hp(ctx), a, class, captured_names, captures);
}
fn vtBuildObject(ctx: *anyopaque, a: Allocator, expr: *const ast.Expr, captured_names: []const []const u8, captures: []const Value) Allocator.Error!EvalResult {
    return host_instances.buildObject(hp(ctx), a, expr, captured_names, captures);
}
fn vtCallSuper(ctx: *anyopaque, a: Allocator, receiver: *const Value, owner_class: []const u8, qualifier: ?[]const u8, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    return host_call_member.callSuper(hp(ctx), a, receiver, owner_class, qualifier, name, args, arg_names);
}
fn vtQualifiedThis(ctx: *anyopaque, a: Allocator, receiver: *const Value, qualifier: []const u8) Allocator.Error!EvalResult {
    return host_call_member.qualifiedThis(hp(ctx), a, receiver, qualifier);
}
fn vtReadLambdaCapture(ctx: *anyopaque, a: Allocator, lambda: *const Value, name: []const u8) Allocator.Error!EvalResult {
    return host_call_value.readLambdaCapture(hp(ctx), a, lambda, name);
}
fn vtBuildClosure(ctx: *anyopaque, a: Allocator, module: *const Module, body_func: FuncId, captures: []const Value) Allocator.Error!EvalResult {
    return host_call_value.buildClosure(hp(ctx), a, module, body_func, captures);
}
fn vtBuildAstLambdaWithFlagFuncid(ctx: *anyopaque, a: Allocator, params: []const []const u8, body: *const ast.Block, captured_names: []const []const u8, captures: []const Value, absorb_return: bool, body_func: ?FuncId) Allocator.Error!EvalResult {
    return host_call_value.buildAstLambdaWithFlagFuncid(hp(ctx), a, params, body, captured_names, captures, absorb_return, body_func);
}
fn vtCallFunc(ctx: *anyopaque, a: Allocator, module: *const Module, func: FuncId, args: []const Value) Allocator.Error!EvalResult {
    return host_call_func.callFunc(hp(ctx), a, module, func, args);
}
fn vtCallFuncNamed(ctx: *anyopaque, a: Allocator, module: *const Module, func: FuncId, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!EvalResult {
    return host_call_func.callFuncNamed(hp(ctx), a, module, func, args, arg_names);
}
fn vtCallFuncTyped(ctx: *anyopaque, a: Allocator, module: *const Module, func: FuncId, args: []const Value, arg_names: []const ?[]const u8, type_args: []const []const u8, exact: bool) Allocator.Error!EvalResult {
    return host_call_func.callFuncTyped(hp(ctx), a, module, func, args, arg_names, type_args, exact);
}
fn vtCallNamedOverload(ctx: *anyopaque, a: Allocator, module: *const Module, name: []const u8, args: []const Value, arg_names: []const ?[]const u8) Allocator.Error!MaybeValueResult {
    return host_call_func.callNamedOverload(hp(ctx), a, module, name, args, arg_names);
}
fn vtEnclosingThis(ctx: *anyopaque) ?Value {
    return host_call_member.enclosingThis(hp(ctx));
}
fn vtEnclosingThisChain(ctx: *anyopaque, a: Allocator) Allocator.Error![]Value {
    return host_call_member.enclosingThisChain(hp(ctx), a);
}
fn vtCallableReceiverShape(ctx: *anyopaque, v: *const Value) ?ReceiverShape {
    return host_call_value.callableReceiverShape(hp(ctx), v);
}
fn vtClosureNeedsThisCapture(ctx: *anyopaque, v: *const Value) bool {
    return host_call_value.closureNeedsThisCapture(hp(ctx), v);
}
fn vtOverrideClosureThis(ctx: *anyopaque, v: *const Value, new_this: *const Value) void {
    host_call_value.overrideClosureThis(hp(ctx), v, new_this);
}
fn vtPushAccessEnclosing(ctx: *anyopaque, v: *const Value) void {
    host_call_member.pushAccessEnclosing(hp(ctx), v);
}
fn vtPopAccessEnclosing(ctx: *anyopaque) void {
    host_call_member.popAccessEnclosing(hp(ctx));
}
fn vtPushInnerOuterHint(ctx: *anyopaque, v: *const Value) void {
    host_instances.pushInnerOuterHint(hp(ctx), v);
}
fn vtPopInnerOuterHint(ctx: *anyopaque) void {
    host_instances.popInnerOuterHint(hp(ctx));
}
fn vtIsShadowingCapture(ctx: *anyopaque, name: []const u8) bool {
    return host_globals.isShadowingCapture(hp(ctx), name);
}

const host_vtable: Host.VTable = .{
    .call_value = vtCallValue,
    .call_value_named = vtCallValueNamed,
    .call_value_with_this = vtCallValueWithThis,
    .call_member = vtCallMember,
    .call_member_named = vtCallMemberNamed,
    .call_member_only = vtCallMemberOnly,
    .host_has_member = vtHostHasMember,
    .member_ref = vtMemberRef,
    .new_instance = vtNewInstance,
    .new_instance_named = vtNewInstanceNamed,
    .get_field = vtGetField,
    .set_field = vtSetField,
    .instance_of = vtInstanceOf,
    .is_concrete_cast_target = vtIsConcreteCastTarget,
    .lookup_global = vtLookupGlobal,
    .lookup_global_throwing = vtLookupGlobalThrowing,
    .store_global = vtStoreGlobal,
    .register_class = vtRegisterClass,
    .register_class_captured = vtRegisterClassCaptured,
    .build_object = vtBuildObject,
    .call_super = vtCallSuper,
    .qualified_this = vtQualifiedThis,
    .read_lambda_capture = vtReadLambdaCapture,
    .build_closure = vtBuildClosure,
    .build_ast_lambda_with_flag_funcid = vtBuildAstLambdaWithFlagFuncid,
    .call_func = vtCallFunc,
    .call_func_named = vtCallFuncNamed,
    .call_func_typed = vtCallFuncTyped,
    .call_named_overload = vtCallNamedOverload,
    .enclosing_this = vtEnclosingThis,
    .enclosing_this_chain = vtEnclosingThisChain,
    .callable_receiver_shape = vtCallableReceiverShape,
    .closure_needs_this_capture = vtClosureNeedsThisCapture,
    .override_closure_this = vtOverrideClosureThis,
    .push_access_enclosing = vtPushAccessEnclosing,
    .pop_access_enclosing = vtPopAccessEnclosing,
    .push_inner_outer_hint = vtPushInnerOuterHint,
    .pop_inner_outer_hint = vtPopInnerOuterHint,
    .is_shadowing_capture = vtIsShadowingCapture,
};

// -------------------------------------------------------------------------
// `runtime.IntrinsicHost` vtable wiring for `VmIntrinsicHost`.
// -------------------------------------------------------------------------

fn ip(ctx: *anyopaque) *VmIntrinsicHost {
    return @ptrCast(@alignCast(ctx));
}

fn ivScheduler(ctx: *anyopaque) Scheduler {
    return intrinsic_host.scheduler(ip(ctx));
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
fn ivSpawnOsThread(ctx: *anyopaque, block: *const Value, out: Output) Allocator.Error!HostResultU64 {
    return intrinsic_host.spawnOsThread(ip(ctx), block, out);
}
fn ivJoinOsThread(ctx: *anyopaque, id: u64) Allocator.Error!?RuntimeError {
    return intrinsic_host.joinOsThread(ip(ctx), id);
}
fn ivOsThreadAlive(ctx: *anyopaque, id: u64) bool {
    return intrinsic_host.osThreadAlive(ip(ctx), id);
}
fn ivDispatchCoroutine(ctx: *anyopaque, block: *const Value, elastic: bool, out: Output) Allocator.Error!HostResultU64 {
    return intrinsic_host.dispatchCoroutine(ip(ctx), block, elastic, out);
}
fn ivJoinDispatched(ctx: *anyopaque, id: u64) Allocator.Error!?RuntimeError {
    return intrinsic_host.joinDispatched(ip(ctx), id);
}

const intrinsic_vtable: IntrinsicHost.VTable = .{
    .scheduler = ivScheduler,
    .invoke_callable = ivInvokeCallable,
    .invoke_callable_with_this = ivInvokeCallableWithThis,
    .invoke_method = ivInvokeMethod,
    .lookup_global = ivLookupGlobal,
    .alloc_instance_id = ivAllocInstanceId,
    .new_synth_instance = ivNewSynthInstance,
    .run_blocking = ivRunBlocking,
    .coroutine_run_root = ivCoroutineRunRoot,
    .coroutine_launch = ivCoroutineLaunch,
    .spawn_os_thread = ivSpawnOsThread,
    .join_os_thread = ivJoinOsThread,
    .os_thread_alive = ivOsThreadAlive,
    .dispatch_coroutine = ivDispatchCoroutine,
    .join_dispatched = ivJoinDispatched,
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
