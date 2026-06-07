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

const ir = @import("ir");
const runtime = @import("runtime");

const root = @import("../interp_ir.zig");
const vmhost = @import("vmhost.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const Env = runtime.Env;
const ClassDef = runtime.ClassDef;
const Output = runtime.Output;
const Scheduler = runtime.Scheduler;
const RuntimeError = runtime.RuntimeError;
const HostResultU64 = runtime.HostResultU64;
const InstanceData = runtime.InstanceData;
const RuntimeEvalResult = runtime.EvalResult;

const Module = ir.Module;
const ClassId = ir.ClassId;
const Host = ir.eval.Host;
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

/// Build a transient `VmHost` over the same shared state, bound to `out`
/// for the duration of one delegated evaluation. Every handle is cloned;
/// release them with `vmHostDeinit` once the delegated call returns.
pub fn vmHost(self: *VmIntrinsicHost, out: Output) VmHost {
    return .{
        .globals = self.globals.clone(),
        .module = self.module.clone(),
        .scheduler = self.scheduler,
        .out = out,
        .instance_id_counter = self.instance_id_counter.clone(),
        .classes = self.classes.clone(),
        .prog = self.prog.clone(),
        .anon_methods = self.anon_methods.clone(),
        .class_default_outer = self.class_default_outer.clone(),
        .closures = self.closures.clone(),
        .out_sink = self.out_sink.clone(),
        .threads = self.threads.clone(),
        .allocator = self.allocator,
    };
}

/// Release the cloned handles a `vmHost` produced.
fn vmHostDeinit(host: *VmHost) void {
    host.globals.deinit();
    host.module.deinit();
    host.instance_id_counter.deinit();
    host.classes.deinit();
    host.prog.deinit();
    host.anon_methods.deinit();
    host.class_default_outer.deinit();
    host.closures.deinit();
    host.out_sink.deinit();
    host.threads.deinit();
}

/// A sibling `VmIntrinsicHost` over the same shared state, used when an
/// intrinsic recursively dispatches another intrinsic.
pub fn childHost(self: *VmIntrinsicHost) VmIntrinsicHost {
    return .{
        .scheduler = self.scheduler,
        .module = self.module.clone(),
        .closures = self.closures.clone(),
        .globals = self.globals.clone(),
        .classes = self.classes.clone(),
        .prog = self.prog.clone(),
        .anon_methods = self.anon_methods.clone(),
        .class_default_outer = self.class_default_outer.clone(),
        .instance_id_counter = self.instance_id_counter.clone(),
        .out_sink = self.out_sink.clone(),
        .threads = self.threads.clone(),
        .allocator = self.allocator,
    };
}

/// Release the cloned handles a `childHost` produced.
fn childHostDeinit(child: *VmIntrinsicHost) void {
    child.module.deinit();
    child.closures.deinit();
    child.globals.deinit();
    child.classes.deinit();
    child.prog.deinit();
    child.anon_methods.deinit();
    child.class_default_outer.deinit();
    child.instance_id_counter.deinit();
    child.out_sink.deinit();
    child.threads.deinit();
}

/// Build a `SendableVmSeed` snapshot of the shared program state for a
/// freshly spawned OS thread / dispatch worker.
fn spawnSeed(self: *VmIntrinsicHost) SendableVmSeed {
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
        .allocator = self.allocator,
    };
}

// -------------------------------------------------------------------------
// EvalError -> RuntimeError mapping.
// -------------------------------------------------------------------------

/// Map an `EvalError` onto the runtime's `RuntimeError`, mirroring the
/// Rust match arms (`Throw -> Thrown`, `NonLocalReturn -> Return`, every
/// other variant rendered as a `Type` error).
fn runtimeErrorFromEval(e: EvalError) RuntimeError {
    return switch (e) {
        .Throw => |v| .{ .Thrown = v },
        .NonLocalReturn => |v| .{ .Return = v },
        .Suspended => .{ .Type = "coroutine suspended outside a driver" },
        .Unsupported => |s| .{ .Type = s },
        .Type => |s| .{ .Type = s },
        .Unbound => |s| .{ .Unbound = s },
        .Unimplemented => |s| .{ .Unimplemented = s },
        .Arity => |s| .{ .Arity = s },
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
    defer vmHostDeinit(&host);
    var iface = host.hostInterface();
    return iface.newInstance(self.allocator, class_id, args);
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
    const module = module_g.get();
    if (info.body_func.int() >= module.funcs.items.len) {
        const msg = try std.fmt.allocPrint(
            self.allocator,
            "closure body FuncId {d} out of range",
            .{info.body_func.int()},
        );
        return .{ .err = .{ .Type = msg } };
    }
    const func = &module.funcs.items[info.body_func.int()];

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

    // Layer a fresh env carrying the captures on top of globals so the
    // body's StoreGlobal writes land there, then read them back into the
    // closure's captures cell for the outer WritebackCaptures.
    const scoped_env = try ObjRef(Env).init(self.allocator, Env.withParent(self.allocator, self.globals.clone()));
    defer scoped_env.deinit();
    {
        const se = scoped_env.borrowMut();
        defer se.deinit();
        const n = @min(info.capture_names.len, capture_values.items.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try se.get().define(info.capture_names[i], capture_values.items[i]);
        }
    }

    var args_owned: std.ArrayList(Value) = .empty;
    try args_owned.appendSlice(self.allocator, call_args.items);
    var caps_owned: std.ArrayList(Value) = .empty;
    try caps_owned.appendSlice(self.allocator, capture_values.items);

    var host = VmHost{
        .globals = scoped_env.clone(),
        .module = self.module.clone(),
        .scheduler = self.scheduler,
        .out = out,
        .instance_id_counter = self.instance_id_counter.clone(),
        .classes = self.classes.clone(),
        .prog = self.prog.clone(),
        .anon_methods = self.anon_methods.clone(),
        .class_default_outer = self.class_default_outer.clone(),
        .closures = self.closures.clone(),
        .out_sink = self.out_sink.clone(),
        .threads = self.threads.clone(),
        .allocator = self.allocator,
    };
    defer vmHostDeinit(&host);
    var iface = host.hostInterface();
    const result = try ir.eval.evalWithCaptures(self.allocator, module, func, args_owned, caps_owned, &iface);

    // Read back updated capture values into the closure's captures cell.
    var new_captures: std.ArrayList(Value) = .empty;
    {
        const se = scoped_env.borrow();
        defer se.deinit();
        for (info.capture_names) |n| {
            try new_captures.append(self.allocator, se.get().lookup(n) orelse .Null);
        }
    }
    {
        const cap_g = info.captures.borrowMut();
        defer cap_g.deinit();
        cap_g.get().deinit(self.allocator);
        cap_g.get().* = new_captures;
    }
    return result;
}

/// Resume a parked activation with `value`, raw `EvalError` out.
pub fn resumeRaw(self: *VmIntrinsicHost, state: *SuspendState, value: Value, out: Output) Allocator.Error!RawResult {
    const module_g = self.module.borrow();
    defer module_g.deinit();
    const module = module_g.get();
    var host = vmHost(self, out);
    defer vmHostDeinit(&host);
    var iface = host.hostInterface();
    return ir.eval.resumeContinuation(self.allocator, module, state, value, &iface);
}

// -------------------------------------------------------------------------
// `runtime.IntrinsicHost` vtable entry points.
// -------------------------------------------------------------------------

pub fn scheduler(self: *VmIntrinsicHost) Scheduler {
    return self.scheduler.scheduler();
}

/// Drive `block` as the root of a cooperative coroutine. The cooperative
/// interceptor / virtual-time driver is not yet in place, so the block
/// runs straight through against its scope, matching the trait default.
pub fn runBlocking(self: *VmIntrinsicHost, block: *const Value, scope: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    const r = try evalClosureRaw(self, block, &.{}, scope, out);
    return flattenEval(r);
}

pub fn coroutineRunRoot(self: *VmIntrinsicHost, scope: ?*const Value, block: *const Value, out: Output) Allocator.Error!RuntimeEvalResult {
    const r = try evalClosureRaw(self, block, &.{}, scope, out);
    return flattenEval(r);
}

pub fn coroutineLaunch(self: *VmIntrinsicHost, block: *const Value, scope: *const Value, out: Output) Allocator.Error!?RuntimeError {
    const r = try evalClosureRaw(self, block, &.{}, scope, out);
    return switch (r) {
        .ok => null,
        .err => |e| runtimeErrorFromEval(e),
    };
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
                    name = sg.get().*;
                }
            }
        }
        if (recv != null and name != null) {
            const r = recv.?;
            const nm = name.?;
            const unbound = r == .Class and args.len != 0;
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
            defer vmHostDeinit(&host);
            var iface = host.hostInterface();
            const result = if (as_property)
                try iface.getField(self.allocator, &target, nm)
            else
                try iface.callMember(self.allocator, &target, nm, member_args);
            return flattenEval(result);
        }
    }

    if (callable.* == .IrClosure) {
        const id = callable.IrClosure.id;
        const info = self.closures.get(@intCast(id)) orelse {
            const msg = try std.fmt.allocPrint(self.allocator, "unknown IrClosure id {d}", .{id});
            return .{ .err = .{ .Type = msg } };
        };
        const module_g = self.module.borrow();
        defer module_g.deinit();
        const module = module_g.get();
        if (info.body_func.int() >= module.funcs.items.len) {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "closure body FuncId {d} out of range",
                .{info.body_func.int()},
            );
            return .{ .err = .{ .Type = msg } };
        }
        const func = &module.funcs.items[info.body_func.int()];

        var capture_values: std.ArrayList(Value) = .empty;
        {
            const cap_g = info.captures.borrow();
            defer cap_g.deinit();
            try capture_values.appendSlice(self.allocator, cap_g.get().items);
        }

        // Pre-define each captured name in a fresh env layered on globals
        // so the body's StoreGlobal writes land there, then read the
        // updated values back into the closure's captures.
        const scoped_env = try ObjRef(Env).init(self.allocator, Env.withParent(self.allocator, self.globals.clone()));
        defer scoped_env.deinit();
        {
            const se = scoped_env.borrowMut();
            defer se.deinit();
            const n = @min(info.capture_names.len, capture_values.items.len);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                try se.get().define(info.capture_names[i], capture_values.items[i]);
            }
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

        var caps_owned: std.ArrayList(Value) = .empty;
        try caps_owned.appendSlice(self.allocator, capture_values.items);
        capture_values.deinit(self.allocator);

        var host = VmHost{
            .globals = scoped_env.clone(),
            .module = self.module.clone(),
            .scheduler = self.scheduler,
            .out = out,
            .instance_id_counter = self.instance_id_counter.clone(),
            .classes = self.classes.clone(),
            .prog = self.prog.clone(),
            .anon_methods = self.anon_methods.clone(),
            .class_default_outer = self.class_default_outer.clone(),
            .closures = self.closures.clone(),
            .out_sink = self.out_sink.clone(),
            .threads = self.threads.clone(),
            .allocator = self.allocator,
        };
        defer vmHostDeinit(&host);
        var iface = host.hostInterface();
        const result = try ir.eval.evalWithCaptures(self.allocator, module, func, call_args, caps_owned, &iface);

        var new_captures: std.ArrayList(Value) = .empty;
        {
            const se = scoped_env.borrow();
            defer se.deinit();
            for (info.capture_names) |n| {
                try new_captures.append(self.allocator, se.get().lookup(n) orelse .Null);
            }
        }
        {
            const cap_g = info.captures.borrowMut();
            defer cap_g.deinit();
            cap_g.get().deinit(self.allocator);
            cap_g.get().* = new_captures;
        }
        return flattenEval(result);
    }

    // A class value used as a function is a constructor reference
    // (`::Box`, `Outer::Nested`) — invoking it builds an instance.
    if (callable.* == .Class) {
        const def = callable.Class;
        var name: []const u8 = undefined;
        {
            const dg = def.borrow();
            defer dg.deinit();
            name = dg.get().name;
        }
        const module_g = self.module.borrow();
        const class_id_opt = module_g.get().classId(name);
        module_g.deinit();
        if (class_id_opt) |class_id| {
            const r = try construct(self, class_id, args, out);
            return flattenEval(r);
        }
    }

    if (callable.* == .Intrinsic) {
        var child = childHost(self);
        defer childHostDeinit(&child);
        var ctx = runtime.CallCtx{
            .args = args,
            .out = out,
            .host = child.intrinsicHost(),
            .allocator = self.allocator,
        };
        return callable.Intrinsic.func(&ctx);
    }

    // Callable instance (a user class declaring `operator fun invoke`):
    // dispatch through its `invoke` member.
    if (callable.* == .Instance) {
        var host = vmHost(self, out);
        defer vmHostDeinit(&host);
        var iface = host.hostInterface();
        const r = try iface.callMember(self.allocator, callable, "invoke", args);
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
            // its parameter.
            var all: std.ArrayList(Value) = .empty;
            defer all.deinit(self.allocator);
            if (inf.n_params >= 1 and args.len < inf.n_params) {
                try all.append(self.allocator, this_value.*);
                for (args) |a| try all.append(self.allocator, a);
            } else {
                try all.appendSlice(self.allocator, args);
            }

            const result = try invokeCallable(self, callable, all.items, out);

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

    const msg = try std.fmt.allocPrint(self.allocator, "Vm::invoke_callable_with_this on `{s}`", .{callable.typeFqn()});
    return .{ .err = .{ .Unimplemented = msg } };
}

pub fn invokeMethod(self: *VmIntrinsicHost, receiver: *const Value, name: []const u8, args: []const Value, out: Output) Allocator.Error!?RuntimeEvalResult {
    // Build a VmHost that shares this IntrinsicHost's tables and route
    // through call_member so the dispatch picks up user override methods.
    var host = vmHost(self, out);
    defer vmHostDeinit(&host);
    var iface = host.hostInterface();
    const r = try iface.callMember(self.allocator, receiver, name, args);
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
    const cg = self.classes.borrow();
    defer cg.deinit();
    if (cg.get().get(name)) |def| {
        return .{ .Class = def.clone() };
    }
    return null;
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
        .supertype_names = &.{},
        .parent = try ObjRef(?ObjRef(ClassDef)).init(self.allocator, null),
        .interfaces = try ObjRef(std.ArrayList(ObjRef(ClassDef))).init(self.allocator, .empty),
        .is_interface = false,
        .is_fun_interface = false,
        .parent_ctor_args = &.{},
        .is_open = false,
        .is_abstract = false,
        .is_inner = false,
        .is_anonymous = true,
        .secondary_ctors = &.{},
        .enum_entries = try ObjRef(std.ArrayList(ClassDef.EnumEntry)).init(self.allocator, .empty),
        .companion = try ObjRef(?ObjRef(InstanceData)).init(self.allocator, null),
        .enclosing_class = try ObjRef(?ObjRef(ClassDef)).init(self.allocator, null),
        .nested_classes = try ObjRef(std.ArrayList(ClassDef.NestedClass)).init(self.allocator, .empty),
        .captured_env = try ObjRef(Env).init(self.allocator, Env.init(self.allocator)),
        .supertype_delegates = try ObjRef(std.ArrayList(runtime.SupertypeDelegate)).init(self.allocator, .empty),
        .delegate_forwarders = try ObjRef(std.ArrayList(runtime.MethodDef)).init(self.allocator, .empty),
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
    threads: root.ThreadTable,
    id: u64,
    elastic: bool,
    gated: bool,
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
    root.setCoroutineTimeMode(args.time_mode);
    var vm = args.seed.materialize() catch {
        publishThreadResult(args.threads, args.id, .{ .err = .{ .Type = "failed to materialize worker Vm" } });
        return;
    };
    defer vm.deinit();
    const r = vm.runThreadBlock(&args.block) catch {
        publishThreadResult(args.threads, args.id, .{ .err = .{ .Type = "worker out of memory" } });
        return;
    };
    runtime.fenceAndPublish();
    switch (r) {
        .ok => |v| {
            v.publishDeep(args.seed.allocator);
            publishThreadResult(args.threads, args.id, .{ .ok = {} });
        },
        .err => |e| switch (e) {
            .Return => |v| {
                v.publishDeep(args.seed.allocator);
                publishThreadResult(args.threads, args.id, .{ .ok = {} });
            },
            else => publishThreadResult(args.threads, args.id, .{ .err = e }),
        },
    }
}

/// Publish the escaping graph then spawn a worker thread for `block`.
fn startWorker(self: *VmIntrinsicHost, block: *const Value, elastic: bool, gated: bool) Allocator.Error!HostResultU64 {
    // Publish the escaping block and every shared root the child can
    // reach so observing them from the new thread is sound.
    block.publishDeep(self.allocator);
    runtime.publishEnvDeep(self.allocator, self.globals);
    {
        const cg = self.classes.borrow();
        defer cg.deinit();
        var it = cg.get().valueIterator();
        while (it.next()) |def| {
            (Value{ .Class = def.clone() }).publishDeep(self.allocator);
        }
    }
    {
        const og = self.class_default_outer.borrow();
        defer og.deinit();
        var it = og.get().valueIterator();
        while (it.next()) |v| v.publishDeep(self.allocator);
    }
    // Transition the shared container cells the child reads to the SHARED
    // (rwlock) discipline so concurrent borrows from the worker don't race
    // the parent's `RefCell`-style flag. Mirrors Rust's `Arc<...>` roots:
    // `classes`, `anon_methods`, `class_default_outer`, plus the
    // build-time-immutable `prog` image and its `installed_bindings`
    // overlay every dispatch path borrows.
    self.classes.publish();
    self.anon_methods.publish();
    self.class_default_outer.publish();
    self.prog.publish();
    {
        const pg = self.prog.borrow();
        defer pg.deinit();
        pg.get().installed_bindings.publish();
    }
    runtime.fenceAndPublish();

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

    const wargs = WorkerArgs{
        .seed = spawnSeed(self),
        .block = block.*,
        .time_mode = root.coroutineTimeMode(),
        .threads = self.threads.clone(),
        .id = id,
        .elastic = elastic,
        .gated = gated,
    };

    const handle = std.Thread.spawn(.{ .stack_size = 64 * 1024 * 1024 }, workerEntry, .{wargs}) catch {
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
pub fn spawnOsThread(self: *VmIntrinsicHost, block: *const Value, out: Output) Allocator.Error!HostResultU64 {
    _ = out;
    return startWorker(self, block, false, false);
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
        h.join();
        runtime.fenceAndPublish();
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

/// Dispatch a coroutine body onto a worker thread (`Dispatchers.Default`
/// / `Dispatchers.IO`). Reuses the spawned-thread publication + join
/// machinery; `elastic` selects the unbounded (IO) pool.
pub fn dispatchCoroutine(self: *VmIntrinsicHost, block: *const Value, elastic: bool, out: Output) Allocator.Error!HostResultU64 {
    _ = out;
    return startWorker(self, block, elastic, true);
}

pub fn joinDispatched(self: *VmIntrinsicHost, id: u64) Allocator.Error!?RuntimeError {
    return joinOsThread(self, id);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}
