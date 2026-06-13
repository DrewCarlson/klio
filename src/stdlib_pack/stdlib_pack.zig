//! Embedded stdlib pack.
//!
//! The interpreter ships with the stdlib pack baked into the binary, the
//! same shape the Rust build produced with `build.rs` + `include_bytes!`:
//! the top-level build.zig runs `embed_gen` over the repo source checkout
//! and wires the bytes in through the `stdlib_embedded` module.
//!
//! `stdlibPackBytes` resolves the pack in this order:
//!   1. `KLIO_STDLIB_PACK=/path/to/stdlib.klio-pack` — an explicit on-disk
//!      pack override, strongest because it is a deliberate per-run choice.
//!   2. The cwd source checkout (`kotlin/libraries/stdlib` + `kotlin-klio`),
//!      built fresh by `build_stdlib_pack`. Ahead of the embedded bytes so
//!      in-repo stdlib `.kt` edits take effect without rebuilding the
//!      binary; in-repo behavior is byte-identical to the pre-embed build.
//!   3. The embedded bytes — always present in a build.zig-produced binary,
//!      so `klio run` works from any directory with zero setup.
//! A `null` `env` skips the override and starts at the checkout.

const std = @import("std");
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;

const pack = @import("pack");
const stdlib = @import("stdlib");
const embedded = @import("stdlib_embedded");

const PackError = pack.PackError;

/// The pack bytes baked into the binary by build.zig, or `null` in builds
/// that bypass build.zig (scripts/zigcheck.py wires the stub module).
pub const EMBEDDED_PACK_BYTES: ?[]const u8 = embedded.pack_bytes;

/// Name of the environment variable that, when set to a readable file
/// path, overrides the built stdlib pack with the file's contents.
pub const STDLIB_PACK_ENV: []const u8 = "KLIO_STDLIB_PACK";

/// Return the stdlib pack bytes the host should load, resolving in the
/// order documented at the top of this file: `KLIO_STDLIB_PACK` override,
/// then the cwd source checkout, then the bytes embedded in the binary.
/// A `null` `env` skips the override entirely.
///
/// The returned slice is always owned by the caller and freed with
/// `allocator`. When every source fails, `result` carries the checkout
/// builder's error (it names the missing root) and `null` is returned.
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

/// Read the embedded stdlib pack's manifest and return the implicit
/// package list it declares. Reflects the pack's declaration, so as the
/// embedded pack adds packages (or future kotlinx packs declare their own)
/// callers automatically see the union. The returned slice and each of its
/// strings are owned by the caller and freed with `allocator`. Any failure
/// yields an empty slice, mirroring the Rust fall-through.
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

/// Free a slice returned by `embeddedImplicitPackages`.
pub fn freeImplicitPackages(allocator: Allocator, packages: [][]const u8) void {
    for (packages) |p| allocator.free(p);
    allocator.free(packages);
}

/// Read `path` into an owned buffer, returning `null` if the file cannot
/// be read (so the caller falls back to the built pack).
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

    // Round-trip through PackReader to validate the embed. `fromBytes`
    // takes ownership of `bytes`.
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
    // Skipped under scripts/zigcheck.py (stub module, no baked bytes).
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
    // The static `stdlib.IMPLICITLY_IMPORTED_PACKAGES` is the boot-time
    // source; the pack manifest is the persistent form a future build will
    // read directly. They must agree for the duration of the transition.
    const a = std.testing.allocator;

    const from_pack = try embeddedImplicitPackages(a, null);
    defer freeImplicitPackages(a, from_pack);

    const from_static = stdlib.IMPLICITLY_IMPORTED_PACKAGES;
    try std.testing.expectEqual(from_static.len, from_pack.len);
    for (from_pack, from_static) |got, want| {
        try std.testing.expectEqualStrings(want, got);
    }
}
