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

/// A member of the base a native calls on a value it was given, named by
/// the declaration rather than by its name: the value's class answers with
/// its own implementation, as a Kotlin call through that member would.
pub const WellKnown = enum(u8) {
    /// `Any.toString()`, `equals(other)`, `hashCode()`.
    to_string,
    equals,
    hash_code,
    /// `Comparable.compareTo(other)`, `Comparator.compare(a, b)`.
    compare_to,
    compare,
    /// `Iterable.iterator()`, `Iterator.hasNext()`, `Iterator.next()`.
    iterator,
    has_next,
    next,
    /// `Collection.size`, `contains(element)`, `isEmpty()`.
    size,
    contains,
    is_empty,
    /// `AbstractCollection.toArray()`, which `toTypedArray` copies through.
    to_array,
    /// `List.get(index)`.
    list_get,
    /// `Map.size`, `get(key)`, `containsKey(key)`, `entries`, `keys`,
    /// `values`.
    map_size,
    map_get,
    contains_key,
    entries,
    keys,
    values,
    /// `Map.Entry.key`, `Map.Entry.value`.
    entry_key,
    entry_value,
    /// `CharSequence.length`, `CharSequence.get(index)`.
    length,
    char_at,
    /// `Grouping.sourceIterator()`, `Grouping.keyOf(element)`.
    source_iterator,
    key_of,
    /// `Continuation.context`, `CoroutineScope.coroutineContext`.
    context,
    coroutine_context,
    /// `Random.nextInt(until)`, which a shuffle draws from.
    next_int,
    /// `CoroutineContext.get(key)`.
    context_get,
    /// `CoroutineExceptionHandler.handleException(context, exception)`.
    handle_exception,
    /// `Sequence.iterator()`.
    sequence_iterator,
    /// `FunctionN.invoke(...)`, of the arity the call passes: a class
    /// implementing a function type, called as the function.
    invoke,

    /// The member's name, for a host that answers by name.
    pub fn memberName(m: WellKnown) []const u8 {
        return switch (m) {
            .to_string => "toString",
            .equals => "equals",
            .hash_code => "hashCode",
            .compare_to => "compareTo",
            .compare => "compare",
            .iterator, .sequence_iterator => "iterator",
            .has_next => "hasNext",
            .next => "next",
            .size, .map_size => "size",
            .contains => "contains",
            .is_empty => "isEmpty",
            .to_array => "toArray",
            .list_get, .map_get, .char_at => "get",
            .contains_key => "containsKey",
            .entries => "entries",
            .keys => "keys",
            .values => "values",
            .entry_key => "key",
            .entry_value => "value",
            .length => "length",
            .source_iterator => "sourceIterator",
            .key_of => "keyOf",
            .context => "context",
            .coroutine_context => "coroutineContext",
            .next_int => "nextInt",
            .context_get => "get",
            .handle_exception => "handleException",
            .invoke => "invoke",
        };
    }

    /// Whether the member is a property, read through its getter.
    pub fn isProperty(m: WellKnown) bool {
        return switch (m) {
            .size, .map_size, .entries, .keys, .values, .entry_key, .entry_value, .length, .context, .coroutine_context => true,
            else => false,
        };
    }
};

/// A top-level property of the base or a pack a host fast path reads, named
/// by its declaration: its package, its name and the file declaring it,
/// since a file-private property's name can repeat across files.
pub const WellKnownStatic = enum(u8) {
    /// Compose's current snapshot per thread and its global snapshot.
    compose_thread_snapshot,
    compose_global_snapshot,
    /// Compose's global write observers, notified on every state write.
    compose_global_write_observers,
    /// The lock `SnapshotStateMap` mutates its state records under.
    compose_snapshot_map_sync,

    pub const Declaration = struct { package: []const u8, name: []const u8, file: []const u8 };

    pub fn declaration(w: WellKnownStatic) Declaration {
        const snapshots = "androidx.compose.runtime.snapshots";
        return switch (w) {
            .compose_thread_snapshot => .{ .package = snapshots, .name = "threadSnapshot", .file = "/Snapshot.kt" },
            .compose_global_snapshot => .{ .package = snapshots, .name = "globalSnapshot", .file = "/Snapshot.kt" },
            .compose_global_write_observers => .{ .package = snapshots, .name = "globalWriteObservers", .file = "/Snapshot.kt" },
            .compose_snapshot_map_sync => .{ .package = snapshots, .name = "sync", .file = "/SnapshotStateMap.kt" },
        };
    }
};

/// An object of the base or a pack a native needs, named by its
/// declaration.
pub const WellKnownObject = enum(u8) {
    /// `CoroutineExceptionHandler.Key`, the context key of a coroutine's
    /// exception handler.
    coroutine_exception_handler_key,
    /// `GlobalScope`, the scope a launch the host starts on its own runs in.
    global_scope,

    /// The object's FQN, as sema spells a nested class's.
    pub fn fqn(o: WellKnownObject) []const u8 {
        return switch (o) {
            .coroutine_exception_handler_key => "kotlinx.coroutines.CoroutineExceptionHandler.Key",
            .global_scope => "kotlinx.coroutines.GlobalScope",
        };
    }
};

/// A class of the base a native builds an instance of through its primary
/// constructor, named by its declaration.
pub const WellKnownClass = enum(u8) {
    /// `IndexedValue(index, value)`, the elements `withIndex` yields.
    indexed_value,

    /// The class's FQN, as sema spells a nested class's.
    pub fn fqn(c: WellKnownClass) []const u8 {
        return switch (c) {
            .indexed_value => "kotlin.collections.IndexedValue",
        };
    }
};

/// A value the host keeps its own state in and presents as an instance of
/// an abstract base type, whose members the host implements. Its class is
/// not in the tables, so a call on it reaches the host's implementation of
/// the member; the declaration it stands for only names it for display.
pub const HostInstance = enum(u8) {
    /// The receiver of a `sequence { }` or `iterator { }` block.
    sequence_scope,
    /// What `groupingBy` returns.
    grouping,
    /// A match's `groups`.
    match_group_collection,
    /// A reified type and one of its arguments.
    ktype,
    ktype_projection,

    /// The declaration the value stands for.
    pub fn fqn(k: HostInstance) []const u8 {
        return switch (k) {
            .sequence_scope => "kotlin.sequences.SequenceScope",
            .grouping => "kotlin.collections.Grouping",
            .match_group_collection => "kotlin.text.MatchNamedGroupCollection",
            .ktype => "kotlin.reflect.KType",
            .ktype_projection => "kotlin.reflect.KTypeProjection",
        };
    }

    /// The slots an instance of the kind holds, in order.
    pub fn layout(k: HostInstance) []const class_mod.LayoutSlot {
        return switch (k) {
            .sequence_scope => &.{ .{ .name = "__seq_has_value" }, .{ .name = "__seq_value" }, .{ .name = "__seq_yield_iter" } },
            .grouping => &.{ .{ .name = "__grouping_src" }, .{ .name = "__grouping_key" } },
            .match_group_collection => &.{.{ .name = "__mgc" }},
            .ktype, .ktype_projection => &.{},
        };
    }
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
        /// `member` of an instance whose class the host's tables cover, by
        /// its slot; null for any other value, which the native serves.
        call_well_known: ?*const fn (ctx: *anyopaque, receiver: *const Value, member: WellKnown, args: []const Value, out: Output) std.mem.Allocator.Error!?EvalResult = null,
        /// `object`, made on first use; null when the host's tables do not
        /// declare it.
        well_known_object: ?*const fn (ctx: *anyopaque, object: WellKnownObject) std.mem.Allocator.Error!?Value = null,
        alloc_instance_id: ?*const fn (ctx: *anyopaque) u64 = null,
        /// A host value presenting as `kind`, holding `fields`.
        new_host_instance: ?*const fn (ctx: *anyopaque, kind: HostInstance, identity: u64, fields: []const InstanceData.Field) std.mem.Allocator.Error!Value = null,
        /// A new `class` built by its primary constructor over `args`; null
        /// when the host's tables do not declare it.
        construct_well_known: ?*const fn (ctx: *anyopaque, class: WellKnownClass, args: []const Value, out: Output) std.mem.Allocator.Error!?EvalResult = null,
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
        coroutine_drain_to_idle: ?*const fn (ctx: *anyopaque, out: Output) std.mem.Allocator.Error!?RuntimeError = null,
        coroutine_resume_external: ?*const fn (ctx: *anyopaque, slot: i64, value: Value, out: Output) void = null,
        /// Run on the caller's stack, unlike `coroutine_resume_external`, which
        /// the pump queue defers because a native park passes through no
        /// interceptor.
        /// The throw the resumed coroutine let escape on this stack, for the
        /// resumer's `resumeWith` to throw.
        coroutine_resume_continuation: ?*const fn (ctx: *anyopaque, slot: i64, value: Value, out: Output) ?Value = null,
        /// Null runs the block inline on the calling thread.
        coroutine_dispatch_pooled: ?*const fn (ctx: *anyopaque, block: *const Value, io: bool, out: Output) std.mem.Allocator.Error!?RuntimeError = null,
        /// `name` is the thread's, as `Thread.name` answers it.
        spawn_os_thread: ?*const fn (ctx: *anyopaque, block: *const Value, name: []const u8, out: Output) std.mem.Allocator.Error!HostResultU64 = null,
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

    /// `member` of `receiver` through its class's slot; null when the
    /// host's tables do not cover the value, which the native then serves.
    pub fn callWellKnown(self: IntrinsicHost, receiver: *const Value, member: WellKnown, args: []const Value, out: Output) !?EvalResult {
        if (self.vtable.call_well_known) |f| return f(self.ctx, receiver, member, args, out);
        return null;
    }

    /// `object` from the host's tables; null when they do not declare it.
    pub fn wellKnownObject(self: IntrinsicHost, object: WellKnownObject) !?Value {
        if (self.vtable.well_known_object) |f| return f(self.ctx, object);
        return null;
    }

    pub fn allocInstanceId(self: IntrinsicHost) u64 {
        if (self.vtable.alloc_instance_id) |f| return f(self.ctx);
        return 0;
    }

    pub fn newHostInstance(self: IntrinsicHost, kind: HostInstance, identity: u64, fields: []const InstanceData.Field) !Value {
        if (self.vtable.new_host_instance) |f| return f(self.ctx, kind, identity, fields);
        return .Unit;
    }

    /// A new `class` over `args` through its primary constructor; null
    /// when the host's tables do not declare it.
    pub fn constructWellKnown(self: IntrinsicHost, class: WellKnownClass, args: []const Value, out: Output) !?EvalResult {
        if (self.vtable.construct_well_known) |f| return f(self.ctx, class, args, out);
        return null;
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

    pub fn coroutineResumeContinuation(self: IntrinsicHost, slot: i64, value: Value, out: Output) ?Value {
        if (self.vtable.coroutine_resume_continuation) |f| return f(self.ctx, slot, value, out);
        self.coroutineResumeExternal(slot, value, out);
        return null;
    }

    pub fn coroutineDispatchPooled(self: IntrinsicHost, block: *const Value, io_kind: bool, out: Output) !?RuntimeError {
        if (self.vtable.coroutine_dispatch_pooled) |f| return f(self.ctx, block, io_kind, out);
        const r = try self.invokeCallable(block, &.{}, out);
        return switch (r) {
            .ok => null,
            .err => |e| e,
        };
    }

    pub fn spawnOsThread(self: IntrinsicHost, block: *const Value, name: []const u8, out: Output) !HostResultU64 {
        if (self.vtable.spawn_os_thread) |f| return f(self.ctx, block, name, out);
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

const class_mod = @import("class.zig");
const InstanceData = class_mod.InstanceData;

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
