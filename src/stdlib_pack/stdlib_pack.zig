//! Embedded stdlib pack.
//!
//! In the Rust build the crate's `build.rs` calls
//! `klio_stdlib::build_stdlib_pack` once per Cargo build and writes the
//! resulting `.klio-pack` byte stream into `OUT_DIR`; the crate root then
//! embeds those bytes via `include_bytes!` so the interpreter ships with
//! the pack inlined into the binary. The Zig port has no compile-time
//! embed step, so the equivalent of the embedded bytes is produced on
//! demand by `build_stdlib_pack` — the same routine `build.rs` runs.
//!
//! For day-to-day stdlib iteration, set
//! `KLIO_STDLIB_PACK=/path/to/stdlib.klio-pack` and `stdlibPackBytes`
//! returns the on-disk pack instead. The environment is supplied by the
//! host through an `Environ.Map`; passing `null` skips the override and
//! always builds the pack.

const std = @import("std");
const Allocator = std.mem.Allocator;
const EnvMap = std.process.Environ.Map;

const pack = @import("pack");
const stdlib = @import("stdlib");

const PackError = pack.PackError;

/// Name of the environment variable that, when set to a readable file
/// path, overrides the built stdlib pack with the file's contents.
pub const STDLIB_PACK_ENV: []const u8 = "KLIO_STDLIB_PACK";

/// Return the stdlib pack bytes the host should load. Respects the
/// `KLIO_STDLIB_PACK` environment variable in `env`: when it names a
/// readable file path, the file's contents are returned (handy for
/// in-place pack edits without rebuilding the binary). Otherwise the pack
/// is built from the embedded stdlib surface via `build_stdlib_pack`.
/// A `null` `env` skips the override entirely.
///
/// The returned slice is always owned by the caller and freed with
/// `allocator`. On a build failure `result` is set and `null` is returned.
pub fn stdlibPackBytes(allocator: Allocator, env: ?*const EnvMap, result: *PackError) Allocator.Error!?[]u8 {
    if (env) |m| {
        if (m.get(STDLIB_PACK_ENV)) |path| {
            if (try readFile(allocator, path)) |bytes| return bytes;
        }
    }
    var built = (try stdlib.build_stdlib_pack(allocator, true, result)) orelse return null;
    defer built.deinit(allocator);
    return try allocator.dupe(u8, built.items);
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
