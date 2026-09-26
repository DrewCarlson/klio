//! Process-global resource table: the program's `--include` files, served to
//! the `klio.bundle.Resources` bindings (and Compose's resource loaders over
//! them). A bundle's are embedded and served straight from the executable's
//! mmap; under `klio run` they are files on disk, read when asked for.
//! Written once before the program runs, and read-only during execution.

const std = @import("std");
const Allocator = std.mem.Allocator;

const pack = @import("pack");

/// One resource: embedded (`stored` borrows the bundle mmap for the
/// process), or a file on disk at `path`.
pub const Entry = struct {
    mount: []const u8,
    stored: []const u8,
    uncompressed_len: usize,
    compressed: bool,
    path: ?[]const u8 = null,
};

var entries: []const Entry = &.{};
var active = false;

/// Install the table. Called once, by bundle boot or `klio run`, before the
/// program runs; `list` and everything it references must live for the
/// process.
pub fn installEntries(list: []const Entry) void {
    entries = list;
    active = true;
}

pub fn isActive() bool {
    return active;
}

pub fn all() []const Entry {
    return entries;
}

pub fn find(mount: []const u8) ?*const Entry {
    for (entries) |*e| {
        if (std.mem.eql(u8, e.mount, mount)) return e;
    }
    return null;
}

/// Materialize an entry's bytes: an uncompressed embedded entry borrows the
/// mmap, a compressed one or a file allocates. Null on a corrupt frame or a
/// file that can no longer be read.
pub fn read(gpa: Allocator, e: *const Entry) Allocator.Error!?[]const u8 {
    if (e.path) |path| {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .unlimited) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => null,
        };
    }
    if (!e.compressed) return e.stored;
    return pack.zstd.decompress(gpa, e.stored, e.uncompressed_len) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ZstdFailed => null,
    };
}

test "find and read serve installed entries" {
    const gpa = std.testing.allocator;
    const plain = [_]Entry{
        .{ .mount = "a.txt", .stored = "hello", .uncompressed_len = 5, .compressed = false },
    };
    installEntries(&plain);
    defer {
        entries = &.{};
        active = false;
    }
    try std.testing.expect(isActive());
    const e = find("a.txt").?;
    const bytes = (try read(gpa, e)).?;
    try std.testing.expectEqualStrings("hello", bytes);
    try std.testing.expect(find("missing") == null);
}

test "a disk entry reads its file when asked, and null once the file is gone" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "note.txt", .data = "from disk" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const path = try std.fs.path.join(gpa, &.{ buf[0..n], "note.txt" });
    defer gpa.free(path);
    const list = [_]Entry{
        .{ .mount = "res/note.txt", .stored = "", .uncompressed_len = 0, .compressed = false, .path = path },
    };
    installEntries(&list);
    defer {
        entries = &.{};
        active = false;
    }
    const bytes = (try read(gpa, find("res/note.txt").?)).?;
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("from disk", bytes);
    try tmp.dir.deleteFile(std.testing.io, "note.txt");
    try std.testing.expect((try read(gpa, find("res/note.txt").?)) == null);
}
