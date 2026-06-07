//! Side-channels the runtime exposes to Rust-native stdlib intrinsics:
//! the `StdlibFn` pointer, the `CallCtx` it receives, the `IntrinsicHost`
//! it calls back through, and the cooperative `Scheduler`.
//!
//! The Rust `IntrinsicHost` / `Scheduler` traits become `{ctx, vtable}`
//! pairs. Trait methods that carried a default body keep that default by
//! letting the vtable slot be optional (`null` = use the default).

const std = @import("std");
const value_mod = @import("value.zig");
const output_mod = @import("output.zig");

const Value = value_mod.Value;
const RuntimeError = value_mod.RuntimeError;
const EvalResult = value_mod.EvalResult;
const Output = output_mod.Output;

/// Function pointer signature for a Rust-native stdlib intrinsic.
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
    /// runtime — the scheduler and the lambda invoker.
    host: IntrinsicHost,
    /// Allocator for any heap the intrinsic produces.
    allocator: std.mem.Allocator,
};

/// Side-channel the runtime exposes to stdlib intrinsics. A `{ctx,
/// vtable}` pair mirroring Rust's `&mut dyn IntrinsicHost`. Vtable slots
/// that were trait defaults are optional; `null` selects the default
/// behavior implemented in the wrapper methods below.
pub const IntrinsicHost = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Cooperative scheduler accessor (required).
        scheduler: *const fn (ctx: *anyopaque) Scheduler,
        /// Invoke a callable `Value` with the supplied args (required).
        invoke_callable: *const fn (ctx: *anyopaque, callable: *const Value, args: []const Value, out: Output) std.mem.Allocator.Error!EvalResult,
        /// Invoke a callable binding `this` to `this_value` (required).
        invoke_callable_with_this: *const fn (ctx: *anyopaque, callable: *const Value, args: []const Value, this_value: *const Value, out: Output) std.mem.Allocator.Error!EvalResult,
        /// Invoke a named method on a receiver. `null` slot => default
        /// (returns `null`, i.e. fall back to structural rendering).
        invoke_method: ?*const fn (ctx: *anyopaque, receiver: *const Value, name: []const u8, args: []const Value, out: Output) std.mem.Allocator.Error!?EvalResult = null,
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
        /// Spawn a child coroutine. `null` => default (run eagerly).
        coroutine_launch: ?*const fn (ctx: *anyopaque, block: *const Value, scope: *const Value, out: Output) std.mem.Allocator.Error!?RuntimeError = null,
        coroutine_park_slot: ?*const fn (ctx: *anyopaque, slot: i64) void = null,
        coroutine_arm_slot: ?*const fn (ctx: *anyopaque, slot: i64) void = null,
        coroutine_disarm_slot: ?*const fn (ctx: *anyopaque) void = null,
        coroutine_resume_slot: ?*const fn (ctx: *anyopaque, slot: i64) void = null,
        coroutine_resume_slot_value: ?*const fn (ctx: *anyopaque, slot: i64, value: Value) void = null,
        coroutine_cancel_timed_parks_with: ?*const fn (ctx: *anyopaque, cause: ?Value) void = null,
        coroutine_drain_to_idle: ?*const fn (ctx: *anyopaque, out: Output) std.mem.Allocator.Error!?RuntimeError = null,
        coroutine_resume_external: ?*const fn (ctx: *anyopaque, slot: i64, value: Value, out: Output) void = null,
        spawn_os_thread: ?*const fn (ctx: *anyopaque, block: *const Value, out: Output) std.mem.Allocator.Error!HostResultU64 = null,
        join_os_thread: ?*const fn (ctx: *anyopaque, id: u64) std.mem.Allocator.Error!?RuntimeError = null,
        os_thread_alive: ?*const fn (ctx: *anyopaque, id: u64) bool = null,
        dispatch_coroutine: ?*const fn (ctx: *anyopaque, block: *const Value, elastic: bool, out: Output) std.mem.Allocator.Error!HostResultU64 = null,
        join_dispatched: ?*const fn (ctx: *anyopaque, id: u64) std.mem.Allocator.Error!?RuntimeError = null,
    };

    pub fn scheduler(self: IntrinsicHost) Scheduler {
        return self.vtable.scheduler(self.ctx);
    }

    pub fn invokeCallable(self: IntrinsicHost, callable: *const Value, args: []const Value, out: Output) !EvalResult {
        return self.vtable.invoke_callable(self.ctx, callable, args, out);
    }

    pub fn invokeCallableWithThis(self: IntrinsicHost, callable: *const Value, args: []const Value, this_value: *const Value, out: Output) !EvalResult {
        return self.vtable.invoke_callable_with_this(self.ctx, callable, args, this_value, out);
    }

    pub fn invokeMethod(self: IntrinsicHost, receiver: *const Value, name: []const u8, args: []const Value, out: Output) !?EvalResult {
        if (self.vtable.invoke_method) |f| return f(self.ctx, receiver, name, args, out);
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

    pub fn coroutineLaunch(self: IntrinsicHost, block: *const Value, scope: *const Value, out: Output) !?RuntimeError {
        if (self.vtable.coroutine_launch) |f| return f(self.ctx, block, scope, out);
        const r = try self.invokeCallableWithThis(block, &.{}, scope, out);
        return switch (r) {
            .ok => null,
            .err => |e| e,
        };
    }

    pub fn coroutineParkSlot(self: IntrinsicHost, slot: i64) void {
        if (self.vtable.coroutine_park_slot) |f| f(self.ctx, slot);
    }

    pub fn coroutineArmSlot(self: IntrinsicHost, slot: i64) void {
        if (self.vtable.coroutine_arm_slot) |f| f(self.ctx, slot);
    }

    pub fn coroutineDisarmSlot(self: IntrinsicHost) void {
        if (self.vtable.coroutine_disarm_slot) |f| f(self.ctx);
    }

    pub fn coroutineResumeSlot(self: IntrinsicHost, slot: i64) void {
        if (self.vtable.coroutine_resume_slot) |f| f(self.ctx, slot);
    }

    pub fn coroutineResumeSlotValue(self: IntrinsicHost, slot: i64, value: Value) void {
        if (self.vtable.coroutine_resume_slot_value) |f| f(self.ctx, slot, value);
    }

    pub fn coroutineCancelTimedParks(self: IntrinsicHost) void {
        self.coroutineCancelTimedParksWith(null);
    }

    pub fn coroutineCancelTimedParksWith(self: IntrinsicHost, cause: ?Value) void {
        if (self.vtable.coroutine_cancel_timed_parks_with) |f| f(self.ctx, cause);
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

    pub fn dispatchCoroutine(self: IntrinsicHost, block: *const Value, elastic: bool, out: Output) !HostResultU64 {
        if (self.vtable.dispatch_coroutine) |f| return f(self.ctx, block, elastic, out);
        return self.spawnOsThread(block, out);
    }

    pub fn joinDispatched(self: IntrinsicHost, id: u64) !?RuntimeError {
        if (self.vtable.join_dispatched) |f| return f(self.ctx, id);
        return self.joinOsThread(id);
    }
};

/// `Result<u64, RuntimeError>` for the OS-thread/dispatch entry points.
pub const HostResultU64 = union(enum) {
    ok: u64,
    err: RuntimeError,
};

/// Cooperative scheduler the runtime exposes. A `{ctx, vtable}` pair
/// mirroring Rust's `&mut dyn Scheduler`. Drain calls hand back an owned
/// slice the caller frees.
pub const Scheduler = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        spawn: *const fn (ctx: *anyopaque, block: Value) std.mem.Allocator.Error!void,
        schedule_resume: *const fn (ctx: *anyopaque, cont: Value) std.mem.Allocator.Error!void,
        drain_launches: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error![]Value,
        drain_resumes: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error![]Value,
    };

    pub fn spawn(self: Scheduler, block: Value) !void {
        return self.vtable.spawn(self.ctx, block);
    }
    pub fn scheduleResume(self: Scheduler, cont: Value) !void {
        return self.vtable.schedule_resume(self.ctx, cont);
    }
    pub fn drainLaunches(self: Scheduler, allocator: std.mem.Allocator) ![]Value {
        return self.vtable.drain_launches(self.ctx, allocator);
    }
    pub fn drainResumes(self: Scheduler, allocator: std.mem.Allocator) ![]Value {
        return self.vtable.drain_resumes(self.ctx, allocator);
    }
};

/// Default scheduler — keeps spawn/resume queues in a pair of lists.
pub const InProcessScheduler = struct {
    launches: std.ArrayList(Value) = .empty,
    resumes: std.ArrayList(Value) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) InProcessScheduler {
        return .{ .launches = .empty, .resumes = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *InProcessScheduler) void {
        self.launches.deinit(self.allocator);
        self.resumes.deinit(self.allocator);
    }

    fn vtSpawn(ctx: *anyopaque, block: Value) std.mem.Allocator.Error!void {
        const self: *InProcessScheduler = @ptrCast(@alignCast(ctx));
        try self.launches.append(self.allocator, block);
    }
    fn vtScheduleResume(ctx: *anyopaque, cont: Value) std.mem.Allocator.Error!void {
        const self: *InProcessScheduler = @ptrCast(@alignCast(ctx));
        try self.resumes.append(self.allocator, cont);
    }
    fn vtDrainLaunches(ctx: *anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error![]Value {
        const self: *InProcessScheduler = @ptrCast(@alignCast(ctx));
        const out = try self.launches.toOwnedSlice(self.allocator);
        _ = allocator;
        return out;
    }
    fn vtDrainResumes(ctx: *anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error![]Value {
        const self: *InProcessScheduler = @ptrCast(@alignCast(ctx));
        const out = try self.resumes.toOwnedSlice(self.allocator);
        _ = allocator;
        return out;
    }

    const vtable: Scheduler.VTable = .{
        .spawn = vtSpawn,
        .schedule_resume = vtScheduleResume,
        .drain_launches = vtDrainLaunches,
        .drain_resumes = vtDrainResumes,
    };

    pub fn scheduler(self: *InProcessScheduler) Scheduler {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

/// Bare-minimum host for unit tests of pure intrinsics. The callable
/// entry points return `RuntimeError.Unimplemented` data; the scheduler
/// is the in-process default.
pub const NoopHost = struct {
    scheduler_impl: InProcessScheduler,

    pub fn init(allocator: std.mem.Allocator) NoopHost {
        return .{ .scheduler_impl = InProcessScheduler.init(allocator) };
    }

    pub fn deinit(self: *NoopHost) void {
        self.scheduler_impl.deinit();
    }

    fn vtScheduler(ctx: *anyopaque) Scheduler {
        const self: *NoopHost = @ptrCast(@alignCast(ctx));
        return self.scheduler_impl.scheduler();
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
        .scheduler = vtScheduler,
        .invoke_callable = vtInvokeCallable,
        .invoke_callable_with_this = vtInvokeCallableWithThis,
    };

    pub fn host(self: *NoopHost) IntrinsicHost {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

const InstanceData = @import("class.zig").InstanceData;

const testing = std.testing;

test "in-process scheduler spawns and drains FIFO" {
    var sched = InProcessScheduler.init(testing.allocator);
    defer sched.deinit();
    const s = sched.scheduler();
    try s.spawn(.{ .Int = 1 });
    try s.spawn(.{ .Int = 2 });
    const launches = try s.drainLaunches(testing.allocator);
    defer testing.allocator.free(launches);
    try testing.expectEqual(@as(usize, 2), launches.len);
    // Draining again yields an empty batch.
    const again = try s.drainLaunches(testing.allocator);
    defer testing.allocator.free(again);
    try testing.expectEqual(@as(usize, 0), again.len);
}

test "noop host reports unimplemented for callables" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = output_mod.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const callable: Value = .Unit;
    const r = try h.host().invokeCallable(&callable, &.{}, cap.output());
    try testing.expect(r == .err);
}
