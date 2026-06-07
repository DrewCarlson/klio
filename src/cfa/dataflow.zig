//! Generic monotone dataflow framework plus the killDataFlow
//! inference pass.
//!
//! The framework exposes a lattice contract, two combinators
//! (`Flat(T)` for finite-height pointwise facts; `MapLattice(K, L)`
//! for per-key facts), and a `solveForward` worklist runner that
//! iterates blocks in reverse-postorder until a fixpoint is reached.
//! Analyses provide a forward-transfer value whose methods mutate a
//! per-node and per-edge state.
//!
//! `killDataFlow` is built on the framework: it counts assignments
//! to each `Place` along every program point; after fixpoint, any
//! backedge whose count differs between the pred and the loop entry
//! gets a `KillDataFlow(place)` node injected at the loop head so
//! smart-cast analyses know to drop that place's narrowings.

const std = @import("std");
const ir = @import("ir.zig");

const Allocator = std.mem.Allocator;
const BasicBlock = ir.BasicBlock;
const BlockId = ir.BlockId;
const Cfg = ir.Cfg;
const EdgeKind = ir.EdgeKind;
const Node = ir.Node;
const Place = ir.Place;
const Terminator = ir.Terminator;

// A monotone lattice value must expose `bottom`, `join`, `eql`, and
// `clone`, mirroring Rust's `Lattice: Clone`. `join` returns `true`
// when the receiver was changed by the join — the worklist relies
// on this to know when to re-enqueue successors. `clone` takes an
// allocator (a no-op for trivially-copyable lattices).
//
// Required member shape (duck-typed at comptime):
//   pub fn bottom(allocator) L
//   pub fn join(self: *L, allocator, other: *const L) Allocator.Error!bool
//   pub fn eql(self: L, other: L) bool
//   pub fn clone(self: L, allocator) Allocator.Error!L
//   pub fn deinit(self: *L, allocator) void

/// `Flat(T)` is the three-point lattice: bottom (unknown), a single
/// concrete value, or top (conflicting). `T` must be trivially
/// comparable with `==`.
pub fn Flat(comptime T: type) type {
    return union(enum) {
        Bottom,
        Value: T,
        Top,

        const Self = @This();

        pub fn bottom(allocator: Allocator) Self {
            _ = allocator;
            return .Bottom;
        }

        pub fn join(self: *Self, allocator: Allocator, other: *const Self) Allocator.Error!bool {
            _ = allocator;
            const new: Self = switch (self.*) {
                .Top => return false,
                .Bottom => switch (other.*) {
                    .Bottom => return false,
                    .Value => |v| .{ .Value = v },
                    .Top => .Top,
                },
                .Value => |a| switch (other.*) {
                    .Bottom => return false,
                    .Top => .Top,
                    .Value => |b| if (a == b) return false else .Top,
                },
            };
            self.* = new;
            return true;
        }

        pub fn eql(self: Self, other: Self) bool {
            if (@as(std.meta.Tag(Self), self) != @as(std.meta.Tag(Self), other)) return false;
            return switch (self) {
                .Bottom, .Top => true,
                .Value => |v| v == other.Value,
            };
        }

        pub fn clone(self: Self, allocator: Allocator) Allocator.Error!Self {
            _ = allocator;
            return self;
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            _ = self;
            _ = allocator;
        }
    };
}

/// Comparator used to keep a `MapLattice` ordered like Rust's
/// `BTreeMap`. `K` must expose `pub fn order(self: K, other: K)
/// std.math.Order` (matching `Place.order`) for the ordered form, or
/// be an integer / enum for `std.math.order`.
fn keyOrder(comptime K: type, a: K, b: K) std.math.Order {
    if (@hasDecl(K, "order")) return a.order(b);
    return std.math.order(@intFromEnum(a), @intFromEnum(b));
}

fn keyClone(comptime K: type, allocator: Allocator, k: K) Allocator.Error!K {
    if (@hasDecl(K, "clone")) return k.clone(allocator);
    return k;
}

/// Map lattice. Pointwise join; missing keys are treated as
/// `L.bottom()`. Keys are kept in ascending `keyOrder` to mirror
/// `BTreeMap` iteration order.
pub fn MapLattice(comptime K: type, comptime L: type) type {
    return struct {
        pub const Entry = struct { key: K, value: L };

        entries: std.ArrayList(Entry) = .empty,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        pub fn bottom(allocator: Allocator) Self {
            _ = allocator;
            return .{};
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (self.entries.items) |*e| {
                e.value.deinit(allocator);
                if (@hasDecl(K, "deinit")) e.key.deinit(allocator);
            }
            self.entries.deinit(allocator);
        }

        fn find(self: *const Self, k: K) ?usize {
            for (self.entries.items, 0..) |e, i| {
                if (keyOrder(K, e.key, k) == .eq) return i;
            }
            return null;
        }

        /// Returns a clone of the fact for `k`, or `L.bottom()` if the
        /// key is absent. Caller owns the returned value.
        pub fn get(self: *const Self, allocator: Allocator, k: K) Allocator.Error!L {
            if (self.find(k)) |i| return self.entries.items[i].value.clone(allocator);
            return L.bottom(allocator);
        }

        /// Insert/overwrite, keeping the entry list ordered. Takes
        /// ownership of `k` and `v`.
        pub fn put(self: *Self, allocator: Allocator, k: K, v: L) Allocator.Error!void {
            if (self.find(k)) |i| {
                self.entries.items[i].value.deinit(allocator);
                if (@hasDecl(K, "deinit")) {
                    var old = self.entries.items[i].key;
                    old.deinit(allocator);
                }
                self.entries.items[i].key = k;
                self.entries.items[i].value = v;
                return;
            }
            var idx: usize = 0;
            while (idx < self.entries.items.len and keyOrder(K, self.entries.items[idx].key, k) == .lt) {
                idx += 1;
            }
            try self.entries.insert(allocator, idx, .{ .key = k, .value = v });
        }

        pub fn join(self: *Self, allocator: Allocator, other: *const Self) Allocator.Error!bool {
            var changed = false;
            for (other.entries.items) |oe| {
                if (self.find(oe.key)) |i| {
                    var v = try oe.value.clone(allocator);
                    defer v.deinit(allocator);
                    if (try self.entries.items[i].value.join(allocator, &v)) changed = true;
                } else {
                    const k = try keyClone(K, allocator, oe.key);
                    const v = try oe.value.clone(allocator);
                    try self.put(allocator, k, v);
                    changed = true;
                }
            }
            return changed;
        }

        pub fn eql(self: Self, other: Self) bool {
            if (self.entries.items.len != other.entries.items.len) return false;
            for (self.entries.items) |e| {
                const oi = other.find(e.key) orelse return false;
                if (!e.value.eql(other.entries.items[oi].value)) return false;
            }
            return true;
        }

        pub fn clone(self: Self, allocator: Allocator) Allocator.Error!Self {
            var out = Self.init();
            errdefer out.deinit(allocator);
            for (self.entries.items) |e| {
                const k = try keyClone(K, allocator, e.key);
                const v = try e.value.clone(allocator);
                try out.entries.append(allocator, .{ .key = k, .value = v });
            }
            return out;
        }
    };
}

/// Per-block in-state for a forward dataflow problem.
pub fn BlockStates(comptime L: type) type {
    return std.ArrayList(L);
}

/// Solve a forward dataflow problem. Returns the per-block in-state
/// at fixpoint. `transfer` is any value exposing `transferNode`,
/// `transferEdge`, and `transferTerminator` (each may be a no-op).
/// `entry_state` is consumed (placed into the entry block's state).
pub fn solveForward(
    comptime L: type,
    comptime T: type,
    allocator: Allocator,
    cfg: *const Cfg,
    entry_state: L,
    transfer: *T,
) Allocator.Error!BlockStates(L) {
    const n = cfg.blocks.items.len;
    var in_states: BlockStates(L) = .empty;
    errdefer {
        for (in_states.items) |*s| s.deinit(allocator);
        in_states.deinit(allocator);
    }
    try in_states.ensureTotalCapacity(allocator, n);
    for (0..n) |_| in_states.appendAssumeCapacity(L.bottom(allocator));
    in_states.items[cfg.entry.int()].deinit(allocator);
    in_states.items[cfg.entry.int()] = entry_state;

    const order = try reversePostorder(allocator, cfg);
    defer allocator.free(order);

    var queue: std.ArrayList(BlockId) = .empty;
    defer queue.deinit(allocator);
    var in_queue = try allocator.alloc(bool, n);
    defer allocator.free(in_queue);
    @memset(in_queue, false);
    for (order) |bid| {
        try queue.append(allocator, bid);
        in_queue[bid.int()] = true;
    }

    var head: usize = 0;
    while (head < queue.items.len) {
        const bid = queue.items[head];
        head += 1;
        in_queue[bid.int()] = false;
        const block = &cfg.blocks.items[bid.int()];
        var state = try in_states.items[bid.int()].clone(allocator);
        defer state.deinit(allocator);
        for (block.nodes.items) |*node| {
            try transferNodeMaybe(T, transfer, node, &state, allocator);
        }
        try transferTerminatorMaybe(T, transfer, &block.term, &state, allocator);
        for (block.succs.items) |edge| {
            var succ_in = try state.clone(allocator);
            defer succ_in.deinit(allocator);
            try transferEdgeMaybe(T, transfer, &edge.kind, &succ_in, allocator);
            const target = edge.block.int();
            if (try in_states.items[target].join(allocator, &succ_in) and !in_queue[target]) {
                try queue.append(allocator, edge.block);
                in_queue[target] = true;
            }
        }
        // Compact the queue periodically to bound memory growth.
        if (head > 64 and head * 2 > queue.items.len) {
            const remaining = queue.items.len - head;
            std.mem.copyForwards(BlockId, queue.items[0..remaining], queue.items[head..]);
            queue.shrinkRetainingCapacity(remaining);
            head = 0;
        }
    }
    return in_states;
}

fn transferNodeMaybe(comptime T: type, t: *T, node: *const Node, state: anytype, allocator: Allocator) Allocator.Error!void {
    if (@hasDecl(T, "transferNode")) return t.transferNode(node, state, allocator);
}

fn transferEdgeMaybe(comptime T: type, t: *T, kind: *const EdgeKind, state: anytype, allocator: Allocator) Allocator.Error!void {
    if (@hasDecl(T, "transferEdge")) return t.transferEdge(kind, state, allocator);
}

fn transferTerminatorMaybe(comptime T: type, t: *T, term: *const Terminator, state: anytype, allocator: Allocator) Allocator.Error!void {
    if (@hasDecl(T, "transferTerminator")) return t.transferTerminator(term, state, allocator);
}

fn reversePostorderDfs(cfg: *const Cfg, bid: BlockId, visited: []bool, order: *std.ArrayList(BlockId), allocator: Allocator) Allocator.Error!void {
    if (visited[bid.int()]) return;
    visited[bid.int()] = true;
    const block: *const BasicBlock = &cfg.blocks.items[bid.int()];
    for (block.succs.items) |e| {
        try reversePostorderDfs(cfg, e.block, visited, order, allocator);
    }
    try order.append(allocator, bid);
}

fn reversePostorder(allocator: Allocator, cfg: *const Cfg) Allocator.Error![]BlockId {
    const n = cfg.blocks.items.len;
    const visited = try allocator.alloc(bool, n);
    defer allocator.free(visited);
    @memset(visited, false);
    var order: std.ArrayList(BlockId) = .empty;
    errdefer order.deinit(allocator);
    try reversePostorderDfs(cfg, cfg.entry, visited, &order, allocator);
    std.mem.reverse(BlockId, order.items);
    return order.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// killDataFlow inference.
//
// We count, at every program point, how many times each `Place` has
// been assigned along the path. A backedge that loops back to a head
// while the per-place count is higher than it was on the head's
// entry means the place was reassigned inside the loop body and any
// smart-cast bound on it must be dropped before the next iteration.
// We then inject `KillDataFlow(place)` at the loop head's first
// non-decl node so the smart-cast analysis sees it.
// ---------------------------------------------------------------------------

/// An ordered set of `Place`, mirroring `BTreeSet<Place>` semantics
/// used by the killDataFlow pass. Entries own their cloned places.
const PlaceSet = struct {
    items: std.ArrayList(Place) = .empty,

    fn find(self: *const PlaceSet, p: Place) ?usize {
        for (self.items.items, 0..) |e, i| {
            switch (e.order(p)) {
                .eq => return i,
                else => {},
            }
        }
        return null;
    }

    /// Insert a clone of `p` if absent. Returns true if inserted.
    fn insert(self: *PlaceSet, allocator: Allocator, p: Place) Allocator.Error!bool {
        if (self.find(p) != null) return false;
        var idx: usize = 0;
        while (idx < self.items.items.len and self.items.items[idx].order(p) == .lt) {
            idx += 1;
        }
        try self.items.insert(allocator, idx, try p.clone(allocator));
        return true;
    }

    fn deinit(self: *PlaceSet, allocator: Allocator) void {
        for (self.items.items) |*p| p.deinit(allocator);
        self.items.deinit(allocator);
    }
};

/// An ordered set of `BlockId`.
const BlockSet = struct {
    items: std.ArrayList(BlockId) = .empty,

    fn insert(self: *BlockSet, allocator: Allocator, b: BlockId) Allocator.Error!bool {
        var idx: usize = 0;
        while (idx < self.items.items.len) : (idx += 1) {
            const cur = self.items.items[idx].int();
            if (cur == b.int()) return false;
            if (cur > b.int()) break;
        }
        try self.items.insert(allocator, idx, b);
        return true;
    }

    fn deinit(self: *BlockSet, allocator: Allocator) void {
        self.items.deinit(allocator);
    }
};

/// Apply killDataFlow inference to `cfg` in place. Inserts a
/// `Node.KillDataFlow` at the head of each loop for every `Place`
/// reassigned anywhere on a path that re-enters the head via a
/// backedge.
pub fn inferKillDataFlow(allocator: Allocator, cfg: *Cfg) Allocator.Error!void {
    var loop_bodies = try collectLoopBodies(allocator, cfg);
    defer {
        for (loop_bodies.items) |*lb| lb.body.deinit(allocator);
        loop_bodies.deinit(allocator);
    }
    for (loop_bodies.items) |*lb| {
        const head = lb.head;
        var killed = PlaceSet{};
        defer killed.deinit(allocator);
        for (lb.body.items.items) |bid| {
            if (bid.int() == head.int()) continue;
            for (cfg.block(bid).nodes.items) |node| {
                if (node == .Assign) {
                    _ = try killed.insert(allocator, node.Assign.lhs);
                }
            }
        }
        if (killed.items.items.len == 0) continue;
        const head_blk = cfg.blockMut(head);
        var insert_at: usize = head_blk.nodes.items.len;
        for (head_blk.nodes.items, 0..) |n, i| {
            if (n != .DeclLocal) {
                insert_at = i;
                break;
            }
        }
        for (killed.items.items) |place| {
            try head_blk.nodes.insert(allocator, insert_at, .{
                .KillDataFlow = .{ .place = try place.clone(allocator) },
            });
        }
    }
}

const LoopBody = struct {
    head: BlockId,
    body: BlockSet,
};

/// For each loop head, the set of blocks that form its body — i.e.
/// blocks reachable from `head` along forward edges that can still
/// reach back to `head` via a `Backedge` node.
fn collectLoopBodies(allocator: Allocator, cfg: *const Cfg) Allocator.Error!std.ArrayList(LoopBody) {
    var out: std.ArrayList(LoopBody) = .empty;
    errdefer {
        for (out.items) |*lb| lb.body.deinit(allocator);
        out.deinit(allocator);
    }
    const heads = try findLoopHeads(allocator, cfg);
    defer allocator.free(heads);
    for (heads) |head| {
        var body = BlockSet{};
        errdefer body.deinit(allocator);
        var stack: std.ArrayList(BlockId) = .empty;
        defer stack.deinit(allocator);
        try stack.append(allocator, head);
        while (stack.items.len > 0) {
            const b = stack.pop().?;
            if (!try body.insert(allocator, b)) continue;
            const blk = cfg.block(b);
            var has_backedge = false;
            for (blk.nodes.items) |n| {
                if (n == .Backedge) {
                    has_backedge = true;
                    break;
                }
            }
            if (has_backedge) continue;
            for (blk.succs.items) |e| {
                switch (e.kind) {
                    .Normal, .True, .False => try stack.append(allocator, e.block),
                    else => {},
                }
            }
        }
        try out.append(allocator, .{ .head = head, .body = body });
    }
    return out;
}

fn findLoopHeads(allocator: Allocator, cfg: *const Cfg) Allocator.Error![]BlockId {
    var heads = BlockSet{};
    defer heads.deinit(allocator);
    for (cfg.blocks.items) |block| {
        for (block.nodes.items) |node| {
            if (node == .Backedge) {
                // The backedge node's containing block goto's the
                // loop head — its single normal successor.
                for (block.succs.items) |edge| {
                    if (edge.kind == .Normal) {
                        _ = try heads.insert(allocator, edge.block);
                    }
                }
            }
        }
    }
    return heads.items.toOwnedSlice(allocator);
}

test "flat lattice joins to top on conflict" {
    const F = Flat(u32);
    var a = F{ .Value = 1 };
    var b = F{ .Value = 1 };
    try std.testing.expect(!try a.join(std.testing.allocator, &b));
    var c = F{ .Value = 2 };
    try std.testing.expect(try a.join(std.testing.allocator, &c));
    try std.testing.expect(a == .Top);
}

test "map lattice pointwise join" {
    const a = std.testing.allocator;
    const M = MapLattice(ir.BlockId, Flat(u32));
    var m = M.init();
    defer m.deinit(a);
    var n = M.init();
    defer n.deinit(a);
    try m.put(a, ir.BlockId.from(0), .{ .Value = 1 });
    try n.put(a, ir.BlockId.from(0), .{ .Value = 1 });
    try n.put(a, ir.BlockId.from(1), .{ .Value = 5 });
    const changed = try m.join(a, &n);
    try std.testing.expect(changed);
    var got = try m.get(a, ir.BlockId.from(1));
    defer got.deinit(a);
    try std.testing.expect(got == .Value and got.Value == 5);
}
