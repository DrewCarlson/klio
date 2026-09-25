//! `runtime.IntrinsicHost` implementation for `VmIntrinsicHost`: the side channel
//! the stdlib reaches through to invoke lambdas, resolve globals, synthesize
//! instances, and drive the coroutine and thread machinery. Free functions wired
//! into the vtable by `vmhost.zig`; each transient `VmHost` shares live program state.

const std = @import("std");
const stdlib = @import("stdlib");

const ir = @import("ir");
const runtime = @import("runtime");

const root = @import("../interp_ir.zig");
const vmhost = @import("vmhost.zig");
const scheduler = @import("scheduler.zig");
const trace = @import("trace.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const Output = runtime.Output;
const RuntimeError = runtime.RuntimeError;
const HostResultU64 = runtime.HostResultU64;
const InstanceData = runtime.InstanceData;
const RuntimeEvalResult = runtime.EvalResult;

const EvalError = ir.eval.EvalError;
const EvalResult = ir.eval.EvalResult;
const SuspendState = ir.eval.SuspendState;

const SendableVmSeed = root.SendableVmSeed;
const ThreadResult = root.ThreadResult;

/// `Result<Value, EvalError>` for the raw coroutine-facing helpers.
pub const RawResult = EvalResult;

/// Transient `VmHost` borrowing this host's shared state, bound to `out` for one
/// evaluation. Handles are copied by value: the view owns nothing, needs no deinit.
pub fn vmHost(self: *VmIntrinsicHost, out: Output) VmHost {
    const state = vmhost.SharedHandles.fromIntrinsic(self);
    return VmHost.borrowed(state, out);
}

/// Sibling `VmIntrinsicHost` over the same shared state; borrows by value, owns nothing.
pub fn childHost(self: *VmIntrinsicHost) VmIntrinsicHost {
    return VmIntrinsicHost.borrowed(vmhost.SharedHandles.fromIntrinsic(self));
}

/// Guards the allocator shared with a worker, copied verbatim into the seed. Sound
/// only while it is thread-safe (an arena over `page_allocator`, or `smp_allocator`)
/// and nothing resets or deinits it while a worker lives (`Vm.run` joins every worker
/// first). Only the degenerate case is checkable, under `KLIO_TRACE_INVARIANTS`.
fn assertSpawnAllocatorInvariant(allocator: Allocator, comptime site: []const u8) void {
    const ok = @intFromPtr(allocator.vtable) != 0;
    if (!ok and trace.invariantsEnabled()) {
        trace.invariant("kind=spawn_allocator site=" ++ site ++ " detail=degenerate_allocator", .{});
    }
    std.debug.assert(ok);
}

fn spawnSeed(self: *VmIntrinsicHost) SendableVmSeed {
    assertSpawnAllocatorInvariant(self.allocator, "spawnSeed");
    return .{
        .module = self.module.clone(),
        .instance_id_counter = self.instance_id_counter.clone(),
        .closures = self.closures.clone(),
        .out_sink = self.out_sink.clone(),
        .threads = self.threads.clone(),
        .resolved_state = if (self.resolved_state) |rs| rs.clone() else null,
        .allocator = self.allocator,
    };
}

/// Map an `EvalError` onto `RuntimeError`; variants with no counterpart become `Type`.
fn runtimeErrorFromEval(e: EvalError) RuntimeError {
    return switch (e) {
        .Throw => |v| .{ .Thrown = v },
        .NonLocalReturn => |v| .{ .Return = v },
        .Suspended => blk: {
            // Always a defect: the activation is dropped and its Job never completes.
            std.debug.print("[SUSPEND-LOST] coroutine suspended across a non-suspending boundary; activation dropped\n", .{});
            if (runtime.envOnce("KLIO_ERR_TRACE") != null) std.debug.dumpCurrentStackTrace(.{});
            ir.eval.dumpFrameChainForDiag();
            break :blk .{ .Type = "coroutine suspended across a non-suspending boundary" };
        },
        .Unsupported => |s| .{ .Type = s },
        .Type => |s| .{ .Type = s },
        .Unbound => |s| .{ .Unbound = s },
        .Unimplemented => |s| .{ .Unimplemented = s },
        .CalleeFailed => |s| .{ .CalleeFailed = s },
        .Arity => |s| .{ .Arity = s },
        .StackOverflow => |s| .{ .Type = s },
        .LabeledReturn => |lr| .{ .LabeledReturn = .{ .label = lr.label, .value = lr.value } },
    };
}

fn flattenEval(r: EvalResult) RuntimeEvalResult {
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = runtimeErrorFromEval(e) },
    };
}

/// Evaluate an `IrClosure` with the raw `EvalError` out, so the driver sees `Suspended`.
pub fn evalClosureRaw(
    self: *VmIntrinsicHost,
    callable: *const Value,
    args: []const Value,
    this_value: ?*const Value,
    out: Output,
) Allocator.Error!RawResult {
    if (callable.* != .IrClosure) {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "coroutine block is not a closure: `{s}`",
            .{callable.typeFqn()},
        );
        return .{ .err = .{ .Type = msg } };
    }
    const id = callable.IrClosure.asPtrConst().id;
    const live_captures = callable.IrClosure;

    const info = self.closures.get(@intCast(id)) orelse {
        const msg = try std.fmt.allocPrint(self.allocator, "unknown IrClosure id {d}", .{id});
        return .{ .err = .{ .Type = msg } };
    };

    const module_g = self.module.borrow();
    defer module_g.deinit();
    const module = info.module orelse module_g.get();
    const func = module.funcById(info.body_func) orelse {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "closure body FuncId {d} out of range",
            .{info.body_func.int()},
        );
        return .{ .err = .{ .Type = msg } };
    };

    // With a receiver, prepend it when the body declares a param; else pad to `n_params`.
    var call_args: std.ArrayList(Value) = .empty;
    defer call_args.deinit(self.allocator);
    try call_args.ensureTotalCapacity(self.allocator, @max(info.n_params, args.len));
    if (this_value) |t| {
        if (info.n_params >= 1) {
            try call_args.append(self.allocator, t.*);
            for (args) |a| try call_args.append(self.allocator, a);
        } else {
            try call_args.appendSlice(self.allocator, args);
        }
    } else {
        var i: usize = 0;
        while (i < info.n_params) : (i += 1) {
            try call_args.append(self.allocator, if (i < args.len) args[i] else .Null);
        }
    }
    while (call_args.items.len < info.n_params) {
        try call_args.append(self.allocator, .Null);
    }

    // Prefer the closure Value's live captures; fall back to the `ClosureInfo` cell.
    var capture_values: std.ArrayList(Value) = .empty;
    defer capture_values.deinit(self.allocator);
    {
        const lc_g = live_captures.borrow();
        defer lc_g.deinit();
        const lc = lc_g.get().captures;
        if (lc.len == info.capture_names.len) {
            try capture_values.appendSlice(self.allocator, lc);
        } else {
            const cap_g = info.captures.borrow();
            defer cap_g.deinit();
            try capture_values.appendSlice(self.allocator, cap_g.get().items);
        }
    }
    if (this_value) |t| {
        for (info.capture_names, 0..) |n, idx| {
            if (std.mem.eql(u8, n, "this") and idx < capture_values.items.len) {
                capture_values.items[idx] = t.*;
            }
        }
    }

    // A captured `var` rides as a shared `Value.Cell`: a write is seen where declared.
    var args_owned: std.ArrayList(Value) = .empty;
    try args_owned.appendSlice(self.allocator, call_args.items);
    var caps_owned: std.ArrayList(Value) = .empty;
    try caps_owned.appendSlice(self.allocator, capture_values.items);

    const state = vmhost.SharedHandles.fromIntrinsic(self);
    var host = VmHost.borrowed(state, out);
    vmhost.emitPath(self.allocator, "coroutine_closure", func.fqn, info.body_func, this_value, args);
    return ir.eval.evalClosure(VmHost, self.allocator, module, info.module, func, args_owned, caps_owned, callable.IrClosure, &host);
}

/// Evaluate a top-level no-arg function as a coroutine driver root, raw `EvalError` out.
pub fn evalFuncRaw(self: *VmIntrinsicHost, func_id: ir.FuncId, out: Output) Allocator.Error!RawResult {
    const module_g = self.module.borrow();
    defer module_g.deinit();
    const module = module_g.get();
    const func = module.funcById(func_id) orelse {
        return .{ .err = .{ .Type = "invalid main FuncId" } };
    };
    const state = vmhost.SharedHandles.fromIntrinsic(self);
    var host = VmHost.borrowed(state, out);
    const empty: std.ArrayList(Value) = .empty;
    return ir.eval.evalWith(VmHost, self.allocator, module, func, empty, &host);
}

/// Resume a parked activation with `value`, raw `EvalError` out.
pub fn resumeRaw(self: *VmIntrinsicHost, state: *SuspendState, value: Value, out: Output) Allocator.Error!RawResult {
    const module_g = self.module.borrow();
    defer module_g.deinit();
    const module = module_g.get();
    var host = vmHost(self, out);
    return ir.eval.resumeContinuation(VmHost, self.allocator, module, state, value, &host);
}

const coroutines = @import("coroutines.zig");

pub fn runBlocking(self: *VmIntrinsicHost, block: *const Value, scope: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return coroutines.runBlocking(self, block, scope, out);
}

pub fn coroutineRunRoot(self: *VmIntrinsicHost, scope: ?*const Value, block: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return coroutines.coroutineRunRoot(self, scope, block, out);
}

pub fn coroutineStartRootOrSuspended(self: *VmIntrinsicHost, scope: ?*const Value, block: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    return coroutines.coroutineStartRootOrSuspended(self, scope, block, out);
}

pub fn coroutineLaunch(self: *VmIntrinsicHost, block: *const Value, scope: *const Value, out: Output) Allocator.Error!?RuntimeError {
    return coroutines.coroutineLaunch(self, block, scope, out);
}

pub fn coroutineSpawnTimeout(self: *VmIntrinsicHost, block: *const Value, out: Output) Allocator.Error!?RuntimeError {
    return coroutines.coroutineSpawnTimeout(self, block, out);
}

pub fn coroutineArmSlot(self: *VmIntrinsicHost, slot: i64) void {
    coroutines.coroutineArmSlot(self, slot);
}

pub fn coroutineDisarmSlot(self: *VmIntrinsicHost) void {
    coroutines.coroutineDisarmSlot(self);
}

pub fn coroutineLastRootParkedOnce(self: *VmIntrinsicHost) bool {
    return coroutines.coroutineLastRootParkedOnce(self);
}

pub fn coroutineNoteSuspensionHit(self: *VmIntrinsicHost) void {
    coroutines.coroutineNoteSuspensionHit(self);
}

pub fn coroutinePushScope(self: *VmIntrinsicHost, scope: *const Value) void {
    _ = self;
    coroutines.coroutinePushScope(scope);
}

pub fn coroutinePopScope(self: *VmIntrinsicHost) void {
    _ = self;
    coroutines.coroutinePopScope();
}

pub fn coroutineResumeSlotValue(self: *VmIntrinsicHost, slot: i64, value: Value) void {
    coroutines.coroutineResumeSlotValue(self, slot, value);
}

pub fn markSlotOwnerSchedulerBacked(slot: i64) void {
    coroutines.markSlotOwnerSchedulerBacked(slot);
}

pub fn activeCoroScope(self: *VmIntrinsicHost) ?Value {
    _ = self;
    return coroutines.activeCoroScope();
}

pub fn coroutineResumeExternal(self: *VmIntrinsicHost, slot: i64, value: Value, out: Output) void {
    _ = coroutines.coroutineResumeExternal(self, slot, value, out) catch null;
}

pub fn coroutineResumeContinuation(self: *VmIntrinsicHost, slot: i64, value: Value, out: Output) ?Value {
    return coroutines.coroutineResumeContinuation(self, slot, value, out) catch null;
}

pub fn coroutineDrainToIdle(self: *VmIntrinsicHost, out: Output) Allocator.Error!?RuntimeError {
    return coroutines.coroutineDrainToIdle(self, out);
}

/// Whether `v` is a companion-object singleton, recognized by a `$Companion$`
/// lift name or a `.Companion` FQN tail.
/// Calls `callable` over `args` for a native: a closure made from sema's
/// code, a native value, an instance of a class implementing the function
/// type of the call's arity, or a host comparator.
pub fn invokeCallable(self: *VmIntrinsicHost, callable: *const Value, args: []const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    if (callable.* == .IrClosure) return invokeResolvedClosure(self, callable, null, args, out);

    if (callable.* == .Intrinsic) {
        var child = childHost(self);
        stdlib.implementations.string.clearRecvMemo();
        var ctx = runtime.CallCtx{
            .args = args,
            .out = out,
            .host = child.intrinsicHost(),
            .allocator = self.allocator,
        };
        vmhost.emitPath(self.allocator, "intrinsic_hof", callable.Intrinsic.fqn, null, null, args);
        return callable.Intrinsic.func(&ctx);
    }

    // An instance of a class implementing a function type is called through
    // its `invoke` of the call's arity.
    if (callable.* == .Instance) {
        if (try callWellKnown(self, callable, .invoke, args, out)) |r| return r;
    }

    // `Comparator` is a `fun interface`: invoking it as a value calls `compare`.
    if (callable.* == .Comparator and args.len == 2) {
        if (try callWellKnown(self, callable, .compare, args, out)) |r| return r;
    }

    const msg = try std.fmt.allocPrint(self.allocator, "Vm::invoke_callable on `{s}`", .{callable.typeFqn()});
    return .{ .err = .{ .Unimplemented = msg } };
}

/// Runs a closure lowered from sema exactly: its body takes `this_value`
/// (a receiver lambda's receiver, its first parameter) and then `args`; a
/// bound property reference's receiver comes first of all.
fn invokeResolvedClosure(self: *VmIntrinsicHost, callable: *const Value, this_value: ?*const Value, args: []const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    var host = vmHost(self, out);
    const body = host.resolvedClosure(callable) orelse return .{ .err = .{ .Type = "closure body is not in the module" } };
    const given = args.len + @intFromBool(this_value != null);
    if (given != body.arity()) {
        const msg = try std.fmt.allocPrint(self.allocator, "closure of {s} takes {d} arguments, called with {d}", .{ body.func.fqn, body.arity(), given });
        return .{ .err = .{ .Type = msg } };
    }
    var params: std.ArrayList(Value) = .empty;
    var caps: std.ArrayList(Value) = .empty;
    {
        const g = callable.IrClosure.borrow();
        defer g.deinit();
        const closure_caps = g.get().captures;
        switch (body.kind) {
            .property_ref => |p| if (p.bound and closure_caps.len != 0) try params.append(self.allocator, closure_caps[0]),
            else => try caps.appendSlice(self.allocator, closure_caps),
        }
    }
    if (this_value) |t| try params.append(self.allocator, t.*);
    try params.appendSlice(self.allocator, args);
    const result = try ir.eval.evalClosure(VmHost, self.allocator, body.module, body.owning, body.func, params, caps, callable.IrClosure, &host);
    return flattenEval(result);
}

/// `callable` called with `this_value` as its receiver: a receiver lambda
/// or a reference takes it as its first argument.
pub fn invokeCallableWithThis(self: *VmIntrinsicHost, callable: *const Value, args: []const Value, this_value: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    if (callable.* == .IrClosure) return invokeResolvedClosure(self, callable, this_value, args, out);
    if (callable.* == .Instance) {
        var with_recv: std.ArrayList(Value) = .empty;
        defer with_recv.deinit(self.allocator);
        try with_recv.append(self.allocator, this_value.*);
        try with_recv.appendSlice(self.allocator, args);
        return invokeCallable(self, callable, with_recv.items, out);
    }
    const msg = try std.fmt.allocPrint(self.allocator, "Vm::invoke_callable_with_this on `{s}`", .{callable.typeFqn()});
    return .{ .err = .{ .Unimplemented = msg } };
}

/// `member` of an instance lowered from sema through its class's slot
/// (`host_resolved.callWellKnown`); null for any other value.
pub fn callWellKnown(self: *VmIntrinsicHost, receiver: *const Value, member: runtime.WellKnown, args: []const Value, out: Output) Allocator.Error!?RuntimeEvalResult {
    var host = vmHost(self, out);
    const r = (try vmhost.host_resolved.callWellKnown(&host, self.allocator, receiver, member, args)) orelse return null;
    return flattenEval(r);
}

/// `object` from the tables (`host_resolved.wellKnownObject`); null when
/// they do not declare it or making it failed.
pub fn wellKnownObject(self: *VmIntrinsicHost, object: runtime.WellKnownObject) Allocator.Error!?Value {
    var host = vmHost(self, self.out_sink.output());
    const r = (try vmhost.host_resolved.wellKnownObject(&host, self.allocator, object)) orelse return null;
    return switch (r) {
        .ok => |v| v,
        .err => null,
    };
}

pub fn allocInstanceId(self: *VmIntrinsicHost) u64 {
    const g = self.instance_id_counter.borrowMut();
    defer g.deinit();
    return g.get().fetchAdd(1, .monotonic) + 1;
}

/// A new `class` through its primary constructor over `args`; null when
/// the tables do not declare it (`host_resolved.constructWellKnown`).
pub fn constructWellKnown(self: *VmIntrinsicHost, class: runtime.WellKnownClass, args: []const Value, out: Output) Allocator.Error!?RuntimeEvalResult {
    var host = vmHost(self, out);
    const r = (try vmhost.host_resolved.constructWellKnown(&host, self.allocator, class, args)) orelse return null;
    return flattenEval(r);
}

/// A host value presenting as `kind`: an instance of a class the tables do
/// not hold, so a call on it reaches the host's implementation of the
/// member. Its slots are the kind's layout; each of `fields` fills the slot
/// of its name, and the rest hold null.
pub fn newHostInstance(self: *VmIntrinsicHost, kind: runtime.HostInstance, identity: u64, fields: []const InstanceData.Field) Allocator.Error!Value {
    const class_fqn = kind.fqn();
    const simple = if (std.mem.findScalarLast(u8, class_fqn, '.')) |i| class_fqn[i + 1 ..] else class_fqn;
    const class_def = try ClassDef.minimal(self.allocator, simple, class_fqn, std.math.maxInt(u32));
    const def = class_def.asPtr();
    def.is_anonymous = true;
    def.layout_slots = kind.layout();
    const slots = try self.allocator.alloc(Value, def.layout_slots.len);
    errdefer self.allocator.free(slots);
    @memset(slots, .Null);
    for (fields) |f| {
        const i = for (def.layout_slots, 0..) |sl, i| {
            if (std.mem.eql(u8, sl.name, f.name)) break i;
        } else std.debug.panic("a {s} has no slot `{s}`", .{ class_fqn, f.name });
        slots[i] = f.value;
    }
    const inst = try ObjRef(InstanceData).init(self.allocator, .{
        .class = class_def,
        .slots = slots,
        .outer = null,
        .identity = identity,
        .native_state = null,
    });
    return .{ .Instance = inst };
}

const WorkerArgs = struct {
    seed: SendableVmSeed,
    block: Value,
    time_mode: root.TimeMode,
    /// The child `Vm` shares the spawning run's arena, so it takes the same
    /// `ObjRef.deinit` path.
    reclaim: bool,
    threads: root.ThreadTable,
    id: u64,
    name: []const u8,
    handoff: u64,
};

// A spawned thread's block from `startWorker` until its worker has pinned it.
// The worker joins the mutator set only once it runs, so a collection in that
// window reaches the block through this set alone. Keyed by a process-wide
// token: thread ids are per program, and programs share the heap.
var handoff_lock: runtime.SpinMutex = .{};
var handoff_blocks: std.AutoArrayHashMapUnmanaged(u64, Value) = .empty;
var handoff_seq = std.atomic.Value(u64).init(0);
var handoff_root = std.atomic.Value(bool).init(false);
var handoff_root_lock: runtime.SpinMutex = .{};

fn handoffPut(block: Value) Allocator.Error!u64 {
    const token = handoff_seq.fetchAdd(1, .monotonic);
    if (!runtime.gc.gc_enabled) return token;
    if (!handoff_root.load(.acquire)) {
        handoff_root_lock.lock();
        defer handoff_root_lock.unlock();
        if (!handoff_root.load(.acquire)) {
            runtime.gc.registerRoot(gcMarkHandoff);
            handoff_root.store(true, .release);
        }
    }
    handoff_lock.lock();
    defer handoff_lock.unlock();
    try handoff_blocks.put(std.heap.page_allocator, token, block);
    return token;
}

fn handoffTake(token: u64) void {
    handoff_lock.lock();
    defer handoff_lock.unlock();
    _ = handoff_blocks.swapRemove(token);
}

fn gcMarkHandoff(m: *runtime.gc.Marker) void {
    handoff_lock.lock();
    defer handoff_lock.unlock();
    for (handoff_blocks.values()) |v| v.gcMark(m);
}

fn publishThreadResult(threads: root.ThreadTable, id: u64, result: ThreadResult) void {
    const g = threads.borrowMut();
    defer g.deinit();
    if (g.get().getPtr(id)) |entry| {
        entry.result = result;
        entry.finished.store(true, .release);
    }
}

fn workerEntry(wargs: WorkerArgs) void {
    runtime.enterThreadStack(runtime.WORKER_STACK_SIZE);
    const tid = std.Thread.getCurrentId();
    runtime.setThreadName(tid, wargs.name);
    defer runtime.clearThreadName(tid);
    var args = wargs;
    defer runtime.slab.flushMagazines();
    assertSpawnAllocatorInvariant(args.seed.allocator, "workerEntry");
    root.setCoroutineTimeMode(args.time_mode);
    runtime.setReclaim(args.reclaim);
    // Join the mutator set for the worker's lifetime; per-thread GC roots unlink here.
    coroutines.gcThreadEnter();
    defer coroutines.gcThreadExit();
    // Pin the block: its captures are reachable only through this stack local.
    const ka = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka);
    runtime.keepalivePush(args.block);
    handoffTake(args.handoff);
    // Balance the spawn-time retain. Registered before `vm.deinit` so it runs
    // after the child Vm tears down (LIFO), keeping the block alive throughout.
    defer if (runtime.reclaimEnabled()) args.block.release(args.seed.allocator);
    var vm = args.seed.materialize() catch {
        publishThreadResult(args.threads, args.id, .{ .err = .{ .Type = "failed to materialize worker Vm" } });
        return;
    };
    defer vm.deinit();
    const r = vm.runThreadBlock(&args.block) catch {
        publishThreadResult(args.threads, args.id, .{ .err = .{ .Type = "worker out of memory" } });
        return;
    };
    // Happens-before to the joining parent: each cell's lock plus the parent's `join()`.
    switch (r) {
        .ok => publishThreadResult(args.threads, args.id, .{ .ok = {} }),
        .err => |e| switch (e) {
            .Return => publishThreadResult(args.threads, args.id, .{ .ok = {} }),
            // A throwable that ends the thread goes to its uncaught handler,
            // which by default prints it as the JVM's does; the thread that
            // joins it carries on.
            .Thrown => |v| {
                reportUncaught(&vm, v, args.name);
                publishThreadResult(args.threads, args.id, .{ .ok = {} });
            },
            else => publishThreadResult(args.threads, args.id, .{ .err = e }),
        },
    }
}

/// `Exception in thread "<name>" ` and the throwable's stack trace on
/// stderr, as the JVM's default uncaught handler prints them.
fn reportUncaught(vm: *root.Vm, v: Value, name: []const u8) void {
    // Rendering runs the throwable's `toString`; the value is held only here.
    const ka = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka);
    runtime.keepalivePush(v);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const text = vm.threadUncaughtText(arena.allocator(), &v, name) catch return;
    std.debug.print("{s}\n", .{text});
}

/// Spawn a worker thread for `block`. Every cell the child reaches orders concurrent
/// borrows through its own lock, and `Thread.spawn`/`join` bracket the happens-before.
fn startWorker(self: *VmIntrinsicHost, block: *const Value, name_in: []const u8) Allocator.Error!HostResultU64 {
    const name = try self.allocator.dupe(u8, name_in);
    const id = blk: {
        const g = self.instance_id_counter.borrowMut();
        defer g.deinit();
        break :blk g.get().fetchAdd(1, .monotonic);
    };

    // Register the entry before the worker starts so its result finds a slot.
    {
        const g = self.threads.borrowMut();
        defer g.deinit();
        try g.get().put(id, .{ .handle = null, .result = null, .name = name });
    }

    // The block and the graph its captures reach cross to a worker that may outlive
    // this frame's hold; retain, and `workerEntry` releases when the task finishes.
    block.retain();
    const handoff = handoffPut(block.*) catch |e| {
        block.release(self.allocator);
        const g = self.threads.borrowMut();
        defer g.deinit();
        _ = g.get().remove(id);
        return e;
    };
    const wargs = WorkerArgs{
        .seed = spawnSeed(self),
        .block = block.*,
        .time_mode = root.coroutineTimeMode(),
        .reclaim = runtime.reclaimEnabled(),
        .threads = self.threads.clone(),
        .id = id,
        .name = name,
        .handoff = handoff,
    };

    const handle = std.Thread.spawn(.{ .stack_size = runtime.WORKER_STACK_SIZE }, workerEntry, .{wargs}) catch {
        handoffTake(handoff);
        block.release(self.allocator);
        const g = self.threads.borrowMut();
        defer g.deinit();
        _ = g.get().remove(id);
        return .{ .err = .{ .Type = "failed to spawn OS thread" } };
    };
    {
        const g = self.threads.borrowMut();
        defer g.deinit();
        if (g.get().getPtr(id)) |entry| entry.handle = handle;
    }
    return .{ .ok = id };
}

/// Spawn `block` on a real OS thread, returning an id joined through the thread table.
pub fn spawnOsThread(self: *VmIntrinsicHost, block: *const Value, name: []const u8, out: Output) Allocator.Error!HostResultU64 {
    _ = out;
    return startWorker(self, block, name);
}

/// Post a dispatcher runnable onto the shared worker pool; `Dispatchers.Default`
/// (`io_kind == false`) and `Dispatchers.IO` (`true`) are views of the same threads.
pub fn coroutineDispatchPooled(self: *VmIntrinsicHost, block: *const Value, io_kind: bool, out: Output) Allocator.Error!?RuntimeError {
    _ = out;
    // Count the dispatch as unsettled on the virtual clock from the post, so a driver
    // cannot advance virtual time before the task's barrier floor. Released by that floor.
    coroutines.poolTaskDispatched();
    // The runnable crosses to a pool thread that outlives this call; retain so
    // its captures survive until the task runs or is dropped.
    block.retain();
    scheduler.post(.{
        .seed = spawnSeed(self),
        .block = block.*,
        .time_mode = root.coroutineTimeMode(),
        .reclaim = runtime.reclaimEnabled(),
        .kind = if (io_kind) .io else .default,
    }) catch |e| {
        coroutines.poolTaskSettleDropped();
        block.release(self.allocator);
        return e;
    };
    return null;
}

/// Let outstanding pool work reach its own first suspension.
///
/// Called where a coroutine DISPATCHES ONTO THE PUMP — which is what
/// `yield()` does, through `Yield.kt`'s `dispatchYield` into
/// `KlioDispatcher.dispatch` — so it is the point where kotlinx's dispatch
/// round-trip gives a `Dispatchers.Default` worker time to start. Placing it
/// at the pooled dispatch instead was measured WRONG: a `main` that launches
/// a daemon and returns without suspending must drop that task, and waiting
/// there ran it.
///
/// Bounded, skipped on a pool worker, and a no-op when the pool has nothing
/// outstanding. `KLIO_DISPATCH_HANDOFF=0` withdraws it.
pub fn awaitPoolQuiescent() void {
    if (std.mem.eql(u8, runtime.envOnce("KLIO_DISPATCH_HANDOFF") orelse "1", "0")) return;
    if (scheduler.onPoolWorker()) return;
    if (scheduler.outstandingOtherCount() == 0) return;
    const deadline = ir.eval.nowMonotonicMs() + 5;
    while (scheduler.outstandingOtherCount() != 0) {
        if (ir.eval.nowMonotonicMs() >= deadline) return;
        runtime.clockSleepMicros(50);
    }
}

/// Join the thread `spawnOsThread` returned, propagating the body's error. Idempotent.
pub fn joinOsThread(self: *VmIntrinsicHost, id: u64) Allocator.Error!?RuntimeError {
    const handle = blk: {
        const g = self.threads.borrowMut();
        defer g.deinit();
        if (g.get().getPtr(id)) |entry| {
            const h = entry.handle;
            entry.handle = null;
            break :blk h;
        }
        break :blk null;
    };
    if (handle) |h| {
        // `join()` establishes happens-before with the worker's writes. The
        // joining thread is blocked, so mark it parked for a worker's concurrent
        // collection rendezvous; otherwise the collector waits on it forever.
        runtime.gc.enterBlockingSafe();
        h.join();
        runtime.gc.exitBlockingSafe();
    }
    const g = self.threads.borrow();
    defer g.deinit();
    if (g.get().get(id)) |entry| {
        if (entry.result) |res| {
            return switch (res) {
                .ok => null,
                .err => |e| e,
            };
        }
    }
    return null;
}

pub fn osThreadAlive(self: *VmIntrinsicHost, id: u64) bool {
    const g = self.threads.borrow();
    defer g.deinit();
    if (g.get().get(id)) |entry| {
        if (entry.handle == null) return false;
        return !entry.finished.load(.acquire);
    }
    return false;
}

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}
