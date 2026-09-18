//! Hashing for the interpreter's name-keyed tables.
//!
//! Every side table the image carries is keyed by a declaration name, and the
//! steady-state interpreter probes them on every field read, every member
//! dispatch and every global lookup. `std.hash_map.StringContext` runs Wyhash
//! over the bytes for each of those, which on a profile of a recomposer frame
//! is the single largest block of self time outside the evaluator itself.
//!
//! Declaration names are short — almost all under 32 bytes — so the mixing a
//! general-purpose hash does for long inputs is pure cost here. `hashName`
//! folds eight bytes at a time with one multiply per word and finishes with a
//! full avalanche, which keeps the bucket distribution a hash table needs
//! while costing a few instructions on the lengths that actually occur.
//!
//! Equality exploits what the tables guarantee: names are canonicalized to
//! program-lifetime strings, so an identical pointer is an identical name and
//! the byte compare only runs for a key that reached the table uncanonicalized.

const std = @import("std");

const mul: u64 = 0xD6E8FEB86659FD93;
const seed: u64 = 0x9E3779B97F4A7C15;

/// The name hash. Wyhash, the same function `std.hash_map.StringContext` runs:
/// a cheaper mixer measured WORSE, because at this table's load factor the
/// probe length a weaker hash costs is larger than the mixing it saves.
pub fn hashName(key: []const u8) u64 {
    return std.hash.Wyhash.hash(0, key);
}

/// Mixes an already-hashed word into a second one, for a composite key.
pub inline fn mixHash(a: u64, b: u64) u64 {
    var h = (a ^ b) *% mul;
    h ^= h >> 31;
    return h;
}

pub inline fn eqlName(a: []const u8, b: []const u8) bool {
    if (a.ptr == b.ptr and a.len == b.len) return true;
    return std.mem.eql(u8, a, b);
}

/// Drop-in replacement for `std.hash_map.StringContext`.
pub const NameContext = struct {
    pub fn hash(_: NameContext, key: []const u8) u64 {
        return hashName(key);
    }
    pub fn eql(_: NameContext, a: []const u8, b: []const u8) bool {
        return eqlName(a, b);
    }
};

/// A lookup whose hash the caller already computed, for a chain that probes the
/// same name at several levels.
pub const PrehashedName = struct {
    h: u64,
    pub fn hash(self: PrehashedName, _: []const u8) u64 {
        return self.h;
    }
    pub fn eql(_: PrehashedName, a: []const u8, b: []const u8) bool {
        return eqlName(a, b);
    }
};

pub fn NameHashMap(comptime V: type) type {
    return std.HashMap([]const u8, V, NameContext, std.hash_map.default_max_load_percentage);
}

pub fn NameHashMapUnmanaged(comptime V: type) type {
    return std.HashMapUnmanaged([]const u8, V, NameContext, std.hash_map.default_max_load_percentage);
}

test "hashName separates the names a program actually uses" {
    const names = [_][]const u8{
        "", "a", "ab", "key", "value", "context", "length", "intValue",
        "startRestartGroup", "endRestartGroup",  "updateChangedFlags",
        "androidx.compose.runtime.Composer",     "$composer", "$changed",
    };
    var seen = std.AutoHashMap(u64, usize).init(std.testing.allocator);
    defer seen.deinit();
    for (names, 0..) |n, i| {
        const h = hashName(n);
        try std.testing.expect(seen.get(h) == null);
        try seen.put(h, i);
    }
}

test "hashName agrees with itself across slices of the same bytes" {
    const buf = "startRestartGroup";
    const a: []const u8 = buf[0..];
    const b: []const u8 = buf[0..buf.len];
    try std.testing.expectEqual(hashName(a), hashName(b));
    try std.testing.expect(eqlName(a, b));
}
