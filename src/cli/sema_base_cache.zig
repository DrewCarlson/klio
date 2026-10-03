//! Where the sema pipeline keeps base images: one file per base, keyed by
//! the klio binary and what the base is built from (`Key`), under
//! `$KLIO_HOME/.klio/cache` (or `~/.klio/cache`) as
//! `sema-base-<key>.klio-sema`. The build installs the image of the base a
//! program without packs runs on beside the binary, under
//! `share/klio/cache`, and a run whose own cache has no image reads that one.
//! `KLIO_SEMA_IMAGE=0` turns the cache off; `KLIO_STDLIB_IMAGE_SHIPPED=0`
//! ignores the installed copy.
//!
//! A run maps its image rather than reading it: the bodies it never calls
//! are never read in. The cache keeps to a size (`KLIO_CACHE_MAX_MB`, 1 GiB
//! by default): each write evicts the images used longest ago beyond it,
//! a read marking its image used.

const std = @import("std");
const runtime = @import("runtime");
const lower_driver = @import("lower_driver");

const Allocator = std.mem.Allocator;
const base_image = lower_driver.pipeline.base_image;
const codec = @import("interp_ir").codec;

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

/// The image at `path`, mapped read-only for the process's life, and
/// marked used; else the copy the build installed beside the binary under
/// the same name; null when neither is there.
pub fn read(a: Allocator, path: []const u8) ?[]const u8 {
    if (mapFile(path)) |bytes| {
        touch(a, path);
        return bytes;
    }
    const shipped = shippedPath(a, std.fs.path.basename(path)) orelse return null;
    return mapFile(shipped);
}

fn mapFile(path: []const u8) ?[]const u8 {
    const file = runtime.platform.ReadOnlyFile.open(path) orelse return null;
    defer file.close();
    const len = file.size() orelse return null;
    if (len == 0) return null;
    return file.mapAll(@intCast(len));
}

/// Marks the image at `path` used now: eviction takes the images used
/// longest ago first.
fn touch(a: Allocator, path: []const u8) void {
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().setTimestamps(threaded.io(), path, .{ .access_timestamp = .now, .modify_timestamp = .now }) catch {};
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
/// reader never sees half of one, then keeps the cache to its size
/// (`prune`). A cache that cannot be written is only slower.
pub fn write(a: Allocator, path: []const u8, bytes: []const u8) void {
    writeOrFail(a, path, bytes) catch return;
    pruneFor(a, path);
}

/// Keeps the cache the image at `path` is in to its size, never evicting
/// that image (`prune`).
pub fn pruneFor(a: Allocator, path: []const u8) void {
    const dir = std.fs.path.dirname(path) orelse return;
    prune(a, dir, std.fs.path.basename(path), budget());
}

/// An image written as it is encoded (`sink`) into a temporary file beside
/// `path`, which `commit` renames into place: a reader never sees half of
/// one.
pub const Writing = struct {
    threaded: std.Io.Threaded,
    file: std.Io.File,
    tmp: []const u8,
    path: []const u8,

    pub fn begin(a: Allocator, path: []const u8) !*Writing {
        const w = try a.create(Writing);
        w.threaded = .init(a, .{});
        errdefer w.threaded.deinit();
        const pid = runtime.platform.processId();
        w.tmp = try std.fmt.allocPrint(a, "{s}.tmp-{x}", .{ path, runtime.clockMonotonicNanos() ^ (pid << 32) });
        w.path = path;
        w.file = try std.Io.Dir.cwd().createFile(w.threaded.io(), w.tmp, .{});
        return w;
    }

    pub fn sink(self: *Writing) codec.Sink {
        return .{ .ctx = self, .writeAt = writeAt };
    }

    fn writeAt(ctx: *anyopaque, offset: u64, bytes: []const u8) anyerror!void {
        const self: *Writing = @ptrCast(@alignCast(ctx));
        try self.file.writePositionalAll(self.threaded.io(), bytes, offset);
    }

    /// Puts the image at its path.
    pub fn commit(self: *Writing) !void {
        const io = self.threaded.io();
        defer self.threaded.deinit();
        self.file.close(io);
        const cwd = std.Io.Dir.cwd();
        cwd.rename(self.tmp, cwd, self.path, io) catch |e| {
            cwd.deleteFile(io, self.tmp) catch {};
            return e;
        };
    }

    /// Drops what was written.
    pub fn abort(self: *Writing) void {
        const io = self.threaded.io();
        self.file.close(io);
        std.Io.Dir.cwd().deleteFile(io, self.tmp) catch {};
        self.threaded.deinit();
    }
};

/// The cache's size: `KLIO_CACHE_MAX_MB` megabytes, else 1 GiB.
fn budget() u64 {
    const mb: u64 = if (runtime.envOnce("KLIO_CACHE_MAX_MB")) |v| std.fmt.parseInt(u64, v, 10) catch 1024 else 1024;
    return mb * 1024 * 1024;
}

const Entry = struct { name: []const u8, size: u64, mtime: i128 };

/// Keeps the images in `dir` within `limit` bytes, evicting the ones used
/// longest ago first and never `keep`. Removes too what an interrupted
/// write left (a temporary file an hour old) and what an older klio kept
/// there, which nothing reads (`stdlib-*.klio-image`, `stdlib-meta-*.bin`).
/// A file that will not go (another process has it open) stays.
pub fn prune(a: Allocator, dir_path: []const u8, keep: []const u8, limit: u64) void {
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    const now = std.Io.Clock.real.now(io).nanoseconds;
    var images: std.ArrayList(Entry) = .empty;
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        const st = dir.statFile(io, e.name, .{}) catch continue;
        const mtime: i128 = st.mtime.nanoseconds;
        const stale_tmp = std.mem.indexOf(u8, e.name, ".tmp-") != null and now - mtime > std.time.ns_per_hour;
        const legacy = (std.mem.startsWith(u8, e.name, "stdlib-") and std.mem.endsWith(u8, e.name, ".klio-image")) or
            (std.mem.startsWith(u8, e.name, "stdlib-meta-") and std.mem.endsWith(u8, e.name, ".bin"));
        if (stale_tmp or legacy) {
            dir.deleteFile(io, e.name) catch {};
            continue;
        }
        if (!std.mem.startsWith(u8, e.name, "sema-base-") or !std.mem.endsWith(u8, e.name, ".klio-sema")) continue;
        const name = a.dupe(u8, e.name) catch return;
        images.append(a, .{ .name = name, .size = st.size, .mtime = mtime }) catch return;
        total += st.size;
    }
    if (total <= limit) return;
    std.mem.sort(Entry, images.items, {}, struct {
        fn lt(_: void, x: Entry, y: Entry) bool {
            return x.mtime < y.mtime;
        }
    }.lt);
    for (images.items) |e| {
        if (total <= limit) break;
        if (std.mem.eql(u8, e.name, keep)) continue;
        dir.deleteFile(io, e.name) catch continue;
        total -= e.size;
    }
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

test "a pruned cache keeps within its size, the newest images and the one just written" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const names = [_][]const u8{ "sema-base-a.klio-sema", "sema-base-b.klio-sema", "sema-base-c.klio-sema", "stdlib-x.klio-image", "notes.txt" };
    for (names, 0..) |n, i| {
        try tmp.dir.writeFile(io, .{ .sub_path = n, .data = "0123456789" });
        // Oldest first: a, b, c.
        try tmp.dir.setTimestamps(io, n, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, @intCast(i + 1)) * std.time.ns_per_s } } });
    }
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    // Room for two images: the oldest goes, unless it is the one kept.
    prune(arena.allocator(), dir_path, "sema-base-a.klio-sema", 20);
    _ = try tmp.dir.statFile(io, "sema-base-a.klio-sema", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "sema-base-b.klio-sema", .{}));
    _ = try tmp.dir.statFile(io, "sema-base-c.klio-sema", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "stdlib-x.klio-image", .{}));
    _ = try tmp.dir.statFile(io, "notes.txt", .{});
}

test "an image written as it is encoded appears at its path only once committed" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir_path = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const path = try std.fs.path.join(arena.allocator(), &.{ dir_path, "sema-base-k.klio-sema" });

    const w = try Writing.begin(arena.allocator(), path);
    const sink = w.sink();
    try sink.writeAt(sink.ctx, 0, "head....");
    try sink.writeAt(sink.ctx, 8, "body");
    // A header filled in last.
    try sink.writeAt(sink.ctx, 4, "1234");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "sema-base-k.klio-sema", .{}));
    try w.commit();
    const got = try tmp.dir.readFileAlloc(io, "sema-base-k.klio-sema", a, .limited(64));
    defer a.free(got);
    try std.testing.expectEqualStrings("head1234body", got);

    // An abandoned image leaves nothing behind.
    const dropped = try Writing.begin(arena.allocator(), try std.fs.path.join(arena.allocator(), &.{ dir_path, "sema-base-d.klio-sema" }));
    const ds = dropped.sink();
    try ds.writeAt(ds.ctx, 0, "partial");
    dropped.abort();
    var it = tmp.dir.iterate();
    var files: usize = 0;
    while (try it.next(io)) |_| files += 1;
    try std.testing.expectEqual(@as(usize, 1), files);
}
