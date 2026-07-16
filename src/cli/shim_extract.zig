//! First-launch extraction of the embedded Skia shim: a UI bundle
//! carries the rendering backend as a zstd blob; `dlopen` needs a real
//! file, so the blob is written once to a content-addressed per-user
//! cache and the path handed to the loader.
//!
//! Cache layout: `<cache-base>/klio/shim/<blake3-16>/<libname>` where
//! `<blake3-16>` is the hex prefix of the DECOMPRESSED bytes' hash —
//! upgrades land in a new directory, co-installed bundles sharing a shim
//! share one file, and a later launch that finds the file skips the
//! write entirely. Writes go through a unique temp file + rename, so
//! concurrent first launches are safe and a torn temp file is invisible.
//!
//! `<cache-base>` is `$XDG_CACHE_HOME` (default `~/.cache`) on Linux,
//! `~/Library/Caches` on macOS, `%LOCALAPPDATA%` on Windows. An
//! unwritable cache falls back to the system temp dir; if that also
//! fails the caller reports one stderr line and the program keeps the
//! existing headless fallback.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const runtime = @import("runtime");

fn threadedIo(gpa: Allocator) std.Io.Threaded {
    return std.Io.Threaded.init(gpa, .{});
}

/// The platform shim file name.
pub fn libName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "libklio_skia.dylib",
        .windows => "klio_skia.dll",
        else => "libklio_skia.so",
    };
}

fn cacheBase(gpa: Allocator) ?[]const u8 {
    switch (builtin.os.tag) {
        .windows => {
            return runtime.procEnvGetVar(gpa, "LOCALAPPDATA") catch null;
        },
        .macos => {
            const home = runtime.procEnvGetVar(gpa, "HOME") catch null orelse return null;
            defer gpa.free(home);
            return std.fs.path.join(gpa, &.{ home, "Library", "Caches" }) catch null;
        },
        else => {
            if (runtime.procEnvGetVar(gpa, "XDG_CACHE_HOME") catch null) |x| {
                if (x.len != 0) return x;
                gpa.free(x);
            }
            const home = runtime.procEnvGetVar(gpa, "HOME") catch null orelse return null;
            defer gpa.free(home);
            return std.fs.path.join(gpa, &.{ home, ".cache" }) catch null;
        },
    }
}

/// Ensure `bytes` exists as a file in the content-addressed cache and
/// return its path (allocated from `gpa`, process-lifetime). Null when
/// neither the cache nor the temp dir is writable.
pub fn ensureExtracted(gpa: Allocator, bytes: []const u8) ?[]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest[0..16].*, .lower);

    if (cacheBase(gpa)) |base| {
        defer gpa.free(@constCast(base));
        const dir = std.fs.path.join(gpa, &.{ base, "klio", "shim", &hex }) catch return null;
        defer gpa.free(dir);
        if (extractInto(gpa, dir, bytes)) |p| return p;
    }
    // Fallback: the system temp dir, same content-addressed layout.
    const tmp = std.fs.path.join(gpa, &.{ "/tmp", "klio-shim", &hex }) catch return null;
    defer gpa.free(tmp);
    return extractInto(gpa, tmp, bytes);
}

fn extractInto(gpa: Allocator, dir: []const u8, bytes: []const u8) ?[]const u8 {
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const fio = threaded.io();
    const cwd = std.Io.Dir.cwd();

    const dest = std.fs.path.join(gpa, &.{ dir, libName() }) catch return null;
    // Content-addressed: an existing file IS the right file.
    if (cwd.statFile(fio, dest, .{}) catch null) |st| {
        if (st.size == bytes.len) return dest;
    }
    cwd.createDirPath(fio, dir) catch {
        gpa.free(dest);
        return null;
    };
    const pid: u64 = switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
    const unique = runtime.clockMonotonicNanos() ^ (pid << 32);
    const tmp_path = std.fmt.allocPrint(gpa, "{s}/.tmp-{x}", .{ dir, unique }) catch {
        gpa.free(dest);
        return null;
    };
    defer gpa.free(tmp_path);
    cwd.writeFile(fio, .{ .sub_path = tmp_path, .data = bytes }) catch {
        gpa.free(dest);
        return null;
    };
    markExecutable(tmp_path);
    cwd.rename(tmp_path, cwd, dest, fio) catch {
        cwd.deleteFile(fio, tmp_path) catch {};
        // A concurrent launch may have won the rename; the destination
        // still serves.
        if (cwd.statFile(fio, dest, .{}) catch null) |_| return dest;
        gpa.free(dest);
        return null;
    };
    return dest;
}

fn markExecutable(path: []const u8) void {
    if (builtin.os.tag == .windows) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&buf);
    _ = std.c.chmod(path_z, 0o755);
}

test "extraction is content-addressed and idempotent" {
    const gpa = std.testing.allocator;
    var threaded = threadedIo(gpa);
    defer threaded.deinit();
    const fio = threaded.io();

    const scratch = "/tmp/klio_test_shim_extract";
    std.Io.Dir.cwd().deleteTree(fio, scratch) catch {};
    const payload = "fake shim bytes for extraction";
    const first = extractInto(gpa, scratch, payload) orelse return error.TestUnexpectedResult;
    defer gpa.free(@constCast(first));
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(fio, first, gpa, .unlimited);
    defer gpa.free(on_disk);
    try std.testing.expectEqualStrings(payload, on_disk);

    // Second extraction finds the file and skips the write (same path,
    // same mtime).
    const st_before = try std.Io.Dir.cwd().statFile(fio, first, .{});
    const second = extractInto(gpa, scratch, payload) orelse return error.TestUnexpectedResult;
    defer gpa.free(@constCast(second));
    try std.testing.expectEqualStrings(first, second);
    const st_after = try std.Io.Dir.cwd().statFile(fio, first, .{});
    try std.testing.expectEqual(st_before.mtime.nanoseconds, st_after.mtime.nanoseconds);
    std.Io.Dir.cwd().deleteTree(fio, scratch) catch {};
}
