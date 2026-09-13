//! CFG IR shared across analyses. Every interesting program point is an `Eval`
//! of a sub-expression into a virtual register, an `Assume` refining a register
//! on one control-flow edge, or an assignment to a `Place`. Blocks end in a
//! `Terminator` naming their successors, and each edge carries an `EdgeKind` so
//! analyses can tell exception edges and finally entry/exit from normal flow.

const std = @import("std");
const span = @import("span");
const types = @import("types");

const Allocator = std.mem.Allocator;

pub const Span = span.Span;
pub const Type = types.Type;

/// Stable index for a basic block within a single CFG.
pub const BlockId = enum(u32) {
    _,
    pub fn from(v: u32) BlockId {
        return @enumFromInt(v);
    }
    pub fn int(self: BlockId) u32 {
        return @intFromEnum(self);
    }
};

/// Virtual register holding the result of an `Eval` node. Not SSA: a register
/// is produced once and consumed at any later point in the same CFG.
pub const Reg = enum(u32) {
    _,
    pub fn from(v: u32) Reg {
        return @enumFromInt(v);
    }
    pub fn int(self: Reg) u32 {
        return @intFromEnum(self);
    }
};

/// Stable identifier for a labeled loop. Used by `Backedge` nodes
/// and by `break@l` / `continue@l` lowerings.
pub const LoopId = enum(u32) {
    _,
    pub fn from(v: u32) LoopId {
        return @enumFromInt(v);
    }
    pub fn int(self: LoopId) u32 {
        return @intFromEnum(self);
    }
};

/// Stable identifier for a user-visible label (`outer@`, `lambda@foo`).
/// Distinct from `LoopId` so a labeled non-loop block needs no fake loop.
pub const LabelId = enum(u32) {
    _,
    pub fn from(v: u32) LabelId {
        return @enumFromInt(v);
    }
    pub fn int(self: LabelId) u32 {
        return @intFromEnum(self);
    }
};

/// Identifier for a named local, parameter, property, or
/// `this`-bound receiver. The same symbol space as the resolver.
pub const Symbol = struct {
    name: []const u8,

    pub fn eql(self: Symbol, other: Symbol) bool {
        return std.mem.eql(u8, self.name, other.name);
    }

    pub fn clone(self: Symbol, allocator: Allocator) Allocator.Error!Symbol {
        return .{ .name = try allocator.dupe(u8, self.name) };
    }
};

/// Structural field projection used by smart-cast dot paths (`p.x.y`). Carries
/// the unresolved name, which smart-cast matches within an enclosing
/// `val`-stable chain.
pub const FieldId = struct {
    name: []const u8,

    pub fn eql(self: FieldId, other: FieldId) bool {
        return std.mem.eql(u8, self.name, other.name);
    }

    pub fn clone(self: FieldId, allocator: Allocator) Allocator.Error!FieldId {
        return .{ .name = try allocator.dupe(u8, self.name) };
    }
};

/// Assignable, narrowable location. Smart casts attach to `Place` rather than
/// `Reg`: registers are short-lived expression slots, places persist across the
/// CFG.
pub const Place = union(enum) {
    Local: Symbol,
    /// Dotted access onto another place: `receiver.field`.
    Field: struct {
        receiver: *Place,
        field: FieldId,
    },
    /// `this` of the enclosing class/lambda receiver.
    This,

    pub fn eql(self: Place, other: Place) bool {
        if (@as(std.meta.Tag(Place), self) != @as(std.meta.Tag(Place), other)) {
            return false;
        }
        return switch (self) {
            .Local => |s| s.eql(other.Local),
            .Field => |f| f.receiver.eql(other.Field.receiver.*) and f.field.eql(other.Field.field),
            .This => true,
        };
    }

    pub fn clone(self: Place, allocator: Allocator) Allocator.Error!Place {
        return switch (self) {
            .Local => |s| .{ .Local = try s.clone(allocator) },
            .Field => |f| .{ .Field = .{
                .receiver = blk: {
                    const r = try allocator.create(Place);
                    r.* = try f.receiver.clone(allocator);
                    break :blk r;
                },
                .field = try f.field.clone(allocator),
            } },
            .This => .This,
        };
    }

    pub fn deinit(self: *Place, allocator: Allocator) void {
        switch (self.*) {
            .Local => |s| allocator.free(s.name),
            .Field => |*f| {
                f.receiver.deinit(allocator);
                allocator.destroy(f.receiver);
                allocator.free(f.field.name);
            },
            .This => {},
        }
    }

    /// Total order over `Place` values by their structural rendering.
    pub fn order(self: Place, other: Place) std.math.Order {
        return orderStructural(self, other);
    }
};

fn placeTagRank(p: Place) u8 {
    return switch (p) {
        .Local => 0,
        .Field => 1,
        .This => 2,
    };
}

fn orderStructural(a: Place, b: Place) std.math.Order {
    const ra = placeTagRank(a);
    const rb = placeTagRank(b);
    if (ra != rb) return std.math.order(ra, rb);
    return switch (a) {
        .Local => |s| std.mem.order(u8, s.name, b.Local.name),
        .Field => |f| blk: {
            const recv = orderStructural(f.receiver.*, b.Field.receiver.*);
            if (recv != .eq) break :blk recv;
            break :blk std.mem.order(u8, f.field.name, b.Field.field.name);
        },
        .This => .eq,
    };
}

/// Per-node `Eval` payload. The AST span maps results back to source for
/// diagnostics, and the static type lets reachability spot a `Nothing`-typed
/// evaluation without re-running typeck.
pub const ExprRef = struct {
    span: Span,
    ty: Type,
};

/// A single CFG node within a block. Nodes execute top to bottom; control
/// transfers only at the block's `Terminator`.
pub const Node = union(enum) {
    Eval: struct { reg: Reg, expr: ExprRef },
    Assign: struct { lhs: Place, rhs: Reg, span: Span },
    /// Declare a fresh local; VIA seeds this place as `Unassigned`.
    DeclLocal: struct {
        place: Symbol,
        declared_ty: Type,
        span: Span,
    },
    /// Assume `reg` is true (false). Emitted on `Branch::True` /
    /// `Branch::False` arms after lowering `if`/`when`/`&&`/`||`.
    Assume: struct { reg: Reg, polarity: bool },
    /// Assume the runtime type of `reg` is (is not) `ty`, emitted on the arms of
    /// an `is` / `!is` check; the smart-cast lattice consumes both polarities.
    /// `class_name` carries the source type-ref's simple name so the typechecker
    /// can recover a user-class narrowing, `ty` being `Type.Unresolved` for any
    /// name outside `builtin_by_name`.
    AssumeIs: struct {
        reg: Reg,
        ty: Type,
        class_name: ?[]const u8,
        polarity: bool,
        span: Span,
    },
    /// Assume `reg == null` (or `!= null`). Distinct from `AssumeIs Nothing?`
    /// because nullability is its own axis on the smart-cast lattice.
    AssumeNull: struct { reg: Reg, eq_null: bool, span: Span },
    /// Assume two registers refer to the same runtime value. Produced by
    /// `a === b`, and by structural equality when at least one side is
    /// non-nullable; on the truthy branch both places narrow to the intersection
    /// of their facts.
    AssumeRefEq: struct {
        reg_a: Reg,
        reg_b: Reg,
        polarity: bool,
        span: Span,
    },
    /// Assert `reg` is true; otherwise control diverges, the containing block
    /// ending in `Terminator.Unreachable` along the false edge. Used for `!!`,
    /// `as`, and contract `require`.
    Assert: struct { reg: Reg, span: Span },
    /// Invalidate every smart cast bound on `place`, since a loop back-edge may
    /// have reassigned it. Inserted by `killDataFlow` after the fixpoint.
    KillDataFlow: struct { place: Place },
    /// Loop back-jump marker carrying the loop's id, so the dataflow solver
    /// identifies backedges without re-deriving the loop nest.
    Backedge: struct { loop_id: LoopId },
    /// Source-visible label position, consumed by `break@l` / `continue@l`
    /// lowering and by diagnostics pointing at the labeled site.
    LabelMark: struct { label: LabelId },
    /// Marker inserted wherever lowering knows a point is statically dead, such
    /// as after a `Nothing`-returning call. Reachability treats it as bottom.
    Unreachable,
};

pub const SwitchArm = struct {
    pattern: Pattern,
    target: BlockId,
};

/// Pattern shapes lowering produces for `when` arms. Conditions inside an arm
/// (`is T`, `in r`, equality) become `AssumeIs` / `AssumeNull` / `Assume` nodes
/// in the arm's body rather than part of the pattern, which keeps the switch
/// table cheap to walk.
pub const Pattern = union(enum) {
    Equal: Reg,
    Is: struct { ty: Type, polarity: bool },
    /// Always-match arm (used for the desugared `else`).
    Wildcard,
};

/// How control leaves a block. Every block has exactly one.
pub const Terminator = union(enum) {
    Goto: BlockId,
    Branch: struct {
        cond: Reg,
        then_blk: BlockId,
        else_blk: BlockId,
    },
    /// N-way switch on a register and a list of exclusive patterns, used for
    /// `when (subject)`; `default` is taken when none match.
    Switch: struct {
        reg: Reg,
        arms: []SwitchArm,
        default: BlockId,
    },
    /// Throw a value; control transfers to the nearest matching handler, found
    /// through this block's exception edges.
    Throw: Reg,
    /// Return from the enclosing function. `null` for `Unit`.
    Return: ?Reg,
    /// Statically unreachable past this point, equivalent to a divergent
    /// terminator; reachability prunes the successors.
    Unreachable,
};

/// Kind of edge between two blocks. Analyses route by kind: exception edges
/// skip normal joins, and finally edges feed both the normal-exit and the
/// exception-path summaries.
pub const EdgeKind = union(enum) {
    Normal,
    True,
    False,
    /// Edge taken when the source block throws a value whose runtime type is a
    /// subtype of `ty`. Lowered for every statement in a `try` with a matching
    /// handler.
    Exception: struct { ty: ?Type },
    /// Edge into the `finally` block from the normal exit of a `try` body or of
    /// one of its handlers.
    FinallyEntry,
    /// Edge out of the `finally` block back to the original continuation,
    /// normal exit or rethrow.
    FinallyExit,

    pub fn eql(self: EdgeKind, other: EdgeKind) bool {
        if (@as(std.meta.Tag(EdgeKind), self) != @as(std.meta.Tag(EdgeKind), other)) {
            return false;
        }
        return switch (self) {
            .Normal, .True, .False, .FinallyEntry, .FinallyExit => true,
            .Exception => |e| blk: {
                const o = other.Exception;
                if (e.ty == null and o.ty == null) break :blk true;
                if (e.ty == null or o.ty == null) break :blk false;
                break :blk e.ty.?.eql(o.ty.?);
            },
        };
    }
};

pub const Edge = struct {
    block: BlockId,
    kind: EdgeKind,
};

/// One block in a CFG. `preds` and `succs` carry each edge's kind, so an
/// analysis can pick the matching transfer function.
pub const BasicBlock = struct {
    id: BlockId,
    nodes: std.ArrayList(Node) = .empty,
    term: Terminator = .Unreachable,
    preds: std.ArrayList(Edge) = .empty,
    succs: std.ArrayList(Edge) = .empty,
};

/// The CFG of one function, property accessor or init block. `entry` is always
/// present; `exits` lists every block whose terminator is `Return` and every
/// block that falls off the end of a `Unit`-typed body.
pub const Cfg = struct {
    blocks: std.ArrayList(BasicBlock) = .empty,
    entry: BlockId,
    exits: std.ArrayList(BlockId) = .empty,
    /// Source span of the function/accessor/init this CFG covers.
    source: Span,
    /// Next register id to allocate during further IR manipulation.
    next_reg: u32,

    pub fn block(self: *const Cfg, id: BlockId) *const BasicBlock {
        return &self.blocks.items[id.int()];
    }

    pub fn blockMut(self: *Cfg, id: BlockId) *BasicBlock {
        return &self.blocks.items[id.int()];
    }
};

test "place equality and ordering" {
    const a = Place{ .Local = .{ .name = "a" } };
    const b = Place{ .Local = .{ .name = "b" } };
    const this = Place.This;
    try std.testing.expect(a.eql(a));
    try std.testing.expect(!a.eql(b));
    try std.testing.expectEqual(std.math.Order.lt, orderStructural(a, b));
    try std.testing.expectEqual(std.math.Order.lt, orderStructural(a, this));
}

test "edge kind equality" {
    const normal: EdgeKind = .Normal;
    const truth: EdgeKind = .True;
    const falsity: EdgeKind = .False;
    try std.testing.expect(normal.eql(.Normal));
    try std.testing.expect(!truth.eql(falsity));
    const e1 = EdgeKind{ .Exception = .{ .ty = null } };
    const e2 = EdgeKind{ .Exception = .{ .ty = .Int } };
    try std.testing.expect(e1.eql(.{ .Exception = .{ .ty = null } }));
    try std.testing.expect(!e1.eql(e2));
}
