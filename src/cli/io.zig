//! Process stdio helpers. `std.fs.File`'s writer API needs an explicit `Io` and
//! buffer, so output goes through a direct `write(2)` on the process descriptors.

const std = @import("std");

const runtime = @import("runtime");
const Output = runtime.Output;

/// One process-wide `Io`: a per-call `std.Io.Threaded` would start a thread pool per `println`.
var stdio_mutex: runtime.SpinMutex = .{};
var stdio_threaded: ?std.Io.Threaded = null;

fn stdioIo() std.Io {
    if (stdio_threaded == null) stdio_threaded = .init(std.heap.page_allocator, .{});
    return stdio_threaded.?.io();
}

fn writeFile(file: std.Io.File, data: []const u8) void {
    stdio_mutex.lock();
    defer stdio_mutex.unlock();
    file.writeStreamingAll(stdioIo(), data) catch {};
}

pub fn writeStdout(s: []const u8) void {
    writeFile(std.Io.File.stdout(), s);
}

pub fn writeStdoutLine(s: []const u8) void {
    stdio_mutex.lock();
    defer stdio_mutex.unlock();
    const io = stdioIo();
    const f = std.Io.File.stdout();
    f.writeStreamingAll(io, s) catch {};
    f.writeStreamingAll(io, "\n") catch {};
}

pub fn writeStderr(s: []const u8) void {
    writeFile(std.Io.File.stderr(), s);
}

/// Caller owns the returned slice and every element; free with `freeArgs`.
pub fn processArgs(gpa: std.mem.Allocator, args: std.process.Args) ![]const []const u8 {
    var it = try args.iterateAllocator(gpa);
    defer it.deinit();
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |a| gpa.free(a);
        out.deinit(gpa);
    }
    while (it.next()) |arg| {
        try out.append(gpa, try gpa.dupe(u8, arg));
    }
    return out.toOwnedSlice(gpa);
}

pub fn freeArgs(gpa: std.mem.Allocator, args: []const []const u8) void {
    for (args) |a| gpa.free(a);
    gpa.free(args);
}

/// Reads `path`, relative to cwd, into a buffer the caller owns.
pub fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const tio = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(tio, path, gpa, .unlimited) catch
        return error.ReadFailed;
}

/// A line of stdin in `buf`, newline excluded; null on EOF.
pub fn readLine(buf: []u8) ?[]const u8 {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const tio = threaded.io();
    // A single-byte buffer keeps the reader from consuming past the newline,
    // so a REPL's next prompt still sees the user's type-ahead.
    var read_buf: [1]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(tio, &read_buf);
    const r = &stdin_reader.interface;
    var len: usize = 0;
    while (len < buf.len) {
        const ch = r.takeByte() catch return if (len == 0) null else buf[0..len];
        if (ch == '\n') return buf[0..len];
        buf[len] = ch;
        len += 1;
    }
    return buf[0..len];
}

/// Drops the message on OOM.
pub fn printStdout(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(gpa, fmt, args) catch return;
    defer gpa.free(s);
    writeStdout(s);
}

/// Drops the message on OOM.
pub fn printStderr(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(gpa, fmt, args) catch return;
    defer gpa.free(s);
    writeStderr(s);
}

pub const StdoutSink = struct {
    fn vtWriteln(ctx: *anyopaque, s: []const u8) void {
        _ = ctx;
        writeStdoutLine(s);
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
