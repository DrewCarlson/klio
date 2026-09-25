//! Wire-format helpers for TLS structures: a bounds-checked reader over
//! received bytes and an appending writer with length-prefix back-patching.
//! Every read that would run past its buffer is `error.Decode`, which the
//! session turns into a `decode_error` alert.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DecodeError = error{Decode};

/// A cursor over received bytes. It never reads outside `buf`.
pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn remaining(r: *const Reader) usize {
        return r.buf.len - r.pos;
    }

    pub fn done(r: *const Reader) bool {
        return r.pos == r.buf.len;
    }

    /// A big-endian unsigned integer of `T`'s width (u8, u16, u24, u32, u64).
    pub fn int(r: *Reader, comptime T: type) DecodeError!T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        if (r.remaining() < n) return error.Decode;
        var v: u64 = 0;
        for (r.buf[r.pos..][0..n]) |b| v = (v << 8) | b;
        r.pos += n;
        return @intCast(v);
    }

    pub fn bytes(r: *Reader, n: usize) DecodeError![]const u8 {
        if (r.remaining() < n) return error.Decode;
        const out = r.buf[r.pos..][0..n];
        r.pos += n;
        return out;
    }

    pub fn array(r: *Reader, comptime n: usize) DecodeError!*const [n]u8 {
        return (try r.bytes(n))[0..n];
    }

    /// An opaque vector prefixed by a `Len`-wide length.
    pub fn vec(r: *Reader, comptime Len: type) DecodeError![]const u8 {
        const n = try r.int(Len);
        return r.bytes(n);
    }

    /// A reader over a `Len`-prefixed vector's contents.
    pub fn sub(r: *Reader, comptime Len: type) DecodeError!Reader {
        return .init(try r.vec(Len));
    }

    pub fn expectEnd(r: *const Reader) DecodeError!void {
        if (!r.done()) return error.Decode;
    }
};

pub const WriteError = Allocator.Error || error{Overflow};

/// Builds a message by appending; `begin`/`end` bracket a length-prefixed
/// vector whose length is patched in when it closes.
pub const Writer = struct {
    a: Allocator,
    list: std.ArrayList(u8) = .empty,

    pub fn init(a: Allocator) Writer {
        return .{ .a = a };
    }

    pub fn deinit(w: *Writer) void {
        w.list.deinit(w.a);
    }

    pub fn int(w: *Writer, comptime T: type, v: T) Allocator.Error!void {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        var buf: [n]u8 = undefined;
        std.mem.writeInt(T, &buf, v, .big);
        try w.list.appendSlice(w.a, &buf);
    }

    pub fn bytes(w: *Writer, b: []const u8) Allocator.Error!void {
        try w.list.appendSlice(w.a, b);
    }

    /// Reserves a `Len`-wide length and returns the mark `end` patches.
    pub fn begin(w: *Writer, comptime Len: type) Allocator.Error!usize {
        const mark = w.list.items.len;
        try w.int(Len, 0);
        return mark;
    }

    pub fn end(w: *Writer, comptime Len: type, mark: usize) WriteError!void {
        const n = @divExact(@typeInfo(Len).int.bits, 8);
        const len = w.list.items.len - mark - n;
        if (len > std.math.maxInt(Len)) return error.Overflow;
        var x: usize = len;
        var i: usize = n;
        while (i > 0) {
            i -= 1;
            w.list.items[mark + i] = @truncate(x);
            x >>= 8;
        }
    }

    /// A length-prefixed opaque vector.
    pub fn vec(w: *Writer, comptime Len: type, b: []const u8) WriteError!void {
        if (b.len > std.math.maxInt(Len)) return error.Overflow;
        try w.int(Len, @intCast(b.len));
        try w.bytes(b);
    }
};

const testing = std.testing;

test "reader decodes big-endian integers and vectors and refuses to overrun" {
    var r: Reader = .init(&.{ 0x01, 0x02, 0x03, 0x00, 0x00, 0x05, 0x02, 0xaa, 0xbb, 0x09 });
    try testing.expectEqual(@as(u16, 0x0102), try r.int(u16));
    try testing.expectEqual(@as(u24, 0x030000), try r.int(u24));
    try testing.expectEqual(@as(u8, 0x05), try r.int(u8));
    try testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, try r.vec(u8));
    try testing.expectError(error.Decode, r.int(u16));
    try testing.expectError(error.Decode, r.bytes(2));
    try testing.expectEqual(@as(u8, 0x09), try r.int(u8));
    try r.expectEnd();
    var short: Reader = .init(&.{ 0x00, 0x05, 0x01 });
    try testing.expectError(error.Decode, short.vec(u16));
}

test "writer patches nested length prefixes" {
    var w: Writer = .init(testing.allocator);
    defer w.deinit();
    const outer = try w.begin(u24);
    try w.int(u16, 0x1301);
    const inner = try w.begin(u8);
    try w.bytes("ab");
    try w.end(u8, inner);
    try w.end(u24, outer);
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x05, 0x13, 0x01, 0x02, 'a', 'b' }, w.list.items);
}

test "writer refuses a vector longer than its prefix" {
    var w: Writer = .init(testing.allocator);
    defer w.deinit();
    const mark = try w.begin(u8);
    try w.bytes(&([_]u8{0} ** 256));
    try testing.expectError(error.Overflow, w.end(u8, mark));
}
