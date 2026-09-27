//! Where the sema pipeline keeps base images: one file per base, keyed by
//! the klio binary and what the base is built from (`Key`), under
//! `$KLIO_HOME/.klio/cache` (or `~/.klio/cache`) as
//! `sema-base-<key>.klio-sema`. The build installs the image of the base a
//! program without packs runs on beside the binary, under
//! `share/klio/cache`, and a run whose own cache has no image reads that one.
//! `KLIO_SEMA_IMAGE=0` turns the cache off; `KLIO_STDLIB_IMAGE_SHIPPED=0`
//! ignores the installed copy.

const std = @import("std");
const runtime = @import("runtime");
const lower_driver = @import("lower_driver");

const Allocator = std.mem.Allocator;
const base_image = lower_driver.pipeline.base_image;

/// Whether the environment turns the base image off.
pub fn disabled() bool {
    const v = std.c.getenv("KLIO_SEMA_IMAGE") orelse return false;
    return std.mem.eql(u8, std.mem.span(v), "0");
}

/// What names a base's image: the binary (a rebuilt klio binds natives
/// differently), the image's layout, and the base, as the files it is built
/// from, read but not parsed. The stdlib's and the sema actuals' files go
/// in by path and text, a pack by its content hash and the features it was
/// loaded with, each in the order the base loads it.
pub const Key = struct {
    h: std.crypto.hash.Blake3,

    pub fn init() Key {
        var k: Key = .{ .h = .init(.{}) };
        if (exeStamp()) |stamp| k.h.update(std.mem.asBytes(&stamp));
        k.h.update(std.mem.asBytes(&base_image.version));
        return k;
    }

    pub fn file(self: *Key, path: []const u8, text: []const u8) void {
        self.h.update(path);
        self.h.update(&.{0});
        self.h.update(std.mem.asBytes(&text.len));
        self.h.update(text);
    }

    pub fn pack(self: *Key, hash: []const u8, features: []const []const u8) void {
        self.h.update("pack\x00");
        self.h.update(hash);
        for (features) |f| {
            self.h.update(f);
            self.h.update(&.{0});
        }
        self.h.update(&.{1});
    }

    pub fn final(self: *Key) [16]u8 {
        var out: [32]u8 = undefined;
        self.h.final(&out);
        return out[0..16].*;
    }
};

/// The cache file of the base `key` names; null when there is no cache
/// directory. Owned by `a`.
pub fn pathFor(a: Allocator, key: [16]u8) ?[]const u8 {
    const dir = cacheDir(a) orelse return null;
    return pathIn(a, dir, key);
}

/// The file the image of the base `key` names has in the cache directory
/// `dir`: `sema-base-<key>.klio-sema`. Owned by `a`.
pub fn pathIn(a: Allocator, dir: []const u8, key: [16]u8) ?[]const u8 {
    return std.fmt.allocPrint(a, "{s}/sema-base-{s}.klio-sema", .{ dir, std.fmt.bytesToHex(key, .lower) }) catch null;
}

/// The image at `path`, read into `a`; else the copy the build installed
/// beside the binary under the same name; null when neither is there.
pub fn read(a: Allocator, path: []const u8) ?[]const u8 {
    if (readFile(a, path)) |bytes| return bytes;
    const shipped = shippedPath(a, std.fs.path.basename(path)) orelse return null;
    return readFile(a, shipped);
}

fn readFile(a: Allocator, path: []const u8) ?[]const u8 {
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, a, .unlimited) catch null;
}

/// `<bin dir>/../share/klio/cache/<name>`, where the build installs the
/// image it baked. Null under `KLIO_STDLIB_IMAGE_SHIPPED=0`.
fn shippedPath(a: Allocator, name: []const u8) ?[]const u8 {
    if (runtime.envOnce("KLIO_STDLIB_IMAGE_SHIPPED")) |v| {
        if (std.mem.eql(u8, v, "0")) return null;
    }
    // The shipped cache sits beside the real file, not beside a link to it,
    // and `selfExePath` resolves links.
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = runtime.platform.selfExePath(&buf) orelse return null;
    const bin_dir = std.fs.path.dirname(real) orelse return null;
    return std.fs.path.join(a, &.{ bin_dir, "..", "share", "klio", "cache", name }) catch null;
}

/// Writes `bytes` as the image at `path` through a temporary file, so a
/// reader never sees half of one. A cache that cannot be written is only
/// slower.
pub fn write(a: Allocator, path: []const u8, bytes: []const u8) void {
    writeOrFail(a, path, bytes) catch {};
}

/// `write`, saying why it could not.
pub fn writeOrFail(a: Allocator, path: []const u8, bytes: []const u8) !void {
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const fio = threaded.io();
    const pid = runtime.platform.processId();
    const tmp = try std.fmt.allocPrint(a, "{s}.tmp-{x}", .{ path, runtime.clockMonotonicNanos() ^ (pid << 32) });
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(fio, .{ .sub_path = tmp, .data = bytes });
    cwd.rename(tmp, cwd, path, fio) catch |e| {
        cwd.deleteFile(fio, tmp) catch {};
        return e;
    };
}

fn cacheDir(a: Allocator) ?[]const u8 {
    const home = (runtime.procEnvKlioHome(a) catch null) orelse return null;
    const dir = std.fs.path.join(a, &.{ home, ".klio", "cache" }) catch return null;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().createDirPath(threaded.io(), dir) catch return null;
    return dir;
}

/// The executable whose images this process names: the running one, or
/// the target binary a cross build bakes the shipped image for
/// (`bake-image --stdlib-cache <dir> --for <exe>`).
pub var stamp_exe: ?[]const u8 = null;

/// Size and modification time of the running executable: a rebuilt klio
/// binds natives differently, so its images are its own. The build installs
/// the binary with its modification time, so the installed copy keys as
/// the one that baked the shipped image.
fn exeStamp() ?[2]u64 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = stamp_exe orelse runtime.platform.selfExePath(&buf) orelse return null;
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const st = std.Io.Dir.cwd().statFile(threaded.io(), path, .{}) catch return null;
    const mtime_ns: u64 = @truncate(@as(u128, @bitCast(@as(i128, st.mtime.nanoseconds))));
    // Whole 100 ns ticks, the finest time NTFS keeps: a binary cross-built
    // elsewhere and copied to Windows keys as the one that baked its image.
    return .{ st.size, mtime_ns - mtime_ns % 100 };
}

