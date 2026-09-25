//! `VmHost` calls of stdlib natives: a native runs through a `CallCtx` on a
//! view of this host's handles, and its error comes back as the evaluator's.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const vmhost = @import("vmhost.zig");

const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const StdlibFn = runtime.StdlibFn;
const CallCtx = runtime.CallCtx;

const EvalError = ir.eval.EvalError;
const EvalResult = ir.eval.EvalResult;
const SuspendState = ir.eval.SuspendState;

/// Run stdlib native `func` over `args` through a `CallCtx` on a view of
/// this host's handles that takes no references. A native that keeps the
/// host past its call takes `persist()`, which holds its own.
pub fn dispatchIntrinsic(self: *VmHost, allocator: Allocator, fqn: []const u8, func: StdlibFn, args: []const Value) Allocator.Error!EvalResult {
    vmhost.emitPath(allocator, "intrinsic_call_func", fqn, null, null, args);
    return callStdlibBorrowed(self, allocator, fqn, func, args);
}

/// Runs stdlib native `func` over `args` on a view of this host's handles
/// that takes no references: a member the bridge bound to the native once
/// (`host_members`), which lives no longer than this host does.
pub fn callStdlibBorrowed(self: *VmHost, allocator: Allocator, fqn: []const u8, func: StdlibFn, args: []const Value) Allocator.Error!EvalResult {
    const keepalive = self.ka.mark();
    defer self.ka.restore(keepalive);
    self.ka.pushSlice(args);
    var intrinsic = VmIntrinsicHost.borrowed(vmhost.SharedHandles.fromHost(self));
    stdlib.implementations.string.clearRecvMemo();
    var ctx = CallCtx{
        .args = args,
        .out = self.out,
        .host = intrinsic.intrinsicHost(),
        .allocator = allocator,
    };
    const prev_fqn_lt = runtime.leaktrack.currentFqn();
    runtime.leaktrack.setCurrentFqn(fqn);
    const r = try func(&ctx);
    runtime.leaktrack.setCurrentFqn(prev_fqn_lt);
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = runtimeErrorToEval(allocator, e) },
    };
}

fn runtimeErrorToEval(allocator: Allocator, e: RuntimeError) EvalError {
    return switch (e) {
        .Thrown => |v| .{ .Throw = v },
        .Return => |v| .{ .NonLocalReturn = v },
        // A suspending primitive asked to park: seed a fresh SuspendState, which
        // each enclosing `eval` frame fills as it unwinds for the driver to park.
        .Suspend => |wake| blk: {
            const st = allocator.create(SuspendState) catch break :blk EvalError{ .Type = "out of memory seeding suspend" };
            st.* = .{ .token = 0, .frames = .empty, .wake_in_millis = wake, .pending_resume_reg = null };
            break :blk EvalError{ .Suspended = st };
        },
        .Unbound => |s| .{ .Unbound = s },
        .Type => |s| .{ .Type = s },
        .Arity => |s| .{ .Arity = s },
        .Unimplemented => |s| .{ .Unimplemented = s },
        .CalleeFailed => |s| .{ .CalleeFailed = s },
        // A labeled return crossing a host intrinsic keeps unwinding, not flattened to
        // a Type error.
        .LabeledReturn => |lr| .{ .LabeledReturn = .{ .label = lr.label, .value = lr.value } },
        else => .{ .Type = std.fmt.allocPrint(allocator, "{s}", .{@tagName(e)}) catch "IR type error" },
    };
}
