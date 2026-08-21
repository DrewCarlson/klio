//! Side-channels the runtime exposes to native stdlib intrinsics:
//! the `StdlibFn` pointer, the `CallCtx` it receives, and the
//! `IntrinsicHost` it calls back through.
//!
//! `IntrinsicHost` is a `{ctx, vtable}` pair. Methods that carry a default
//! body keep that default by letting the vtable slot be optional (`null`
//! = use the default).

const std = @import("std");
const value_mod = @import("value.zig");
const output_mod = @import("output.zig");

const Value = value_mod.Value;
const RuntimeError = value_mod.RuntimeError;
const EvalResult = value_mod.EvalResult;
const BuilderStateRef = value_mod.BuilderStateRef;
const Output = output_mod.Output;

/// Outcome of driving a lazy `sequence{}`/`iterator{}` builder one step.
pub const BuilderStepResult = union(enum) {
    /// The block yielded a value (it suspended at a `yield`).
    value: Value,
    /// The block ran to completion — no more elements.
    done,
    err: RuntimeError,
};

/// Function pointer signature for a native stdlib intrinsic.
///
/// `CallCtx.args` carries the call arguments. For member access the
/// receiver is `args[0]`, with any further user arguments following.
/// OOM surfaces as a Zig error; a `RuntimeError` surfaces as data via
/// `EvalResult`.
pub const StdlibFn = *const fn (ctx: *CallCtx) std.mem.Allocator.Error!EvalResult;

pub const CallCtx = struct {
    args: []const Value,
    out: Output,
    /// Single host handle the intrinsic uses to reach the rest of the
    /// runtime — the lambda invoker and coroutine/thread machinery.
    host: IntrinsicHost,
    /// Allocator for any heap the intrinsic produces.
    allocator: std.mem.Allocator,
};

/// Side-channel the runtime exposes to stdlib intrinsics. A `{ctx,
/// vtable}` pair. Vtable slots that default are optional; `null` selects
/// the default behavior implemented in the wrapper methods below.
pub const IntrinsicHost = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Invoke a callable `Value` with the supplied args (required).
        invoke_callable: *const fn (ctx: *anyopaque, callable: *const Value, args: []const Value, out: Output) std.mem.Allocator.Error!EvalResult,
        /// Invoke a callable binding `this` to `this_value` (required).
        invoke_callable_with_this: *const fn (ctx: *anyopaque, callable: *const Value, args: []const Value, this_value: *const Value, out: Output) std.mem.Allocator.Error!EvalResult,
        /// Invoke a named method on a receiver. `null` slot => default
        /// (returns `null`, i.e. fall back to structural rendering).
        invoke_method: ?*const fn (ctx: *anyopaque, receiver: *const Value, name: []const u8, args: []const Value, out: Output) std.mem.Allocator.Error!?EvalResult = null,
        /// Construct an instance of a class value with NAMED arguments,
        /// letting the constructor's defaults fill every unnamed parameter.
        /// `null` slot => unavailable.
        construct_named: ?*const fn (ctx: *anyopaque, class: *const Value, names: []const []const u8, args: []const Value, out: Output) std.mem.Allocator.Error!?EvalResult = null,
        /// Read a property/field off a receiver: resolves custom getters,
        /// stored fields, and ctor-property params (unlike `invoke_method`,
        /// which only dispatches functions). `null` slot => default (returns
        /// `null`, i.e. unavailable).
        get_property: ?*const fn (ctx: *anyopaque, receiver: *const Value, name: []const u8, out: Output) std.mem.Allocator.Error!?EvalResult = null,
        /// Resolve a top-level identifier. `null` => default (`null`).
        lookup_global: ?*const fn (ctx: *anyopaque, name: []const u8) ?Value = null,
        /// Allocate a fresh instance identity. `null` => default (`0`).
        alloc_instance_id: ?*const fn (ctx: *anyopaque) u64 = null,
        /// Synthesise an opaque `Value::Instance`. `null` => default (Unit).
        new_synth_instance: ?*const fn (ctx: *anyopaque, class_fqn: []const u8, identity: u64, fields: []const InstanceData.Field) std.mem.Allocator.Error!Value = null,
        /// Drive a root `runBlocking` block. `null` => default.
        run_blocking: ?*const fn (ctx: *anyopaque, block: *const Value, scope: *const Value, out: Output) std.mem.Allocator.Error!EvalResult = null,
        /// Drive a `startCoroutine` root block. `null` => default.
        coroutine_run_root: ?*const fn (ctx: *anyopaque, scope: ?*const Value, block: *const Value, out: Output) std.mem.Allocator.Error!EvalResult = null,
        /// Start `block` as a fresh root with no enclosing driver; returns
        /// the block's value or `Value.CoroutineSuspended` when the root
        /// parked (persisted for a later external resume).
        coroutine_start_root_or_suspended: ?*const fn (ctx: *anyopaque, scope: ?*const Value, block: *const Value, out: Output) std.mem.Allocator.Error!EvalResult = null,
        /// Whether a cooperative driver pump is live on this thread.
        coroutine_has_driver: ?*const fn (ctx: *anyopaque) bool = null,
        /// Spawn a child coroutine. `null` => default (run eagerly).
        coroutine_launch: ?*const fn (ctx: *anyopaque, block: *const Value, scope: *const Value, out: Output) std.mem.Allocator.Error!?RuntimeError = null,
        /// Schedule a `withTimeout` cancellation gate (`invokeOnTimeout`).
        /// `null` => default (run eagerly, like a launch with no pump).
        coroutine_spawn_timeout: ?*const fn (ctx: *anyopaque, block: *const Value, out: Output) std.mem.Allocator.Error!?RuntimeError = null,
        coroutine_arm_slot: ?*const fn (ctx: *anyopaque, slot: i64) void = null,
        coroutine_disarm_slot: ?*const fn (ctx: *anyopaque) void = null,
        /// Mark the pump owning `slot` as driven by an external dispatcher (a
        /// `runTest` `TestCoroutineScheduler`): a channel delivery to one of its
        /// waiters routed through that dispatcher, not the pump queue. `null` =>
        /// no-op.
        mark_slot_owner_scheduler_backed: ?*const fn (ctx: *anyopaque, slot: i64) void = null,
        /// Push / pop the active coroutine scope around an undispatched
        /// block run inline in the caller's activation
        /// (`startCoroutineUninterceptedOrReturn`). `null` => no-op.
        coroutine_push_scope: ?*const fn (ctx: *anyopaque, scope: *const Value) void = null,
        coroutine_pop_scope: ?*const fn (ctx: *anyopaque) void = null,
        coroutine_resume_slot_value: ?*const fn (ctx: *anyopaque, slot: i64, value: Value) void = null,
        /// The active coroutine scope (the running coroutine / `Job`), or
        /// `null` outside any cooperative driver. `null` slot => no scope.
        active_coro_scope: ?*const fn (ctx: *anyopaque) ?Value = null,
        /// Resolve a top-level Kotlin function by name (the heavier
        /// module-function lookup, distinct from `lookup_global`). `null`
        /// slot => default (`null`).
        lookup_global_func: ?*const fn (ctx: *anyopaque, name: []const u8) ?Value = null,
        coroutine_drain_to_idle: ?*const fn (ctx: *anyopaque, out: Output) std.mem.Allocator.Error!?RuntimeError = null,
        coroutine_resume_external: ?*const fn (ctx: *anyopaque, slot: i64, value: Value, out: Output) void = null,
        /// A Kotlin `Continuation.resumeWith`: the coroutine's own step, which
        /// runs on the caller's stack. Distinct from `coroutine_resume_external`
        /// (a klio-native suspension's resume, which the pump queue defers —
        /// klio's native parks pass through no interceptor, so the queue is
        /// their dispatch).
        coroutine_resume_continuation: ?*const fn (ctx: *anyopaque, slot: i64, value: Value, out: Output) void = null,
        /// Post a dispatcher runnable onto the shared worker pool
        /// (`Dispatchers.Default` / `Dispatchers.IO`). `null` => default
        /// (run the block inline on the calling thread).
        coroutine_dispatch_pooled: ?*const fn (ctx: *anyopaque, block: *const Value, io: bool, out: Output) std.mem.Allocator.Error!?RuntimeError = null,
        spawn_os_thread: ?*const fn (ctx: *anyopaque, block: *const Value, out: Output) std.mem.Allocator.Error!HostResultU64 = null,
        join_os_thread: ?*const fn (ctx: *anyopaque, id: u64) std.mem.Allocator.Error!?RuntimeError = null,
        os_thread_alive: ?*const fn (ctx: *anyopaque, id: u64) bool = null,
        /// Drive a lazy `sequence{}`/`iterator{}` builder one element: start or
        /// resume the coroutine block, return the next yielded value (or
        /// `.done` at completion). `null` => default (`.done`, i.e. an empty
        /// sequence — only the VM host implements real lazy driving).
        builder_step: ?*const fn (ctx: *anyopaque, state: BuilderStateRef, out: Output) std.mem.Allocator.Error!BuilderStepResult = null,
        /// Declared return-type name of a callable's underlying function
        /// (`"kotlin.Long"`), or `null` when unknown / not statically
        /// typed. Numeric-kind-preserving folds (`sumOf`) read it to seed
        /// an empty-receiver accumulator with the right kind. `null`
        /// slot => default (`null`).
        callable_return_ty: ?*const fn (ctx: *anyopaque, callable: *const Value) ?[]const u8 = null,
        /// Return a stable `IntrinsicHost` that outlives the current activation.
        /// A platform-driven frame loop (an OS vsync callback) re-enters the VM
        /// after `main` has returned, so the transient per-call host it was
        /// handed is gone; this hands back a resident copy that stays valid for
        /// the process lifetime. `null` => default (returns `self` unchanged;
        /// only the VM host builds a resident copy).
        persist: ?*const fn (ctx: *anyopaque) IntrinsicHost = null,
    };

    pub fn invokeCallable(self: IntrinsicHost, callable: *const Value, args: []const Value, out: Output) !EvalResult {
        return self.vtable.invoke_callable(self.ctx, callable, args, out);
    }

    /// A resident host bound to the same VM state, safe to store and re-enter
    /// across activations (see `VTable.persist`).
    pub fn persist(self: IntrinsicHost) IntrinsicHost {
        if (self.vtable.persist) |f| return f(self.ctx);
        return self;
    }

    pub fn invokeCallableWithThis(self: IntrinsicHost, callable: *const Value, args: []const Value, this_value: *const Value, out: Output) !EvalResult {
        return self.vtable.invoke_callable_with_this(self.ctx, callable, args, this_value, out);
    }

    pub fn invokeMethod(self: IntrinsicHost, receiver: *const Value, name: []const u8, args: []const Value, out: Output) !?EvalResult {
        if (self.vtable.invoke_method) |f| return f(self.ctx, receiver, name, args, out);
        return null;
    }

    pub fn getProperty(self: IntrinsicHost, receiver: *const Value, name: []const u8, out: Output) !?EvalResult {
        if (self.vtable.get_property) |f| return f(self.ctx, receiver, name, out);
        return null;
    }

    pub fn constructNamed(self: IntrinsicHost, class: *const Value, names: []const []const u8, args: []const Value, out: Output) !?EvalResult {
        if (self.vtable.construct_named) |f| return f(self.ctx, class, names, args, out);
        return null;
    }

    pub fn lookupGlobal(self: IntrinsicHost, name: []const u8) ?Value {
        if (self.vtable.lookup_global) |f| return f(self.ctx, name);
        return null;
    }

    pub fn allocInstanceId(self: IntrinsicHost) u64 {
        if (self.vtable.alloc_instance_id) |f| return f(self.ctx);
        return 0;
    }

    pub fn newSynthInstance(self: IntrinsicHost, class_fqn: []const u8, identity: u64, fields: []const InstanceData.Field) !Value {
        if (self.vtable.new_synth_instance) |f| return f(self.ctx, class_fqn, identity, fields);
        return .Unit;
    }

    pub fn runBlocking(self: IntrinsicHost, block: *const Value, scope: *const Value, out: Output) !EvalResult {
        if (self.vtable.run_blocking) |f| return f(self.ctx, block, scope, out);
        return self.invokeCallableWithThis(block, &.{}, scope, out);
    }

    pub fn coroutineRunRoot(self: IntrinsicHost, scope: ?*const Value, block: *const Value, out: Output) !EvalResult {
        if (self.vtable.coroutine_run_root) |f| return f(self.ctx, scope, block, out);
        return self.invokeCallable(block, &.{}, out);
    }

    pub fn coroutineStartRootOrSuspended(self: IntrinsicHost, scope: ?*const Value, block: *const Value, out: Output) !EvalResult {
        if (self.vtable.coroutine_start_root_or_suspended) |f| return f(self.ctx, scope, block, out);
        return self.invokeCallable(block, &.{}, out);
    }

    pub fn coroutineHasDriver(self: IntrinsicHost) bool {
        if (self.vtable.coroutine_has_driver) |f| return f(self.ctx);
        return false;
    }

    pub fn coroutineLaunch(self: IntrinsicHost, block: *const Value, scope: *const Value, out: Output) !?RuntimeError {
        if (self.vtable.coroutine_launch) |f| return f(self.ctx, block, scope, out);
        const r = try self.invokeCallableWithThis(block, &.{}, scope, out);
        return switch (r) {
            .ok => null,
            .err => |e| e,
        };
    }

    pub fn coroutineSpawnTimeout(self: IntrinsicHost, block: *const Value, out: Output) !?RuntimeError {
        if (self.vtable.coroutine_spawn_timeout) |f| return f(self.ctx, block, out);
        const r = try self.invokeCallable(block, &.{}, out);
        return switch (r) {
            .ok => null,
            .err => |e| e,
        };
    }

    pub fn coroutineArmSlot(self: IntrinsicHost, slot: i64) void {
        if (self.vtable.coroutine_arm_slot) |f| f(self.ctx, slot);
    }

    pub fn coroutineDisarmSlot(self: IntrinsicHost) void {
        if (self.vtable.coroutine_disarm_slot) |f| f(self.ctx);
    }

    pub fn coroutinePushScope(self: IntrinsicHost, scope: *const Value) void {
        if (self.vtable.coroutine_push_scope) |f| f(self.ctx, scope);
    }

    pub fn coroutinePopScope(self: IntrinsicHost) void {
        if (self.vtable.coroutine_pop_scope) |f| f(self.ctx);
    }

    pub fn coroutineResumeSlotValue(self: IntrinsicHost, slot: i64, value: Value) void {
        if (self.vtable.coroutine_resume_slot_value) |f| f(self.ctx, slot, value);
    }

    pub fn markSlotOwnerSchedulerBacked(self: IntrinsicHost, slot: i64) void {
        if (self.vtable.mark_slot_owner_scheduler_backed) |f| f(self.ctx, slot);
    }

    pub fn activeCoroScope(self: IntrinsicHost) ?Value {
        if (self.vtable.active_coro_scope) |f| return f(self.ctx);
        return null;
    }

    pub fn lookupGlobalFunc(self: IntrinsicHost, name: []const u8) ?Value {
        if (self.vtable.lookup_global_func) |f| return f(self.ctx, name);
        return null;
    }

    pub fn coroutineDrainToIdle(self: IntrinsicHost, out: Output) !?RuntimeError {
        if (self.vtable.coroutine_drain_to_idle) |f| return f(self.ctx, out);
        return null;
    }

    pub fn coroutineResumeExternal(self: IntrinsicHost, slot: i64, value: Value, out: Output) void {
        if (self.vtable.coroutine_resume_external) |f| {
            f(self.ctx, slot, value, out);
        } else {
            self.coroutineResumeSlotValue(slot, value);
        }
    }

    pub fn coroutineResumeContinuation(self: IntrinsicHost, slot: i64, value: Value, out: Output) void {
        if (self.vtable.coroutine_resume_continuation) |f| {
            f(self.ctx, slot, value, out);
        } else {
            self.coroutineResumeExternal(slot, value, out);
        }
    }

    pub fn coroutineDispatchPooled(self: IntrinsicHost, block: *const Value, io_kind: bool, out: Output) !?RuntimeError {
        if (self.vtable.coroutine_dispatch_pooled) |f| return f(self.ctx, block, io_kind, out);
        const r = try self.invokeCallable(block, &.{}, out);
        return switch (r) {
            .ok => null,
            .err => |e| e,
        };
    }

    pub fn spawnOsThread(self: IntrinsicHost, block: *const Value, out: Output) !HostResultU64 {
        if (self.vtable.spawn_os_thread) |f| return f(self.ctx, block, out);
        const r = try self.invokeCallable(block, &.{}, out);
        return switch (r) {
            .ok => .{ .ok = 0 },
            .err => |e| .{ .err = e },
        };
    }

    pub fn joinOsThread(self: IntrinsicHost, id: u64) !?RuntimeError {
        if (self.vtable.join_os_thread) |f| return f(self.ctx, id);
        return null;
    }

    pub fn osThreadAlive(self: IntrinsicHost, id: u64) bool {
        if (self.vtable.os_thread_alive) |f| return f(self.ctx, id);
        return false;
    }

    pub fn builderStep(self: IntrinsicHost, state: BuilderStateRef, out: Output) !BuilderStepResult {
        if (self.vtable.builder_step) |f| return f(self.ctx, state, out);
        return .done;
    }

    pub fn callableReturnTy(self: IntrinsicHost, callable: *const Value) ?[]const u8 {
        if (self.vtable.callable_return_ty) |f| return f(self.ctx, callable);
        return null;
    }
};

/// `Result<u64, RuntimeError>` for the OS-thread/dispatch entry points.
pub const HostResultU64 = union(enum) {
    ok: u64,
    err: RuntimeError,
};

/// Bare-minimum host for unit tests of pure intrinsics. The callable
/// entry points return `RuntimeError.Unimplemented` data.
pub const NoopHost = struct {
    pub fn init(allocator: std.mem.Allocator) NoopHost {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *NoopHost) void {
        _ = self;
    }

    fn vtInvokeCallable(ctx: *anyopaque, callable: *const Value, args: []const Value, out: Output) std.mem.Allocator.Error!EvalResult {
        _ = ctx;
        _ = callable;
        _ = args;
        _ = out;
        return .{ .err = .{ .Unimplemented = "NoopHost::invoke_callable" } };
    }
    fn vtInvokeCallableWithThis(ctx: *anyopaque, callable: *const Value, args: []const Value, this_value: *const Value, out: Output) std.mem.Allocator.Error!EvalResult {
        _ = ctx;
        _ = callable;
        _ = args;
        _ = this_value;
        _ = out;
        return .{ .err = .{ .Unimplemented = "NoopHost::invoke_callable_with_this" } };
    }

    const vtable: IntrinsicHost.VTable = .{
        .invoke_callable = vtInvokeCallable,
        .invoke_callable_with_this = vtInvokeCallableWithThis,
    };

    pub fn host(self: *NoopHost) IntrinsicHost {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

const InstanceData = @import("class.zig").InstanceData;

const testing = std.testing;

test "noop host reports unimplemented for callables" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = output_mod.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const callable: Value = .Unit;
    const r = try h.host().invokeCallable(&callable, &.{}, cap.output());
    try testing.expect(r == .err);
}

test "intrinsic host slot seams default to a no-op without a vtable slot" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    const ih = h.host();
    // The merged one-arm / one-resume coroutine surface: an unwired host
    // tolerates each call as a no-op rather than dereferencing a null slot.
    ih.coroutineArmSlot(1);
    ih.coroutineResumeSlotValue(1, .Unit);
    ih.coroutineDisarmSlot();
    try testing.expect(!ih.osThreadAlive(0));
}
