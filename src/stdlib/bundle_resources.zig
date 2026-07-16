//! Process-global resource table for bundle mode: the `--include` files
//! embedded in a bundle, served to the `klio.bundle.Resources` host
//! bindings straight from the executable's mmap (entries decompress on
//! read; uncompressed entries are zero-copy borrows).
//!
//! Set-up-time configuration like `ExtraKnownPackages`: written once by
//! bundle boot before the program runs, read-only during execution.

const std = @import("std");
const Allocator = std.mem.Allocator;

const pack = @import("pack");

/// One embedded resource. `stored` borrows the bundle mmap for the
/// process lifetime.
pub const Entry = struct {
    mount: []const u8,
    stored: []const u8,
    uncompressed_len: usize,
    compressed: bool,
};

var entries: []const Entry = &.{};
var active = false;

/// Install the table. Called once by bundle boot; `list` and everything
/// it references must live for the process.
pub fn installEntries(list: []const Entry) void {
    entries = list;
    active = true;
}

/// Whether the process runs in bundle mode with a resource table (even
/// an empty one).
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

/// Materialize an entry's bytes. Uncompressed entries borrow the mmap;
/// compressed entries allocate. Null on a corrupt frame.
pub fn read(gpa: Allocator, e: *const Entry) Allocator.Error!?[]const u8 {
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
