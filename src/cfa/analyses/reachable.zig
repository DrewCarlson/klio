//! Reachability analysis.
//!
//! A block is reachable iff there is a path from the CFG's entry to
//! it through edges that the dataflow regards as live. An edge is
//! dead when its source block ends in a divergent terminator
//! (`Throw`, `Return`, `Unreachable`) or when an `Unreachable`
//! node is encountered before the terminator (typical for code
//! after a `Nothing`-typed call).
//!
//! The `WithTypes` variant consults a span-keyed type map so an
//! `Eval` of a `Nothing`-returning call (`error("…")`, `TODO()`)
//! prunes its block's successors the same way an explicit
//! `Throw` would. The typechecker passes its `types` map in.

const std = @import("std");
const ir = @import("../ir.zig");
const lower = @import("../lower.zig");

const Allocator = std.mem.Allocator;
const BlockId = ir.BlockId;
const Cfg = ir.Cfg;
const Node = ir.Node;
const Terminator = ir.Terminator;
const Type = ir.Type;
const SpanKey = lower.SpanKey;

const SpanKeyContext = struct {
    pub fn hash(_: SpanKeyContext, k: SpanKey) u64 {
        return (@as(u64, k.start) << 32) | @as(u64, k.end);
    }
    pub fn eql(_: SpanKeyContext, a: SpanKey, b: SpanKey) bool {
        return a.start == b.start and a.end == b.end;
    }
};

/// Span-keyed type map mirroring Rust's `HashMap<(u32, u32), Type>`.
/// The typechecker collects its span→Type results into this shape.
pub const TypeMap = std.HashMap(SpanKey, Type, SpanKeyContext, std.hash_map.default_max_load_percentage);

pub const Reachability = struct {
    reachable: []bool,

    pub fn isReachable(self: Reachability, b: BlockId) bool {
        if (b.int() >= self.reachable.len) return false;
        return self.reachable[b.int()];
    }

    pub fn unreachableBlocks(self: Reachability, allocator: Allocator) Allocator.Error![]BlockId {
        var out: std.ArrayList(BlockId) = .empty;
        errdefer out.deinit(allocator);
        for (self.reachable, 0..) |r, i| {
            if (!r) try out.append(allocator, BlockId.from(@intCast(i)));
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *Reachability, allocator: Allocator) void {
        allocator.free(self.reachable);
    }
};

fn isNothing(t: Type) bool {
    return @as(std.meta.Tag(Type), t) == .Nothing;
}

pub fn analyse(allocator: Allocator, cfg: *const Cfg) Allocator.Error!Reachability {
    return analyseWithTypes(allocator, cfg, null);
}

/// Same as `analyse` but consults `type_map` (typechecker-supplied
/// span→Type results) so an `Eval` of a `Nothing`-typed expression
/// is treated like an in-block `Unreachable` marker: control does
/// not propagate past it.
pub fn analyseWithTypes(
    allocator: Allocator,
    cfg: *const Cfg,
    type_map: ?*const TypeMap,
) Allocator.Error!Reachability {
    const reachable = try allocator.alloc(bool, cfg.blocks.items.len);
    errdefer allocator.free(reachable);
    @memset(reachable, false);

    var stack: std.ArrayList(BlockId) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, cfg.entry);

    var visited = std.AutoHashMap(BlockId, void).init(allocator);
    defer visited.deinit();

    while (stack.pop()) |b| {
        const gop = try visited.getOrPut(b);
        if (gop.found_existing) continue;
        reachable[b.int()] = true;
        const block = cfg.block(b);
        var block_diverges = false;
        for (block.nodes.items) |n| {
            const diverges = switch (n) {
                .Unreachable => true,
                .Eval => |e| blk: {
                    if (type_map) |tm| {
                        const key = SpanKey{ .start = e.expr.span.start, .end = e.expr.span.end };
                        if (tm.get(key)) |t| break :blk isNothing(t);
                        break :blk false;
                    }
                    break :blk isNothing(e.expr.ty);
                },
                else => false,
            };
            if (diverges) {
                block_diverges = true;
                break;
            }
        }
        if (block_diverges) continue;
        switch (block.term) {
            .Return, .Unreachable => {},
            // A throw's recorded successors are exactly the exceptional
            // edges the lowering routed to enclosing catch / finally
            // blocks; control genuinely flows there. Without a handler
            // the successor list is empty.
            else => {
                for (block.succs.items) |e| {
                    try stack.append(allocator, e.block);
                }
            },
        }
    }
    return .{ .reachable = reachable };
}

const testing = std.testing;
const builder = @import("../builder.zig");
const span = @import("span");

fn deinitBuilder(b: *builder.CfgBuilder, allocator: Allocator) void {
    for (b.blocks.items) |*blk| {
        blk.nodes.deinit(allocator);
        blk.preds.deinit(allocator);
        blk.succs.deinit(allocator);
    }
    b.blocks.deinit(allocator);
}

test "reachability marks main path reachable" {
    const a = testing.allocator;
    var b = builder.CfgBuilder.init();
    defer deinitBuilder(&b, a);
    const entry = try b.newBlock(a);
    try b.setTerminator(a, entry, .{ .Return = null });
    var cfg: Cfg = .{
        .blocks = b.blocks,
        .entry = entry,
        .exits = .empty,
        .source = span.Span.init(span.FileId.from(0), 0, 0),
        .next_reg = b.next_reg,
    };
    b.blocks = cfg.blocks;

    var r = try analyse(a, &cfg);
    defer r.deinit(a);
    try testing.expect(r.isReachable(cfg.entry));
}

test "reachability after return is dead" {
    const a = testing.allocator;
    var b = builder.CfgBuilder.init();
    defer deinitBuilder(&b, a);
    const entry = try b.newBlock(a);
    const dead = try b.newBlock(a);
    // entry returns, yet keeps an out-edge to `dead`; the divergent
    // terminator must stop the walk from following it.
    try b.setTerminator(a, entry, .{ .Return = null });
    try b.addEdge(a, entry, dead, .Normal);
    try b.setTerminator(a, dead, .{ .Return = null });
    var cfg: Cfg = .{
        .blocks = b.blocks,
        .entry = entry,
        .exits = .empty,
        .source = span.Span.init(span.FileId.from(0), 0, 0),
        .next_reg = b.next_reg,
    };
    b.blocks = cfg.blocks;

    var r = try analyse(a, &cfg);
    defer r.deinit(a);
    try testing.expect(r.isReachable(entry));
    try testing.expect(!r.isReachable(dead));

    const blocked = try r.unreachableBlocks(a);
    defer a.free(blocked);
    try testing.expectEqual(@as(usize, 1), blocked.len);
    try testing.expectEqual(dead, blocked[0]);
}

test "unreachable node prunes successors" {
    const a = testing.allocator;
    var b = builder.CfgBuilder.init();
    defer deinitBuilder(&b, a);
    const entry = try b.newBlock(a);
    const after = try b.newBlock(a);
    try b.push(a, entry, .Unreachable);
    try b.setTerminator(a, entry, .{ .Goto = after });
    try b.setTerminator(a, after, .{ .Return = null });
    var cfg: Cfg = .{
        .blocks = b.blocks,
        .entry = entry,
        .exits = .empty,
        .source = span.Span.init(span.FileId.from(0), 0, 0),
        .next_reg = b.next_reg,
    };
    b.blocks = cfg.blocks;

    var r = try analyse(a, &cfg);
    defer r.deinit(a);
    try testing.expect(r.isReachable(entry));
    try testing.expect(!r.isReachable(after));
}

test "with-types prunes after a Nothing-typed eval" {
    const a = testing.allocator;
    var b = builder.CfgBuilder.init();
    defer deinitBuilder(&b, a);
    const entry = try b.newBlock(a);
    const after = try b.newBlock(a);
    const reg = b.newReg();
    const sp = span.Span.init(span.FileId.from(0), 10, 20);
    // The eval's intrinsic `ty` is Unit; only the type map says Nothing.
    try b.push(a, entry, .{ .Eval = .{ .reg = reg, .expr = .{ .span = sp, .ty = .Unit } } });
    try b.setTerminator(a, entry, .{ .Goto = after });
    try b.setTerminator(a, after, .{ .Return = null });
    var cfg: Cfg = .{
        .blocks = b.blocks,
        .entry = entry,
        .exits = .empty,
        .source = span.Span.init(span.FileId.from(0), 0, 0),
        .next_reg = b.next_reg,
    };
    b.blocks = cfg.blocks;

    // Without the type map, the eval's own type is Unit, so `after` is reachable.
    var plain = try analyse(a, &cfg);
    defer plain.deinit(a);
    try testing.expect(plain.isReachable(after));

    var tm = TypeMap.init(a);
    defer tm.deinit();
    try tm.put(.{ .start = sp.start, .end = sp.end }, .Nothing);

    var typed = try analyseWithTypes(a, &cfg, &tm);
    defer typed.deinit(a);
    try testing.expect(typed.isReachable(entry));
    try testing.expect(!typed.isReachable(after));
}
