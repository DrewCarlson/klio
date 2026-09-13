//! Side-channels the runtime exposes to native stdlib intrinsics: the
//! `StdlibFn` pointer, the `CallCtx` it receives, and the `IntrinsicHost` it
//! calls back through, whose optional vtable slots select a default.

const std = @import("std");
const value_mod = @import("value.zig");
const output_mod = @import("output.zig");

const Value = value_mod.Value;
const RuntimeError = value_mod.RuntimeError;
const EvalResult = value_mod.EvalResult;
const BuilderStateRef = value_mod.BuilderStateRef;
const Output = output_mod.Output;

pub const BuilderStepResult = union(enum) {
    /// The block suspended at a `yield`, producing this value.
    value: Value,
    done,
    err: RuntimeError,
};

/// `CallCtx.args` carries the arguments, with a member access's receiver at
/// `args[0]`. OOM surfaces as a Zig error, a `RuntimeError` as `EvalResult`.
pub const StdlibFn = *const fn (ctx: *CallCtx) std.mem.Allocator.Error!EvalResult;

pub const CallCtx = struct {
    args: []const Value,
    out: Output,
    host: IntrinsicHost,
    allocator: std.mem.Allocator,
};

/// Optional slots fall back to the wrapper methods below.
pub const IntrinsicHost = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Required.
        invoke_callable: *const fn (ctx: *anyopaque, callable: *const Value, args: []const Value, out: Output) std.mem.Allocator.Error!EvalResult,
        /// Required.
        invoke_callable_with_this: *const fn (ctx: *anyopaque, callable: *const Value, args: []const Value, this_value: *const Value, out: Output) std.mem.Allocator.Error!EvalResult,
        /// Null answers null, falling back to structural rendering.
        invoke_method: ?*const fn (ctx: *anyopaque, receiver: *const Value, name: []const u8, args: []const Value, out: Output) std.mem.Allocator.Error!?EvalResult = null,
        /// The constructor's defaults fill every unnamed parameter.
        construct_named: ?*const fn (ctx: *anyopaque, class: *const Value, names: []const []const u8, args: []const Value, out: Output) std.mem.Allocator.Error!?EvalResult = null,
        /// Resolves custom getters and stored fields, where `invoke_method`
        /// dispatches only functions.
        get_property: ?*const fn (ctx: *anyopaque, receiver: *const Value, name: []const u8, out: Output) std.mem.Allocator.Error!?EvalResult = null,
        lookup_global: ?*const fn (ctx: *anyopaque, name: []const u8) ?Value = null,
        alloc_instance_id: ?*const fn (ctx: *anyopaque) u64 = null,
        new_synth_instance: ?*const fn (ctx: *anyopaque, class_fqn: []const u8, identity: u64, fields: []const InstanceData.Field) std.mem.Allocator.Error!Value = null,
        run_blocking: ?*const fn (ctx: *anyopaque, block: *const Value, scope: *const Value, out: Output) std.mem.Allocator.Error!EvalResult = null,
        coroutine_run_root: ?*const fn (ctx: *anyopaque, scope: ?*const Value, block: *const Value, out: Output) std.mem.Allocator.Error!EvalResult = null,
        /// Answers the block's value, or `Value.CoroutineSuspended` when the
        /// root parked and was persisted for a later external resume.
        coroutine_start_root_or_suspended: ?*const fn (ctx: *anyopaque, scope: ?*const Value, block: *const Value, out: Output) std.mem.Allocator.Error!EvalResult = null,
        coroutine_has_driver: ?*const fn (ctx: *anyopaque) bool = null,
        /// Null runs it eagerly.
        coroutine_launch: ?*const fn (ctx: *anyopaque, block: *const Value, scope: *const Value, out: Output) std.mem.Allocator.Error!?RuntimeError = null,
        /// Null runs it eagerly, like a launch with no pump.
        coroutine_spawn_timeout: ?*const fn (ctx: *anyopaque, block: *const Value, out: Output) std.mem.Allocator.Error!?RuntimeError = null,
        coroutine_arm_slot: ?*const fn (ctx: *anyopaque, slot: i64) void = null,
        coroutine_disarm_slot: ?*const fn (ctx: *anyopaque) void = null,
        coroutine_last_root_parked_once: ?*const fn (ctx: *anyopaque) bool = null,
        coroutine_note_suspension_hit: ?*const fn (ctx: *anyopaque) void = null,
        /// A channel delivery to one of that pump's waiters then routes through
        /// the external dispatcher rather than the pump queue.
        mark_slot_owner_scheduler_backed: ?*const fn (ctx: *anyopaque, slot: i64) void = null,
        coroutine_push_scope: ?*const fn (ctx: *anyopaque, scope: *const Value) void = null,
        coroutine_pop_scope: ?*const fn (ctx: *anyopaque) void = null,
        coroutine_resume_slot_value: ?*const fn (ctx: *anyopaque, slot: i64, value: Value) void = null,
        active_coro_scope: ?*const fn (ctx: *anyopaque) ?Value = null,
        /// The heavier module-function lookup, distinct from `lookup_global`.
        lookup_global_func: ?*const fn (ctx: *anyopaque, name: []const u8) ?Value = null,
        coroutine_drain_to_idle: ?*const fn (ctx: *anyopaque, out: Output) std.mem.Allocator.Error!?RuntimeError = null,
        coroutine_resume_external: ?*const fn (ctx: *anyopaque, slot: i64, value: Value, out: Output) void = null,
        /// Run on the caller's stack, unlike `coroutine_resume_external`, which
        /// the pump queue defers because a native park passes through no
        /// interceptor.
        coroutine_resume_continuation: ?*const fn (ctx: *anyopaque, slot: i64, value: Value, out: Output) void = null,
        /// Null runs the block inline on the calling thread.
        coroutine_dispatch_pooled: ?*const fn (ctx: *anyopaque, block: *const Value, io: bool, out: Output) std.mem.Allocator.Error!?RuntimeError = null,
        spawn_os_thread: ?*const fn (ctx: *anyopaque, block: *const Value, out: Output) std.mem.Allocator.Error!HostResultU64 = null,
        join_os_thread: ?*const fn (ctx: *anyopaque, id: u64) std.mem.Allocator.Error!?RuntimeError = null,
        os_thread_alive: ?*const fn (ctx: *anyopaque, id: u64) bool = null,
        /// Answers the next yielded value, or `.done`. Null answers `.done`;
        /// only the VM host drives lazily for real.
        builder_step: ?*const fn (ctx: *anyopaque, state: BuilderStateRef, out: Output) std.mem.Allocator.Error!BuilderStepResult = null,
        /// Null when not statically typed. A kind-preserving fold like `sumOf`
        /// reads it to seed an empty-receiver accumulator.
        callable_return_ty: ?*const fn (ctx: *anyopaque, callable: *const Value) ?[]const u8 = null,
        /// Outlives the current activation, for a frame loop that re-enters the
        /// VM after `main` returned. Null answers `self` unchanged.
        persist: ?*const fn (ctx: *anyopaque) IntrinsicHost = null,
    };

    pub fn invokeCallable(self: IntrinsicHost, callable: *const Value, args: []const Value, out: Output) !EvalResult {
        return self.vtable.invoke_callable(self.ctx, callable, args, out);
    }

    /// Safe to store and re-enter across activations.
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

    pub fn coroutineLastRootParkedOnce(self: IntrinsicHost) bool {
        if (self.vtable.coroutine_last_root_parked_once) |f| return f(self.ctx);
        return false;
    }

    pub fn coroutineNoteSuspensionHit(self: IntrinsicHost) void {
        if (self.vtable.coroutine_note_suspension_hit) |f| f(self.ctx);
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

pub const HostResultU64 = union(enum) {
    ok: u64,
    err: RuntimeError,
};

/// The callable entry points answer `RuntimeError.Unimplemented`.
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
    // An unwired host tolerates the call rather than dereferencing a null
    // slot.
    ih.coroutineArmSlot(1);
    ih.coroutineResumeSlotValue(1, .Unit);
    ih.coroutineDisarmSlot();
    try testing.expect(!ih.osThreadAlive(0));
}
