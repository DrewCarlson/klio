//! Portable process-environment access.
//!
//! Zig 0.16 has no single global env accessor that works the same on every
//! target, so this module reads the running process environment per platform:
//! `/proc/self/environ` on Linux, the C `environ` array on other POSIX hosts,
//! and the PEB environment block on Windows. All of these expose the same
//! `KEY=VALUE` view; the value is returned as an `allocator`-owned copy.

const std = @import("std");
const builtin = @import("builtin");

/// Read an environment variable's value, returning an `allocator`-owned copy
/// or `null` when the variable is unset (or the environment is unreadable).
pub fn getVar(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!?[]u8 {
    if (builtin.os.tag == .windows) return getVarWindows(allocator, name);
    const data = readEnvironBlock(allocator) orelse return null;
    defer allocator.free(data);
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (eq == 0) continue;
        if (std.mem.eql(u8, entry[0..eq], name)) {
            return try allocator.dupe(u8, entry[eq + 1 ..]);
        }
    }
    return null;
}

/// Whether the named environment variable is present.
pub fn isSet(allocator: std.mem.Allocator, name: []const u8) bool {
    const v = getVar(allocator, name) catch return false;
    if (v) |owned| {
        allocator.free(owned);
        return true;
    }
    return false;
}

/// Populate `map` with every `KEY=VALUE` pair from the process environment.
/// Failures to read the environment leave `map` unchanged.
pub fn putAllInto(allocator: std.mem.Allocator, map: *std.process.Environ.Map) void {
    switch (builtin.os.tag) {
        .windows => putAllWindows(map),
        else => putAllNulBlock(allocator, map),
    }
}

/// Linux/POSIX: read the NUL-delimited `KEY=VALUE` block and split it.
fn putAllNulBlock(allocator: std.mem.Allocator, map: *std.process.Environ.Map) void {
    const data = readEnvironBlock(allocator) orelse return;
    defer allocator.free(data);
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (eq == 0) continue;
        map.put(entry[0..eq], entry[eq + 1 ..]) catch {};
    }
}

/// Read the whole `KEY=VALUE` environment block into an owned buffer.
/// Linux uses `/proc/self/environ`; other POSIX hosts reconstruct it from
/// the libc `environ` array.
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

/// Windows: walk the PEB env block, WTF-8 decoding each key and value.
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

/// Windows: the PEB holds the environment as a doubly-NUL-terminated block of
/// UTF-16 `KEY=VALUE` entries. Keys compare case-insensitively (Windows env
/// semantics). The value is WTF-8 decoded into an `allocator`-owned copy.
fn getVarWindows(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!?[]u8 {
    const windows = std.os.windows;
    const peb = windows.peb();
    const ptr = peb.ProcessParameters.Environment;

    var i: usize = 0;
    while (ptr[i] != 0) {
        const key_start = i;
        // Some special vars start with '='; don't treat a leading '=' as the
        // key/value separator.
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

/// Case-insensitive (ASCII) comparison between a UTF-16 env key and an ASCII
/// name. Env var names used here are ASCII, so a byte-wise fold suffices.
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
