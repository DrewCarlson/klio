//! Low-level CFG construction primitives. The AST → CFG lowering
//! pass (`lower.zig`) drives this builder; tests construct CFGs
//! directly through it. The builder is intentionally dumb: it
//! allocates blocks, registers, and edges; it does not know about
//! the source language.

const std = @import("std");
const span = @import("span");
const ir = @import("ir.zig");

const Allocator = std.mem.Allocator;
const Span = span.Span;
const BasicBlock = ir.BasicBlock;
const BlockId = ir.BlockId;
const Cfg = ir.Cfg;
const Edge = ir.Edge;
const EdgeKind = ir.EdgeKind;
const LabelId = ir.LabelId;
const LoopId = ir.LoopId;
const Node = ir.Node;
const Reg = ir.Reg;
const Terminator = ir.Terminator;

pub const CfgBuilder = struct {
    blocks: std.ArrayList(BasicBlock) = .empty,
    next_reg: u32 = 0,
    next_loop: u32 = 0,
    next_label: u32 = 0,

    pub fn init() CfgBuilder {
        return .{};
    }

    pub fn newBlock(self: *CfgBuilder, allocator: Allocator) Allocator.Error!BlockId {
        const id = BlockId.from(@intCast(self.blocks.items.len));
        try self.blocks.append(allocator, .{ .id = id });
        return id;
    }

    pub fn newReg(self: *CfgBuilder) Reg {
        const r = Reg.from(self.next_reg);
        self.next_reg += 1;
        return r;
    }

    pub fn newLoop(self: *CfgBuilder) LoopId {
        const id = LoopId.from(self.next_loop);
        self.next_loop += 1;
        return id;
    }

    pub fn newLabel(self: *CfgBuilder) LabelId {
        const id = LabelId.from(self.next_label);
        self.next_label += 1;
        return id;
    }

    /// Append a node to the given block. Order-sensitive.
    pub fn push(self: *CfgBuilder, allocator: Allocator, blk: BlockId, node: Node) Allocator.Error!void {
        try self.blocks.items[blk.int()].nodes.append(allocator, node);
    }

    /// Number of nodes already in `blk`. Useful for callers that
    /// want to remember the position a node is about to be pushed
    /// into — the returned value is the insertion index.
    pub fn currentNodeCount(self: *const CfgBuilder, blk: BlockId) ?usize {
        if (blk.int() >= self.blocks.items.len) return null;
        return self.blocks.items[blk.int()].nodes.items.len;
    }

    /// Set the terminator for a block and wire up the edges to the
    /// referenced successors. Replaces any prior terminator on
    /// `blk` and any preds/succs implied by it.
    pub fn setTerminator(self: *CfgBuilder, allocator: Allocator, blk: BlockId, term: Terminator) Allocator.Error!void {
        self.unwireSuccs(blk);
        var succs: std.ArrayList(Edge) = .empty;
        errdefer succs.deinit(allocator);
        switch (term) {
            .Goto => |t| try succs.append(allocator, .{ .block = t, .kind = .Normal }),
            .Branch => |b| {
                try succs.append(allocator, .{ .block = b.then_blk, .kind = .True });
                try succs.append(allocator, .{ .block = b.else_blk, .kind = .False });
            },
            .Switch => |sw| {
                for (sw.arms) |a| {
                    try succs.append(allocator, .{ .block = a.target, .kind = .Normal });
                }
                try succs.append(allocator, .{ .block = sw.default, .kind = .Normal });
            },
            .Throw, .Return, .Unreachable => {},
        }
        self.blocks.items[blk.int()].term = term;
        for (succs.items) |edge| {
            try self.blocks.items[edge.block.int()].preds.append(allocator, .{
                .block = blk,
                .kind = edge.kind,
            });
        }
        self.blocks.items[blk.int()].succs.deinit(allocator);
        self.blocks.items[blk.int()].succs = succs;
    }

    /// Add an additional out-edge of an arbitrary kind from `from` to
    /// `to`. Used for exception edges and finally entry/exit, which
    /// are not implied by the terminator shape.
    pub fn addEdge(self: *CfgBuilder, allocator: Allocator, from: BlockId, to: BlockId, kind: EdgeKind) Allocator.Error!void {
        try self.blocks.items[from.int()].succs.append(allocator, .{ .block = to, .kind = kind });
        try self.blocks.items[to.int()].preds.append(allocator, .{ .block = from, .kind = kind });
    }

    /// Detach any preds that point to `blk`'s prior terminator-implied
    /// successors so we can replace them cleanly.
    fn unwireSuccs(self: *CfgBuilder, blk: BlockId) void {
        const prior = &self.blocks.items[blk.int()].succs;
        for (prior.items) |edge| {
            const dst = &self.blocks.items[edge.block.int()].preds;
            var idx: usize = 0;
            while (idx < dst.items.len) : (idx += 1) {
                const e = dst.items[idx];
                if (e.block == blk and e.kind.eql(edge.kind)) {
                    _ = dst.swapRemove(idx);
                    break;
                }
            }
        }
        prior.clearRetainingCapacity();
    }

    pub fn finish(
        self: *CfgBuilder,
        allocator: Allocator,
        entry: BlockId,
        exits: std.ArrayList(BlockId),
        source: Span,
    ) Cfg {
        _ = allocator;
        return .{
            .blocks = self.blocks,
            .entry = entry,
            .exits = exits,
            .source = source,
            .next_reg = self.next_reg,
        };
    }
};

test "builder allocates blocks and registers" {
    const a = std.testing.allocator;
    var b = CfgBuilder.init();
    defer {
        for (b.blocks.items) |*blk| {
            blk.nodes.deinit(a);
            blk.preds.deinit(a);
            blk.succs.deinit(a);
        }
        b.blocks.deinit(a);
    }
    const b0 = try b.newBlock(a);
    const b1 = try b.newBlock(a);
    try std.testing.expectEqual(@as(u32, 0), b0.int());
    try std.testing.expectEqual(@as(u32, 1), b1.int());
    const r0 = b.newReg();
    const r1 = b.newReg();
    try std.testing.expectEqual(@as(u32, 0), r0.int());
    try std.testing.expectEqual(@as(u32, 1), r1.int());
    try b.setTerminator(a, b0, .{ .Goto = b1 });
    try std.testing.expectEqual(@as(usize, 1), b.blocks.items[b0.int()].succs.items.len);
    try std.testing.expectEqual(@as(usize, 1), b.blocks.items[b1.int()].preds.items.len);
}
