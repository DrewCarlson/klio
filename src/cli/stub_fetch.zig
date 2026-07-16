//! Cross-target stub + shim resolution for `klio bundle --target`.
//!
//! A cross bundle needs the target's runtime stub (the `klio` binary for
//! that OS/arch, same version as the bundler) and, for UI bundles, its
//! Skia shim blob. Resolve order:
//!
//!   1. `--stub <path>` (handled by the caller).
//!   2. `KLIO_STUB_DIR`: `<dir>/<target>/<name>` — CI and air-gapped use.
//!   3. `~/.klio/stubs/<version>/<target>/<name>` — the fetch cache.
//!   4. HTTPS fetch from the GitHub release of the bundler's own version,
//!      verified against the sha256 manifest baked into the binary at
//!      release build time, then cached under 3. A dev build carries no
//!      manifest, so the fetch path refuses and the caller reports the
//!      offline hint (`--stub` / `KLIO_STUB_DIR` still work).
//!
//! Same-target bundling never reaches this module (the stub is the
//! running executable).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const runtime = @import("runtime");
const pack = @import("pack");
const io = @import("io.zig");

/// Release-baked `name -> sha256` manifest (JSON). Empty in dev builds:
/// the release workflow generates `release/stubs-manifest.json` and the
/// tag build embeds it through this hook.
pub const baked_manifest_json: []const u8 = "";

const RELEASE_URL_BASE = "https://github.com/klio-lang/klio/releases/download";

fn threadedIo(gpa: Allocator) std.Io.Threaded {
    return std.Io.Threaded.init(gpa, .{});
}

pub fn stubFileName(gpa: Allocator, target: []const u8, version: []const u8) ?[]const u8 {
    const ext: []const u8 = if (std.mem.startsWith(u8, target, "windows")) ".exe" else "";
    return std.fmt.allocPrint(gpa, "klio-{s}-{s}{s}", .{ version, target, ext }) catch null;
}

pub fn shimFileName(gpa: Allocator, target: []const u8, version: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(gpa, "klio-skia-{s}-{s}.zst", .{ version, target }) catch null;
}

/// The plain in-tree names accepted alongside the release names, so a
/// test/CI dir can hold `<target>/klio` copies without renaming.
fn plainStubName(target: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, target, "windows")) "klio.exe" else "klio";
}

fn plainShimName(target: []const u8) []const u8 {
    if (std.mem.startsWith(u8, target, "macos")) return "libklio_skia.dylib";
    if (std.mem.startsWith(u8, target, "windows")) return "klio_skia.dll";
    return "libklio_skia.so";
}

/// Look for `names` under `<dir>/<target>/`. Returns the first existing
/// path (owned).
fn findIn(gpa: Allocator, dir: []const u8, target: []const u8, names: []const []const u8) ?[]const u8 {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const fio = threaded.io();
    for (names) |name| {
        if (name.len == 0) continue;
        const path = std.fs.path.join(gpa, &.{ dir, target, name }) catch continue;
        if (std.Io.Dir.cwd().statFile(fio, path, .{})) |_| {
            return path;
        } else |_| {
            gpa.free(path);
        }
    }
    return null;
}

fn stubCacheDir(gpa: Allocator, version: []const u8) ?[]const u8 {
    const home = runtime.procEnvGetVar(gpa, "HOME") catch null orelse return null;
    defer gpa.free(home);
    return std.fs.path.join(gpa, &.{ home, ".klio", "stubs", version }) catch null;
}

/// Resolve the runtime stub binary for `target`. Returns an owned path,
/// or null when unavailable (the caller prints the offline hint).
pub fn resolveStub(gpa: Allocator, target: []const u8, version: []const u8) ?[]const u8 {
    const release_name = stubFileName(gpa, target, version) orelse return null;
    const names = [_][]const u8{ plainStubName(target), release_name };

    if (runtime.procEnvGetVar(gpa, "KLIO_STUB_DIR") catch null) |dir| {
        defer gpa.free(dir);
        if (findIn(gpa, dir, target, &names)) |p| return p;
    }
    if (stubCacheDir(gpa, version)) |cache| {
        defer gpa.free(cache);
        if (findIn(gpa, cache, target, &names)) |p| return p;
        if (fetchIntoCache(gpa, cache, target, version, release_name)) |p| return p;
    }
    return null;
}

/// Resolve the Skia shim BYTES for `target` (decompressed when the
/// artifact is the release `.zst`). Allocates into `arena`.
pub fn resolveShim(arena: Allocator, target: []const u8, version: []const u8) ?[]const u8 {
    const release_name = shimFileName(arena, target, version) orelse return null;
    const names = [_][]const u8{ plainShimName(target), release_name };

    var path: ?[]const u8 = null;
    if (runtime.procEnvGetVar(arena, "KLIO_STUB_DIR") catch null) |dir| {
        path = findIn(arena, dir, target, &names);
    }
    if (path == null) {
        if (stubCacheDir(arena, version)) |cache| {
            path = findIn(arena, cache, target, &names);
            if (path == null) path = fetchIntoCache(arena, cache, target, version, release_name);
        }
    }
    const p = path orelse return null;
    var threaded = threadedIo(arena);
    defer threaded.deinit();
    const bytes = std.Io.Dir.cwd().readFileAlloc(threaded.io(), p, arena, .unlimited) catch return null;
    if (std.mem.endsWith(u8, p, ".zst")) {
        return decompressZstFrame(arena, bytes);
    }
    return bytes;
}

/// A release shim artifact is a bare zstd frame; its decompressed size is
/// read from the frame header.
fn decompressZstFrame(arena: Allocator, bytes: []const u8) ?[]const u8 {
    const size = pack.zstd.frameContentSize(bytes) orelse return null;
    return pack.zstd.decompress(arena, bytes, size) catch null;
}

/// Fetch `name` from the GitHub release for `version` into
/// `<cache>/<target>/<name>`, verifying its sha256 against the manifest
/// baked into this binary. Null when no manifest is baked (dev build),
/// the network is unavailable, or verification fails.
fn fetchIntoCache(
    gpa: Allocator,
    cache: []const u8,
    target: []const u8,
    version: []const u8,
    name: []const u8,
) ?[]const u8 {
    const expect_hash = manifestSha256(gpa, name) orelse return null;

    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const fio = threaded.io();

    const url = std.fmt.allocPrint(gpa, "{s}/v{s}/{s}", .{ RELEASE_URL_BASE, version, name }) catch return null;
    defer gpa.free(url);

    var client = std.http.Client{ .allocator = gpa, .io = fio };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const res = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    }) catch return null;
    if (res.status != .ok) return null;
    const bytes = body.written();

    var got: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &got, .{});
    if (!std.mem.eql(u8, &got, &expect_hash)) {
        io.printStderr(gpa, "error: fetched {s} fails sha256 verification; refusing it\n", .{name});
        return null;
    }

    const dir = std.fs.path.join(gpa, &.{ cache, target }) catch return null;
    defer gpa.free(dir);
    std.Io.Dir.cwd().createDirPath(fio, dir) catch return null;
    const dest = std.fs.path.join(gpa, &.{ dir, name }) catch return null;
    std.Io.Dir.cwd().writeFile(fio, .{ .sub_path = dest, .data = bytes }) catch {
        gpa.free(dest);
        return null;
    };
    return dest;
}

/// Look `name` up in the baked release manifest. The manifest is a flat
/// JSON object of `"artifact-name": "hex-sha256"`.
fn manifestSha256(gpa: Allocator, name: []const u8) ?[32]u8 {
    if (baked_manifest_json.len == 0) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, baked_manifest_json, .{}) catch return null;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const hex = switch (obj.get(name) orelse return null) {
        .string => |s| s,
        else => return null,
    };
    if (hex.len != 64) return null;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return null;
    return out;
}

test "artifact names follow the release convention" {
    const gpa = std.testing.allocator;
    const linux = stubFileName(gpa, "linux-arm64", "0.1.0").?;
    defer gpa.free(linux);
    try std.testing.expectEqualStrings("klio-0.1.0-linux-arm64", linux);
    const win = stubFileName(gpa, "windows-x64", "0.1.0").?;
    defer gpa.free(win);
    try std.testing.expectEqualStrings("klio-0.1.0-windows-x64.exe", win);
    const shim = shimFileName(gpa, "macos-arm64", "0.1.0").?;
    defer gpa.free(shim);
    try std.testing.expectEqualStrings("klio-skia-0.1.0-macos-arm64.zst", shim);
}

test "manifest lookup is absent in dev builds" {
    try std.testing.expect(manifestSha256(std.testing.allocator, "klio-0.1.0-linux-x64") == null);
}
