//! Range/progression stdlib intrinsics.
//!
//! Each intrinsic is a `fn(*CallCtx) !EvalResult`. For member access the
//! receiver is `args[0]`, with any further user arguments following.

const std = @import("std");
const runtime = @import("runtime");

const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const RangeKind = runtime.RangeKind;
const StringRef = runtime.StringRef;
const ValueList = runtime.ValueList;

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

fn typeErr(msg: []const u8) EvalResult {
    return .{ .err = .{ .Type = msg } };
}

/// The progression's element kind, derived from the operand types so a Long
/// `downTo`/`until` yields a `.Long` range (structurally equal to the matching
/// `..` range) rather than a default `.Int` one.
fn rangeKindForArgs(a: Value, b: Value) RangeKind {
    if (a == .Long or b == .Long) return .Long;
    if (a == .ULong or b == .ULong) return .ULong;
    if (a == .Char or b == .Char) return .Char;
    if (a == .UInt or a == .UByte or a == .UShort or
        b == .UInt or b == .UByte or b == .UShort) return .UInt;
    return .Int;
}

// ============================================================
// Range progressions
// ============================================================

pub fn ranges_down_to(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const pair = pairIntArgs(ctx, "downTo") orelse return typeErr("downTo requires two Int operands");
    return ok(.{ .Range = .{
        .start = pair[0],
        .end = pair[1],
        .step = -1,
        .kind = rangeKindForArgs(ctx.args[0], ctx.args[1]),
    } });
}

pub fn ranges_until(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const pair = pairIntArgs(ctx, "until") orelse return typeErr("until requires two Int operands");
    return ok(.{ .Range = .{
        .start = pair[0],
        .end = saturatingSub(pair[1], 1),
        .step = 1,
        .kind = rangeKindForArgs(ctx.args[0], ctx.args[1]),
    } });
}

pub fn ranges_step(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 2 and ctx.args[0] == .Range and ctx.args[1].isIntegral()) {
        const r = ctx.args[0].Range;
        const n = ctx.args[1].asI64().?;
        if (n <= 0) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "Step must be positive, was: {d}.", .{n});
            return .{ .err = .{ .Thrown = .{ .Exception = .{
                .fqn = try runtime.strInit(ctx.allocator, "kotlin.IllegalArgumentException"),
                .message = try runtime.strInitOwned(ctx.allocator, msg),
                .cause = null,
            } } } };
        }
        const signed = if (r.step < 0) -n else n;
        const normalized_end = normalizeProgressionEnd(r.start, r.end, signed);
        return ok(.{ .Range = .{
            .start = r.start,
            .end = normalized_end,
            .step = signed,
            .kind = r.kind,
        } });
    }
    return typeErr("step requires IntRange . step(Int)");
}

/// Match Kotlin's `IntProgression.fromClosedRange`: the stored `end` is the
/// last element that's actually reachable from `start` with the given
/// `step`. For `1..10 step 2` this normalizes 10 -> 9 because 9 is the last
/// reachable value.
pub fn normalizeProgressionEnd(start: i64, end: i64, step: i64) i64 {
    if (step == 0) {
        return end;
    }
    if (step > 0) {
        if (start > end) {
            return start - 1;
        }
        const diff = end - start;
        const rem = @rem(diff, step);
        return end - rem;
    } else {
        if (start < end) {
            return start + 1;
        }
        const diff = start - end;
        const mag = -step;
        const rem = @rem(diff, mag);
        return end + rem;
    }
}

fn argToI64(v: Value) ?i64 {
    if (v == .Char) return @as(i64, v.Char);
    return v.asI64();
}

fn pairIntArgs(ctx: *const CallCtx, what: []const u8) ?[2]i64 {
    _ = what;
    if (ctx.args.len != 2) return null;
    const a = argToI64(ctx.args[0]) orelse return null;
    const b = argToI64(ctx.args[1]) orelse return null;
    return .{ a, b };
}

// Int narrows the endpoint; Char reinterprets it as a UTF-16 code unit.
pub fn rangeEndpoint(kind: RangeKind, v: i64) Value {
    return switch (kind) {
        .Long => .{ .Long = v },
        .Int => .{ .Int = @truncate(v) },
        .Char => .{ .Char = @truncate(@as(u64, @bitCast(v))) },
        .UInt => .{ .UInt = @truncate(@as(u64, @bitCast(v))) },
        .ULong => .{ .ULong = @bitCast(v) },
    };
}

/// View a receiver as a range's `(start, end, step, kind)`.
///
/// klio represents a range two ways: the host `Value.Range`, and -- when the
/// upstream `kotlin.ranges.{Int,Long,Char}{Range,Progression}` constructor is
/// invoked as a class (e.g. `Array<T>.indices`'s getter does `IntRange(0,
/// lastIndex)`) -- a generic `Value.Instance` carrying the same `first`/`last`/
/// `step` fields. Range intrinsics accept either so an op like `reversed` works
/// regardless of which form a range value took, without a caller having to
/// normalize first.
pub const RangeView = struct {
    start: i64,
    end: i64,
    step: i64,
    kind: RangeKind,
};

pub fn asRangeView(v: *const Value) ?RangeView {
    switch (v.*) {
        .Range => |r| return .{ .start = r.start, .end = r.end, .step = r.step, .kind = r.kind },
        .Instance => |inst| {
            const b = inst.borrow();
            defer b.deinit();
            const data = b.get();
            const cg = data.class.borrow();
            defer cg.deinit();
            const fqn = cg.get().fqn;
            if (!std.mem.startsWith(u8, fqn, "kotlin.ranges.")) {
                return null;
            }
            const kind: RangeKind = if (std.mem.indexOf(u8, fqn, "Long") != null)
                .Long
            else if (std.mem.indexOf(u8, fqn, "Char") != null)
                .Char
            else if (std.mem.indexOf(u8, fqn, "Int") != null)
                .Int
            else
                return null;
            // IntProgression stores first/last/step; IntRange also exposes
            // start/endInclusive -- accept whichever the lowered fields carry.
            const start = num(data, &.{ "first", "start" }) orelse return null;
            const end = num(data, &.{ "last", "endInclusive" }) orelse return null;
            const step = num(data, &.{"step"}) orelse 1;
            return .{ .start = start, .end = end, .step = step, .kind = kind };
        },
        else => return null,
    }
}

fn num(data: *const runtime.InstanceData, names: []const []const u8) ?i64 {
    for (names) |n| {
        if (data.get(n)) |val| {
            if (val.asI64()) |i| return i;
            if (val == .Char) return @as(i64, val.Char);
        }
    }
    return null;
}

fn rangeViewArg(ctx: *const CallCtx, op: []const u8) ?RangeView {
    _ = op;
    if (ctx.args.len == 0) return null;
    return asRangeView(&ctx.args[0]);
}

pub fn range_first(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "first") orelse return typeErr("first requires a Range receiver");
    return ok(rangeEndpoint(view.kind, view.start));
}

pub fn range_last(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "last") orelse return typeErr("last requires a Range receiver");
    return ok(rangeEndpoint(view.kind, view.end));
}

pub fn range_step_field(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "step") orelse return typeErr("step requires a Range receiver");
    return ok(rangeEndpoint(view.kind, intAbs(view.step)));
}

/// `OpenEndRange.endExclusive` — one past the last element. A `..<` range is
/// stored as the closed `start..(end-1)`, so the exclusive bound is `end + 1`.
pub fn range_end_exclusive(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "endExclusive") orelse return typeErr("endExclusive requires a Range receiver");
    return ok(rangeEndpoint(view.kind, view.end + 1));
}

pub fn range_to_string(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "toString") orelse return typeErr("toString requires a Range receiver");
    const r = Value{ .Range = .{
        .start = view.start,
        .end = view.end,
        .step = view.step,
        .kind = view.kind,
    } };
    const s = try r.display(ctx.allocator);
    return ok(.{ .String = try runtime.strInitOwned(ctx.allocator, s) });
}

pub fn range_contains(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "contains") orelse return typeErr("contains requires a Range receiver");
    const n: i64 = blk: {
        if (ctx.args.len > 1) {
            if (ctx.args[1].asI64()) |v| break :blk v;
        }
        return typeErr("Range.contains requires an Int argument");
    };
    const lo = if (view.step > 0) view.start else view.end;
    const hi = if (view.step > 0) view.end else view.start;
    const in_bounds = n >= lo and n <= hi;
    if (!in_bounds) {
        return ok(.{ .Bool = false });
    }
    const s = intAbs(view.step);
    return ok(.{ .Bool = intAbs(@rem(n - view.start, s)) == 0 or s == 1 });
}

pub fn range_is_empty(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "isEmpty") orelse return typeErr("isEmpty requires a Range receiver");
    const empty = if (view.step > 0) view.start > view.end else view.start < view.end;
    return ok(.{ .Bool = empty });
}

pub fn range_reversed(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "reversed") orelse return typeErr("reversed requires a Range receiver");
    return ok(.{ .Range = .{
        .start = view.end,
        .end = view.start,
        .step = -view.step,
        .kind = view.kind,
    } });
}

pub fn range_to_list(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "toList") orelse return typeErr("toList requires a Range receiver");
    var items = try ValueList.init(ctx.allocator, .empty);
    {
        const g = items.borrowMut();
        defer g.deinit();
        var it = rangeIterInt(view.start, view.end, view.step);
        while (it.next()) |v| {
            try g.get().append(ctx.allocator, rangeEndpoint(view.kind, v));
        }
    }
    return ok(makeList(items, false));
}

// The element count is a Kotlin Int; range sizes never exceed i64::MAX.
pub fn range_count(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "count") orelse return typeErr("count requires a Range receiver");
    // O(1) element count: never iterate (a near-MAX range has billions of
    // elements). `(last - first) / step + 1`, clamped to 0 when empty.
    const n: i64 = if (view.step > 0)
        (if (view.start > view.end) 0 else @divFloor(view.end - view.start, view.step) + 1)
    else
        (if (view.start < view.end) 0 else @divFloor(view.start - view.end, -view.step) + 1);
    return ok(Value.newInt(n));
}

pub fn range_sum(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "sum") orelse return typeErr("sum requires a Range receiver");
    var s: i64 = 0;
    var it = rangeIterInt(view.start, view.end, view.step);
    while (it.next()) |v| {
        s +%= v;
    }
    return ok(switch (view.kind) {
        .Long => .{ .Long = s },
        .Int, .Char => Value.newInt(s),
        .UInt => .{ .UInt = @truncate(@as(u64, @bitCast(s))) },
        .ULong => .{ .ULong = @bitCast(s) },
    });
}

// ============================================================
// Local helpers re-exported by the Rust `super::` import.
// ============================================================

fn makeList(items: ValueList, mutable: bool) Value {
    return .{ .List = .{
        .items = items,
        .mutable = mutable,
        .enum_entries = false,
        .backing = null,
    } };
}

/// Lazy iterator over an inclusive integer progression with a signed step.
/// Mirrors the Rust `range_iter_int`: empty when `step == 0` or the bounds
/// are crossed; `cur` advances by a saturating add.
const RangeIntIter = struct {
    cur: i64,
    end: i64,
    step: i64,
    done: bool,

    fn next(self: *RangeIntIter) ?i64 {
        if (self.done or self.step == 0) return null;
        if (self.step > 0) {
            if (self.cur > self.end) {
                self.done = true;
                return null;
            }
        } else {
            if (self.cur < self.end) {
                self.done = true;
                return null;
            }
        }
        const v = self.cur;
        self.cur = saturatingAdd(self.cur, self.step);
        return v;
    }
};

fn rangeIterInt(start: i64, end: i64, step: i64) RangeIntIter {
    return .{ .cur = start, .end = end, .step = step, .done = false };
}

fn saturatingAdd(a: i64, b: i64) i64 {
    return a +| b;
}

fn saturatingSub(a: i64, b: i64) i64 {
    return a -| b;
}

fn intAbs(v: i64) i64 {
    return if (v < 0) -%v else v;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

fn noopCtx(args: []const Value) CallCtx {
    return .{
        .args = args,
        .out = undefined,
        .host = undefined,
        .allocator = testing.allocator,
    };
}

test "normalize progression end clamps to last reachable element" {
    // 1..10 step 2 -> last reachable is 9.
    try testing.expectEqual(@as(i64, 9), normalizeProgressionEnd(1, 10, 2));
    // 1..10 step 3 -> 1,4,7,10 -> 10.
    try testing.expectEqual(@as(i64, 10), normalizeProgressionEnd(1, 10, 3));
    // exact multiple stays put.
    try testing.expectEqual(@as(i64, 9), normalizeProgressionEnd(1, 9, 2));
    // empty forward range collapses to start-1.
    try testing.expectEqual(@as(i64, 4), normalizeProgressionEnd(5, 1, 2));
    // step == 0 returns end unchanged.
    try testing.expectEqual(@as(i64, 10), normalizeProgressionEnd(1, 10, 0));
    // 10 downTo 1 step 2 -> 10,8,6,4,2 -> 2.
    try testing.expectEqual(@as(i64, 2), normalizeProgressionEnd(10, 1, -2));
    // empty backward range collapses to start+1.
    try testing.expectEqual(@as(i64, 2), normalizeProgressionEnd(1, 5, -2));
}

test "downTo builds a descending range" {
    const args = [_]Value{ .{ .Int = 10 }, .{ .Int = 1 } };
    var ctx = noopCtx(&args);
    const r = try ranges_down_to(&ctx);
    try testing.expect(r == .ok);
    try testing.expectEqual(@as(i64, 10), r.ok.Range.start);
    try testing.expectEqual(@as(i64, 1), r.ok.Range.end);
    try testing.expectEqual(@as(i64, -1), r.ok.Range.step);
    try testing.expectEqual(RangeKind.Int, r.ok.Range.kind);
}

test "downTo rejects non-int operands" {
    const args = [_]Value{ .{ .Int = 10 }, .{ .Double = 1.0 } };
    var ctx = noopCtx(&args);
    const r = try ranges_down_to(&ctx);
    try testing.expect(r == .err);
}

test "until shrinks the inclusive end by one" {
    const args = [_]Value{ .{ .Int = 0 }, .{ .Int = 5 } };
    var ctx = noopCtx(&args);
    const r = try ranges_until(&ctx);
    try testing.expect(r == .ok);
    try testing.expectEqual(@as(i64, 0), r.ok.Range.start);
    try testing.expectEqual(@as(i64, 4), r.ok.Range.end);
    try testing.expectEqual(@as(i64, 1), r.ok.Range.step);
}

test "step normalizes a range progression" {
    const range = Value{ .Range = .{ .start = 1, .end = 10, .step = 1, .kind = .Int } };
    const args = [_]Value{ range, .{ .Int = 2 } };
    var ctx = noopCtx(&args);
    const r = try ranges_step(&ctx);
    try testing.expect(r == .ok);
    try testing.expectEqual(@as(i64, 1), r.ok.Range.start);
    try testing.expectEqual(@as(i64, 9), r.ok.Range.end);
    try testing.expectEqual(@as(i64, 2), r.ok.Range.step);
}

test "step preserves descending direction" {
    const range = Value{ .Range = .{ .start = 10, .end = 1, .step = -1, .kind = .Int } };
    const args = [_]Value{ range, .{ .Int = 2 } };
    var ctx = noopCtx(&args);
    const r = try ranges_step(&ctx);
    try testing.expect(r == .ok);
    try testing.expectEqual(@as(i64, 10), r.ok.Range.start);
    try testing.expectEqual(@as(i64, 2), r.ok.Range.end);
    try testing.expectEqual(@as(i64, -2), r.ok.Range.step);
}

test "step throws on non-positive step" {
    const range = Value{ .Range = .{ .start = 1, .end = 10, .step = 1, .kind = .Int } };
    const args = [_]Value{ range, .{ .Int = 0 } };
    var ctx = noopCtx(&args);
    const r = try ranges_step(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Thrown);
    const exc = r.err.Thrown.Exception;
    // The message cell owns its bytes and frees them on the final drop;
    // just borrow to assert, then drop the two refcounted handles.
    {
        const mg = exc.message.?.borrow();
        defer mg.deinit();
        try testing.expectEqualStrings("Step must be positive, was: 0.", mg.get().bytes);
    }
    {
        const fg = exc.fqn.borrow();
        defer fg.deinit();
        try testing.expectEqualStrings("kotlin.IllegalArgumentException", fg.get().bytes);
    }
    exc.message.?.deinit();
    exc.fqn.deinit();
}

test "first and last read range endpoints" {
    const range = Value{ .Range = .{ .start = 3, .end = 7, .step = 1, .kind = .Int } };
    const args = [_]Value{range};
    var ctx = noopCtx(&args);
    const f = try range_first(&ctx);
    try testing.expectEqual(@as(i32, 3), f.ok.Int);
    const l = try range_last(&ctx);
    try testing.expectEqual(@as(i32, 7), l.ok.Int);
}

test "step field returns the absolute step" {
    const range = Value{ .Range = .{ .start = 10, .end = 1, .step = -2, .kind = .Int } };
    const args = [_]Value{range};
    var ctx = noopCtx(&args);
    const s = try range_step_field(&ctx);
    try testing.expectEqual(@as(i32, 2), s.ok.Int);
}

test "char range endpoints reinterpret as code units" {
    const range = Value{ .Range = .{ .start = 'a', .end = 'e', .step = 1, .kind = .Char } };
    const args = [_]Value{range};
    var ctx = noopCtx(&args);
    const f = try range_first(&ctx);
    try testing.expectEqual(@as(u16, 'a'), f.ok.Char);
    const l = try range_last(&ctx);
    try testing.expectEqual(@as(u16, 'e'), l.ok.Char);
}

test "contains respects bounds and step" {
    const range = Value{ .Range = .{ .start = 0, .end = 10, .step = 2, .kind = .Int } };
    var args = [_]Value{ range, .{ .Int = 4 } };
    var ctx = noopCtx(&args);
    try testing.expect((try range_contains(&ctx)).ok.Bool);
    args[1] = .{ .Int = 5 };
    try testing.expect(!(try range_contains(&ctx)).ok.Bool);
    args[1] = .{ .Int = 12 };
    try testing.expect(!(try range_contains(&ctx)).ok.Bool);
}

test "contains with unit step ignores remainder" {
    const range = Value{ .Range = .{ .start = 1, .end = 5, .step = 1, .kind = .Int } };
    var args = [_]Value{ range, .{ .Int = 3 } };
    var ctx = noopCtx(&args);
    try testing.expect((try range_contains(&ctx)).ok.Bool);
}

test "is empty reflects direction" {
    const fwd = Value{ .Range = .{ .start = 5, .end = 1, .step = 1, .kind = .Int } };
    var a1 = [_]Value{fwd};
    var c1 = noopCtx(&a1);
    try testing.expect((try range_is_empty(&c1)).ok.Bool);
    const bwd = Value{ .Range = .{ .start = 1, .end = 5, .step = -1, .kind = .Int } };
    var a2 = [_]Value{bwd};
    var c2 = noopCtx(&a2);
    try testing.expect((try range_is_empty(&c2)).ok.Bool);
    const nonempty = Value{ .Range = .{ .start = 1, .end = 5, .step = 1, .kind = .Int } };
    var a3 = [_]Value{nonempty};
    var c3 = noopCtx(&a3);
    try testing.expect(!(try range_is_empty(&c3)).ok.Bool);
}

test "reversed flips bounds and step sign" {
    const range = Value{ .Range = .{ .start = 1, .end = 10, .step = 2, .kind = .Int } };
    const args = [_]Value{range};
    var ctx = noopCtx(&args);
    const r = try range_reversed(&ctx);
    try testing.expectEqual(@as(i64, 10), r.ok.Range.start);
    try testing.expectEqual(@as(i64, 1), r.ok.Range.end);
    try testing.expectEqual(@as(i64, -2), r.ok.Range.step);
}

test "to list enumerates elements" {
    const range = Value{ .Range = .{ .start = 1, .end = 5, .step = 2, .kind = .Int } };
    const args = [_]Value{range};
    var ctx = noopCtx(&args);
    const r = try range_to_list(&ctx);
    try testing.expect(r == .ok);
    // The ObjRef owns the backing ArrayList and frees it on the final drop.
    defer r.ok.List.items.deinit();
    const g = r.ok.List.items.borrow();
    defer g.deinit();
    const items = g.get().items;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(@as(i32, 1), items[0].Int);
    try testing.expectEqual(@as(i32, 3), items[1].Int);
    try testing.expectEqual(@as(i32, 5), items[2].Int);
}

test "count totals reachable elements" {
    const range = Value{ .Range = .{ .start = 0, .end = 9, .step = 3, .kind = .Int } };
    const args = [_]Value{range};
    var ctx = noopCtx(&args);
    const r = try range_count(&ctx);
    try testing.expectEqual(@as(i32, 4), r.ok.Int);
}

test "sum adds elements with kind-aware result" {
    const range = Value{ .Range = .{ .start = 1, .end = 5, .step = 1, .kind = .Int } };
    var a1 = [_]Value{range};
    var c1 = noopCtx(&a1);
    const r1 = try range_sum(&c1);
    try testing.expectEqual(@as(i32, 15), r1.ok.Int);

    const lrange = Value{ .Range = .{ .start = 1, .end = 3, .step = 1, .kind = .Long } };
    var a2 = [_]Value{lrange};
    var c2 = noopCtx(&a2);
    const r2 = try range_sum(&c2);
    try testing.expectEqual(@as(i64, 6), r2.ok.Long);
}

test "to string renders the range form" {
    const range = Value{ .Range = .{ .start = 1, .end = 10, .step = 2, .kind = .Int } };
    const args = [_]Value{range};
    var ctx = noopCtx(&args);
    const r = try range_to_string(&ctx);
    try testing.expect(r == .ok);
    const g = r.ok.String.borrow();
    defer {
        g.deinit();
        r.ok.String.deinit();
    }
    try testing.expectEqualStrings("1..10 step 2", g.get().bytes);
}

test "range view rejects a non-range receiver" {
    const v = Value{ .Int = 3 };
    try testing.expect(asRangeView(&v) == null);
}

test "range iter is empty when bounds cross" {
    var it = rangeIterInt(5, 1, 1);
    try testing.expect(it.next() == null);
    var it2 = rangeIterInt(1, 5, -1);
    try testing.expect(it2.next() == null);
    var it3 = rangeIterInt(1, 10, 0);
    try testing.expect(it3.next() == null);
}
