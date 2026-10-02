//! Comparison intrinsics: `compareValues`, the `Comparator` SAM factory and the
//! `naturalOrder` comparator factories. `compareBy` and `compareValuesBy` are the
//! library's own Kotlin, whose selectors run without leaving the interpreter.

const std = @import("std");
const runtime = @import("runtime");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const RuntimeError = runtime.RuntimeError;
const Value = runtime.Value;
const ComparatorStep = runtime.ComparatorStep;
const ObjRef = runtime.ObjRef;
const text = @import("../text.zig");

const CmpResult = union(enum) {
    ord: std.math.Order,
    err: RuntimeError,
};

/// Total order over doubles matching Kotlin's `Double.compareTo`: `-0.0 < 0.0`
/// and every NaN sorts above `+Infinity`.
fn kotlinFloatTotalCmp(a: f64, b: f64) std.math.Order {
    if (a < b) return .lt;
    if (a > b) return .gt;
    const bits = struct {
        fn of(x: f64) i64 {
            if (std.math.isNan(x)) return @bitCast(@as(u64, 0x7ff8_0000_0000_0000));
            return @bitCast(x);
        }
    };
    return std.math.order(bits.of(a), bits.of(b));
}

/// Kotlin's natural ordering: numerics by widened value, strings by UTF-16 code
/// unit, chars and booleans by ordinal. Any other pairing is not comparable.
fn compareValuesPure(a: *const Value, b: *const Value) CmpResult {
    if (a.isNumeric() and b.isNumeric()) {
        if (a.isIntegral() and b.isIntegral()) {
            if (a.isUnsigned() and b.isUnsigned()) {
                return .{ .ord = std.math.order(a.asU64().?, b.asU64().?) };
            }
            return .{ .ord = std.math.order(a.asI64().?, b.asI64().?) };
        }
        return .{ .ord = kotlinFloatTotalCmp(a.asF64().?, b.asF64().?) };
    }
    return switch (a.*) {
        .String => |x| switch (b.*) {
            .String => |y| blk: {
                const gx = x.borrow();
                defer gx.deinit();
                const gy = y.borrow();
                defer gy.deinit();
                break :blk .{ .ord = text.compareUtf16(gx.get().bytes, gy.get().bytes) };
            },
            else => notComparable(a, b),
        },
        .Char => |x| switch (b.*) {
            .Char => |y| .{ .ord = std.math.order(x, y) },
            else => notComparable(a, b),
        },
        .Bool => |x| switch (b.*) {
            .Bool => |y| .{ .ord = std.math.order(@intFromBool(x), @intFromBool(y)) },
            else => notComparable(a, b),
        },
        // Enum entries order by declaration ordinal, but only within one enum
        // class: entries of different enums have no common ordering.
        .Instance => |x| switch (b.*) {
            .Instance => |y| blk: {
                const gx = x.borrow();
                defer gx.deinit();
                const gy = y.borrow();
                defer gy.deinit();
                const cx = gx.get().class.borrow();
                defer cx.deinit();
                const cy = gy.get().class.borrow();
                defer cy.deinit();
                if (!cx.get().is_enum or !cy.get().is_enum) break :blk notComparable(a, b);
                if (!std.mem.eql(u8, cx.get().fqn, cy.get().fqn)) break :blk notComparable(a, b);
                const ox = gx.get().get("ordinal") orelse break :blk notComparable(a, b);
                const oy = gy.get().get("ordinal") orelse break :blk notComparable(a, b);
                const ix = ox.asI64() orelse break :blk notComparable(a, b);
                const iy = oy.asI64() orelse break :blk notComparable(a, b);
                break :blk .{ .ord = std.math.order(ix, iy) };
            },
            else => notComparable(a, b),
        },
        else => notComparable(a, b),
    };
}

/// Kotlin's natural ordering reaches any `Comparable`, so a library value type
/// dispatches its own `compareTo`. Tried only after the builtin table declines.
fn compareViaCompareTo(
    ctx: *CallCtx,
    a: *const Value,
    b: *const Value,
) std.mem.Allocator.Error!?CmpResult {
    if (a.* != .Instance) return null;
    const r = (try ctx.host.callWellKnown(a, .compare_to, &.{b.*}, ctx.out)) orelse return null;
    switch (r) {
        .ok => |v| {
            const n = v.asI64() orelse return null;
            return CmpResult{ .ord = if (n < 0) .lt else if (n > 0) .gt else .eq };
        },
        .err => |e| return CmpResult{ .err = e },
    }
}

fn compareValues(
    ctx: *CallCtx,
    a: *const Value,
    b: *const Value,
) std.mem.Allocator.Error!CmpResult {
    const builtin = compareValuesPure(a, b);
    if (builtin == .ord) return builtin;
    if (try compareViaCompareTo(ctx, a, b)) |r| return r;
    return builtin;
}

fn notComparable(a: *const Value, b: *const Value) CmpResult {
    const sa = a.display(std.heap.page_allocator) catch return .{ .err = .{ .Type = "values are not comparable" } };
    defer std.heap.page_allocator.free(sa);
    const sb = b.display(std.heap.page_allocator) catch return .{ .err = .{ .Type = "values are not comparable" } };
    defer std.heap.page_allocator.free(sb);
    const msg = std.fmt.allocPrint(std.heap.page_allocator, "values are not comparable: {s}, {s}", .{ sa, sb }) catch
        return .{ .err = .{ .Type = "values are not comparable" } };
    return .{ .err = .{ .Type = msg } };
}

fn isNull(v: Value) bool {
    return v == .Null;
}

/// Anything Kotlin can invoke as a key selector, often a property reference
/// rather than a lambda, since a `KProperty1<T, R>` is a `(T) -> R`. Mirrors
/// `interp_ir.valueIsCallable`, which the stdlib layer cannot import.
fn isCallable(v: Value) bool {
    return switch (v) {
        .IrClosure, .Intrinsic, .BoundMethod, .PropertyRef => true,
        .Instance => |inst| blk: {
            const g = inst.borrow();
            defer g.deinit();
            break :blk g.get().get("__bound_receiver__") != null;
        },
        else => false,
    };
}

fn orderToInt(o: std.math.Order) i64 {
    return switch (o) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

pub fn cmp_comparator_sam(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len != 1) {
        return .{ .err = .{ .Arity = "Comparator { … } expects a 2-arg comparison lambda" } };
    }
    const lam = ctx.args[0];
    if (!isCallable(lam)) {
        return .{ .err = .{ .Type = "Comparator { … } expects a 2-arg comparison lambda" } };
    }
    const steps = try ctx.allocator.alloc(ComparatorStep, 1);
    steps[0] = .{ .selector = lam, .descending = false };
    return .{ .ok = try Value.newComparator(ctx.allocator, .{
        .steps = try ObjRef([]ComparatorStep).init(ctx.allocator, steps),
        .descending = false,
    }) };
}

pub fn cmp_compare_values(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len != 2) {
        return .{ .err = .{ .Arity = "compareValues expects two arguments" } };
    }
    const a = ctx.args[0];
    const b = ctx.args[1];
    const n: i64 = if (isNull(a) and isNull(b))
        0
    else if (isNull(a))
        -1
    else if (isNull(b))
        1
    else if (compareToDifference(&a, &b)) |d|
        d
    else if (a == .Instance) blk: {
        // A `compareTo` of the program's own answers what it answers.
        if (try ctx.host.callWellKnown(&a, .compare_to, &.{b}, ctx.out)) |r| switch (r) {
            .ok => |v| if (v.asI64()) |x| break :blk x,
            .err => |e| return .{ .err = e },
        };
        break :blk switch (try compareValues(ctx, &a, &b)) {
            .ord => |o| orderToInt(o),
            .err => |e| return .{ .err = e },
        };
    } else switch (try compareValues(ctx, &a, &b)) {
        .ord => |o| orderToInt(o),
        .err => |e| return .{ .err = e },
    };
    return .{ .ok = Value.newInt(n) };
}

/// What the JVM's `compareTo` answers for a pair whose answer is a difference, not a sign:
/// two strings, the first unequal UTF-16 units' or else the lengths'; two chars, shorts or
/// bytes, the values'; two entries of one enum, the ordinals'. Null for any other pair, the
/// other numbers and Booleans answering a sign.
fn compareToDifference(a: *const Value, b: *const Value) ?i64 {
    switch (a.*) {
        .String => |x| if (b.* == .String) {
            const gx = x.borrow();
            defer gx.deinit();
            const gy = b.String.borrow();
            defer gy.deinit();
            return text.compareUtf16Difference(gx.get().bytes, gy.get().bytes);
        },
        .Char => |x| if (b.* == .Char) return @as(i64, x) - b.Char,
        .Short => |x| if (b.* == .Short) return @as(i64, x) - b.Short,
        .Byte => |x| if (b.* == .Byte) return @as(i64, x) - b.Byte,
        .Instance => |x| if (b.* == .Instance) {
            const cx = x.asPtrConst().class.asPtrConst();
            const cy = b.Instance.asPtrConst().class.asPtrConst();
            if (!cx.is_enum or !cy.is_enum or !std.mem.eql(u8, cx.fqn, cy.fqn)) return null;
            const ox = (x.asPtrConst().get("ordinal") orelse return null).asI64() orelse return null;
            const oy = (b.Instance.asPtrConst().get("ordinal") orelse return null).asI64() orelse return null;
            return ox - oy;
        },
        else => {},
    }
    return null;
}

pub fn comparator_natural_order(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const steps = try ctx.allocator.alloc(ComparatorStep, 0);
    return .{ .ok = try Value.newComparator(ctx.allocator, .{
        .steps = try ObjRef([]ComparatorStep).init(ctx.allocator, steps),
        .descending = false,
    }) };
}

pub fn comparator_reverse_order(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const steps = try ctx.allocator.alloc(ComparatorStep, 0);
    return .{ .ok = try Value.newComparator(ctx.allocator, .{
        .steps = try ObjRef([]ComparatorStep).init(ctx.allocator, steps),
        .descending = true,
    }) };
}

const testing = std.testing;

fn testClosure(id: u64) Value {
    const c = runtime.IrClosureRef.init(testing.allocator, .{ .id = id, .captures = &.{} }) catch unreachable;
    return .{ .IrClosure = c };
}

fn freeTestClosure(v: Value) void {
    v.IrClosure.deinit();
}


fn makeCtx(host: runtime.IntrinsicHost, out: runtime.Output, args: []const Value) CallCtx {
    return .{
        .args = args,
        .out = out,
        .host = host,
        .allocator = testing.allocator,
    };
}

test "compareValues orders numerics" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var ctx = makeCtx(h.host(), cap.output(), &.{ .{ .Int = 1 }, .{ .Int = 2 } });
    var r = try cmp_compare_values(&ctx);
    try testing.expect(r == .ok);
    try testing.expectEqual(@as(i32, -1), r.ok.Int);

    ctx = makeCtx(h.host(), cap.output(), &.{ .{ .Int = 5 }, .{ .Int = 5 } });
    r = try cmp_compare_values(&ctx);
    try testing.expectEqual(@as(i32, 0), r.ok.Int);

    ctx = makeCtx(h.host(), cap.output(), &.{ .{ .Long = 9 }, .{ .Int = 2 } });
    r = try cmp_compare_values(&ctx);
    try testing.expectEqual(@as(i32, 1), r.ok.Int);

    ctx = makeCtx(h.host(), cap.output(), &.{
        .{ .ULong = std.math.maxInt(u64) },
        .{ .ULong = 0 },
    });
    r = try cmp_compare_values(&ctx);
    try testing.expectEqual(@as(i32, 1), r.ok.Int);
}

test "compareValues answers a difference where the JVM's compareTo does, a sign elsewhere" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const kim = try runtime.strInit(testing.allocator, "kim");
    defer kim.deinit();
    const al = try runtime.strInit(testing.allocator, "al");
    defer al.deinit();
    const cases = [_]struct { a: Value, b: Value, want: i32 }{
        .{ .a = .{ .String = kim }, .b = .{ .String = al }, .want = 10 },
        .{ .a = .{ .Char = 'a' }, .b = .{ .Char = 'k' }, .want = -10 },
        .{ .a = .{ .Short = 3 }, .b = .{ .Short = 9 }, .want = -6 },
        .{ .a = .{ .Byte = 9 }, .b = .{ .Byte = -3 }, .want = 12 },
        .{ .a = .{ .Int = 3 }, .b = .{ .Int = 9 }, .want = -1 },
        .{ .a = .{ .Bool = true }, .b = .{ .Bool = false }, .want = 1 },
    };
    for (cases) |cs| {
        var ctx = makeCtx(h.host(), cap.output(), &.{ cs.a, cs.b });
        const r = try cmp_compare_values(&ctx);
        try testing.expectEqual(cs.want, r.ok.Int);
    }
}

test "compareValues totals NaN above infinity" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const nan = Value{ .Double = std.math.nan(f64) };
    const inf = Value{ .Double = std.math.inf(f64) };
    var ctx = makeCtx(h.host(), cap.output(), &.{ nan, inf });
    const r = try cmp_compare_values(&ctx);
    try testing.expectEqual(@as(i32, 1), r.ok.Int);
}

test "compareValues treats null as smallest" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var ctx = makeCtx(h.host(), cap.output(), &.{ .Null, .{ .Int = 1 } });
    var r = try cmp_compare_values(&ctx);
    try testing.expectEqual(@as(i32, -1), r.ok.Int);

    ctx = makeCtx(h.host(), cap.output(), &.{ .{ .Int = 1 }, .Null });
    r = try cmp_compare_values(&ctx);
    try testing.expectEqual(@as(i32, 1), r.ok.Int);

    ctx = makeCtx(h.host(), cap.output(), &.{ .Null, .Null });
    r = try cmp_compare_values(&ctx);
    try testing.expectEqual(@as(i32, 0), r.ok.Int);
}

test "compareValues arity error" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = makeCtx(h.host(), cap.output(), &.{.{ .Int = 1 }});
    const r = try cmp_compare_values(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Arity);
}

test "compareValues not-comparable type error" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    var ctx = makeCtx(h.host(), cap.output(), &.{ .{ .Int = 1 }, .{ .Bool = true } });
    const r = try cmp_compare_values(&ctx);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Type);
}

test "Comparator SAM wraps one step" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const lam = testClosure(1);
    defer freeTestClosure(lam);
    var ctx = makeCtx(h.host(), cap.output(), &.{lam});
    const r = try cmp_comparator_sam(&ctx);
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .Comparator);
    defer runtime.comparatorRefOf(r.ok.Comparator).deinit();
    defer testing.allocator.free(r.ok.Comparator.steps.asPtrConst().*);
    try testing.expectEqual(@as(usize, 1), r.ok.Comparator.steps.asPtrConst().*.len);
    try testing.expect(!r.ok.Comparator.descending);
    try testing.expect(!r.ok.Comparator.steps.asPtrConst().*[0].descending);
}

test "Comparator SAM rejects wrong arity and non-lambda" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var ctx = makeCtx(h.host(), cap.output(), &.{});
    var r = try cmp_comparator_sam(&ctx);
    try testing.expect(r.err == .Arity);

    const not_lambda = Value{ .Int = 0 };
    ctx = makeCtx(h.host(), cap.output(), &.{not_lambda});
    r = try cmp_comparator_sam(&ctx);
    try testing.expect(r.err == .Type);
}

test "naturalOrder and reverseOrder build empty-step comparators" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var ctx = makeCtx(h.host(), cap.output(), &.{});
    const nat = try comparator_natural_order(&ctx);
    defer runtime.comparatorRefOf(nat.ok.Comparator).deinit();
    try testing.expect(nat.ok == .Comparator);
    defer nat.ok.Comparator.steps.deinit();
    defer testing.allocator.free(nat.ok.Comparator.steps.asPtrConst().*);
    try testing.expectEqual(@as(usize, 0), nat.ok.Comparator.steps.asPtrConst().*.len);
    try testing.expect(!nat.ok.Comparator.descending);

    const rev = try comparator_reverse_order(&ctx);
    defer runtime.comparatorRefOf(rev.ok.Comparator).deinit();
    try testing.expect(rev.ok == .Comparator);
    defer rev.ok.Comparator.steps.deinit();
    defer testing.allocator.free(rev.ok.Comparator.steps.asPtrConst().*);
    try testing.expectEqual(@as(usize, 0), rev.ok.Comparator.steps.asPtrConst().*.len);
    try testing.expect(rev.ok.Comparator.descending);
}
