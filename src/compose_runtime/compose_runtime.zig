//! Native bindings for `androidx.compose.runtime`.
//!
//! Compose's compiler plugin normally synthesizes the `$composer` threading and
//! slot-table bookkeeping for every `@Composable` function. klio has no such
//! plugin: the interpreter maintains an implicit current-composer and
//! positional group-key stack (`src/interp_ir/vm/compose.zig`), and `klioMain`
//! reimplements the composer, composition, recomposer and snapshot-state engine
//! in plain Kotlin. This module supplies the host intrinsics those actuals route
//! to: object identity, an id counter, a monotonic clock and stderr logging.

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

var state_id_counter: std.atomic.Value(i64) = .init(0);
var mono_counter: std.atomic.Value(i64) = .init(0);

pub fn hostBindings(allocator: std.mem.Allocator) Error!HostBindings {
    var b = HostBindings.init(allocator);
    try b.register("androidx.compose.runtime.__compose_identityHashCode", identityHashCode);
    try b.register("androidx.compose.runtime.__compose_nextStateId", nextStateId);
    try b.register("androidx.compose.runtime.__compose_monotonicNanos", monotonicNanos);
    try b.register("androidx.compose.runtime.__compose_logError", logError);
    try b.register("androidx.compose.runtime.internal.__compose_currentThreadId", currentThreadId);
    try b.register("androidx.compose.ui.internal.__composeui_identityHashCode", identityHashCode);
    // Gap-buffer group-field accessors. Layout mirrors SlotTable.kt: 5 ints per
    // group (key, groupInfo, parentAnchor, size, dataAnchor).
    try b.register("androidx.compose.runtime.composer.gapbuffer.parentAnchor", gapParentAnchor);
    try b.register("androidx.compose.runtime.composer.gapbuffer.updateParentAnchor", gapUpdateParentAnchor);
    try b.register("androidx.compose.runtime.composer.gapbuffer.dataAnchor", gapDataAnchor);
    try b.register("androidx.compose.runtime.composer.gapbuffer.updateDataAnchor", gapUpdateDataAnchor);
    try b.register("androidx.compose.runtime.composer.gapbuffer.groupSize", gapGroupSize);
    try b.register("androidx.compose.runtime.composer.gapbuffer.hasObjectKey", gapHasObjectKey);
    try b.register("androidx.compose.runtime.composer.gapbuffer.countOneBits", gapCountOneBits);
    return b;
}

const group_fields_size: i64 = 5;
const parent_anchor_offset: i64 = 2;
const size_offset: i64 = 3;
const data_anchor_offset: i64 = 4;
const group_info_offset: i64 = 1;
const object_key_mask: i32 = 0x2000_0000;

fn asIndex(v: Value) ?i64 {
    return switch (v) {
        .Int => |i| @as(i64, i),
        .Long => |i| i,
        else => null,
    };
}

fn gapFieldGet(ctx: *CallCtx, offset: i64) Error!EvalResult {
    if (ctx.args.len < 2 or ctx.args[0] != .Array) return .{ .err = .{ .Type = "IntArray group-field read" } };
    const addr = asIndex(ctx.args[1]) orelse return .{ .err = .{ .Type = "IntArray group-field read" } };
    const idx = addr * group_fields_size + offset;
    const arr = ctx.args[0].Array;
    if (idx < 0 or @as(usize, @intCast(idx)) >= arr.len()) return .{ .err = .{ .Type = "IntArray group-field read" } };
    return ok(arr.get(@intCast(idx)));
}

fn gapFieldSet(ctx: *CallCtx, offset: i64) Error!EvalResult {
    if (ctx.args.len < 3 or ctx.args[0] != .Array) return .{ .err = .{ .Type = "IntArray group-field write" } };
    const addr = asIndex(ctx.args[1]) orelse return .{ .err = .{ .Type = "IntArray group-field write" } };
    const idx = addr * group_fields_size + offset;
    const arr = ctx.args[0].Array;
    if (idx < 0 or @as(usize, @intCast(idx)) >= arr.len()) return .{ .err = .{ .Type = "IntArray group-field write" } };
    arr.set(ctx.allocator, @intCast(idx), ctx.args[2]);
    return ok(unit);
}

fn gapParentAnchor(ctx: *CallCtx) Error!EvalResult {
    return gapFieldGet(ctx, parent_anchor_offset);
}

fn gapUpdateParentAnchor(ctx: *CallCtx) Error!EvalResult {
    return gapFieldSet(ctx, parent_anchor_offset);
}

fn gapDataAnchor(ctx: *CallCtx) Error!EvalResult {
    return gapFieldGet(ctx, data_anchor_offset);
}

fn gapUpdateDataAnchor(ctx: *CallCtx) Error!EvalResult {
    return gapFieldSet(ctx, data_anchor_offset);
}

fn gapGroupSize(ctx: *CallCtx) Error!EvalResult {
    return gapFieldGet(ctx, size_offset);
}

fn gapHasObjectKey(ctx: *CallCtx) Error!EvalResult {
    const r = try gapFieldGet(ctx, group_info_offset);
    if (r != .ok or r.ok != .Int) return .{ .err = .{ .Type = "IntArray group-field read" } };
    return ok(.{ .Bool = (r.ok.Int & object_key_mask) != 0 });
}

fn gapCountOneBits(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return .{ .err = .{ .Type = "countOneBits" } };
    const v = asIndex(ctx.args[0]) orelse return .{ .err = .{ .Type = "countOneBits" } };
    return ok(Value.newInt(@popCount(@as(u32, @bitCast(@as(i32, @truncate(v)))))));
}

/// A stable per-object hash, as JVM `System.identityHashCode`. A boxed scalar
/// falls back to a value-derived hash, identity hashing needing spread only.
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
                const h: i32 = @truncate(@as(i64, @bitCast(@as(u64, id) *% 0x9E3779B97F4A7C15)));
                return ok(Value.newInt(@as(i64, h & 0x7FFFFFFF)));
            }
            return ok(Value.newInt(0));
        },
    }
}

fn nextStateId(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    const id = state_id_counter.fetchAdd(1, .monotonic) + 1;
    return ok(Value.newLong(id));
}

/// A strictly increasing time source for the frame clock: a counter rather than
/// wall-clock, so deterministic tests stay reproducible.
fn monotonicNanos(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    const t = mono_counter.fetchAdd(1, .monotonic) + 1;
    return ok(Value.newLong(t));
}

/// The calling OS thread's id, which the snapshot core keys per-thread state on.
fn currentThreadId(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    return ok(Value.newLong(@bitCast(@as(u64, std.Thread.getCurrentId()))));
}

/// Compose's internal error sink, writing to stderr so it never pollutes program
/// stdout.
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
    try testing.expect(b.resolve("androidx.compose.runtime.internal.__compose_currentThreadId") != null);
    try testing.expect(b.resolve("androidx.compose.ui.internal.__composeui_identityHashCode") != null);
    try testing.expect(b.resolve("androidx.compose.runtime.composer.gapbuffer.parentAnchor") != null);
    try testing.expect(b.resolve("androidx.compose.runtime.composer.gapbuffer.updateDataAnchor") != null);
    try testing.expect(b.resolve("androidx.compose.runtime.composer.gapbuffer.countOneBits") != null);
    try testing.expectEqual(@as(usize, 13), b.len());
}

test "gap-buffer field accessors read and write the 5-int group layout" {
    var host: TestHost = .{};
    var backing = [_]Value{
        Value.newInt(11), Value.newInt(0x2000_0000), Value.newInt(-1), Value.newInt(4), Value.newInt(7),
        Value.newInt(22), Value.newInt(0),           Value.newInt(0),  Value.newInt(1), Value.newInt(9),
    };
    var list: std.ArrayList(Value) = .empty;
    try list.appendSlice(testing.allocator, &backing);
    const store = try runtime.ValueList.init(testing.allocator, list);
    defer store.deinit();
    const arr: Value = .{ .Array = runtime.ArrayData.boxed(store) };

    var ctx1 = host.ctx(&.{ arr, Value.newInt(1) });
    try testing.expectEqual(@as(i32, 1), (try gapGroupSize(&ctx1)).ok.Int);
    try testing.expectEqual(@as(i32, 9), (try gapDataAnchor(&ctx1)).ok.Int);
    var ctx0 = host.ctx(&.{ arr, Value.newInt(0) });
    try testing.expectEqual(@as(i32, -1), (try gapParentAnchor(&ctx0)).ok.Int);
    try testing.expect((try gapHasObjectKey(&ctx0)).ok.Bool);
    try testing.expect(!(try gapHasObjectKey(&ctx1)).ok.Bool);
    var ctx_set = host.ctx(&.{ arr, Value.newInt(1), Value.newInt(42) });
    _ = try gapUpdateParentAnchor(&ctx_set);
    try testing.expectEqual(@as(i32, 42), (try gapParentAnchor(&ctx1)).ok.Int);
    var ctx_pc = host.ctx(&.{Value.newInt(0x2000_0001)});
    try testing.expectEqual(@as(i32, 2), (try gapCountOneBits(&ctx_pc)).ok.Int);
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
