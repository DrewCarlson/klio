const std = @import("std");

/// Constant pool entry: anything not representable as a `u32` lives here.
pub const Const = union(enum) {
    Unit,
    Int: i32,
    Long: i64,
    UInt: u32,
    ULong: u64,
    UShort: u16,
    UByte: u8,
    Short: i16,
    Byte: i8,
    Double: f64,
    Float: f32,
    Bool: bool,
    /// UTF-16 code unit (see `runtime.Value.Char`).
    Char: u16,
    String: []const u8,
    Null,

    /// Structural equality for the interning pool. `Double`/`Float` compare by bit
    /// pattern, so NaN interns total and +0.0 / -0.0 stay distinct.
    pub fn eql(self: Const, other: Const) bool {
        return switch (self) {
            .Unit => other == .Unit,
            .Int => |a| other == .Int and a == other.Int,
            .Long => |a| other == .Long and a == other.Long,
            .UInt => |a| other == .UInt and a == other.UInt,
            .ULong => |a| other == .ULong and a == other.ULong,
            .UShort => |a| other == .UShort and a == other.UShort,
            .UByte => |a| other == .UByte and a == other.UByte,
            .Short => |a| other == .Short and a == other.Short,
            .Byte => |a| other == .Byte and a == other.Byte,
            .Double => |a| other == .Double and @as(u64, @bitCast(a)) == @as(u64, @bitCast(other.Double)),
            .Float => |a| other == .Float and @as(u32, @bitCast(a)) == @as(u32, @bitCast(other.Float)),
            .Bool => |a| other == .Bool and a == other.Bool,
            .Char => |a| other == .Char and a == other.Char,
            .String => |a| other == .String and std.mem.eql(u8, a, other.String),
            .Null => other == .Null,
        };
    }
};

/// Structural hash paired with `Const.eql`, including its bit-pattern float rule.
pub fn constHash(c: Const) u64 {
    var h = std.hash.Wyhash.init(@intFromEnum(std.meta.activeTag(c)));
    switch (c) {
        .Unit, .Null => {},
        .Int => |v| h.update(std.mem.asBytes(&v)),
        .Long => |v| h.update(std.mem.asBytes(&v)),
        .UInt => |v| h.update(std.mem.asBytes(&v)),
        .ULong => |v| h.update(std.mem.asBytes(&v)),
        .UShort => |v| h.update(std.mem.asBytes(&v)),
        .UByte => |v| h.update(std.mem.asBytes(&v)),
        .Short => |v| h.update(std.mem.asBytes(&v)),
        .Byte => |v| h.update(std.mem.asBytes(&v)),
        .Double => |v| {
            const bits: u64 = @bitCast(v);
            h.update(std.mem.asBytes(&bits));
        },
        .Float => |v| {
            const bits: u32 = @bitCast(v);
            h.update(std.mem.asBytes(&bits));
        },
        .Bool => |v| h.update(std.mem.asBytes(&v)),
        .Char => |v| h.update(std.mem.asBytes(&v)),
        .String => |s| h.update(s),
    }
    return h.final();
}
