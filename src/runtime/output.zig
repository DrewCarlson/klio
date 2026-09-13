//! Output sink for the interpreter and stdlib, plus the Kotlin-compatible
//! number and char rendering the `Value` display path leans on. `Output` is a
//! `{ctx, vtable}` pair, so every sink presents one interface to intrinsics.

const std = @import("std");
const float_fmt = @import("float_fmt.zig");

/// `writeln` appends a newline; `write` does not.
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

pub const OutOp = union(enum) {
    write: []const u8,
    writeln: []const u8,
};

/// Owns the recorded strings; `deinit` frees them.
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

/// `lines` and the pending partial own their bytes; `deinit` frees them.
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

pub fn kotlinFloatToString(allocator: std.mem.Allocator, d: f32) ![]u8 {
    return float_fmt.floatToString(allocator, d);
}

pub fn kotlinDoubleToString(allocator: std.mem.Allocator, d: f64) ![]u8 {
    return float_fmt.doubleToString(allocator, d);
}

pub fn charUnitToString(allocator: std.mem.Allocator, unit: u16) ![]u8 {
    return float_fmt.charUnitToString(allocator, unit);
}

/// Pairs a pending high surrogate (`prev`) with a following low surrogate, and
/// answers the new pending high surrogate.
pub fn pushCharUnit(allocator: std.mem.Allocator, out: *std.ArrayList(u8), prev: ?u16, unit: u16) !?u16 {
    if (prev) |hi| {
        if (unit >= 0xDC00 and unit <= 0xDFFF) {
            const c: u32 = 0x10000 + ((@as(u32, hi) - 0xD800) << 10) + (@as(u32, unit) - 0xDC00);
            try appendScalar(allocator, out, c);
            return null;
        }
        // An unpaired high surrogate is a valid Kotlin Char that must
        // round-trip, so keep its WTF-8 form rather than U+FFFD.
        try appendSurrogateUnit(allocator, out, hi);
    }
    if (unit >= 0xD800 and unit <= 0xDBFF) {
        return unit; // hold as pending high surrogate
    }
    if (unit >= 0xDC00 and unit <= 0xDFFF) {
        try appendSurrogateUnit(allocator, out, unit); // lone low surrogate -> WTF-8
        return null;
    }
    try appendScalar(allocator, out, @as(u32, unit));
    return null;
}

fn appendSurrogateUnit(allocator: std.mem.Allocator, out: *std.ArrayList(u8), unit: u16) !void {
    try out.append(allocator, 0xE0 | @as(u8, @intCast(unit >> 12)));
    try out.append(allocator, 0x80 | @as(u8, @intCast((unit >> 6) & 0x3F)));
    try out.append(allocator, 0x80 | @as(u8, @intCast(unit & 0x3F)));
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

pub fn charUnitsToString(allocator: std.mem.Allocator, units: []const u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending: ?u16 = null;
    for (units) |u| {
        pending = try pushCharUnit(allocator, &out, pending, u);
    }
    if (pending) |hi| {
        try appendSurrogateUnit(allocator, &out, hi);
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
    try testing.expectEqual(@as(usize, 0), rec.ops.items.len);
}
