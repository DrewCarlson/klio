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
const host_call_member = @import("host_call_member.zig");
const host_instances = @import("host_instances.zig");
const host_fields = @import("host_fields.zig");
const host_call_value = @import("host_call_value.zig");
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
pub const RawResult = EvalResult;

/// Transient `VmHost` borrowing this host's shared state, bound to `out` for one
/// evaluation. Handles are copied by value: the view owns nothing, needs no deinit.
pub fn vmHost(self: *VmIntrinsicHost, out: Output) VmHost {
    const state = vmhost.SharedHandles.fromIntrinsic(self);
    return VmHost.borrowed(state, state.globals, out);
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

fn classDefIsInner(def: ObjRef(ClassDef)) bool {
    const dg = def.borrow();
    defer dg.deinit();
    return dg.get().is_inner;
}

pub fn construct(self: *VmIntrinsicHost, class_id: ClassId, args: []const Value, out: Output) Allocator.Error!RawResult {
    var host = vmHost(self, out);
    return host.newInstance(self.allocator, class_id, args, null);
}

/// Named construction: parameters not in `names` take their declared defaults.
/// Null when `class` is not a resolvable class; the caller then goes positional.
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
    const id = callable.IrClosure.asPtr().id;
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
    var host = VmHost.borrowed(state, state.globals, out);
    vmhost.emitPath(self.allocator, "coroutine_closure", func.fqn, info.body_func, this_value, args);
    return ir.eval.evalWithCapturesChained(VmHost, self.allocator, module, info.module, func, args_owned, caps_owned, info.chain, @intCast(id), &host);
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
    coroutines.coroutineResumeExternal(self, slot, value, out) catch {};
}

pub fn coroutineResumeContinuation(self: *VmIntrinsicHost, slot: i64, value: Value, out: Output) void {
    coroutines.coroutineResumeContinuation(self, slot, value, out) catch {};
}

pub fn coroutineDrainToIdle(self: *VmIntrinsicHost, out: Output) Allocator.Error!?RuntimeError {
    return coroutines.coroutineDrainToIdle(self, out);
}

/// Whether `v` is a companion-object singleton, recognized by a `$Companion$`
/// lift name or a `.Companion` FQN tail.
fn isCompanionInstanceValue(v: Value) bool {
    if (v != .Instance) return false;
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return std.mem.find(u8, cg.get().name, "$Companion$") != null or
        std.mem.endsWith(u8, cg.get().fqn, ".Companion");
}

pub fn invokeCallable(self: *VmIntrinsicHost, callable: *const Value, args: []const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    // A bound method/property reference (`recv::method`, `Cls::method`) is a
    // synthetic Instance carrying `__bound_receiver__` and `__bound_name__`.
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
            // itself, a `.Class` or its companion; its first argument is the receiver.
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
            var host = vmHost(self, out);
            // A property reference reads the property: a member property, or an
            // extension property when no extension function owns the name.
            const as_property = member_args.len == 0 and
                (root.memberIsProperty(self.allocator, &self.classes, &target, nm) or
                    (!host_call_value.extensionFnNamed(&host, nm) and host_fields.hostHasExtProp(&host, self.allocator, &target, nm)));
            // Dispatch under the reference's creation site, where visibility is decided.
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
        const id = callable.IrClosure.asPtr().id;
        const info = self.closures.get(@intCast(id)) orelse {
            const msg = try std.fmt.allocPrint(self.allocator, "unknown IrClosure id {d}", .{id});
            return .{ .err = .{ .Type = msg } };
        };
        // A receiver lambda invoked as a plain value with one extra leading arg is
        // the ABI's flattened form: bind arg 0 as the receiver, never as a positional.
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

        const state = vmhost.SharedHandles.fromIntrinsic(self);
        var host = VmHost.borrowed(state, state.globals, out);
        vmhost.emitPath(self.allocator, "hof_invoke", func.fqn, info.body_func, null, args);
        const result = try ir.eval.evalWithCapturesChained(VmHost, self.allocator, module, info.module, func, call_args, caps_owned, info.chain, @intCast(id), &host);
        return flattenEval(result);
    }

    // A class value used as a function is a constructor reference (`::Box`,
    // `Outer::Nested`).
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
        // The bound ClassDef carries the FQN; resolve by it so `::Ctor` of a
        // same-simple-name class in another package constructs the right class.
        const module_g = self.module.borrow();
        const class_id_opt = module_g.get().classIdByFqn(fqn) orelse module_g.get().classId(name);
        module_g.deinit();
        if (class_id_opt) |class_id| {
            // An inner class's constructor reference takes the enclosing instance first.
            const inner_outer: ?*const Value = blk: {
                if (args.len == 0 or args[0] != .Instance) break :blk null;
                if (!classDefIsInner(def)) break :blk null;
                const mg = self.module.borrow();
                defer mg.deinit();
                if (class_id.int() >= mg.get().classes.items.len) break :blk null;
                if (args.len != mg.get().classes.items[class_id.int()].primary_params.len + 1) break :blk null;
                break :blk &args[0];
            };
            if (inner_outer) |oh| {
                var host = vmHost(self, out);
                const r = try host.newInstance(self.allocator, class_id, args[1..], oh);
                return flattenEval(r);
            }
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

    // A user class declaring `operator fun invoke` dispatches through it.
    if (callable.* == .Instance) {
        var host = vmHost(self, out);
        const r = try host.callMember(self.allocator, callable, "invoke", args);
        return flattenEval(r);
    }

    // `Comparator` is a `fun interface`: invoking it as a value calls `compare`.
    if (callable.* == .Comparator and args.len == 2) {
        var host = vmHost(self, out);
        const r = try host.callMember(self.allocator, callable, "compare", args);
        return flattenEval(r);
    }

    const msg = try std.fmt.allocPrint(self.allocator, "Vm::invoke_callable on `{s}`", .{callable.typeFqn()});
    return .{ .err = .{ .Unimplemented = msg } };
}

pub fn invokeCallableWithThis(self: *VmIntrinsicHost, callable: *const Value, args: []const Value, this_value: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    // Receiver-typed lambda dispatch: bind the receiver as the lambda's implicit
    // `this` and as the injected `it` by overriding the captures cell for the call.
    if (callable.* == .IrClosure) {
        const id = callable.IrClosure.asPtr().id;
        const info = self.closures.get(@intCast(id));
        if (info) |inf| {
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

            // The receiver fills the leading declared positional only when the
            // caller left one unfilled, never displacing a real parameter. The
            // pass-threaded `$composer`/`$changed` pair are not user positionals.
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

            // The receiver just displaced an enclosing `this` (`with(sb) { … }`
            // inside a member); keep the prior one as an outer implicit receiver so
            // bare members and `this@Outer` still resolve, matching Kotlin's nested
            // receiver rule. Any distinct prior `this` counts, not only an Instance.
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
            // The member-extension visibility filter reads the runtime enclosing-this
            // stack, not closure captures, so push the receiver for the call. A null
            // subject is a real candidate for nullable-receiver extensions.
            const pushed_receiver = this_value.* == .Instance or this_value.* == .Null;
            if (pushed_receiver) {
                host_call_member.pushOuterSubject(self.allocator, this_value);
            }

            const result = try invokeCallable(self, callable, all.items, out);

            if (pushed_receiver) host_call_member.popOuterThis();
            if (pushed_outer) host_call_member.popOuterThis();

            // Restore the prior `this` so a reused closure keeps its captured value.
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

    // An inner class's constructor reference called with receiver syntax
    // (`val a: Foo.() -> Foo.Bar = Foo::Bar`): the receiver is the outer instance.
    if (callable.* == .Class and this_value.* == .Instance and classDefIsInner(callable.Class)) {
        const class_id_opt = blk: {
            const dg = callable.Class.borrow();
            defer dg.deinit();
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().classIdByFqn(dg.get().fqn) orelse mg.get().classId(dg.get().name);
        };
        if (class_id_opt) |class_id| {
            var host = vmHost(self, out);
            const r = try host.newInstance(self.allocator, class_id, args, this_value);
            return flattenEval(r);
        }
    }

    // With receiver syntax (`recv.refValue()`) the receiver is the reference's leading arg.
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
    // Route through call_member so a user override method wins the dispatch.
    var host = vmHost(self, out);
    const r = try host.callMember(self.allocator, receiver, name, args);
    return switch (r) {
        .ok => |v| RuntimeEvalResult{ .ok = v },
        .err => |e| switch (e) {
            .Throw => |v| RuntimeEvalResult{ .err = .{ .Thrown = v } },
            // A body that ran and failed must propagate: falling through to
            // another dispatch hides the failure and can re-run side effects.
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
    // Route through the field path so custom getters, stored fields and ctor-property
    // params resolve, member-strict: a capability sniff must not walk the receiver chain.
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
    // A pack native's first `object`/companion reference drives the lazy first-access gate.
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

/// Resolve a top-level Kotlin function value by name. Separate from
/// `lookupGlobal` so the heavier module-function search runs only when needed.
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
        if (std.mem.findScalarLast(u8, class_fqn, '.')) |i| break :blk class_fqn[i + 1 ..];
        break :blk class_fqn;
    };
    // A concrete data class has a registered ClassDef, so reuse it and the synth instance
    // behaves like a constructed one; klio-internal synth types keep the stub.
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

const WorkerArgs = struct {
    seed: SendableVmSeed,
    block: Value,
    time_mode: root.TimeMode,
    /// The child `Vm` shares the spawning run's arena, so it takes the same
    /// `ObjRef.deinit` path.
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
            else => publishThreadResult(args.threads, args.id, .{ .err = e }),
        },
    }
}

/// Spawn a worker thread for `block`. Every cell the child reaches orders concurrent
/// borrows through its own lock, and `Thread.spawn`/`join` bracket the happens-before.
fn startWorker(self: *VmIntrinsicHost, block: *const Value) Allocator.Error!HostResultU64 {
    const id = blk: {
        const g = self.instance_id_counter.borrowMut();
        defer g.deinit();
        break :blk g.get().fetchAdd(1, .monotonic);
    };

    // Register the entry before the worker starts so its result finds a slot.
    {
        const g = self.threads.borrowMut();
        defer g.deinit();
        try g.get().put(id, .{ .handle = null, .result = null });
    }

    // The block and the graph its captures reach cross to a worker that may outlive
    // this frame's hold; retain, and `workerEntry` releases when the task finishes.
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

/// Spawn `block` on a real OS thread, returning an id joined through the thread table.
pub fn spawnOsThread(self: *VmIntrinsicHost, block: *const Value, out: Output) Allocator.Error!HostResultU64 {
    _ = out;
    return startWorker(self, block);
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
