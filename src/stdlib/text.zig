//! `kotlin.text.*`: `String`, `CharSequence`, `StringBuilder`, regex.

const std = @import("std");

/// Compare two UTF-8 strings as Kotlin's `String.compareTo` does,
/// lexicographically over UTF-16 code units. BMP-only strings match a UTF-8 byte
/// comparison, but a supplementary character diverges: its surrogate pair starts
/// with a high surrogate (D800-DBFF) while its UTF-8 starts with a 4-byte lead
/// (F0-F4), which sorts after every 3-byte lead.
pub fn compareUtf16(a: []const u8, b: []const u8) std.math.Order {
    var ai = Utf16Iter{ .bytes = a };
    var bi = Utf16Iter{ .bytes = b };
    while (true) {
        const x = ai.next();
        const y = bi.next();
        if (x != null and y != null) {
            const ord = std.math.order(x.?, y.?);
            if (ord != .eq) return ord;
        } else if (x != null and y == null) {
            return .gt;
        } else if (x == null and y != null) {
            return .lt;
        } else {
            return .eq;
        }
    }
}

pub fn utf16Len(a: []const u8) i32 {
    var it = Utf16Iter{ .bytes = a };
    var n: i32 = 0;
    while (it.next() != null) n += 1;
    return n;
}

/// `compareUtf16` returning kotlinc's value rather than an ordering: the JVM's
/// `String.compareTo` is the code-unit difference at the first mismatch, or the
/// length difference when one string is a prefix. `Comparable` contracts only
/// for the sign, but a program printing the result sees this number.
pub fn compareUtf16Difference(a: []const u8, b: []const u8) i32 {
    var ai = Utf16Iter{ .bytes = a };
    var bi = Utf16Iter{ .bytes = b };
    while (true) {
        const x = ai.next();
        const y = bi.next();
        if (x != null and y != null) {
            if (x.? != y.?) return @as(i32, x.?) - @as(i32, y.?);
        } else if (x != null and y == null) {
            var n: i32 = 1;
            while (ai.next() != null) n += 1;
            return n;
        } else if (x == null and y != null) {
            var n: i32 = 1;
            while (bi.next() != null) n += 1;
            return -n;
        } else return 0;
    }
}

const Utf16Iter = struct {
    bytes: []const u8,
    pos: usize = 0,
    pending_low: ?u16 = null,

    fn next(self: *Utf16Iter) ?u16 {
        if (self.pending_low) |low| {
            self.pending_low = null;
            return low;
        }
        if (self.pos >= self.bytes.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(self.bytes[self.pos]) catch {
            const unit: u16 = self.bytes[self.pos];
            self.pos += 1;
            return unit;
        };
        if (self.pos + len > self.bytes.len) {
            const unit: u16 = self.bytes[self.pos];
            self.pos += 1;
            return unit;
        }
        const cp: u21 = std.unicode.utf8Decode(self.bytes[self.pos .. self.pos + len]) catch cp_blk: {
            // A lone surrogate is stored as WTF-8, which strict UTF-8 decoding
            // rejects, so the three-byte form is decoded by hand to yield its
            // true UTF-16 code-unit value.
            if (len == 3) {
                const b0 = self.bytes[self.pos];
                const b1 = self.bytes[self.pos + 1];
                const b2 = self.bytes[self.pos + 2];
                if ((b0 & 0xF0) == 0xE0 and (b1 & 0xC0) == 0x80 and (b2 & 0xC0) == 0x80) {
                    break :cp_blk (@as(u21, b0 & 0x0F) << 12) | (@as(u21, b1 & 0x3F) << 6) | (@as(u21, b2 & 0x3F));
                }
            }
            const unit: u16 = self.bytes[self.pos];
            self.pos += 1;
            return unit;
        };
        self.pos += len;
        if (cp <= 0xFFFF) {
            return @intCast(cp);
        }
        const adjusted = cp - 0x10000;
        const high: u16 = @intCast(0xD800 + (adjusted >> 10));
        const low: u16 = @intCast(0xDC00 + (adjusted & 0x3FF));
        self.pending_low = low;
        return high;
    }
};

const testing = std.testing;

test "bmp strings match utf8 order" {
    try testing.expectEqual(std.math.Order.lt, compareUtf16("abc", "abd"));
    try testing.expectEqual(std.math.Order.eq, compareUtf16("abc", "abc"));
    try testing.expectEqual(std.math.Order.gt, compareUtf16("abd", "abc"));
    try testing.expectEqual(std.math.Order.eq, compareUtf16("", ""));
    try testing.expectEqual(std.math.Order.lt, compareUtf16("", "a"));
    try testing.expectEqual(std.math.Order.gt, compareUtf16("a", ""));
    try testing.expectEqual(std.math.Order.lt, compareUtf16("hello", "hello!"));
}

test "supplementary vs private use diverges from utf8" {
    const grin = "\u{1F600}";
    const pua = "\u{E000}";
    try testing.expectEqual(std.math.Order.lt, compareUtf16(grin, pua));
    try testing.expectEqual(std.math.Order.gt, std.mem.order(u8, grin, pua));
}

test "another supplementary divergence" {
    const clef = "\u{1D11E}";
    const high_bmp = "\u{F8FF}";
    try testing.expectEqual(std.math.Order.lt, compareUtf16(clef, high_bmp));
    try testing.expectEqual(std.math.Order.gt, std.mem.order(u8, clef, high_bmp));
}

test "equal supplementary pairs" {
    try testing.expectEqual(std.math.Order.eq, compareUtf16("\u{1F600}", "\u{1F600}"));
}

test "shorter is less when prefix equal" {
    try testing.expectEqual(std.math.Order.lt, compareUtf16("\u{1F600}", "\u{1F600}a"));
    try testing.expectEqual(std.math.Order.gt, compareUtf16("\u{1F600}a", "\u{1F600}"));
}
