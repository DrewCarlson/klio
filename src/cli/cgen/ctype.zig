//! Machine types of registers and parameters, and the C text of values:
//! literals, boxing and unboxing.

const std = @import("std");
const ir = @import("ir");

/// How a value lives in the generated C. A reference is a `klio_value`,
/// which the collector finds only in a published frame slot; every other
/// kind is a plain C scalar.
pub const Ty = enum {
    i32,
    i64,
    f64,
    f32,
    boolean,
    unit,
    /// A UTF-16 code unit.
    char,
    short,
    byte,
    /// The unsigned value classes, held in the bits of their signed form.
    u32,
    u64,
    u16,
    u8,
    object,

    pub fn cName(self: Ty) []const u8 {
        return switch (self) {
            .i32 => "int32_t",
            .i64 => "int64_t",
            .f64 => "double",
            .f32 => "float",
            .boolean => "int32_t",
            .unit => "int32_t",
            .char => "uint16_t",
            .short => "int16_t",
            .byte => "int8_t",
            .u32 => "uint32_t",
            .u64 => "uint64_t",
            .u16 => "uint16_t",
            .u8 => "uint8_t",
            .object => "klio_value",
        };
    }

    pub fn isFloat(self: Ty) bool {
        return self == .f64 or self == .f32;
    }

    pub fn isUnsigned(self: Ty) bool {
        return switch (self) {
            .u32, .u64, .u16, .u8 => true,
            else => false,
        };
    }

    /// A number `+`, `-`, `*`, `/` and `%` apply to directly.
    pub fn isNumeric(self: Ty) bool {
        return switch (self) {
            .i32, .i64, .f64, .f32, .short, .byte, .u32, .u64, .u16, .u8 => true,
            else => false,
        };
    }

    /// The runtime's boxing function for this kind.
    pub fn boxFn(self: Ty) []const u8 {
        return switch (self) {
            .i32 => "klio_nat_box_int",
            .i64 => "klio_nat_box_long",
            .f64 => "klio_nat_box_double",
            .f32 => "klio_nat_box_float",
            .boolean => "klio_nat_box_bool",
            .char => "klio_nat_box_char",
            .short => "klio_nat_box_short",
            .byte => "klio_nat_box_byte",
            .u32 => "klio_nat_box_uint",
            .u64 => "klio_nat_box_ulong",
            .u16 => "klio_nat_box_ushort",
            .u8 => "klio_nat_box_ubyte",
            .unit, .object => "",
        };
    }

    /// The runtime's unboxing function for this kind.
    pub fn unboxFn(self: Ty) []const u8 {
        return switch (self) {
            .i32 => "klio_nat_int",
            .i64 => "klio_nat_long",
            .f64 => "klio_nat_double",
            .f32 => "klio_nat_float",
            .boolean => "klio_nat_bool",
            .char => "klio_nat_char",
            .short => "klio_nat_short",
            .byte => "klio_nat_byte",
            .u32 => "klio_nat_uint",
            .u64 => "klio_nat_ulong",
            .u16 => "klio_nat_ushort",
            .u8 => "klio_nat_ubyte",
            .unit, .object => "",
        };
    }
};

/// The kind of a constant.
pub fn constTy(c: ir.Const) Ty {
    return switch (c) {
        .Int => .i32,
        .Long => .i64,
        .Double => .f64,
        .Float => .f32,
        .Bool => .boolean,
        .Unit => .unit,
        .Char => .char,
        .Short => .short,
        .Byte => .byte,
        .UInt => .u32,
        .ULong => .u64,
        .UShort => .u16,
        .UByte => .u8,
        .String, .Null => .object,
    };
}

/// Writes `expr`, of kind `have`, as a value of kind `want`. Kinds that
/// differ between two scalars are the same bits read another way (an
/// unsigned class over its signed form), so C's conversion is enough.
pub fn writeConv(w: *std.Io.Writer, have: Ty, want: Ty, expr: []const u8) !void {
    if (have == want) return w.writeAll(expr);
    if (want == .object) return writeBox(w, have, expr);
    if (have == .object) return writeUnbox(w, want, expr);
    if (want == .unit) return w.print("((void)({s}), 0)", .{expr});
    try w.print("(({s})({s}))", .{ want.cName(), expr });
}

pub fn writeBox(w: *std.Io.Writer, t: Ty, expr: []const u8) !void {
    switch (t) {
        .object => try w.writeAll(expr),
        // Boxing a Unit result still runs what produced it.
        .unit => try w.print("((void)({s}), klio_nat_box_unit())", .{expr}),
        else => try w.print("{s}({s})", .{ t.boxFn(), expr }),
    }
}

pub fn writeUnbox(w: *std.Io.Writer, t: Ty, expr: []const u8) !void {
    switch (t) {
        .object => try w.writeAll(expr),
        .unit => try w.print("((void)({s}), 0)", .{expr}),
        else => try w.print("{s}({s})", .{ t.unboxFn(), expr }),
    }
}

/// A scalar constant as a C literal of its kind.
pub fn writeScalar(w: *std.Io.Writer, c: ir.Const) !void {
    switch (c) {
        .Int => |v| try w.print("INT32_C({d})", .{v}),
        .Long => |v| if (v == std.math.minInt(i64)) try w.writeAll("INT64_MIN") else try w.print("INT64_C({d})", .{v}),
        .Bool => |v| try w.print("{d}", .{@intFromBool(v)}),
        .Char => |v| try w.print("((uint16_t){d}u)", .{v}),
        .Short => |v| try w.print("((int16_t){d})", .{v}),
        .Byte => |v| try w.print("((int8_t){d})", .{v}),
        .UInt => |v| try w.print("UINT32_C({d})", .{v}),
        .ULong => |v| try w.print("UINT64_C({d})", .{v}),
        .UShort => |v| try w.print("((uint16_t){d}u)", .{v}),
        .UByte => |v| try w.print("((uint8_t){d}u)", .{v}),
        .Unit => try w.writeAll("0"),
        .Double => |v| try writeFloat(w, v, false),
        .Float => |v| try writeFloat(w, v, true),
        .String, .Null => unreachable,
    }
}

/// A C string literal for arbitrary bytes: everything outside the
/// printable range is escaped by value, so embedded NULs and invalid UTF-8
/// survive.
pub fn writeCString(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.writeByte('"');
    try writeCChars(w, bytes);
    try w.writeByte('"');
}

/// The inside of `writeCString`'s literal.
pub fn writeCChars(w: *std.Io.Writer, bytes: []const u8) !void {
    for (bytes) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            // A `?` pair could start a trigraph.
            '?' => try w.writeAll("\\?"),
            0x20...0x21, 0x23...0x3E, 0x40...0x5B, 0x5D...0x7E => try w.writeByte(ch),
            else => try w.print("\\{o:0>3}", .{ch}),
        }
    }
}

/// A C floating literal. The shortest round-trip decimal is exact but may
/// carry no point or exponent, which C would read as an integer.
pub fn writeFloat(w: *std.Io.Writer, v: f64, is_f32: bool) !void {
    if (std.math.isNan(v)) return w.print("(({s})NAN)", .{if (is_f32) "float" else "double"});
    if (std.math.isInf(v)) return w.print("(({s}{s})INFINITY)", .{ if (v < 0) "-" else "", if (is_f32) "float" else "double" });
    var buf: [64]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{e}", .{v}) catch return error.WriteFailed;
    try w.writeAll(txt);
    if (std.mem.findAny(u8, txt, ".eE") == null) try w.writeAll(".0");
    if (is_f32) try w.writeByte('f');
}

test "a string literal escapes everything outside printable ASCII" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeCString(&aw.writer, "a\"b\\c\n\x00??=");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\012\\000\\?\\?=\"", aw.written());
}

test "a float literal always reads back as floating" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeFloat(&aw.writer, 1e20, false);
    try aw.writer.writeByte(' ');
    try writeFloat(&aw.writer, 0.5, true);
    try aw.writer.writeByte(' ');
    try writeFloat(&aw.writer, -std.math.inf(f64), false);
    try std.testing.expectEqualStrings("1e20 5e-1f ((-double)INFINITY)", aw.written());
}

test "conversions box, unbox and reinterpret" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeConv(&aw.writer, .i32, .object, "r1");
    try aw.writer.writeByte(' ');
    try writeConv(&aw.writer, .object, .i64, "KS[0]");
    try aw.writer.writeByte(' ');
    try writeConv(&aw.writer, .i32, .u32, "r2");
    try std.testing.expectEqualStrings("klio_nat_box_int(r1) klio_nat_long(KS[0]) ((uint32_t)(r2))", aw.written());
}
