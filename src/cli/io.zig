//! Process stdio helpers for the CLI.
//!
//! Zig 0.16's `std.fs.File` writer API needs an explicit `Io` instance
//! and buffer; for the CLI's line-oriented output a direct `write(2)`
//! against the process file descriptors is simpler and matches the
//! pattern used elsewhere in the workspace. Also provides a
//! `runtime.Output` sink that writes program output to stdout.

const std = @import("std");
const linux = std.os.linux;

const runtime = @import("runtime");
const Output = runtime.Output;

const STDIN: i32 = 0;
const STDOUT: i32 = 1;
const STDERR: i32 = 2;

fn writeFd(fd: i32, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const rc = linux.write(fd, data.ptr + off, data.len - off);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return;
        if (rc == 0) return;
        off += rc;
    }
}

pub fn writeStdout(s: []const u8) void {
    writeFd(STDOUT, s);
}

pub fn writeStderr(s: []const u8) void {
    writeFd(STDERR, s);
}

/// Read the full process command line (argv) into an owned slice of
/// owned strings. Zig 0.16's `std.process.Args` is only constructible
/// from the entry-point vector, so for a `run(gpa)` entry the argv is
/// recovered from `/proc/self/cmdline` (NUL-separated). The caller owns
/// the returned slice and each element.
pub fn processArgs(gpa: std.mem.Allocator) ![]const []const u8 {
    const raw = readWholeFd("/proc/self/cmdline", gpa) catch return &.{};
    defer gpa.free(raw);
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |a| gpa.free(a);
        out.deinit(gpa);
    }
    var it = std.mem.splitScalar(u8, raw, 0);
    while (it.next()) |arg| {
        if (arg.len == 0) continue;
        try out.append(gpa, try gpa.dupe(u8, arg));
    }
    return out.toOwnedSlice(gpa);
}

/// Free a slice produced by `processArgs` / `readFile`-style helpers.
pub fn freeArgs(gpa: std.mem.Allocator, args: []const []const u8) void {
    for (args) |a| gpa.free(a);
    gpa.free(args);
}

/// Read a whole file at `path` (opened relative to cwd) into an owned
/// buffer. Returns an error on open/read failure.
pub fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return readWholeFd(path, gpa);
}

fn readWholeFd(path: []const u8, gpa: std.mem.Allocator) ![]u8 {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);
    const rc = linux.open(path_z, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = linux.read(fd, &chunk, chunk.len);
        const e = linux.errno(n);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(gpa, chunk[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

/// Read a line from stdin into `buf` (without the trailing newline).
/// Returns the slice read, or `null` on EOF.
pub fn readLine(buf: []u8) ?[]const u8 {
    var len: usize = 0;
    while (len < buf.len) {
        var ch: [1]u8 = undefined;
        const rc = linux.read(STDIN, &ch, 1);
        const e = linux.errno(rc);
        if (e == .INTR) continue;
        if (e != .SUCCESS) return if (len == 0) null else buf[0..len];
        if (rc == 0) return if (len == 0) null else buf[0..len];
        if (ch[0] == '\n') return buf[0..len];
        buf[len] = ch[0];
        len += 1;
    }
    return buf[0..len];
}

/// Format and write to stdout. Allocates a scratch buffer; on OOM the
/// message is dropped.
pub fn printStdout(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(gpa, fmt, args) catch return;
    defer gpa.free(s);
    writeStdout(s);
}

/// Format and write to stderr. Allocates a scratch buffer; on OOM the
/// message is dropped.
pub fn printStderr(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(gpa, fmt, args) catch return;
    defer gpa.free(s);
    writeStderr(s);
}

/// A `runtime.Output` sink that writes program output straight to the
/// process stdout file descriptor.
pub const StdoutSink = struct {
    fn vtWriteln(ctx: *anyopaque, s: []const u8) void {
        _ = ctx;
        writeStdout(s);
        writeStdout("\n");
    }
    fn vtWrite(ctx: *anyopaque, s: []const u8) void {
        _ = ctx;
        writeStdout(s);
    }
    const vtable: Output.VTable = .{ .writeln = vtWriteln, .write = vtWrite };

    pub fn output(self: *StdoutSink) Output {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

test "stdout sink builds an output" {
    var sink = StdoutSink{};
    const out = sink.output();
    try std.testing.expect(out.ctx == @as(*anyopaque, @ptrCast(&sink)));
}
