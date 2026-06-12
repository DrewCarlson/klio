//! `kotlin.Result` intrinsics plus the `kotlin.coroutines` language-layer
//! rendezvous primitives the suspend machinery drives.
//!
//! Each intrinsic is a `fn(*CallCtx) !EvalResult`. OOM surfaces as a Zig
//! error; a `RuntimeError` surfaces as data via `EvalResult`.

const std = @import("std");
const runtime = @import("runtime");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const StringRef = runtime.StringRef;

// ============================================================
// Result
// ============================================================

/// The `(ok, payload)` a `recvResult` extracts from a `Value::Result`
/// receiver — `payload` is the result's own boxed payload pointer.
const Recv = struct { ok: bool, payload: *Value };

/// Extract the `(ok, payload)` of a `Value::Result` receiver, or `null`
/// if `args[0]` is not a `Result` (the caller turns that into a
/// `"{what} requires a Result receiver"` type error).
fn recvResult(args: []const Value) ?Recv {
    if (args.len > 0) {
        switch (args[0]) {
            .Result => |r| return .{ .ok = r.ok, .payload = r.payload },
            else => {},
        }
    }
    return null;
}

/// Construct a `Value::Result { ok, payload }` with a heap-boxed payload.
fn makeResult(allocator: std.mem.Allocator, ok: bool, payload: Value) std.mem.Allocator.Error!Value {
    return .{ .Result = .{ .ok = ok, .payload = try Value.box(allocator, payload) } };
}

pub fn result_success(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const v = if (ctx.args.len > 0) ctx.args[0] else Value.Unit;
    return .{ .ok = try makeResult(ctx.allocator, true, v) };
}

pub fn result_failure(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const v = if (ctx.args.len > 0) ctx.args[0] else Value.Unit;
    return .{ .ok = try makeResult(ctx.allocator, false, v) };
}

fn runCatchingResult(allocator: std.mem.Allocator, r: EvalResult) std.mem.Allocator.Error!EvalResult {
    return switch (r) {
        .ok => |v| .{ .ok = try makeResult(allocator, true, v) },
        .err => |e| switch (e) {
            .Thrown => |thrown| .{ .ok = try makeResult(allocator, false, thrown) },
            else => .{ .err = e },
        },
    };
}

fn runCatchingImpl(block: *const Value, ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = try ctx.host.invokeCallable(block, &.{}, ctx.out);
    return runCatchingResult(ctx.allocator, r);
}

pub fn result_run_catching(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    // Two forms:
    //   runCatching { … }    -> 1 arg (block)
    //   x.runCatching { … }  -> 2 args (receiver, block); receiver bound as `this`
    if (ctx.args.len == 1) {
        const block = ctx.args[0];
        return runCatchingImpl(&block, ctx);
    }
    if (ctx.args.len == 2) {
        const recv = ctx.args[0];
        const block = ctx.args[1];
        const r = try ctx.host.invokeCallableWithThis(&block, &.{}, &recv, ctx.out);
        return runCatchingResult(ctx.allocator, r);
    }
    return .{ .err = .{ .Arity = "runCatching expects (block) or (receiver, block)" } };
}

pub fn result_fold(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len != 3) {
        return .{ .err = .{ .Arity = "Result.fold expects (receiver, onSuccess, onFailure)" } };
    }
    const recv = recvResult(ctx.args) orelse
        return .{ .err = .{ .Type = "Result.fold requires a Result receiver" } };
    const payload = recv.payload.*;
    const on_success = ctx.args[1];
    const on_failure = ctx.args[2];
    if (recv.ok) {
        return ctx.host.invokeCallable(&on_success, &.{payload}, ctx.out);
    } else {
        return ctx.host.invokeCallable(&on_failure, &.{payload}, ctx.out);
    }
}

pub fn result_map(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len != 2) {
        return .{ .err = .{ .Arity = "Result.map expects (receiver, block)" } };
    }
    const recv = recvResult(ctx.args) orelse
        return .{ .err = .{ .Type = "Result.map requires a Result receiver" } };
    const payload = recv.payload.*;
    const block = ctx.args[1];
    if (!recv.ok) {
        return .{ .ok = try makeResult(ctx.allocator, false, payload) };
    }
    const r = try ctx.host.invokeCallable(&block, &.{payload}, ctx.out);
    return switch (r) {
        .ok => |v| .{ .ok = try makeResult(ctx.allocator, true, v) },
        .err => |e| .{ .err = e },
    };
}

pub fn result_map_catching(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len != 2) {
        return .{ .err = .{ .Arity = "Result.mapCatching expects (receiver, block)" } };
    }
    const recv = recvResult(ctx.args) orelse
        return .{ .err = .{ .Type = "Result.mapCatching requires a Result receiver" } };
    const payload = recv.payload.*;
    const block = ctx.args[1];
    if (!recv.ok) {
        return .{ .ok = try makeResult(ctx.allocator, false, payload) };
    }
    const r = try ctx.host.invokeCallable(&block, &.{payload}, ctx.out);
    return runCatchingResult(ctx.allocator, r);
}

pub fn result_on_success(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len != 2) {
        return .{ .err = .{ .Arity = "Result.onSuccess expects (receiver, block)" } };
    }
    const recv_value = ctx.args[0];
    const recv = recvResult(ctx.args) orelse
        return .{ .err = .{ .Type = "Result.onSuccess requires a Result receiver" } };
    const payload = recv.payload.*;
    const block = ctx.args[1];
    if (recv.ok) {
        const r = try ctx.host.invokeCallable(&block, &.{payload}, ctx.out);
        if (r == .err) return r;
    }
    return .{ .ok = recv_value };
}

pub fn result_on_failure(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len != 2) {
        return .{ .err = .{ .Arity = "Result.onFailure expects (receiver, block)" } };
    }
    const recv_value = ctx.args[0];
    const recv = recvResult(ctx.args) orelse
        return .{ .err = .{ .Type = "Result.onFailure requires a Result receiver" } };
    const payload = recv.payload.*;
    const block = ctx.args[1];
    if (!recv.ok) {
        const r = try ctx.host.invokeCallable(&block, &.{payload}, ctx.out);
        if (r == .err) return r;
    }
    return .{ .ok = recv_value };
}

pub fn result_is_success(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const recv = recvResult(ctx.args) orelse
        return .{ .err = .{ .Type = "Result.isSuccess requires a Result receiver" } };
    return .{ .ok = .{ .Bool = recv.ok } };
}

pub fn result_is_failure(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const recv = recvResult(ctx.args) orelse
        return .{ .err = .{ .Type = "Result.isFailure requires a Result receiver" } };
    return .{ .ok = .{ .Bool = !recv.ok } };
}

pub fn result_get_or_null(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const recv = recvResult(ctx.args) orelse
        return .{ .err = .{ .Type = "Result.getOrNull requires a Result receiver" } };
    if (recv.ok) {
        return .{ .ok = recv.payload.* };
    } else {
        return .{ .ok = Value.Null };
    }
}

pub fn result_exception_or_null(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const recv = recvResult(ctx.args) orelse
        return .{ .err = .{ .Type = "Result.exceptionOrNull requires a Result receiver" } };
    if (recv.ok) {
        return .{ .ok = Value.Null };
    } else {
        return .{ .ok = recv.payload.* };
    }
}

/// `kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED` — the
/// singleton a `suspendCoroutineUninterceptedOrReturn` block
/// returns to signal it parked rather than producing a value.
/// One logical instance, so `x === COROUTINE_SUSPENDED` holds for
/// any sentinel `x`.
pub fn coroutine_suspended_sentinel(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    return .{ .ok = Value.CoroutineSuspended };
}

/// Process-global monotonic rendezvous-slot counter for the
/// `kotlin.coroutines` language layer. Process-global so cross-thread
/// resume routing (slot → owning runBlocking driver) cannot alias a
/// slot id minted on a different thread.
var co_next_slot = std.atomic.Value(i64).init(1);

/// `__klio_co_newSlot()` — a fresh slot id for a `suspendCoroutine`
/// rendezvous.
pub fn coro_new_slot(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    const id = co_next_slot.fetchAdd(1, .monotonic);
    return .{ .ok = .{ .Long = id } };
}

fn slotArg(args: []const Value, who: []const u8) union(enum) { ok: i64, err: RuntimeError } {
    if (args.len > 0) {
        switch (args[0]) {
            .Long => |l| return .{ .ok = l },
            .Int => |i| return .{ .ok = @as(i64, i) },
            else => {},
        }
    }
    return .{ .err = slotTypeErr(who) };
}

fn slotTypeErr(who: []const u8) RuntimeError {
    if (std.mem.eql(u8, who, "__klio_co_park")) return .{ .Type = "__klio_co_park: slot must be Long" };
    if (std.mem.eql(u8, who, "__klio_co_armSlot")) return .{ .Type = "__klio_co_armSlot: slot must be Long" };
    if (std.mem.eql(u8, who, "__klio_co_resume")) return .{ .Type = "__klio_co_resume: slot must be Long" };
    return .{ .Type = "slot must be Long" };
}

/// `__klio_co_park(slot)` — record the current activation as waiting
/// on `slot`, then suspend indefinitely. On resume the call yields
/// the `Result` delivered by `__klio_co_resume`.
pub fn coro_park(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const slot = switch (slotArg(ctx.args, "__klio_co_park")) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    ctx.host.coroutineArmSlot(slot);
    return .{ .err = .{ .Suspend = -1 } };
}

/// `__klio_co_armSlot(slot)` — bind the next suspension (even a
/// timed one) to `slot` without suspending now, so a suspend inside
/// a `suspendCoroutineUninterceptedOrReturn` block stays reachable
/// via the continuation's slot for preemptive cancellation.
pub fn coro_arm_slot(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const slot = switch (slotArg(ctx.args, "__klio_co_armSlot")) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    ctx.host.coroutineArmSlot(slot);
    return .{ .ok = Value.Unit };
}

/// `__klio_co_disarmSlot()` — cancel a pending arm (the block
/// returned a value without suspending).
pub fn coro_disarm_slot(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    ctx.host.coroutineDisarmSlot();
    return .{ .ok = Value.Unit };
}

/// `__klio_co_pushScope(scope)` — make `scope` the active coroutine
/// scope for an undispatched block running inline in the caller's
/// activation (`startCoroutineUninterceptedOrReturn`), so the
/// suspend-implicit `coroutineContext` inside the block resolves to the
/// block's own coroutine. Balanced by `__klio_co_popScope`.
pub fn coro_push_scope(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const scope: Value = if (ctx.args.len > 0) ctx.args[0] else Value.Unit;
    ctx.host.coroutinePushScope(&scope);
    return .{ .ok = Value.Unit };
}

/// `__klio_co_popScope()` — pop the scope pushed by `__klio_co_pushScope`.
pub fn coro_pop_scope(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    ctx.host.coroutinePopScope();
    return .{ .ok = Value.Unit };
}

/// `__klio_co_resume(slot, ok, value)` — deliver a `Result` to the
/// activation parked on `slot` and make it ready.
pub fn coro_resume(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const slot = switch (slotArg(ctx.args, "__klio_co_resume")) {
        .ok => |s| s,
        .err => |e| return .{ .err = e },
    };
    const ok = ctx.args.len > 1 and ctx.args[1] == .Bool and ctx.args[1].Bool;
    const payload = if (ctx.args.len > 2) ctx.args[2] else Value.Null;
    const result = try makeResult(ctx.allocator, ok, payload);
    ctx.host.coroutineResumeExternal(slot, result, ctx.out);
    return .{ .ok = Value.Unit };
}

/// `__klio_co_runRoot(scope, block)` — drive `block` as a cooperative
/// coroutine root to quiescence, returning its terminal value. The block
/// is always the trailing arg; an optional leading arg is the coroutine
/// the block belongs to, made the active scope while it runs (so a
/// suspend-implicit `coroutineContext` read inside resolves to its `Job`).
pub fn coro_run_root(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 0) {
        return .{ .err = .{ .Type = "__klio_co_runRoot: missing block" } };
    }
    const block = ctx.args[ctx.args.len - 1];
    if (ctx.args.len >= 2) {
        const scope = ctx.args[0];
        return ctx.host.coroutineRunRoot(&scope, &block, ctx.out);
    }
    return ctx.host.coroutineRunRoot(null, &block, ctx.out);
}

/// `Result.getOrThrow()` — the success value, or rethrow the
/// captured failure. Core to `Continuation.resumeWith`.
pub fn result_get_or_throw(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const recv = recvResult(ctx.args) orelse
        return .{ .err = .{ .Type = "Result.getOrThrow requires a Result receiver" } };
    if (recv.ok) {
        return .{ .ok = recv.payload.* };
    } else {
        return .{ .err = .{ .Thrown = recv.payload.* } };
    }
}

pub fn result_get_or_else(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len != 2) {
        return .{ .err = .{ .Arity = "Result.getOrElse expects (receiver, onFailure)" } };
    }
    const recv = recvResult(ctx.args[0..1]) orelse
        return .{ .err = .{ .Type = "Result.getOrElse requires a Result receiver" } };
    if (recv.ok) {
        return .{ .ok = recv.payload.* };
    }
    const payload = recv.payload.*;
    const block = ctx.args[1];
    return ctx.host.invokeCallable(&block, &.{payload}, ctx.out);
}

pub fn result_get_or_default(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const recv = recvResult(ctx.args) orelse
        return .{ .err = .{ .Type = "Result.getOrDefault requires a Result receiver" } };
    if (ctx.args.len < 2) {
        return .{ .err = .{ .Arity = "Result.getOrDefault requires a default" } };
    }
    const default = ctx.args[1];
    if (recv.ok) {
        return .{ .ok = recv.payload.* };
    } else {
        return .{ .ok = default };
    }
}

pub fn result_to_string(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const recv = recvResult(ctx.args) orelse
        return .{ .err = .{ .Type = "Result.toString requires a Result receiver" } };
    const inner = try recv.payload.display(ctx.allocator);
    defer ctx.allocator.free(inner);
    const s = if (recv.ok)
        try std.fmt.allocPrint(ctx.allocator, "Success({s})", .{inner})
    else
        try std.fmt.allocPrint(ctx.allocator, "Failure({s})", .{inner});
    return .{ .ok = .{ .String = try StringRef.init(ctx.allocator, s) } };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;
const NoopHost = runtime.NoopHost;
const CaptureOutput = runtime.CaptureOutput;

/// A test host whose `invoke_callable` returns a fixed `EvalResult`,
/// recording the args/this it was handed. Lets the higher-order Result
/// intrinsics be exercised without a full interpreter.
const StubHost = struct {
    /// What `invoke_callable` / `invoke_callable_with_this` hand back.
    reply: EvalResult = .{ .ok = Value.Unit },
    /// Most recent first-arg / this seen by an invocation.
    last_arg: ?Value = null,
    last_this: ?Value = null,
    invoked: usize = 0,

    fn init(allocator: std.mem.Allocator) StubHost {
        _ = allocator;
        return .{};
    }
    fn deinit(self: *StubHost) void {
        _ = self;
    }

    fn vtInvokeCallable(ctx: *anyopaque, callable: *const Value, args: []const Value, out: runtime.Output) std.mem.Allocator.Error!EvalResult {
        _ = callable;
        _ = out;
        const self: *StubHost = @ptrCast(@alignCast(ctx));
        self.invoked += 1;
        self.last_arg = if (args.len > 0) args[0] else null;
        return self.reply;
    }
    fn vtInvokeCallableWithThis(ctx: *anyopaque, callable: *const Value, args: []const Value, this_value: *const Value, out: runtime.Output) std.mem.Allocator.Error!EvalResult {
        _ = callable;
        _ = out;
        const self: *StubHost = @ptrCast(@alignCast(ctx));
        self.invoked += 1;
        self.last_arg = if (args.len > 0) args[0] else null;
        self.last_this = this_value.*;
        return self.reply;
    }

    const vtable: runtime.IntrinsicHost.VTable = .{
        .invoke_callable = vtInvokeCallable,
        .invoke_callable_with_this = vtInvokeCallableWithThis,
    };

    fn host(self: *StubHost) runtime.IntrinsicHost {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

fn ctxWith(args: []const Value, h: runtime.IntrinsicHost, out: runtime.Output, allocator: std.mem.Allocator) CallCtx {
    return .{ .args = args, .out = out, .host = h, .allocator = allocator };
}

test "result_success and result_failure box the payload" {
    var noop = NoopHost.init(testing.allocator);
    defer noop.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ok_args = [_]Value{.{ .Int = 7 }};
    var ctx = ctxWith(&ok_args, noop.host(), cap.output(), a);
    const r = try result_success(&ctx);
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .Result);
    try testing.expect(r.ok.Result.ok);
    try testing.expectEqual(@as(i32, 7), r.ok.Result.payload.Int);

    var ctx2 = ctxWith(&ok_args, noop.host(), cap.output(), a);
    const r2 = try result_failure(&ctx2);
    try testing.expect(r2.ok == .Result);
    try testing.expect(!r2.ok.Result.ok);
    try testing.expectEqual(@as(i32, 7), r2.ok.Result.payload.Int);
}

test "result_success defaults to Unit when no arg" {
    var noop = NoopHost.init(testing.allocator);
    defer noop.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = ctxWith(&.{}, noop.host(), cap.output(), arena.allocator());
    const r = try result_success(&ctx);
    try testing.expect(r.ok.Result.ok);
    try testing.expect(r.ok.Result.payload.* == .Unit);
}

test "isSuccess / isFailure read the ok flag" {
    var noop = NoopHost.init(testing.allocator);
    defer noop.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var payload: Value = .{ .Int = 1 };
    const success = [_]Value{.{ .Result = .{ .ok = true, .payload = &payload } }};
    const failure = [_]Value{.{ .Result = .{ .ok = false, .payload = &payload } }};

    var c1 = ctxWith(&success, noop.host(), cap.output(), a);
    try testing.expect((try result_is_success(&c1)).ok.Bool);
    var c2 = ctxWith(&success, noop.host(), cap.output(), a);
    try testing.expect(!(try result_is_failure(&c2)).ok.Bool);
    var c3 = ctxWith(&failure, noop.host(), cap.output(), a);
    try testing.expect(!(try result_is_success(&c3)).ok.Bool);
    var c4 = ctxWith(&failure, noop.host(), cap.output(), a);
    try testing.expect((try result_is_failure(&c4)).ok.Bool);
}

test "getOrNull / exceptionOrNull pick the right branch" {
    var noop = NoopHost.init(testing.allocator);
    defer noop.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ok_payload: Value = .{ .Int = 5 };
    var err_payload: Value = .{ .Int = 9 };
    const success = [_]Value{.{ .Result = .{ .ok = true, .payload = &ok_payload } }};
    const failure = [_]Value{.{ .Result = .{ .ok = false, .payload = &err_payload } }};

    var c1 = ctxWith(&success, noop.host(), cap.output(), a);
    try testing.expectEqual(@as(i32, 5), (try result_get_or_null(&c1)).ok.Int);
    var c2 = ctxWith(&failure, noop.host(), cap.output(), a);
    try testing.expect((try result_get_or_null(&c2)).ok == .Null);
    var c3 = ctxWith(&success, noop.host(), cap.output(), a);
    try testing.expect((try result_exception_or_null(&c3)).ok == .Null);
    var c4 = ctxWith(&failure, noop.host(), cap.output(), a);
    try testing.expectEqual(@as(i32, 9), (try result_exception_or_null(&c4)).ok.Int);
}

test "getOrThrow returns success and rethrows failure" {
    var noop = NoopHost.init(testing.allocator);
    defer noop.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ok_payload: Value = .{ .Int = 3 };
    var err_payload: Value = .{ .Int = 4 };
    const success = [_]Value{.{ .Result = .{ .ok = true, .payload = &ok_payload } }};
    const failure = [_]Value{.{ .Result = .{ .ok = false, .payload = &err_payload } }};

    var c1 = ctxWith(&success, noop.host(), cap.output(), a);
    try testing.expectEqual(@as(i32, 3), (try result_get_or_throw(&c1)).ok.Int);
    var c2 = ctxWith(&failure, noop.host(), cap.output(), a);
    const r = try result_get_or_throw(&c2);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Thrown);
    try testing.expectEqual(@as(i32, 4), r.err.Thrown.Int);
}

test "getOrDefault falls back on failure and requires a default" {
    var noop = NoopHost.init(testing.allocator);
    defer noop.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ok_payload: Value = .{ .Int = 1 };
    var err_payload: Value = .{ .Int = 2 };
    const success = [_]Value{ .{ .Result = .{ .ok = true, .payload = &ok_payload } }, .{ .Int = 99 } };
    const failure = [_]Value{ .{ .Result = .{ .ok = false, .payload = &err_payload } }, .{ .Int = 99 } };
    const no_default = [_]Value{.{ .Result = .{ .ok = false, .payload = &err_payload } }};

    var c1 = ctxWith(&success, noop.host(), cap.output(), a);
    try testing.expectEqual(@as(i32, 1), (try result_get_or_default(&c1)).ok.Int);
    var c2 = ctxWith(&failure, noop.host(), cap.output(), a);
    try testing.expectEqual(@as(i32, 99), (try result_get_or_default(&c2)).ok.Int);
    var c3 = ctxWith(&no_default, noop.host(), cap.output(), a);
    const r = try result_get_or_default(&c3);
    try testing.expect(r == .err and r.err == .Arity);
}

test "non-Result receiver is a type error" {
    var noop = NoopHost.init(testing.allocator);
    defer noop.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const bad = [_]Value{.{ .Int = 1 }};
    var ctx = ctxWith(&bad, noop.host(), cap.output(), arena.allocator());
    const r = try result_is_success(&ctx);
    try testing.expect(r == .err and r.err == .Type);
}

test "result_to_string renders Success/Failure" {
    var noop = NoopHost.init(testing.allocator);
    defer noop.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var payload: Value = .{ .Int = 42 };
    const success = [_]Value{.{ .Result = .{ .ok = true, .payload = &payload } }};
    const failure = [_]Value{.{ .Result = .{ .ok = false, .payload = &payload } }};

    var c1 = ctxWith(&success, noop.host(), cap.output(), a);
    const s1 = (try result_to_string(&c1)).ok;
    {
        const g = s1.String.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("Success(42)", g.get().*);
    }
    var c2 = ctxWith(&failure, noop.host(), cap.output(), a);
    const s2 = (try result_to_string(&c2)).ok;
    {
        const g = s2.String.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("Failure(42)", g.get().*);
    }
}

test "runCatching wraps a returned value and a thrown one" {
    var stub = StubHost.init(testing.allocator);
    defer stub.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Block returns a value -> Success(value).
    stub.reply = .{ .ok = .{ .Int = 11 } };
    const args = [_]Value{Value.Unit};
    var c1 = ctxWith(&args, stub.host(), cap.output(), a);
    const r1 = try result_run_catching(&c1);
    try testing.expect(r1.ok.Result.ok);
    try testing.expectEqual(@as(i32, 11), r1.ok.Result.payload.Int);

    // Block throws -> Failure(thrown).
    stub.reply = .{ .err = .{ .Thrown = .{ .Int = 13 } } };
    var c2 = ctxWith(&args, stub.host(), cap.output(), a);
    const r2 = try result_run_catching(&c2);
    try testing.expect(!r2.ok.Result.ok);
    try testing.expectEqual(@as(i32, 13), r2.ok.Result.payload.Int);

    // A non-Thrown runtime error propagates unchanged.
    stub.reply = .{ .err = .{ .Type = "boom" } };
    var c3 = ctxWith(&args, stub.host(), cap.output(), a);
    const r3 = try result_run_catching(&c3);
    try testing.expect(r3 == .err and r3.err == .Type);
}

test "runCatching with a receiver binds this" {
    var stub = StubHost.init(testing.allocator);
    defer stub.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    stub.reply = .{ .ok = .{ .Int = 1 } };
    const args = [_]Value{ .{ .Int = 5 }, Value.Unit };
    var ctx = ctxWith(&args, stub.host(), cap.output(), arena.allocator());
    const r = try result_run_catching(&ctx);
    try testing.expect(r.ok.Result.ok);
    try testing.expect(stub.last_this != null);
    try testing.expectEqual(@as(i32, 5), stub.last_this.?.Int);
}

test "result_map maps success, passes failure through, mapCatching catches throws" {
    var stub = StubHost.init(testing.allocator);
    defer stub.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ok_payload: Value = .{ .Int = 2 };
    var err_payload: Value = .{ .Int = 7 };
    const success = [_]Value{ .{ .Result = .{ .ok = true, .payload = &ok_payload } }, Value.Unit };
    const failure = [_]Value{ .{ .Result = .{ .ok = false, .payload = &err_payload } }, Value.Unit };

    stub.reply = .{ .ok = .{ .Int = 100 } };
    var c1 = ctxWith(&success, stub.host(), cap.output(), a);
    const r1 = try result_map(&c1);
    try testing.expect(r1.ok.Result.ok);
    try testing.expectEqual(@as(i32, 100), r1.ok.Result.payload.Int);
    try testing.expectEqual(@as(i32, 2), stub.last_arg.?.Int);

    // map on a failure does not invoke the block.
    stub.invoked = 0;
    var c2 = ctxWith(&failure, stub.host(), cap.output(), a);
    const r2 = try result_map(&c2);
    try testing.expect(!r2.ok.Result.ok);
    try testing.expectEqual(@as(i32, 7), r2.ok.Result.payload.Int);
    try testing.expectEqual(@as(usize, 0), stub.invoked);

    // mapCatching turns a thrown block into a Failure.
    stub.reply = .{ .err = .{ .Thrown = .{ .Int = 55 } } };
    var c3 = ctxWith(&success, stub.host(), cap.output(), a);
    const r3 = try result_map_catching(&c3);
    try testing.expect(!r3.ok.Result.ok);
    try testing.expectEqual(@as(i32, 55), r3.ok.Result.payload.Int);
}

test "result_fold dispatches to onSuccess or onFailure" {
    var stub = StubHost.init(testing.allocator);
    defer stub.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ok_payload: Value = .{ .Int = 21 };
    var err_payload: Value = .{ .Int = 31 };
    // (receiver, onSuccess, onFailure)
    const success = [_]Value{ .{ .Result = .{ .ok = true, .payload = &ok_payload } }, Value.Unit, Value.Unit };
    const failure = [_]Value{ .{ .Result = .{ .ok = false, .payload = &err_payload } }, Value.Unit, Value.Unit };

    stub.reply = .{ .ok = .{ .Int = 0 } };
    var c1 = ctxWith(&success, stub.host(), cap.output(), a);
    _ = try result_fold(&c1);
    try testing.expectEqual(@as(i32, 21), stub.last_arg.?.Int);

    var c2 = ctxWith(&failure, stub.host(), cap.output(), a);
    _ = try result_fold(&c2);
    try testing.expectEqual(@as(i32, 31), stub.last_arg.?.Int);
}

test "onSuccess / onFailure run the side effect then return the receiver" {
    var stub = StubHost.init(testing.allocator);
    defer stub.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ok_payload: Value = .{ .Int = 8 };
    const success = [_]Value{ .{ .Result = .{ .ok = true, .payload = &ok_payload } }, Value.Unit };

    stub.reply = .{ .ok = Value.Unit };
    stub.invoked = 0;
    var c1 = ctxWith(&success, stub.host(), cap.output(), a);
    const r1 = try result_on_success(&c1);
    try testing.expect(r1.ok == .Result and r1.ok.Result.ok);
    try testing.expectEqual(@as(usize, 1), stub.invoked);

    // onFailure on a success does not invoke the block, returns receiver.
    stub.invoked = 0;
    var c2 = ctxWith(&success, stub.host(), cap.output(), a);
    const r2 = try result_on_failure(&c2);
    try testing.expect(r2.ok == .Result);
    try testing.expectEqual(@as(usize, 0), stub.invoked);
}

test "getOrElse returns success or calls onFailure" {
    var stub = StubHost.init(testing.allocator);
    defer stub.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var ok_payload: Value = .{ .Int = 6 };
    var err_payload: Value = .{ .Int = 9 };
    const success = [_]Value{ .{ .Result = .{ .ok = true, .payload = &ok_payload } }, Value.Unit };
    const failure = [_]Value{ .{ .Result = .{ .ok = false, .payload = &err_payload } }, Value.Unit };

    var c1 = ctxWith(&success, stub.host(), cap.output(), a);
    try testing.expectEqual(@as(i32, 6), (try result_get_or_else(&c1)).ok.Int);

    stub.reply = .{ .ok = .{ .Int = 77 } };
    var c2 = ctxWith(&failure, stub.host(), cap.output(), a);
    const r2 = try result_get_or_else(&c2);
    try testing.expectEqual(@as(i32, 77), r2.ok.Int);
    try testing.expectEqual(@as(i32, 9), stub.last_arg.?.Int);
}

test "coroutine_suspended_sentinel and coro_new_slot" {
    var noop = NoopHost.init(testing.allocator);
    defer noop.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var c1 = ctxWith(&.{}, noop.host(), cap.output(), a);
    try testing.expect((try coroutine_suspended_sentinel(&c1)).ok == .CoroutineSuspended);

    var c2 = ctxWith(&.{}, noop.host(), cap.output(), a);
    const first = (try coro_new_slot(&c2)).ok.Long;
    var c3 = ctxWith(&.{}, noop.host(), cap.output(), a);
    const second = (try coro_new_slot(&c3)).ok.Long;
    try testing.expect(second == first + 1);
}

test "coro_park suspends and rejects a non-Long slot" {
    var noop = NoopHost.init(testing.allocator);
    defer noop.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ok_args = [_]Value{.{ .Long = 4 }};
    var c1 = ctxWith(&ok_args, noop.host(), cap.output(), a);
    const r1 = try coro_park(&c1);
    try testing.expect(r1 == .err and r1.err == .Suspend);
    try testing.expectEqual(@as(i64, -1), r1.err.Suspend);

    const bad_args = [_]Value{Value.Unit};
    var c2 = ctxWith(&bad_args, noop.host(), cap.output(), a);
    const r2 = try coro_park(&c2);
    try testing.expect(r2 == .err and r2.err == .Type);
}

test "coro_arm_slot / coro_disarm_slot return Unit" {
    var noop = NoopHost.init(testing.allocator);
    defer noop.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const arm = [_]Value{.{ .Long = 1 }};
    var c1 = ctxWith(&arm, noop.host(), cap.output(), a);
    try testing.expect((try coro_arm_slot(&c1)).ok == .Unit);

    var c2 = ctxWith(&.{}, noop.host(), cap.output(), a);
    try testing.expect((try coro_disarm_slot(&c2)).ok == .Unit);
}

test "coro_run_root requires a block" {
    var noop = NoopHost.init(testing.allocator);
    defer noop.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var ctx = ctxWith(&.{}, noop.host(), cap.output(), arena.allocator());
    const r = try coro_run_root(&ctx);
    try testing.expect(r == .err and r.err == .Type);
}
