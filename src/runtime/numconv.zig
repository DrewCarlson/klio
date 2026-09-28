//! Kotlin's conversions between the primitive numbers and `Char`: `toInt()`,
//! `toLong()` and the rest, as the JVM's conversion bytecodes compute them.
//! An integral value narrows by keeping its low bits and widens by its sign;
//! a floating-point value converts to an integer toward zero, NaN giving 0
//! and the rest saturating at the target's bounds (through `Int` for the
//! types narrower than it); an integer converts to a floating-point value
//! at the nearest one.

const std = @import("std");
const Value = @import("value.zig").Value;

/// The primitive a conversion makes.
pub const Target = enum { byte, short, int, long, float, double, char };

/// `v` converted to `to`; null when `v` is not a number or a `Char`.
pub inline fn convert(to: Target, v: Value) ?Value {
    switch (v) {
        .Double => |d| return fromFloating(to, d, f64ToI32Kotlin(d), f64ToI64Kotlin(d)),
        .Float => |f| return fromFloating(to, f, f32ToI32Kotlin(f), f32ToI64Kotlin(f)),
        else => {},
    }
    const n: i64 = switch (v) {
        .Int => |x| x,
        .Long => |x| x,
        .Short => |x| x,
        .Byte => |x| x,
        .Char => |c| c,
        else => return null,
    };
    return fromIntegral(to, n);
}

inline fn fromIntegral(to: Target, n: i64) Value {
    return switch (to) {
        .byte => .{ .Byte = @truncate(n) },
        .short => .{ .Short = @truncate(n) },
        .int => .{ .Int = @truncate(n) },
        .long => .{ .Long = n },
        .float => .{ .Float = @floatFromInt(n) },
        .double => .{ .Double = @floatFromInt(n) },
        .char => .{ .Char = @truncate(@as(u64, @bitCast(n))) },
    };
}

inline fn fromFloating(to: Target, x: anytype, as_int: i32, as_long: i64) Value {
    return switch (to) {
        .byte => .{ .Byte = @truncate(as_int) },
        .short => .{ .Short = @truncate(as_int) },
        .int => .{ .Int = as_int },
        .long => .{ .Long = as_long },
        .float => .{ .Float = @floatCast(x) },
        .double => .{ .Double = @floatCast(x) },
        .char => .{ .Char = @truncate(@as(u32, @bitCast(as_int))) },
    };
}

pub fn f64ToI32Kotlin(d: f64) i32 {
    if (std.math.isNan(d)) return 0;
    const hi: f64 = @floatFromInt(@as(i32, std.math.maxInt(i32)));
    const lo: f64 = @floatFromInt(@as(i32, std.math.minInt(i32)));
    if (d >= hi) return std.math.maxInt(i32);
    if (d <= lo) return std.math.minInt(i32);
    return @intFromFloat(@trunc(d));
}

pub fn f64ToI64Kotlin(d: f64) i64 {
    if (std.math.isNan(d)) return 0;
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

const testing = std.testing;

test "integral conversions keep the low bits and widen by sign" {
    try testing.expectEqual(Value{ .Int = -1 }, convert(.int, .{ .Long = 0xFFFF_FFFF }).?);
    try testing.expectEqual(Value{ .Long = -5 }, convert(.long, .{ .Int = -5 }).?);
    try testing.expectEqual(Value{ .Byte = -128 }, convert(.byte, .{ .Int = 128 }).?);
    try testing.expectEqual(Value{ .Short = 1 }, convert(.short, .{ .Int = 65537 }).?);
    try testing.expectEqual(Value{ .Char = 0xFFFF }, convert(.char, .{ .Byte = -1 }).?);
    try testing.expectEqual(Value{ .Int = 65 }, convert(.int, .{ .Char = 'A' }).?);
    try testing.expectEqual(Value{ .Double = 3 }, convert(.double, .{ .Short = 3 }).?);
    // The nearest Float to 2^53 + 1 is 2^53.
    try testing.expectEqual(Value{ .Float = 9007199254740992.0 }, convert(.float, .{ .Long = 9007199254740993 }).?);
}

test "floating conversions truncate toward zero, map NaN to 0 and saturate" {
    try testing.expectEqual(Value{ .Int = -3 }, convert(.int, .{ .Double = -3.9 }).?);
    try testing.expectEqual(Value{ .Int = 0 }, convert(.int, .{ .Double = std.math.nan(f64) }).?);
    try testing.expectEqual(Value{ .Int = std.math.maxInt(i32) }, convert(.int, .{ .Float = 1e20 }).?);
    try testing.expectEqual(Value{ .Long = std.math.minInt(i64) }, convert(.long, .{ .Double = -1e30 }).?);
    // Narrower than Int: through Int, then its low bits.
    try testing.expectEqual(Value{ .Short = -1 }, convert(.short, .{ .Double = 1e30 }).?);
    try testing.expectEqual(Value{ .Byte = 44 }, convert(.byte, .{ .Float = 300.5 }).?);
    try testing.expectEqual(Value{ .Char = 'a' }, convert(.char, .{ .Double = 97.9 }).?);
    try testing.expectEqual(Value{ .Float = 0.1 }, convert(.float, .{ .Double = 0.1 }).?);
    try testing.expectEqual(Value{ .Double = 0.5 }, convert(.double, .{ .Float = 0.5 }).?);
    try testing.expect(convert(.int, .{ .Bool = true }) == null);
}
