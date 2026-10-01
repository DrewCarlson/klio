//! The span a stack trace names for a frame, from where it stands: the last `Trace` before
//! its position in its block, else the span the block's entry finds. Each block leaves its
//! last `Trace` to the blocks after it, or the span it found when it has none, so a block
//! every path into leaves the same span finds that one, known when the function's code is
//! built. Only a block whose paths leave two, and which reads one before its first `Trace`,
//! finds it in the frame, left there by the edges into it.

const std = @import("std");
const root_ir = @import("../ir.zig");
const core_ids = @import("ids.zig");
const core_func = @import("func.zig");
const core_inst = @import("inst.zig");

const Allocator = std.mem.Allocator;
const Block = core_func.Block;
const BlockId = core_ids.BlockId;
const Inst = core_inst.Inst;
const Span = root_ir.Span;
const Terminator = core_inst.Terminator;

/// The span a frame standing in a block before its first `Trace` is in.
pub const EntrySpan = union(enum) {
    /// Every path into the block leaves this one; none before the function's first
    /// statement.
    known: ?Span,
    /// Paths into the block leave different ones and the block reads one: the edges into
    /// it leave theirs in the frame (`Frame.cur_span`).
    dyn,
    /// Paths into the block leave different ones and no position in it reads one: it opens
    /// with a `Trace`.
    opens,
};

/// Per block of `blocks`, the span its entry finds. The entry block finds none as the
/// function starts; a catch or a finally, which a throw, a return or an unwind reaches from
/// anywhere in its region, and a finally's done block, which its flows key, find theirs in
/// the frame.
pub fn entrySpans(a: Allocator, blocks: []const Block, entry: u32) Allocator.Error![]EntrySpan {
    const n = blocks.len;
    const State = union(enum) { unset, known: ?Span, amb };
    const st = try a.alloc(State, n);
    defer a.free(st);
    @memset(st, .unset);
    if (entry < n) st[entry] = .{ .known = null };
    for (blocks) |*b| {
        const hs = b.h();
        for (hs.catches) |ch| if (ch.handler.int() < n) {
            st[ch.handler.int()] = .amb;
        };
        for ([_]?BlockId{ hs.finally, hs.finally_done }) |f| if (f) |x| if (x.int() < n) {
            st[x.int()] = .amb;
        };
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (blocks, 0..) |*b, bi| {
            if (st[bi] == .unset) continue;
            const leaves: State = if (lastTrace(b)) |sp| .{ .known = sp } else st[bi];
            for (successors(&b.terminator)) |s| {
                const t = s orelse continue;
                if (t >= n) continue;
                const m: State = switch (st[t]) {
                    .unset => leaves,
                    .amb => .amb,
                    .known => |x| switch (leaves) {
                        .unset => st[t],
                        .amb => .amb,
                        .known => |y| if (std.meta.eql(x, y)) st[t] else .amb,
                    },
                };
                if (!std.meta.eql(m, st[t])) {
                    st[t] = m;
                    changed = true;
                }
            }
        }
    }
    const out = try a.alloc(EntrySpan, n);
    for (out, st, blocks) |*o, s, *b| o.* = switch (s) {
        .known => |sp| .{ .known = sp },
        .unset, .amb => if (b.insts.len != 0 and b.insts[0] == .Trace) .opens else .dyn,
    };
    return out;
}

/// The span block `b` leaves to the blocks after it when it has a `Trace`.
pub fn lastTrace(b: *const Block) ?Span {
    var i = b.insts.len;
    while (i > 0) {
        i -= 1;
        switch (b.insts[i]) {
            .Trace => |t| return t.span,
            else => {},
        }
    }
    return null;
}

/// The span an edge out of block `s` leaves in the frame for its targets `targets`: none
/// (null) when no target finds its span in the frame or the frame holds the one to leave
/// already, else the span `s` leaves, which may be none (`.none`).
pub fn edgeSpan(spans: []const EntrySpan, s: *const Block, si: u32, targets: []const u32) ?EdgeSpan {
    const any_dyn = for (targets) |t| {
        if (t < spans.len and spans[t] == .dyn) break true;
    } else false;
    if (!any_dyn) return null;
    if (lastTrace(s)) |sp| return .{ .span = sp };
    return switch (spans[si]) {
        .known => |sp| if (sp) |x| .{ .span = x } else .none,
        .dyn, .opens => null,
    };
}

pub const EdgeSpan = union(enum) { span: Span, none };

fn successors(t: *const Terminator) [2]?u32 {
    return switch (t.*) {
        .Goto => |x| .{ x.int(), null },
        .Branch => |br| .{ br.t.int(), br.f.int() },
        else => .{ null, null },
    };
}

const testing = std.testing;

test "a block's entry span is the one every path to it leaves, and the frame's where paths leave two" {
    const r = core_ids.Reg.from;
    const file = @import("span").FileId.from(3);
    const s1: Span = .{ .file = file, .start = 10, .end = 20 };
    const s2: Span = .{ .file = file, .start = 30, .end = 40 };
    // b0 (s1) branches to b1 (no statement) and b2 (s2); b1 goes to b3 alone, and both
    // to b4, which reads the span it finds, and to b5 through b3 and b2, which opens with
    // a statement.
    var b0 = [_]Inst{ .{ .Trace = .{ .span = s1 } }, .{ .LoadParam = .{ .dst = r(0), .idx = 0 } } };
    var b2 = [_]Inst{.{ .Trace = .{ .span = s2 } }};
    var b5 = [_]Inst{.{ .Trace = .{ .span = s1 } }};
    var blocks = [_]Block{
        .{ .id = BlockId.from(0), .insts = &b0, .terminator = .{ .Branch = .{ .cond = r(0), .t = BlockId.from(1), .f = BlockId.from(2) } } },
        .{ .id = BlockId.from(1), .insts = &.{}, .terminator = .{ .Goto = BlockId.from(3) } },
        .{ .id = BlockId.from(2), .insts = &b2, .terminator = .{ .Branch = .{ .cond = r(0), .t = BlockId.from(4), .f = BlockId.from(5) } } },
        .{ .id = BlockId.from(3), .insts = &.{}, .terminator = .{ .Branch = .{ .cond = r(0), .t = BlockId.from(4), .f = BlockId.from(5) } } },
        .{ .id = BlockId.from(4), .insts = &.{}, .terminator = .{ .Return = r(0) } },
        .{ .id = BlockId.from(5), .insts = &b5, .terminator = .{ .Return = r(0) } },
    };
    const spans = try entrySpans(testing.allocator, &blocks, 0);
    defer testing.allocator.free(spans);
    try testing.expectEqual(EntrySpan{ .known = null }, spans[0]);
    try testing.expectEqual(EntrySpan{ .known = s1 }, spans[1]);
    try testing.expectEqual(EntrySpan{ .known = s1 }, spans[3]);
    try testing.expectEqual(EntrySpan.dyn, spans[4]);
    try testing.expectEqual(EntrySpan.opens, spans[5]);
    // Only the edges into b4 leave a span: b2's own, and b3's, which it found.
    const t45 = [_]u32{ 4, 5 };
    try testing.expectEqual(EdgeSpan{ .span = s2 }, edgeSpan(spans, &blocks[2], 2, &t45).?);
    try testing.expectEqual(EdgeSpan{ .span = s1 }, edgeSpan(spans, &blocks[3], 3, &t45).?);
    try testing.expectEqual(@as(?EdgeSpan, null), edgeSpan(spans, &blocks[0], 0, &.{ 1, 2 }));
    try testing.expectEqual(@as(?EdgeSpan, null), edgeSpan(spans, &blocks[1], 1, &.{3}));
    // A loop back into the entry block from a statement makes the entry's span differ by
    // path.
    blocks[4].terminator = .{ .Goto = BlockId.from(0) };
    b0[0] = .{ .LoadParam = .{ .dst = r(0), .idx = 0 } };
    b0[1] = .{ .Trace = .{ .span = s1 } };
    const looped = try entrySpans(testing.allocator, &blocks, 0);
    defer testing.allocator.free(looped);
    try testing.expectEqual(EntrySpan.dyn, looped[0]);
    try testing.expectEqual(EntrySpan{ .known = s1 }, looped[1]);
}

test "a catch, a finally and a finally's done block find their span in the frame unless they open with a statement" {
    const r = core_ids.Reg.from;
    const file = @import("span").FileId.from(1);
    const s1: Span = .{ .file = file, .start = 1, .end = 2 };
    var body = [_]Inst{.{ .Trace = .{ .span = s1 } }};
    var catch_insts = [_]Inst{.{ .Trace = .{ .span = s1 } }};
    var catches = [_]core_inst.CatchHandler{.{ .class = core_ids.ClassId.from(0), .handler = BlockId.from(2), .exception_reg = r(1) }};
    var hs: core_func.BlockHandlers = .{ .catches = &catches, .finally = BlockId.from(3), .finally_done = BlockId.from(4) };
    var blocks = [_]Block{
        .{ .id = BlockId.from(0), .insts = &.{}, .terminator = .{ .Goto = BlockId.from(1) } },
        .{ .id = BlockId.from(1), .insts = &body, .terminator = .{ .Goto = BlockId.from(3) }, .handlers = &hs },
        .{ .id = BlockId.from(2), .insts = &catch_insts, .terminator = .{ .Goto = BlockId.from(3) } },
        .{ .id = BlockId.from(3), .insts = &.{}, .terminator = .{ .Goto = BlockId.from(4) } },
        .{ .id = BlockId.from(4), .insts = &.{}, .terminator = .{ .Return = null } },
    };
    const spans = try entrySpans(testing.allocator, &blocks, 0);
    defer testing.allocator.free(spans);
    try testing.expectEqual(EntrySpan{ .known = null }, spans[1]);
    try testing.expectEqual(EntrySpan.opens, spans[2]);
    try testing.expectEqual(EntrySpan.dyn, spans[3]);
    try testing.expectEqual(EntrySpan.dyn, spans[4]);
    // The try body's edge into the finally leaves its statement; the finally's into its
    // done block, having none, the one the frame holds.
    try testing.expectEqual(EdgeSpan{ .span = s1 }, edgeSpan(spans, &blocks[1], 1, &.{3}).?);
    try testing.expectEqual(@as(?EdgeSpan, null), edgeSpan(spans, &blocks[3], 3, &.{4}));
}
