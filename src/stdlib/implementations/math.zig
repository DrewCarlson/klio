//! kotlin.math intrinsics.

const std = @import("std");
const runtime = @import("runtime");
const text = @import("../text.zig");

const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const Output = runtime.Output;
const IntrinsicHost = runtime.IntrinsicHost;
const StringRef = runtime.StringRef;

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

/// A computed f64 or the `EvalResult` carrying a data-level error.
const DoubleResult = union(enum) { ok: f64, err: EvalResult };
/// A computed natural-ordering or the `EvalResult` carrying a data-level error.
const OrderResult = union(enum) { ok: std.math.Order, err: EvalResult };

fn typeErr(ctx: *CallCtx, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!EvalResult {
    const msg = try std.fmt.allocPrint(ctx.allocator, fmt, args);
    return .{ .err = .{ .Type = msg } };
}

fn arityErr(ctx: *CallCtx, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!EvalResult {
    const msg = try std.fmt.allocPrint(ctx.allocator, fmt, args);
    return .{ .err = .{ .Arity = msg } };
}

// ============================================================
// math
// ============================================================

/// Accept every numeric type (Float/Long/Short/Byte too), each widening
/// to f64 like Kotlin's numeric conversions, so math intrinsics aren't
/// limited to `Double`/`Int` operands. Returns null when the value is not
/// numeric; callers wrap that into a `Type` error including `what`.
pub fn as_double(v: *const Value, what: []const u8, ctx: *CallCtx) std.mem.Allocator.Error!DoubleResult {
    if (numeric_as_f64(v)) |d| return .{ .ok = d };
    const rendered = v.display(ctx.allocator) catch return .{ .err = .{ .err = .{ .Type = "out of memory" } } };
    defer ctx.allocator.free(rendered);
    return .{ .err = try typeErr(ctx, "{s} requires a number, got {s}", .{ what, rendered }) };
}

pub fn math_abs(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len == 1) {
        switch (ctx.args[0]) {
            .Int => |n| return ok(.{ .Int = if (n == std.math.minInt(i32)) n else @intCast(@abs(n)) }),
            .Long => |n| return ok(.{ .Long = if (n == std.math.minInt(i64)) n else @intCast(@abs(n)) }),
            .Double => |n| return ok(.{ .Double = @abs(n) }),
            .Float => |n| return ok(.{ .Float = @abs(n) }),
            else => {},
        }
    }
    return .{ .err = .{ .Type = "abs requires a number" } };
}

fn numeric_as_f64(v: *const Value) ?f64 {
    return switch (v.*) {
        .Int => |x| @floatFromInt(x),
        // Kotlin Long widens to Double (may lose precision past 2^53).
        .Long => |x| @floatFromInt(x),
        .Short => |x| @floatFromInt(x),
        .Byte => |x| @floatFromInt(x),
        .Float => |x| @floatCast(x),
        .Double => |x| x,
        else => null,
    };
}

fn numeric_as_i64(v: *const Value) ?i64 {
    return switch (v.*) {
        .Int => |x| @intCast(x),
        .Long => |x| x,
        .Short => |x| @intCast(x),
        .Byte => |x| @intCast(x),
        else => null,
    };
}

/// Numeric `min`/`max` over any Kotlin number pair (Byte/Short/Int/
/// Long/Float/Double, including mixed). Doubles as the
/// `kotlin.comparisons.minOf`/`maxOf` and `kotlin.math.min`/`max`
/// implementation. Integral pairs keep an integral result (widened
/// to the larger of the two so e.g. `minOf(Long, Int)` is a Long);
/// any floating operand promotes the result to Double.
pub fn num_extreme(ctx: *CallCtx, args: []const Value, want_min: bool, what: []const u8) std.mem.Allocator.Error!EvalResult {
    if (args.len == 0) return arityErr(ctx, "{s} expects at least 2 arguments", .{what});
    if (args.len == 1) return ok(args[0]);
    // `minOf(a, b, c, …)` / `minOf(a, vararg others)` fold pairwise.
    if (args.len > 2) {
        var acc = args[0];
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            switch (try num_extreme(ctx, &.{ acc, args[i] }, want_min, what)) {
                .ok => |v| acc = v,
                .err => |e| return .{ .err = e },
            }
        }
        return ok(acc);
    }
    const first = &args[0];
    const second = &args[1];
    const floating = (first.* == .Double or first.* == .Float) or
        (second.* == .Double or second.* == .Float);
    if (floating) {
        const x = numeric_as_f64(first) orelse return typeErr(ctx, "{s}: non-numeric arg", .{what});
        const y = numeric_as_f64(second) orelse return typeErr(ctx, "{s}: non-numeric arg", .{what});
        // Kotlin's minOf/maxOf use Math.min/max, which propagate NaN — unlike
        // Rust's f64::min/max which return the non-NaN operand.
        const r: f64 = if (std.math.isNan(x) or std.math.isNan(y))
            std.math.nan(f64)
        else if (x == 0.0 and y == 0.0)
            // Signed-zero tie (`@min`/`@max` treat -0.0 == 0.0): match
            // Math.min/max — min yields -0.0 if either is -0.0, max yields
            // +0.0 unless both are -0.0.
            (if (want_min)
                (if (std.math.signbit(x) or std.math.signbit(y)) -@as(f64, 0.0) else 0.0)
            else
                (if (std.math.signbit(x) and std.math.signbit(y)) -@as(f64, 0.0) else 0.0))
        else if (want_min)
            @min(x, y)
        else
            @max(x, y);
        // Kotlin's `min/max(Float, Float)` (and Float+integral) returns Float;
        // only a Double operand widens the result to Double.
        if (first.* != .Double and second.* != .Double) return ok(.{ .Float = @floatCast(r) });
        return ok(.{ .Double = r });
    }
    // A pair that is *both* unsigned compares by unsigned magnitude and keeps
    // its unsigned kind, widening to the larger when the kinds differ.
    if (unsigned_as_u64(first) != null and unsigned_as_u64(second) != null) {
        const x = unsigned_as_u64(first).?;
        const y = unsigned_as_u64(second).?;
        const r: u64 = if (want_min) @min(x, y) else @max(x, y);
        if (first.* == .ULong or second.* == .ULong) return ok(.{ .ULong = r });
        if (first.* == .UInt or second.* == .UInt) return ok(.{ .UInt = @intCast(r) });
        if (first.* == .UShort or second.* == .UShort) return ok(.{ .UShort = @intCast(r) });
        return ok(.{ .UByte = @intCast(r) });
    }
    // Otherwise compare by signed value, accepting an unsigned operand by its
    // magnitude: a mixed signed/unsigned pair arises when an untyped integer
    // literal lands on the unsigned overload of `minOf`/`maxOf`. Kotlin's
    // result there is the signed integral type, so widen to i64 and return
    // Int (or Long when either side is 64-bit).
    const x = integral_as_i64(first) orelse return typeErr(ctx, "{s}: non-numeric arg", .{what});
    const y = integral_as_i64(second) orelse return typeErr(ctx, "{s}: non-numeric arg", .{what});
    const r: i64 = if (want_min) @min(x, y) else @max(x, y);
    if (first.* == .Long or second.* == .Long or first.* == .ULong or second.* == .ULong) {
        return ok(.{ .Long = r });
    }
    return ok(.{ .Int = @truncate(r) });
}

/// Any integral operand widened to `i64`, signed or unsigned, by magnitude.
fn integral_as_i64(v: *const Value) ?i64 {
    return switch (v.*) {
        .Int => |x| @intCast(x),
        .Long => |x| x,
        .Short => |x| @intCast(x),
        .Byte => |x| @intCast(x),
        .UByte => |x| @intCast(x),
        .UShort => |x| @intCast(x),
        .UInt => |x| @intCast(x),
        .ULong => |x| @bitCast(x),
        else => null,
    };
}

/// Unsigned operand widened to `u64` (UByte/UShort/UInt/ULong only).
fn unsigned_as_u64(v: *const Value) ?u64 {
    return switch (v.*) {
        .UByte => |x| @as(u64, x),
        .UShort => |x| @as(u64, x),
        .UInt => |x| @as(u64, x),
        .ULong => |x| x,
        else => null,
    };
}

pub fn math_min(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return cmp_extreme(ctx, true, "min");
}

pub fn math_max(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return cmp_extreme(ctx, false, "max");
}

pub fn cmp_extreme(ctx: *CallCtx, want_min: bool, what: []const u8) std.mem.Allocator.Error!EvalResult {
    // Instance-aware path: a user receiver implementing Comparable
    // (`operator fun compareTo`) reaches min/max via call_member,
    // falling back to the primitive num_extreme for plain numbers.
    if (ctx.args.len == 2) {
        const a = &ctx.args[0];
        const b = &ctx.args[1];
        if (a.* == .Instance or b.* == .Instance) {
            const ord = switch (try compare_host_aware(a, b, ctx.host, ctx.out)) {
                .ok => |o| o,
                .err => |e| return e,
            };
            const pick_first = if (want_min) ord != .gt else ord != .lt;
            return ok(if (pick_first) a.* else b.*);
        }
        // Numeric operands use `num_extreme` (width widening +
        // Math.min/max NaN propagation). Any other `Comparable`
        // (`maxOf("a","b")`, Char) picks by the total comparison
        // order, mirroring the generic `maxOf<T : Comparable<T>>`.
        if (!(a.isNumeric() and b.isNumeric())) {
            const ord = switch (try compare_values(ctx, a, b)) {
                .ok => |o| o,
                .err => |e| return e,
            };
            const pick_first = if (want_min) ord != .gt else ord != .lt;
            return ok(if (pick_first) a.* else b.*);
        }
    }
    return num_extreme(ctx, ctx.args, want_min, what);
}

pub fn math_sqrt(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len != 1) {
        return .{ .err = .{ .Arity = "sqrt expects 1 argument" } };
    }
    const is_float = ctx.args[0] == .Float;
    const d = switch (try as_double(&ctx.args[0], "sqrt", ctx)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    if (is_float) return ok(.{ .Float = @floatCast(@sqrt(d)) });
    return ok(.{ .Double = @sqrt(d) });
}

/// `Double.pow(Double)` and `Double.pow(Int)` — Kotlin's only `pow` shape.
/// Receiver is `args[0]`, exponent is `args[1]`.
pub fn double_pow(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len != 2) {
        return .{ .err = .{ .Arity = "Double.pow expects 1 argument" } };
    }
    const base = switch (try recv_double(ctx, "Double.pow")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const exp = switch (try as_double(&ctx.args[1], "Double.pow", ctx)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    // Java/Kotlin Math.pow: `pow(±1, ±Inf)` is NaN (unlike C/Zig pow which
    // returns 1). Every other base with a NaN exponent is NaN too.
    if (@abs(base) == 1.0 and (std.math.isInf(exp) or std.math.isNan(exp))) {
        return ok(.{ .Double = std.math.nan(f64) });
    }
    return ok(.{ .Double = std.math.pow(f64, base, exp) });
}

/// `Float.pow(Float)` / `Float.pow(Int)` — like `Double.pow` but keeping a
/// `Float` result.
pub fn float_pow(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    if (ctx.args.len != 2) {
        return .{ .err = .{ .Arity = "Float.pow expects 1 argument" } };
    }
    const base_d = switch (try recv_double(ctx, "Float.pow")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const exp_d = switch (try as_double(&ctx.args[1], "Float.pow", ctx)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const base: f32 = @floatCast(base_d);
    const exp: f32 = @floatCast(exp_d);
    return ok(.{ .Float = std.math.pow(f32, base, exp) });
}

/// `Math.nextUp` — the adjacent f64 toward +∞.
fn f64_next_up(x: f64) f64 {
    if (std.math.isNan(x) or x == std.math.inf(f64)) {
        return x;
    }
    if (x == 0.0) {
        return @bitCast(@as(u64, 1)); // smallest positive subnormal
    }
    const bits: u64 = @bitCast(x);
    return @bitCast(if (x > 0.0) bits + 1 else bits - 1);
}

/// `Math.nextDown` — the adjacent f64 toward -∞.
fn f64_next_down(x: f64) f64 {
    return -f64_next_up(-x);
}

pub fn double_next_up(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = switch (try recv_double(ctx, "Double.nextUp")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    return ok(.{ .Double = f64_next_up(r) });
}
pub fn double_next_down(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const r = switch (try recv_double(ctx, "Double.nextDown")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    return ok(.{ .Double = f64_next_down(r) });
}
pub fn double_next_towards(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const x = switch (try recv_double(ctx, "Double.nextTowards")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) {
        return .{ .err = .{ .Arity = "nextTowards expects (to)" } };
    }
    const to = switch (try as_double(&ctx.args[1], "Double.nextTowards", ctx)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const r: f64 = if (std.math.isNan(x) or std.math.isNan(to))
        std.math.nan(f64)
    else if (x == to)
        to
    else if (x < to)
        f64_next_up(x)
    else
        f64_next_down(x);
    return ok(.{ .Double = r });
}
pub fn double_ulp(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const x = switch (try recv_double(ctx, "Double.ulp")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const r: f64 = if (std.math.isNan(x))
        std.math.nan(f64)
    else if (std.math.isInf(x))
        std.math.inf(f64)
    else blk: {
        const a = @abs(x);
        break :blk f64_next_up(a) - a;
    };
    return ok(.{ .Double = r });
}
pub fn double_with_sign(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const x = switch (try recv_double(ctx, "Double.withSign")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) {
        return .{ .err = .{ .Arity = "withSign expects (sign)" } };
    }
    const sign = switch (try as_double(&ctx.args[1], "Double.withSign", ctx)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    return ok(.{ .Double = std.math.copysign(x, sign) });
}
pub fn float_with_sign(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const x_d = switch (try recv_double(ctx, "Float.withSign")) {
        .ok => |v| v,
        .err => |e| return e,
    };
    if (ctx.args.len < 2) {
        return .{ .err = .{ .Arity = "withSign expects (sign)" } };
    }
    const sign_d = switch (try as_double(&ctx.args[1], "Float.withSign", ctx)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const x: f32 = @floatCast(x_d);
    const sign: f32 = @floatCast(sign_d);
    return ok(.{ .Float = std.math.copysign(x, sign) });
}

/// Apply a one-argument f64 -> f64 function over the single numeric arg.
fn unaryDouble(ctx: *CallCtx, what: []const u8, comptime f: fn (f64) f64) std.mem.Allocator.Error!EvalResult {
    const v = switch (try arg1(ctx, what)) {
        .ok => |p| p,
        .err => |e| return e,
    };
    const is_float = v.* == .Float;
    const d = switch (try as_double(v, what, ctx)) {
        .ok => |x| x,
        .err => |e| return e,
    };
    const r = f(d);
    // The `Float` overload of each function returns a `Float`; computing in
    // f64 and narrowing matches the special values (NaN/±∞/±0) exactly and
    // is within tolerance for the finite cases the tests assert.
    if (is_float) return ok(.{ .Float = @floatCast(r) });
    return ok(.{ .Double = r });
}

/// As `unaryDouble`, for a two-argument function: the `Float,Float` overload
/// returns a `Float`, so narrow when both operands are `Float`.
fn binaryDouble(ctx: *CallCtx, what: []const u8, comptime f: fn (f64, f64) f64) std.mem.Allocator.Error!EvalResult {
    const pair = switch (try arg2(ctx, what)) {
        .ok => |p| p,
        .err => |e| return e,
    };
    const both_float = pair.a.* == .Float and pair.b.* == .Float;
    const a = switch (try as_double(pair.a, what, ctx)) {
        .ok => |x| x,
        .err => |e| return e,
    };
    const b = switch (try as_double(pair.b, what, ctx)) {
        .ok => |x| x,
        .err => |e| return e,
    };
    const r = f(a, b);
    if (both_float) return ok(.{ .Float = @floatCast(r) });
    return ok(.{ .Double = r });
}

fn fAtan2(y: f64, x: f64) f64 {
    return std.math.atan2(y, x);
}
fn fHypot(a: f64, b: f64) f64 {
    return std.math.hypot(a, b);
}

fn fSinh(x: f64) f64 {
    return std.math.sinh(x);
}
fn fCosh(x: f64) f64 {
    return std.math.cosh(x);
}
fn fTanh(x: f64) f64 {
    return std.math.tanh(x);
}
fn fAsinh(x: f64) f64 {
    return std.math.asinh(x);
}
fn fAcosh(x: f64) f64 {
    return std.math.acosh(x);
}
fn fAtanh(x: f64) f64 {
    return std.math.atanh(x);
}
fn fExpm1(x: f64) f64 {
    return std.math.expm1(x);
}
fn fLn1p(x: f64) f64 {
    return std.math.log1p(x);
}
fn fSin(x: f64) f64 {
    return @sin(x);
}
fn fCos(x: f64) f64 {
    return @cos(x);
}
fn fTan(x: f64) f64 {
    return @tan(x);
}
fn fLn(x: f64) f64 {
    return @log(x);
}
fn fLog10(x: f64) f64 {
    return @log10(x);
}
fn fLog2(x: f64) f64 {
    return @log2(x);
}
fn fExp(x: f64) f64 {
    return @exp(x);
}
fn fFloor(x: f64) f64 {
    return @floor(x);
}
fn fCeil(x: f64) f64 {
    return @ceil(x);
}
fn fTrunc(x: f64) f64 {
    return @trunc(x);
}
fn fCbrt(x: f64) f64 {
    return std.math.cbrt(x);
}
fn fAsin(x: f64) f64 {
    return std.math.asin(x);
}
fn fAcos(x: f64) f64 {
    return std.math.acos(x);
}
fn fAtan(x: f64) f64 {
    return std.math.atan(x);
}

pub fn math_sinh(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "sinh", fSinh);
}
pub fn math_cosh(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "cosh", fCosh);
}
pub fn math_tanh(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "tanh", fTanh);
}
pub fn math_asinh(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "asinh", fAsinh);
}
pub fn math_acosh(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "acosh", fAcosh);
}
pub fn math_atanh(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "atanh", fAtanh);
}
pub fn math_expm1(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "expm1", fExpm1);
}
pub fn math_ln1p(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "ln1p", fLn1p);
}

pub fn math_sin(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "sin", fSin);
}
pub fn math_cos(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "cos", fCos);
}
pub fn math_tan(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "tan", fTan);
}
pub fn math_ln(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "ln", fLn);
}
pub fn math_log(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const pair = switch (try arg2(ctx, "log")) {
        .ok => |p| p,
        .err => |e| return e,
    };
    const both_float = pair.a.* == .Float and pair.b.* == .Float;
    const x = switch (try as_double(pair.a, "log", ctx)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const base = switch (try as_double(pair.b, "log", ctx)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    // Kotlin's `Double.log(base)` is `ln(x) / ln(base)`, and is NaN when the
    // base is not a usable logarithm base (`base <= 0` or `base == 1`).
    const r = if (base <= 0.0 or base == 1.0) std.math.nan(f64) else std.math.log(f64, base, x);
    if (both_float) return ok(.{ .Float = @floatCast(r) });
    return ok(.{ .Double = r });
}
pub fn math_log10(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "log10", fLog10);
}
pub fn math_log2(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "log2", fLog2);
}
pub fn math_exp(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "exp", fExp);
}
pub fn math_floor(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "floor", fFloor);
}
pub fn math_ceil(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "ceil", fCeil);
}

/// Round half to even (IEEE rint), matching `kotlin.math.round`. Zig has
/// no ties-to-even builtin, so floor-and-adjust on the .5 boundary.
fn roundTiesEven(x: f64) f64 {
    if (std.math.isNan(x) or std.math.isInf(x) or x == 0.0) return x;
    const fl = @floor(x);
    const diff = x - fl;
    if (diff < 0.5) return fl;
    if (diff > 0.5) return fl + 1.0;
    // Exactly halfway: pick the even neighbor.
    const half = fl * 0.5;
    if (@floor(half) == half) return fl; // fl is even
    return fl + 1.0;
}

pub fn math_round(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    // Kotlin's kotlin.math.round rounds half to even (IEEE rint), unlike
    // Rust's round() which rounds half away from zero.
    return unaryDouble(ctx, "round", roundTiesEven);
}
pub fn math_truncate(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "truncate", fTrunc);
}
pub fn math_hypot(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return binaryDouble(ctx, "hypot", fHypot);
}

/// Kotlin's sign preserves a signed/NaN zero: sign(0.0)=0.0, sign(-0.0)=-0.0,
/// sign(NaN)=NaN. Rust's `signum()` returns ±1.0 for zero, so special-case it.
fn fsign(n: f64) f64 {
    if (n == 0.0 or std.math.isNan(n)) {
        return n;
    }
    return std.math.sign(n);
}

pub fn math_sign(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const v = switch (try arg1(ctx, "sign")) {
        .ok => |p| p,
        .err => |e| return e,
    };
    switch (v.*) {
        .Int => |n| return ok(.{ .Int = signumI32(n) }),
        // Long.signum() yields -1/0/1, which always fits an Int.
        .Long => |n| return ok(.{ .Int = @intCast(signumI64(n)) }),
        // Float.sign stays a Float.
        .Float => |n| return ok(.{ .Float = @floatCast(fsign(@as(f64, @floatCast(n)))) }),
        .Double => |n| return ok(.{ .Double = fsign(n) }),
        else => {
            const rendered = v.display(ctx.allocator) catch return .{ .err = .{ .Type = "out of memory" } };
            defer ctx.allocator.free(rendered);
            return typeErr(ctx, "sign requires a number, got {s}", .{rendered});
        },
    }
}

fn signumI32(n: i32) i32 {
    if (n > 0) return 1;
    if (n < 0) return -1;
    return 0;
}
fn signumI64(n: i64) i64 {
    if (n > 0) return 1;
    if (n < 0) return -1;
    return 0;
}

pub fn math_cbrt(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "cbrt", fCbrt);
}

/// `roundToInt()` / `roundToLong()`: round half toward +∞ (Java `Math.round`),
/// throw on NaN, clamp out-of-range to the type's MIN/MAX.
pub fn num_round_to_int(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const v = switch (try arg1(ctx, "roundToInt")) {
        .ok => |p| p,
        .err => |e| return e,
    };
    const d = switch (try as_double(v, "roundToInt", ctx)) {
        .ok => |x| x,
        .err => |e| return e,
    };
    if (std.math.isNan(d)) {
        return .{ .err = .{ .Thrown = try make_exception(ctx, "kotlin.IllegalArgumentException", "Cannot round NaN value.") } };
    }
    const r = @floor(d + 0.5);
    const i32_max: f64 = @floatFromInt(std.math.maxInt(i32));
    const i32_min: f64 = @floatFromInt(std.math.minInt(i32));
    const out_v: i32 = if (r >= i32_max)
        std.math.maxInt(i32)
    else if (r <= i32_min)
        std.math.minInt(i32)
    else
        @intFromFloat(r);
    return ok(.{ .Int = out_v });
}

pub fn num_round_to_long(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const v = switch (try arg1(ctx, "roundToLong")) {
        .ok => |p| p,
        .err => |e| return e,
    };
    const d = switch (try as_double(v, "roundToLong", ctx)) {
        .ok => |x| x,
        .err => |e| return e,
    };
    if (std.math.isNan(d)) {
        return .{ .err = .{ .Thrown = try make_exception(ctx, "kotlin.IllegalArgumentException", "Cannot round NaN value.") } };
    }
    const r = @floor(d + 0.5);
    const i64_max: f64 = @floatFromInt(std.math.maxInt(i64));
    const i64_min: f64 = @floatFromInt(std.math.minInt(i64));
    const out_v: i64 = if (r >= i64_max)
        std.math.maxInt(i64)
    else if (r <= i64_min)
        std.math.minInt(i64)
    else
        @intFromFloat(r);
    return ok(.{ .Long = out_v });
}

pub fn num_take_highest_one_bit(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const v = switch (try arg1(ctx, "takeHighestOneBit")) {
        .ok => |p| p,
        .err => |e| return e,
    };
    switch (v.*) {
        .Int => |n| {
            const u: u32 = @bitCast(n);
            const r: i32 = if (u == 0) 0 else @bitCast(@as(u32, 1) << @intCast(std.math.log2_int(u32, u)));
            return ok(.{ .Int = r });
        },
        .Long => |n| {
            const u: u64 = @bitCast(n);
            const r: i64 = if (u == 0) 0 else @bitCast(@as(u64, 1) << @intCast(std.math.log2_int(u64, u)));
            return ok(.{ .Long = r });
        },
        .UByte => |u| return ok(.{ .UByte = if (u == 0) 0 else @as(u8, 1) << @intCast(std.math.log2_int(u8, u)) }),
        .UShort => |u| return ok(.{ .UShort = if (u == 0) 0 else @as(u16, 1) << @intCast(std.math.log2_int(u16, u)) }),
        .UInt => |u| return ok(.{ .UInt = if (u == 0) 0 else @as(u32, 1) << @intCast(std.math.log2_int(u32, u)) }),
        .ULong => |u| return ok(.{ .ULong = if (u == 0) 0 else @as(u64, 1) << @intCast(std.math.log2_int(u64, u)) }),
        else => {
            const rendered = v.display(ctx.allocator) catch return .{ .err = .{ .Type = "out of memory" } };
            defer ctx.allocator.free(rendered);
            return typeErr(ctx, "takeHighestOneBit requires an integer, got {s}", .{rendered});
        },
    }
}

pub fn num_take_lowest_one_bit(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const v = switch (try arg1(ctx, "takeLowestOneBit")) {
        .ok => |p| p,
        .err => |e| return e,
    };
    switch (v.*) {
        .Int => |n| {
            const neg = 0 -% n;
            return ok(.{ .Int = n & neg });
        },
        .Long => |n| {
            const neg = 0 -% n;
            return ok(.{ .Long = n & neg });
        },
        .UByte => |u| return ok(.{ .UByte = u & (0 -% u) }),
        .UShort => |u| return ok(.{ .UShort = u & (0 -% u) }),
        .UInt => |u| return ok(.{ .UInt = u & (0 -% u) }),
        .ULong => |u| return ok(.{ .ULong = u & (0 -% u) }),
        else => {
            const rendered = v.display(ctx.allocator) catch return .{ .err = .{ .Type = "out of memory" } };
            defer ctx.allocator.free(rendered);
            return typeErr(ctx, "takeLowestOneBit requires an integer, got {s}", .{rendered});
        },
    }
}

pub fn num_rotate_left(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const pair = switch (try arg2(ctx, "rotateLeft")) {
        .ok => |p| p,
        .err => |e| return e,
    };
    const n = pair.b.asI64() orelse return .{ .err = .{ .Type = "rotateLeft bitCount must be Int" } };
    switch (pair.a.*) {
        .Int => |x| {
            const sh: u5 = @intCast(@mod(n, 32));
            const u: u32 = @bitCast(x);
            return ok(.{ .Int = @bitCast(std.math.rotl(u32, u, sh)) });
        },
        .Long => |x| {
            const sh: u6 = @intCast(@mod(n, 64));
            const u: u64 = @bitCast(x);
            return ok(.{ .Long = @bitCast(std.math.rotl(u64, u, sh)) });
        },
        .UByte => |u| return ok(.{ .UByte = std.math.rotl(u8, u, @as(u8, @intCast(@mod(n, 8)))) }),
        .UShort => |u| return ok(.{ .UShort = std.math.rotl(u16, u, @as(u16, @intCast(@mod(n, 16)))) }),
        .UInt => |u| return ok(.{ .UInt = std.math.rotl(u32, u, @as(u32, @intCast(@mod(n, 32)))) }),
        .ULong => |u| return ok(.{ .ULong = std.math.rotl(u64, u, @as(u64, @intCast(@mod(n, 64)))) }),
        else => {
            const rendered = pair.a.display(ctx.allocator) catch return .{ .err = .{ .Type = "out of memory" } };
            defer ctx.allocator.free(rendered);
            return typeErr(ctx, "rotateLeft requires an integer, got {s}", .{rendered});
        },
    }
}

pub fn num_rotate_right(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const pair = switch (try arg2(ctx, "rotateRight")) {
        .ok => |p| p,
        .err => |e| return e,
    };
    const n = pair.b.asI64() orelse return .{ .err = .{ .Type = "rotateRight bitCount must be Int" } };
    switch (pair.a.*) {
        .Int => |x| {
            const sh: u5 = @intCast(@mod(n, 32));
            const u: u32 = @bitCast(x);
            return ok(.{ .Int = @bitCast(std.math.rotr(u32, u, sh)) });
        },
        .Long => |x| {
            const sh: u6 = @intCast(@mod(n, 64));
            const u: u64 = @bitCast(x);
            return ok(.{ .Long = @bitCast(std.math.rotr(u64, u, sh)) });
        },
        .UByte => |u| return ok(.{ .UByte = std.math.rotr(u8, u, @as(u8, @intCast(@mod(n, 8)))) }),
        .UShort => |u| return ok(.{ .UShort = std.math.rotr(u16, u, @as(u16, @intCast(@mod(n, 16)))) }),
        .UInt => |u| return ok(.{ .UInt = std.math.rotr(u32, u, @as(u32, @intCast(@mod(n, 32)))) }),
        .ULong => |u| return ok(.{ .ULong = std.math.rotr(u64, u, @as(u64, @intCast(@mod(n, 64)))) }),
        else => {
            const rendered = pair.a.display(ctx.allocator) catch return .{ .err = .{ .Type = "out of memory" } };
            defer ctx.allocator.free(rendered);
            return typeErr(ctx, "rotateRight requires an integer, got {s}", .{rendered});
        },
    }
}

/// `Double.rem(Double)` / `Float.rem` — IEEE remainder (sign of dividend),
/// same as the `%` operator.
pub fn num_float_rem(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const pair = switch (try arg2(ctx, "rem")) {
        .ok => |p| p,
        .err => |e| return e,
    };
    const a = switch (try as_double(pair.a, "rem", ctx)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const b = switch (try as_double(pair.b, "rem", ctx)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const r = @rem(a, b);
    if (pair.a.* == .Float) {
        return ok(.{ .Float = @floatCast(r) });
    }
    return ok(.{ .Double = r });
}

/// `Double.mod(Double)` / `Float.mod` — floored modulus (sign of divisor).
pub fn num_float_mod(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    const pair = switch (try arg2(ctx, "mod")) {
        .ok => |p| p,
        .err => |e| return e,
    };
    const dividend = switch (try as_double(pair.a, "mod", ctx)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    const divisor = switch (try as_double(pair.b, "mod", ctx)) {
        .ok => |v| v,
        .err => |e| return e,
    };
    var rem = @rem(dividend, divisor);
    if (rem != 0.0 and (rem < 0.0) != (divisor < 0.0)) {
        rem += divisor;
    }
    if (pair.a.* == .Float) {
        return ok(.{ .Float = @floatCast(rem) });
    }
    return ok(.{ .Double = rem });
}

pub fn math_pi(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    return ok(.{ .Double = std.math.pi });
}
pub fn math_e(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    _ = ctx;
    return ok(.{ .Double = std.math.e });
}

const ArgRef = union(enum) { ok: *const Value, err: EvalResult };
const ArgPair = union(enum) { ok: struct { a: *const Value, b: *const Value }, err: EvalResult };

pub fn arg1(ctx: *CallCtx, what: []const u8) std.mem.Allocator.Error!ArgRef {
    if (ctx.args.len != 1) {
        return .{ .err = try arityErr(ctx, "{s} expects 1 argument", .{what}) };
    }
    return .{ .ok = &ctx.args[0] };
}

pub fn arg2(ctx: *CallCtx, what: []const u8) std.mem.Allocator.Error!ArgPair {
    if (ctx.args.len != 2) {
        return .{ .err = try arityErr(ctx, "{s} expects 2 arguments", .{what}) };
    }
    return .{ .ok = .{ .a = &ctx.args[0], .b = &ctx.args[1] } };
}

// ============================================================
// Additional math
// ============================================================

pub fn math_asin(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "asin", fAsin);
}
pub fn math_acos(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "acos", fAcos);
}
pub fn math_atan(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return unaryDouble(ctx, "atan", fAtan);
}
pub fn math_atan2(ctx: *CallCtx) std.mem.Allocator.Error!EvalResult {
    return binaryDouble(ctx, "atan2", fAtan2);
}

// ------------------------------------------------------------
// Shared helpers ported alongside the math intrinsics that use them.
// These mirror the cross-module helpers in the Rust crate
// (`numeric::recv_double`, `exceptions::make_exception`,
// `collections::{compare_values, compare_host_aware}`).
// ------------------------------------------------------------

/// `numeric::recv_double` — the receiver as f64, or a `Type` error.
fn recv_double(ctx: *CallCtx, what: []const u8) std.mem.Allocator.Error!DoubleResult {
    if (ctx.args.len > 0) {
        if (ctx.args[0].asF64()) |d| return .{ .ok = d };
    }
    return .{ .err = try typeErr(ctx, "{s} requires a numeric receiver", .{what}) };
}

/// `exceptions::make_exception` — a bare Throwable with the given fqn and
/// message. The fqn/message are duped into shared refcounted strings.
fn make_exception(ctx: *CallCtx, fqn: []const u8, message: ?[]const u8) std.mem.Allocator.Error!Value {
    const fqn_ref = try runtime.strInit(ctx.allocator, fqn);
    const msg_ref: ?StringRef = if (message) |m| try runtime.strInit(ctx.allocator, m) else null;
    return .{ .Exception = .{ .fqn = fqn_ref, .message = msg_ref, .cause = null } };
}

/// `collections::kotlin_float_total_cmp` — total order over f64 with NaN
/// sorting greatest and -0.0 < +0.0.
fn kotlin_float_total_cmp(a: f64, b: f64) std.math.Order {
    if (a < b) return .lt;
    if (a > b) return .gt;
    const bits = struct {
        fn f(x: f64) i64 {
            if (std.math.isNan(x)) {
                return @bitCast(@as(u64, 0x7ff8_0000_0000_0000));
            }
            return @bitCast(x);
        }
    }.f;
    return std.math.order(bits(a), bits(b));
}

/// `collections::compare_values` — Kotlin natural ordering for the
/// builtin comparable kinds. Returns a `Type` error when incomparable.
fn compare_values(ctx: *CallCtx, a: *const Value, b: *const Value) std.mem.Allocator.Error!OrderResult {
    if (a.isNumeric() and b.isNumeric()) {
        if (a.isIntegral() and b.isIntegral()) {
            return .{ .ok = std.math.order(a.asI64().?, b.asI64().?) };
        }
        return .{ .ok = kotlin_float_total_cmp(a.asF64().?, b.asF64().?) };
    }
    switch (a.*) {
        .String => |x| if (b.* == .String) {
            const gx = x.borrow();
            defer gx.deinit();
            const gy = b.String.borrow();
            defer gy.deinit();
            return .{ .ok = text.compareUtf16(gx.get().bytes, gy.get().bytes) };
        },
        .Char => |x| if (b.* == .Char) return .{ .ok = std.math.order(x, b.Char) },
        .Bool => |x| if (b.* == .Bool) return .{ .ok = std.math.order(@intFromBool(x), @intFromBool(b.Bool)) },
        else => {},
    }
    const ra = a.display(ctx.allocator) catch return .{ .err = .{ .err = .{ .Type = "out of memory" } } };
    defer ctx.allocator.free(ra);
    const rb = b.display(ctx.allocator) catch return .{ .err = .{ .err = .{ .Type = "out of memory" } } };
    defer ctx.allocator.free(rb);
    return .{ .err = try typeErr(ctx, "values are not comparable: {s}, {s}", .{ ra, rb }) };
}

fn i32_to_ordering(n: i32) std.math.Order {
    return std.math.order(n, 0);
}

/// `collections::compare_host_aware` — defer to a user `compareTo` for an
/// `Instance` receiver, else the structural `compare_values`.
fn compare_host_aware(a: *const Value, b: *const Value, host: IntrinsicHost, out: Output) std.mem.Allocator.Error!OrderResult {
    if (a.* == .Instance) {
        if (try host.invokeMethod(a, "compareTo", b[0..1], out)) |r| {
            switch (r) {
                .ok => |val| if (val == .Int) return .{ .ok = i32_to_ordering(val.Int) },
                .err => {},
            }
        }
    }
    // compare_values needs an allocator for error rendering; build a
    // throwaway CallCtx so the helper signature stays uniform.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp = CallCtx{ .args = &.{}, .out = out, .host = host, .allocator = arena.allocator() };
    return compare_values(&tmp, a, b);
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;
const NoopHost = runtime.NoopHost;
const CaptureOutput = runtime.CaptureOutput;

fn makeCtx(args: []const Value, h: *NoopHost, cap: *CaptureOutput) CallCtx {
    return .{ .args = args, .out = cap.output(), .host = h.host(), .allocator = testing.allocator };
}

fn expectDouble(expected: f64, r: EvalResult) !void {
    try testing.expect(r == .ok);
    try testing.expect(r.ok == .Double);
    try testing.expectApproxEqAbs(expected, r.ok.Double, 1e-12);
}

test "abs over numeric kinds" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var ctx = makeCtx(&.{.{ .Int = -5 }}, &h, &cap);
    try testing.expectEqual(@as(i32, 5), (try math_abs(&ctx)).ok.Int);

    var c2 = makeCtx(&.{.{ .Long = -7 }}, &h, &cap);
    try testing.expectEqual(@as(i64, 7), (try math_abs(&c2)).ok.Long);

    var c3 = makeCtx(&.{.{ .Double = -2.5 }}, &h, &cap);
    try testing.expectEqual(@as(f64, 2.5), (try math_abs(&c3)).ok.Double);

    var c4 = makeCtx(&.{.{ .Float = -1.5 }}, &h, &cap);
    try testing.expectEqual(@as(f32, 1.5), (try math_abs(&c4)).ok.Float);

    // i32::MIN abs wraps to itself.
    var c5 = makeCtx(&.{.{ .Int = std.math.minInt(i32) }}, &h, &cap);
    try testing.expectEqual(std.math.minInt(i32), (try math_abs(&c5)).ok.Int);

    var c6 = makeCtx(&.{.Unit}, &h, &cap);
    try testing.expect((try math_abs(&c6)) == .err);
}

test "sqrt and trig" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var ctx = makeCtx(&.{.{ .Double = 9.0 }}, &h, &cap);
    try expectDouble(3.0, try math_sqrt(&ctx));

    // sqrt accepts an Int operand, widening it.
    var ci = makeCtx(&.{.{ .Int = 16 }}, &h, &cap);
    try expectDouble(4.0, try math_sqrt(&ci));

    var cs = makeCtx(&.{.{ .Double = 0.0 }}, &h, &cap);
    try expectDouble(0.0, try math_sin(&cs));

    var cc = makeCtx(&.{.{ .Double = 0.0 }}, &h, &cap);
    try expectDouble(1.0, try math_cos(&cc));
}

test "ln log10 log2 exp and base log" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var c1 = makeCtx(&.{.{ .Double = std.math.e }}, &h, &cap);
    try expectDouble(1.0, try math_ln(&c1));

    var c2 = makeCtx(&.{.{ .Double = 1000.0 }}, &h, &cap);
    try expectDouble(3.0, try math_log10(&c2));

    var c3 = makeCtx(&.{.{ .Double = 8.0 }}, &h, &cap);
    try expectDouble(3.0, try math_log2(&c3));

    var c4 = makeCtx(&.{.{ .Double = 0.0 }}, &h, &cap);
    try expectDouble(1.0, try math_exp(&c4));

    // log(81, 3) == 4
    var c5 = makeCtx(&.{ .{ .Double = 81.0 }, .{ .Double = 3.0 } }, &h, &cap);
    try expectDouble(4.0, try math_log(&c5));
}

test "floor ceil truncate round ties-even" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var c1 = makeCtx(&.{.{ .Double = 2.7 }}, &h, &cap);
    try expectDouble(2.0, try math_floor(&c1));

    var c2 = makeCtx(&.{.{ .Double = 2.1 }}, &h, &cap);
    try expectDouble(3.0, try math_ceil(&c2));

    var c3 = makeCtx(&.{.{ .Double = -2.7 }}, &h, &cap);
    try expectDouble(-2.0, try math_truncate(&c3));

    // 2.5 rounds to even (2), 3.5 rounds to even (4).
    var c4 = makeCtx(&.{.{ .Double = 2.5 }}, &h, &cap);
    try expectDouble(2.0, try math_round(&c4));
    var c5 = makeCtx(&.{.{ .Double = 3.5 }}, &h, &cap);
    try expectDouble(4.0, try math_round(&c5));
    var c6 = makeCtx(&.{.{ .Double = -2.5 }}, &h, &cap);
    try expectDouble(-2.0, try math_round(&c6));
}

test "min and max widen and propagate NaN" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var c1 = makeCtx(&.{ .{ .Int = 3 }, .{ .Int = 7 } }, &h, &cap);
    try testing.expectEqual(@as(i32, 3), (try math_min(&c1)).ok.Int);

    var c2 = makeCtx(&.{ .{ .Int = 3 }, .{ .Int = 7 } }, &h, &cap);
    try testing.expectEqual(@as(i32, 7), (try math_max(&c2)).ok.Int);

    // Mixed Long/Int widens to Long.
    var c3 = makeCtx(&.{ .{ .Long = 10 }, .{ .Int = 4 } }, &h, &cap);
    const r3 = try math_min(&c3);
    try testing.expect(r3.ok == .Long);
    try testing.expectEqual(@as(i64, 4), r3.ok.Long);

    // Any floating operand promotes to Double; NaN propagates.
    var c4 = makeCtx(&.{ .{ .Double = std.math.nan(f64) }, .{ .Int = 1 } }, &h, &cap);
    const r4 = try math_max(&c4);
    try testing.expect(r4.ok == .Double);
    try testing.expect(std.math.isNan(r4.ok.Double));

    // Non-numeric Comparable (Char) picks by natural order.
    var c5 = makeCtx(&.{ .{ .Char = 'b' }, .{ .Char = 'a' } }, &h, &cap);
    const r5 = try math_min(&c5);
    try testing.expectEqual(@as(u16, 'a'), r5.ok.Char);
}

test "min and max compare unsigned operands by magnitude" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var c1 = makeCtx(&.{ .{ .UInt = 1 }, .{ .UInt = 5 } }, &h, &cap);
    const r1 = try math_max(&c1);
    try testing.expect(r1.ok == .UInt);
    try testing.expectEqual(@as(u32, 5), r1.ok.UInt);

    var c2 = makeCtx(&.{ .{ .UInt = 1 }, .{ .UInt = 5 } }, &h, &cap);
    const r2 = try math_min(&c2);
    try testing.expectEqual(@as(u32, 1), r2.ok.UInt);

    // A high-bit ULong is large, not negative.
    var c3 = makeCtx(&.{ .{ .ULong = 0xFFFF_FFFF_FFFF_FFFF }, .{ .ULong = 3 } }, &h, &cap);
    const r3 = try math_max(&c3);
    try testing.expect(r3.ok == .ULong);
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), r3.ok.ULong);

    // Mixed unsigned kinds widen to the larger kind.
    var c4 = makeCtx(&.{ .{ .UInt = 7 }, .{ .ULong = 2 } }, &h, &cap);
    const r4 = try math_min(&c4);
    try testing.expect(r4.ok == .ULong);
    try testing.expectEqual(@as(u64, 2), r4.ok.ULong);

    var c5 = makeCtx(&.{ .{ .UByte = 9 }, .{ .UByte = 4 } }, &h, &cap);
    const r5 = try math_max(&c5);
    try testing.expect(r5.ok == .UByte);
    try testing.expectEqual(@as(u8, 9), r5.ok.UByte);
}

test "pow for double and float" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var c1 = makeCtx(&.{ .{ .Double = 2.0 }, .{ .Int = 10 } }, &h, &cap);
    try expectDouble(1024.0, try double_pow(&c1));

    var c2 = makeCtx(&.{ .{ .Float = 3.0 }, .{ .Int = 2 } }, &h, &cap);
    const r2 = try float_pow(&c2);
    try testing.expect(r2.ok == .Float);
    try testing.expectApproxEqAbs(@as(f32, 9.0), r2.ok.Float, 1e-5);
}

test "sign preserves signed and NaN zero" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var c1 = makeCtx(&.{.{ .Int = -8 }}, &h, &cap);
    try testing.expectEqual(@as(i32, -1), (try math_sign(&c1)).ok.Int);

    var c2 = makeCtx(&.{.{ .Long = 0 }}, &h, &cap);
    try testing.expectEqual(@as(i32, 0), (try math_sign(&c2)).ok.Int);

    var c3 = makeCtx(&.{.{ .Double = -0.0 }}, &h, &cap);
    const r3 = try math_sign(&c3);
    try testing.expect(r3.ok == .Double);
    try testing.expect(std.math.signbit(r3.ok.Double));
    try testing.expectEqual(@as(f64, 0.0), r3.ok.Double);

    var c4 = makeCtx(&.{.{ .Double = std.math.nan(f64) }}, &h, &cap);
    try testing.expect(std.math.isNan((try math_sign(&c4)).ok.Double));

    var c5 = makeCtx(&.{.{ .Double = 5.0 }}, &h, &cap);
    try expectDouble(1.0, try math_sign(&c5));
}

test "roundToInt and roundToLong clamp and reject NaN" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var c1 = makeCtx(&.{.{ .Double = 2.5 }}, &h, &cap);
    try testing.expectEqual(@as(i32, 3), (try num_round_to_int(&c1)).ok.Int); // half toward +inf

    var c2 = makeCtx(&.{.{ .Double = -2.5 }}, &h, &cap);
    try testing.expectEqual(@as(i32, -2), (try num_round_to_int(&c2)).ok.Int);

    var c3 = makeCtx(&.{.{ .Double = 1e30 }}, &h, &cap);
    try testing.expectEqual(std.math.maxInt(i32), (try num_round_to_int(&c3)).ok.Int);

    var c4 = makeCtx(&.{.{ .Double = std.math.nan(f64) }}, &h, &cap);
    const r4 = try num_round_to_int(&c4);
    try testing.expect(r4 == .err);
    try testing.expect(r4.err == .Thrown);
    freeException(r4.err.Thrown);

    var c5 = makeCtx(&.{.{ .Double = 4.5 }}, &h, &cap);
    try testing.expectEqual(@as(i64, 5), (try num_round_to_long(&c5)).ok.Long);
}

/// Free the refcounted strings backing a freshly-built `Exception` value.
fn freeException(v: Value) void {
    if (v == .Exception) {
        v.Exception.fqn.deinit();
        if (v.Exception.message) |m| m.deinit();
    }
}

test "bit operations" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var c1 = makeCtx(&.{.{ .Int = 0b1010 }}, &h, &cap);
    try testing.expectEqual(@as(i32, 0b1000), (try num_take_highest_one_bit(&c1)).ok.Int);

    var c2 = makeCtx(&.{.{ .Int = 0b1010 }}, &h, &cap);
    try testing.expectEqual(@as(i32, 0b0010), (try num_take_lowest_one_bit(&c2)).ok.Int);

    var c3 = makeCtx(&.{.{ .Int = 0 }}, &h, &cap);
    try testing.expectEqual(@as(i32, 0), (try num_take_highest_one_bit(&c3)).ok.Int);

    // rotateLeft by 4 on a byte-width pattern.
    var c4 = makeCtx(&.{ .{ .Int = 1 }, .{ .Int = 1 } }, &h, &cap);
    try testing.expectEqual(@as(i32, 2), (try num_rotate_left(&c4)).ok.Int);

    var c5 = makeCtx(&.{ .{ .Int = 2 }, .{ .Int = 1 } }, &h, &cap);
    try testing.expectEqual(@as(i32, 1), (try num_rotate_right(&c5)).ok.Int);

    // Negative/over-width shift counts wrap via rem_euclid.
    var c6 = makeCtx(&.{ .{ .Int = 1 }, .{ .Int = 33 } }, &h, &cap);
    try testing.expectEqual(@as(i32, 2), (try num_rotate_left(&c6)).ok.Int);
}

test "float rem and mod sign behavior" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    // rem takes the sign of the dividend.
    var c1 = makeCtx(&.{ .{ .Double = -5.0 }, .{ .Double = 3.0 } }, &h, &cap);
    try expectDouble(-2.0, try num_float_rem(&c1));

    // mod takes the sign of the divisor.
    var c2 = makeCtx(&.{ .{ .Double = -5.0 }, .{ .Double = 3.0 } }, &h, &cap);
    try expectDouble(1.0, try num_float_mod(&c2));

    // Float operands keep a Float result.
    var c3 = makeCtx(&.{ .{ .Float = 5.0 }, .{ .Float = 3.0 } }, &h, &cap);
    const r3 = try num_float_rem(&c3);
    try testing.expect(r3.ok == .Float);
    try testing.expectApproxEqAbs(@as(f32, 2.0), r3.ok.Float, 1e-6);
}

test "hypot atan2 and constants" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var c1 = makeCtx(&.{ .{ .Double = 3.0 }, .{ .Double = 4.0 } }, &h, &cap);
    try expectDouble(5.0, try math_hypot(&c1));

    var c2 = makeCtx(&.{ .{ .Double = 0.0 }, .{ .Double = 1.0 } }, &h, &cap);
    try expectDouble(0.0, try math_atan2(&c2));

    var c3 = makeCtx(&.{}, &h, &cap);
    try expectDouble(std.math.pi, try math_pi(&c3));
    var c4 = makeCtx(&.{}, &h, &cap);
    try expectDouble(std.math.e, try math_e(&c4));
}

test "nextUp nextDown ulp and withSign" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var c1 = makeCtx(&.{.{ .Double = 1.0 }}, &h, &cap);
    const up = (try double_next_up(&c1)).ok.Double;
    try testing.expect(up > 1.0);

    var c2 = makeCtx(&.{.{ .Double = 1.0 }}, &h, &cap);
    const down = (try double_next_down(&c2)).ok.Double;
    try testing.expect(down < 1.0);

    var c3 = makeCtx(&.{.{ .Double = 1.0 }}, &h, &cap);
    const ulp = (try double_ulp(&c3)).ok.Double;
    try testing.expect(ulp > 0.0);
    try testing.expectEqual(up - 1.0, ulp);

    var c4 = makeCtx(&.{ .{ .Double = 3.0 }, .{ .Double = -1.0 } }, &h, &cap);
    try expectDouble(-3.0, try double_with_sign(&c4));
}

test "arity errors carry the name" {
    var h = NoopHost.init(testing.allocator);
    defer h.deinit();
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();

    var c1 = makeCtx(&.{}, &h, &cap);
    const r1 = try math_sqrt(&c1);
    try testing.expect(r1 == .err);
    try testing.expect(r1.err == .Arity);

    var c2 = makeCtx(&.{ .{ .Double = 1.0 }, .{ .Double = 2.0 } }, &h, &cap);
    const r2 = try math_sin(&c2);
    try testing.expect(r2 == .err);
    try testing.expect(r2.err == .Arity);
    testing.allocator.free(r2.err.Arity);
}
