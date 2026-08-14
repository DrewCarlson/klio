//! Comparison intrinsics: `compareValues`, `compareValuesBy`, the
//! `Comparator { … }` SAM factory, `compareBy` / `compareByDescending`,
//! and the `naturalOrder` / `reverseOrder` comparator factories.

const std = @import("std");
const runtime = @import("runtime");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const RuntimeError = runtime.RuntimeError;
const Value = runtime.Value;
const ComparatorStep = runtime.ComparatorStep;
const ObjRef = runtime.ObjRef;
const text = @import("../text.zig");

/// `Result<Ordering, RuntimeError>` for the value-level comparison helper.
const CmpResult = union(enum) {
    ord: std.math.Order,
    err: RuntimeError,
};

/// Total order over IEEE-754 doubles matching Kotlin's `Double.compareTo`:
/// `-0.0 < 0.0` and every `NaN` sorts above `+Infinity`.
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

/// Compare two values by Kotlin's natural ordering. Numerics compare by
/// widened value (integral via `i64`, floating via the IEEE total order);
/// strings via UTF-16 code units; chars and booleans by their ordinal.
/// Any other pairing is not comparable.
fn compareValues(a: *const Value, b: *const Value) CmpResult {
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
        else => notComparable(a, b),
    };
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

/// Anything Kotlin can invoke as a key selector. A selector is very often a
/// property REFERENCE rather than a lambda — `compareValuesBy(a, b,
/// TestDispatchEvent::time, TestDispatchEvent::count)` is how the test
/// scheduler orders its event heap — and a `KProperty1<T, R>` is a `(T) -> R`.
/// Accepting only `IrClosure` rejected every reference form, though
/// `invokeCallable` dispatches all of them (`map(E::time)` has always worked).
/// Mirrors `interp_ir.valueIsCallable`, which the stdlib layer cannot import.
fn isCallable(v: Value) bool {
    return switch (v) {
        .IrClosure, .Intrinsic, .BoundMethod, .PropertyRef => true,
        // `E::time` — an UNBOUND property reference — lowers to a synth instance
        // carrying `__bound_receiver__` (the owning class). It is the `KProperty1`
        // Kotlin passes as a `(T) -> R`, and `invokeCallable` dispatches it.
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

pub fn cmp_compare_values_by(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len < 3) {
        return .{ .err = .{ .Arity = "compareValuesBy expects (a, b, selector, ...)" } };
    }
    const a = ctx.args[0];
    const b = ctx.args[1];
    const selectors = ctx.args[2..];
    for (selectors) |sel| {
        if (!isCallable(sel)) {
            return .{ .err = .{ .Type = "compareValuesBy expects key-selector lambdas" } };
        }
        const ka = switch (try ctx.host.invokeCallable(&sel, &.{a}, ctx.out)) {
            .ok => |v| v,
            .err => |e| return .{ .err = e },
        };
        const kb = switch (try ctx.host.invokeCallable(&sel, &.{b}, ctx.out)) {
            .ok => |v| v,
            .err => |e| return .{ .err = e },
        };
        const ord: std.math.Order = if (isNull(ka) and isNull(kb))
            .eq
        else if (isNull(ka))
            .lt
        else if (isNull(kb))
            .gt
        else switch (compareValues(&ka, &kb)) {
            .ord => |o| o,
            .err => |e| return .{ .err = e },
        };
        if (ord != .eq) {
            return .{ .ok = Value.newInt(orderToInt(ord)) };
        }
    }
    return .{ .ok = Value.newInt(0) };
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

pub fn cmp_compare_by(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return makeComparator(ctx, false);
}

pub fn cmp_compare_by_descending(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return makeComparator(ctx, true);
}

/// Build a `Comparator` whose steps are each argument used as a key
/// selector, tagged with the shared per-step `descending` flag. The
/// comparator-level `descending` stays `false`; reversal is per step.
fn makeComparator(ctx: *CallCtx, descending: bool) std.mem.Allocator.Error!EvalResult {
    // `compareBy(comparator, selector)` vs the vararg `compareBy(s1, s2)`:
    // both take two args, distinguished by arg[0] — a comparator value
    // (`.Comparator`, or a non-callable comparator like
    // `String.CASE_INSENSITIVE_ORDER`) vs a selector (a callable). Only the
    // comparator form gets a per-step key comparator; the selector form falls
    // through to the multi-selector loop below.
    if (ctx.args.len == 2 and isCallable(ctx.args[1]) and
        (ctx.args[0] == .Comparator or !isCallable(ctx.args[0])))
    {
        const steps = try ctx.allocator.alloc(ComparatorStep, 1);
        steps[0] = .{ .selector = ctx.args[1], .descending = descending, .key_comparator = ctx.args[0] };
        return .{ .ok = try Value.newComparator(ctx.allocator, .{
            .steps = try ObjRef([]ComparatorStep).init(ctx.allocator, steps),
            .descending = false,
        }) };
    }
    const steps = try ctx.allocator.alloc(ComparatorStep, ctx.args.len);
    for (ctx.args, 0..) |arg, i| {
        steps[i] = .{ .selector = arg, .descending = descending };
    }
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
    else switch (compareValues(&a, &b)) {
        .ord => |o| orderToInt(o),
        .err => |e| return .{ .err = e },
    };
    return .{ .ok = Value.newInt(n) };
}

// ============================================================
// Comparator factories
// ============================================================

/// `naturalOrder()` — an empty-step `Comparator`. The interpreter's sort
/// path treats an empty-step comparator as "compare items directly via the
/// natural order".
pub fn comparator_natural_order(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const steps = try ctx.allocator.alloc(ComparatorStep, 0);
    return .{ .ok = try Value.newComparator(ctx.allocator, .{
        .steps = try ObjRef([]ComparatorStep).init(ctx.allocator, steps),
        .descending = false,
    }) };
}

/// `reverseOrder()` — an empty-step `Comparator` flagged `descending`.
pub fn comparator_reverse_order(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const steps = try ctx.allocator.alloc(ComparatorStep, 0);
    return .{ .ok = try Value.newComparator(ctx.allocator, .{
        .steps = try ObjRef([]ComparatorStep).init(ctx.allocator, steps),
        .descending = true,
    }) };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

fn makeCtx(host: runtime.IntrinsicHost, out: runtime.Output, args: []const Value) CallCtx {
    return .{
        .args = args,
        .out = out,
        .host = host,
        .allocator = testing.allocator,
    };
}

/// Test host whose `invokeCallable` echoes a value chosen by a key
/// function over the single supplied argument. Used to drive the
/// selector-invoking `compareValuesBy` path without a real interpreter.
const SelectorHost = struct {
    /// Maps an input arg to the key the selector "returns".
    keyFn: *const fn (arg: Value) Value,

    fn init(allocator: std.mem.Allocator, keyFn: *const fn (arg: Value) Value) SelectorHost {
        _ = allocator;
        return .{ .keyFn = keyFn };
    }
    fn deinit(self: *SelectorHost) void {
        _ = self;
    }
    fn vtInvokeCallable(c: *anyopaque, callable: *const Value, args: []const Value, out: runtime.Output) std.mem.Allocator.Error!EvalResult {
        _ = callable;
        _ = out;
        const self: *SelectorHost = @ptrCast(@alignCast(c));
        const arg: Value = if (args.len > 0) args[0] else .Unit;
        return .{ .ok = self.keyFn(arg) };
    }
    fn vtInvokeCallableWithThis(c: *anyopaque, callable: *const Value, args: []const Value, this_value: *const Value, out: runtime.Output) std.mem.Allocator.Error!EvalResult {
        _ = this_value;
        return vtInvokeCallable(c, callable, args, out);
    }
    const vtable: runtime.IntrinsicHost.VTable = .{
        .invoke_callable = vtInvokeCallable,
        .invoke_callable_with_this = vtInvokeCallableWithThis,
    };
    fn host(self: *SelectorHost) runtime.IntrinsicHost {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

fn identityKey(arg: Value) Value {
    return arg;
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

test "compareValuesBy returns 0 when all selectors tie" {
    var h = SelectorHost.init(testing.allocator, identityKey);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const sel = Value{ .IrClosure = .{ .id = 0, .captures = undefined } };
    var ctx = makeCtx(h.host(), cap.output(), &.{ .{ .Int = 3 }, .{ .Int = 3 }, sel });
    const r = try cmp_compare_values_by(&ctx);
    try testing.expect(r == .ok);
    try testing.expectEqual(@as(i32, 0), r.ok.Int);
}

test "compareValuesBy uses the first differing selector" {
    var h = SelectorHost.init(testing.allocator, identityKey);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const sel = Value{ .IrClosure = .{ .id = 0, .captures = undefined } };
    var ctx = makeCtx(h.host(), cap.output(), &.{ .{ .Int = 7 }, .{ .Int = 9 }, sel });
    const r = try cmp_compare_values_by(&ctx);
    try testing.expectEqual(@as(i32, -1), r.ok.Int);
}

test "compareValuesBy arity and type errors" {
    var h = SelectorHost.init(testing.allocator, identityKey);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var ctx = makeCtx(h.host(), cap.output(), &.{ .{ .Int = 1 }, .{ .Int = 2 } });
    var r = try cmp_compare_values_by(&ctx);
    try testing.expect(r.err == .Arity);

    const not_lambda = Value{ .Int = 0 };
    ctx = makeCtx(h.host(), cap.output(), &.{ .{ .Int = 1 }, .{ .Int = 2 }, not_lambda });
    r = try cmp_compare_values_by(&ctx);
    try testing.expect(r.err == .Type);
}

test "Comparator SAM wraps one step" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const lam = Value{ .IrClosure = .{ .id = 1, .captures = undefined } };
    var ctx = makeCtx(h.host(), cap.output(), &.{lam});
    const r = try cmp_comparator_sam(&ctx);
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .Comparator);
    defer runtime.comparatorRefOf(r.ok.Comparator).deinit();
    defer testing.allocator.free(r.ok.Comparator.steps.asPtr().*);
    try testing.expectEqual(@as(usize, 1), r.ok.Comparator.steps.asPtr().*.len);
    try testing.expect(!r.ok.Comparator.descending);
    try testing.expect(!r.ok.Comparator.steps.asPtr().*[0].descending);
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

test "compareBy tags steps ascending" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const a = Value{ .IrClosure = .{ .id = 1, .captures = undefined } };
    const b = Value{ .IrClosure = .{ .id = 2, .captures = undefined } };
    var ctx = makeCtx(h.host(), cap.output(), &.{ a, b });
    const r = try cmp_compare_by(&ctx);
    try testing.expect(r.ok == .Comparator);
    defer runtime.comparatorRefOf(r.ok.Comparator).deinit();
    defer testing.allocator.free(r.ok.Comparator.steps.asPtr().*);
    const steps = r.ok.Comparator.steps.asPtr().*;
    try testing.expectEqual(@as(usize, 2), steps.len);
    try testing.expect(!r.ok.Comparator.descending);
    try testing.expect(!steps[0].descending);
    try testing.expect(!steps[1].descending);
}

test "compareByDescending tags steps descending" {
    var h = runtime.NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = runtime.CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const a = Value{ .IrClosure = .{ .id = 1, .captures = undefined } };
    var ctx = makeCtx(h.host(), cap.output(), &.{a});
    const r = try cmp_compare_by_descending(&ctx);
    try testing.expect(r.ok == .Comparator);
    defer runtime.comparatorRefOf(r.ok.Comparator).deinit();
    defer testing.allocator.free(r.ok.Comparator.steps.asPtr().*);
    const steps = r.ok.Comparator.steps.asPtr().*;
    try testing.expectEqual(@as(usize, 1), steps.len);
    try testing.expect(!r.ok.Comparator.descending);
    try testing.expect(steps[0].descending);
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
    defer testing.allocator.free(nat.ok.Comparator.steps.asPtr().*);
    try testing.expectEqual(@as(usize, 0), nat.ok.Comparator.steps.asPtr().*.len);
    try testing.expect(!nat.ok.Comparator.descending);

    const rev = try comparator_reverse_order(&ctx);
    defer runtime.comparatorRefOf(rev.ok.Comparator).deinit();
    try testing.expect(rev.ok == .Comparator);
    defer rev.ok.Comparator.steps.deinit();
    defer testing.allocator.free(rev.ok.Comparator.steps.asPtr().*);
    try testing.expectEqual(@as(usize, 0), rev.ok.Comparator.steps.asPtr().*.len);
    try testing.expect(rev.ok.Comparator.descending);
}
