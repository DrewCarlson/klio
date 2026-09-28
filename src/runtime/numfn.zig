//! Numeric functions of one value that an instruction computes: the bit
//! views of the floating-point types, a trailing-zero count, the unsigned
//! types' conversions to floating point, bitwise inversion, `sin`, `cos`
//! and `sqrt`, and the unsigned types' constructors and their `data`. Each
//! answers as the stdlib native it stands for does; a value of a type the
//! function does not take answers null.

const std = @import("std");
const Value = @import("value.zig").Value;

pub const Fn = enum {
    inv,
    to_raw_bits,
    to_bits,
    float_from_bits,
    double_from_bits,
    count_trailing_zero_bits,
    uint_to_float,
    uint_to_double,
    ulong_to_float,
    ulong_to_double,
    sin,
    cos,
    sqrt,
    /// `ULong(data)` and the other unsigned constructors: the integer's bits
    /// as the unsigned number, as the host's constructors take them.
    to_ulong,
    to_uint,
    to_ushort,
    to_ubyte,
    /// An unsigned number's `data`: its bits as the signed type.
    unsigned_bits,
};

pub inline fn apply(f: Fn, v: Value) ?Value {
    return switch (f) {
        .inv => switch (v) {
            .Int => |x| .{ .Int = ~x },
            .Long => |x| .{ .Long = ~x },
            else => null,
        },
        .to_raw_bits => switch (v) {
            .Float => |x| .{ .Int = @bitCast(x) },
            .Double => |x| .{ .Long = @bitCast(x) },
            else => null,
        },
        // A NaN has the one bit pattern Kotlin's `toBits` gives it.
        .to_bits => switch (v) {
            .Float => |x| .{ .Int = @bitCast(if (std.math.isNan(x)) @as(u32, 0x7fc0_0000) else @as(u32, @bitCast(x))) },
            .Double => |x| .{ .Long = @bitCast(if (std.math.isNan(x)) @as(u64, 0x7ff8_0000_0000_0000) else @as(u64, @bitCast(x))) },
            else => null,
        },
        // `Float.fromBits` takes the low 32 bits.
        .float_from_bits => .{ .Float = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(v.asI64() orelse return null))))) },
        .double_from_bits => .{ .Double = @bitCast(v.asI64() orelse return null) },
        .count_trailing_zero_bits => .{ .Int = switch (v) {
            .Long => |x| @ctz(@as(u64, @bitCast(x))),
            .Int => |x| @ctz(@as(u32, @bitCast(x))),
            .Short => |x| @min(@as(i32, @ctz(@as(u16, @bitCast(x)))), 16),
            .Byte => |x| @min(@as(i32, @ctz(@as(u8, @bitCast(x)))), 8),
            .ULong => |x| @ctz(x),
            .UInt => |x| @ctz(x),
            .UShort => |x| @min(@as(i32, @ctz(x)), 16),
            .UByte => |x| @min(@as(i32, @ctz(x)), 8),
            else => return null,
        } },
        .uint_to_float => .{ .Float = @floatFromInt(@as(u32, @truncate(@as(u64, @bitCast(v.asI64() orelse return null))))) },
        .uint_to_double => .{ .Double = @floatFromInt(@as(u32, @truncate(@as(u64, @bitCast(v.asI64() orelse return null))))) },
        .ulong_to_float => .{ .Float = @floatFromInt(@as(u64, @bitCast(v.asI64() orelse return null))) },
        .ulong_to_double => .{ .Double = @floatFromInt(@as(u64, @bitCast(v.asI64() orelse return null))) },
        .to_ulong => .{ .ULong = @bitCast(v.asI64() orelse return null) },
        .to_uint => .{ .UInt = @truncate(@as(u64, @bitCast(v.asI64() orelse return null))) },
        .to_ushort => .{ .UShort = @truncate(@as(u64, @bitCast(v.asI64() orelse return null))) },
        .to_ubyte => .{ .UByte = @truncate(@as(u64, @bitCast(v.asI64() orelse return null))) },
        .unsigned_bits => switch (v) {
            .ULong => |x| .{ .Long = @bitCast(x) },
            .UInt => |x| .{ .Int = @bitCast(x) },
            .UShort => |x| .{ .Short = @bitCast(x) },
            .UByte => |x| .{ .Byte = @bitCast(x) },
            else => null,
        },
        // A `Float` is computed as a `Double` and narrowed, as the natives do.
        inline .sin, .cos, .sqrt => |which| switch (v) {
            .Double => |x| .{ .Double = mathOf(which, x) },
            .Float => |x| .{ .Float = @floatCast(mathOf(which, @as(f64, x))) },
            else => null,
        },
    };
}

inline fn mathOf(comptime f: Fn, x: f64) f64 {
    return switch (f) {
        .sin => @sin(x),
        .cos => @cos(x),
        .sqrt => @sqrt(x),
        else => unreachable,
    };
}

const testing = std.testing;

test "bit views, counts and inversion answer as the natives do" {
    try testing.expectEqual(Value{ .Int = -1 }, apply(.inv, .{ .Int = 0 }).?);
    try testing.expectEqual(Value{ .Long = 5 }, apply(.inv, .{ .Long = -6 }).?);
    try testing.expectEqual(Value{ .Int = 0x3f80_0000 }, apply(.to_raw_bits, .{ .Float = 1.0 }).?);
    try testing.expectEqual(Value{ .Long = @bitCast(@as(u64, 0x8000_0000_0000_0000)) }, apply(.to_raw_bits, .{ .Double = -0.0 }).?);
    try testing.expectEqual(Value{ .Int = 0x7fc0_0000 }, apply(.to_bits, .{ .Float = @bitCast(@as(u32, 0x7fc0_0001)) }).?);
    try testing.expectEqual(Value{ .Float = 1.0 }, apply(.float_from_bits, .{ .Int = 0x3f80_0000 }).?);
    try testing.expectEqual(Value{ .Double = 2.0 }, apply(.double_from_bits, .{ .Long = 0x4000_0000_0000_0000 }).?);
    try testing.expectEqual(Value{ .Int = 32 }, apply(.count_trailing_zero_bits, .{ .Int = 0 }).?);
    try testing.expectEqual(Value{ .Int = 3 }, apply(.count_trailing_zero_bits, .{ .Long = 8 }).?);
    try testing.expectEqual(Value{ .Int = 8 }, apply(.count_trailing_zero_bits, .{ .UByte = 0 }).?);
    try testing.expectEqual(Value{ .Float = 4294967295.0 }, apply(.uint_to_float, .{ .Int = -1 }).?);
    try testing.expectEqual(Value{ .Double = 18446744073709551615.0 }, apply(.ulong_to_double, .{ .Long = -1 }).?);
    try testing.expect(apply(.inv, .{ .Double = 1.0 }) == null);
}

test "an unsigned number is made from an integer's bits, and gives them back" {
    try testing.expectEqual(Value{ .ULong = std.math.maxInt(u64) }, apply(.to_ulong, .{ .Long = -1 }).?);
    try testing.expectEqual(Value{ .UInt = 0xffff_ffff }, apply(.to_uint, .{ .Int = -1 }).?);
    try testing.expectEqual(Value{ .UShort = 0xff80 }, apply(.to_ushort, .{ .Short = -128 }).?);
    try testing.expectEqual(Value{ .UByte = 0x80 }, apply(.to_ubyte, .{ .Byte = -128 }).?);
    try testing.expectEqual(Value{ .Long = -1 }, apply(.unsigned_bits, .{ .ULong = std.math.maxInt(u64) }).?);
    try testing.expectEqual(Value{ .Int = std.math.minInt(i32) }, apply(.unsigned_bits, .{ .UInt = 0x8000_0000 }).?);
    try testing.expectEqual(Value{ .Byte = -1 }, apply(.unsigned_bits, .{ .UByte = 0xff }).?);
    try testing.expect(apply(.unsigned_bits, .{ .Long = 1 }) == null);
}

test "sin, cos and sqrt keep a Float a Float" {
    try testing.expectEqual(Value{ .Double = 0.0 }, apply(.sin, .{ .Double = 0.0 }).?);
    try testing.expectEqual(Value{ .Float = 1.0 }, apply(.cos, .{ .Float = 0.0 }).?);
    try testing.expectEqual(Value{ .Float = 3.0 }, apply(.sqrt, .{ .Float = 9.0 }).?);
    try testing.expect(std.math.isNan(apply(.sqrt, .{ .Double = -1.0 }).?.Double));
    try testing.expect(apply(.sin, .{ .Int = 1 }) == null);
}
