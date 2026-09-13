//! On-disk module format for the klio interpreter: one byte stream carrying a
//! library's parsed AST, resolved symbols, type-check side tables, public
//! symbol index and native-binding manifest, loaded without re-running the
//! front end. This module is the container (header, section directory,
//! deterministic writer, validating reader, per-section zstd); the schemas live
//! in `schema`.

const std = @import("std");

pub const format = @import("format.zig");
pub const schema = @import("schema.zig");
pub const read = @import("read.zig");
pub const write = @import("write.zig");
pub const bundle_format = @import("bundle_format.zig");
pub const zstd = @import("zstd.zig");

pub const Compression = format.Compression;
pub const FORMAT_VERSION = format.FORMAT_VERSION;
pub const MAGIC = format.MAGIC;
pub const SectionDirectory = format.SectionDirectory;
pub const SectionEntry = format.SectionEntry;
pub const section_names = format.section_names;

pub const PackReader = read.PackReader;
pub const DEFAULT_ZSTD_LEVEL = write.DEFAULT_ZSTD_LEVEL;
pub const PackWriter = write.PackWriter;

pub const PackError = @import("errors.zig").PackError;

/// Highest ABI version this build supports; a pack declaring more is rejected.
/// Bump when a host-binding signature or the runtime value shape changes.
pub const SUPPORTED_ABI_VERSION: u32 = 1;

test {
    std.testing.refAllDecls(@This());
    _ = format;
    _ = schema;
    _ = read;
    _ = write;
    _ = bundle_format;
    _ = @import("errors.zig");
}

test "empty pack round trip" {
    const a = std.testing.allocator;
    var err: PackError = undefined;

    var w = PackWriter.init(a);
    defer w.deinit();
    var bytes = (try w.finish(&err)).?;
    defer bytes.deinit(a);

    const owned = try a.dupe(u8, bytes.items);
    var reader = (try PackReader.fromBytes(a, owned, &err)).?;
    defer reader.deinit();
    try std.testing.expectEqual(@as(usize, 0), reader.sections().len);
    try std.testing.expectEqual(@as(usize, 0), reader.sectionCount());
    _ = reader.packHash();

    var w2 = PackWriter.init(a);
    defer w2.deinit();
    var again = (try w2.finish(&err)).?;
    defer again.deinit(a);
    try std.testing.expectEqualSlices(u8, bytes.items, again.items);
}

test "multi section round trip" {
    const a = std.testing.allocator;
    var err: PackError = undefined;

    const manifest = "manifest-bytes";
    const symbols = "symbols-bytes";
    const bindings = "bindings-bytes";

    var w = PackWriter.init(a);
    defer w.deinit();
    // Out of order on purpose: the writer must sort.
    _ = try w.addRaw(section_names.SYMBOLS, symbols);
    _ = try w.addRaw(section_names.MANIFEST, manifest);
    _ = try w.addRaw(section_names.BINDINGS, bindings);
    var bytes = (try w.finish(&err)).?;
    defer bytes.deinit(a);

    const owned = try a.dupe(u8, bytes.items);
    var reader = (try PackReader.fromBytes(a, owned, &err)).?;
    defer reader.deinit();

    const names = reader.sections();
    try std.testing.expectEqual(@as(usize, 3), names.len);
    try std.testing.expectEqualStrings(section_names.BINDINGS, names[0].name);
    try std.testing.expectEqualStrings(section_names.MANIFEST, names[1].name);
    try std.testing.expectEqualStrings(section_names.SYMBOLS, names[2].name);

    const got_manifest = (try reader.readSection(section_names.MANIFEST, &err)).?;
    const got_symbols = (try reader.readSection(section_names.SYMBOLS, &err)).?;
    const got_bindings = (try reader.readSection(section_names.BINDINGS, &err)).?;
    try std.testing.expectEqualSlices(u8, manifest, got_manifest.slice());
    try std.testing.expectEqualSlices(u8, symbols, got_symbols.slice());
    try std.testing.expectEqualSlices(u8, bindings, got_bindings.slice());
    try std.testing.expect((try reader.readSection("unknown", &err)) == null);
}

test "deterministic byte output" {
    const a = std.testing.allocator;
    var err: PackError = undefined;
    const payload_a = "payload-a";
    const payload_b = "payload-b";

    // Reverse of the emitted order, so a non-deterministic writer shows up.
    var w1 = PackWriter.init(a);
    defer w1.deinit();
    _ = try w1.addRaw("b", payload_b);
    _ = try w1.addRaw("a", payload_a);
    var first = (try w1.finish(&err)).?;
    defer first.deinit(a);

    var w2 = PackWriter.init(a);
    defer w2.deinit();
    _ = try w2.addRaw("b", payload_b);
    _ = try w2.addRaw("a", payload_a);
    var second = (try w2.finish(&err)).?;
    defer second.deinit(a);

    try std.testing.expectEqualSlices(u8, first.items, second.items);
}

test "tampered pack is rejected" {
    const a = std.testing.allocator;
    var err: PackError = undefined;

    var w = PackWriter.init(a);
    defer w.deinit();
    _ = try w.addRaw(section_names.MANIFEST, "hello");
    var bytes = (try w.finish(&err)).?;
    defer bytes.deinit(a);

    // Flip a payload byte; the header hash catches it on read.
    const owned = try a.dupe(u8, bytes.items);
    owned[owned.len - 1] ^= 0x01;
    const reader = try PackReader.fromBytes(a, owned, &err);
    try std.testing.expect(reader == null);
    try std.testing.expect(err == .HashMismatch);
}

test "duplicate section is rejected" {
    const a = std.testing.allocator;
    var err: PackError = undefined;

    var w = PackWriter.init(a);
    defer w.deinit();
    _ = try w.addRaw(section_names.MANIFEST, "one");
    _ = try w.addRaw(section_names.MANIFEST, "two");
    const out = try w.finish(&err);
    try std.testing.expect(out == null);
    try std.testing.expect(err == .DuplicateSection);
}

test "zstd section round trip" {
    const a = std.testing.allocator;
    var err: PackError = undefined;

    const payload = "klio pack zstd compressed section payload " ** 32;

    var w = PackWriter.init(a);
    defer w.deinit();
    _ = try w.addZstd(section_names.SYMBOLS, payload);
    _ = try w.addRaw(section_names.MANIFEST, "manifest-bytes");
    var bytes = (try w.finish(&err)).?;
    defer bytes.deinit(a);

    const owned = try a.dupe(u8, bytes.items);
    var reader = (try PackReader.fromBytes(a, owned, &err)).?;
    defer reader.deinit();

    const entry = blk: {
        for (reader.sections()) |e| {
            if (std.mem.eql(u8, e.name, section_names.SYMBOLS)) break :blk e;
        }
        return error.MissingSection;
    };
    try std.testing.expectEqual(Compression.Zstd, entry.compression);
    try std.testing.expectEqual(@as(u64, payload.len), entry.uncompressed_len);
    try std.testing.expect(entry.stored_len < payload.len);

    const got = (try reader.readSection(section_names.SYMBOLS, &err)).?;
    defer got.deinit(a);
    try std.testing.expectEqualSlices(u8, payload, got.slice());

    const got_manifest = (try reader.readSection(section_names.MANIFEST, &err)).?;
    defer got_manifest.deinit(a);
    try std.testing.expectEqualSlices(u8, "manifest-bytes", got_manifest.slice());
}

test "zstd dict round trip" {
    const a = std.testing.allocator;
    var err: PackError = undefined;

    const dict = "the quick brown fox jumps over the lazy dog " ** 8;
    const payload = "the quick brown fox is fast and the lazy dog is slow " ** 8;

    var w = PackWriter.init(a);
    defer w.deinit();
    _ = w.setZstdDict(dict);
    _ = try w.addZstdDict(section_names.SYMBOLS, payload);
    var bytes = (try w.finish(&err)).?;
    defer bytes.deinit(a);

    const owned = try a.dupe(u8, bytes.items);
    var reader = (try PackReader.fromBytes(a, owned, &err)).?;
    defer reader.deinit();

    // The dictionary ships as its own section, so the reader is self-contained.
    var saw_dict = false;
    var saw_symbols = false;
    for (reader.sections()) |e| {
        if (std.mem.eql(u8, e.name, section_names.ZSTD_DICT)) {
            saw_dict = true;
            try std.testing.expectEqual(Compression.None, e.compression);
        }
        if (std.mem.eql(u8, e.name, section_names.SYMBOLS)) {
            saw_symbols = true;
            try std.testing.expectEqual(Compression.ZstdDict, e.compression);
        }
    }
    try std.testing.expect(saw_dict);
    try std.testing.expect(saw_symbols);

    const got = (try reader.readSection(section_names.SYMBOLS, &err)).?;
    defer got.deinit(a);
    try std.testing.expectEqualSlices(u8, payload, got.slice());

    const got_dict = (try reader.readSection(section_names.ZSTD_DICT, &err)).?;
    defer got_dict.deinit(a);
    try std.testing.expectEqualSlices(u8, dict, got_dict.slice());
}
