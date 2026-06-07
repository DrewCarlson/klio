//! `kotlin.text.*`: `String`, `CharSequence`, `StringBuilder`, regex.

const std = @import("std");

/// Compare two UTF-8 strings the way Kotlin's `String.compareTo` does:
/// lexicographically over UTF-16 code units. For BMP-only strings the result
/// matches a UTF-8 byte comparison, but supplementary characters diverge
/// because a UTF-16 surrogate pair starts with a high surrogate (D800-DBFF),
/// while the same code point's UTF-8 encoding starts with a 4-byte lead
/// (F0-F4) that sorts after every 3-byte lead (E0-EF) used for U+E000-U+FFFF.
///
/// Streams the UTF-16 view of each string in lockstep, never materialising a
/// whole `[]u16`.
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

/// Streams the UTF-16 code units of a UTF-8 string one at a time. A
/// supplementary code point yields its high surrogate, then its low
/// surrogate on the following call.
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
            // Fall back to a single byte on malformed input; keeps the
            // comparison total rather than erroring out.
            const unit: u16 = self.bytes[self.pos];
            self.pos += 1;
            return unit;
        };
        if (self.pos + len > self.bytes.len) {
            const unit: u16 = self.bytes[self.pos];
            self.pos += 1;
            return unit;
        }
        const cp = std.unicode.utf8Decode(self.bytes[self.pos .. self.pos + len]) catch {
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
