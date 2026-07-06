//! Smart-cast and nullability dataflow.
//!
//! The lattice is `Map<Place, SmartCastFact>` where each fact bundles
//! a refined type (intersected as paths join) and a nullability axis
//! (definitely non-null / definitely null / unknown). Transfer
//! functions consume `AssumeIs`, `AssumeNull`, `Assign`, and
//! `KillDataFlow`. The mapping from register-bearing nodes back to
//! `Place` comes from the lowering's `reg_to_place` table.

const std = @import("std");
const types = @import("types");
const dataflow = @import("../dataflow.zig");
const ir = @import("../ir.zig");
const lower = @import("../lower.zig");

const Allocator = std.mem.Allocator;
const Cfg = ir.Cfg;
const Node = ir.Node;
const Place = ir.Place;
const Reg = ir.Reg;
const Type = types.Type;

pub const Nullability = enum {
    Unknown,
    /// `x != null` is known to hold.
    NonNull,
    /// `x == null` is known to hold.
    DefinitelyNull,
};

/// A single fact about a `Place` at a program point.
pub const SmartCastFact = struct {
    /// The type the place has been narrowed to along this path. `null`
    /// means "no narrowing" — fall back to the declared type.
    narrowed: ?Type = null,
    /// User-class narrowing recorded alongside `narrowed` when the
    /// runtime type is a non-builtin class. The typechecker uses this
    /// to recover the class-name path it previously kept in its
    /// `narrowing_class` map.
    narrowed_class: ?[]const u8 = null,
    /// Negative `is` refinements: types the place is known *not* to
    /// be along this path. Used for exhaustive-`when` propagation.
    not_types: std.ArrayList(Type) = .empty,
    /// Nullability axis.
    null: Nullability = .Unknown,

    pub fn unknown() SmartCastFact {
        return .{};
    }

    pub fn bottom(allocator: Allocator) SmartCastFact {
        _ = allocator;
        return SmartCastFact.unknown();
    }

    pub fn deinit(self: *SmartCastFact, allocator: Allocator) void {
        if (self.narrowed) |*t| t.deinit(allocator);
        if (self.narrowed_class) |c| allocator.free(c);
        for (self.not_types.items) |*t| t.deinit(allocator);
        self.not_types.deinit(allocator);
    }

    pub fn reset(self: *SmartCastFact, allocator: Allocator) void {
        self.deinit(allocator);
        self.* = SmartCastFact.unknown();
    }

    /// Compose `self` with an `is T` narrowing. Intersection-on-rhs
    /// when both are non-trivial; otherwise the more specific one
    /// wins by direct replacement (`intersect` normalises). The
    /// optional `class_name` is recorded alongside for user-class
    /// narrowings whose Type is `Unresolved`. Takes ownership of `ty`
    /// and `class_name`.
    pub fn assumeIs(self: *SmartCastFact, allocator: Allocator, ty: Type, class_name: ?[]const u8) Allocator.Error!void {
        if (self.narrowed) |prev| {
            self.narrowed = null;
            self.narrowed = try intersect(allocator, prev, ty);
        } else {
            self.narrowed = ty;
        }
        if (class_name) |cn| {
            if (self.narrowed_class) |old| allocator.free(old);
            self.narrowed_class = cn;
        }
    }

    /// Record a `!is T` refinement. Takes ownership of `ty`; frees it
    /// when an equal entry is already present.
    pub fn assumeNotIs(self: *SmartCastFact, allocator: Allocator, ty: Type) Allocator.Error!void {
        for (self.not_types.items) |t| {
            if (t.eql(ty)) {
                var owned = ty;
                owned.deinit(allocator);
                return;
            }
        }
        try self.not_types.append(allocator, ty);
    }

    pub fn assumeNull(self: *SmartCastFact) void {
        self.null = switch (self.null) {
            .Unknown, .DefinitelyNull => .DefinitelyNull,
            .NonNull => .Unknown,
        };
    }

    pub fn assumeNonNull(self: *SmartCastFact) void {
        self.null = switch (self.null) {
            .Unknown, .NonNull => .NonNull,
            .DefinitelyNull => .Unknown,
        };
    }

    pub fn eql(self: SmartCastFact, other: SmartCastFact) bool {
        if ((self.narrowed == null) != (other.narrowed == null)) return false;
        if (self.narrowed) |a| {
            if (!a.eql(other.narrowed.?)) return false;
        }
        if ((self.narrowed_class == null) != (other.narrowed_class == null)) return false;
        if (self.narrowed_class) |a| {
            if (!std.mem.eql(u8, a, other.narrowed_class.?)) return false;
        }
        if (self.null != other.null) return false;
        if (self.not_types.items.len != other.not_types.items.len) return false;
        for (self.not_types.items, other.not_types.items) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }

    pub fn clone(self: SmartCastFact, allocator: Allocator) Allocator.Error!SmartCastFact {
        var not_types: std.ArrayList(Type) = .empty;
        errdefer {
            for (not_types.items) |*t| t.deinit(allocator);
            not_types.deinit(allocator);
        }
        try not_types.ensureTotalCapacity(allocator, self.not_types.items.len);
        for (self.not_types.items) |t| not_types.appendAssumeCapacity(try t.clone(allocator));
        return .{
            .narrowed = if (self.narrowed) |t| try t.clone(allocator) else null,
            .narrowed_class = if (self.narrowed_class) |c| try allocator.dupe(u8, c) else null,
            .not_types = not_types,
            .null = self.null,
        };
    }

    /// Join two facts at a control-flow merge. The narrowed type is
    /// the union of both sides (collapsing to `Any` when they
    /// disagree, dropping entirely when either side has no narrowing);
    /// class narrowing survives only on exact agreement; negative
    /// refinements intersect; nullability collapses to `Unknown` on
    /// disagreement.
    pub fn join(self: *SmartCastFact, allocator: Allocator, other: *const SmartCastFact) Allocator.Error!bool {
        var changed = false;

        // Narrowed type: union when both present, else None.
        var new_narrow: ?Type = null;
        if (self.narrowed) |a| {
            if (other.narrowed) |b| {
                new_narrow = try unionOf(allocator, a, b);
            }
        }
        const narrow_eq = blk: {
            if ((new_narrow == null) != (self.narrowed == null)) break :blk false;
            if (new_narrow) |n| break :blk n.eql(self.narrowed.?);
            break :blk true;
        };
        if (!narrow_eq) {
            if (self.narrowed) |*t| t.deinit(allocator);
            self.narrowed = new_narrow;
            changed = true;
        } else if (new_narrow) |*t| {
            t.deinit(allocator);
        }

        // Class narrowing: drops to None unless both sides agree.
        const keep_class = blk: {
            if (self.narrowed_class == null or other.narrowed_class == null) break :blk false;
            break :blk std.mem.eql(u8, self.narrowed_class.?, other.narrowed_class.?);
        };
        if (!keep_class and self.narrowed_class != null) {
            allocator.free(self.narrowed_class.?);
            self.narrowed_class = null;
            changed = true;
        }

        // Negative refinements intersect: only those known on *both*
        // sides survive.
        var new_not: std.ArrayList(Type) = .empty;
        errdefer {
            for (new_not.items) |*t| t.deinit(allocator);
            new_not.deinit(allocator);
        }
        for (self.not_types.items) |t| {
            var present = false;
            for (other.not_types.items) |o| {
                if (t.eql(o)) {
                    present = true;
                    break;
                }
            }
            if (present) try new_not.append(allocator, try t.clone(allocator));
        }
        if (new_not.items.len != self.not_types.items.len) changed = true;
        for (self.not_types.items) |*t| t.deinit(allocator);
        self.not_types.deinit(allocator);
        self.not_types = new_not;

        const new_null: Nullability = if (self.null == other.null) self.null else .Unknown;
        if (new_null != self.null) {
            self.null = new_null;
            changed = true;
        }
        return changed;
    }
};

/// Intersect two smart-cast facts: the narrowed type is the GLB
/// of both sides (with `null` treated as "no narrowing" so the
/// other side dominates); class-name agreement survives; the
/// nullability axis is the stronger of the two. Borrows both inputs;
/// the result owns freshly cloned heap data.
fn intersectFacts(allocator: Allocator, a: *const SmartCastFact, b: *const SmartCastFact) Allocator.Error!SmartCastFact {
    var narrowed: ?Type = null;
    errdefer if (narrowed) |*t| t.deinit(allocator);
    if (a.narrowed) |x| {
        if (b.narrowed) |y| {
            narrowed = try intersect(allocator, try x.clone(allocator), try y.clone(allocator));
        } else {
            narrowed = try x.clone(allocator);
        }
    } else if (b.narrowed) |y| {
        narrowed = try y.clone(allocator);
    }

    var narrowed_class: ?[]const u8 = null;
    errdefer if (narrowed_class) |c| allocator.free(c);
    if (a.narrowed_class) |x| {
        if (b.narrowed_class) |y| {
            if (std.mem.eql(u8, x, y)) narrowed_class = try allocator.dupe(u8, x);
        } else {
            narrowed_class = try allocator.dupe(u8, x);
        }
    } else if (b.narrowed_class) |y| {
        narrowed_class = try allocator.dupe(u8, y);
    }

    const null_axis: Nullability = blk: {
        if (a.null == .NonNull or b.null == .NonNull) break :blk .NonNull;
        if (a.null == .DefinitelyNull or b.null == .DefinitelyNull) break :blk .DefinitelyNull;
        break :blk .Unknown;
    };

    var not_types: std.ArrayList(Type) = .empty;
    errdefer {
        for (not_types.items) |*t| t.deinit(allocator);
        not_types.deinit(allocator);
    }
    for (a.not_types.items) |t| try not_types.append(allocator, try t.clone(allocator));
    for (b.not_types.items) |t| {
        var found = false;
        for (not_types.items) |x| {
            if (x.eql(t)) {
                found = true;
                break;
            }
        }
        if (!found) try not_types.append(allocator, try t.clone(allocator));
    }

    return .{
        .narrowed = narrowed,
        .narrowed_class = narrowed_class,
        .not_types = not_types,
        .null = null_axis,
    };
}

/// Intersection of two types, materialised as `Type.Intersection`
/// when both sides are non-trivial. Mirrors the typechecker's
/// existing intersection construction. Takes ownership of `a` and
/// `b`; frees `b` when the two are equal.
fn intersect(allocator: Allocator, a: Type, b: Type) Allocator.Error!Type {
    if (a.eql(b)) {
        var owned = b;
        owned.deinit(allocator);
        return a;
    }
    const parts = try allocator.alloc(Type, 2);
    parts[0] = a;
    parts[1] = b;
    return .{ .Intersection = parts };
}

/// Union for join points. With only `Type.Intersection` available
/// for refinement and no explicit union variant, we conservatively
/// drop the narrowing to `Any` when the two branches disagree — same
/// as the current typechecker behavior. Borrows both inputs; the
/// result owns freshly cloned heap data.
fn unionOf(allocator: Allocator, a: Type, b: Type) Allocator.Error!Type {
    if (a.eql(b)) return a.clone(allocator);
    return .Any;
}

pub const SmartCastLattice = dataflow.MapLattice(Place, SmartCastFact);

/// Ordered per-place declared-type map. Borrows place keys and types —
/// entries are not owned by the map; the transfer holds the borrowed
/// reference.
pub const PlaceTypeMap = struct {
    pub const Entry = struct { key: Place, value: Type };
    entries: []const Entry,

    pub fn get(self: PlaceTypeMap, place: *const Place) ?*const Type {
        for (self.entries) |*e| {
            if (e.key.eql(place.*)) return &e.value;
        }
        return null;
    }
};

pub const SmartCastBlockStates = std.ArrayList(SmartCastLattice);

pub const SmartCastTransfer = struct {
    reg_to_place: *const lower.RegPlaceMap,
    /// Declared types per place, supplied by the typechecker before
    /// the analysis runs. Used by `AssumeRefEq` to seed each side
    /// with its declaration when no prior narrowing has refined it.
    declared_types: ?PlaceTypeMap,

    /// Fetch the current fact for `place`, falling back to the
    /// declared type when no narrowing has been recorded. Caller owns
    /// the returned fact.
    fn factOrDeclared(self: *const SmartCastTransfer, allocator: Allocator, place: *const Place, state: *const SmartCastLattice) Allocator.Error!SmartCastFact {
        var fact = try state.get(allocator, place.*);
        errdefer fact.deinit(allocator);
        if (fact.narrowed == null) {
            if (self.declared_types) |decl_map| {
                if (decl_map.get(place)) |t| {
                    fact.narrowed = try t.clone(allocator);
                    // Nullable declared types get no automatic
                    // nullability axis — the explicit AssumeNull
                    // nodes carry that signal.
                }
            }
        }
        return fact;
    }

    pub fn transferNode(self: *SmartCastTransfer, node: *const Node, state: *SmartCastLattice, allocator: Allocator) Allocator.Error!void {
        switch (node.*) {
            .AssumeIs => |a| {
                if (self.reg_to_place.get(a.reg)) |place| {
                    var fact = try state.get(allocator, place);
                    errdefer fact.deinit(allocator);
                    if (a.polarity) {
                        const cn = if (a.class_name) |c| try allocator.dupe(u8, c) else null;
                        try fact.assumeIs(allocator, try a.ty.clone(allocator), cn);
                    } else {
                        try fact.assumeNotIs(allocator, try a.ty.clone(allocator));
                    }
                    try state.put(allocator, try place.clone(allocator), fact);
                }
            },
            .AssumeNull => |a| {
                if (self.reg_to_place.get(a.reg)) |place| {
                    var fact = try state.get(allocator, place);
                    errdefer fact.deinit(allocator);
                    if (a.eq_null) {
                        fact.assumeNull();
                    } else {
                        fact.assumeNonNull();
                    }
                    try state.put(allocator, try place.clone(allocator), fact);
                }
            },
            .AssumeRefEq => |a| {
                if (!a.polarity) return;
                const place_a = self.reg_to_place.get(a.reg_a);
                const place_b = self.reg_to_place.get(a.reg_b);
                if (place_a != null and place_b != null) {
                    const pa = place_a.?;
                    const pb = place_b.?;
                    var fa = try self.factOrDeclared(allocator, &pa, state);
                    defer fa.deinit(allocator);
                    var fb = try self.factOrDeclared(allocator, &pb, state);
                    defer fb.deinit(allocator);
                    var merged = try intersectFacts(allocator, &fa, &fb);
                    defer merged.deinit(allocator);
                    try state.put(allocator, try pa.clone(allocator), try merged.clone(allocator));
                    try state.put(allocator, try pb.clone(allocator), try merged.clone(allocator));
                }
            },
            .Assign => |a| {
                const fact = SmartCastFact.unknown();
                try state.put(allocator, try a.lhs.clone(allocator), fact);
            },
            .KillDataFlow => |k| {
                const fact = SmartCastFact.unknown();
                try state.put(allocator, try k.place.clone(allocator), fact);
            },
            else => {},
        }
    }
};

/// Run the smart-cast analysis to fixpoint. Returns per-block in-
/// states; the caller queries facts at the entry of the block
/// containing a given AST span.
pub fn solve(
    allocator: Allocator,
    cfg: *const Cfg,
    reg_to_place: *const lower.RegPlaceMap,
) Allocator.Error!SmartCastBlockStates {
    return solveWithDeclared(allocator, cfg, reg_to_place, null);
}

/// Like `solve`, but also seeded with a per-place declared-type map
/// that `AssumeRefEq` consults to bridge cross-variable narrowings
/// when neither side has a prior fact.
pub fn solveWithDeclared(
    allocator: Allocator,
    cfg: *const Cfg,
    reg_to_place: *const lower.RegPlaceMap,
    declared_types: ?PlaceTypeMap,
) Allocator.Error!SmartCastBlockStates {
    var transfer = SmartCastTransfer{
        .reg_to_place = reg_to_place,
        .declared_types = declared_types,
    };
    return dataflow.solveForward(
        SmartCastLattice,
        SmartCastTransfer,
        allocator,
        cfg,
        SmartCastLattice.init(),
        &transfer,
    );
}

/// Reproduce the per-node in-state walk inside a block. Mirrors
/// `analyses.via.statesWithinBlock` for ad-hoc lookups. Consumes
/// `entry`. Caller owns every returned lattice.
pub fn statesWithinBlock(
    allocator: Allocator,
    cfg: *const Cfg,
    block: ir.BlockId,
    entry: SmartCastLattice,
    reg_to_place: *const lower.RegPlaceMap,
) Allocator.Error!SmartCastBlockStates {
    return statesWithinBlockWithDeclared(allocator, cfg, block, entry, reg_to_place, null);
}

pub fn statesWithinBlockWithDeclared(
    allocator: Allocator,
    cfg: *const Cfg,
    block: ir.BlockId,
    entry: SmartCastLattice,
    reg_to_place: *const lower.RegPlaceMap,
    declared_types: ?PlaceTypeMap,
) Allocator.Error!SmartCastBlockStates {
    const blk = cfg.block(block);
    var out: SmartCastBlockStates = .empty;
    errdefer {
        for (out.items) |*s| s.deinit(allocator);
        out.deinit(allocator);
    }
    try out.ensureTotalCapacity(allocator, blk.nodes.items.len + 1);
    var s = entry;
    errdefer s.deinit(allocator);
    try out.append(allocator, try s.clone(allocator));
    var t = SmartCastTransfer{
        .reg_to_place = reg_to_place,
        .declared_types = declared_types,
    };
    for (blk.nodes.items) |*node| {
        try t.transferNode(node, &s, allocator);
        try out.append(allocator, try s.clone(allocator));
    }
    s.deinit(allocator);
    return out;
}

test "smartcast fact join unions disagreeing narrowing to Any" {
    const a = std.testing.allocator;
    var x = SmartCastFact{ .narrowed = .Int, .null = .NonNull };
    defer x.deinit(a);
    var y = SmartCastFact{ .narrowed = .String, .null = .NonNull };
    defer y.deinit(a);
    const changed = try x.join(a, &y);
    try std.testing.expect(changed);
    try std.testing.expect(x.narrowed != null and x.narrowed.? == .Any);
    try std.testing.expectEqual(Nullability.NonNull, x.null);
}

test "smartcast fact join keeps agreeing narrowing" {
    const a = std.testing.allocator;
    var x = SmartCastFact{ .narrowed = .Int };
    defer x.deinit(a);
    var y = SmartCastFact{ .narrowed = .Int };
    defer y.deinit(a);
    const changed = try x.join(a, &y);
    try std.testing.expect(!changed);
    try std.testing.expect(x.narrowed != null and x.narrowed.? == .Int);
}

test "smartcast fact join drops narrowing when one side has none" {
    const a = std.testing.allocator;
    var x = SmartCastFact{ .narrowed = .Int };
    defer x.deinit(a);
    var y = SmartCastFact{};
    defer y.deinit(a);
    const changed = try x.join(a, &y);
    try std.testing.expect(changed);
    try std.testing.expect(x.narrowed == null);
}

test "smartcast assumeIs intersects with prior narrowing" {
    const a = std.testing.allocator;
    var f = SmartCastFact{ .narrowed = .Int };
    defer f.deinit(a);
    try f.assumeIs(a, .String, null);
    try std.testing.expect(f.narrowed != null and f.narrowed.? == .Intersection);
    try std.testing.expectEqual(@as(usize, 2), f.narrowed.?.Intersection.len);
}

test "smartcast assumeIs records class name" {
    const a = std.testing.allocator;
    var f = SmartCastFact.unknown();
    defer f.deinit(a);
    try f.assumeIs(a, .Unresolved, try a.dupe(u8, "Foo"));
    try std.testing.expect(f.narrowed_class != null);
    try std.testing.expectEqualStrings("Foo", f.narrowed_class.?);
}

test "smartcast nullability axis flips" {
    var f = SmartCastFact.unknown();
    f.assumeNonNull();
    try std.testing.expectEqual(Nullability.NonNull, f.null);
    f.assumeNull();
    try std.testing.expectEqual(Nullability.Unknown, f.null);
    f.assumeNull();
    try std.testing.expectEqual(Nullability.DefinitelyNull, f.null);
    f.assumeNonNull();
    try std.testing.expectEqual(Nullability.Unknown, f.null);
}

test "smartcast assumeNotIs dedups" {
    const a = std.testing.allocator;
    var f = SmartCastFact.unknown();
    defer f.deinit(a);
    try f.assumeNotIs(a, .Int);
    try f.assumeNotIs(a, .Int);
    try f.assumeNotIs(a, .String);
    try std.testing.expectEqual(@as(usize, 2), f.not_types.items.len);
}

test "smartcast join intersects negative refinements" {
    const a = std.testing.allocator;
    var x = SmartCastFact.unknown();
    defer x.deinit(a);
    try x.assumeNotIs(a, .Int);
    try x.assumeNotIs(a, .String);
    var y = SmartCastFact.unknown();
    defer y.deinit(a);
    try y.assumeNotIs(a, .Int);
    const changed = try x.join(a, &y);
    try std.testing.expect(changed);
    try std.testing.expectEqual(@as(usize, 1), x.not_types.items.len);
    try std.testing.expect(x.not_types.items[0] == .Int);
}
