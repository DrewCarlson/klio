//! Native bindings for `androidx.compose.runtime`.
//!
//! Compose's compiler plugin normally synthesizes the `$composer` threading
//! and slot-table bookkeeping for every `@Composable` function. klio has no
//! compiler plugin: the interpreter maintains an implicit current-composer +
//! positional group-key stack (see `src/interp_ir/vm/compose.zig`) and the
//! klio-authored `klioMain` layer reimplements the composer / composition /
//! recomposer / snapshot-state engine in plain Kotlin.
//!
//! This module supplies the small set of host intrinsics that klioMain's
//! `expect`/`actual` actuals route to — operations the interpreter alone can
//! answer (object identity, a process-global id counter, a monotonic clock,
//! stderr logging). Everything else in the runtime is pure Kotlin.

const std = @import("std");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const Value = runtime.Value;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const HostBindings = stdlib.HostBindings;

const Error = std.mem.Allocator.Error;

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

const unit: Value = .{ .Unit = {} };

/// Process-global monotonic counters. The interpreter is single-threaded for
/// the synchronous composition core, but keep these atomic so the auxiliary
/// (coroutine-driven) recomposition phase stays correct under the worker pool.
var state_id_counter: std.atomic.Value(i64) = .init(0);
var mono_counter: std.atomic.Value(i64) = .init(0);

/// Build the registry of native bindings this crate supplies, mapping each
/// host symbol to its implementing intrinsic.
pub fn hostBindings(allocator: std.mem.Allocator) Error!HostBindings {
    var b = HostBindings.init(allocator);
    try b.register("androidx.compose.runtime.__compose_identityHashCode", identityHashCode);
    try b.register("androidx.compose.runtime.__compose_nextStateId", nextStateId);
    try b.register("androidx.compose.runtime.__compose_monotonicNanos", monotonicNanos);
    try b.register("androidx.compose.runtime.__compose_logError", logError);
    try b.register("androidx.compose.runtime.__compose_currentThreadId", currentThreadId);
    // The real androidx.compose.ui engine needs the same identity hash for its
    // node/coordinator caches; expose it under the ui package's own symbol.
    try b.register("androidx.compose.ui.internal.__composeui_identityHashCode", identityHashCode);
    return b;
}

/// `identityHashCode(instance: Any?): Int` — a stable per-object hash for the
/// JVM `System.identityHashCode`. Reference types use their address-stable
/// runtime identity; boxed scalars fall back to a value-derived hash (identity
/// hashing only needs stability + reasonable spread, not uniqueness).
fn identityHashCode(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return ok(Value.newInt(0));
    const v = ctx.args[0];
    switch (v) {
        .Null, .Unit => return ok(Value.newInt(0)),
        .Int => |i| return ok(Value.newInt(@as(i64, @as(i32, @truncate(i))))),
        .Long => |i| return ok(Value.newInt(@as(i64, @as(i32, @truncate(i))))),
        .Short => |i| return ok(Value.newInt(@intCast(i))),
        .Byte => |i| return ok(Value.newInt(@intCast(i))),
        .UInt => |i| return ok(Value.newInt(@as(i64, @as(i32, @bitCast(i))))),
        .Char => |c| return ok(Value.newInt(@intCast(c))),
        .Bool => |bb| return ok(Value.newInt(if (bb) 1231 else 1237)),
        else => {
            if (v.lockIdentity()) |id| {
                // Fold the 64-bit identity into a positive 31-bit hash.
                const h: i32 = @truncate(@as(i64, @bitCast(@as(u64, id) *% 0x9E3779B97F4A7C15)));
                return ok(Value.newInt(@as(i64, h & 0x7FFFFFFF)));
            }
            return ok(Value.newInt(0));
        },
    }
}

/// `__compose_nextStateId(): Long` — next value from a process-global counter.
/// Backs snapshot/state-record id allocation without exposing atomics to
/// klioMain.
fn nextStateId(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    const id = state_id_counter.fetchAdd(1, .monotonic) + 1;
    return ok(Value.newLong(id));
}

/// `__compose_monotonicNanos(): Long` — a strictly increasing time source for
/// the frame clock. Returns a counter rather than wall-clock so deterministic
/// tests stay reproducible; the recomposer only needs monotonicity.
fn monotonicNanos(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    const t = mono_counter.fetchAdd(1, .monotonic) + 1;
    return ok(Value.newLong(t));
}

/// `__compose_logError(message: String, error: Throwable?): Unit` — Compose's
/// internal error sink. Writes to stderr so it never pollutes program stdout.
/// `__compose_currentThreadId(): Long` — the calling OS thread's id. The snapshot
/// core keys its per-thread state on this.
fn currentThreadId(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    return ok(Value.newLong(@bitCast(@as(u64, std.Thread.getCurrentId()))));
}

fn logError(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len >= 1) {
        if (ctx.args[0] == .String) {
            const g = ctx.args[0].String.borrow();
            defer g.deinit();
            std.debug.print("compose: {s}\n", .{g.get().bytes});
        }
    }
    return ok(unit);
}

const testing = std.testing;

test "hostBindings registers every compose symbol" {
    var b = try hostBindings(testing.allocator);
    defer b.deinit();
    try testing.expect(b.resolve("androidx.compose.runtime.__compose_identityHashCode") != null);
    try testing.expect(b.resolve("androidx.compose.runtime.__compose_nextStateId") != null);
    try testing.expect(b.resolve("androidx.compose.runtime.__compose_monotonicNanos") != null);
    try testing.expect(b.resolve("androidx.compose.runtime.__compose_logError") != null);
    try testing.expect(b.resolve("androidx.compose.ui.internal.__composeui_identityHashCode") != null);
    try testing.expectEqual(@as(usize, 5), b.len());
}

test "nextStateId is strictly increasing" {
    state_id_counter.store(0, .monotonic);
    var host: TestHost = .{};
    var ctx = host.ctx(&.{});
    const a = (try nextStateId(&ctx)).ok.Long;
    const b2 = (try nextStateId(&ctx)).ok.Long;
    try testing.expect(b2 > a);
}

test "identityHashCode is stable for scalars and 0 for null" {
    var host: TestHost = .{};
    {
        var ctx = host.ctx(&.{Value.newInt(42)});
        const h1 = (try identityHashCode(&ctx)).ok.Int;
        const h2 = (try identityHashCode(&ctx)).ok.Int;
        try testing.expectEqual(h1, h2);
        try testing.expectEqual(@as(i64, 42), h1);
    }
    {
        var ctx = host.ctx(&.{.{ .Null = {} }});
        try testing.expectEqual(@as(i64, 0), (try identityHashCode(&ctx)).ok.Int);
    }
}

/// Minimal `CallCtx` builder for unit tests: the compose intrinsics never use
/// the host vtable, so a stub is sufficient.
const TestHost = struct {
    fn ctx(self: *TestHost, args: []const Value) CallCtx {
        _ = self;
        return .{
            .args = args,
            .out = undefined,
            .host = undefined,
            .allocator = testing.allocator,
        };
    }
};

test {
    testing.refAllDecls(@This());
}
