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
    // As `until`: the name is shared with library extensions on non-integral
    // types, so a shape this builtin cannot serve declines rather than fails.
    const pair = pairIntArgs(ctx, "downTo") orelse
        return .{ .err = .{ .Unimplemented = "Vm::downTo non-integral operands" } };
    return ok(try Value.newRange(ctx.allocator, .{
        .start = pair[0],
        .end = pair[1],
        .step = -1,
        .kind = rangeKindForArgs(ctx.args[0], ctx.args[1]),
        .progression = true,
    }));
}

/// `Int.rangeTo` / `Long.rangeTo` / `Char.rangeTo` called by name
/// (`0.rangeTo(2)`): the same value the `..` operator builds. Without a
/// builtin the explicit call fell through to the generic
/// `Comparable<T>.rangeTo` extension, whose `ComparableRange` has no
/// iterator. Non-integral operands are not ours.
pub fn ranges_range_to(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const pair = pairIntArgs(ctx, "rangeTo") orelse
        return .{ .err = .{ .Unimplemented = "Vm::rangeTo non-integral operands" } };
    return ok(try Value.newRange(ctx.allocator, .{
        .start = pair[0],
        .end = pair[1],
        .step = 1,
        .kind = rangeKindForArgs(ctx.args[0], ctx.args[1]),
    }));
}
/// `Int.rangeUntil` by name is `until`.
pub fn ranges_range_until(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return ranges_until(ctx);
}
pub fn ranges_until(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    // `until` is the integral range builtin, but the name is shared by user
    // extensions (e.g. `LocalDate.until(other, unit)`). Non-integral operands
    // are not ours: yield `Unimplemented` so dispatch falls back to the user
    // extension rather than hard-failing with a type error.
    const pair = pairIntArgs(ctx, "until") orelse
        return .{ .err = .{ .Unimplemented = "Vm::until non-integral operands" } };
    const kind = rangeKindForArgs(ctx.args[0], ctx.args[1]);
    // `a until MIN_VALUE` is empty: Kotlin returns the type's EMPTY range rather
    // than wrapping `to - 1` below MIN.
    if (kind.untilEmpty(pair[1])) {
        const e = kind.emptyBounds();
        return ok(try Value.newRange(ctx.allocator, .{ .start = e[0], .end = e[1], .step = 1, .kind = kind }));
    }
    return ok(try Value.newRange(ctx.allocator, .{
        .start = pair[0],
        .end = saturatingSub(pair[1], 1),
        .step = 1,
        .kind = kind,
    }));
}

pub fn ranges_step(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    // Either range representation serves as the receiver: the host
    // `Value.Range` and the `Value.Instance` an upstream
    // `LongProgression.fromClosedRange` builds carry the same triple.
    if (ctx.args.len == 2 and ctx.args[1].isIntegral()) {
        if (asRangeView(&ctx.args[0])) |r| {
        const n = ctx.args[1].asI64().?;
        if (n <= 0) {
            const msg = try std.fmt.allocPrint(ctx.allocator, "Step must be positive, was: {d}.", .{n});
            return .{ .err = .{ .Thrown = try Value.newException(ctx.allocator, .{
                .fqn = try runtime.strInit(ctx.allocator, "kotlin.IllegalArgumentException"),
                .message = .from(try runtime.strInitOwned(ctx.allocator, msg)),
                .cause = null,
            }) } };
        }
        const signed = if (r.step < 0) -n else n;
        const normalized_end = normalizeProgressionEnd(r.start, r.end, signed, r.kind);
        return ok(try Value.newRange(ctx.allocator, .{
            .start = r.start,
            .end = normalized_end,
            .step = signed,
            .kind = r.kind,
            .progression = true,
        }));
        }
    }
    // Not the integral builtin's shape (a progression INSTANCE receiver, a
    // non-integral step): decline so dispatch reaches the library extension
    // of the same name rather than hard-failing here.
    return .{ .err = .{ .Unimplemented = "Vm::step non-integral operands" } };
}

/// Match Kotlin's `IntProgression.fromClosedRange`: the stored `end` is the
/// last element that's actually reachable from `start` with the given
/// `step`. For `1..10 step 2` this normalizes 10 -> 9 because 9 is the last
/// reachable value.
pub fn normalizeProgressionEnd(start: i64, end: i64, step: i64, kind: RangeKind) i64 {
    if (step == 0) return end;
    // Kotlin getProgressionLastElement: when `start` is already past `end` (an
    // empty/one-element progression, unsigned for ULong), the closed-range bound
    // stays as `last`.
    if (!kind.inBounds(start, end, step)) return end;
    if (step > 0) {
        return end - @rem(end - start, step);
    } else {
        return end + @rem(start - end, -step);
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
    /// Mirrors `Value.Range.progression`; an `Instance`-backed view of a
    /// `*Progression` class is always a progression.
    progression: bool = false,
};

const InstanceRangeType = struct {
    kind: RangeKind,
    progression: bool,
};

fn instanceRangeType(fqn: []const u8) ?InstanceRangeType {
    const entries = [_]struct { []const u8, RangeKind, bool }{
        .{ "kotlin.ranges.IntRange", .Int, false },
        .{ "kotlin.ranges.LongRange", .Long, false },
        .{ "kotlin.ranges.CharRange", .Char, false },
        .{ "kotlin.ranges.UIntRange", .UInt, false },
        .{ "kotlin.ranges.ULongRange", .ULong, false },
        .{ "kotlin.ranges.IntProgression", .Int, true },
        .{ "kotlin.ranges.LongProgression", .Long, true },
        .{ "kotlin.ranges.CharProgression", .Char, true },
        .{ "kotlin.ranges.UIntProgression", .UInt, true },
        .{ "kotlin.ranges.ULongProgression", .ULong, true },
    };
    for (entries) |entry| {
        if (std.mem.eql(u8, fqn, entry[0])) {
            return .{ .kind = entry[1], .progression = entry[2] };
        }
    }
    return null;
}

pub fn asRangeView(v: *const Value) ?RangeView {
    switch (v.*) {
        .Range => |r| return .{ .start = r.start, .end = r.end, .step = r.step, .kind = r.kind, .progression = r.progression },
        .Instance => |inst| {
            const b = inst.borrow();
            defer b.deinit();
            const data = b.get();
            const cg = data.class.borrow();
            defer cg.deinit();
            const fqn = cg.get().fqn;
            const range_type = instanceRangeType(fqn) orelse return null;
            // IntProgression stores first/last/step; IntRange also exposes
            // start/endInclusive -- accept whichever the lowered fields carry.
            const start = num(data, &.{ "first", "start" }) orelse return null;
            const end = num(data, &.{ "last", "endInclusive" }) orelse return null;
            const step = num(data, &.{"step"}) orelse 1;
            return .{
                .start = start,
                .end = end,
                .step = step,
                .kind = range_type.kind,
                .progression = range_type.progression,
            };
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

fn rangeViewEmpty(view: RangeView) bool {
    // Empty when `start` is already past `end` in the step direction (unsigned
    // for ULong, so `MaxUL..MinUL` is empty rather than a wrapped range).
    return !view.kind.inBounds(view.start, view.end, view.step);
}

fn throwNoSuchElement(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return .{ .err = .{ .Thrown = try Value.newException(ctx.allocator, .{
        .fqn = try runtime.strInit(ctx.allocator, "kotlin.NoSuchElementException"),
        .message = .{},
        .cause = null,
    }) } };
}

/// `IntProgression.first()` / `last()` (the iterable extensions, not the
/// `start`/`endInclusive` bound properties) throw on an empty progression.
/// The `Iterable.first()`/`last()` *functions* (a call): throw on an empty
/// range. The `Progression.first`/`.last` property *reads* (non-throwing) are
/// served ahead of this in the field-access path.
pub fn range_first(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "first") orelse return typeErr("first requires a Range receiver");
    if (rangeViewEmpty(view)) return throwNoSuchElement(ctx);
    return ok(rangeEndpoint(view.kind, view.start));
}

pub fn range_last(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "last") orelse return typeErr("last requires a Range receiver");
    if (rangeViewEmpty(view)) return throwNoSuchElement(ctx);
    return ok(rangeEndpoint(view.kind, view.end));
}

/// `ClosedRange.start` / `endInclusive` return the stored bound even for an
/// empty range (unlike `first()`/`last()`).
pub fn range_start(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "start") orelse return typeErr("start requires a Range receiver");
    return ok(rangeEndpoint(view.kind, view.start));
}

pub fn range_end_inclusive(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "endInclusive") orelse return typeErr("endInclusive requires a Range receiver");
    return ok(rangeEndpoint(view.kind, view.end));
}

pub fn range_step_field(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "step") orelse return typeErr("step requires a Range receiver");
    // A progression's `step` is always `Int` (Int/Char/UInt progressions) or
    // `Long` (Long/ULong progressions) — never the element type — and keeps its
    // sign (negative for a `downTo`).
    return ok(switch (view.kind) {
        .Long, .ULong => Value{ .Long = view.step },
        .Int, .Char, .UInt => Value.newInt(view.step),
    });
}

fn rangeKindMax(kind: RangeKind) i64 {
    return switch (kind) {
        .Int => std.math.maxInt(i32),
        .Long => std.math.maxInt(i64),
        .Char => std.math.maxInt(u16),
        .UInt => std.math.maxInt(u32),
        .ULong => @bitCast(@as(u64, std.math.maxInt(u64))),
    };
}

/// `OpenEndRange.endExclusive` — one past the last element. A `..<` range is
/// stored as the closed `start..(end-1)`, so the exclusive bound is `end + 1`.
/// When `endInclusive` is the element type's MAX value the exclusive bound is
/// unrepresentable, so the access throws (matching the stdlib).
pub fn range_end_exclusive(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "endExclusive") orelse return typeErr("endExclusive requires a Range receiver");
    if (view.end == rangeKindMax(view.kind)) {
        return .{ .err = .{ .Thrown = try Value.newException(ctx.allocator, .{
            .fqn = try runtime.strInit(ctx.allocator, "kotlin.IllegalStateException"),
            .message = .from(try runtime.strInitOwned(ctx.allocator, try ctx.allocator.dupe(u8, "Cannot return the exclusive upper bound of a range that includes MAX_VALUE."))),
            .cause = null,
        }) } };
    }
    return ok(rangeEndpoint(view.kind, view.end + 1));
}

pub fn range_to_string(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "toString") orelse return typeErr("toString requires a Range receiver");
    const r = try Value.newRange(ctx.allocator, .{
        .start = view.start,
        .end = view.end,
        .step = view.step,
        .kind = view.kind,
        .progression = view.progression,
    });
    defer runtime.rangeRefOf(r.Range).deinit();
    const s = try r.display(ctx.allocator);
    return ok(.{ .String = try runtime.strInitOwned(ctx.allocator, s) });
}

pub fn range_contains(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "contains") orelse return typeErr("contains requires a Range receiver");
    const n: i64 = blk: {
        if (ctx.args.len > 1) {
            if (ctx.args[1].asI64()) |v| break :blk v;
            // A Char range takes a Char (`'b' in 'a'..'c'` and
            // `('a'..'c').contains('b')` are the same call).
            if (ctx.args[1] == .Char) break :blk @as(i64, ctx.args[1].Char);
        }
        return typeErr("Range.contains requires an Int argument");
    };
    const lo = if (view.step > 0) view.start else view.end;
    const hi = if (view.step > 0) view.end else view.start;
    // ULong bounds span the full u64 range stored as i64, so test unsigned.
    const in_bounds = if (view.kind == .ULong) blk2: {
        const un: u64 = @bitCast(n);
        break :blk2 un >= @as(u64, @bitCast(lo)) and un <= @as(u64, @bitCast(hi));
    } else (n >= lo and n <= hi);
    if (!in_bounds) {
        return ok(.{ .Bool = false });
    }
    const s = intAbs(view.step);
    return ok(.{ .Bool = intAbs(@rem(n - view.start, s)) == 0 or s == 1 });
}

pub fn range_is_empty(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "isEmpty") orelse return typeErr("isEmpty requires a Range receiver");
    // `rangeViewEmpty` compares unsigned for ULong, so `ULongRange.EMPTY`
    // (`MaxUL..MinUL`) reads as empty.
    return ok(.{ .Bool = rangeViewEmpty(view) });
}

pub fn range_reversed(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "reversed") orelse return typeErr("reversed requires a Range receiver");
    return ok(try Value.newRange(ctx.allocator, .{
        .start = view.end,
        .end = view.start,
        .step = -view.step,
        .kind = view.kind,
        .progression = true,
    }));
}

pub fn range_to_list(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const view = rangeViewArg(ctx, "toList") orelse return typeErr("toList requires a Range receiver");
    var items = try ValueList.init(ctx.allocator, .empty);
    {
        const g = items.borrowMut();
        defer g.deinit();
        var it = rangeIterInt(view.start, view.end, view.step, view.kind);
        while (it.next()) |v| {
            try g.get().append(ctx.allocator, rangeEndpoint(view.kind, v));
        }
    }
    return ok(try makeList(items, false));
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
    var it = rangeIterInt(view.start, view.end, view.step, view.kind);
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
// Local helpers.
// ============================================================

fn makeList(items: ValueList, mutable: bool) std.mem.Allocator.Error!Value {
    return try Value.newList(items.cell.allocator, .{
        .items = items,
        .mutable = mutable,
        .enum_entries = false,
        .backing = null,
    });
}

/// Lazy iterator over an inclusive integer progression with a signed step.
/// Empty when `step == 0` or the bounds are crossed; `cur` advances by a
/// saturating add.
const RangeIntIter = struct {
    cur: i64,
    end: i64,
    step: i64,
    kind: RangeKind,
    done: bool,

    fn next(self: *RangeIntIter) ?i64 {
        if (self.done or self.step == 0) return null;
        // `inBounds` compares unsigned for ULong (`MaxUL..MinUL` is empty).
        if (!self.kind.inBounds(self.cur, self.end, self.step)) {
            self.done = true;
            return null;
        }
        const v = self.cur;
        // `end` is the exact final element; stop once yielded so the cursor
        // never advances past it (Long.MAX overflow, or a ULong wrap past MaxUL).
        if (self.cur == self.end) {
            self.done = true;
            return v;
        }
        const adv = saturatingAdd(self.cur, self.step);
        if (adv == self.cur) self.done = true else self.cur = adv;
        return v;
    }
};

fn rangeIterInt(start: i64, end: i64, step: i64, kind: RangeKind) RangeIntIter {
    return .{ .cur = start, .end = end, .step = step, .kind = kind, .done = false };
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
    try testing.expectEqual(@as(i64, 9), normalizeProgressionEnd(1, 10, 2, .Int));
    // 1..10 step 3 -> 1,4,7,10 -> 10.
    try testing.expectEqual(@as(i64, 10), normalizeProgressionEnd(1, 10, 3, .Int));
    // exact multiple stays put.
    try testing.expectEqual(@as(i64, 9), normalizeProgressionEnd(1, 9, 2, .Int));
    // empty forward range keeps the closed-range bound (Kotlin
    // getProgressionLastElement: start >= end yields end).
    try testing.expectEqual(@as(i64, 1), normalizeProgressionEnd(5, 1, 2, .Int));
    // step == 0 returns end unchanged.
    try testing.expectEqual(@as(i64, 10), normalizeProgressionEnd(1, 10, 0, .Int));
    // 10 downTo 1 step 2 -> 10,8,6,4,2 -> 2.
    try testing.expectEqual(@as(i64, 2), normalizeProgressionEnd(10, 1, -2, .Int));
    // empty backward range keeps the closed-range bound (start <= end yields end).
    try testing.expectEqual(@as(i64, 5), normalizeProgressionEnd(1, 5, -2, .Int));
}

test "downTo builds a descending range" {
    const args = [_]Value{ .{ .Int = 10 }, .{ .Int = 1 } };
    var ctx = noopCtx(&args);
    const r = try ranges_down_to(&ctx);
    try testing.expect(r == .ok);
    defer runtime.rangeRefOf(r.ok.Range).deinit();
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
    defer runtime.rangeRefOf(r.ok.Range).deinit();
    try testing.expectEqual(@as(i64, 0), r.ok.Range.start);
    try testing.expectEqual(@as(i64, 4), r.ok.Range.end);
    try testing.expectEqual(@as(i64, 1), r.ok.Range.step);
}

test "step normalizes a range progression" {
    const range = try Value.newRange(testing.allocator, .{ .start = 1, .end = 10, .step = 1, .kind = .Int });
    defer runtime.rangeRefOf(range.Range).deinit();
    const args = [_]Value{ range, .{ .Int = 2 } };
    var ctx = noopCtx(&args);
    const r = try ranges_step(&ctx);
    try testing.expect(r == .ok);
    defer runtime.rangeRefOf(r.ok.Range).deinit();
    try testing.expectEqual(@as(i64, 1), r.ok.Range.start);
    try testing.expectEqual(@as(i64, 9), r.ok.Range.end);
    try testing.expectEqual(@as(i64, 2), r.ok.Range.step);
}

test "step preserves descending direction" {
    const range = try Value.newRange(testing.allocator, .{ .start = 10, .end = 1, .step = -1, .kind = .Int });
    defer runtime.rangeRefOf(range.Range).deinit();
    const args = [_]Value{ range, .{ .Int = 2 } };
    var ctx = noopCtx(&args);
    const r = try ranges_step(&ctx);
    try testing.expect(r == .ok);
    defer runtime.rangeRefOf(r.ok.Range).deinit();
    try testing.expectEqual(@as(i64, 10), r.ok.Range.start);
    try testing.expectEqual(@as(i64, 2), r.ok.Range.end);
    try testing.expectEqual(@as(i64, -2), r.ok.Range.step);
}

test "step throws on non-positive step" {
    const range = try Value.newRange(testing.allocator, .{ .start = 1, .end = 10, .step = 1, .kind = .Int });
    defer runtime.rangeRefOf(range.Range).deinit();
    const args = [_]Value{ range, .{ .Int = 0 } };
    var ctx = noopCtx(&args);
    const r = try ranges_step(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Thrown);
    const exc = r.err.Thrown.Exception;
    // The message cell owns its bytes and frees them on the final drop;
    // just borrow to assert, then drop the two refcounted handles.
    {
        const mg = exc.message.get().?.borrow();
        defer mg.deinit();
        try testing.expectEqualStrings("Step must be positive, was: 0.", mg.get().bytes);
    }
    {
        const fg = exc.fqn.borrow();
        defer fg.deinit();
        try testing.expectEqualStrings("kotlin.IllegalArgumentException", fg.get().bytes);
    }
    runtime.exceptionRefOf(exc).deinit();
}

test "first and last read range endpoints" {
    const range = try Value.newRange(testing.allocator, .{ .start = 3, .end = 7, .step = 1, .kind = .Int });
    defer runtime.rangeRefOf(range.Range).deinit();
    const args = [_]Value{range};
    var ctx = noopCtx(&args);
    const f = try range_first(&ctx);
    try testing.expectEqual(@as(i32, 3), f.ok.Int);
    const l = try range_last(&ctx);
    try testing.expectEqual(@as(i32, 7), l.ok.Int);
}

test "step field returns the signed step" {
    // `10 downTo 1 step 2` -> IntProgression.step is -2 (Kotlin keeps the sign).
    const range = try Value.newRange(testing.allocator, .{ .start = 10, .end = 1, .step = -2, .kind = .Int });
    defer runtime.rangeRefOf(range.Range).deinit();
    const args = [_]Value{range};
    var ctx = noopCtx(&args);
    const s = try range_step_field(&ctx);
    try testing.expectEqual(@as(i32, -2), s.ok.Int);
}

test "char range endpoints reinterpret as code units" {
    const range = try Value.newRange(testing.allocator, .{ .start = 'a', .end = 'e', .step = 1, .kind = .Char });
    defer runtime.rangeRefOf(range.Range).deinit();
    const args = [_]Value{range};
    var ctx = noopCtx(&args);
    const f = try range_first(&ctx);
    try testing.expectEqual(@as(u16, 'a'), f.ok.Char);
    const l = try range_last(&ctx);
    try testing.expectEqual(@as(u16, 'e'), l.ok.Char);
}

test "contains respects bounds and step" {
    const range = try Value.newRange(testing.allocator, .{ .start = 0, .end = 10, .step = 2, .kind = .Int });
    defer runtime.rangeRefOf(range.Range).deinit();
    var args = [_]Value{ range, .{ .Int = 4 } };
    var ctx = noopCtx(&args);
    try testing.expect((try range_contains(&ctx)).ok.Bool);
    args[1] = .{ .Int = 5 };
    try testing.expect(!(try range_contains(&ctx)).ok.Bool);
    args[1] = .{ .Int = 12 };
    try testing.expect(!(try range_contains(&ctx)).ok.Bool);
}

test "contains with unit step ignores remainder" {
    const range = try Value.newRange(testing.allocator, .{ .start = 1, .end = 5, .step = 1, .kind = .Int });
    defer runtime.rangeRefOf(range.Range).deinit();
    var args = [_]Value{ range, .{ .Int = 3 } };
    var ctx = noopCtx(&args);
    try testing.expect((try range_contains(&ctx)).ok.Bool);
}

test "is empty reflects direction" {
    const fwd = try Value.newRange(testing.allocator, .{ .start = 5, .end = 1, .step = 1, .kind = .Int });
    defer runtime.rangeRefOf(fwd.Range).deinit();
    var a1 = [_]Value{fwd};
    var c1 = noopCtx(&a1);
    try testing.expect((try range_is_empty(&c1)).ok.Bool);
    const bwd = try Value.newRange(testing.allocator, .{ .start = 1, .end = 5, .step = -1, .kind = .Int });
    defer runtime.rangeRefOf(bwd.Range).deinit();
    var a2 = [_]Value{bwd};
    var c2 = noopCtx(&a2);
    try testing.expect((try range_is_empty(&c2)).ok.Bool);
    const nonempty = try Value.newRange(testing.allocator, .{ .start = 1, .end = 5, .step = 1, .kind = .Int });
    defer runtime.rangeRefOf(nonempty.Range).deinit();
    var a3 = [_]Value{nonempty};
    var c3 = noopCtx(&a3);
    try testing.expect(!(try range_is_empty(&c3)).ok.Bool);
}

test "reversed flips bounds and step sign" {
    const range = try Value.newRange(testing.allocator, .{ .start = 1, .end = 10, .step = 2, .kind = .Int });
    defer runtime.rangeRefOf(range.Range).deinit();
    const args = [_]Value{range};
    var ctx = noopCtx(&args);
    const r = try range_reversed(&ctx);
    defer runtime.rangeRefOf(r.ok.Range).deinit();
    try testing.expectEqual(@as(i64, 10), r.ok.Range.start);
    try testing.expectEqual(@as(i64, 1), r.ok.Range.end);
    try testing.expectEqual(@as(i64, -2), r.ok.Range.step);
}

test "to list enumerates elements" {
    const range = try Value.newRange(testing.allocator, .{ .start = 1, .end = 5, .step = 2, .kind = .Int });
    defer runtime.rangeRefOf(range.Range).deinit();
    const args = [_]Value{range};
    var ctx = noopCtx(&args);
    const r = try range_to_list(&ctx);
    try testing.expect(r == .ok);
    // The ObjRef owns the backing ArrayList and frees it on the final drop.
    defer runtime.listRefOf(r.ok.List).deinit();
    const g = r.ok.List.items.borrow();
    defer g.deinit();
    const items = g.get().items;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(@as(i32, 1), items[0].Int);
    try testing.expectEqual(@as(i32, 3), items[1].Int);
    try testing.expectEqual(@as(i32, 5), items[2].Int);
}

test "count totals reachable elements" {
    const range = try Value.newRange(testing.allocator, .{ .start = 0, .end = 9, .step = 3, .kind = .Int });
    defer runtime.rangeRefOf(range.Range).deinit();
    const args = [_]Value{range};
    var ctx = noopCtx(&args);
    const r = try range_count(&ctx);
    try testing.expectEqual(@as(i32, 4), r.ok.Int);
}

test "sum adds elements with kind-aware result" {
    const range = try Value.newRange(testing.allocator, .{ .start = 1, .end = 5, .step = 1, .kind = .Int });
    defer runtime.rangeRefOf(range.Range).deinit();
    var a1 = [_]Value{range};
    var c1 = noopCtx(&a1);
    const r1 = try range_sum(&c1);
    try testing.expectEqual(@as(i32, 15), r1.ok.Int);

    const lrange = try Value.newRange(testing.allocator, .{ .start = 1, .end = 3, .step = 1, .kind = .Long });
    defer runtime.rangeRefOf(lrange.Range).deinit();
    var a2 = [_]Value{lrange};
    var c2 = noopCtx(&a2);
    const r2 = try range_sum(&c2);
    try testing.expectEqual(@as(i64, 6), r2.ok.Long);
}

test "to string renders the range form" {
    const range = try Value.newRange(testing.allocator, .{ .start = 1, .end = 10, .step = 2, .kind = .Int });
    defer runtime.rangeRefOf(range.Range).deinit();
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

test "instance range types exclude iterator implementation classes" {
    try testing.expectEqual(RangeKind.UInt, instanceRangeType("kotlin.ranges.UIntRange").?.kind);
    try testing.expect(instanceRangeType("kotlin.ranges.UIntProgression").?.progression);
    try testing.expect(instanceRangeType("kotlin.ranges.UIntProgressionIterator") == null);
}

test "range iter is empty when bounds cross" {
    var it = rangeIterInt(5, 1, 1, .Int);
    try testing.expect(it.next() == null);
    var it2 = rangeIterInt(1, 5, -1, .Int);
    try testing.expect(it2.next() == null);
    var it3 = rangeIterInt(1, 10, 0, .Int);
    try testing.expect(it3.next() == null);
}
