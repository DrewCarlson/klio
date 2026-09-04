//! The `runtime.IntrinsicHost` implementation for `VmIntrinsicHost` —
//! the side-channel the stdlib reaches back through to invoke lambdas,
//! resolve globals, synthesize instances, and drive the coroutine /
//! thread machinery.
//!
//! Free functions over `*VmIntrinsicHost`, wired into the
//! `runtime.IntrinsicHost` vtable by `vmhost.zig`. Each transient
//! `VmHost` built here shares the same program state so a delegated
//! evaluation (`call_member`, `new_instance`, a closure body) runs
//! against the live globals / classes / closure table.

const std = @import("std");
const stdlib = @import("stdlib");

const ir = @import("ir");
const runtime = @import("runtime");

const root = @import("../interp_ir.zig");
const vmhost = @import("vmhost.zig");
const scheduler = @import("scheduler.zig");
const host_call_member = @import("host_call_member.zig");
const host_instances = @import("host_instances.zig");
const trace = @import("trace.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const Env = runtime.Env;
const ClassDef = runtime.ClassDef;
const Output = runtime.Output;
const RuntimeError = runtime.RuntimeError;
const HostResultU64 = runtime.HostResultU64;
const InstanceData = runtime.InstanceData;
const RuntimeEvalResult = runtime.EvalResult;

const Module = ir.Module;
const ClassId = ir.ClassId;
const EvalError = ir.eval.EvalError;
const EvalResult = ir.eval.EvalResult;
const SuspendState = ir.eval.SuspendState;

const SendableVmSeed = root.SendableVmSeed;
const ThreadEntry = root.ThreadEntry;
const ThreadResult = root.ThreadResult;

/// `Result<Value, EvalError>` for the raw coroutine-facing helpers.
const RawResult = EvalResult;

// -------------------------------------------------------------------------
// Transient hosts over the shared state.
// -------------------------------------------------------------------------

/// Build a transient `VmHost` that borrows this host's shared state, bound
/// to `out` for the duration of one delegated evaluation. The handles are
/// copied by value with no refcount bump, so the view owns nothing and is
/// dropped just by going out of scope — no matching deinit. `self` keeps
/// every cell alive for the call's whole lifetime.
pub fn vmHost(self: *VmIntrinsicHost, out: Output) VmHost {
    const state = vmhost.SharedHandles.fromIntrinsic(self);
    return VmHost.borrowed(state, state.globals, out);
}

/// A sibling `VmIntrinsicHost` over the same shared state, used when an
/// intrinsic recursively dispatches another intrinsic. Borrows by value;
/// owns nothing and needs no matching deinit.
pub fn childHost(self: *VmIntrinsicHost) VmIntrinsicHost {
    return VmIntrinsicHost.borrowed(vmhost.SharedHandles.fromIntrinsic(self));
}

/// Build a `SendableVmSeed` snapshot of the shared program state for a
/// freshly spawned OS thread / dispatch worker.
/// Worker spawn precondition guard.
///
/// A worker materializes its own child `Vm` on a fresh OS thread
/// (`workerEntry` → `seed.materialize`) and allocates Values, Envs,
/// instance fields, and `ObjRef` control blocks — and runs `vm.deinit()`
/// — all against the *same* allocator the parent passed in (`spawnSeed`
/// copies `self.allocator` verbatim into the seed). That sharing is sound
/// under Zig 0.16 only while two invariants hold, and the runtime never
/// enforces them:
///
///   1. The shared backing allocator is thread-safe. Zig 0.16's
///      `ArenaAllocator` is documented thread-safe for the `Allocator`
///      interface (its lock-free `alloc`/free advance `end_index` with
///      atomic RMW) *when its child allocator is thread-safe*; the CLI
///      backs the `Vm` with an arena over `page_allocator`, which is
///      thread-safe. `std.heap.smp_allocator` is the other thread-safe
///      option. A bare `FixedBufferAllocator` or a single-threaded debug
///      allocator would silently reintroduce a data race. (Zig 0.16 has
///      no `std.heap.ThreadSafeAllocator`, so this is a precondition to
///      assert, not a wrapper to apply.)
///   2. No `arena.reset()` / `arena.deinit()` runs on the backing
///      allocator while any worker is live. The only `ArenaAllocator`
///      teardown is the process-exit `defer arena.deinit()`, and `Vm.run`
///      joins every outstanding worker (`joinAllThreads`) before
///      returning, so teardown never overlaps a live worker. Re-running a
///      `Vm` against a `reset()`-reused arena would break this.
///
/// Neither is fully introspectable from a `std.mem.Allocator` (the arena's
/// child thread-safety and the lifetime ordering are not in the vtable),
/// so this asserts the cheaply-checkable part — the allocator about to be
/// shared with the worker is a non-degenerate, real allocator (a
/// zeroed/torn allocator at the seam is a clear bug) — and emits a
/// machine-readable invariant line under `KLIO_TRACE_INVARIANTS` when it
/// is not. Invariant (2) is enforced structurally by `joinAllThreads` and
/// cannot be checked at the seam.
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
        .globals = self.globals.clone(),
        .instance_id_counter = self.instance_id_counter.clone(),
        .classes = self.classes.clone(),
        .prog = self.prog.clone(),
        .anon_methods = self.anon_methods.clone(),
        .class_default_outer = self.class_default_outer.clone(),
        .closures = self.closures.clone(),
        .out_sink = self.out_sink.clone(),
        .threads = self.threads.clone(),
        .object_states = self.object_states.clone(),
        .singletons_by_id = self.singletons_by_id.clone(),
        .allocator = self.allocator,
    };
}

// -------------------------------------------------------------------------
// EvalError -> RuntimeError mapping.
// -------------------------------------------------------------------------

/// Map an `EvalError` onto the runtime's `RuntimeError`: `Throw -> Thrown`,
/// `NonLocalReturn -> Return`, every other variant rendered as a `Type`
/// error.
fn runtimeErrorFromEval(e: EvalError) RuntimeError {
    return switch (e) {
        .Throw => |v| .{ .Thrown = v },
        .NonLocalReturn => |v| .{ .Return = v },
        .Suspended => blk: {
            // ALWAYS a defect: a suspension crossed a boundary that cannot
            // park it, so the activation is dropped and its coroutine's Job
            // never completes — an indefinite hang for every joiner. Loud by
            // design; the message names the phase for triage.
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

/// Flatten an `EvalResult` into a `runtime.EvalResult`, mapping the
/// error variant.
fn flattenEval(r: EvalResult) RuntimeEvalResult {
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = runtimeErrorFromEval(e) },
    };
}

// -------------------------------------------------------------------------
// Constructor / closure delegation.
// -------------------------------------------------------------------------

/// Construct an instance through the full constructor pipeline. The
/// intrinsic child host has no `new_instance` of its own, so build a
/// transient `VmHost` over the same shared state and delegate. Lets a
/// constructor reference (`::Box`, `Outer::Nested`) be invoked uniformly
/// from stdlib higher-order ops like `map`/`fold`.
pub fn construct(self: *VmIntrinsicHost, class_id: ClassId, args: []const Value, out: Output) Allocator.Error!RawResult {
    var host = vmHost(self, out);
    return host.newInstance(self.allocator, class_id, args, null);
}

/// NAMED construction of a class value: every parameter not in `names`
/// takes its declared default. Null when the value is not a resolvable
/// class — the caller falls back to the positional path.
pub fn constructNamed(self: *VmIntrinsicHost, class: *const Value, names: []const []const u8, args: []const Value, out: Output) Allocator.Error!?RuntimeEvalResult {
    if (class.* != .Class) return null;
    var name: []const u8 = undefined;
    var fqn: []const u8 = undefined;
    {
        const dg = class.Class.borrow();
        defer dg.deinit();
        name = dg.get().name;
        fqn = dg.get().fqn;
    }
    const class_id = blk: {
        const module_g = self.module.borrow();
        defer module_g.deinit();
        break :blk module_g.get().classIdByFqn(fqn) orelse module_g.get().classId(name);
    } orelse return null;
    const arg_names = try self.allocator.alloc(?[]const u8, names.len);
    defer self.allocator.free(arg_names);
    for (names, arg_names) |n, *slot| slot.* = n;
    var host = vmHost(self, out);
    const r = try host_instances.newInstanceNamed(&host, self.allocator, class_id, args, arg_names, null);
    return flattenEval(r);
}

/// Evaluate an `IrClosure` and return the *raw* `EvalError` so the
/// coroutine driver can observe `Suspended`. Mirrors the closure-setup
/// half of `invoke_callable` (capture env, param fill, write-back)
/// without flattening errors.
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
    const id = callable.IrClosure.id;
    const live_captures = callable.IrClosure.captures;

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

    // Fill the call args. With a receiver, prepend it (when the body
    // declares at least one param); otherwise pad to `n_params`.
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

    // Prefer the live captures carried on the closure Value; fall back
    // to the ClosureInfo cell when the Value carries none.
    var capture_values: std.ArrayList(Value) = .empty;
    defer capture_values.deinit(self.allocator);
    {
        const lc_g = live_captures.borrow();
        defer lc_g.deinit();
        const lc = lc_g.get().*;
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

    // Run the body over the real top-level env. Captured `var`s a nested
    // closure writes are shared `Value.Cell`s carried positionally in the
    // captures, so a write is a `CellSet` on the shared cell and is visible
    // at the declaration site with no name-seeded scratch env or read-back.
    var args_owned: std.ArrayList(Value) = .empty;
    try args_owned.appendSlice(self.allocator, call_args.items);
    var caps_owned: std.ArrayList(Value) = .empty;
    try caps_owned.appendSlice(self.allocator, capture_values.items);

    const state = vmhost.SharedHandles.fromIntrinsic(self);
    var host = VmHost.borrowed(state, state.globals, out);
    vmhost.emitPath(self.allocator, "coroutine_closure", func.fqn, info.body_func, this_value, args);
    return ir.eval.evalWithCapturesChained(VmHost, self.allocator, module, info.module, func, args_owned, caps_owned, info.chain, @intCast(id), &host);
}

/// Evaluate a top-level function (no args, no captures) as the root of a
/// coroutine driver, with a raw `EvalError` out — the `evalClosureRaw`
/// analogue used to drive a `suspend fun main`.
pub fn evalFuncRaw(self: *VmIntrinsicHost, func_id: ir.FuncId, out: Output) Allocator.Error!RawResult {
    const module_g = self.module.borrow();
    defer module_g.deinit();
    const module = module_g.get();
    const func = module.funcById(func_id) orelse {
        return .{ .err = .{ .Type = "invalid main FuncId" } };
    };
    const state = vmhost.SharedHandles.fromIntrinsic(self);
    var host = VmHost.borrowed(state, state.globals, out);
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

// -------------------------------------------------------------------------
// `runtime.IntrinsicHost` vtable entry points.
// -------------------------------------------------------------------------

// The cooperative coroutine driver (the engine behind `runBlocking` /
// `coroutineRunRoot` and the park / resume / launch / drain seams) lives
// with its `CooperativeInterceptor` machinery in `coroutines.zig`. The
// `runtime.IntrinsicHost` entry points below delegate straight to it.
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
    coroutines.coroutineResumeExternal(self, slot, value, out) catch {};
}

pub fn coroutineResumeContinuation(self: *VmIntrinsicHost, slot: i64, value: Value, out: Output) void {
    coroutines.coroutineResumeContinuation(self, slot, value, out) catch {};
}

pub fn coroutineDrainToIdle(self: *VmIntrinsicHost, out: Output) Allocator.Error!?RuntimeError {
    return coroutines.coroutineDrainToIdle(self, out);
}

/// Whether `v` is a companion-object singleton instance, recognized by the
/// `$Companion$` marker in its lift name or a `.Companion` FQN tail.
fn isCompanionInstanceValue(v: Value) bool {
    if (v != .Instance) return false;
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return std.mem.indexOf(u8, cg.get().name, "$Companion$") != null or
        std.mem.endsWith(u8, cg.get().fqn, ".Companion");
}

/// Single callable-dispatch flow over the value variants.
pub fn invokeCallable(self: *VmIntrinsicHost, callable: *const Value, args: []const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    // Bound method/property reference (`recv::method`, `Cls::method`):
    // the lowering creates a synthetic Instance carrying
    // `__bound_receiver__` + `__bound_name__`. When invoked through a
    // HOF, dispatch on the captured receiver. An unbound class-method
    // ref passes its first arg as the receiver.
    if (callable.* == .Instance) {
        const inst = callable.Instance;
        var recv: ?Value = null;
        var name: ?[]const u8 = null;
        {
            const snap = inst.borrow();
            defer snap.deinit();
            recv = snap.get().get("__bound_receiver__");
            if (snap.get().get("__bound_name__")) |nv| {
                if (nv == .String) {
                    const sg = nv.String.borrow();
                    defer sg.deinit();
                    name = sg.get().bytes;
                }
            }
        }
        if (recv != null and name != null) {
            const r = recv.?;
            const nm = name.?;
            // An unbound class-method reference's captured receiver is the type
            // itself — a `.Class`, or its companion-object instance when one is
            // in scope. Both route the first argument as the dispatch receiver
            // when the named member is an instance method, not a companion one.
            var host0 = vmHost(self, out);
            const type_like = (r == .Class) or
                (isCompanionInstanceValue(r) and !host0.hostHasMember(&r, nm));
            const unbound = type_like and args.len != 0;
            var target: Value = undefined;
            var member_args: []const Value = undefined;
            if (unbound) {
                target = args[0];
                member_args = args[1..];
            } else {
                target = r;
                member_args = args;
            }
            const as_property = member_args.len == 0 and
                root.memberIsProperty(self.allocator, &self.classes, &target, nm);
            var host = vmHost(self, out);
            // Dispatch under the reference's creation-site file (private
            // visibility is decided where the reference was written).
            var ref_pushed = false;
            var ref_prev: ?ir.eval.RefSiteOverride = null;
            if (host_call_member.boundRefFile(callable)) |bf| {
                ref_prev = ir.eval.pushRefSiteFile(bf);
                ref_pushed = true;
            }
            defer if (ref_pushed) ir.eval.popRefSiteFile(ref_prev);
            const result = if (as_property)
                try host.getField(self.allocator, &target, nm)
            else
                try host.callMember(self.allocator, &target, nm, member_args);
            return flattenEval(result);
        }
    }

    if (callable.* == .IrClosure) {
        const id = callable.IrClosure.id;
        const info = self.closures.get(@intCast(id)) orelse {
            const msg = try std.fmt.allocPrint(self.allocator, "unknown IrClosure id {d}", .{id});
            return .{ .err = .{ .Type = msg } };
        };
        // A receiver lambda invoked as a plain value with one extra leading
        // arg is the compiler ABI's flattened form: the receiver rides as the
        // first positional (`ComposableLambdaImpl.invoke(p1, c, changed)`
        // feeding an `R.()` block). Bind it as the receiver; padding it into
        // the positional params would misfeed a pass-appended pair.
        if (info.receiver_shape_known and info.has_receiver and args.len == info.n_params + 1) {
            return invokeCallableWithThis(self, callable, args[1..], &args[0], out);
        }
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

        var caps_owned: std.ArrayList(Value) = .empty;
        {
            const cap_g = info.captures.borrow();
            defer cap_g.deinit();
            try caps_owned.appendSlice(self.allocator, cap_g.get().items);
        }

        // Pad args to the body's declared arity with Null.
        var call_args: std.ArrayList(Value) = .empty;
        {
            var i: usize = 0;
            while (i < info.n_params) : (i += 1) {
                try call_args.append(self.allocator, if (i < args.len) args[i] else .Null);
            }
            var j: usize = info.n_params;
            while (j < args.len) : (j += 1) {
                try call_args.append(self.allocator, args[j]);
            }
        }

        // Run the body over the real top-level env. A captured `var` a nested
        // closure writes is a shared `Value.Cell` carried positionally, so the
        // write is a `CellSet` on the shared cell — visible at the declaration
        // site with no name-seeded scratch env or capture read-back.
        const state = vmhost.SharedHandles.fromIntrinsic(self);
        var host = VmHost.borrowed(state, state.globals, out);
        vmhost.emitPath(self.allocator, "hof_invoke", func.fqn, info.body_func, null, args);
        const result = try ir.eval.evalWithCapturesChained(VmHost, self.allocator, module, info.module, func, call_args, caps_owned, info.chain, @intCast(id), &host);
        return flattenEval(result);
    }

    // A class value used as a function is a constructor reference
    // (`::Box`, `Outer::Nested`) — invoking it builds an instance.
    if (callable.* == .Class) {
        const def = callable.Class;
        var name: []const u8 = undefined;
        var fqn: []const u8 = undefined;
        {
            const dg = def.borrow();
            defer dg.deinit();
            name = dg.get().name;
            fqn = dg.get().fqn;
        }
        // The bound ClassDef carries the FQN; resolve the module class
        // by it so `::Ctor` of a same-simple-name class from another
        // package constructs the referenced class.
        const module_g = self.module.borrow();
        const class_id_opt = module_g.get().classIdByFqn(fqn) orelse module_g.get().classId(name);
        module_g.deinit();
        if (class_id_opt) |class_id| {
            const r = try construct(self, class_id, args, out);
            return flattenEval(r);
        }
    }

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

    // Callable instance (a user class declaring `operator fun invoke`):
    // dispatch through its `invoke` member.
    if (callable.* == .Instance) {
        var host = vmHost(self, out);
        const r = try host.callMember(self.allocator, callable, "invoke", args);
        return flattenEval(r);
    }

    // `Comparator` is a `fun interface`: invoking it as a value
    // (`comparator(a, b)` inside `compareBy(comparator, selector)`)
    // calls `compare` — same bridge the main-evaluator `callValue` has.
    if (callable.* == .Comparator and args.len == 2) {
        var host = vmHost(self, out);
        const r = try host.callMember(self.allocator, callable, "compare", args);
        return flattenEval(r);
    }

    const msg = try std.fmt.allocPrint(self.allocator, "Vm::invoke_callable on `{s}`", .{callable.typeFqn()});
    return .{ .err = .{ .Unimplemented = msg } };
}

pub fn invokeCallableWithThis(self: *VmIntrinsicHost, callable: *const Value, args: []const Value, this_value: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    // Receiver-typed lambda dispatch: bind the receiver as the lambda's
    // implicit `this` AND as the parser-injected `it` when the lambda has
    // a single param. The capture is overridden via the closure's
    // captures cell before invoke, then restored after.
    if (callable.* == .IrClosure) {
        const id = callable.IrClosure.id;
        const info = self.closures.get(@intCast(id));
        if (info) |inf| {
            // Locate the captured `this` slot and snapshot its prior value.
            var this_idx: ?usize = null;
            var prior_this: ?Value = null;
            for (inf.capture_names, 0..) |n, idx| {
                if (std.mem.eql(u8, n, "this")) {
                    this_idx = idx;
                    break;
                }
            }
            if (this_idx) |idx| {
                const cap_g = inf.captures.borrowMut();
                defer cap_g.deinit();
                if (idx < cap_g.get().items.len) {
                    prior_this = cap_g.get().items[idx];
                    cap_g.get().items[idx] = this_value.*;
                } else {
                    try cap_g.get().appendNTimes(self.allocator, .Null, idx + 1 - cap_g.get().items.len);
                    cap_g.get().items[idx] = this_value.*;
                }
            }

            // The receiver fills the leading declared positional when the
            // caller left one unfilled; otherwise the lambda is an
            // ordinary value function and the receiver must not displace
            // its parameter. Pass-threaded ($composer, $changed) params are
            // NOT user positionals: filling one with the receiver made the
            // `apply { setContent { ... } }` subject the ambient composer
            // for the whole sub-composition.
            var fill_params = inf.n_params;
            {
                const mg2 = self.module.borrow();
                defer mg2.deinit();
                const m2 = inf.module orelse mg2.get();
                if (m2.funcById(inf.body_func)) |bf| {
                    const p2 = bf.params;
                    if (p2.len >= 2 and std.mem.eql(u8, p2[p2.len - 1].name, "$changed") and
                        std.mem.eql(u8, p2[p2.len - 2].name, "$composer"))
                    {
                        fill_params -|= 2;
                    }
                }
            }
            var all: std.ArrayList(Value) = .empty;
            defer all.deinit(self.allocator);
            if (fill_params >= 1 and args.len < fill_params) {
                try all.append(self.allocator, this_value.*);
                for (args) |a| try all.append(self.allocator, a);
            } else {
                try all.appendSlice(self.allocator, args);
            }

            // The receiver just displaced an enclosing-class `this` (e.g.
            // `with(sb) { … }` written inside a member). Keep that instance
            // reachable as an outer implicit receiver so bare members /
            // `this@Outer` inside the lambda still resolve, matching Kotlin's
            // nested-receiver rule. Any distinct prior `this` (not only an
            // Instance) is kept: an extension-receiver lambda such as
            // `IntRange.asFlow() = flow { … }` captures the range as its
            // `this`, which the new collector receiver displaces.
            const pushed_outer = po: {
                const pt = prior_this orelse break :po false;
                if (pt == .Null or pt == .Unit) break :po false;
                if (pt == .Instance and this_value.* == .Instance) {
                    break :po !ObjRef(InstanceData).ptrEq(pt.Instance, this_value.Instance);
                }
                break :po true;
            };
            if (pushed_outer) {
                if (prior_this) |p| host_call_member.pushOuterThis(self.allocator, &p);
            }
            // The new receiver is bound to the lambda's captured `this` slot
            // above. The member-extension visibility filter consults the
            // runtime enclosing-this stack, not closure captures, so push the
            // receiver for the duration of the lambda call: a `with(a) { … }`
            // body that calls a member-extension declared on `a`'s class then
            // sees that owner as visible.
            // A null subject is a real receiver candidate for
            // nullable-receiver extensions.
            const pushed_receiver = this_value.* == .Instance or this_value.* == .Null;
            if (pushed_receiver) {
                host_call_member.pushOuterSubject(self.allocator, this_value);
            }

            const result = try invokeCallable(self, callable, all.items, out);

            if (pushed_receiver) host_call_member.popOuterThis();
            if (pushed_outer) host_call_member.popOuterThis();

            // Restore the prior `this` so a closure reused with different
            // receivers preserves its captured value between uses.
            if (this_idx) |idx| {
                if (prior_this) |prior| {
                    const cap_g = inf.captures.borrowMut();
                    defer cap_g.deinit();
                    if (idx < cap_g.get().items.len) {
                        cap_g.get().items[idx] = prior;
                    }
                }
            }
            return result;
        }
        return invokeCallable(self, callable, args, out);
    }

    // A callable reference (`recv::method`, `Long::toByte`) invoked with
    // receiver syntax (`recv.refValue()`): the receiver is the reference's
    // leading argument. `invokeCallable` then routes an unbound class-method
    // reference's first argument as its dispatch receiver.
    if (callable.* == .Instance) {
        var with_recv: std.ArrayList(Value) = .empty;
        defer with_recv.deinit(self.allocator);
        try with_recv.append(self.allocator, this_value.*);
        try with_recv.appendSlice(self.allocator, args);
        return invokeCallable(self, callable, with_recv.items, out);
    }

    const msg = try std.fmt.allocPrint(self.allocator, "Vm::invoke_callable_with_this on `{s}`", .{callable.typeFqn()});
    if (runtime.envOnce("KLIO_ERR_TRACE") != null) {
        std.debug.print("[icwt] callable={s} this={s} nargs={d}\n", .{ callable.typeFqn(), this_value.typeFqn(), args.len });
        ir.eval.dumpCurrentFrameParamsForDiag();
        ir.eval.dumpFrameChainForDiagAlways();
    }
    return .{ .err = .{ .Unimplemented = msg } };
}

pub fn invokeMethod(self: *VmIntrinsicHost, receiver: *const Value, name: []const u8, args: []const Value, out: Output) Allocator.Error!?RuntimeEvalResult {
    // Build a VmHost that shares this IntrinsicHost's tables and route
    // through call_member so the dispatch picks up user override methods.
    var host = vmHost(self, out);
    const r = try host.callMember(self.allocator, receiver, name, args);
    return switch (r) {
        .ok => |v| RuntimeEvalResult{ .ok = v },
        .err => |e| switch (e) {
            .Throw => |v| RuntimeEvalResult{ .err = .{ .Thrown = v } },
            // A body that RAN and failed must propagate — falling through
            // to another dispatch (the SAM `invoke` arm) both hides the
            // real failure and can re-run side effects.
            .CalleeFailed => |m| RuntimeEvalResult{ .err = .{ .CalleeFailed = m } },
            else => blk: {
                if (runtime.envOnce("KLIO_SELDBG") != null) {
                    std.debug.print("[seldbg] invokeMethod {s}: err={s}", .{ name, @tagName(std.meta.activeTag(e)) });
                    switch (e) {
                        .Unimplemented, .Type, .CalleeFailed => |m| std.debug.print(" {s}", .{m}),
                        else => {},
                    }
                    std.debug.print("\n", .{});
                }
                break :blk null;
            },
        },
    };
}

pub fn getProperty(self: *VmIntrinsicHost, receiver: *const Value, name: []const u8, out: Output) Allocator.Error!?RuntimeEvalResult {
    // Route through the field path so custom getters / stored fields /
    // ctor-property params resolve (call_member only dispatches functions).
    // MEMBER-strict: a native's capability sniff (`entries` to tell a user
    // Map from an Iterable in `putAll`) must never be answered by an
    // ENCLOSING receiver's member through the chain fallbacks — with a
    // spliced `apply` subject on the chain, the destination map's own
    // `entries` made every Iterable look like a Map.
    var host = vmHost(self, out);
    const r = try vmhost.host_fields.getMemberField(&host, self.allocator, receiver, name);
    return switch (r) {
        .ok => |v| RuntimeEvalResult{ .ok = v },
        .err => |e| switch (e) {
            .Throw => |v| RuntimeEvalResult{ .err = .{ .Thrown = v } },
            else => null,
        },
    };
}

pub fn lookupGlobal(self: *VmIntrinsicHost, name: []const u8) ?Value {
    {
        const g = self.globals.borrow();
        defer g.deinit();
        if (g.get().lookup(name)) |v| return v;
    }
    // A pack native's first reference to an `object` / companion drives
    // the same lazy first-access gate the evaluator uses.
    {
        const state = vmhost.SharedHandles.fromIntrinsic(self);
        var host = VmHost.borrowed(state, state.globals, self.out_sink.output());
        if (vmhost.host_globals.objectSingletonQuiet(&host, name)) |v| return v;
    }
    const cg = self.classes.borrow();
    defer cg.deinit();
    if (cg.get().get(name)) |def| {
        return .{ .Class = def.clone() };
    }
    return null;
}

/// Resolve a top-level Kotlin function value by name for a native intrinsic
/// that needs to invoke a pack helper. Distinct from `lookupGlobal` (which
/// only covers globals/objects/classes) so the heavier module-function
/// resolution runs only when explicitly needed.
pub fn lookupGlobalFunc(self: *VmIntrinsicHost, name: []const u8) ?Value {
    const state = vmhost.SharedHandles.fromIntrinsic(self);
    var host = VmHost.borrowed(state, state.globals, self.out_sink.output());
    return vmhost.host_globals.lookupGlobal(&host, name);
}

pub fn allocInstanceId(self: *VmIntrinsicHost) u64 {
    const g = self.instance_id_counter.borrowMut();
    defer g.deinit();
    return g.get().fetchAdd(1, .monotonic) + 1;
}

pub fn newSynthInstance(self: *VmIntrinsicHost, class_fqn: []const u8, identity: u64, fields: []const InstanceData.Field) Allocator.Error!Value {
    const simple = blk: {
        if (std.mem.lastIndexOfScalar(u8, class_fqn, '.')) |i| break :blk class_fqn[i + 1 ..];
        break :blk class_fqn;
    };
    // A concrete data class (e.g. `IndexedValue`) has a real registered
    // ClassDef carrying its primary params and the synthesized data-class
    // members (componentN, equals, toString). Reuse it so the synth instance
    // behaves like one the constructor would build, instead of the bare
    // field-bag stub below (which klio's klio-internal synth types — Grouping,
    // SequenceScope — are not data classes, so they keep).
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(simple)) |real_def| {
            const rg = real_def.borrow();
            const is_data = rg.get().is_data;
            rg.deinit();
            if (is_data) {
                var field_list: std.ArrayList(InstanceData.Field) = .empty;
                try field_list.appendSlice(self.allocator, fields);
                const inst = try ObjRef(InstanceData).init(self.allocator, .{
                    .class = real_def.clone(),
                    .fields = field_list,
                    .outer = null,
                    .identity = identity,
                    .native_state = null,
                });
                return .{ .Instance = inst };
            }
        }
    }
    const supertypes: []const []const u8 = &.{};
    const class_def = try ObjRef(ClassDef).init(self.allocator, .{
        .name = simple,
        .fqn = class_fqn,
        .annotation_names = &.{},
        .primary_params = &.{},
        .methods = &.{},
        .body_properties = &.{},
        .init_blocks = &.{},
        .init_block_property_positions = &.{},
        .is_data = false,
        .is_value = false,
        .is_object = false,
        .is_enum = false,
        .is_sealed = false,
        .supertype_names = supertypes,
        .parent = null,
        .interfaces = &.{},
        .is_interface = false,
        .is_fun_interface = false,
        .parent_ctor_args = &.{},
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .is_anonymous = true,
        .secondary_ctors = &.{},
        .enum_entries = &.{},
        .companion = try ObjRef(?ObjRef(InstanceData)).init(self.allocator, null),
        .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(self.allocator, null),
        .nested_classes = &.{},
        .captured_env = try ObjRef(Env).init(self.allocator, Env.init(self.allocator)),
        .supertype_delegates = &.{},
        .delegate_forwarders = &.{},
        .object_singleton = try ObjRef(?ObjRef(InstanceData)).init(self.allocator, null),
    });

    var field_list: std.ArrayList(InstanceData.Field) = .empty;
    try field_list.appendSlice(self.allocator, fields);

    const inst = try ObjRef(InstanceData).init(self.allocator, .{
        .class = class_def,
        .fields = field_list,
        .outer = null,
        .identity = identity,
        .native_state = null,
    });
    return .{ .Instance = inst };
}

// -------------------------------------------------------------------------
// OS-thread / dispatch worker machinery.
// -------------------------------------------------------------------------

/// Trampoline state for a spawned worker. Holds the materialization seed,
/// the escaping block, the time mode to install on the new thread, and a
/// handle back to the thread-table entry it publishes its result into.
const WorkerArgs = struct {
    seed: SendableVmSeed,
    block: Value,
    time_mode: root.TimeMode,
    /// Teardown mode inherited from the spawning run: the worker's child
    /// `Vm` shares the same arena, so it must use the same `ObjRef.deinit`
    /// path (fast under an arena-backed run, full under leak-checking).
    reclaim: bool,
    threads: root.ThreadTable,
    id: u64,
};

fn publishThreadResult(threads: root.ThreadTable, id: u64, result: ThreadResult) void {
    const g = threads.borrowMut();
    defer g.deinit();
    if (g.get().getPtr(id)) |entry| {
        entry.result = result;
        entry.finished.store(true, .release);
    }
}

fn workerEntry(wargs: WorkerArgs) void {
    var args = wargs;
    defer runtime.slab.flushMagazines();
    // The seed allocator is about to back every allocation this worker
    // makes and its `vm.deinit()`; the invariants it relies on are
    // documented on `assertSpawnAllocatorInvariant`.
    assertSpawnAllocatorInvariant(args.seed.allocator, "workerEntry");
    root.setCoroutineTimeMode(args.time_mode);
    // Inherit the spawning run's teardown mode so the worker's child-Vm
    // `ObjRef.deinit`/`vm.deinit()` take the same path as the parent over
    // the shared arena.
    runtime.setReclaim(args.reclaim);
    // Join the mutator set for the worker's lifetime; the per-thread GC roots
    // link lazily on first use and unlink here (runs last, after teardown).
    coroutines.gcThreadEnter();
    defer coroutines.gcThreadExit();
    // Pin the thread block so its closure's captures survive a collection for
    // the whole run (it is reachable only through this stack local).
    const ka = runtime.keepaliveMark();
    defer runtime.keepaliveRestore(ka);
    runtime.keepalivePush(args.block);
    // Balance the spawn-time retain: drop the worker's hold on the block once
    // the task is done. Registered before `vm.deinit` so it runs after the
    // child Vm tears down (LIFO), keeping the block alive for the whole run.
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
    // Worker result publication: happens-before to the joining parent is
    // carried by each cell's reader/writer lock plus the parent's join().
    switch (r) {
        .ok => publishThreadResult(args.threads, args.id, .{ .ok = {} }),
        .err => |e| switch (e) {
            .Return => publishThreadResult(args.threads, args.id, .{ .ok = {} }),
            else => publishThreadResult(args.threads, args.id, .{ .err = e }),
        },
    }
}

/// Spawn a worker thread for `block`. Every cell the child reaches
/// mediates access through its own reader/writer lock, so concurrent
/// borrows from the worker and the parent are ordered by that lock; the
/// `Thread.spawn`/`join` below carry the bracketing happens-before. No
/// separate graph publication is needed.
fn startWorker(self: *VmIntrinsicHost, block: *const Value) Allocator.Error!HostResultU64 {
    const id = blk: {
        const g = self.instance_id_counter.borrowMut();
        defer g.deinit();
        break :blk g.get().fetchAdd(1, .monotonic);
    };

    // Register the thread entry before the worker starts so its result
    // publication finds a live slot.
    {
        const g = self.threads.borrowMut();
        defer g.deinit();
        try g.get().put(id, .{ .handle = null, .result = null });
    }

    // The block (and the value graph its captures reach) crosses to the
    // worker thread, which may outlive the spawning frame's hold on it.
    // Retain so it survives regardless; `workerEntry` releases it when the
    // task finishes. No-op under the arena fast path.
    block.retain();
    const wargs = WorkerArgs{
        .seed = spawnSeed(self),
        .block = block.*,
        .time_mode = root.coroutineTimeMode(),
        .reclaim = runtime.reclaimEnabled(),
        .threads = self.threads.clone(),
        .id = id,
    };

    const handle = std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, workerEntry, .{wargs}) catch {
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

/// Spawn `block` on a real OS thread, returning an opaque thread id.
/// `kotlin.concurrent.thread` — one OS thread per call, joined through
/// the thread table.
pub fn spawnOsThread(self: *VmIntrinsicHost, block: *const Value, out: Output) Allocator.Error!HostResultU64 {
    _ = out;
    return startWorker(self, block);
}

/// Post a dispatcher runnable onto the shared worker pool —
/// `Dispatchers.Default` (`io_kind == false`, the CPU-bounded view) and
/// `Dispatchers.IO` (`io_kind == true`, the elastic view) share the same
/// pool threads. The block, its captures, and any value it produces cross
/// threads; each shared cell they reach mediates concurrent access through
/// its own reader/writer lock (the spawned-thread boundary contract).
pub fn coroutineDispatchPooled(self: *VmIntrinsicHost, block: *const Value, io_kind: bool, out: Output) Allocator.Error!?RuntimeError {
    _ = out;
    // Count this dispatch as "unsettled" on the virtual clock from the moment
    // it is posted, so a top-level driver cannot advance virtual time across
    // the window between dispatch and the task establishing its barrier floor.
    // Released by the task's pump (first floor) or its drop at shutdown.
    coroutines.poolTaskDispatched();
    // The runnable crosses to a pool thread that outlives this call; retain so
    // its captures survive until the task runs (or is dropped). The pool's
    // task runner / drop path releases it. No-op under the arena fast path.
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

/// Join the OS thread previously returned by `spawnOsThread`,
/// propagating any error the body threw. Idempotent.
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
        // join() establishes happens-before with the worker's writes. The
        // joining thread is blocked, so it counts as parked for a worker's
        // concurrent collection rendezvous — otherwise the collector would
        // wait forever for a thread stuck in `join`.
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

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}
