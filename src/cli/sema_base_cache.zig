//! Where the sema pipeline keeps base images: one file per base, keyed by
//! the klio binary and every base file's path and text, under
//! `$KLIO_HOME/.klio/cache` (or `~/.klio/cache`) as
//! `sema-base-<key>.klio-sema`. The build installs the image of the base a
//! program without packs runs on beside the binary, under
//! `share/klio/cache`, and a run whose own cache has no image reads that one.
//! `KLIO_SEMA_IMAGE=0` turns the cache off; `KLIO_STDLIB_IMAGE_SHIPPED=0`
//! ignores the installed copy.

const std = @import("std");
const builtin = @import("builtin");
const span = @import("span");
const sema = @import("sema");
const runtime = @import("runtime");
const lower_driver = @import("lower_driver");

const Allocator = std.mem.Allocator;
const base_image = lower_driver.pipeline.base_image;

/// Whether the environment turns the base image off.
pub fn disabled() bool {
    const v = std.c.getenv("KLIO_SEMA_IMAGE") orelse return false;
    return std.mem.eql(u8, std.mem.span(v), "0");
}

/// The cache file of the base `base` as loaded into `map`; null when there
/// is no cache directory. Owned by `a`.
pub fn pathFor(a: Allocator, map: *const span.SourceMap, base: []const sema.SourceFile) ?[]const u8 {
    const dir = cacheDir(a) orelse return null;
    return pathIn(a, dir, map, base);
}

/// The file the image of `base` has in the cache directory `dir`. Owned by
/// `a`.
pub fn pathIn(a: Allocator, dir: []const u8, map: *const span.SourceMap, base: []const sema.SourceFile) ?[]const u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, fileName(map, base) }) catch null;
}

/// `sema-base-<key>.klio-sema`: the key hashes the binary's stamp, the
/// image version and every base file's path and text.
fn fileName(map: *const span.SourceMap, base: []const sema.SourceFile) [std.fmt.count("sema-base-{s}.klio-sema", .{[_]u8{0} ** 32})]u8 {
    var h = std.crypto.hash.Blake3.init(.{});
    if (exeStamp()) |stamp| h.update(std.mem.asBytes(&stamp));
    h.update(std.mem.asBytes(&base_image.version));
    for (base) |sf| {
        const src = map.getChecked(sf.ast.span.file) orelse continue;
        h.update(sf.path);
        h.update(&.{0});
        h.update(std.mem.asBytes(&src.source.len));
        h.update(src.source);
    }
    var key: [32]u8 = undefined;
    h.final(&key);
    const hex = std.fmt.bytesToHex(key[0..16], .lower);
    var out: [std.fmt.count("sema-base-{s}.klio-sema", .{[_]u8{0} ** 32})]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "sema-base-{s}.klio-sema", .{hex}) catch unreachable;
    return out;
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
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe = exePath(&buf) orelse return null;
    // The shipped cache sits beside the real file, not beside a link to it.
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_z = a.dupeZ(u8, exe) catch return null;
    const real_z = std.c.realpath(exe_z, &real_buf) orelse return null;
    const real = std.mem.sliceTo(real_z, 0);
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
    const pid: u64 = switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
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

/// The running executable's path, into `buf`.
fn exePath(buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    return switch (builtin.os.tag) {
        .linux => "/proc/self/exe",
        .macos, .ios, .tvos, .watchos, .visionos => blk: {
            var n: u32 = buf.len;
            if (std.c._NSGetExecutablePath(buf, &n) != 0) return null;
            break :blk std.mem.sliceTo(buf, 0);
        },
        else => null,
    };
}

/// Size and modification time of the running executable: a rebuilt klio
/// binds natives differently, so its images are its own. The build installs
/// the binary with its modification time, so the installed copy keys as
/// the one that baked the shipped image.
fn exeStamp() ?[2]u64 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = exePath(&buf) orelse return null;
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const st = std.Io.Dir.cwd().statFile(threaded.io(), path, .{}) catch return null;
    const mtime_ns: u64 = @truncate(@as(u128, @bitCast(@as(i128, st.mtime.nanoseconds))));
    return .{ st.size, mtime_ns };
}
