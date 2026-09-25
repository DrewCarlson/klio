//! `VmHost` value calls: a closure made from sema's code, a native value, or
//! an instance of a class implementing a function type. Free functions over
//! `*VmHost`.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");

const vmhost = @import("vmhost.zig");
const host_resolved = @import("host_resolved.zig");
const host_call_func = @import("host_call_func.zig");

const VmHost = vmhost.VmHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;

const EvalResult = ir.eval.EvalResult;

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

