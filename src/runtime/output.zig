//! Output sink for the interpreter and stdlib, plus the Kotlin-compatible
//! number/char rendering re-exports the `Value` Display path leans on.
//!
//! `Output` is the Rust trait; in Zig it is a small vtable struct
//! (`ctx` + `*const VTable`) so the interpreter, the recording sink, the
//! stdout sink, and the test capture sink all present the same `{write,
//! writeln}` interface to intrinsics.

const std = @import("std");
const float_fmt = @import("float_fmt.zig");

/// Output sink interface. A `{ctx, vtable}` pair mirroring Rust's
/// `&mut dyn Output`. `writeln` writes a string followed by a newline;
/// `write` writes with no trailing newline.
pub const Output = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writeln: *const fn (ctx: *anyopaque, s: []const u8) void,
        write: *const fn (ctx: *anyopaque, s: []const u8) void,
    };

    pub fn writeln(self: Output, s: []const u8) void {
        self.vtable.writeln(self.ctx, s);
    }

    pub fn write(self: Output, s: []const u8) void {
        self.vtable.write(self.ctx, s);
    }
};

/// One recorded output call. A `RecordingSink` logs the exact
/// write/writeln sequence so it can later be replayed verbatim.
pub const OutOp = union(enum) {
    write: []const u8,
    writeln: []const u8,
};

/// Sink that records the exact call sequence instead of formatting
/// eagerly. Owns the recorded strings; `deinit` frees them.
pub const RecordingSink = struct {
    ops: std.ArrayList(OutOp) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RecordingSink {
        return .{ .ops = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *RecordingSink) void {
        for (self.ops.items) |op| {
            switch (op) {
                .write => |s| self.allocator.free(s),
                .writeln => |s| self.allocator.free(s),
            }
        }
        self.ops.deinit(self.allocator);
    }

    pub fn replayInto(self: *RecordingSink, out: Output) void {
        for (self.ops.items) |op| {
            switch (op) {
                .write => |s| out.write(s),
                .writeln => |s| out.writeln(s),
            }
        }
        for (self.ops.items) |op| {
            switch (op) {
                .write => |s| self.allocator.free(s),
                .writeln => |s| self.allocator.free(s),
            }
        }
        self.ops.clearRetainingCapacity();
    }

    fn vtWriteln(ctx: *anyopaque, s: []const u8) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        const owned = self.allocator.dupe(u8, s) catch return;
        self.ops.append(self.allocator, .{ .writeln = owned }) catch {};
    }

    fn vtWrite(ctx: *anyopaque, s: []const u8) void {
        const self: *RecordingSink = @ptrCast(@alignCast(ctx));
        const owned = self.allocator.dupe(u8, s) catch return;
        self.ops.append(self.allocator, .{ .write = owned }) catch {};
    }

    const vtable: Output.VTable = .{ .writeln = vtWriteln, .write = vtWrite };

    pub fn output(self: *RecordingSink) Output {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

/// Sink that writes to process stdout.
pub const StdoutOutput = struct {
    fn vtWriteln(ctx: *anyopaque, s: []const u8) void {
        _ = ctx;
        const w = std.fs.File.stdout().deprecatedWriter();
        w.print("{s}\n", .{s}) catch {};
    }
    fn vtWrite(ctx: *anyopaque, s: []const u8) void {
        _ = ctx;
        const w = std.fs.File.stdout().deprecatedWriter();
        w.writeAll(s) catch {};
    }
    const vtable: Output.VTable = .{ .writeln = vtWriteln, .write = vtWrite };

    pub fn output(self: *StdoutOutput) Output {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

/// Spin mutex for `SharedOutput`. Zig 0.16's std has no blocking
/// `Thread.Mutex`, so this is a small spin lock over `std.atomic.Value`
/// with a `spinLoopHint`/`Thread.yield` backoff, mirroring `objcell`.
/// It provides the same exclusive-access discipline a `Mutex` does:
/// one holder at a time, with acquire/release ordering.
const SpinMutex = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *SpinMutex) void {
        while (self.locked.swap(true, .acquire)) {
            std.atomic.spinLoopHint();
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *SpinMutex) void {
        self.locked.store(false, .release);
    }
};

/// A shared output sink shared by every OS thread of one program.
///
/// All threads (the root and every `kotlin.concurrent.thread` child)
/// write through the same atomically reference-counted `RecordingSink`
/// behind a mutex, so a `println` is serialized at write granularity.
/// Single-thread behaviour is byte-identical to writing the inner sink
/// directly: there is exactly one writer, the mutex is uncontended, and
/// `write`/`writeln` forward verbatim in the same program order.
///
/// Mirrors Rust's `SharedOutput(Arc<Mutex<RecordingSink>>)`: `clone`
/// bumps the strong count and shares the same inner sink; `deinit`
/// decrements it and frees the inner sink and control block at zero.
pub const SharedOutput = struct {
    inner: *Inner,

    const Inner = struct {
        refcount: std.atomic.Value(usize),
        mutex: SpinMutex,
        sink: RecordingSink,
        allocator: std.mem.Allocator,
    };

    pub fn new(allocator: std.mem.Allocator) std.mem.Allocator.Error!SharedOutput {
        const inner = try allocator.create(Inner);
        inner.* = .{
            .refcount = std.atomic.Value(usize).init(1),
            .mutex = .{},
            .sink = RecordingSink.init(allocator),
            .allocator = allocator,
        };
        return .{ .inner = inner };
    }

    /// Increment the strong count and return another handle to the same
    /// inner sink (Rust's `Clone for SharedOutput` / `Arc::clone`).
    pub fn clone(self: SharedOutput) SharedOutput {
        _ = self.inner.refcount.fetchAdd(1, .monotonic);
        return .{ .inner = self.inner };
    }

    /// Drop one handle: decrement the strong count and, at zero, free the
    /// inner `RecordingSink` and control block (Rust's `Drop for Arc`).
    pub fn deinit(self: SharedOutput) void {
        if (self.inner.refcount.fetchSub(1, .release) == 1) {
            _ = self.inner.refcount.load(.acquire);
            const allocator = self.inner.allocator;
            self.inner.sink.deinit();
            allocator.destroy(self.inner);
        }
    }

    /// Replay every recorded call, in order, into the caller's real sink,
    /// then clear the recording. Called once after the run and every
    /// spawned thread have completed.
    pub fn replayInto(self: SharedOutput, out: Output) void {
        self.inner.mutex.lock();
        defer self.inner.mutex.unlock();
        self.inner.sink.replayInto(out);
    }

    fn vtWriteln(ctx: *anyopaque, s: []const u8) void {
        const self: *Inner = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        RecordingSink.vtWriteln(&self.sink, s);
    }

    fn vtWrite(ctx: *anyopaque, s: []const u8) void {
        const self: *Inner = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        RecordingSink.vtWrite(&self.sink, s);
    }

    const vtable: Output.VTable = .{ .writeln = vtWriteln, .write = vtWrite };

    pub fn output(self: SharedOutput) Output {
        return .{ .ctx = self.inner, .vtable = &vtable };
    }
};

/// Test helper that captures every line written to it. `lines` and the
/// pending partial own their bytes; `deinit` frees them.
pub const CaptureOutput = struct {
    lines: std.ArrayList([]const u8) = .empty,
    partial: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CaptureOutput {
        return .{ .lines = .empty, .partial = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *CaptureOutput) void {
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
        self.partial.deinit(self.allocator);
    }

    fn vtWriteln(ctx: *anyopaque, s: []const u8) void {
        const self: *CaptureOutput = @ptrCast(@alignCast(ctx));
        if (self.partial.items.len == 0) {
            const owned = self.allocator.dupe(u8, s) catch return;
            self.lines.append(self.allocator, owned) catch {};
        } else {
            self.partial.appendSlice(self.allocator, s) catch {};
            const owned = self.partial.toOwnedSlice(self.allocator) catch return;
            self.lines.append(self.allocator, owned) catch {};
            self.partial = .empty;
        }
    }
    fn vtWrite(ctx: *anyopaque, s: []const u8) void {
        const self: *CaptureOutput = @ptrCast(@alignCast(ctx));
        self.partial.appendSlice(self.allocator, s) catch {};
    }
    const vtable: Output.VTable = .{ .writeln = vtWriteln, .write = vtWrite };

    pub fn output(self: *CaptureOutput) Output {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

/// Kotlin-compatible `Float.toString`.
pub fn kotlinFloatToString(allocator: std.mem.Allocator, d: f32) ![]u8 {
    return float_fmt.floatToString(allocator, d);
}

/// Kotlin-compatible `Double.toString`.
pub fn kotlinDoubleToString(allocator: std.mem.Allocator, d: f64) ![]u8 {
    return float_fmt.doubleToString(allocator, d);
}

/// Render a single Kotlin `Char` (a UTF-16 code unit) as a string.
pub fn charUnitToString(allocator: std.mem.Allocator, unit: u16) ![]u8 {
    return float_fmt.charUnitToString(allocator, unit);
}

/// Append a UTF-16 code unit to `out`, pairing a pending high surrogate
/// (`prev`) with a following low surrogate into the astral scalar.
/// Returns the new pending high surrogate, or `null`.
pub fn pushCharUnit(allocator: std.mem.Allocator, out: *std.ArrayList(u8), prev: ?u16, unit: u16) !?u16 {
    if (prev) |hi| {
        if (unit >= 0xDC00 and unit <= 0xDFFF) {
            const c: u32 = 0x10000 + ((@as(u32, hi) - 0xD800) << 10) + (@as(u32, unit) - 0xDC00);
            try appendScalar(allocator, out, c);
            return null;
        }
        try appendScalar(allocator, out, 0xFFFD); // unpaired high surrogate
    }
    if (unit >= 0xD800 and unit <= 0xDBFF) {
        return unit; // hold as pending high surrogate
    }
    try appendScalar(allocator, out, @as(u32, unit));
    return null;
}

fn appendScalar(allocator: std.mem.Allocator, out: *std.ArrayList(u8), c: u32) !void {
    var buf: [4]u8 = undefined;
    const scalar: u21 = if (c <= 0x10FFFF and !(c >= 0xD800 and c <= 0xDFFF))
        @intCast(c)
    else
        0xFFFD;
    const n = std.unicode.utf8Encode(scalar, &buf) catch blk: {
        break :blk std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
    };
    try out.appendSlice(allocator, buf[0..n]);
}

/// Fold a sequence of UTF-16 code units into a string, reconstructing
/// surrogate pairs (and flushing any trailing unpaired high surrogate).
pub fn charUnitsToString(allocator: std.mem.Allocator, units: []const u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending: ?u16 = null;
    for (units) |u| {
        pending = try pushCharUnit(allocator, &out, pending, u);
    }
    if (pending != null) {
        try appendScalar(allocator, &out, 0xFFFD);
    }
    return out.toOwnedSlice(allocator);
}

const testing = std.testing;

test "capture output records full lines" {
    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    const out = cap.output();
    out.write("a");
    out.write("b");
    out.writeln("c");
    out.writeln("d");
    try testing.expectEqual(@as(usize, 2), cap.lines.items.len);
    try testing.expectEqualStrings("abc", cap.lines.items[0]);
    try testing.expectEqualStrings("d", cap.lines.items[1]);
}

test "char units to string reconstructs a surrogate pair" {
    const units = [_]u16{ 0xD83D, 0xDE00 }; // U+1F600
    const s = try charUnitsToString(testing.allocator, &units);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("\u{1F600}", s);
}

test "recording sink replays the exact call sequence" {
    var rec = RecordingSink.init(testing.allocator);
    defer rec.deinit();
    const sink = rec.output();
    sink.write("a");
    sink.write("b");
    sink.writeln("c");
    sink.writeln("d");

    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    rec.replayInto(cap.output());

    try testing.expectEqual(@as(usize, 2), cap.lines.items.len);
    try testing.expectEqualStrings("abc", cap.lines.items[0]);
    try testing.expectEqualStrings("d", cap.lines.items[1]);
    // Replay drains the recording.
    try testing.expectEqual(@as(usize, 0), rec.ops.items.len);
}

test "shared output records and replays into the real sink" {
    const shared = try SharedOutput.new(testing.allocator);
    defer shared.deinit();
    const sink = shared.output();
    sink.write("x");
    sink.writeln("y");
    sink.writeln("z");

    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    shared.replayInto(cap.output());

    try testing.expectEqual(@as(usize, 2), cap.lines.items.len);
    try testing.expectEqualStrings("xy", cap.lines.items[0]);
    try testing.expectEqualStrings("z", cap.lines.items[1]);
}

test "shared output clone shares one inner sink" {
    const shared = try SharedOutput.new(testing.allocator);
    defer shared.deinit();
    const other = shared.clone();
    defer other.deinit();
    try testing.expectEqual(shared.inner, other.inner);

    shared.output().writeln("a");
    other.output().writeln("b");

    var cap = CaptureOutput.init(testing.allocator);
    defer cap.deinit();
    other.replayInto(cap.output());

    try testing.expectEqual(@as(usize, 2), cap.lines.items.len);
    try testing.expectEqualStrings("a", cap.lines.items[0]);
    try testing.expectEqualStrings("b", cap.lines.items[1]);
}
