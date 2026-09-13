//! Pack writer, deterministic. The byte-level serializer is the postcard wire
//! format: little varints for multi-byte integers, length-prefixed sequences
//! and byte strings, single-byte bool and `Option` tags, in-order struct
//! fields. A `ZstdDict` section compresses against the pack's dictionary, which
//! ships as a `zstd_dict` section so readers need no out-of-band state.

const std = @import("std");
const Allocator = std.mem.Allocator;

const format = @import("format.zig");
const errors = @import("errors.zig");
const zstd = @import("zstd.zig");
const PackError = errors.PackError;
const Compression = format.Compression;
const SectionDirectory = format.SectionDirectory;
const SectionEntry = format.SectionEntry;
const section_names = format.section_names;

/// Level 3 encodes fast and decompresses near memcpy speed.
pub const DEFAULT_ZSTD_LEVEL: i32 = 3;

const PendingSection = struct {
    name: []const u8,
    payload: []const u8,
    compression: Compression,
};

/// Sections are added in any order and sorted at finish, so output is stable.
pub const PackWriter = struct {
    allocator: Allocator,
    sections: std.ArrayList(PendingSection) = .empty,
    flags: u32 = 0,
    /// Sections added through `addZstdDict` compress against it, and it ships
    /// as a `zstd_dict` section.
    zstd_dict: ?[]const u8 = null,

    pub fn init(allocator: Allocator) PackWriter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PackWriter) void {
        self.sections.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setFlags(self: *PackWriter, flags: u32) *PackWriter {
        self.flags = flags;
        return self;
    }

    /// `name` must be unique; duplicates are rejected at `finish`. `name` and
    /// `payload` are borrowed and must outlive `finish`.
    pub fn addSection(
        self: *PackWriter,
        name: []const u8,
        payload: []const u8,
        compression: Compression,
    ) Allocator.Error!*PackWriter {
        try self.sections.append(self.allocator, .{
            .name = name,
            .payload = payload,
            .compression = compression,
        });
        return self;
    }

    pub fn addRaw(self: *PackWriter, name: []const u8, payload: []const u8) Allocator.Error!*PackWriter {
        return self.addSection(name, payload, .None);
    }

    pub fn addZstd(self: *PackWriter, name: []const u8, payload: []const u8) Allocator.Error!*PackWriter {
        return self.addSection(name, payload, .Zstd);
    }

    /// Errors at `finish` without a prior `setZstdDict`.
    pub fn addZstdDict(self: *PackWriter, name: []const u8, payload: []const u8) Allocator.Error!*PackWriter {
        return self.addSection(name, payload, .ZstdDict);
    }

    pub fn setZstdDict(self: *PackWriter, bytes: []const u8) *PackWriter {
        self.zstd_dict = bytes;
        return self;
    }

/// Deterministic for a given set of sections; the caller owns the buffer.
    pub fn finish(self: *PackWriter, result: *PackError) Allocator.Error!?std.ArrayList(u8) {
        const a = self.allocator;

        // An explicitly added `zstd_dict` section wins over the attached one.
        if (self.zstd_dict) |dict| {
            var has_dict = false;
            for (self.sections.items) |s| {
                if (std.mem.eql(u8, s.name, section_names.ZSTD_DICT)) {
                    has_dict = true;
                    break;
                }
            }
            if (!has_dict) {
                try self.sections.append(a, .{
                    .name = section_names.ZSTD_DICT,
                    .payload = dict,
                    .compression = .None,
                });
            }
        }

        // Sort by name so directory and payload ordering are stable.
        std.mem.sort(PendingSection, self.sections.items, {}, lessByName);
        var i: usize = 1;
        while (i < self.sections.items.len) : (i += 1) {
            if (std.mem.eql(u8, self.sections.items[i].name, self.sections.items[i - 1].name)) {
                result.* = .{ .DuplicateSection = self.sections.items[i].name };
                return null;
            }
        }

        var payloads: std.ArrayList(u8) = .empty;
        defer payloads.deinit(a);
        var entries: std.ArrayList(SectionEntry) = .empty;
        defer entries.deinit(a);

        for (self.sections.items) |s| {
            const uncompressed_len: u64 = s.payload.len;
            var owned_stored: ?[]u8 = null;
            defer if (owned_stored) |o| a.free(o);
            const stored: []const u8 = switch (s.compression) {
                .None => s.payload,
                .Zstd => blk: {
                    const buf = zstd.compress(a, s.payload, DEFAULT_ZSTD_LEVEL) catch |e| {
                        switch (e) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.ZstdFailed => {
                                result.* = .{ .Compression = zstd.last_error };
                                return null;
                            },
                        }
                    };
                    owned_stored = buf;
                    break :blk buf;
                },
                .ZstdDict => blk: {
                    const dict = self.zstd_dict orelse {
                        result.* = .{ .Compression = "section requests zstd_dict compression but the pack has no dictionary" };
                        return null;
                    };
                    const buf = zstd.compressDict(a, s.payload, dict, DEFAULT_ZSTD_LEVEL) catch |e| {
                        switch (e) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.ZstdFailed => {
                                result.* = .{ .Compression = zstd.last_error };
                                return null;
                            },
                        }
                    };
                    owned_stored = buf;
                    break :blk buf;
                },
            };
            const offset: u64 = payloads.items.len;
            const stored_len: u64 = stored.len;
            try payloads.appendSlice(a, stored);
            try entries.append(a, .{
                .name = s.name,
                .offset = offset,
                .stored_len = stored_len,
                .uncompressed_len = uncompressed_len,
                .compression = s.compression,
            });
        }

        const dir = SectionDirectory{ .entries = entries.items };
        var dir_buf: std.ArrayList(u8) = .empty;
        defer dir_buf.deinit(a);
        try encodeValue(SectionDirectory, a, &dir_buf, dir);
        if (dir_buf.items.len > std.math.maxInt(u32)) {
            result.* = .{ .DirectoryTooLarge = dir_buf.items.len };
            return null;
        }
        const dir_len: u32 = @intCast(dir_buf.items.len);

        // Layout matches format.zig.
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try out.ensureTotalCapacity(a, format.HASHED_REGION_OFFSET + 4 + dir_buf.items.len + payloads.items.len);
        try out.appendSlice(a, format.MAGIC);
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, format.FORMAT_VERSION)));
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, self.flags)));
        const hash_slot = out.items.len;
        try out.appendNTimes(a, 0, format.HASH_LEN);
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, dir_len)));
        try out.appendSlice(a, dir_buf.items);
        try out.appendSlice(a, payloads.items);

        // Hash everything after the hash field.
        var hash: [format.HASH_LEN]u8 = undefined;
        std.crypto.hash.Blake3.hash(out.items[hash_slot + format.HASH_LEN ..], &hash, .{});
        @memcpy(out.items[hash_slot .. hash_slot + format.HASH_LEN], &hash);

        return out;
    }
};

fn lessByName(_: void, a: PendingSection, b: PendingSection) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Caller owns the buffer; on failure `result` is set and null returned.
pub fn encode(
    comptime T: type,
    allocator: Allocator,
    value: *const T,
    result: *PackError,
) Allocator.Error!?std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    encodeValue(T, allocator, &out, value.*) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    _ = result;
    return out;
}

fn encodeValue(comptime T: type, allocator: Allocator, out: *std.ArrayList(u8), value: T) Allocator.Error!void {
    const info = @typeInfo(T);
    switch (info) {
        .bool => try out.append(allocator, if (value) 1 else 0),
        .int => try encodeInt(T, allocator, out, value),
        // IEEE-754 bit pattern, little-endian, so the stream is host-independent.
        .float => {
            const Bits = std.meta.Int(.unsigned, @bitSizeOf(T));
            const raw: Bits = @bitCast(value);
            try out.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(Bits, raw)));
        },
        .@"enum" => |e| try encodeVarint(allocator, out, @as(u64, @intCast(@as(e.tag_type, @intFromEnum(value))))),
        .optional => |o| {
            if (value) |v| {
                try out.append(allocator, 1);
                try encodeValue(o.child, allocator, out, v);
            } else {
                try out.append(allocator, 0);
            }
        },
        .pointer => |p| {
            switch (p.size) {
                .slice => {
                    if (p.child == u8) {
                        try encodeVarint(allocator, out, value.len);
                        try out.appendSlice(allocator, value);
                    } else {
                        try encodeVarint(allocator, out, value.len);
                        for (value) |elem| try encodeValue(p.child, allocator, out, elem);
                    }
                },
                .one => try encodeValue(p.child, allocator, out, value.*),
                else => @compileError("unsupported pointer kind in pack encode: " ++ @typeName(T)),
            }
        },
        .@"struct" => |s| {
            if (comptime isPackedFlags(T)) {
                try encodeInt(s.backing_integer.?, allocator, out, @bitCast(value));
            } else {
                inline for (s.fields) |f| {
                    try encodeValue(f.type, allocator, out, @field(value, f.name));
                }
            }
        },
        .@"union" => |u| {
            const tag = @as(std.meta.Tag(T), value);
            const tag_int = @intFromEnum(tag);
            try encodeVarint(allocator, out, @intCast(tag_int));
            inline for (u.fields, 0..) |f, idx| {
                if (idx == tag_int) {
                    if (f.type != void) {
                        try encodeValue(f.type, allocator, out, @field(value, f.name));
                    }
                }
            }
        },
        else => @compileError("unsupported type in pack encode: " ++ @typeName(T)),
    }
}

fn encodeInt(comptime T: type, allocator: Allocator, out: *std.ArrayList(u8), value: T) Allocator.Error!void {
    const info = @typeInfo(T).int;
    if (info.bits <= 8) {
        try out.append(allocator, @bitCast(value));
        return;
    }
    if (info.signedness == .signed) {
        // zigzag, then varint.
        const wide: i64 = value;
        const zz: u64 = @bitCast((wide << 1) ^ (wide >> 63));
        try encodeVarint(allocator, out, zz);
    } else {
        try encodeVarint(allocator, out, @intCast(value));
    }
}

fn encodeVarint(allocator: Allocator, out: *std.ArrayList(u8), value: u64) Allocator.Error!void {
    var v = value;
    while (true) {
        const byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v == 0) {
            try out.append(allocator, byte);
            break;
        }
        try out.append(allocator, byte | 0x80);
    }
}

fn isPackedFlags(comptime T: type) bool {
    const s = @typeInfo(T).@"struct";
    return s.layout == .@"packed" and s.backing_integer != null;
}

test "float encodes as little-endian IEEE-754 bits" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try encodeValue(f64, a, &out, 1.5);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0xf8, 0x3f }, out.items);
    out.clearRetainingCapacity();
    try encodeValue(f32, a, &out, -2.25);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0x10, 0xc0 }, out.items);
}

test "varint matches postcard LEB128" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try encodeVarint(a, &out, 0);
    try std.testing.expectEqualSlices(u8, &.{0x00}, out.items);
    out.clearRetainingCapacity();
    try encodeVarint(a, &out, 127);
    try std.testing.expectEqualSlices(u8, &.{0x7f}, out.items);
    out.clearRetainingCapacity();
    try encodeVarint(a, &out, 128);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, out.items);
    out.clearRetainingCapacity();
    try encodeVarint(a, &out, 300);
    try std.testing.expectEqualSlices(u8, &.{ 0xac, 0x02 }, out.items);
}
