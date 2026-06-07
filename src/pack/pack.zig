//! `pack` — on-disk module format for the klio interpreter.
//!
//! A pack bundles a library's parsed AST, resolved symbols, type-check
//! side tables, public symbol index, and optional native-binding manifest
//! into a single byte stream that the interpreter can load without
//! re-running the front end. The same format is used by the Kotlin
//! standard library, by kotlinx modules, and by user libraries.
//!
//! The core of this crate is the on-disk container: header layout,
//! section directory, deterministic writer, validating reader, and
//! optional per-section zstd compression. Higher-level schemas (manifest,
//! symbol index, bindings, AST bundle, source bundle) live in `schema`.

const std = @import("std");

pub const format = @import("format.zig");
pub const schema = @import("schema.zig");
pub const read = @import("read.zig");
pub const write = @import("write.zig");

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

/// Highest ABI version this build of klio supports. Pack manifests
/// declare an `abi_version`; the loader rejects packs whose ABI is
/// greater than this value. Bump when the host-binding signature, the
/// runtime value shape, or any other runtime-binding contract changes.
pub const SUPPORTED_ABI_VERSION: u32 = 1;

test {
    std.testing.refAllDecls(@This());
    _ = format;
    _ = schema;
    _ = read;
    _ = write;
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
    // Hash is recomputed by the reader; if it disagreed we'd have bailed
    // before reaching this point.
    _ = reader.packHash();

    // Re-encoding empty produces identical bytes.
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
    // Intentionally out-of-order: the writer must sort.
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

    // Insertion order is the opposite of what the writer should emit, to
    // make a non-deterministic implementation visible.
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

    // Flip a byte inside the payload area. The header hash should catch it
    // on the next read.
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
    // The zstd codec is reserved for a later stage; the directory layout
    // and entry points are in place. Restore this once the compressor
    // lands.
    return error.SkipZigTest;
}

test "zstd dict round trip" {
    // The zstd codec is reserved for a later stage; see above.
    return error.SkipZigTest;
}
