//! Bundle container for `klio bundle`: a stub executable followed by an
//! aligned payload area and a fixed-size trailer at a known position
//! (EOF on ELF/PE; before the code-signature blob on Mach-O).
//!
//! ```text
//! +--------------------------------------------------+
//! | stub executable (byte-identical to the release)  |
//! | padding to 16384-byte alignment                  |
//! | payload area:                                    |
//! |   sections, each 16384-aligned when mmap-target  |
//! |   section table (postcard)                       |
//! | trailer (72 bytes):                              |
//! |   magic      "KBND\0KL1"  8 bytes                |
//! |   payload_off u64 LE                             |
//! |   payload_len u64 LE                             |
//! |   table_off   u64 LE   (absolute)                |
//! |   table_len   u64 LE                             |
//! |   payload_hash [32]    blake3 of payload area    |
//! +--------------------------------------------------+
//! ```
//!
//! Section payloads and the manifest use the pack module's postcard codec
//! (`write.encode` / `read.decode`). Image sections (`base-image`,
//! `program-image`) are stored uncompressed and 16384-aligned so the boot
//! path can mmap them straight out of the executable file (16 KiB covers
//! macOS arm64 pages, so one constant serves every target). Cold sections
//! (resources, the Skia shim) compress with zstd.
//!
//! Versioning: the trailer magic carries the container revision (`KL1`);
//! a layout change bumps it and an old stub simply fails the probe. The
//! manifest's `klio_version` / `image_format_version` fields pin the
//! producing binary — a stub refuses a payload from a different version,
//! so cross-version skew is caught before anything decodes.

const std = @import("std");
const Allocator = std.mem.Allocator;

const errors = @import("errors.zig");
const read = @import("read.zig");
const write = @import("write.zig");
const zstd = @import("zstd.zig");
const PackError = errors.PackError;

/// Trailer magic. The final three bytes are the container revision.
pub const MAGIC: *const [8]u8 = "KBND\x00KL1";

/// Fixed trailer size in bytes: 8 magic + 4×8 offsets/lengths + 32 hash.
pub const TRAILER_LEN: usize = 72;

/// Alignment for the payload area and every mmap-target section, as an
/// absolute file offset. 16 KiB covers the largest page size in the
/// support matrix (macOS arm64).
pub const SECTION_ALIGN: u64 = 16384;

pub const HASH_LEN: usize = 32;

/// Well-known section names.
pub const section_names = struct {
    pub const MANIFEST: []const u8 = "manifest";
    pub const BASE_IMAGE: []const u8 = "base-image";
    pub const PROGRAM_SRC: []const u8 = "program-src";
    pub const PROGRAM_IMAGE: []const u8 = "program-image";
    pub const RESOURCES: []const u8 = "resources";
    pub const SKIA_SHIM: []const u8 = "skia-shim";
    pub const ICON: []const u8 = "icon";
};

/// Compression applied to a stored section (or one resource entry).
pub const Compression = enum(u8) {
    none = 0,
    zstd = 1,
};

/// The fixed-size trailer.
pub const Trailer = struct {
    /// Absolute file offset of the payload area (SECTION_ALIGN-aligned).
    payload_off: u64,
    /// Length of the payload area (sections + table, no trailer).
    payload_len: u64,
    /// Absolute file offset of the encoded section table.
    table_off: u64,
    table_len: u64,
    /// blake3 of the whole payload area.
    payload_hash: [HASH_LEN]u8,

    pub fn encode(self: *const Trailer) [TRAILER_LEN]u8 {
        var out: [TRAILER_LEN]u8 = undefined;
        @memcpy(out[0..8], MAGIC);
        std.mem.writeInt(u64, out[8..16], self.payload_off, .little);
        std.mem.writeInt(u64, out[16..24], self.payload_len, .little);
        std.mem.writeInt(u64, out[24..32], self.table_off, .little);
        std.mem.writeInt(u64, out[32..40], self.table_len, .little);
        @memcpy(out[40..72], &self.payload_hash);
        return out;
    }

    /// Parse a trailer candidate. Null when the magic is absent — the
    /// running executable is a plain `klio`, not a bundle.
    pub fn decode(bytes: *const [TRAILER_LEN]u8) ?Trailer {
        if (!std.mem.eql(u8, bytes[0..8], MAGIC)) return null;
        var hash: [HASH_LEN]u8 = undefined;
        @memcpy(&hash, bytes[40..72]);
        return .{
            .payload_off = std.mem.readInt(u64, bytes[8..16], .little),
            .payload_len = std.mem.readInt(u64, bytes[16..24], .little),
            .table_off = std.mem.readInt(u64, bytes[24..32], .little),
            .table_len = std.mem.readInt(u64, bytes[32..40], .little),
            .payload_hash = hash,
        };
    }

    /// Structural sanity against the containing file's size: every region
    /// in bounds, the table inside the payload area, alignment held.
    pub fn consistent(self: *const Trailer, file_len: u64) bool {
        if (self.payload_off % SECTION_ALIGN != 0) return false;
        const payload_end = std.math.add(u64, self.payload_off, self.payload_len) catch return false;
        if (payload_end + TRAILER_LEN > file_len) return false;
        const table_end = std.math.add(u64, self.table_off, self.table_len) catch return false;
        if (self.table_off < self.payload_off or table_end > payload_end) return false;
        return true;
    }
};

/// Directory entry for one stored section. Offsets are absolute file
/// offsets so the boot path can mmap/slice without extra arithmetic.
pub const Section = struct {
    name: []const u8,
    offset: u64,
    stored_len: u64,
    uncompressed_len: u64,
    compression: Compression,
};

pub const SectionTable = struct {
    entries: []Section = &.{},
};

/// One embedded resource (`--include`): a mount path and its zstd frame
/// inside the `resources` section. `offset` is relative to the section's
/// stored payload start.
pub const ResourceEntry = struct {
    mount: []const u8,
    offset: u64,
    stored_len: u64,
    uncompressed_len: u64,
    compression: Compression,
};

/// One pack the bundle baked in, for introspection and diagnostics.
pub const PackInfo = struct {
    id: []const u8,
    version: []const u8,
    features: []const []const u8,
};

/// A pack host binding replayed at boot: the Kotlin FQN and the in-binary
/// host symbol it resolves to. Function pointers never serialize; boot
/// re-resolves `host_symbol` against the running stub's registry and
/// errors hard when it is missing (a version-skewed stub, refused earlier
/// by the manifest version check).
pub const BindingPair = struct {
    fqn: []const u8,
    host_symbol: []const u8,
};

pub const Flavor = enum(u8) {
    headless = 0,
    ui = 1,
};

/// The manifest section. Postcard is sequential, so fields only append;
/// a breaking change bumps the trailer magic revision instead.
pub const BundleManifest = struct {
    /// Version of the klio binary that produced the bundle. The stub
    /// refuses a payload whose version differs from its own.
    klio_version: []const u8,
    /// `interp_ir.image.FORMAT_VERSION` of the embedded image sections.
    image_format_version: u32,
    flavor: Flavor,
    /// App display name (window title default; `--name`).
    name: []const u8,
    /// Main-function FQN when a `program-image` section boots directly;
    /// empty when boot parses `program-src`.
    entry: []const u8,
    /// True when a program-image bake was attempted but refused, so the
    /// bundle fell back to `program-src` (startup-only difference).
    program_src_fallback: bool,
    packs: []const PackInfo,
    /// Packages to replay through `stdlib.registerKnownPackage` at boot.
    known_packages: []const []const u8,
    /// Platform-helper FQNs replayed against the host registry (the
    /// stdlib image's own replay list, duplicated for introspection).
    binding_fqns: []const []const u8,
    /// Pack host bindings replayed at boot (see `BindingPair`).
    pack_bindings: []const BindingPair,
    resources: []const ResourceEntry,
};

/// One user source file carried in the `program-src` section.
pub const ProgramFile = struct {
    path: []const u8,
    bytes: []const u8,
};

pub const ProgramSources = struct {
    files: []const ProgramFile = &.{},
};

// ---------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------

const PendingSection = struct {
    name: []const u8,
    payload: []const u8,
    compression: Compression,
    /// Align the stored payload to SECTION_ALIGN (absolute file offset)
    /// so boot can mmap it. Implies `compression == .none`.
    mmap_target: bool,
};

/// Assembles the payload area + trailer. Sections are emitted in
/// insertion order (the bundler adds them in a fixed order, so output is
/// deterministic). The writer borrows names and payloads until `finish`.
pub const Writer = struct {
    gpa: Allocator,
    sections: std.ArrayList(PendingSection) = .empty,

    pub fn init(gpa: Allocator) Writer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Writer) void {
        self.sections.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn addSection(
        self: *Writer,
        name: []const u8,
        payload: []const u8,
        compression: Compression,
        mmap_target: bool,
    ) Allocator.Error!void {
        std.debug.assert(!(mmap_target and compression != .none));
        try self.sections.append(self.gpa, .{
            .name = name,
            .payload = payload,
            .compression = compression,
            .mmap_target = mmap_target,
        });
    }

    /// Encode everything that follows a stub of `stub_len` bytes: the
    /// alignment padding, the payload area (sections + table), and the
    /// trailer. Appending the returned bytes to the stub yields the
    /// complete bundle. Caller owns the result.
    pub fn finish(self: *Writer, stub_len: u64, result: *PackError) Allocator.Error!?[]u8 {
        const gpa = self.gpa;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);

        const payload_off = std.mem.alignForward(u64, stub_len, SECTION_ALIGN);
        try out.appendNTimes(gpa, 0, @intCast(payload_off - stub_len));
        // From here `stub_len + out.items.len` is the absolute file offset.
        const abs = struct {
            fn of(stub: u64, buffered: usize) u64 {
                return stub + @as(u64, buffered);
            }
        };

        var entries: std.ArrayList(Section) = .empty;
        defer entries.deinit(gpa);

        for (self.sections.items) |s| {
            if (s.mmap_target) {
                const cur = abs.of(stub_len, out.items.len);
                const aligned = std.mem.alignForward(u64, cur, SECTION_ALIGN);
                try out.appendNTimes(gpa, 0, @intCast(aligned - cur));
            }
            const offset = abs.of(stub_len, out.items.len);
            var owned_stored: ?[]u8 = null;
            defer if (owned_stored) |o| gpa.free(o);
            const stored: []const u8 = switch (s.compression) {
                .none => s.payload,
                .zstd => blk: {
                    const buf = zstd.compress(gpa, s.payload, write.DEFAULT_ZSTD_LEVEL) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.ZstdFailed => {
                            result.* = .{ .Compression = zstd.last_error };
                            return null;
                        },
                    };
                    owned_stored = buf;
                    break :blk buf;
                },
            };
            try out.appendSlice(gpa, stored);
            try entries.append(gpa, .{
                .name = s.name,
                .offset = offset,
                .stored_len = stored.len,
                .uncompressed_len = s.payload.len,
                .compression = s.compression,
            });
        }

        const table = SectionTable{ .entries = entries.items };
        var table_bytes = (try write.encode(SectionTable, gpa, &table, result)) orelse return null;
        defer table_bytes.deinit(gpa);
        const table_off = abs.of(stub_len, out.items.len);
        try out.appendSlice(gpa, table_bytes.items);

        const payload_len = abs.of(stub_len, out.items.len) - payload_off;
        var hash: [HASH_LEN]u8 = undefined;
        const payload_start_in_out: usize = @intCast(payload_off - stub_len);
        std.crypto.hash.Blake3.hash(out.items[payload_start_in_out..], &hash, .{});

        const trailer = Trailer{
            .payload_off = payload_off,
            .payload_len = payload_len,
            .table_off = table_off,
            .table_len = table_bytes.items.len,
            .payload_hash = hash,
        };
        try out.appendSlice(gpa, &trailer.encode());
        return try out.toOwnedSlice(gpa);
    }
};

// ---------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------

/// Verify the payload hash over the full bundle bytes. `bytes` must span
/// the whole file (offsets are absolute).
pub fn verifyPayload(bytes: []const u8, trailer: *const Trailer) bool {
    if (!trailer.consistent(bytes.len)) return false;
    const start: usize = @intCast(trailer.payload_off);
    const end: usize = @intCast(trailer.payload_off + trailer.payload_len);
    var hash: [HASH_LEN]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes[start..end], &hash, .{});
    return std.mem.eql(u8, &hash, &trailer.payload_hash);
}

/// Decode the section table. Caller frees via the allocator (or hands in
/// an arena).
pub fn decodeTable(gpa: Allocator, bytes: []const u8, trailer: *const Trailer) ?SectionTable {
    if (!trailer.consistent(bytes.len)) return null;
    const start: usize = @intCast(trailer.table_off);
    const end: usize = @intCast(trailer.table_off + trailer.table_len);
    var perr: PackError = undefined;
    return (read.decode(SectionTable, gpa, bytes[start..end], &perr) catch return null) orelse null;
}

pub fn findSection(table: *const SectionTable, name: []const u8) ?Section {
    for (table.entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// The stored (possibly compressed) bytes of a section, borrowed from the
/// bundle bytes.
pub fn sectionStored(bytes: []const u8, s: Section) []const u8 {
    const start: usize = @intCast(s.offset);
    return bytes[start .. start + @as(usize, @intCast(s.stored_len))];
}

/// Materialize a section's payload: borrowed for uncompressed sections,
/// owned (decompressed) for zstd. Null on a corrupt frame.
pub fn sectionBytes(gpa: Allocator, bytes: []const u8, s: Section) Allocator.Error!?read.SectionBytes {
    const stored = sectionStored(bytes, s);
    switch (s.compression) {
        .none => return .{ .borrowed = stored },
        .zstd => {
            const out = zstd.decompress(gpa, stored, @intCast(s.uncompressed_len)) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ZstdFailed => return null,
            };
            return .{ .owned = out };
        },
    }
}

/// Decompress one resource entry out of the `resources` section's stored
/// bytes. Caller owns the result for compressed entries.
pub fn resourceBytes(gpa: Allocator, resources_stored: []const u8, e: ResourceEntry) Allocator.Error!?read.SectionBytes {
    const start: usize = @intCast(e.offset);
    const end: usize = start + @as(usize, @intCast(e.stored_len));
    if (end > resources_stored.len) return null;
    const stored = resources_stored[start..end];
    switch (e.compression) {
        .none => return .{ .borrowed = stored },
        .zstd => {
            const out = zstd.decompress(gpa, stored, @intCast(e.uncompressed_len)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ZstdFailed => return null,
            };
            return .{ .owned = out };
        },
    }
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

test "trailer round-trips and rejects a non-bundle tail" {
    const t = Trailer{
        .payload_off = SECTION_ALIGN,
        .payload_len = 1234,
        .table_off = SECTION_ALIGN + 1000,
        .table_len = 234,
        .payload_hash = @splat(7),
    };
    const enc = t.encode();
    const got = Trailer.decode(&enc).?;
    try std.testing.expectEqual(t.payload_off, got.payload_off);
    try std.testing.expectEqual(t.payload_len, got.payload_len);
    try std.testing.expectEqual(t.table_off, got.table_off);
    try std.testing.expectEqual(t.table_len, got.table_len);
    try std.testing.expectEqualSlices(u8, &t.payload_hash, &got.payload_hash);

    // A plain-binary tail (no magic) probes negative.
    var plain: [TRAILER_LEN]u8 = @splat(0xAB);
    try std.testing.expect(Trailer.decode(&plain) == null);
    // A pack file's magic is not a bundle trailer either.
    var packish: [TRAILER_LEN]u8 = @splat(0);
    @memcpy(packish[0..4], "KPK\x00");
    try std.testing.expect(Trailer.decode(&packish) == null);
}

fn buildTestBundle(gpa: Allocator, stub: []const u8) ![]u8 {
    var w = Writer.init(gpa);
    defer w.deinit();
    var perr: PackError = undefined;
    try w.addSection(section_names.MANIFEST, "manifest-bytes", .none, false);
    try w.addSection(section_names.BASE_IMAGE, "IMAGE" ** 100, .none, true);
    try w.addSection(section_names.SKIA_SHIM, "shim-payload " ** 64, .zstd, false);
    const tail = (try w.finish(stub.len, &perr)) orelse return error.TestUnexpectedResult;
    defer gpa.free(tail);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, stub);
    try out.appendSlice(gpa, tail);
    return out.toOwnedSlice(gpa);
}

test "bundle round-trips sections with alignment and hash" {
    const gpa = std.testing.allocator;
    const stub = "fake-stub-executable-bytes";
    const bundle = try buildTestBundle(gpa, stub);
    defer gpa.free(bundle);

    // The stub prefix is untouched.
    try std.testing.expectEqualSlices(u8, stub, bundle[0..stub.len]);

    var tail: [TRAILER_LEN]u8 = undefined;
    @memcpy(&tail, bundle[bundle.len - TRAILER_LEN ..]);
    const trailer = Trailer.decode(&tail).?;
    try std.testing.expect(trailer.consistent(bundle.len));
    try std.testing.expect(verifyPayload(bundle, &trailer));
    try std.testing.expectEqual(@as(u64, 0), trailer.payload_off % SECTION_ALIGN);

    var table = decodeTable(gpa, bundle, &trailer).?;
    defer {
        for (table.entries) |e| gpa.free(@constCast(e.name));
        gpa.free(table.entries);
    }
    try std.testing.expectEqual(@as(usize, 3), table.entries.len);

    const manifest = findSection(&table, section_names.MANIFEST).?;
    const mb = (try sectionBytes(gpa, bundle, manifest)).?;
    defer mb.deinit(gpa);
    try std.testing.expectEqualSlices(u8, "manifest-bytes", mb.slice());

    // The image section is mmap-aligned and stored verbatim.
    const image = findSection(&table, section_names.BASE_IMAGE).?;
    try std.testing.expectEqual(@as(u64, 0), image.offset % SECTION_ALIGN);
    try std.testing.expectEqual(Compression.none, image.compression);
    const ib = (try sectionBytes(gpa, bundle, image)).?;
    defer ib.deinit(gpa);
    try std.testing.expectEqualSlices(u8, "IMAGE" ** 100, ib.slice());

    // The zstd section decompresses back.
    const shim = findSection(&table, section_names.SKIA_SHIM).?;
    try std.testing.expectEqual(Compression.zstd, shim.compression);
    try std.testing.expect(shim.stored_len < shim.uncompressed_len);
    const sb = (try sectionBytes(gpa, bundle, shim)).?;
    defer sb.deinit(gpa);
    try std.testing.expectEqualSlices(u8, "shim-payload " ** 64, sb.slice());

    try std.testing.expect(findSection(&table, section_names.ICON) == null);
}

test "payload corruption fails the hash check" {
    const gpa = std.testing.allocator;
    const bundle = try buildTestBundle(gpa, "stub");
    defer gpa.free(bundle);
    var tail: [TRAILER_LEN]u8 = undefined;
    @memcpy(&tail, bundle[bundle.len - TRAILER_LEN ..]);
    const trailer = Trailer.decode(&tail).?;
    bundle[@intCast(trailer.payload_off + 3)] ^= 0x40;
    try std.testing.expect(!verifyPayload(bundle, &trailer));
}

test "writer output is deterministic" {
    const gpa = std.testing.allocator;
    const one = try buildTestBundle(gpa, "stub-bytes");
    defer gpa.free(one);
    const two = try buildTestBundle(gpa, "stub-bytes");
    defer gpa.free(two);
    try std.testing.expectEqualSlices(u8, one, two);
}

test "manifest round-trips through the postcard codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const manifest = BundleManifest{
        .klio_version = "0.1.0",
        .image_format_version = 20,
        .flavor = .ui,
        .name = "myapp",
        .entry = "",
        .program_src_fallback = false,
        .packs = &.{
            .{ .id = "kotlinx.coroutines", .version = "1.8.0", .features = &.{"core"} },
        },
        .known_packages = &.{ "kotlinx.coroutines", "kotlinx.coroutines.flow" },
        .binding_fqns = &.{"kotlin.time.__klio_time_systemMillis"},
        .pack_bindings = &.{
            .{ .fqn = "kotlinx.atomicfu.__klio_cas", .host_symbol = "klio.host.atomicfu_cas" },
        },
        .resources = &.{
            .{ .mount = "data/config.json", .offset = 0, .stored_len = 10, .uncompressed_len = 32, .compression = .zstd },
        },
    };
    var perr: PackError = undefined;
    var bytes = (try write.encode(BundleManifest, a, &manifest, &perr)).?;
    defer bytes.deinit(a);
    const got = (try read.decode(BundleManifest, a, bytes.items, &perr)).?;
    try std.testing.expectEqualStrings("0.1.0", got.klio_version);
    try std.testing.expectEqual(@as(u32, 20), got.image_format_version);
    try std.testing.expectEqual(Flavor.ui, got.flavor);
    try std.testing.expectEqualStrings("myapp", got.name);
    try std.testing.expectEqual(@as(usize, 1), got.packs.len);
    try std.testing.expectEqualStrings("kotlinx.coroutines", got.packs[0].id);
    try std.testing.expectEqual(@as(usize, 2), got.known_packages.len);
    try std.testing.expectEqual(@as(usize, 1), got.pack_bindings.len);
    try std.testing.expectEqualStrings("klio.host.atomicfu_cas", got.pack_bindings[0].host_symbol);
    try std.testing.expectEqual(@as(usize, 1), got.resources.len);
    try std.testing.expectEqual(Compression.zstd, got.resources[0].compression);
}

test "program sources round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = ProgramSources{ .files = &.{
        .{ .path = "main.kt", .bytes = "fun main() {}\n" },
        .{ .path = "util.kt", .bytes = "fun helper() = 1\n" },
    } };
    var perr: PackError = undefined;
    var bytes = (try write.encode(ProgramSources, a, &src, &perr)).?;
    defer bytes.deinit(a);
    const got = (try read.decode(ProgramSources, a, bytes.items, &perr)).?;
    try std.testing.expectEqual(@as(usize, 2), got.files.len);
    try std.testing.expectEqualStrings("main.kt", got.files[0].path);
    try std.testing.expectEqualStrings("fun helper() = 1\n", got.files[1].bytes);
}
