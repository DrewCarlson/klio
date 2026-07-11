//! On-disk format constants and shared types for `.klio-pack` files.
//!
//! A pack is a single file:
//!
//! ```text
//! +-------------------------+
//! | magic       "KPK\0"     |  4 bytes
//! | version     u32 LE      |  4
//! | flags       u32 LE      |  4
//! | pack_hash   [u8; 32]    | 32   blake3 of every byte after this field
//! | dir_len     u32 LE      |  4
//! | dir         [u8; ...]   |      postcard-encoded SectionDirectory
//! | payloads    [u8; ...]   |      concatenated section bodies
//! +-------------------------+
//! ```
//!
//! The directory lists every section; each entry records its offset
//! (relative to the start of the payload area), on-disk length, the
//! uncompressed length when `Compression.Zstd` is in use, and a
//! compression tag. Readers may skip unknown sections without
//! understanding their contents.

const std = @import("std");

/// Magic bytes at the start of every pack file.
pub const MAGIC: *const [4]u8 = "KPK\x00";

/// Pack format version. Bumped when the on-disk layout or the
/// `SectionDirectory` schema changes incompatibly. v2 added pack
/// features (`PackManifest.default_features`/`features`, per-dependency
/// `features`/`default_features`); postcard is sequential, so old packs
/// are rejected on read and must be rebuilt.
pub const FORMAT_VERSION: u32 = 2;

/// Length of the blake3 pack hash, in bytes.
pub const HASH_LEN: usize = 32;

/// Compression scheme applied to a section payload.
pub const Compression = enum(u8) {
    None = 0,
    Zstd = 1,
    /// zstd compressed against the dictionary bytes carried in
    /// this pack's `zstd_dict` section. Section is rejected if
    /// the pack does not carry a matching dictionary.
    ZstdDict = 2,
};

/// Directory entry for one section. Names are case-sensitive byte strings;
/// well-known names are listed under `section_names`.
pub const SectionEntry = struct {
    /// Section name (e.g. `"manifest"`). Owned.
    name: []const u8,
    /// Offset of the section payload from the start of the payload area.
    offset: u64,
    /// On-disk length of the payload (compressed when `compression != None`).
    stored_len: u64,
    /// Uncompressed length. Equal to `stored_len` for `Compression.None`.
    uncompressed_len: u64,
    /// Compression scheme applied to the payload bytes.
    compression: Compression,

    pub fn clone(self: SectionEntry, allocator: std.mem.Allocator) std.mem.Allocator.Error!SectionEntry {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .offset = self.offset,
            .stored_len = self.stored_len,
            .uncompressed_len = self.uncompressed_len,
            .compression = self.compression,
        };
    }

    pub fn deinit(self: *SectionEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

/// Sorted directory of section entries. Sections are ordered by name so
/// the encoded directory is byte-deterministic for a given input set.
pub const SectionDirectory = struct {
    entries: []SectionEntry = &.{},

    pub const empty: SectionDirectory = .{ .entries = &.{} };

    pub fn deinit(self: *SectionDirectory, allocator: std.mem.Allocator) void {
        for (self.entries) |*e| e.deinit(allocator);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

/// Well-known section names. Sections outside this list are still legal —
/// readers must tolerate them — but tooling keys off these constants.
pub const section_names = struct {
    pub const MANIFEST: []const u8 = "manifest";
    /// Raw `.kt` source bytes carried in the pack. The interpreter
    /// parses these at install time. Frozen AST sections (`ast`,
    /// `resolved`, `typeck`) are reserved for a later phase that
    /// adds serde derives across the front-end crates.
    pub const SOURCES: []const u8 = "sources";
    /// Precomputed per-source package + import paths (`schema.ImportsBundle`),
    /// derived from the same parse that fills `ast`. Optional; loaders that
    /// need only the import graph read this instead of parsing `sources`.
    pub const IMPORTS: []const u8 = "imports";
    pub const AST: []const u8 = "ast";
    pub const RESOLVED: []const u8 = "resolved";
    pub const TYPECK: []const u8 = "typeck";
    pub const SYMBOLS: []const u8 = "symbols";
    pub const BINDINGS: []const u8 = "bindings";
    pub const TESTS: []const u8 = "tests";
    pub const DEBUG: []const u8 = "debug";
    /// Raw zstd dictionary bytes. When present, sections marked
    /// `Compression.ZstdDict` decode against these bytes.
    pub const ZSTD_DICT: []const u8 = "zstd_dict";
};

/// Byte offset of the `dir_len` u32 inside the file header. Useful for
/// readers walking the header without recomputing the layout.
pub const DIR_LEN_OFFSET: usize = 4 + 4 + 4 + HASH_LEN;

/// Byte offset where the hashed region begins. Everything from this
/// offset to end-of-file participates in `pack_hash`.
pub const HASHED_REGION_OFFSET: usize = DIR_LEN_OFFSET;

/// Byte offset of the `pack_hash` field inside the header.
pub const HASH_OFFSET: usize = 4 + 4 + 4;

test "magic and header offsets are stable" {
    try std.testing.expectEqualSlices(u8, "KPK\x00", MAGIC);
    try std.testing.expectEqual(@as(usize, 4), MAGIC.len);
    try std.testing.expectEqual(@as(usize, 12), HASH_OFFSET);
    try std.testing.expectEqual(@as(usize, 44), DIR_LEN_OFFSET);
    try std.testing.expectEqual(@as(usize, 44), HASHED_REGION_OFFSET);
    try std.testing.expectEqual(@as(usize, 32), HASH_LEN);
}

test "compression tags match repr(u8)" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Compression.None));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Compression.Zstd));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Compression.ZstdDict));
}
