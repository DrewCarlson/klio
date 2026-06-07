//! `finally`-divergence pruning.
//!
//! When a `finally` block always diverges (`return`, `throw`, infinite
//! loop), the `try` it wraps cannot reach its normal continuation —
//! every path out of the `try` is replaced by the `finally`'s
//! divergent terminator. The CFG records this by placing a copy of
//! the finally body on each exit path; the analysis here detects the
//! divergent-finally case and prunes the normal-exit edge from the
//! finally copy to the join, leaving only the divergent terminators
//! in place.

const std = @import("std");
const ir = @import("../ir.zig");
const reachable = @import("reachable.zig");

const Allocator = std.mem.Allocator;
const BlockId = ir.BlockId;
const Cfg = ir.Cfg;
const EdgeKind = ir.EdgeKind;
const Terminator = ir.Terminator;

pub fn pruneDivergentFinally(allocator: Allocator, cfg: *Cfg) Allocator.Error!usize {
    var pruned: usize = 0;
    var reach = try reachable.analyse(allocator, cfg);
    defer reach.deinit(allocator);
    const n = cfg.blocks.items.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const bid = BlockId.from(@intCast(i));
        if (!reach.isReachable(bid)) {
            continue;
        }
        // A FinallyExit edge whose source's terminator is divergent
        // is unreachable and should be detached from the join.
        var to_prune: std.ArrayList(usize) = .empty;
        defer to_prune.deinit(allocator);
        {
            const blk = cfg.block(bid);
            for (blk.succs.items, 0..) |e, idx| {
                if (!isFinallyExit(e.kind)) {
                    continue;
                }
                if (isDivergent(blk.term)) {
                    try to_prune.append(allocator, idx);
                }
            }
        }
        var k: usize = to_prune.items.len;
        while (k > 0) {
            k -= 1;
            const idx = to_prune.items[k];
            const edge = cfg.blockMut(bid).succs.orderedRemove(idx);
            const dst_preds = &cfg.blockMut(edge.block).preds;
            if (positionPred(dst_preds.items, bid, edge.kind)) |p_idx| {
                _ = dst_preds.swapRemove(p_idx);
            }
            pruned += 1;
        }
    }
    return pruned;
}

fn isFinallyExit(kind: EdgeKind) bool {
    return switch (kind) {
        .FinallyExit => true,
        else => false,
    };
}

fn isDivergent(term: Terminator) bool {
    return switch (term) {
        .Throw, .Return, .Unreachable => true,
        else => false,
    };
}

fn positionPred(preds: []const ir.Edge, bid: BlockId, kind: EdgeKind) ?usize {
    for (preds, 0..) |p, idx| {
        if (p.block == bid and p.kind.eql(kind)) {
            return idx;
        }
    }
    return null;
}
