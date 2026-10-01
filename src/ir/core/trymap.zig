//! The try regions a frame stands in, from where it stands. Entering a block that opens a
//! region pushes its try frame, a catch-only try's join pops it, a finally's entry disarms
//! it, and a Goto out of a finally or its done block, or out of an inline return's bypassed
//! regions, pops it; a throw, a return or an unwind routed to a handler pops the frames above
//! the region's. Where every path into a block leaves the same frames, the frames are known
//! when the function's code is built, and a frame's try stack need not be kept as it runs:
//! only a route through a handler reads it, from its block's context.

const std = @import("std");
const core_ids = @import("ids.zig");
const core_func = @import("func.zig");
const core_inst = @import("inst.zig");

const Allocator = std.mem.Allocator;
const Block = core_func.Block;
const BlockId = core_ids.BlockId;

/// Per block, the try frames in effect from its entry on, innermost last: each the body
/// block that pushed it.
pub const TryContexts = struct {
    /// Per block, its frames' place in `bodies`.
    start: []u32,
    len: []u32,
    bodies: []u32,

    /// No block in a try region.
    pub const none: TryContexts = .{ .start = &.{}, .len = &.{}, .bodies = &.{} };

    pub fn deinit(self: *TryContexts, a: Allocator) void {
        a.free(self.start);
        a.free(self.len);
        a.free(self.bodies);
    }

    /// The frames in effect in block `b`, innermost last.
    pub fn of(self: *const TryContexts, b: u32) []const u32 {
        if (b >= self.len.len) return &.{};
        return self.bodies[self.start[b]..][0..self.len[b]];
    }
};

const Stack = std.ArrayList(u32);

/// The try contexts of `blocks`, or null when two paths into a block leave it different
/// frames (its try stack is then kept as it runs).
pub fn tryContexts(a: Allocator, blocks: []const Block, entry: u32) Allocator.Error!?TryContexts {
    const n = blocks.len;
    var ctx = try a.alloc(?[]u32, n);
    defer {
        for (ctx) |c| if (c) |x| a.free(x);
        a.free(ctx);
    }
    @memset(ctx, null);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(a);
    var s: Stack = .empty;
    defer s.deinit(a);
    if (entry >= n) return null;
    // The function's entry block, entered with no frames.
    enter(blocks, entry, &s, a) catch |e| return e;
    if (!try set(a, &ctx, &work, entry, s.items)) return null;
    while (work.pop()) |b| {
        const blk = &blocks[b];
        const in = ctx[b].?;
        // A throw, a return or an unwind from the region this block opens goes to its
        // handlers with the frames beneath the region's.
        const h = blk.h();
        if (h.catches.len != 0 or h.finally != null) {
            const below = in[0 .. in.len - 1];
            for (h.catches) |ch| {
                s.clearRetainingCapacity();
                try s.appendSlice(a, below);
                try enter(blocks, ch.handler.int(), &s, a);
                if (!try set(a, &ctx, &work, ch.handler.int(), s.items)) return null;
            }
            if (h.finally) |fin| {
                s.clearRetainingCapacity();
                try s.appendSlice(a, below);
                try enter(blocks, fin.int(), &s, a);
                if (!try set(a, &ctx, &work, fin.int(), s.items)) return null;
            }
        }
        switch (blk.terminator) {
            .Goto => |t| {
                s.clearRetainingCapacity();
                try s.appendSlice(a, in);
                leave(blocks, b, &s);
                try enter(blocks, t.int(), &s, a);
                if (!try set(a, &ctx, &work, t.int(), s.items)) return null;
            },
            .Branch => |br| for ([_]BlockId{ br.t, br.f }) |t| {
                s.clearRetainingCapacity();
                try s.appendSlice(a, in);
                try enter(blocks, t.int(), &s, a);
                if (!try set(a, &ctx, &work, t.int(), s.items)) return null;
            },
            else => {},
        }
    }
    var total: usize = 0;
    for (ctx) |c| if (c) |x| {
        total += x.len;
    };
    var out: TryContexts = .{
        .start = try a.alloc(u32, n),
        .len = try a.alloc(u32, n),
        .bodies = try a.alloc(u32, total),
    };
    var at: u32 = 0;
    for (ctx, 0..) |c, b| {
        const x = c orelse &.{};
        out.start[b] = at;
        out.len[b] = @intCast(x.len);
        @memcpy(out.bodies[at..][0..x.len], x);
        at += @intCast(x.len);
    }
    return out;
}

/// Records `frames` as block `t`'s context, queueing it the first time; false when it
/// had another.
fn set(a: Allocator, ctx: *[]?[]u32, work: *std.ArrayList(u32), t: u32, frames: []const u32) Allocator.Error!bool {
    if (t >= ctx.len) return false;
    if (ctx.*[t]) |have| return std.mem.eql(u32, have, frames);
    ctx.*[t] = try a.dupe(u32, frames);
    try work.append(a, t);
    return true;
}

/// What entering block `t` does to the frames (`exec.enterTryBlock`).
fn enter(blocks: []const Block, t: u32, s: *Stack, a: Allocator) Allocator.Error!void {
    if (t >= blocks.len) return;
    const h = blocks[t].h();
    if (h.catch_done_for) |body| removeBody(s, body.int());
    removeFinallyEntry(blocks, s, t);
    if (h.catches.len != 0 or h.finally != null) try s.append(a, t);
}

/// What a Goto out of block `b` does to the frames with no finally flow pending
/// (`exec.leaveTryBlock`).
fn leave(blocks: []const Block, b: u32, s: *Stack) void {
    const h = blocks[b].h();
    if (h.finally_done_for) |body| removeBody(s, body.int()) else removeFinallyEntry(blocks, s, b);
    for (h.pop_on_exit) |body| removeBody(s, body.int());
}

fn removeBody(s: *Stack, body: u32) void {
    var i = s.items.len;
    while (i > 0) {
        i -= 1;
        if (s.items[i] == body) {
            _ = s.orderedRemove(i);
            return;
        }
    }
}

fn removeFinallyEntry(blocks: []const Block, s: *Stack, b: u32) void {
    var i = s.items.len;
    while (i > 0) {
        i -= 1;
        if (blocks[s.items[i]].h().finally) |f| if (f.int() == b) {
            _ = s.orderedRemove(i);
            return;
        };
    }
}

const testing = std.testing;

test "a try body's blocks stand in its frame, and its finally and catch beneath it" {
    const r = core_ids.Reg.from;
    var catches = [_]core_inst.CatchHandler{.{ .class = core_ids.ClassId.from(0), .handler = BlockId.from(4), .exception_reg = r(1) }};
    var body_h: core_func.BlockHandlers = .{ .catches = &catches, .finally = BlockId.from(2), .finally_done = BlockId.from(3) };
    var done_h: core_func.BlockHandlers = .{ .finally_done_for = BlockId.from(1) };
    // b0 enters the try at b1, whose body goes on in b5 and then to the finally b2; b3 is
    // the finally's done block and b4 the catch, which goes to the finally too.
    var blocks = [_]Block{
        .{ .id = BlockId.from(0), .insts = &.{}, .terminator = .{ .Goto = BlockId.from(1) } },
        .{ .id = BlockId.from(1), .insts = &.{}, .terminator = .{ .Goto = BlockId.from(5) }, .handlers = &body_h },
        .{ .id = BlockId.from(2), .insts = &.{}, .terminator = .{ .Goto = BlockId.from(3) } },
        .{ .id = BlockId.from(3), .insts = &.{}, .terminator = .{ .Return = null }, .handlers = &done_h },
        .{ .id = BlockId.from(4), .insts = &.{}, .terminator = .{ .Goto = BlockId.from(2) } },
        .{ .id = BlockId.from(5), .insts = &.{}, .terminator = .{ .Goto = BlockId.from(2) } },
    };
    var tc = (try tryContexts(testing.allocator, &blocks, 0)).?;
    defer tc.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{}, tc.of(0));
    try testing.expectEqualSlices(u32, &.{1}, tc.of(1));
    try testing.expectEqualSlices(u32, &.{1}, tc.of(5));
    try testing.expectEqualSlices(u32, &.{}, tc.of(2));
    try testing.expectEqualSlices(u32, &.{}, tc.of(3));
    try testing.expectEqualSlices(u32, &.{}, tc.of(4));
}

test "a block two paths reach with different frames has no context" {
    const r = core_ids.Reg.from;
    var catches = [_]core_inst.CatchHandler{.{ .class = core_ids.ClassId.from(0), .handler = BlockId.from(3), .exception_reg = r(1) }};
    var body_h: core_func.BlockHandlers = .{ .catches = &catches };
    // b0 branches into the try at b1 and around it to b2, which b1 also goes on to without
    // leaving its region.
    var blocks = [_]Block{
        .{ .id = BlockId.from(0), .insts = &.{}, .terminator = .{ .Branch = .{ .cond = r(0), .t = BlockId.from(1), .f = BlockId.from(2) } } },
        .{ .id = BlockId.from(1), .insts = &.{}, .terminator = .{ .Goto = BlockId.from(2) }, .handlers = &body_h },
        .{ .id = BlockId.from(2), .insts = &.{}, .terminator = .{ .Return = null } },
        .{ .id = BlockId.from(3), .insts = &.{}, .terminator = .{ .Return = null } },
    };
    try testing.expectEqual(@as(?TryContexts, null), try tryContexts(testing.allocator, &blocks, 0));
    // A catch-only try's join pops the body's frame, and both paths agree.
    var join_h: core_func.BlockHandlers = .{ .catch_done_for = BlockId.from(1) };
    blocks[2].handlers = &join_h;
    var tc = (try tryContexts(testing.allocator, &blocks, 0)).?;
    defer tc.deinit(testing.allocator);
    try testing.expectEqualSlices(u32, &.{}, tc.of(2));
    try testing.expectEqualSlices(u32, &.{1}, tc.of(1));
}
