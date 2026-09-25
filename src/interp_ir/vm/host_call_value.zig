//! `VmHost` value calls: a closure made from sema's code, a native value, or
//! an instance of a class implementing a function type; and the evaluator's
//! hooks around flat calls and coroutine roots. Free functions over
//! `*VmHost`, aliased as methods by `vmhost.zig`.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");

const vmhost = @import("vmhost.zig");
const host_resolved = @import("host_resolved.zig");
const host_call_func = @import("host_call_func.zig");
const compose = @import("compose.zig");

const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;

const EvalResult = ir.eval.EvalResult;
const SuspendState = ir.eval.SuspendState;

pub fn flatCallClosed(self: *VmHost) void {
    _ = self;
    compose.popComposer();
}

/// Driver hook: park the root into its own pump, drain and exit it, and return
/// the resumed value or COROUTINE_SUSPENDED.
pub fn rootPumpBarrierPark(self: *VmHost, allocator: Allocator, st: *SuspendState, scope: Value, base: usize) Allocator.Error!EvalResult {
    var sink = self.out_sink.clone();
    defer sink.deinit();
    var intrinsic = VmIntrinsicHost.owning(self);
    defer intrinsic.release();
    const r = try vmhost.coroutines.rootPumpFlatPark(&intrinsic, allocator, sink.output(), st, &scope, base);
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| try runtimeErrToEval(allocator, e),
    };
}

/// Driver hook: run the pump to quiescence with the body's result as the root
/// value, or just exit it when the body raised.
pub fn rootPumpFlatComplete(self: *VmHost, allocator: Allocator, res: EvalResult, scope: Value, base: usize) Allocator.Error!EvalResult {
    var sink = self.out_sink.clone();
    defer sink.deinit();
    var intrinsic = VmIntrinsicHost.owning(self);
    defer intrinsic.release();
    if (res == .ok) {
        const r = try vmhost.coroutines.rootPumpFlatFinish(&intrinsic, sink.output(), &scope, res.ok, base, false);
        return switch (r) {
            .ok => |v| .{ .ok = v },
            .err => |e| try runtimeErrToEval(allocator, e),
        };
    }
    _ = try vmhost.coroutines.rootPumpFlatFinish(&intrinsic, sink.output(), &scope, null, base, true);
    return res;
}

pub fn undispatchedBarrierPark(self: *VmHost, allocator: Allocator, st: *SuspendState, scope_base: usize) Allocator.Error!Value {
    _ = self;
    return vmhost.coroutines.undispatchedFlatPark(allocator, st, scope_base);
}

/// Driver hook: remove the scope entry the prepare pushed, by identity.
pub fn undispatchedScopeLeave(self: *VmHost, ident: usize) void {
    _ = self;
    vmhost.coroutines.undispatchedFlatLeaveIdent(ident);
}

/// Calls `callee` over `args`: a closure made from sema's code, a native
/// value, or an instance of a class implementing the function type of the
/// call's arity.
pub fn callValue(self: *VmHost, allocator: Allocator, callee: *const Value, args: []const Value) Allocator.Error!EvalResult {
    // A captured-and-written local is boxed, so a function-typed one is a cell.
    if (callee.* == .Cell) {
        const cg = callee.Cell.borrow();
        const inner = cg.get().*;
        inner.retain();
        cg.deinit();
        defer inner.release(allocator);
        return callValue(self, allocator, &inner, args);
    }
    if (callee.* == .Intrinsic) {
        return host_call_func.callStdlibBorrowed(self, allocator, callee.Intrinsic.fqn, callee.Intrinsic.func, args);
    }
    if (try host_resolved.callResolvedClosure(self, allocator, callee, null, args)) |r| return r;
    if (callee.* == .Instance) {
        if (try host_resolved.callWellKnown(self, allocator, callee, .invoke, args)) |r| return r;
    }
    const msg = try std.fmt.allocPrint(allocator, "a {s} takes no {d} arguments as a function", .{ callee.typeFqn(), args.len });
    return .{ .err = .{ .Type = msg } };
}

/// Map a `RuntimeError` onto an `EvalError`, preserving throws, returns, suspends.
fn runtimeErrToEval(allocator: Allocator, e: RuntimeError) Allocator.Error!EvalResult {
    switch (e) {
        // Preserve the thrown Value so try/catch can match the exception class.
        .Thrown => |v| return .{ .err = .{ .Throw = v } },
        .Return => |v| return .{ .err = .{ .NonLocalReturn = v } },
        // A suspending primitive asked to park: seed a fresh SuspendState. Each
        // enclosing `eval` frame snapshots itself as it unwinds.
        .Suspend => |wake| {
            const st = try allocator.create(SuspendState);
            st.* = .{
                .token = 0,
                .frames = .empty,
                .wake_in_millis = wake,
                .pending_resume_reg = null,
            };
            return .{ .err = .{ .Suspended = st } };
        },
        // Each kind maps to its `EvalError` counterpart, message carried through;
        // `{any}` would print the payload raw and re-wrap it in a second `.Type`.
        .Unbound => |s| return .{ .err = .{ .Unbound = s } },
        .Type => |s| return .{ .err = .{ .Type = s } },
        .Arity => |s| return .{ .err = .{ .Arity = s } },
        .Unimplemented => |s| return .{ .err = .{ .Unimplemented = s } },
        .CalleeFailed => |s| return .{ .err = .{ .CalleeFailed = s } },
        .LabeledReturn => |lr| return .{ .err = .{ .LabeledReturn = .{ .label = lr.label, .value = lr.value } } },
        else => {
            const msg = try std.fmt.allocPrint(allocator, "{s}", .{@tagName(e)});
            return .{ .err = .{ .Type = msg } };
        },
    }
}
