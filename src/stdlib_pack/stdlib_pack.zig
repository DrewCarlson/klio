//! Stdlib pack resolution, in order:
//!   1. `KLIO_STDLIB_PACK=/path/to/stdlib.klio-pack`, a per-run override.
//!   2. The cwd source checkout (`kotlin/libraries/stdlib`, `kotlin-klio`),
//!      built fresh, so in-repo `.kt` edits apply without rebuilding.
//!   3. The bytes build.zig baked in, so `klio run` works from any directory.
//! A null `env` skips the override and starts at the checkout.

const std = @import("std");
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;

const pack = @import("pack");
const stdlib = @import("stdlib");
const embedded = @import("stdlib_embedded");

const PackError = pack.PackError;

/// Baked in by build.zig; null where build.zig is bypassed.
pub const EMBEDDED_PACK_BYTES: ?[]const u8 = embedded.pack_bytes;

pub const STDLIB_PACK_ENV: []const u8 = "KLIO_STDLIB_PACK";

/// Resolved in the order at the top of this file. The slice is owned by the
/// caller. When every source fails, `result` names the missing root.
pub fn stdlibPackBytes(allocator: Allocator, env: ?*const EnvMap, result: *PackError) Allocator.Error!?[]u8 {
    if (env) |m| {
        if (m.get(STDLIB_PACK_ENV)) |path| {
            if (try readFile(allocator, path)) |bytes| return bytes;
        }
    }
    var built_opt = try stdlib.build_stdlib_pack(allocator, true, result);
    if (built_opt) |*built| {
        defer built.deinit(allocator);
        return try allocator.dupe(u8, built.items);
    }
    if (EMBEDDED_PACK_BYTES) |bytes| {
        return try allocator.dupe(u8, bytes);
    }
    return null;
}

/// The stdlib `SOURCES`, every string in `arena`; `deinit` drops them all.
pub const StdlibSources = struct {
    arena: std.heap.ArenaAllocator,
    files: []const pack.schema.SourceFile,

    pub fn deinit(self: *StdlibSources) void {
        self.arena.deinit();
    }
};

/// The stdlib sources, resolved in the order at the top of this file. The
/// checkout is read straight into the bundle rather than packed and decoded
/// again, which yields the same files; a pack override and the baked-in
/// bytes decode their `SOURCES` section. Null when every source fails, with
/// `result` naming the missing root; a pack that resolves but does not decode
/// yields no files.
pub fn stdlibSources(allocator: Allocator, env: ?*const EnvMap, result: *PackError) Allocator.Error!?StdlibSources {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    if (env) |m| {
        if (m.get(STDLIB_PACK_ENV)) |path| {
            if (try readFile(a, path)) |bytes| {
                return .{ .arena = arena, .files = try decodeSources(a, bytes, result) };
            }
        }
    }
    if (try stdlib.pack_builder.buildCuratedSources(a, result)) |bundle| {
        return .{ .arena = arena, .files = bundle.files };
    }
    if (EMBEDDED_PACK_BYTES) |bytes| {
        return .{ .arena = arena, .files = try decodeEmbeddedSources(a, bytes, result) };
    }
    arena.deinit();
    return null;
}

/// The `SOURCES` section of the pack `bytes`, or no files when it does not
/// decode. `bytes` and everything decoded belong to the arena `a`.
fn decodeSources(a: Allocator, bytes: []u8, result: *PackError) Allocator.Error![]const pack.schema.SourceFile {
    var reader = (try pack.PackReader.fromBytes(a, bytes, result)) orelse return &.{};
    const payload = (try reader.readSection(pack.section_names.SOURCES, result)) orelse return &.{};
    const bundle = (try pack.schema.decode(pack.schema.SourceBundle, a, payload.slice(), result)) orelse return &.{};
    return bundle.files;
}

/// The sources the binary carries, as slices of its own bytes: no copy of
/// the pack, no hash over it and no copy of each file, only the file table
/// on the arena `a`. The section is stored uncompressed, so its payload is a
/// slice of the pack too.
fn decodeEmbeddedSources(a: Allocator, bytes: []const u8, result: *PackError) Allocator.Error![]const pack.schema.SourceFile {
    var reader = (try pack.PackReader.fromBytesBorrowed(a, bytes, result)) orelse return &.{};
    // A compressed section would land on the arena instead, which the files
    // then borrow from just the same.
    const payload = (try reader.readSection(pack.section_names.SOURCES, result)) orelse return &.{};
    const bundle = (try pack.schema.decodeBorrowed(pack.schema.SourceBundle, a, payload.slice(), result)) orelse return &.{};
    return bundle.files;
}

/// Implicit packages the pack manifest declares. Slice and strings owned by
/// the caller; any failure yields an empty slice.
pub fn embeddedImplicitPackages(allocator: Allocator, env: ?*const EnvMap) Allocator.Error![][]const u8 {
    var err: PackError = undefined;
    const bytes = (try stdlibPackBytes(allocator, env, &err)) orelse return &.{};
    var reader = (try pack.PackReader.fromBytes(allocator, bytes, &err)) orelse return &.{};
    defer reader.deinit();
    const payload = (try reader.readSection(pack.section_names.MANIFEST, &err)) orelse return &.{};
    defer payload.deinit(allocator);
    var manifest = (try pack.schema.decode(pack.schema.PackManifest, allocator, payload.slice(), &err)) orelse return &.{};
    defer manifest.deinit(allocator);
    const out = try allocator.alloc([]const u8, manifest.implicit_packages.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| allocator.free(s);
        allocator.free(out);
    }
    for (manifest.implicit_packages) |p| {
        out[filled] = try allocator.dupe(u8, p);
        filled += 1;
    }
    return out;
}

pub fn freeImplicitPackages(allocator: Allocator, packages: [][]const u8) void {
    for (packages) |p| allocator.free(p);
    allocator.free(packages);
}

/// Null when unreadable, so the caller falls back to the built pack.
fn readFile(allocator: Allocator, path: []const u8) Allocator.Error!?[]u8 {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

test "embedded pack loads" {
    const a = std.testing.allocator;
    var err: PackError = undefined;

    const bytes = (try stdlibPackBytes(a, null, &err)).?;
    try std.testing.expect(bytes.len != 0);

    // `fromBytes` takes ownership of `bytes`.
    var reader = (try pack.PackReader.fromBytes(a, bytes, &err)).?;
    defer reader.deinit();

    var saw_manifest = false;
    var saw_bindings = false;
    for (reader.sections()) |entry| {
        if (std.mem.eql(u8, entry.name, pack.section_names.MANIFEST)) saw_manifest = true;
        if (std.mem.eql(u8, entry.name, pack.section_names.BINDINGS)) saw_bindings = true;
    }
    try std.testing.expect(saw_manifest);
    try std.testing.expect(saw_bindings);
}

test "baked-in pack bytes parse and carry every section" {
    const a = std.testing.allocator;
    const bytes = EMBEDDED_PACK_BYTES orelse return error.SkipZigTest;
    var err: PackError = undefined;
    var reader = (try pack.PackReader.fromBytes(a, try a.dupe(u8, bytes), &err)).?;
    defer reader.deinit();
    for ([_][]const u8{
        pack.section_names.MANIFEST,
        pack.section_names.SYMBOLS,
        pack.section_names.BINDINGS,
        pack.section_names.SOURCES,
    }) |want| {
        var saw = false;
        for (reader.sections()) |entry| {
            if (std.mem.eql(u8, entry.name, want)) saw = true;
        }
        try std.testing.expect(saw);
    }
}

test "embedded implicit packages match static list" {
    // The boot-time list and the pack manifest must agree.
    const a = std.testing.allocator;

    const from_pack = try embeddedImplicitPackages(a, null);
    defer freeImplicitPackages(a, from_pack);

    const from_static = stdlib.IMPLICITLY_IMPORTED_PACKAGES;
    try std.testing.expectEqual(from_static.len, from_pack.len);
    for (from_pack, from_static) |got, want| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "direct sources equal the packed and decoded sources" {
    const a = std.testing.allocator;
    var err: PackError = undefined;

    var direct = (try stdlibSources(a, null, &err)) orelse return error.SkipZigTest;
    defer direct.deinit();
    try std.testing.expect(direct.files.len != 0);

    const bytes = (try stdlibPackBytes(a, null, &err)).?;
    var reader = (try pack.PackReader.fromBytes(a, bytes, &err)).?;
    defer reader.deinit();
    const payload = (try reader.readSection(pack.section_names.SOURCES, &err)).?;
    defer payload.deinit(a);
    var bundle = (try pack.schema.decode(pack.schema.SourceBundle, a, payload.slice(), &err)).?;
    defer bundle.deinit(a);

    try std.testing.expectEqual(bundle.files.len, direct.files.len);
    for (bundle.files, direct.files) |want, got| {
        try std.testing.expectEqualStrings(want.rel_path, got.rel_path);
        try std.testing.expectEqualStrings(want.bytes, got.bytes);
    }
}
