//! Numeric type intrinsics and conversions: the member implementations
//! for `Int`/`Long`/`Short`/`Byte`, the unsigned family, `Float`/`Double`,
//! and `Boolean`, plus the shared bit-count / coercion / floorDiv / mod
//! helpers used across the integer kinds.

const std = @import("std");
const runtime = @import("runtime");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const RuntimeError = runtime.RuntimeError;
const StringRef = runtime.StringRef;

const Allocator = std.mem.Allocator;

// ============================================================
// Local result/helper plumbing
// ============================================================

/// `Result<T, RuntimeError>` for the fallible non-`Value` helpers that
/// the Rust file expresses with `?`. The intrinsics surface OOM as a Zig
/// error and the `RuntimeError` as data via `EvalResult`.
fn Res(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: RuntimeError,
    };
}

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

fn typeErr(allocator: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!RuntimeError {
    return .{ .Type = try std.fmt.allocPrint(allocator, fmt, args) };
}

fn arityErr(allocator: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!RuntimeError {
    return .{ .Arity = try std.fmt.allocPrint(allocator, fmt, args) };
}

/// Build an exception `Value`. Mirrors `implementations::make_exception`.
/// `message`, when present, must be allocator-owned for the program
/// lifetime (the arena), matching Rust's `Arc<String>`.
fn makeException(allocator: Allocator, fqn: []const u8, message: ?[]const u8) Allocator.Error!Value {
    return .{ .Exception = .{
        .fqn = try StringRef.init(allocator, fqn),
        .message = if (message) |m| try StringRef.init(allocator, m) else null,
        .cause = null,
    } };
}

/// Kotlin's `compareTo` total order over floating values. NaN sorts as the
/// greatest value and `-0.0 < 0.0`, unlike the IEEE `<`/`>` operators.
/// Returns `-1`/`0`/`1` to match the Rust `Ordering as i64`/`as i32` casts.
fn kotlinFloatTotalCmp(a: f64, b: f64) i64 {
    if (a < b) return -1;
    if (a > b) return 1;
    const bits = struct {
        fn f(x: f64) i64 {
            if (std.math.isNan(x)) return @bitCast(@as(u64, 0x7ff8_0000_0000_0000));
            return @bitCast(x);
        }
    }.f;
    const ba = bits(a);
    const bb = bits(b);
    if (ba < bb) return -1;
    if (ba > bb) return 1;
    return 0;
}

// ============================================================
// Int members
// ============================================================

fn recvInt(allocator: Allocator, args: []const Value, what: []const u8) Allocator.Error!Res(i64) {
    if (args.len > 0) {
        if (args[0].asI64()) |v| return .{ .ok = v };
    }
    return .{ .err = try typeErr(allocator, "{s} requires an integer receiver", .{what}) };
}

fn recvIntRadix(allocator: Allocator, v: ?Value, what: []const u8) Allocator.Error!Res(i64) {
    if (v == null) return .{ .ok = 10 };
    if (v.?.asI64()) |r| return .{ .ok = r };
    return .{ .err = try typeErr(allocator, "{s} radix must be Int", .{what}) };
}

pub fn int_to_string(ctx: *CallCtx) Allocator.Error!EvalResult {
    const n = switch (try recvInt(ctx.allocator, ctx.args, "Int.toString")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const radix = switch (try recvIntRadix(ctx.allocator, argAt(ctx, 1), "Int.toString")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (!(radix >= 2 and radix <= 36)) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "radix {d} was not in valid range 2..36", .{radix});
        return .{ .err = .{ .Thrown = try makeException(ctx.allocator, "kotlin.IllegalArgumentException", msg) } };
    }
    const s = try intToRadixString(ctx.allocator, n, @intCast(radix));
    return ok(.{ .String = try StringRef.init(ctx.allocator, s) });
}

/// Render `n` in `radix`. Kotlin prefixes a `-` and renders the absolute
/// digit run for negatives; casts through `i128` to handle `i64::MIN`.
pub fn intToRadixString(allocator: Allocator, n: i64, radix: u32) Allocator.Error![]u8 {
    if (n == 0) return allocator.dupe(u8, "0");
    const negative = n < 0;
    var x: u128 = if (negative)
        // unsigned_abs of an i64 widened through i128.
        @intCast(@as(i128, -@as(i128, n)))
    else
        @intCast(n);
    var digits = std.ArrayList(u8).empty;
    defer digits.deinit(allocator);
    const r: u128 = @intCast(radix);
    while (x > 0) {
        const d: u32 = @intCast(x % r);
        x /= r;
        try digits.append(allocator, fromDigit(d));
    }
    if (negative) try digits.append(allocator, '-');
    std.mem.reverse(u8, digits.items);
    return digits.toOwnedSlice(allocator);
}

/// `std::char::from_digit` for `0..=35`.
fn fromDigit(d: u32) u8 {
    if (d < 10) return @intCast('0' + d);
    return @intCast('a' + (d - 10));
}

pub fn int_to_long(ctx: *CallCtx) Allocator.Error!EvalResult {
    return retInt(ctx, "Int.toLong", recvAsLong);
}
pub fn int_to_double(ctx: *CallCtx) Allocator.Error!EvalResult {
    const n = switch (try recvInt(ctx.allocator, ctx.args, "Int.toDouble")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Double = @floatFromInt(n) });
}
pub fn int_to_float(ctx: *CallCtx) Allocator.Error!EvalResult {
    const n = switch (try recvInt(ctx.allocator, ctx.args, "Int.toFloat")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Float = @floatFromInt(n) });
}
pub fn int_to_int(ctx: *CallCtx) Allocator.Error!EvalResult {
    // Identity for Int receivers; truncates Long/Short/Byte if any caller
    // routes through this slot.
    const n = switch (try recvInt(ctx.allocator, ctx.args, "Int.toInt")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(Value.newInt(n));
}
pub fn int_to_short(ctx: *CallCtx) Allocator.Error!EvalResult {
    const n = switch (try recvInt(ctx.allocator, ctx.args, "Int.toShort")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(Value.newShort(n));
}
pub fn int_to_byte(ctx: *CallCtx) Allocator.Error!EvalResult {
    const n = switch (try recvInt(ctx.allocator, ctx.args, "Int.toByte")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(Value.newByte(n));
}

// Long-only conversion methods (when the receiver is `Value::Long`).
// These intentionally mirror the Int-family — `recvInt` widens any
// integral receiver to i64, so they cover Long, Int, Short, Byte.
pub fn long_to_long(ctx: *CallCtx) Allocator.Error!EvalResult {
    return retInt(ctx, "Long.toLong", recvAsLong);
}
pub fn long_to_int(ctx: *CallCtx) Allocator.Error!EvalResult {
    const n = switch (try recvInt(ctx.allocator, ctx.args, "Long.toInt")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(Value.newInt(n));
}
pub fn long_to_short(ctx: *CallCtx) Allocator.Error!EvalResult {
    const n = switch (try recvInt(ctx.allocator, ctx.args, "Long.toShort")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(Value.newShort(n));
}
pub fn long_to_byte(ctx: *CallCtx) Allocator.Error!EvalResult {
    const n = switch (try recvInt(ctx.allocator, ctx.args, "Long.toByte")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(Value.newByte(n));
}
pub fn long_to_double(ctx: *CallCtx) Allocator.Error!EvalResult {
    const n = switch (try recvInt(ctx.allocator, ctx.args, "Long.toDouble")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Double = @floatFromInt(n) });
}
pub fn long_to_float(ctx: *CallCtx) Allocator.Error!EvalResult {
    const n = switch (try recvInt(ctx.allocator, ctx.args, "Long.toFloat")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Float = @floatFromInt(n) });
}

// Shared tail for `to_long`-shaped intrinsics.
fn recvAsLong(n: i64) Value {
    return .{ .Long = n };
}
fn retInt(ctx: *CallCtx, what: []const u8, build: *const fn (i64) Value) Allocator.Error!EvalResult {
    const n = switch (try recvInt(ctx.allocator, ctx.args, what)) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(build(n));
}

fn recvUnsigned(allocator: Allocator, args: []const Value, what: []const u8) Allocator.Error!Res(u64) {
    if (args.len > 0) {
        if (args[0].asU64()) |v| return .{ .ok = v };
    }
    return .{ .err = try typeErr(allocator, "{s} requires an integer receiver", .{what}) };
}

pub fn to_ubyte(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = switch (try recvUnsigned(ctx.allocator, ctx.args, "toUByte")) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .UByte = @truncate(v) });
}
pub fn to_ushort(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = switch (try recvUnsigned(ctx.allocator, ctx.args, "toUShort")) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .UShort = @truncate(v) });
}
pub fn to_uint(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = switch (try recvUnsigned(ctx.allocator, ctx.args, "toUInt")) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .UInt = @truncate(v) });
}
pub fn to_ulong(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = switch (try recvUnsigned(ctx.allocator, ctx.args, "toULong")) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .ULong = v });
}
pub fn unsigned_to_int(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = switch (try recvUnsigned(ctx.allocator, ctx.args, "toInt")) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    return ok(Value.newInt(@bitCast(v)));
}
pub fn unsigned_to_long(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = switch (try recvUnsigned(ctx.allocator, ctx.args, "toLong")) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Long = @bitCast(v) });
}
pub fn unsigned_to_short(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = switch (try recvUnsigned(ctx.allocator, ctx.args, "toShort")) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    return ok(Value.newShort(@bitCast(v)));
}
pub fn unsigned_to_byte(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = switch (try recvUnsigned(ctx.allocator, ctx.args, "toByte")) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    return ok(Value.newByte(@bitCast(v)));
}
pub fn unsigned_to_double(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = switch (try recvUnsigned(ctx.allocator, ctx.args, "toDouble")) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Double = @floatFromInt(v) });
}
pub fn unsigned_to_float(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = switch (try recvUnsigned(ctx.allocator, ctx.args, "toFloat")) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Float = @floatFromInt(v) });
}
pub fn unsigned_to_string(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = switch (try recvUnsigned(ctx.allocator, ctx.args, "toString")) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    const s = try std.fmt.allocPrint(ctx.allocator, "{d}", .{v});
    return ok(.{ .String = try StringRef.init(ctx.allocator, s) });
}

// ============================================================
// Float receiver conversions
// ============================================================

pub fn float_to_double(ctx: *CallCtx) Allocator.Error!EvalResult {
    const f = switch (try recvFloat(ctx.allocator, ctx.args, "Float.toDouble")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Double = @floatCast(f) });
}
pub fn float_to_float(ctx: *CallCtx) Allocator.Error!EvalResult {
    const f = switch (try recvFloat(ctx.allocator, ctx.args, "Float.toFloat")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Float = f });
}
pub fn float_to_int(ctx: *CallCtx) Allocator.Error!EvalResult {
    const f = switch (try recvFloat(ctx.allocator, ctx.args, "Float.toInt")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(Value.newInt(f32ToI32Kotlin(f)));
}
pub fn float_to_long(ctx: *CallCtx) Allocator.Error!EvalResult {
    const f = switch (try recvFloat(ctx.allocator, ctx.args, "Float.toLong")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Long = f32ToI64Kotlin(f) });
}
pub fn float_to_short(ctx: *CallCtx) Allocator.Error!EvalResult {
    const f = switch (try recvFloat(ctx.allocator, ctx.args, "Float.toShort")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(Value.newShort(f32ToI32Kotlin(f)));
}
pub fn float_to_byte(ctx: *CallCtx) Allocator.Error!EvalResult {
    const f = switch (try recvFloat(ctx.allocator, ctx.args, "Float.toByte")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(Value.newByte(f32ToI32Kotlin(f)));
}

pub fn float_to_string(ctx: *CallCtx) Allocator.Error!EvalResult {
    const d = switch (try recvFloat(ctx.allocator, ctx.args, "Float.toString")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const s = try runtime.kotlinFloatToString(ctx.allocator, d);
    return ok(.{ .String = try StringRef.init(ctx.allocator, s) });
}
pub fn float_is_nan(ctx: *CallCtx) Allocator.Error!EvalResult {
    const f = switch (try recvFloat(ctx.allocator, ctx.args, "Float.isNaN")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Bool = std.math.isNan(f) });
}
pub fn float_is_infinite(ctx: *CallCtx) Allocator.Error!EvalResult {
    const f = switch (try recvFloat(ctx.allocator, ctx.args, "Float.isInfinite")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Bool = std.math.isInf(f) });
}
pub fn float_is_finite(ctx: *CallCtx) Allocator.Error!EvalResult {
    const f = switch (try recvFloat(ctx.allocator, ctx.args, "Float.isFinite")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Bool = std.math.isFinite(f) });
}
pub fn float_compare_to(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = switch (try recvFloat(ctx.allocator, ctx.args, "Float.compareTo")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const b = blk: {
        if (argAt(ctx, 1)) |arg| {
            if (arg.asF32()) |v| break :blk v;
        }
        return .{ .err = .{ .Type = "Float.compareTo requires a number" } };
    };
    // `compareTo` is a total order (NaN greatest, -0.0 < 0.0), unlike the
    // IEEE `<`/`>` operators.
    return ok(Value.newInt(kotlinFloatTotalCmp(@floatCast(a), @floatCast(b))));
}

// ============================================================
// Double additional conversions (Float)
// ============================================================

pub fn double_to_float(ctx: *CallCtx) Allocator.Error!EvalResult {
    const d = switch (try recvDouble(ctx.allocator, ctx.args, "Double.toFloat")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Float = @floatCast(d) });
}
pub fn double_to_double(ctx: *CallCtx) Allocator.Error!EvalResult {
    const d = switch (try recvDouble(ctx.allocator, ctx.args, "Double.toDouble")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Double = d });
}
pub fn double_to_short(ctx: *CallCtx) Allocator.Error!EvalResult {
    const d = switch (try recvDouble(ctx.allocator, ctx.args, "Double.toShort")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(Value.newShort(f64ToI32Kotlin(d)));
}
pub fn double_to_byte(ctx: *CallCtx) Allocator.Error!EvalResult {
    const d = switch (try recvDouble(ctx.allocator, ctx.args, "Double.toByte")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(Value.newByte(f64ToI32Kotlin(d)));
}

// ============================================================
// Integer bit / arithmetic binops
// ============================================================

fn intBinop(
    ctx: *CallCtx,
    what: []const u8,
    op: *const fn (i32, i32) i32,
) Allocator.Error!EvalResult {
    const a64 = switch (try recvInt(ctx.allocator, ctx.args, what)) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const a: i32 = @truncate(a64);
    const b64 = blk: {
        if (argAt(ctx, 1)) |arg| {
            if (arg.asI64()) |v| break :blk v;
        }
        return .{ .err = try typeErr(ctx.allocator, "{s} requires an Int argument", .{what}) };
    };
    return ok(Value.newInt(op(a, @truncate(b64))));
}

fn opAnd(a: i32, b: i32) i32 {
    return a & b;
}
fn opOr(a: i32, b: i32) i32 {
    return a | b;
}
fn opXor(a: i32, b: i32) i32 {
    return a ^ b;
}
fn opShl(a: i32, b: i32) i32 {
    const amt: u5 = @intCast(b & 31);
    return @bitCast(@as(u32, @bitCast(a)) << amt);
}
fn opShr(a: i32, b: i32) i32 {
    const amt: u5 = @intCast(b & 31);
    return a >> amt;
}
fn opUshr(a: i32, b: i32) i32 {
    const amt: u5 = @intCast(b & 31);
    return @bitCast(@as(u32, @bitCast(a)) >> amt);
}

pub fn int_and(ctx: *CallCtx) Allocator.Error!EvalResult {
    return intBinop(ctx, "Int.and", opAnd);
}
pub fn int_or(ctx: *CallCtx) Allocator.Error!EvalResult {
    return intBinop(ctx, "Int.or", opOr);
}
pub fn int_xor(ctx: *CallCtx) Allocator.Error!EvalResult {
    return intBinop(ctx, "Int.xor", opXor);
}
pub fn int_inv(ctx: *CallCtx) Allocator.Error!EvalResult {
    const n = switch (try recvInt(ctx.allocator, ctx.args, "Int.inv")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(Value.newInt(~n));
}
pub fn int_shl(ctx: *CallCtx) Allocator.Error!EvalResult {
    return intBinop(ctx, "Int.shl", opShl);
}
pub fn int_shr(ctx: *CallCtx) Allocator.Error!EvalResult {
    return intBinop(ctx, "Int.shr", opShr);
}
pub fn int_ushr(ctx: *CallCtx) Allocator.Error!EvalResult {
    return intBinop(ctx, "Int.ushr", opUshr);
}

fn longBinop(
    ctx: *CallCtx,
    what: []const u8,
    op: *const fn (i64, i64) i64,
) Allocator.Error!EvalResult {
    const a = switch (try recvInt(ctx.allocator, ctx.args, what)) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const b = blk: {
        if (argAt(ctx, 1)) |arg| {
            if (arg.asI64()) |v| break :blk v;
        }
        return .{ .err = try typeErr(ctx.allocator, "{s} requires a Long argument", .{what}) };
    };
    return ok(.{ .Long = op(a, b) });
}

fn lopAnd(a: i64, b: i64) i64 {
    return a & b;
}
fn lopOr(a: i64, b: i64) i64 {
    return a | b;
}
fn lopXor(a: i64, b: i64) i64 {
    return a ^ b;
}
fn lopShl(a: i64, b: i64) i64 {
    const amt: u6 = @intCast(b & 63);
    return @bitCast(@as(u64, @bitCast(a)) << amt);
}
fn lopShr(a: i64, b: i64) i64 {
    const amt: u6 = @intCast(b & 63);
    return a >> amt;
}
fn lopUshr(a: i64, b: i64) i64 {
    const amt: u6 = @intCast(b & 63);
    return @bitCast(@as(u64, @bitCast(a)) >> amt);
}

pub fn long_and(ctx: *CallCtx) Allocator.Error!EvalResult {
    return longBinop(ctx, "Long.and", lopAnd);
}
pub fn long_or(ctx: *CallCtx) Allocator.Error!EvalResult {
    return longBinop(ctx, "Long.or", lopOr);
}
pub fn long_xor(ctx: *CallCtx) Allocator.Error!EvalResult {
    return longBinop(ctx, "Long.xor", lopXor);
}
pub fn long_inv(ctx: *CallCtx) Allocator.Error!EvalResult {
    const n = switch (try recvInt(ctx.allocator, ctx.args, "Long.inv")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Long = ~n });
}
pub fn long_shl(ctx: *CallCtx) Allocator.Error!EvalResult {
    return longBinop(ctx, "Long.shl", lopShl);
}
pub fn long_shr(ctx: *CallCtx) Allocator.Error!EvalResult {
    return longBinop(ctx, "Long.shr", lopShr);
}
pub fn long_ushr(ctx: *CallCtx) Allocator.Error!EvalResult {
    return longBinop(ctx, "Long.ushr", lopUshr);
}

pub fn long_to_string(ctx: *CallCtx) Allocator.Error!EvalResult {
    const n = switch (try recvInt(ctx.allocator, ctx.args, "Long.toString")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const radix = switch (try recvIntRadix(ctx.allocator, argAt(ctx, 1), "Long.toString")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    if (!(radix >= 2 and radix <= 36)) {
        const msg = try std.fmt.allocPrint(ctx.allocator, "radix {d} was not in valid range 2..36", .{radix});
        return .{ .err = .{ .Thrown = try makeException(ctx.allocator, "kotlin.IllegalArgumentException", msg) } };
    }
    const s = try intToRadixString(ctx.allocator, n, @intCast(radix));
    return ok(.{ .String = try StringRef.init(ctx.allocator, s) });
}

pub fn long_compare_to(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = switch (try recvInt(ctx.allocator, ctx.args, "Long.compareTo")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const b = blk: {
        if (argAt(ctx, 1)) |arg| {
            if (arg.asI64()) |v| break :blk v;
        }
        return .{ .err = .{ .Type = "Long.compareTo requires a Long" } };
    };
    return ok(.{ .Int = if (a < b) -1 else @intFromBool(a > b) });
}
pub fn int_compare_to(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = switch (try recvInt(ctx.allocator, ctx.args, "Int.compareTo")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const b = blk: {
        if (argAt(ctx, 1)) |arg| {
            if (arg.asI64()) |v| break :blk v;
        }
        return .{ .err = .{ .Type = "Int.compareTo requires an Int" } };
    };
    return ok(.{ .Int = if (a < b) -1 else @intFromBool(a > b) });
}

// ============================================================
// Double members
// ============================================================

fn recvDouble(allocator: Allocator, args: []const Value, what: []const u8) Allocator.Error!Res(f64) {
    if (args.len > 0) {
        if (args[0].asF64()) |v| return .{ .ok = v };
    }
    return .{ .err = try typeErr(allocator, "{s} requires a numeric receiver", .{what}) };
}

fn recvFloat(allocator: Allocator, args: []const Value, what: []const u8) Allocator.Error!Res(f32) {
    if (args.len > 0) {
        if (args[0].asF32()) |v| return .{ .ok = v };
    }
    return .{ .err = try typeErr(allocator, "{s} requires a numeric receiver", .{what}) };
}

pub fn double_to_string(ctx: *CallCtx) Allocator.Error!EvalResult {
    const d = switch (try recvDouble(ctx.allocator, ctx.args, "Double.toString")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const s = try runtime.kotlinDoubleToString(ctx.allocator, d);
    return ok(.{ .String = try StringRef.init(ctx.allocator, s) });
}
pub fn double_to_int(ctx: *CallCtx) Allocator.Error!EvalResult {
    const d = switch (try recvDouble(ctx.allocator, ctx.args, "Double.toInt")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(Value.newInt(f64ToI32Kotlin(d)));
}
pub fn double_to_long(ctx: *CallCtx) Allocator.Error!EvalResult {
    const d = switch (try recvDouble(ctx.allocator, ctx.args, "Double.toLong")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Long = f64ToI64Kotlin(d) });
}

/// Kotlin's `Double.toInt` semantics: truncate toward zero, saturate at
/// `Int.MIN_VALUE`/`Int.MAX_VALUE` for out-of-range, `NaN -> 0`.
pub fn f64ToI32Kotlin(d: f64) i32 {
    if (std.math.isNan(d)) return 0;
    // `f64::from(i32::MAX)` / `f64::from(i32::MIN)` — both exact in f64.
    const hi: f64 = @floatFromInt(@as(i32, std.math.maxInt(i32)));
    const lo: f64 = @floatFromInt(@as(i32, std.math.minInt(i32)));
    if (d >= hi) return std.math.maxInt(i32);
    if (d <= lo) return std.math.minInt(i32);
    return @intFromFloat(@trunc(d));
}

pub fn f64ToI64Kotlin(d: f64) i64 {
    if (std.math.isNan(d)) return 0;
    // `i64::MAX as f64` rounds up to 2^63; `i64::MIN as f64` is exact.
    const hi: f64 = @floatFromInt(@as(i64, std.math.maxInt(i64)));
    const lo: f64 = @floatFromInt(@as(i64, std.math.minInt(i64)));
    if (d >= hi) return std.math.maxInt(i64);
    if (d <= lo) return std.math.minInt(i64);
    return @intFromFloat(@trunc(d));
}

pub fn f32ToI32Kotlin(d: f32) i32 {
    if (std.math.isNan(d)) return 0;
    const hi: f32 = @floatFromInt(@as(i32, std.math.maxInt(i32)));
    const lo: f32 = @floatFromInt(@as(i32, std.math.minInt(i32)));
    if (d >= hi) return std.math.maxInt(i32);
    if (d <= lo) return std.math.minInt(i32);
    return @intFromFloat(@trunc(d));
}

pub fn f32ToI64Kotlin(d: f32) i64 {
    if (std.math.isNan(d)) return 0;
    const hi: f32 = @floatFromInt(@as(i64, std.math.maxInt(i64)));
    const lo: f32 = @floatFromInt(@as(i64, std.math.minInt(i64)));
    if (d >= hi) return std.math.maxInt(i64);
    if (d <= lo) return std.math.minInt(i64);
    return @intFromFloat(@trunc(d));
}

pub fn double_is_nan(ctx: *CallCtx) Allocator.Error!EvalResult {
    const d = switch (try recvDouble(ctx.allocator, ctx.args, "Double.isNaN")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Bool = std.math.isNan(d) });
}

// IEEE-754 bit reflection. `toRawBits` preserves the exact bit pattern;
// `toBits` collapses every NaN to the single canonical quiet NaN
// (matching `java.lang.Double.doubleToLongBits`/`Float.floatToIntBits`);
// `fromBits` reconstructs the value.
pub fn double_to_raw_bits(ctx: *CallCtx) Allocator.Error!EvalResult {
    const d = switch (try recvDouble(ctx.allocator, ctx.args, "Double.toRawBits")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Long = @bitCast(d) });
}
pub fn double_to_bits(ctx: *CallCtx) Allocator.Error!EvalResult {
    const d = switch (try recvDouble(ctx.allocator, ctx.args, "Double.toBits")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const bits: u64 = if (std.math.isNan(d)) 0x7ff8_0000_0000_0000 else @bitCast(d);
    return ok(.{ .Long = @bitCast(bits) });
}
pub fn double_from_bits(ctx: *CallCtx) Allocator.Error!EvalResult {
    const bits = blk: {
        var i: usize = ctx.args.len;
        while (i > 0) {
            i -= 1;
            if (ctx.args[i].asI64()) |v| break :blk v;
        }
        return .{ .err = .{ .Type = "Double.fromBits requires a Long" } };
    };
    return ok(.{ .Double = @bitCast(bits) });
}
pub fn float_to_raw_bits(ctx: *CallCtx) Allocator.Error!EvalResult {
    const f = switch (try recvFloat(ctx.allocator, ctx.args, "Float.toRawBits")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const u: u32 = @bitCast(f);
    const i: i32 = @bitCast(u);
    return ok(Value.newInt(@as(i64, i)));
}
pub fn float_to_bits(ctx: *CallCtx) Allocator.Error!EvalResult {
    const f = switch (try recvFloat(ctx.allocator, ctx.args, "Float.toBits")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const u: u32 = if (std.math.isNan(f)) 0x7fc0_0000 else @bitCast(f);
    const i: i32 = @bitCast(u);
    return ok(Value.newInt(@as(i64, i)));
}
pub fn float_from_bits(ctx: *CallCtx) Allocator.Error!EvalResult {
    const bits = blk: {
        var i: usize = ctx.args.len;
        while (i > 0) {
            i -= 1;
            if (ctx.args[i].asI64()) |v| break :blk v;
        }
        return .{ .err = .{ .Type = "Float.fromBits requires an Int" } };
    };
    // Kotlin Float.fromBits narrows the Int to its low 32 bits.
    const u: u32 = @truncate(@as(u64, @bitCast(bits)));
    return ok(.{ .Float = @bitCast(u) });
}
pub fn double_is_infinite(ctx: *CallCtx) Allocator.Error!EvalResult {
    const d = switch (try recvDouble(ctx.allocator, ctx.args, "Double.isInfinite")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Bool = std.math.isInf(d) });
}
pub fn double_is_finite(ctx: *CallCtx) Allocator.Error!EvalResult {
    const d = switch (try recvDouble(ctx.allocator, ctx.args, "Double.isFinite")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Bool = std.math.isFinite(d) });
}
pub fn double_compare_to(ctx: *CallCtx) Allocator.Error!EvalResult {
    const a = switch (try recvDouble(ctx.allocator, ctx.args, "Double.compareTo")) {
        .ok => |v| v,
        .err => |e| return .{ .err = e },
    };
    const b = blk: {
        if (argAt(ctx, 1)) |arg| {
            if (arg.asF64()) |v| break :blk v;
        }
        return .{ .err = .{ .Type = "Double.compareTo requires a number" } };
    };
    // `compareTo` is a total order (NaN greatest, -0.0 < 0.0), unlike the
    // IEEE `<`/`>` operators.
    return ok(.{ .Int = @intCast(kotlinFloatTotalCmp(a, b)) });
}

// ============================================================
// Boolean members
// ============================================================

pub fn bool_to_string(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args[0] != .Bool) {
        return .{ .err = .{ .Type = "Boolean.toString requires a Boolean" } };
    }
    const b = ctx.args[0].Bool;
    return ok(.{ .String = try StringRef.init(ctx.allocator, if (b) "true" else "false") });
}

// ============================================================
// Additional Int
// ============================================================

pub fn int_coerce_in(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = switch (try recvInt(ctx.allocator, ctx.args, "Int.coerceIn")) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    const rest = ctx.args[@min(1, ctx.args.len)..];
    if (rest.len == 1 and rest[0] == .Range) {
        const r = rest[0].Range;
        return ok(Value.newInt(@min(@max(v, r.start), r.end)));
    }
    if (rest.len == 2 and rest[0].isIntegral() and rest[1].isIntegral()) {
        const lo = rest[0].asI64().?;
        const hi = rest[1].asI64().?;
        return ok(Value.newInt(@min(@max(v, lo), hi)));
    }
    return .{ .err = .{ .Type = "coerceIn requires (min, max) or a range" } };
}

pub fn int_coerce_at_least(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = switch (try recvInt(ctx.allocator, ctx.args, "Int.coerceAtLeast")) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    const lo = blk: {
        if (argAt(ctx, 1)) |arg| {
            if (arg.asI64()) |x| break :blk x;
        }
        return .{ .err = .{ .Type = "coerceAtLeast requires an Int" } };
    };
    return ok(Value.newInt(@max(v, lo)));
}

pub fn int_coerce_at_most(ctx: *CallCtx) Allocator.Error!EvalResult {
    const v = switch (try recvInt(ctx.allocator, ctx.args, "Int.coerceAtMost")) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    const hi = blk: {
        if (argAt(ctx, 1)) |arg| {
            if (arg.asI64()) |x| break :blk x;
        }
        return .{ .err = .{ .Type = "coerceAtMost requires an Int" } };
    };
    return ok(Value.newInt(@min(v, hi)));
}

/// `Int`/`Long`.`countLeadingZeroBits()` — leading zeros in the
/// two's-complement bit pattern (32 / 64 wide). Result is Int.
pub fn num_count_leading_zero_bits(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len == 0) {
        return .{ .err = .{ .Arity = "countLeadingZeroBits" } };
    }
    const n: i32 = switch (ctx.args[0]) {
        .Long => |v| @clz(@as(u64, @bitCast(v))),
        .Int => |v| @clz(@as(u32, @bitCast(v))),
        .Short => |v| @clz(@as(u16, @bitCast(v))),
        .Byte => |v| @clz(@as(u8, @bitCast(v))),
        else => return .{ .err = try countTypeErr(ctx.allocator, "countLeadingZeroBits", ctx.args[0]) },
    };
    return ok(Value.newInt(@as(i64, n)));
}

/// `Int`/`Long`.`countTrailingZeroBits()`.
pub fn num_count_trailing_zero_bits(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len == 0) {
        return .{ .err = .{ .Arity = "countTrailingZeroBits" } };
    }
    const n: i32 = switch (ctx.args[0]) {
        .Long => |v| @ctz(@as(u64, @bitCast(v))),
        .Int => |v| @ctz(@as(u32, @bitCast(v))),
        .Short => |v| @min(@as(i32, @ctz(@as(u16, @bitCast(v)))), 16),
        .Byte => |v| @min(@as(i32, @ctz(@as(u8, @bitCast(v)))), 8),
        else => return .{ .err = try countTypeErr(ctx.allocator, "countTrailingZeroBits", ctx.args[0]) },
    };
    return ok(Value.newInt(@as(i64, n)));
}

/// `Int`/`Long`.`countOneBits()` (population count).
pub fn num_count_one_bits(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len == 0) {
        return .{ .err = .{ .Arity = "countOneBits" } };
    }
    const n: i32 = switch (ctx.args[0]) {
        .Long => |v| @popCount(@as(u64, @bitCast(v))),
        .Int => |v| @popCount(@as(u32, @bitCast(v))),
        .Short => |v| @popCount(@as(u16, @bitCast(v))),
        .Byte => |v| @popCount(@as(u8, @bitCast(v))),
        else => return .{ .err = try countTypeErr(ctx.allocator, "countOneBits", ctx.args[0]) },
    };
    return ok(Value.newInt(@as(i64, n)));
}

/// Render the `{what} requires an integer, got {other:?}` type error.
/// The Rust `{other:?}` debug form is the variant tag name.
fn countTypeErr(allocator: Allocator, what: []const u8, other: Value) Allocator.Error!RuntimeError {
    return typeErr(allocator, "{s} requires an integer, got {s}", .{ what, @tagName(other) });
}

pub fn num_floor_div(ctx: *CallCtx) Allocator.Error!EvalResult {
    const pair = switch (try arg2(ctx.allocator, ctx, "floorDiv")) {
        .ok => |p| p,
        .err => |e| return .{ .err = e },
    };
    const lhs = pair[0];
    const rhs = pair[1];
    const dividend = lhs.asI64() orelse return .{ .err = .{ .Type = "floorDiv requires integers" } };
    const divisor = rhs.asI64() orelse return .{ .err = .{ .Type = "floorDiv requires integers" } };
    if (divisor == 0) {
        return .{ .err = .{ .Thrown = try makeException(ctx.allocator, "kotlin.ArithmeticException", "/ by zero") } };
    }
    var quotient = @divTrunc(dividend, divisor);
    const rem = @rem(dividend, divisor);
    if (rem != 0 and ((rem < 0) != (divisor < 0))) {
        quotient -= 1;
    }
    const wide = lhs == .Long or rhs == .Long;
    return ok(if (wide) Value{ .Long = quotient } else Value.newInt(quotient));
}

/// `Int`/`Long`/… `mod` — remainder whose sign follows the divisor
/// (Kotlin's `mod`, distinct from `%` whose sign follows the dividend).
/// Result widens to `Long` if either operand is `Long`.
pub fn num_mod(ctx: *CallCtx) Allocator.Error!EvalResult {
    const pair = switch (try arg2(ctx.allocator, ctx, "mod")) {
        .ok => |p| p,
        .err => |e| return .{ .err = e },
    };
    const lhs = pair[0];
    const rhs = pair[1];
    const dividend = lhs.asI64() orelse return .{ .err = .{ .Type = "mod requires integers" } };
    const divisor = rhs.asI64() orelse return .{ .err = .{ .Type = "mod requires integers" } };
    if (divisor == 0) {
        return .{ .err = .{ .Thrown = try makeException(ctx.allocator, "kotlin.ArithmeticException", "/ by zero") } };
    }
    var rem = @rem(dividend, divisor);
    if (rem != 0 and ((rem < 0) != (divisor < 0))) {
        rem += divisor;
    }
    const wide = lhs == .Long or rhs == .Long;
    return ok(if (wide) Value{ .Long = rem } else Value.newInt(rem));
}

// ============================================================
// num coerce family (Long / Double receivers)
// ============================================================

/// Numeric `min`/`max` over a Kotlin number pair, mirroring
/// `math::num_extreme`. Integral pairs widen to the larger kind (Long if
/// either is Long, else Int); any floating operand promotes to Double and
/// propagates NaN (Math.min/max semantics).
fn numExtreme(allocator: Allocator, args: []const Value, want_min: bool, what: []const u8) Allocator.Error!Res(Value) {
    if (args.len != 2) {
        return .{ .err = try arityErr(allocator, "{s} expects 2 arguments", .{what}) };
    }
    const first = args[0];
    const second = args[1];
    const floating = first == .Double or first == .Float or second == .Double or second == .Float;
    if (floating) {
        const x = numericAsF64(first) orelse return .{ .err = try typeErr(allocator, "{s}: non-numeric arg", .{what}) };
        const y = numericAsF64(second) orelse return .{ .err = try typeErr(allocator, "{s}: non-numeric arg", .{what}) };
        // Kotlin's minOf/maxOf use Math.min/max, which propagate NaN.
        const r: f64 = if (std.math.isNan(x) or std.math.isNan(y))
            std.math.nan(f64)
        else if (want_min)
            @min(x, y)
        else
            @max(x, y);
        return .{ .ok = .{ .Double = r } };
    }
    const x = numericAsI64(first) orelse return .{ .err = try typeErr(allocator, "{s}: non-numeric arg", .{what}) };
    const y = numericAsI64(second) orelse return .{ .err = try typeErr(allocator, "{s}: non-numeric arg", .{what}) };
    const r = if (want_min) @min(x, y) else @max(x, y);
    if (first == .Long or second == .Long) {
        return .{ .ok = .{ .Long = r } };
    }
    return .{ .ok = Value.newInt(r) };
}

/// Mirror of `math::numeric_as_i64` (Int/Long/Short/Byte only).
fn numericAsI64(v: Value) ?i64 {
    return switch (v) {
        .Int => |x| @as(i64, x),
        .Long => |x| x,
        .Short => |x| @as(i64, x),
        .Byte => |x| @as(i64, x),
        else => null,
    };
}

/// Mirror of `math::numeric_as_f64` (signed integers + float/double).
fn numericAsF64(v: Value) ?f64 {
    return switch (v) {
        .Int => |x| @floatFromInt(x),
        .Long => |x| @floatFromInt(x),
        .Short => |x| @floatFromInt(x),
        .Byte => |x| @floatFromInt(x),
        .Float => |x| @as(f64, x),
        .Double => |x| x,
        else => null,
    };
}

pub fn num_coerce_in(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len == 0) {
        return .{ .err = .{ .Arity = "coerceIn: missing receiver" } };
    }
    const recv = ctx.args[0];
    const rest = ctx.args[1..];
    if (rest.len == 1 and rest[0] == .Range) {
        const r = rest[0].Range;
        const lo = switch (try numExtreme(ctx.allocator, &.{ recv, .{ .Long = r.start } }, false, "coerceIn")) {
            .ok => |v| v,
            .err => |e| return .{ .err = e },
        };
        return wrapRes(try numExtreme(ctx.allocator, &.{ lo, .{ .Long = r.end } }, true, "coerceIn"));
    }
    if (rest.len == 2) {
        const lo = switch (try numExtreme(ctx.allocator, &.{ recv, rest[0] }, false, "coerceIn")) {
            .ok => |v| v,
            .err => |e| return .{ .err = e },
        };
        return wrapRes(try numExtreme(ctx.allocator, &.{ lo, rest[1] }, true, "coerceIn"));
    }
    return .{ .err = .{ .Type = "coerceIn requires (min, max) or a range" } };
}

pub fn num_coerce_at_least(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len == 0) {
        return .{ .err = .{ .Arity = "coerceAtLeast: missing receiver" } };
    }
    const recv = ctx.args[0];
    if (ctx.args.len < 2) {
        return .{ .err = .{ .Arity = "coerceAtLeast requires a minimum" } };
    }
    const min = ctx.args[1];
    return wrapRes(try numExtreme(ctx.allocator, &.{ recv, min }, false, "coerceAtLeast"));
}

pub fn num_coerce_at_most(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len == 0) {
        return .{ .err = .{ .Arity = "coerceAtMost: missing receiver" } };
    }
    const recv = ctx.args[0];
    if (ctx.args.len < 2) {
        return .{ .err = .{ .Arity = "coerceAtMost requires a maximum" } };
    }
    const max = ctx.args[1];
    return wrapRes(try numExtreme(ctx.allocator, &.{ recv, max }, true, "coerceAtMost"));
}

fn wrapRes(r: Res(Value)) EvalResult {
    return switch (r) {
        .ok => |v| .{ .ok = v },
        .err => |e| .{ .err = e },
    };
}

pub fn int_to_char(ctx: *CallCtx) Allocator.Error!EvalResult {
    // Kotlin's `Int.toChar()` is a narrowing conversion: it keeps the low
    // 16 bits (the resulting UTF-16 code unit), never throwing.
    const v = switch (try recvInt(ctx.allocator, ctx.args, "Int.toChar")) {
        .ok => |x| x,
        .err => |e| return .{ .err = e },
    };
    return ok(.{ .Char = @truncate(@as(u64, @bitCast(v))) });
}

// ============================================================
// Argument helpers
// ============================================================

/// `ctx.args.get(i)` — the i-th argument, or null when out of range.
fn argAt(ctx: *CallCtx, i: usize) ?Value {
    if (i < ctx.args.len) return ctx.args[i];
    return null;
}

/// Mirror of `math::arg2`: require exactly two arguments.
fn arg2(allocator: Allocator, ctx: *CallCtx, what: []const u8) Allocator.Error!Res([2]Value) {
    if (ctx.args.len != 2) {
        return .{ .err = try arityErr(allocator, "{s} expects 2 arguments", .{what}) };
    }
    return .{ .ok = .{ ctx.args[0], ctx.args[1] } };
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

/// Per-test arena so intrinsics can allocate (strings, exception cells,
/// formatted diagnostics) without per-value frees — matching the real
/// runtime's arena-per-phase ownership.
const Harness = struct {
    arena: std.heap.ArenaAllocator,

    fn init() Harness {
        return .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }
    fn deinit(self: *Harness) void {
        self.arena.deinit();
    }
    fn ctx(self: *Harness, args: []const Value) CallCtx {
        return .{
            .args = args,
            .out = undefined,
            .host = undefined,
            .allocator = self.arena.allocator(),
        };
    }
};

fn expectValue(res: EvalResult, expected: Value) !void {
    switch (res) {
        .ok => |v| {
            try testing.expect(Value.structuralEq(&v, &expected));
        },
        .err => return error.UnexpectedError,
    }
}

test "int_to_radix_string renders bases and negatives" {
    const s10 = try intToRadixString(testing.allocator, 255, 10);
    defer testing.allocator.free(s10);
    try testing.expectEqualStrings("255", s10);

    const s16 = try intToRadixString(testing.allocator, 255, 16);
    defer testing.allocator.free(s16);
    try testing.expectEqualStrings("ff", s16);

    const sneg = try intToRadixString(testing.allocator, -255, 16);
    defer testing.allocator.free(sneg);
    try testing.expectEqualStrings("-ff", sneg);

    const szero = try intToRadixString(testing.allocator, 0, 2);
    defer testing.allocator.free(szero);
    try testing.expectEqualStrings("0", szero);
}

test "int_to_radix_string handles i64::MIN" {
    const s = try intToRadixString(testing.allocator, std.math.minInt(i64), 10);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("-9223372036854775808", s);
}

test "int_to_string rejects out-of-range radix" {
    var h = Harness.init();
    defer h.deinit();
    var ctx = h.ctx(&.{ Value.newInt(10), Value.newInt(1) });
    const res = try int_to_string(&ctx);
    switch (res) {
        .ok => return error.ExpectedError,
        .err => |e| switch (e) {
            .Thrown => |v| {
                try testing.expect(v == .Exception);
                const g = v.Exception.fqn.borrow();
                defer g.deinit();
                try testing.expectEqualStrings("kotlin.IllegalArgumentException", g.get().*);
                const mg = v.Exception.message.?.borrow();
                defer mg.deinit();
                try testing.expectEqualStrings("radix 1 was not in valid range 2..36", mg.get().*);
            },
            else => return error.WrongError,
        },
    }
}

test "int_to_string renders in base" {
    var h = Harness.init();
    defer h.deinit();
    var ctx = h.ctx(&.{ Value.newInt(255), Value.newInt(16) });
    const res = try int_to_string(&ctx);
    const g = res.ok.String.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("ff", g.get().*);
}

test "int conversions widen and narrow" {
    var h = Harness.init();
    defer h.deinit();
    {
        var ctx = h.ctx(&.{Value.newInt(7)});
        try expectValue(try int_to_long(&ctx), .{ .Long = 7 });
    }
    {
        var ctx = h.ctx(&.{Value.newInt(300)});
        try expectValue(try int_to_byte(&ctx), Value.newByte(300));
    }
    {
        var ctx = h.ctx(&.{Value.newInt(5)});
        try expectValue(try int_to_double(&ctx), .{ .Double = 5.0 });
    }
}

test "unsigned reinterpretation conversions" {
    var h = Harness.init();
    defer h.deinit();
    {
        var ctx = h.ctx(&.{Value.newInt(-1)});
        try expectValue(try to_uint(&ctx), .{ .UInt = std.math.maxInt(u32) });
    }
    {
        var ctx = h.ctx(&.{.{ .UInt = std.math.maxInt(u32) }});
        try expectValue(try unsigned_to_int(&ctx), Value.newInt(-1));
    }
    {
        var ctx = h.ctx(&.{.{ .ULong = std.math.maxInt(u64) }});
        try expectValue(try unsigned_to_long(&ctx), .{ .Long = -1 });
    }
}

test "float and double conversions saturate" {
    var h = Harness.init();
    defer h.deinit();
    {
        var ctx = h.ctx(&.{.{ .Double = 3.9 }});
        try expectValue(try double_to_int(&ctx), Value.newInt(3));
    }
    {
        var ctx = h.ctx(&.{.{ .Double = 1e300 }});
        try expectValue(try double_to_int(&ctx), Value.newInt(std.math.maxInt(i32)));
    }
    {
        var ctx = h.ctx(&.{.{ .Double = std.math.nan(f64) }});
        try expectValue(try double_to_long(&ctx), .{ .Long = 0 });
    }
    {
        var ctx = h.ctx(&.{.{ .Float = -1e30 }});
        try expectValue(try float_to_int(&ctx), Value.newInt(std.math.minInt(i32)));
    }
}

test "f64ToI32Kotlin saturation table" {
    try testing.expectEqual(@as(i32, 0), f64ToI32Kotlin(std.math.nan(f64)));
    try testing.expectEqual(std.math.maxInt(i32), f64ToI32Kotlin(1e30));
    try testing.expectEqual(std.math.minInt(i32), f64ToI32Kotlin(-1e30));
    try testing.expectEqual(@as(i32, -3), f64ToI32Kotlin(-3.9));
}

test "int bit ops" {
    var h = Harness.init();
    defer h.deinit();
    {
        var ctx = h.ctx(&.{ Value.newInt(0b1100), Value.newInt(0b1010) });
        try expectValue(try int_and(&ctx), Value.newInt(0b1000));
    }
    {
        var ctx = h.ctx(&.{ Value.newInt(0b1100), Value.newInt(0b1010) });
        try expectValue(try int_or(&ctx), Value.newInt(0b1110));
    }
    {
        var ctx = h.ctx(&.{ Value.newInt(1), Value.newInt(4) });
        try expectValue(try int_shl(&ctx), Value.newInt(16));
    }
    {
        var ctx = h.ctx(&.{ Value.newInt(-1), Value.newInt(1) });
        try expectValue(try int_ushr(&ctx), Value.newInt(0x7fff_ffff));
    }
    {
        var ctx = h.ctx(&.{Value.newInt(0)});
        try expectValue(try int_inv(&ctx), Value.newInt(-1));
    }
}

test "long shifts mask to 0..63" {
    var h = Harness.init();
    defer h.deinit();
    var ctx = h.ctx(&.{ Value{ .Long = 1 }, Value.newInt(64) });
    // 64 & 63 == 0, so a no-op shift.
    try expectValue(try long_shl(&ctx), .{ .Long = 1 });
}

test "compareTo total order" {
    var h = Harness.init();
    defer h.deinit();
    {
        var ctx = h.ctx(&.{ Value.newInt(1), Value.newInt(2) });
        try expectValue(try int_compare_to(&ctx), .{ .Int = -1 });
    }
    {
        var ctx = h.ctx(&.{ Value{ .Long = 5 }, Value{ .Long = 5 } });
        try expectValue(try long_compare_to(&ctx), .{ .Int = 0 });
    }
    {
        // NaN is the greatest value under the total order.
        var ctx = h.ctx(&.{ Value{ .Double = std.math.nan(f64) }, Value{ .Double = 1.0 } });
        try expectValue(try double_compare_to(&ctx), .{ .Int = 1 });
    }
}

test "double bit reflection round trip" {
    var h = Harness.init();
    defer h.deinit();
    {
        var ctx = h.ctx(&.{.{ .Double = 1.0 }});
        try expectValue(try double_to_raw_bits(&ctx), .{ .Long = @bitCast(@as(f64, 1.0)) });
    }
    {
        const bits: i64 = @bitCast(@as(f64, 2.5));
        var ctx = h.ctx(&.{.{ .Long = bits }});
        try expectValue(try double_from_bits(&ctx), .{ .Double = 2.5 });
    }
    {
        // toBits canonicalises NaN.
        var ctx = h.ctx(&.{.{ .Double = std.math.nan(f64) }});
        try expectValue(try double_to_bits(&ctx), .{ .Long = @bitCast(@as(u64, 0x7ff8_0000_0000_0000)) });
    }
}

test "bool_to_string" {
    var h = Harness.init();
    defer h.deinit();
    {
        var ctx = h.ctx(&.{.{ .Bool = true }});
        const res = try bool_to_string(&ctx);
        const g = res.ok.String.borrow();
        defer g.deinit();
        try testing.expectEqualStrings("true", g.get().*);
    }
    {
        var ctx = h.ctx(&.{Value.newInt(1)});
        const res = try bool_to_string(&ctx);
        try testing.expect(res == .err);
    }
}

test "coerceIn for Int" {
    var h = Harness.init();
    defer h.deinit();
    {
        var ctx = h.ctx(&.{ Value.newInt(5), Value.newInt(0), Value.newInt(10) });
        try expectValue(try int_coerce_in(&ctx), Value.newInt(5));
    }
    {
        var ctx = h.ctx(&.{ Value.newInt(-3), Value.newInt(0), Value.newInt(10) });
        try expectValue(try int_coerce_in(&ctx), Value.newInt(0));
    }
    {
        var ctx = h.ctx(&.{ Value.newInt(99), Value.newInt(0), Value.newInt(10) });
        try expectValue(try int_coerce_in(&ctx), Value.newInt(10));
    }
}

test "num coerce family widens like minOf/maxOf" {
    var h = Harness.init();
    defer h.deinit();
    {
        // Long receiver keeps a Long result.
        var ctx = h.ctx(&.{ Value{ .Long = 50 }, Value{ .Long = 0 }, Value{ .Long = 10 } });
        try expectValue(try num_coerce_in(&ctx), .{ .Long = 10 });
    }
    {
        var ctx = h.ctx(&.{ Value{ .Double = 5.0 }, Value{ .Double = 6.0 } });
        try expectValue(try num_coerce_at_least(&ctx), .{ .Double = 6.0 });
    }
}

test "floorDiv and mod follow Kotlin sign rules" {
    var h = Harness.init();
    defer h.deinit();
    {
        var ctx = h.ctx(&.{ Value.newInt(-7), Value.newInt(2) });
        try expectValue(try num_floor_div(&ctx), Value.newInt(-4));
    }
    {
        var ctx = h.ctx(&.{ Value.newInt(-7), Value.newInt(2) });
        try expectValue(try num_mod(&ctx), Value.newInt(1));
    }
    {
        // Widening to Long when either operand is Long.
        var ctx = h.ctx(&.{ Value{ .Long = -7 }, Value.newInt(2) });
        try expectValue(try num_floor_div(&ctx), .{ .Long = -4 });
    }
    {
        // Division by zero throws ArithmeticException.
        var ctx = h.ctx(&.{ Value.newInt(1), Value.newInt(0) });
        const res = try num_floor_div(&ctx);
        try testing.expect(res == .err and res.err == .Thrown);
    }
}

test "bit counts across integer widths" {
    var h = Harness.init();
    defer h.deinit();
    {
        var ctx = h.ctx(&.{Value.newInt(0)});
        try expectValue(try num_count_leading_zero_bits(&ctx), Value.newInt(32));
    }
    {
        var ctx = h.ctx(&.{Value{ .Long = 0 }});
        try expectValue(try num_count_leading_zero_bits(&ctx), Value.newInt(64));
    }
    {
        var ctx = h.ctx(&.{Value.newInt(0b1011)});
        try expectValue(try num_count_one_bits(&ctx), Value.newInt(3));
    }
    {
        var ctx = h.ctx(&.{Value.newInt(8)});
        try expectValue(try num_count_trailing_zero_bits(&ctx), Value.newInt(3));
    }
    {
        // Byte zero saturates trailing-zero count at 8.
        var ctx = h.ctx(&.{Value{ .Byte = 0 }});
        try expectValue(try num_count_trailing_zero_bits(&ctx), Value.newInt(8));
    }
}

test "int_to_char keeps low 16 bits" {
    var h = Harness.init();
    defer h.deinit();
    var ctx = h.ctx(&.{Value.newInt(65)});
    try expectValue(try int_to_char(&ctx), .{ .Char = 65 });
}

test "type errors surface as RuntimeError data" {
    var h = Harness.init();
    defer h.deinit();
    var ctx = h.ctx(&.{.{ .Bool = true }});
    const res = try int_to_long(&ctx);
    try testing.expect(res == .err and res.err == .Type);
}
