//! Variable initialisation analysis.
//!
//! Forward pass over the CFG with a `Map<Place, Flat<AssignState>>`
//! lattice. `DeclLocal` seeds `Unassigned`; `Assign` sets `Assigned`.
//! A read of a place whose state is not `Assigned` (i.e. `Unassigned`
//! or `Top` — "may be unassigned along some path") is a definite-
//! assignment violation. A future integration step reroutes T0020
//! onto this analysis; for now we expose the per-place facts and a
//! helper that reports violations as a list of spans.

const std = @import("std");
const span = @import("span");
const dataflow = @import("../dataflow.zig");
const ir = @import("../ir.zig");

const Allocator = std.mem.Allocator;
const BlockId = ir.BlockId;
const Cfg = ir.Cfg;
const Node = ir.Node;
const Place = ir.Place;
const Span = span.Span;

pub const AssignState = enum {
    /// Declared but no `Assign` has been seen on this path.
    Unassigned,
    /// Definitely assigned on this path.
    Assigned,

    pub fn bottom() AssignState {
        return .Unassigned;
    }

    pub fn join(self: *AssignState, other: *const AssignState) bool {
        if (self.* == other.*) {
            return false;
        }
        self.* = .Unassigned;
        return true;
    }
};

pub const ViaLattice = dataflow.MapLattice(Place, dataflow.Flat(AssignState));

pub const ViaTransfer = struct {
    pub fn transferNode(self: *ViaTransfer, node: *const Node, state: *ViaLattice, allocator: Allocator) Allocator.Error!void {
        _ = self;
        switch (node.*) {
            .DeclLocal => |d| {
                const p = Place{ .Local = try d.place.clone(allocator) };
                try state.put(allocator, p, .{ .Value = .Unassigned });
            },
            .Assign => |a| {
                const lhs = try a.lhs.clone(allocator);
                try state.put(allocator, lhs, .{ .Value = .Assigned });
            },
            else => {},
        }
    }
};

pub const UnassignedRead = struct {
    place: Place,
    span: Span,
};

/// Per-block in-state at fixpoint.
pub const ViaBlockStates = std.ArrayList(ViaLattice);

pub fn solveVia(allocator: Allocator, cfg: *const Cfg) Allocator.Error!ViaBlockStates {
    // Function parameters land as "assigned" before we enter the
    // function body; the lowering doesn't currently emit `DeclLocal`
    // for them, which means absent ⇒ "no fact" ⇒ not flagged.
    const entry = ViaLattice.init();
    var transfer = ViaTransfer{};
    return dataflow.solveForward(ViaLattice, ViaTransfer, allocator, cfg, entry, &transfer);
}

/// Returns the in-state at every node in `block` by re-running the
/// transfer from the block's start. Useful for a downstream
/// "check at this AST span" query without a full per-node array.
/// Consumes `entry`; the caller owns every returned lattice.
pub fn statesWithinBlock(
    allocator: Allocator,
    cfg: *const Cfg,
    block: BlockId,
    entry: ViaLattice,
) Allocator.Error![]ViaLattice {
    const blk = cfg.block(block);
    var out: std.ArrayList(ViaLattice) = .empty;
    errdefer {
        for (out.items) |*s| s.deinit(allocator);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, blk.nodes.items.len + 1);
    var s = entry;
    out.appendAssumeCapacity(try s.clone(allocator));
    var t = ViaTransfer{};
    for (blk.nodes.items) |*node| {
        try t.transferNode(node, &s, allocator);
        out.appendAssumeCapacity(try s.clone(allocator));
    }
    s.deinit(allocator);
    return out.toOwnedSlice(allocator);
}

/// Read of a place is "live" when the place is named on the right of
/// an `Eval` whose AST shape would touch it. The IR does not record
/// reads directly — those live in `ExprRef.span`. This helper
/// therefore returns the per-block fact stream so the typechecker
/// can query "is this place assigned at this span?" by
/// indexing the state map with the place at the eval's preceding
/// program point. Caller owns the returned value.
pub fn placeStateAtBlockEntry(
    allocator: Allocator,
    states: *const ViaBlockStates,
    block: BlockId,
    place: *const Place,
) Allocator.Error!dataflow.Flat(AssignState) {
    return states.items[block.int()].get(allocator, place.*);
}

/// One ordered entry of `maybeUnassignedPlaces`: a place plus the
/// blocks at whose entry it may be unassigned.
pub const MaybeUnassignedEntry = struct {
    place: Place,
    blocks: std.ArrayList(BlockId),

    pub fn deinit(self: *MaybeUnassignedEntry, allocator: Allocator) void {
        self.place.deinit(allocator);
        self.blocks.deinit(allocator);
    }
};

/// Ordered `Place -> []BlockId` collection, iterated in sorted-key
/// order.
pub const MaybeUnassigned = struct {
    entries: std.ArrayList(MaybeUnassignedEntry) = .empty,

    fn find(self: *const MaybeUnassigned, p: Place) ?usize {
        for (self.entries.items, 0..) |e, i| {
            if (e.place.order(p) == .eq) return i;
        }
        return null;
    }

    pub fn deinit(self: *MaybeUnassigned, allocator: Allocator) void {
        for (self.entries.items) |*e| e.deinit(allocator);
        self.entries.deinit(allocator);
    }
};

/// Convenience aggregator: collect places that join to `Top`
/// (i.e. "assigned on some paths, not all") at any block entry.
/// These are candidates for a "variable might be uninitialised"
/// diagnostic. Caller owns the returned collection.
pub fn maybeUnassignedPlaces(allocator: Allocator, states: *const ViaBlockStates) Allocator.Error!MaybeUnassigned {
    var out = MaybeUnassigned{};
    errdefer out.deinit(allocator);
    for (states.items, 0..) |st, i| {
        for (st.entries.items) |entry| {
            const flagged = switch (entry.value) {
                .Top => true,
                .Value => |v| v == .Unassigned,
                .Bottom => false,
            };
            if (!flagged) continue;
            const block = BlockId.from(@intCast(i));
            if (out.find(entry.key)) |idx| {
                try out.entries.items[idx].blocks.append(allocator, block);
            } else {
                var blocks: std.ArrayList(BlockId) = .empty;
                errdefer blocks.deinit(allocator);
                try blocks.append(allocator, block);
                var idx: usize = 0;
                while (idx < out.entries.items.len and out.entries.items[idx].place.order(entry.key) == .lt) {
                    idx += 1;
                }
                try out.entries.insert(allocator, idx, .{
                    .place = try entry.key.clone(allocator),
                    .blocks = blocks,
                });
            }
        }
    }
    return out;
}

const testing = std.testing;
const BasicBlock = ir.BasicBlock;
const Type = ir.Type;

fn dummySpan() Span {
    return Span.init(span.FileId.from(0), 0, 0);
}

fn deinitStates(allocator: Allocator, states: *ViaBlockStates) void {
    for (states.items) |*s| s.deinit(allocator);
    states.deinit(allocator);
}

test "assign state joins to unassigned on conflict" {
    var a: AssignState = .Assigned;
    var b: AssignState = .Assigned;
    try testing.expect(!a.join(&b));
    var c: AssignState = .Unassigned;
    try testing.expect(a.join(&c));
    try testing.expectEqual(AssignState.Unassigned, a);
}

test "decl seeds unassigned and assign marks assigned" {
    const a = testing.allocator;
    var state = ViaLattice.init();
    defer state.deinit(a);
    var t = ViaTransfer{};

    const decl = Node{ .DeclLocal = .{
        .place = .{ .name = "x" },
        .declared_ty = Type.Int,
        .span = dummySpan(),
    } };
    try t.transferNode(&decl, &state, a);

    const px = Place{ .Local = .{ .name = "x" } };
    var s0 = try state.get(a, px);
    defer s0.deinit(a);
    try testing.expect(s0 == .Value and s0.Value == .Unassigned);

    const assign = Node{ .Assign = .{
        .lhs = .{ .Local = .{ .name = "x" } },
        .rhs = ir.Reg.from(0),
        .span = dummySpan(),
    } };
    try t.transferNode(&assign, &state, a);

    var s1 = try state.get(a, px);
    defer s1.deinit(a);
    try testing.expect(s1 == .Value and s1.Value == .Assigned);
}

test "solve via over a straight-line block" {
    const a = testing.allocator;
    var cfg = Cfg{
        .entry = BlockId.from(0),
        .source = dummySpan(),
        .next_reg = 1,
    };
    defer {
        for (cfg.blocks.items) |*b| {
            // Node names are string literals in this fixture, not
            // allocator-owned, so only the containers are freed.
            b.nodes.deinit(a);
            b.preds.deinit(a);
            b.succs.deinit(a);
        }
        cfg.blocks.deinit(a);
        cfg.exits.deinit(a);
    }

    var block = BasicBlock{ .id = BlockId.from(0), .term = .{ .Return = null } };
    try block.nodes.append(a, .{ .DeclLocal = .{
        .place = .{ .name = "x" },
        .declared_ty = Type.Int,
        .span = dummySpan(),
    } });
    try block.nodes.append(a, .{ .Assign = .{
        .lhs = .{ .Local = .{ .name = "x" } },
        .rhs = ir.Reg.from(0),
        .span = dummySpan(),
    } });
    try cfg.blocks.append(a, block);

    var states = try solveVia(a, &cfg);
    defer deinitStates(a, &states);
    try testing.expectEqual(@as(usize, 1), states.items.len);

    // At block entry the place is not yet seeded.
    const px = Place{ .Local = .{ .name = "x" } };
    var entry_fact = try placeStateAtBlockEntry(a, &states, BlockId.from(0), &px);
    defer entry_fact.deinit(a);
    try testing.expect(entry_fact == .Bottom);
}

test "states within block tracks per-node assignment" {
    const a = testing.allocator;
    var cfg = Cfg{
        .entry = BlockId.from(0),
        .source = dummySpan(),
        .next_reg = 1,
    };
    defer {
        for (cfg.blocks.items) |*b| {
            // Node names are string literals in this fixture, not
            // allocator-owned, so only the containers are freed.
            b.nodes.deinit(a);
            b.preds.deinit(a);
            b.succs.deinit(a);
        }
        cfg.blocks.deinit(a);
        cfg.exits.deinit(a);
    }

    var block = BasicBlock{ .id = BlockId.from(0), .term = .{ .Return = null } };
    try block.nodes.append(a, .{ .DeclLocal = .{
        .place = .{ .name = "x" },
        .declared_ty = Type.Int,
        .span = dummySpan(),
    } });
    try block.nodes.append(a, .{ .Assign = .{
        .lhs = .{ .Local = .{ .name = "x" } },
        .rhs = ir.Reg.from(0),
        .span = dummySpan(),
    } });
    try cfg.blocks.append(a, block);

    const entry = ViaLattice.init();
    const out = try statesWithinBlock(a, &cfg, BlockId.from(0), entry);
    defer {
        for (out) |*s| s.deinit(a);
        a.free(out);
    }
    try testing.expectEqual(@as(usize, 3), out.len);

    const px = Place{ .Local = .{ .name = "x" } };
    var f0 = try out[0].get(a, px);
    defer f0.deinit(a);
    try testing.expect(f0 == .Bottom);
    var f1 = try out[1].get(a, px);
    defer f1.deinit(a);
    try testing.expect(f1 == .Value and f1.Value == .Unassigned);
    var f2 = try out[2].get(a, px);
    defer f2.deinit(a);
    try testing.expect(f2 == .Value and f2.Value == .Assigned);
}

test "maybe unassigned collects flagged places" {
    const a = testing.allocator;
    var states: ViaBlockStates = .empty;
    defer deinitStates(a, &states);

    var st = ViaLattice.init();
    try st.put(a, .{ .Local = .{ .name = try a.dupe(u8, "x") } }, .{ .Value = .Unassigned });
    try st.put(a, .{ .Local = .{ .name = try a.dupe(u8, "y") } }, .{ .Value = .Assigned });
    try st.put(a, .{ .Local = .{ .name = try a.dupe(u8, "z") } }, .Top);
    try states.append(a, st);

    var out = try maybeUnassignedPlaces(a, &states);
    defer out.deinit(a);
    try testing.expectEqual(@as(usize, 2), out.entries.items.len);
    // Ordered by place: "x" before "z".
    try testing.expectEqualStrings("x", out.entries.items[0].place.Local.name);
    try testing.expectEqualStrings("z", out.entries.items[1].place.Local.name);
    try testing.expectEqual(@as(usize, 1), out.entries.items[0].blocks.items.len);
    try testing.expectEqual(BlockId.from(0), out.entries.items[0].blocks.items[0]);
}
