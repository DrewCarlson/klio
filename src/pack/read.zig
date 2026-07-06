//! Pack reader. Validates the header, the pack hash, and decodes the
//! section directory eagerly; section payloads are decoded on demand.
//!
//! The byte-level deserializer mirrors `write.zig`'s postcard encoder.
//! Sections marked `Zstd`/`ZstdDict` are decompressed through the system
//! zstd library; the mmap-backed constructor for large packs is reserved
//! for a later stage.

const std = @import("std");
const Allocator = std.mem.Allocator;

const format = @import("format.zig");
const errors = @import("errors.zig");
const zstd = @import("zstd.zig");
const PackError = errors.PackError;
const section_names = format.section_names;
const Compression = format.Compression;
const SectionDirectory = format.SectionDirectory;
const SectionEntry = format.SectionEntry;

/// Result of reading a section: either a slice borrowed from the reader's
/// bytes (uncompressed sections) or an owned buffer (decompressed). The
/// caller frees `owned` buffers with the reader's allocator.
pub const SectionBytes = union(enum) {
    borrowed: []const u8,
    owned: []u8,

    pub fn slice(self: SectionBytes) []const u8 {
        return switch (self) {
            .borrowed => |b| b,
            .owned => |o| o,
        };
    }

    pub fn deinit(self: SectionBytes, allocator: Allocator) void {
        switch (self) {
            .borrowed => {},
            .owned => |o| allocator.free(o),
        }
    }
};

/// Parsed view over a pack's bytes. The bytes are owned by the reader and
/// kept alive for its lifetime; payload accessors return borrowed slices
/// for uncompressed sections and owned buffers for compressed ones.
pub const PackReader = struct {
    allocator: Allocator,
    bytes: []u8,
    dir: SectionDirectory,
    payload_start: usize,

    /// Construct a reader by loading the file at `path` into a single
    /// owned allocation, then delegating to `fromBytes`. The mmap-backed
    /// constructor for large packs is reserved for a later stage. On a
    /// file-read failure `result` is set to `.Compression` and `null` is
    /// returned.
    pub fn fromPath(allocator: Allocator, path: []const u8, result: *PackError) Allocator.Error!?PackReader {
        var threaded: std.Io.Threaded = .init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                result.* = .{ .Compression = @errorName(e) };
                return null;
            },
        };
        return fromBytes(allocator, bytes, result);
    }

    /// Construct a reader from a complete pack byte stream. Takes
    /// ownership of `bytes` (frees them in `deinit`). Verifies the magic,
    /// format version, and pack hash; rejects truncated streams. On error
    /// `bytes` are freed and `null` is returned with `result` set.
    pub fn fromBytes(allocator: Allocator, bytes: []u8, result: *PackError) Allocator.Error!?PackReader {
        const buf = bytes;
        if (buf.len < format.HASHED_REGION_OFFSET + 4) {
            allocator.free(bytes);
            result.* = .Truncated;
            return null;
        }
        if (!std.mem.eql(u8, buf[0..4], format.MAGIC)) {
            allocator.free(bytes);
            result.* = .BadMagic;
            return null;
        }
        const version = std.mem.readInt(u32, buf[4..8], .little);
        if (version != format.FORMAT_VERSION) {
            allocator.free(bytes);
            result.* = .{ .VersionMismatch = .{ .expected = format.FORMAT_VERSION, .found = version } };
            return null;
        }
        var stored_hash: [format.HASH_LEN]u8 = undefined;
        @memcpy(&stored_hash, buf[format.HASH_OFFSET .. format.HASH_OFFSET + format.HASH_LEN]);
        var computed: [format.HASH_LEN]u8 = undefined;
        std.crypto.hash.Blake3.hash(buf[format.HASHED_REGION_OFFSET..], &computed, .{});
        if (!std.mem.eql(u8, &computed, &stored_hash)) {
            allocator.free(bytes);
            result.* = .HashMismatch;
            return null;
        }

        const dir_len: usize = std.mem.readInt(u32, buf[format.HASHED_REGION_OFFSET..][0..4], .little);
        const dir_start = format.HASHED_REGION_OFFSET + 4;
        const dir_end = std.math.add(usize, dir_start, dir_len) catch {
            allocator.free(bytes);
            result.* = .Truncated;
            return null;
        };
        if (dir_end > buf.len) {
            allocator.free(bytes);
            result.* = .Truncated;
            return null;
        }
        var cursor = Cursor{ .bytes = buf[dir_start..dir_end] };
        const dir = decodeValue(SectionDirectory, allocator, &cursor) catch |e| switch (e) {
            error.OutOfMemory => {
                allocator.free(bytes);
                return error.OutOfMemory;
            },
            error.Malformed => {
                allocator.free(bytes);
                result.* = .{ .Decode = "section directory is malformed" };
                return null;
            },
        };
        const payload_start = dir_end;
        for (dir.entries) |e| {
            const end = std.math.add(u64, e.offset, e.stored_len) catch {
                freeDir(allocator, dir);
                allocator.free(bytes);
                result.* = .Truncated;
                return null;
            };
            const abs = std.math.add(u64, @as(u64, payload_start), end) catch {
                freeDir(allocator, dir);
                allocator.free(bytes);
                result.* = .Truncated;
                return null;
            };
            if (abs > buf.len) {
                freeDir(allocator, dir);
                allocator.free(bytes);
                result.* = .Truncated;
                return null;
            }
        }
        return PackReader{
            .allocator = allocator,
            .bytes = bytes,
            .dir = dir,
            .payload_start = payload_start,
        };
    }

    pub fn deinit(self: *PackReader) void {
        freeDir(self.allocator, self.dir);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    /// Pack format version recorded in the header.
    pub fn formatVersion(self: *const PackReader) u32 {
        _ = self;
        return format.FORMAT_VERSION;
    }

    /// Borrow the directory entries (sorted by name).
    pub fn sections(self: *const PackReader) []const SectionEntry {
        return self.dir.entries;
    }

    /// Number of well-known + unknown sections in the directory.
    pub fn sectionCount(self: *const PackReader) usize {
        return self.dir.entries.len;
    }

    /// Look up a section name by directory index.
    pub fn sectionName(self: *const PackReader, index: usize) []const u8 {
        return self.dir.entries[index].name;
    }

    /// Read a section by name. Returns `null` when the section is absent.
    /// Uncompressed sections borrow from the reader's bytes; compressed
    /// sections allocate and are owned by the caller.
    pub fn readSection(self: *const PackReader, name: []const u8, result: *PackError) Allocator.Error!?SectionBytes {
        const entry = self.findEntry(name) orelse return null;
        const start = self.payload_start + @as(usize, @intCast(entry.offset));
        const end = start + @as(usize, @intCast(entry.stored_len));
        const stored = self.bytes[start..end];
        switch (entry.compression) {
            .None => return SectionBytes{ .borrowed = stored },
            .Zstd => {
                const out = zstd.decompress(self.allocator, stored, @intCast(entry.uncompressed_len)) catch |e| {
                    switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.ZstdFailed => {
                            result.* = .{ .Compression = zstd.last_error };
                            return null;
                        },
                    }
                };
                return SectionBytes{ .owned = out };
            },
            .ZstdDict => {
                const dict_entry = self.findEntry(section_names.ZSTD_DICT) orelse {
                    result.* = .{ .Compression = "section is zstd_dict compressed but the pack has no zstd_dict section" };
                    return null;
                };
                const dict_start = self.payload_start + @as(usize, @intCast(dict_entry.offset));
                const dict_end = dict_start + @as(usize, @intCast(dict_entry.stored_len));
                const dict = self.bytes[dict_start..dict_end];
                const out = zstd.decompressDict(
                    self.allocator,
                    stored,
                    dict,
                    @intCast(entry.uncompressed_len),
                ) catch |e| {
                    switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.ZstdFailed => {
                            result.* = .{ .Compression = zstd.last_error };
                            return null;
                        },
                    }
                };
                return SectionBytes{ .owned = out };
            },
        }
    }

    /// Compute the pack hash as stored in the header.
    pub fn packHash(self: *const PackReader) [format.HASH_LEN]u8 {
        var hash: [format.HASH_LEN]u8 = undefined;
        @memcpy(&hash, self.bytes[format.HASH_OFFSET .. format.HASH_OFFSET + format.HASH_LEN]);
        return hash;
    }

    fn findEntry(self: *const PackReader, name: []const u8) ?SectionEntry {
        for (self.dir.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }
};

fn freeDir(allocator: Allocator, dir: SectionDirectory) void {
    var d = dir;
    d.deinit(allocator);
}

/// Decode a section payload into a value of type `T`. The caller owns any
/// heap data inside the result and frees it with the value's `deinit`. On
/// failure `result` is set and `null` is returned.
pub fn decode(
    comptime T: type,
    allocator: Allocator,
    bytes: []const u8,
    result: *PackError,
) Allocator.Error!?T {
    var cursor = Cursor{ .bytes = bytes };
    return decodeValue(T, allocator, &cursor) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Malformed => {
            result.* = .{ .Decode = "input is malformed" };
            return null;
        },
    };
}

// ---------------------------------------------------------------------
// postcard wire format decoder
// ---------------------------------------------------------------------

const DecodeError = error{ OutOfMemory, Malformed };

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, n: usize) DecodeError![]const u8 {
        if (self.pos + n > self.bytes.len) return error.Malformed;
        const out = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    fn byte(self: *Cursor) DecodeError!u8 {
        const s = try self.take(1);
        return s[0];
    }

    fn varint(self: *Cursor) DecodeError!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try self.byte();
            result |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) break;
            if (shift >= 63) return error.Malformed;
            shift += 7;
        }
        return result;
    }
};

fn decodeValue(comptime T: type, allocator: Allocator, c: *Cursor) DecodeError!T {
    const info = @typeInfo(T);
    switch (info) {
        .bool => return (try c.byte()) != 0,
        .int => return decodeInt(T, c),
        .float => {
            const s = try c.take(@sizeOf(T));
            return std.mem.bytesToValue(T, s);
        },
        .@"enum" => |e| {
            const v = try c.varint();
            const raw = std.math.cast(e.tag_type, v) orelse return error.Malformed;
            return std.enums.fromInt(T, raw) orelse error.Malformed;
        },
        .optional => |o| {
            const tag = try c.byte();
            if (tag == 0) return null;
            return try decodeValue(o.child, allocator, c);
        },
        .pointer => |p| {
            switch (p.size) {
                .slice => {
                    const len: usize = @intCast(try c.varint());
                    if (p.child == u8) {
                        const src = try c.take(len);
                        return try allocator.dupe(u8, src);
                    }
                    const out = try allocator.alloc(p.child, len);
                    var filled: usize = 0;
                    errdefer freePartialSlice(p.child, allocator, out, filled);
                    while (filled < len) : (filled += 1) {
                        out[filled] = try decodeValue(p.child, allocator, c);
                    }
                    return out;
                },
                .one => {
                    const ptr = try allocator.create(p.child);
                    errdefer allocator.destroy(ptr);
                    ptr.* = try decodeValue(p.child, allocator, c);
                    return ptr;
                },
                else => @compileError("unsupported pointer kind in pack decode: " ++ @typeName(T)),
            }
        },
        .@"struct" => |s| {
            if (comptime isPackedFlags(T)) {
                const raw = try decodeInt(s.backing_integer.?, c);
                return @bitCast(raw);
            }
            var value: T = undefined;
            inline for (s.fields) |f| {
                @field(value, f.name) = try decodeValue(f.type, allocator, c);
            }
            return value;
        },
        .@"union" => |u| {
            const tag = try c.varint();
            inline for (u.fields, 0..) |f, idx| {
                if (idx == tag) {
                    if (f.type == void) {
                        return @unionInit(T, f.name, {});
                    }
                    return @unionInit(T, f.name, try decodeValue(f.type, allocator, c));
                }
            }
            return error.Malformed;
        },
        else => @compileError("unsupported type in pack decode: " ++ @typeName(T)),
    }
}

fn decodeInt(comptime T: type, c: *Cursor) DecodeError!T {
    const info = @typeInfo(T).int;
    if (info.bits <= 8) {
        return @bitCast(try c.byte());
    }
    if (info.signedness == .signed) {
        const zz = try c.varint();
        const u: u64 = zz;
        const decoded: i64 = @bitCast((u >> 1) ^ (~(u & 1) +% 1));
        return std.math.cast(T, decoded) orelse error.Malformed;
    }
    const v = try c.varint();
    return std.math.cast(T, v) orelse error.Malformed;
}

fn freePartialSlice(comptime T: type, allocator: Allocator, slice: []T, filled: usize) void {
    const has_deinit = comptime hasDeinit(T);
    var i: usize = 0;
    while (i < filled) : (i += 1) {
        if (has_deinit) slice[i].deinit(allocator);
    }
    allocator.free(slice);
}

fn hasDeinit(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "deinit"),
        else => false,
    };
}

fn isPackedFlags(comptime T: type) bool {
    const s = @typeInfo(T).@"struct";
    return s.layout == .@"packed" and s.backing_integer != null;
}

test "varint decode round-trips LEB128" {
    var c = Cursor{ .bytes = &.{ 0xac, 0x02 } };
    try std.testing.expectEqual(@as(u64, 300), try c.varint());
}

test "fromPath loads and validates a written pack" {
    const a = std.testing.allocator;
    const write = @import("write.zig");
    const io = std.testing.io;

    var err: PackError = undefined;
    var w = write.PackWriter.init(a);
    defer w.deinit();
    _ = try w.addRaw(section_names.MANIFEST, "manifest-bytes");
    var bytes = (try w.finish(&err)).?;
    defer bytes.deinit(a);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.kliopack", .data = bytes.items });
    const path = try tmp.dir.realPathFileAlloc(io, "lib.kliopack", a);
    defer a.free(path);

    var reader = (try PackReader.fromPath(a, path, &err)).?;
    defer reader.deinit();
    try std.testing.expectEqual(@as(usize, 1), reader.sectionCount());
    const got = (try reader.readSection(section_names.MANIFEST, &err)).?;
    try std.testing.expectEqualSlices(u8, "manifest-bytes", got.slice());
}

test "fromPath reports a missing file" {
    const a = std.testing.allocator;
    var err: PackError = undefined;
    const reader = try PackReader.fromPath(a, "definitely-not-a-real-pack.kliopack", &err);
    try std.testing.expect(reader == null);
    try std.testing.expect(err == .Compression);
}
