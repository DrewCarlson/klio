//! `VmHost` calls of stdlib natives: a native runs through a `CallCtx` on a
//! view of this host's handles, and its error comes back as the evaluator's.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const vmhost = @import("vmhost.zig");
const host_util = @import("host_util.zig");

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
    const track = runtime.leaktrack.active();
    const prev_fqn_lt = if (track) runtime.leaktrack.currentFqn() else null;
    if (track) runtime.leaktrack.setCurrentFqn(fqn);
    const r = try func(&ctx);
    if (track) runtime.leaktrack.setCurrentFqn(prev_fqn_lt);
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = runtimeErrorToEval(allocator, e) },
    };
}

/// A stdlib native's result as the VM's: its error mapped as `callStdlibBorrowed` maps it.
pub fn evalResultOf(allocator: Allocator, r: runtime.EvalResult) EvalResult {
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = runtimeErrorToEval(allocator, e) },
    };
}

/// A suspend state a generator's step handed back (`recycleSuspendState`), its frame list
/// empty with its buffer kept, for the next suspension on this thread; stamped with the
/// program it was allocated in, as a later program's allocator is another. Held in
/// `tls_fast`, as a `threadlocal` costs a call into dyld per access on Darwin.
const Spare = struct { state: ?*SuspendState = null, gen: u32 = 0 };
const spare_tls = runtime.tls_fast.PerThread(Spare);

/// Keeps `st`, whose frames were resumed and emptied, for the next suspension on this thread
/// to fill in place of a new one; frees it when a spare is kept already.
pub fn recycleSuspendState(allocator: Allocator, st: *SuspendState) void {
    const spare = spare_tls.get();
    if (spare.state != null and spare.gen == host_util.dispatchCacheGen()) {
        st.frames.deinit(allocator);
        allocator.destroy(st);
        return;
    }
    st.frames.clearRetainingCapacity();
    spare.* = .{ .state = st, .gen = host_util.dispatchCacheGen() };
}

fn runtimeErrorToEval(allocator: Allocator, e: RuntimeError) EvalError {
    return switch (e) {
        .Thrown => |v| .{ .Throw = v },
        .Return => |v| .{ .NonLocalReturn = v },
        // A suspending primitive asked to park: seed a SuspendState, fresh or the spare a
        // generator handed back, which each enclosing `eval` frame fills as it unwinds for the
        // driver to park.
        .Suspend => |wake| blk: {
            var frames: std.ArrayList(ir.eval.FrameSnapshot) = .empty;
            const spare = spare_tls.get();
            const st = if (spare.state != null and spare.gen == host_util.dispatchCacheGen()) kept: {
                const sp = spare.state.?;
                spare.state = null;
                frames = sp.frames;
                break :kept sp;
            } else fresh: {
                spare.state = null;
                break :fresh allocator.create(SuspendState) catch break :blk EvalError{ .Type = "out of memory seeding suspend" };
            };
            st.* = .{ .token = 0, .frames = frames, .wake_in_millis = wake, .pending_resume_reg = null };
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

test "a suspension takes the state a generator step recycled, but not one an earlier program left" {
    const a = std.testing.allocator;
    const first = runtimeErrorToEval(a, .{ .Suspend = -1 }).Suspended;
    try first.frames.ensureTotalCapacity(a, 1);
    recycleSuspendState(a, first);
    // The next suspension fills the same state, its frame buffer kept.
    const second = runtimeErrorToEval(a, .{ .Suspend = 5 }).Suspended;
    try std.testing.expectEqual(first, second);
    try std.testing.expect(second.frames.capacity >= 1);
    try std.testing.expectEqual(@as(i64, 5), second.wake_in_millis);
    recycleSuspendState(a, second);
    // A program boundary: the spare belongs to the program before, and is left alone.
    host_util.bumpDispatchCacheGen();
    const third = runtimeErrorToEval(a, .{ .Suspend = -1 }).Suspended;
    try std.testing.expect(third != second);
    third.frames.deinit(a);
    a.destroy(third);
    second.frames.deinit(a);
    a.destroy(second);
}
