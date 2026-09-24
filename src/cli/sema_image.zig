//! A self-contained sema image: what a program needs to run over its base
//! with no data home, pack install or checkout. It holds the base image
//! (`lower_driver.pipeline.base_image`), the source text of every file the
//! base was collected from (the stdlib, the sema actuals and the selected
//! packs, in the order they were loaded) and the pack features the base was
//! loaded with. A load registers those files as `klio run` registers them,
//! so the base collects to the digest the image was baked against, then
//! decodes the image and builds only the program.
//!
//! `bake-image` writes one, `run-image` runs a program over one, and a
//! bundle carries one.

const std = @import("std");
const span = @import("span");
const sema = @import("sema");
const pack = @import("pack");
const interp_ir = @import("interp_ir");
const lower_driver = @import("lower_driver");

const sema_cmd = @import("sema_cmd.zig");

const Allocator = std.mem.Allocator;
const codec = interp_ir.codec;
const base_image = lower_driver.pipeline.base_image;

const magic = "KLIOSEMI";

/// Bumped with any change to `Image` or the header.
pub const FORMAT_VERSION: u32 = 1;

/// The `image_format_version` of a bundle whose payload is a sema image and
/// the program's sources. Bundles of the name-resolving pipeline recorded
/// its image codec's version, far below this, so a stub tells the two
/// apart and refuses one it cannot boot.
pub const bundle_payload_version: u32 = 1_000_000 + FORMAT_VERSION;

pub const Header = extern struct {
    version: u32,
    /// `base_image.version` and the codec's, which the image inside needs.
    base_version: u32,
    codec: u32,
    reserved: u32 = 0,
    /// The payload's size before compression.
    raw_len: u64,
};

pub const Kind = enum(u8) { base, pack };

pub const File = struct {
    path: []const u8,
    text: []const u8,
    kind: Kind,
};

pub const Image = struct {
    /// The base image bytes (`base_image.encode`).
    base: []const u8,
    /// The files the base was collected from, in load order; the serializers
    /// generated for the packs are not among them, the load generates them
    /// again.
    files: []const File,
    /// The `<pack>/<feature>` requests the base was loaded with.
    features: []const []const u8,
    /// The library ids of the packs in the base.
    packs: []const []const u8,
    /// The packages the pack load made known (`stdlib.registerKnownPackage`),
    /// which a load registers again.
    known_packages: []const []const u8,
};

pub const DecodeError = error{ OutOfMemory, Malformed, Stale };

/// Serializes `img`, compressed, into an owned `gpa` buffer.
pub fn encode(gpa: Allocator, img: *const Image) ![]u8 {
    const raw = try codec.encodeBytes(Image, gpa, img);
    defer gpa.free(raw);
    const packed_bytes = try pack.zstd.compress(gpa, raw, pack.DEFAULT_ZSTD_LEVEL);
    defer gpa.free(packed_bytes);
    const hdr: Header = .{ .version = FORMAT_VERSION, .base_version = base_image.version, .codec = codec.FORMAT_VERSION, .raw_len = raw.len };
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, magic);
    try out.appendSlice(gpa, std.mem.asBytes(&hdr));
    try out.appendSlice(gpa, packed_bytes);
    return out.toOwnedSlice(gpa);
}

/// Whether `bytes` start like a sema image, of any version.
pub fn isImage(bytes: []const u8) bool {
    return bytes.len >= magic.len and std.mem.eql(u8, bytes[0..magic.len], magic);
}

/// Decodes an image into `a`. `error.Stale` for one another klio wrote in
/// a format this one does not read; `error.Malformed` for anything else
/// that is not an image.
pub fn decode(a: Allocator, bytes: []const u8) DecodeError!Image {
    if (!isImage(bytes) or bytes.len < magic.len + @sizeOf(Header)) return error.Malformed;
    var h: Header = undefined;
    @memcpy(std.mem.asBytes(&h), bytes[magic.len .. magic.len + @sizeOf(Header)]);
    if (h.version != FORMAT_VERSION or h.base_version != base_image.version or h.codec != codec.FORMAT_VERSION) return error.Stale;
    const raw_len = std.math.cast(usize, h.raw_len) orelse return error.Malformed;
    const raw = pack.zstd.decompress(a, bytes[magic.len + @sizeOf(Header) ..], raw_len) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.ZstdFailed => error.Malformed,
    };
    return codec.decodeBytes(Image, a, raw) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Malformed,
    };
}

/// The base files `loadSources` recorded, as an image carries them.
pub fn filesOf(a: Allocator, recorded: []const sema_cmd.BaseFile) ![]const File {
    const out = try a.alloc(File, recorded.len);
    for (recorded, out) |r, *f| f.* = .{ .path = r.path, .text = r.text, .kind = if (r.origin == .pack) .pack else .base };
    return out;
}

/// The files of `img` as `loadSources` takes a base.
pub fn baseOf(a: Allocator, img: *const Image) ![]const sema_cmd.BaseFile {
    const out = try a.alloc(sema_cmd.BaseFile, img.files.len);
    for (img.files, out) |f, *b| b.* = .{ .path = f.path, .text = f.text, .origin = if (f.kind == .pack) .pack else .base };
    return out;
}

test "an image round-trips, and another format is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const img: Image = .{
        .base = "base image bytes",
        .files = &.{
            .{ .path = "kotlin/A.kt", .text = "package kotlin\n", .kind = .base },
            .{ .path = "p/B.kt", .text = "package p\nfun b() = 1\n", .kind = .pack },
        },
        .features = &.{"p/extra"},
        .packs = &.{"p"},
        .known_packages = &.{"p"},
    };
    const bytes = try encode(a, &img);
    try std.testing.expect(isImage(bytes));
    const back = try decode(a, bytes);
    try std.testing.expectEqualStrings("base image bytes", back.base);
    try std.testing.expectEqual(@as(usize, 2), back.files.len);
    try std.testing.expectEqualStrings("p/B.kt", back.files[1].path);
    try std.testing.expectEqualStrings("package p\nfun b() = 1\n", back.files[1].text);
    try std.testing.expectEqual(Kind.pack, back.files[1].kind);
    try std.testing.expectEqualStrings("p/extra", back.features[0]);
    try std.testing.expectEqualStrings("p", back.packs[0]);
    try std.testing.expectEqualStrings("p", back.known_packages[0]);

    const other = try a.dupe(u8, bytes);
    other[magic.len] +%= 1;
    try std.testing.expectError(error.Stale, decode(a, other));
    try std.testing.expectError(error.Malformed, decode(a, "KLIOSEMB not this kind"));
    const cut = bytes[0 .. bytes.len - 4];
    try std.testing.expectError(error.Malformed, decode(a, cut));
}
