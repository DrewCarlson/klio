//! A program's resources: the files `--include <path[:mount]>` and a
//! manifest's `[application] include` name, each read at a mount path. `klio
//! bundle` embeds them in the executable and `klio run` serves them from
//! disk, so a program reads the same resources either way, as a JVM program
//! reads its classpath resources from a directory or from its jar.

const std = @import("std");
const Allocator = std.mem.Allocator;

const stdlib = @import("stdlib");

pub const Include = struct {
    path: []const u8,
    mount: []const u8,
};

/// One file of an include: where it is and the path a program reads it at.
pub const File = struct {
    path: []const u8,
    mount: []const u8,
};

/// `path[:mount]`; an empty mount takes the default.
pub fn parse(val: []const u8) Include {
    if (std.mem.findScalarLast(u8, val, ':')) |colon| {
        return .{ .path = val[0..colon], .mount = val[colon + 1 ..] };
    }
    return .{ .path = val, .mount = "" };
}

/// The files of an include in mount order: a file alone at its mount, or a
/// directory's files at the mount joined with each one's path under it.
/// The default mount is the include's path relative to the main source's
/// directory, or its basename when it is not under it. Null when the include
/// cannot be read.
pub fn files(arena: Allocator, fio: std.Io, inc: Include, main_path: []const u8) ?[]const File {
    const cwd = std.Io.Dir.cwd();
    const mount_root = if (inc.mount.len != 0) inc.mount else defaultMount(inc.path, main_path);
    var out: std.ArrayList(File) = .empty;
    const st = cwd.statFile(fio, inc.path, .{}) catch return null;
    if (st.kind != .directory) {
        out.append(arena, .{ .path = inc.path, .mount = mount_root }) catch return null;
        return out.items;
    }
    var dir = cwd.openDir(fio, inc.path, .{ .iterate = true }) catch return null;
    defer dir.close(fio);
    var walker = dir.walk(arena) catch return null;
    defer walker.deinit();
    var rels: std.ArrayList([]const u8) = .empty;
    while (walker.next(fio) catch return null) |entry| {
        if (entry.kind != .file) continue;
        rels.append(arena, arena.dupe(u8, entry.path) catch return null) catch return null;
    }
    // Sorted, as readdir order is not stable.
    std.mem.sort([]const u8, rels.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (rels.items) |rel| {
        const full = std.fs.path.join(arena, &.{ inc.path, rel }) catch return null;
        const mount = std.fmt.allocPrint(arena, "{s}/{s}", .{ mount_root, rel }) catch return null;
        out.append(arena, .{ .path = full, .mount = mount }) catch return null;
    }
    return out.items;
}

pub fn defaultMount(path: []const u8, main_path: []const u8) []const u8 {
    const dir = std.fs.path.dirname(main_path) orelse "";
    if (dir.len != 0 and std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == '/') {
        return path[dir.len + 1 ..];
    }
    return std.fs.path.basename(path);
}

/// Serves `includes` from disk to the program `klio run` runs, as a bundle
/// serves its embedded ones: `klio.bundle.Resources` and Compose's resource
/// loaders read them. The first include that cannot be read is named in
/// `failed`. The table lives for the process.
pub fn serveFromDisk(gpa: Allocator, fio: std.Io, includes: []const Include, main_path: []const u8, failed: *?[]const u8) bool {
    if (includes.len == 0) return true;
    var entries: std.ArrayList(stdlib.bundle_resources.Entry) = .empty;
    for (includes) |inc| {
        const list = files(gpa, fio, inc, main_path) orelse {
            failed.* = inc.path;
            return false;
        };
        for (list) |f| {
            entries.append(gpa, .{ .mount = f.mount, .stored = "", .uncompressed_len = 0, .compressed = false, .path = f.path }) catch return false;
        }
    }
    stdlib.bundle_resources.installEntries(entries.items);
    return true;
}

test "an include's default mount is its path under the main source's directory, else its name" {
    try std.testing.expectEqualStrings("assets", defaultMount("app/assets", "app/main.kt"));
    try std.testing.expectEqualStrings("assets/logo.svg", defaultMount("app/assets/logo.svg", "app/main.kt"));
    try std.testing.expectEqualStrings("assets", defaultMount("other/assets", "app/main.kt"));
    try std.testing.expectEqualStrings("res", defaultMount("res", "main.kt"));
}

test "parse splits a mount after the last colon" {
    const a = parse("app/assets:img");
    try std.testing.expectEqualStrings("app/assets", a.path);
    try std.testing.expectEqualStrings("img", a.mount);
    const b = parse("app/assets");
    try std.testing.expectEqualStrings("", b.mount);
}
