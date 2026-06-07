//! File walking + per-file parse driving.

const std = @import("std");

const parse = @import("parse.zig");
const Decl = parse.Decl;
const parseFile = parse.parseFile;

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const FailedFile = struct {
    path: []const u8,
    err: []const u8,

    pub fn deinit(self: *FailedFile, allocator: Allocator) void {
        allocator.free(self.path);
        allocator.free(self.err);
        self.* = undefined;
    }
};

pub const CollectStats = struct {
    files_seen: usize = 0,
    files_parsed: usize = 0,
    files_failed: std.ArrayList(FailedFile) = .empty,
    total_decls: usize = 0,

    pub fn deinit(self: *CollectStats, allocator: Allocator) void {
        for (self.files_failed.items) |*f| f.deinit(allocator);
        self.files_failed.deinit(allocator);
        self.* = undefined;
    }
};

pub const FileDecls = struct {
    rel_path: []const u8,
    package: []const u8,
    decls: []Decl,

    pub fn deinit(self: *FileDecls, allocator: Allocator) void {
        allocator.free(self.rel_path);
        allocator.free(self.package);
        for (self.decls) |*d| d.deinit(allocator);
        allocator.free(self.decls);
        self.* = undefined;
    }
};

pub const CollectResult = struct {
    files: []FileDecls,
    stats: CollectStats,

    pub fn deinit(self: *CollectResult, allocator: Allocator) void {
        for (self.files) |*f| f.deinit(allocator);
        allocator.free(self.files);
        self.stats.deinit(allocator);
        self.* = undefined;
    }
};

/// Walk the curated stdlib roots under `stdlib_root` and return all parsed
/// declarations. `stdlib_root` is expected to be `kotlin/libraries/stdlib`.
/// `stdlib_root` is relative to the cwd (or absolute).
pub fn collectDecls(allocator: Allocator, io: Io, stdlib_root: []const u8) Allocator.Error!CollectResult {
    var out: std.ArrayList(FileDecls) = .empty;
    errdefer {
        for (out.items) |*f| f.deinit(allocator);
        out.deinit(allocator);
    }
    var stats = CollectStats{};
    errdefer stats.deinit(allocator);

    const roots = [_][]const u8{
        "common/src/generated",
        "common/src/kotlin",
        "src/kotlin",
    };

    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }
    for (roots) |sub| {
        const root = try std.fs.path.join(allocator, &.{ stdlib_root, sub });
        defer allocator.free(root);
        try gatherKtFiles(allocator, io, root, &files);
    }
    std.mem.sort([]const u8, files.items, {}, lessStr);

    for (files.items) |path| {
        stats.files_seen += 1;
        const rel = stripPrefix(path, stdlib_root);
        const src = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try stats.files_failed.append(allocator, .{
                    .path = try allocator.dupe(u8, path),
                    .err = try allocator.dupe(u8, @errorName(e)),
                });
                continue;
            },
        };
        defer allocator.free(src);
        var pf = try parseFile(allocator, src);
        stats.files_parsed += 1;
        stats.total_decls += pf.decls.len;
        try out.append(allocator, .{
            .rel_path = try allocator.dupe(u8, rel),
            .package = pf.package,
            .decls = pf.decls,
        });
        // `out` took ownership of pf.package and pf.decls.
        pf.package = "";
        pf.decls = &.{};
    }

    return .{ .files = try out.toOwnedSlice(allocator), .stats = stats };
}

/// Strip a leading `prefix` (plus any path separator) from `path`. Returns a
/// slice into `path`.
fn stripPrefix(path: []const u8, prefix: []const u8) []const u8 {
    if (path.len > prefix.len and std.mem.startsWith(u8, path, prefix)) {
        var rest = path[prefix.len..];
        while (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) {
            rest = rest[1..];
        }
        return rest;
    }
    return path;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn gatherKtFiles(allocator: Allocator, io: Io, root: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const child = std.fs.path.join(allocator, &.{ root, entry.name }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        switch (entry.kind) {
            .directory => {
                defer allocator.free(child);
                try gatherKtFiles(allocator, io, child, out);
            },
            else => {
                if (std.mem.endsWith(u8, entry.name, ".kt")) {
                    try out.append(allocator, child);
                } else {
                    allocator.free(child);
                }
            },
        }
    }
}

const testing = std.testing;

test "stripPrefix removes the leading root and separator" {
    try testing.expectEqualStrings(
        "common/src/kotlin/Foo.kt",
        stripPrefix("kotlin/libraries/stdlib/common/src/kotlin/Foo.kt", "kotlin/libraries/stdlib"),
    );
    try testing.expectEqualStrings("Foo.kt", stripPrefix("Foo.kt", "kotlin/libraries/stdlib"));
}

test "collectDecls on a missing root yields empty results" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var result = try collectDecls(testing.allocator, io, "this/dir/does/not/exist");
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), result.files.len);
    try testing.expectEqual(@as(usize, 0), result.stats.files_seen);
}
