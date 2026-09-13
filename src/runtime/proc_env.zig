//! Portable process-environment access, since Zig 0.16 has no global accessor
//! that works the same everywhere: `/proc/self/environ` on Linux, the C
//! `environ` array on other POSIX hosts, the PEB block on Windows. The value is
//! an `allocator`-owned copy.

const std = @import("std");
const builtin = @import("builtin");

/// Null when the variable is unset or the environment is unreadable.
pub fn getVar(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!?[]u8 {
    if (builtin.os.tag == .windows) return getVarWindows(allocator, name);
    const data = readEnvironBlock(allocator) orelse return null;
    defer allocator.free(data);
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.findScalar(u8, entry, '=') orelse continue;
        if (eq == 0) continue;
        if (std.mem.eql(u8, entry[0..eq], name)) {
            return try allocator.dupe(u8, entry[eq + 1 ..]);
        }
    }
    return null;
}

/// The base directory holding klio's `.klio` data tree. `KLIO_HOME` overrides
/// `HOME`, so a project can point its data at a repo-local folder. Caller
/// frees.
pub fn klioHome(allocator: std.mem.Allocator) std.mem.Allocator.Error!?[]u8 {
    if (try getVar(allocator, "KLIO_HOME")) |v| {
        if (v.len != 0) return v;
        allocator.free(v);
    }
    return getVar(allocator, "HOME");
}

pub fn isSet(allocator: std.mem.Allocator, name: []const u8) bool {
    const v = getVar(allocator, name) catch return false;
    if (v) |owned| {
        allocator.free(owned);
        return true;
    }
    return false;
}

pub fn putAllInto(allocator: std.mem.Allocator, map: *std.process.Environ.Map) void {
    switch (builtin.os.tag) {
        .windows => putAllWindows(map),
        else => putAllNulBlock(allocator, map),
    }
}

fn putAllNulBlock(allocator: std.mem.Allocator, map: *std.process.Environ.Map) void {
    const data = readEnvironBlock(allocator) orelse return;
    defer allocator.free(data);
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.findScalar(u8, entry, '=') orelse continue;
        if (eq == 0) continue;
        map.put(entry[0..eq], entry[eq + 1 ..]) catch {};
    }
}

/// Other POSIX hosts reconstruct it from the libc `environ` array.
fn readEnvironBlock(allocator: std.mem.Allocator) ?[]u8 {
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const fd_raw = linux.open("/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0);
        if (linux.errno(fd_raw) != .SUCCESS) return null;
        const fd: i32 = @intCast(fd_raw);
        defer _ = linux.close(fd);

        var contents: std.ArrayList(u8) = .empty;
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = linux.read(fd, &buf, buf.len);
            if (linux.errno(n) != .SUCCESS) {
                contents.deinit(allocator);
                return null;
            }
            if (n == 0) break;
            contents.appendSlice(allocator, buf[0..n]) catch {
                contents.deinit(allocator);
                return null;
            };
        }
        return contents.toOwnedSlice(allocator) catch null;
    }
    if (!builtin.link_libc) return null;
    var contents: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const e = std.mem.span(entry);
        contents.appendSlice(allocator, e) catch {
            contents.deinit(allocator);
            return null;
        };
        contents.append(allocator, 0) catch {
            contents.deinit(allocator);
            return null;
        };
    }
    return contents.toOwnedSlice(allocator) catch null;
}

fn putAllWindows(map: *std.process.Environ.Map) void {
    const windows = std.os.windows;
    const a = map.allocator;
    const peb = windows.peb();
    const ptr = peb.ProcessParameters.Environment;

    var i: usize = 0;
    while (ptr[i] != 0) {
        const key_start = i;
        if (ptr[i] == '=') i += 1;
        while (ptr[i] != 0 and ptr[i] != '=') : (i += 1) {}
        const key_w = ptr[key_start..i];

        const value_start = i + 1;
        while (ptr[i] != 0) : (i += 1) {}
        const value_w = ptr[value_start..i];
        i += 1;

        if (key_w.len == 0) continue;
        const key = wtf16Alloc(a, key_w) orelse continue;
        defer a.free(key);
        const value = wtf16Alloc(a, value_w) orelse continue;
        defer a.free(value);
        map.put(key, value) catch {};
    }
}

fn wtf16Alloc(allocator: std.mem.Allocator, w: []const u16) ?[]u8 {
    const len = std.unicode.calcWtf8Len(w);
    const out = allocator.alloc(u8, len) catch return null;
    std.debug.assert(std.unicode.wtf16LeToWtf8(out, w) == len);
    return out;
}

/// A doubly-NUL-terminated block of UTF-16 `KEY=VALUE` entries, with
/// case-insensitive keys.
fn getVarWindows(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!?[]u8 {
    const windows = std.os.windows;
    const peb = windows.peb();
    const ptr = peb.ProcessParameters.Environment;

    var i: usize = 0;
    while (ptr[i] != 0) {
        const key_start = i;
        // Some special vars start with '=', which is then not the separator.
        if (ptr[i] == '=') i += 1;
        while (ptr[i] != 0 and ptr[i] != '=') : (i += 1) {}
        const key_w = ptr[key_start..i];

        const value_start = i + 1;
        while (ptr[i] != 0) : (i += 1) {}
        const value_w = ptr[value_start..i];
        i += 1; // skip the terminating NUL of this entry

        if (keyMatchesWtf16(key_w, name)) {
            const len = std.unicode.calcWtf8Len(value_w);
            const out = try allocator.alloc(u8, len);
            errdefer allocator.free(out);
            std.debug.assert(std.unicode.wtf16LeToWtf8(out, value_w) == len);
            return out;
        }
    }
    return null;
}

fn keyMatchesWtf16(key_w: []const u16, name: []const u8) bool {
    if (key_w.len != name.len) return false;
    for (key_w, name) |kc, nc| {
        if (kc > 0x7f) return false;
        if (std.ascii.toLower(@intCast(kc)) != std.ascii.toLower(nc)) return false;
    }
    return true;
}

const testing = std.testing;

test "isSet returns false for an unlikely variable name" {
    try testing.expect(!isSet(testing.allocator, "KLIO_DEFINITELY_NOT_SET_XYZZY"));
}
