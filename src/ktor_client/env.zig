//! The process environment and standard error for the ktor natives: the C
//! library's environment on POSIX systems, the Win32 environment on Windows
//! (where names compare ignoring case). Callers serialize access.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const is_windows = builtin.os.tag == .windows;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const win = struct {
    extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: ?[*]u16, size: u32) callconv(.winapi) u32;
    extern "kernel32" fn SetEnvironmentVariableW(name: [*:0]const u16, value: ?[*:0]const u16) callconv(.winapi) i32;
    extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*]u16;
    extern "kernel32" fn FreeEnvironmentStringsW(block: [*]u16) callconv(.winapi) i32;
    extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn WriteFile(h: *anyopaque, buf: [*]const u8, len: u32, written: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
    const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));
};

/// The value of `name`, allocated with `a`, or null when it is unset.
pub fn get(a: Allocator, name: []const u8) Allocator.Error!?[]u8 {
    if (is_windows) {
        const wname = std.unicode.wtf8ToWtf16LeAllocZ(a, name) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWtf8 => return null,
        };
        defer a.free(wname);
        var size: u32 = 256;
        while (true) {
            const buf = try a.alloc(u16, size);
            defer a.free(buf);
            const n = win.GetEnvironmentVariableW(wname.ptr, buf.ptr, size);
            if (n == 0) {
                // Zero is both "unset" and "set to the empty string".
                if (win.GetEnvironmentVariableW(wname.ptr, null, 0) == 0) return null;
                return try a.dupe(u8, "");
            }
            if (n < size) return try std.unicode.wtf16LeToWtf8Alloc(a, buf[0..n]);
            size = n;
        }
    }
    const z = try a.dupeZ(u8, name);
    defer a.free(z);
    const value = std.c.getenv(z.ptr) orelse return null;
    return try a.dupe(u8, std.mem.span(value));
}

/// Sets `name` to `value` unless it is already set.
pub fn setIfAbsent(a: Allocator, name: []const u8, value: []const u8) Allocator.Error!void {
    if (is_windows) {
        if (try get(a, name)) |old| {
            a.free(old);
            return;
        }
        const wname = std.unicode.wtf8ToWtf16LeAllocZ(a, name) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWtf8 => return,
        };
        defer a.free(wname);
        const wvalue = std.unicode.wtf8ToWtf16LeAllocZ(a, value) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWtf8 => return,
        };
        defer a.free(wvalue);
        _ = win.SetEnvironmentVariableW(wname.ptr, wvalue.ptr);
        return;
    }
    const zn = try a.dupeZ(u8, name);
    defer a.free(zn);
    const zv = try a.dupeZ(u8, value);
    defer a.free(zv);
    _ = setenv(zn.ptr, zv.ptr, 0);
}

pub fn unset(a: Allocator, name: []const u8) Allocator.Error!void {
    if (is_windows) {
        const wname = std.unicode.wtf8ToWtf16LeAllocZ(a, name) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidWtf8 => return,
        };
        defer a.free(wname);
        _ = win.SetEnvironmentVariableW(wname.ptr, null);
        return;
    }
    const z = try a.dupeZ(u8, name);
    defer a.free(z);
    _ = unsetenv(z.ptr);
}

/// Every `NAME=value` entry, each allocated with `a`. Windows' per-drive
/// directory entries (`=C:=C:\...`) are not variables and are left out.
pub fn entries(a: Allocator, out: *std.ArrayList([]u8)) Allocator.Error!void {
    if (is_windows) {
        const block = win.GetEnvironmentStringsW() orelse return;
        defer _ = win.FreeEnvironmentStringsW(block);
        var i: usize = 0;
        while (block[i] != 0) {
            const start = i;
            while (block[i] != 0) i += 1;
            const entry = block[start..i];
            i += 1;
            if (entry[0] == '=') continue;
            try out.append(a, try std.unicode.wtf16LeToWtf8Alloc(a, entry));
        }
        return;
    }
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        try out.append(a, try a.dupe(u8, std.mem.span(entry)));
    }
}

/// Writes all of `bytes` to standard error, unbuffered.
pub fn writeStderr(bytes: []const u8) void {
    var off: usize = 0;
    if (is_windows) {
        const h = win.GetStdHandle(win.STD_ERROR_HANDLE) orelse return;
        if (@intFromPtr(h) == std.math.maxInt(usize)) return;
        while (off < bytes.len) {
            var n: u32 = 0;
            const chunk: u32 = @intCast(@min(bytes.len - off, 1 << 30));
            if (win.WriteFile(h, bytes.ptr + off, chunk, &n, null) == 0 or n == 0) return;
            off += n;
        }
        return;
    }
    while (off < bytes.len) {
        const rc = std.c.write(2, bytes.ptr + off, bytes.len - off);
        if (rc <= 0) return;
        off += @intCast(rc);
    }
}

const testing = std.testing;

test "a variable set only when absent reads back and unsets" {
    const a = testing.allocator;
    const name = "KLIO_KTOR_ENV_TEST_VARIABLE";
    try unset(a, name);
    try testing.expect((try get(a, name)) == null);
    try setIfAbsent(a, name, "first");
    try setIfAbsent(a, name, "second");
    const v = (try get(a, name)).?;
    defer a.free(v);
    try testing.expectEqualStrings("first", v);

    var list: std.ArrayList([]u8) = .empty;
    defer {
        for (list.items) |e| a.free(e);
        list.deinit(a);
    }
    try entries(a, &list);
    var found = false;
    for (list.items) |e| {
        if (std.mem.eql(u8, e, name ++ "=first")) found = true;
    }
    try testing.expect(found);

    try unset(a, name);
    try testing.expect((try get(a, name)) == null);
}
