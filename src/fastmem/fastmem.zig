//! `memset` for the whole binary. Zig's compiler-rt brings one that sets a
//! byte at a time, linked weakly, so every `@memset` in klio (zeroing a
//! table, filling a fresh allocation in a safe build) ran it: a third of a
//! cold build's time. This one stores wide words, and is linked strongly
//! in its place.
//!
//! The module is built with `-fno-builtin`: the stores below would
//! otherwise be recognized as a `memset` and compiled into a call to
//! `memset`, which is this function. Nothing here may use `@memset`.

const std = @import("std");

/// The widest store the loop makes: two of the target's vector registers
/// where it has them.
const Wide = @Vector(32, u8);
const Half = @Vector(16, u8);

inline fn put(comptime T: type, p: [*]u8, v: T) void {
    @as(*align(1) T, @ptrCast(p)).* = v;
}

/// C's `memset`: `fill` is an `int`, which callers may pass sign-extended
/// (a fill of 0xFE arrives as -2); its low byte is what is stored.
pub fn memset(dest: ?[*]u8, fill: c_int, len: usize) callconv(.c) ?[*]u8 {
    @setRuntimeSafety(false);
    const c: u8 = @truncate(@as(c_uint, @bitCast(fill)));
    const d = dest orelse return dest;
    if (len < 16) {
        // Two stores that overlap where the length is not their size.
        if (len >= 8) {
            const w: u64 = @as(u64, c) *% 0x0101010101010101;
            put(u64, d, w);
            put(u64, d + len - 8, w);
        } else if (len >= 4) {
            const w: u32 = @as(u32, c) *% 0x01010101;
            put(u32, d, w);
            put(u32, d + len - 4, w);
        } else if (len >= 2) {
            const w: u16 = @as(u16, c) *% 0x0101;
            put(u16, d, w);
            put(u16, d + len - 2, w);
        } else if (len == 1) {
            d[0] = c;
        }
        return dest;
    }
    if (len <= 32) {
        const h: Half = @splat(c);
        put(Half, d, h);
        put(Half, d + len - 16, h);
        return dest;
    }
    const v: Wide = @splat(c);
    // The first and last stores cover the unaligned ends; the loop between
    // them stores aligned, four at a time while it can.
    put(Wide, d, v);
    const end = @intFromPtr(d) + len;
    var p = (@intFromPtr(d) +% @sizeOf(Wide)) & ~@as(usize, @sizeOf(Wide) - 1);
    while (p + 4 * @sizeOf(Wide) <= end) : (p += 4 * @sizeOf(Wide)) {
        const q: [*]Wide = @ptrFromInt(p);
        q[0] = v;
        q[1] = v;
        q[2] = v;
        q[3] = v;
    }
    while (p + @sizeOf(Wide) <= end) : (p += @sizeOf(Wide)) {
        const q: *Wide = @ptrFromInt(p);
        q.* = v;
    }
    put(Wide, @ptrFromInt(end - @sizeOf(Wide)), v);
    return dest;
}

comptime {
    @export(&memset, .{ .name = "memset", .linkage = .strong });
}

test "memset sets every byte it is given and none around them, at every length and alignment" {
    var buf: [700]u8 = undefined;
    var len: usize = 0;
    while (len <= 600) : (len += if (len < 80) 1 else 37) {
        var off: usize = 0;
        while (off < 40) : (off += 1) {
            for (&buf) |*b| b.* = 0x5C;
            // Passed as a C caller may pass 0xA7: sign-extended.
            _ = memset(buf[off..].ptr, @as(i8, @bitCast(@as(u8, 0xA7))), len);
            for (buf, 0..) |b, i| {
                const want: u8 = if (i >= off and i < off + len) 0xA7 else 0x5C;
                try std.testing.expectEqual(want, b);
            }
        }
    }
}

test "@memset through the binary's memset" {
    var buf: [300]u8 = @splat(7);
    // A runtime length, so the store is a call.
    var n: usize = 257;
    _ = &n;
    @memset(buf[1..][0..n], 0xAB);
    try std.testing.expectEqual(@as(u8, 7), buf[0]);
    for (buf[1 .. 1 + n]) |b| try std.testing.expectEqual(@as(u8, 0xAB), b);
    try std.testing.expectEqual(@as(u8, 7), buf[1 + n]);
}
