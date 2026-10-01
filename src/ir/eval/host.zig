//! The evaluator host interface and the null host used when no interpreter is driving.

const std = @import("std");
const runtime = @import("runtime");
const ir = @import("../ir.zig");

const Allocator = std.mem.Allocator;

const Value = runtime.Value;

const FuncId = ir.FuncId;
const Module = ir.Module;

const ev_enter = @import("enter.zig");
const ev_flow = @import("flow.zig");
const ev_state = @import("state.zig");

const EvalResult = ev_flow.EvalResult;
const errResult = ev_flow.errResult;

/// The host for ir's own tests and the bare `eval` entry: natives are unsupported, a
/// closure over a function literal is made only where a run state was given, and a
/// resolved function runs recursively. The evaluator is generic over the host type.
pub const NullHost = struct {
    /// The run state code lowered from sema reads; null until a test sets
    /// one, and every static, singleton and construction then fails.
    resolved_state: ?ir.resolved.StateRef = null,
    /// What a resumed activation receives in place of its resume value;
    /// null passes the value through.
    resume_as: ?Value = null,
    /// Whether the parked frames were on the thread's resume root when the
    /// resume value was asked for.
    resume_rooted: bool = false,
    /// The module of the closures it made, whose function each closure's record is.
    closure_module: ?*const Module = null,
    /// The span of the frame that made the last host call.
    native_span: ?ir.Span = null,

    pub fn resolvedState(self: *NullHost) ?ir.resolved.StateRef {
        return self.resolved_state;
    }

    pub fn resumeValue(self: *NullHost, allocator: Allocator, v: Value) Allocator.Error!Value {
        _ = allocator;
        const node = ev_state.evtlsPtr().resuming;
        self.resume_rooted = node != null and node.?.head.* < node.?.frames.items.len;
        return self.resume_as orelse v;
    }

    pub fn callNative(self: *NullHost, allocator: Allocator, id: ir.NativeId, args: []const Value) Allocator.Error!EvalResult {
        _ = .{ allocator, args };
        _ = id;
        if (ev_state.evtlsPtr().frame_chain) |fr| self.native_span = fr.span();
        return errResult(.{ .Unsupported = "Host.call_native" });
    }

    /// No fast path answers here: every body runs.
    pub fn tryNative(self: *NullHost, allocator: Allocator, id: ir.NativeId, args: []const Value) Allocator.Error!?EvalResult {
        _ = .{ self, allocator, id, args };
        return null;
    }

    /// Runs `f` in `module` recursively; needs no host service of its own.
    pub fn runResolved(self: *NullHost, allocator: Allocator, module: *const Module, f: FuncId, args: []const Value) Allocator.Error!EvalResult {
        const func = module.funcById(f) orelse return errResult(.{ .Unsupported = "Host.run_resolved: no such function" });
        var list: std.ArrayList(Value) = .empty;
        try list.appendSlice(allocator, args);
        return ev_enter.evalWith(NullHost, allocator, module, func, list, self);
    }

    /// A closure over function literal `func` of the one module its closures come from, its
    /// record the function itself.
    pub fn makeResolvedClosure(self: *NullHost, allocator: Allocator, module: *const Module, func: FuncId, captures: []const Value, kind: ir.resolved.Callable) Allocator.Error!EvalResult {
        if (self.resolved_state == null or kind != .lambda) return errResult(.{ .Unsupported = "Host.make_resolved_closure" });
        if (self.closure_module) |m| if (m != module) return errResult(.{ .Unsupported = "Host.make_resolved_closure: another module" });
        const f = module.funcById(func) orelse return errResult(.{ .Unsupported = "Host.make_resolved_closure: no such function" });
        self.closure_module = module;
        const ref = try runtime.IrClosureRef.initTrailing(allocator, .{ .id = 0, .captures = &.{}, .body = @ptrCast(f) }, captures.len);
        @memcpy(ref.cell.data.captures, captures);
        return .{ .ok = .{ .IrClosure = ref } };
    }

    pub fn resolvedClosure(self: *NullHost, v: *const Value) ?ir.resolved.ClosureBody {
        if (v.* != .IrClosure) return null;
        const module = self.closure_module orelse return null;
        const body = v.IrClosure.asPtrConst().body orelse return null;
        return .{ .id = 0, .func = @ptrCast(@alignCast(body)), .module = module, .kind = .lambda };
    }
};

pub fn nullHost() NullHost {
    return .{};
}
