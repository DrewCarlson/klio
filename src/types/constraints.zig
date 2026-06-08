//! Kotlin type-constraint system.
//!
//! Implements the foundations: inference variables, per-variable bound
//! sets with the implicit `Nothing <: α <: Any?` bounds, a constraint
//! pool, and reduction + incorporation passes that drive toward a
//! fixpoint. The solver picks a substitution per inference variable
//! using the pull-up / push-down preference and the GLB/LUB routing.
//!
//! Designed to be consumed by the type checker at call sites for
//! type-argument inference, by branch joins for LUB, and by smart-cast
//! composition for GLB (intersection).

const std = @import("std");
const span = @import("span");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Type = types.Type;
const Variance = types.Variance;
const GenericArg = types.GenericArg;
const Span = span.Span;

/// Fresh inference variable identity. Distinct from `Type.TypeParam`
/// (which models fixed type variables — the body of a generic
/// declaration where the parameter is unknown but immutable).
pub const InferenceVar = enum(u32) {
    _,

    pub fn from(v: u32) InferenceVar {
        return @enumFromInt(v);
    }

    pub fn int(self: InferenceVar) u32 {
        return @intFromEnum(self);
    }
};

/// Pull-up (largest, LUB of lower bounds) or push-down (smallest, GLB of
/// upper bounds) preference attached to an inference variable. Variables
/// default to pull-up.
pub const SolutionPreference = enum {
    PullUp,
    PushDown,

    pub const default: SolutionPreference = .PullUp;
};

/// A variable that cannot be fixed in the active stage because its
/// resolution depends on something else (a lambda body that has not
/// yet been type-checked, a callable reference whose overload depends
/// on the expected type, a `@BuilderInference` receiver). The solver
/// skips postponed vars during staged fixation; the typechecker
/// re-runs the surrounding lambda body once the gating variable
/// resolves and feeds the resulting constraints back.
pub const PostponedKind = union(enum) {
    /// Lambda whose receiver / parameter types or whose body cannot
    /// be checked until `gating` resolves.
    Lambda: struct { gating: InferenceVar },
    /// `::name` whose overload resolution awaits an expected type.
    CallableRef,
    /// `@BuilderInference` receiver — body must be re-typed under the
    /// fixed receiver type before its constraints can flow.
    BuilderInference: struct { owner: InferenceVar },
    /// Eta-expansion of a callable to a function-typed expectation.
    Eta,

    pub fn eql(self: PostponedKind, other: PostponedKind) bool {
        if (@as(std.meta.Tag(PostponedKind), self) != @as(std.meta.Tag(PostponedKind), other)) {
            return false;
        }
        return switch (self) {
            .Lambda => |l| l.gating == other.Lambda.gating,
            .CallableRef => true,
            .BuilderInference => |b| b.owner == other.BuilderInference.owner,
            .Eta => true,
        };
    }
};

/// Per-variable bound set. The implicit `Nothing <: α <: Any?` bounds
/// are pre-installed; callers may freely add tighter bounds.
///
/// All `Type` values held here are owned by the `ConstraintSystem`'s
/// arena, so this struct has no `deinit` of its own.
pub const BoundSet = struct {
    lower: std.ArrayList(Type),
    upper: std.ArrayList(Type),
    preference: SolutionPreference,
    /// When set, the variable is postponed; staged fixation skips it
    /// in the current pass.
    postponed: ?PostponedKind,

    /// Fresh bound set seeded with the implicit `Nothing <: α`
    /// and `α <: Any?` bounds. Both list spines and the seeded `Any`
    /// box are allocated in `arena`, so the system owns everything and
    /// nothing here is freed through a foreign allocator.
    pub fn new(arena: Allocator) Allocator.Error!BoundSet {
        var lower: std.ArrayList(Type) = .empty;
        try lower.append(arena, .Nothing);
        var upper: std.ArrayList(Type) = .empty;
        const any = try arena.create(Type);
        any.* = .Any;
        try upper.append(arena, .{ .Nullable = any });
        return .{
            .lower = lower,
            .upper = upper,
            .preference = .PullUp,
            .postponed = null,
        };
    }

    /// Mark this bound set as postponed under the given kind.
    pub fn postpone(self: *BoundSet, kind: PostponedKind) void {
        self.postponed = kind;
    }

    /// `true` once the postponed gating has been cleared and this
    /// variable is eligible for fixation in the next stage.
    pub fn isPostponed(self: *const BoundSet) bool {
        return self.postponed != null;
    }

    /// Add `t` (already arena-owned) to the lower bounds unless present.
    pub fn addLower(self: *BoundSet, arena: Allocator, t: Type) Allocator.Error!bool {
        for (self.lower.items) |x| {
            if (x.eql(t)) return false;
        }
        try self.lower.append(arena, t);
        return true;
    }

    /// Add `t` (already arena-owned) to the upper bounds unless present.
    pub fn addUpper(self: *BoundSet, arena: Allocator, t: Type) Allocator.Error!bool {
        for (self.upper.items) |x| {
            if (x.eql(t)) return false;
        }
        try self.upper.append(arena, t);
        return true;
    }
};

/// Kind of constraint. `Equality` is symmetric and reduces to two
/// subtype constraints (`S <: T` and `T <: S`) plus a union-find
/// merge of any inference vars involved.
pub const ConstraintKind = enum {
    Subtype,
    Equality,
};

/// Where a constraint came from, so failure diagnostics can point at
/// the responsible source expression instead of a synthesised
/// description. Diagnostic renderers consume this side-channel;
/// the solver itself just carries the data alongside every
/// constraint.
pub const Provenance = union(enum) {
    /// Argument at position `arg_idx` of a call at `span` is bound to
    /// a parameter of the inferred function signature.
    CallSite: struct { span: Span, arg_idx: usize },
    /// The return type of a call at `span` flows into the surrounding
    /// expected type.
    Return: struct { span: Span },
    /// The body of a lambda at `span` flows into its expected return.
    LambdaBody: struct { span: Span },
    /// A smart-cast intersection at a CFG join feeds back into the
    /// inference session as a refined bound on an inference variable.
    SmartCast: struct { span: Span },
    /// A bound carried by a declaration-site type parameter.
    Bound: struct { name: []const u8 },
    /// LUB join over `if` / `when` / `try` branches.
    LubJoin: struct { span: Span },
    /// Internal derivation by the solver itself (incorporation,
    /// equality propagation, supertype walk). Carries the kind of
    /// derivation so diagnostics can still explain it.
    Derived: []const u8,

    pub fn eql(self: Provenance, other: Provenance) bool {
        if (@as(std.meta.Tag(Provenance), self) != @as(std.meta.Tag(Provenance), other)) {
            return false;
        }
        return switch (self) {
            .CallSite => |c| c.span.eql(other.CallSite.span) and c.arg_idx == other.CallSite.arg_idx,
            .Return => |r| r.span.eql(other.Return.span),
            .LambdaBody => |l| l.span.eql(other.LambdaBody.span),
            .SmartCast => |s| s.span.eql(other.SmartCast.span),
            .Bound => |b| std.mem.eql(u8, b.name, other.Bound.name),
            .LubJoin => |l| l.span.eql(other.LubJoin.span),
            .Derived => |d| std.mem.eql(u8, d, other.Derived),
        };
    }

    /// Convenience constructor for the common `Derived(&'static str)` form.
    pub fn derived(s: []const u8) Provenance {
        return .{ .Derived = s };
    }
};

/// Constraint over types that may contain inference variables. An
/// inference variable is encoded as `Type.TypeParam(name)` where
/// `name` is the textual id assigned by `ConstraintSystem.fresh`.
/// All `Type` values are owned by the `ConstraintSystem`'s arena.
pub const Constraint = struct {
    lhs: Type,
    rhs: Type,
    kind: ConstraintKind,
    provenance: Provenance,
};

/// Failure modes the reducer can hit. Surface these through diagnostics
/// at the call site. `Type` values are owned by the system arena.
pub const InferenceError = union(enum) {
    /// Two resolved (non-inference-variable) types are unrelated and the
    /// constraint cannot be satisfied.
    UnsatisfiableConcrete: struct { lhs: Type, rhs: Type },
    /// A nullable lhs flows into a known non-nullable rhs.
    NullableIntoNonNullable: struct { lhs: Type, rhs: Type },
    /// A generic-class supertype required by rhs was not found on lhs.
    MissingSupertype: struct { lhs: Type, rhs_head: []const u8 },
    /// Bounds on the same variable form a contradiction.
    ContradictoryBounds: InferenceVar,

    pub fn eql(self: InferenceError, other: InferenceError) bool {
        if (@as(std.meta.Tag(InferenceError), self) != @as(std.meta.Tag(InferenceError), other)) {
            return false;
        }
        return switch (self) {
            .UnsatisfiableConcrete => |u| u.lhs.eql(other.UnsatisfiableConcrete.lhs) and
                u.rhs.eql(other.UnsatisfiableConcrete.rhs),
            .NullableIntoNonNullable => |n| n.lhs.eql(other.NullableIntoNonNullable.lhs) and
                n.rhs.eql(other.NullableIntoNonNullable.rhs),
            .MissingSupertype => |m| m.lhs.eql(other.MissingSupertype.lhs) and
                std.mem.eql(u8, m.rhs_head, other.MissingSupertype.rhs_head),
            .ContradictoryBounds => |v| v == other.ContradictoryBounds,
        };
    }
};

/// Stable identifier for an interned type. Two types are
/// `TypeId`-equal iff they are structurally equal modulo
/// interning. Used as the key of the solver's `seen` set so we
/// don't re-emit a constraint we've already reduced.
pub const TypeId = enum(u32) {
    _,

    pub fn from(v: u32) TypeId {
        return @enumFromInt(v);
    }

    pub fn int(self: TypeId) u32 {
        return @intFromEnum(self);
    }
};

/// Key into the `seen` set: a reduced `(S, T, kind)` triple.
const SeenKey = struct {
    lhs: TypeId,
    rhs: TypeId,
    kind: ConstraintKind,
};

const SeenContext = struct {
    pub fn hash(_: SeenContext, k: SeenKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&k.lhs));
        h.update(std.mem.asBytes(&k.rhs));
        const tag: u8 = @intFromEnum(k.kind);
        h.update(std.mem.asBytes(&tag));
        return h.final();
    }

    pub fn eql(_: SeenContext, a: SeenKey, b: SeenKey) bool {
        return a.lhs == b.lhs and a.rhs == b.rhs and a.kind == b.kind;
    }
};

/// Structural hash/eql context for using `Type` as a hash-map key. The
/// stored key is owned by the system arena.
const TypeContext = struct {
    pub fn hash(_: TypeContext, t: Type) u64 {
        var h = std.hash.Wyhash.init(0);
        hashType(&h, t);
        return h.final();
    }

    pub fn eql(_: TypeContext, a: Type, b: Type) bool {
        return a.eql(b);
    }
};

fn hashType(h: *std.hash.Wyhash, t: Type) void {
    const tag: u8 = @intFromEnum(@as(std.meta.Tag(Type), t));
    h.update(std.mem.asBytes(&tag));
    switch (t) {
        .Unit, .Boolean, .Byte, .Short, .Int, .Long, .UByte, .UShort, .UInt, .ULong, .Float, .Double, .Char, .String, .Any, .Nothing, .Unresolved => {},
        .Nullable, .Range => |inner| hashType(h, inner.*),
        .TypeParam => |name| h.update(name),
        .Function => |f| {
            const susp: u8 = @intFromBool(f.is_suspend);
            h.update(std.mem.asBytes(&susp));
            for (f.params) |p| hashType(h, p);
            hashType(h, f.return_type.*);
        },
        .Generic => |g| {
            h.update(g.name);
            for (g.args) |a| {
                const v: u8 = @intFromEnum(a.variance);
                h.update(std.mem.asBytes(&v));
                const star: u8 = @intFromBool(a.is_star);
                h.update(std.mem.asBytes(&star));
                hashType(h, a.ty);
            }
        },
        .Intersection => |parts| {
            for (parts) |p| hashType(h, p);
        },
    }
}

const VarMap = std.AutoHashMapUnmanaged(InferenceVar, BoundSet);
const NameMap = std.StringHashMapUnmanaged(InferenceVar);
const SeenSet = std.HashMapUnmanaged(SeenKey, void, SeenContext, std.hash_map.default_max_load_percentage);
const TypeIndex = std.HashMapUnmanaged(Type, TypeId, TypeContext, std.hash_map.default_max_load_percentage);
const EquivMap = std.AutoHashMapUnmanaged(InferenceVar, InferenceVar);
const ResolvedMap = std.AutoHashMap(InferenceVar, Type);

/// The last unsatisfied constraint together with the provenance that
/// produced it, for diagnostics.
pub const LastError = struct {
    err: InferenceError,
    provenance: Provenance,
};

/// Solver workspace: holds the set of inference variables, their bounds,
/// and the pending constraint pool. All owned `Type` data lives in the
/// internal arena and is released by `deinit`.
pub const ConstraintSystem = struct {
    /// Backing store for every `Type` cloned into bounds, the pending
    /// pool, the interned pool, and recorded errors.
    type_arena: std.heap.ArenaAllocator,
    /// Allocator for the container structures (maps, lists).
    gpa: Allocator,

    bounds: VarMap,
    /// Stable id-to-name lookup for the textual encoding inside
    /// `Type.TypeParam`. Names are arena-owned.
    var_names: NameMap,
    next_id: u32,
    pending: std.ArrayList(Constraint),
    /// Constraints already reduced, keyed by interned type ids
    /// rather than `Type.toString()`. Prevents the incorporation
    /// phase from re-emitting an `S <: T` that has been processed.
    seen: SeenSet,
    /// Interned type pool. Each unique `Type` (by structural
    /// equality) gets a stable `TypeId`.
    type_pool: std.ArrayList(Type),
    type_index: TypeIndex,
    /// Equality classes over inference variables. When `α ≡ β` is
    /// derived (either explicitly or by `S <: α ∧ α <: S` for the
    /// same `S`), we collapse them so subsequent constraints share
    /// a single bound set.
    equiv: EquivMap,
    /// Last `InferenceError` recorded with the failing provenance
    /// attached. The solver continues processing the pool to surface
    /// any additional errors; the caller reads this after solve.
    last_error_val: ?LastError,

    pub fn init(gpa: Allocator) ConstraintSystem {
        return .{
            .type_arena = std.heap.ArenaAllocator.init(gpa),
            .gpa = gpa,
            .bounds = .empty,
            .var_names = .empty,
            .next_id = 0,
            .pending = .empty,
            .seen = .empty,
            .type_pool = .empty,
            .type_index = .empty,
            .equiv = .empty,
            .last_error_val = null,
        };
    }

    /// Single ownership story: every container the system holds is
    /// arena-backed, so the whole solver workspace — map spines, bound
    /// lists, interned `Type`s, and `var_names` keys — is reclaimed by
    /// the one `type_arena.deinit()`. No system memory is freed through
    /// `gpa`, and no arena memory is ever handed to a foreign allocator
    /// to free.
    pub fn deinit(self: *ConstraintSystem) void {
        self.type_arena.deinit();
    }

    fn arena(self: *ConstraintSystem) Allocator {
        return self.type_arena.allocator();
    }

    /// Clone `t` into the system arena so the solver owns a stable copy.
    fn own(self: *ConstraintSystem, t: Type) Allocator.Error!Type {
        return t.clone(self.arena());
    }

    /// Allocates a fresh inference variable. The returned `Type` is the
    /// canonical textual encoding used inside constraints (arena-owned).
    pub fn fresh(self: *ConstraintSystem, hint: []const u8) Allocator.Error!struct { InferenceVar, Type } {
        const id = InferenceVar.from(self.next_id);
        self.next_id += 1;
        const a = self.arena();
        const name = try std.fmt.allocPrint(a, "?{s}{d}", .{ hint, id.int() });
        try self.var_names.put(a, name, id);
        try self.bounds.put(a, id, try BoundSet.new(a));
        return .{ id, .{ .TypeParam = name } };
    }

    pub fn setPreference(self: *ConstraintSystem, v: InferenceVar, p: SolutionPreference) void {
        if (self.bounds.getPtr(v)) |b| {
            b.preference = p;
        }
    }

    /// Mark a variable postponed under `kind`. The staged fixation
    /// pass will skip it until `clearPostponed(v)` is called.
    pub fn postpone(self: *ConstraintSystem, v: InferenceVar, kind: PostponedKind) void {
        if (self.bounds.getPtr(v)) |b| {
            b.postpone(kind);
        }
    }

    pub fn clearPostponed(self: *ConstraintSystem, v: InferenceVar) void {
        if (self.bounds.getPtr(v)) |b| {
            b.postponed = null;
        }
    }

    /// Returns the postponed kind for `v`, if any.
    pub fn postponedKind(self: *const ConstraintSystem, v: InferenceVar) ?PostponedKind {
        if (self.bounds.getPtr(v)) |b| {
            return b.postponed;
        }
        return null;
    }

    /// Returns the inference var `t` encodes, or null if it isn't one.
    pub fn isInferenceVar(self: *const ConstraintSystem, t: Type) ?InferenceVar {
        return switch (t) {
            .TypeParam => |name| self.var_names.get(name),
            else => null,
        };
    }

    /// Subtype constraint without provenance. Convenience entry
    /// point preserved for callers that don't yet have a source span
    /// to attribute the failure to.
    pub fn addConstraint(self: *ConstraintSystem, lhs: Type, rhs: Type) Allocator.Error!void {
        try self.addConstraintWith(lhs, rhs, .Subtype, Provenance.derived("legacy"));
    }

    /// Equality constraint. Records `S ≡ T` and reduces to `S <: T`
    /// and `T <: S` in the pending pool; if both sides are inference
    /// vars, also merges their equivalence classes.
    pub fn addEquality(self: *ConstraintSystem, lhs: Type, rhs: Type, provenance: Provenance) Allocator.Error!void {
        if (self.isInferenceVar(lhs)) |a| {
            if (self.isInferenceVar(rhs)) |b| {
                try self.unionVars(a, b);
            }
        }
        try self.addConstraintWith(lhs, rhs, .Equality, provenance);
        try self.addConstraintWith(rhs, lhs, .Subtype, provenance);
    }

    /// Subtype constraint with provenance. Use this from the
    /// typechecker; the carried provenance feeds back into failure
    /// diagnostics.
    pub fn addConstraintWith(
        self: *ConstraintSystem,
        lhs: Type,
        rhs: Type,
        kind: ConstraintKind,
        provenance: Provenance,
    ) Allocator.Error!void {
        const owned_lhs = try self.own(lhs);
        const owned_rhs = try self.own(rhs);
        const key: SeenKey = .{
            .lhs = try self.intern(owned_lhs),
            .rhs = try self.intern(owned_rhs),
            .kind = kind,
        };
        if (self.seen.contains(key)) {
            return;
        }
        try self.pending.append(self.arena(), .{
            .lhs = owned_lhs,
            .rhs = owned_rhs,
            .kind = kind,
            .provenance = provenance,
        });
    }

    /// Look up an interned id for `t`, allocating a fresh one if
    /// this is the first time we've seen its structural form. `t`
    /// must already be arena-owned.
    fn intern(self: *ConstraintSystem, t: Type) Allocator.Error!TypeId {
        if (self.type_index.get(t)) |id| {
            return id;
        }
        const id = TypeId.from(@intCast(self.type_pool.items.len));
        const a = self.arena();
        try self.type_pool.append(a, t);
        try self.type_index.put(a, t, id);
        return id;
    }

    fn unionVars(self: *ConstraintSystem, a: InferenceVar, b: InferenceVar) Allocator.Error!void {
        const ra = self.findRoot(a);
        const rb = self.findRoot(b);
        if (ra == rb) {
            return;
        }
        // Point the higher-id var at the lower-id one; stable choice.
        const keep = if (ra.int() <= rb.int()) ra else rb;
        const drop = if (ra.int() <= rb.int()) rb else ra;
        const arena_alloc = self.arena();
        try self.equiv.put(arena_alloc, drop, keep);
        // Merge bound sets: drop's bounds become keep's bounds. The
        // dropped set's lists are arena-owned and reclaimed at teardown,
        // so there is nothing to free here.
        if (self.bounds.fetchRemove(drop)) |entry| {
            const dropped = entry.value;
            const target = self.bounds.getPtr(keep).?;
            for (dropped.lower.items) |t| {
                _ = try target.addLower(arena_alloc, t);
            }
            for (dropped.upper.items) |t| {
                _ = try target.addUpper(arena_alloc, t);
            }
            if (dropped.preference == .PushDown) {
                target.preference = .PushDown;
            }
        }
    }

    fn findRoot(self: *const ConstraintSystem, v: InferenceVar) InferenceVar {
        var cur = v;
        while (self.equiv.get(cur)) |parent| {
            cur = parent;
        }
        return cur;
    }

    /// Returns the canonical representative of an inference variable's
    /// equivalence class. Callers use this to rewrite bounds through
    /// the union-find before consulting them.
    pub fn canonical(self: *const ConstraintSystem, v: InferenceVar) InferenceVar {
        return self.findRoot(v);
    }

    /// The last unsatisfied constraint together with its provenance,
    /// for diagnostics.
    pub fn lastError(self: *const ConstraintSystem) ?LastError {
        return self.last_error_val;
    }

    /// Ensures a bound set exists for `v`, creating one if needed.
    fn boundsEntry(self: *ConstraintSystem, v: InferenceVar) Allocator.Error!*BoundSet {
        const a = self.arena();
        const gop = try self.bounds.getOrPut(a, v);
        if (!gop.found_existing) {
            gop.value_ptr.* = try BoundSet.new(a);
        }
        return gop.value_ptr;
    }

    /// Drains the pending pool, applying the reduction rules. Returns the
    /// first inference error encountered, if any (as data). New bounds
    /// can drive incorporation; callers loop reduce / incorporate to a
    /// fixpoint via `solveToFixpoint`.
    pub fn reduce(self: *ConstraintSystem) Allocator.Error!?InferenceError {
        while (self.pending.pop()) |c| {
            const key: SeenKey = .{
                .lhs = try self.intern(c.lhs),
                .rhs = try self.intern(c.rhs),
                .kind = c.kind,
            };
            const gop = try self.seen.getOrPut(self.arena(), key);
            if (gop.found_existing) {
                continue;
            }
            if (try self.reduceOne(c.lhs, c.rhs, c.kind, c.provenance)) |e| {
                return e;
            }
        }
        return null;
    }

    // Single dispatch over resolved type pairs; kept whole so the
    // reduction arms stay together.
    fn reduceOne(
        self: *ConstraintSystem,
        lhs: Type,
        rhs: Type,
        kind: ConstraintKind,
        provenance: Provenance,
    ) Allocator.Error!?InferenceError {
        // Inference variable on either side -> add a bound.
        if (self.isInferenceVar(lhs)) |raw| {
            const v = self.findRoot(raw);
            const bs = try self.boundsEntry(v);
            _ = try bs.addUpper(self.arena(), try self.own(rhs));
            if (kind == .Equality) {
                _ = try bs.addLower(self.arena(), try self.own(rhs));
            }
            return null;
        }
        if (self.isInferenceVar(rhs)) |raw| {
            const v = self.findRoot(raw);
            const bs = try self.boundsEntry(v);
            _ = try bs.addLower(self.arena(), try self.own(lhs));
            if (kind == .Equality) {
                _ = try bs.addUpper(self.arena(), try self.own(lhs));
            }
            return null;
        }
        // Resolved on both sides.
        const result: ?InferenceError = blk: {
            // `S? <: T?` reduces to `S!! <: T` AND `S <: T`. The non-null
            // projection check ensures the underlying types are compatible;
            // the second arm carries the nullability-compatible case.
            if (lhs == .Nullable and rhs == .Nullable) {
                try self.addConstraintWith(lhs.Nullable.*, rhs.Nullable.*, kind, provenance);
                try self.addConstraintWith(lhs.Nullable.nonNull().*, rhs.Nullable.*, kind, provenance);
                break :blk null;
            }
            // Nullable lhs into a non-nullable resolved rhs is a hard fail.
            if (lhs == .Nullable and !rhs.isNullable()) {
                break :blk InferenceError{ .NullableIntoNonNullable = .{
                    .lhs = try self.own(lhs),
                    .rhs = try self.own(rhs),
                } };
            }
            // Intersection on the right: reduce per-component.
            if (rhs == .Intersection) {
                for (rhs.Intersection) |p| {
                    try self.addConstraintWith(lhs, p, kind, provenance);
                }
                break :blk null;
            }
            // Intersection on the left: at least one component must
            // satisfy. We approximate by accepting if any does at the
            // current resolved state.
            if (lhs == .Intersection) {
                for (lhs.Intersection) |p| {
                    if (p.isSubtypeOf(rhs)) break :blk null;
                }
                break :blk InferenceError{ .UnsatisfiableConcrete = .{
                    .lhs = try self.own(lhs),
                    .rhs = try self.own(rhs),
                } };
            }
            // Function on both sides: decompose structurally so an
            // inference variable in a parameter or the return type
            // gets bound. Parameters are contravariant, the return
            // type covariant. A non-suspend function satisfies a
            // `suspend` expectation but not the reverse.
            if (lhs == .Function and rhs == .Function and
                lhs.Function.params.len == rhs.Function.params.len)
            {
                const lf = lhs.Function;
                const rf = rhs.Function;
                if (lf.is_suspend and !rf.is_suspend) {
                    break :blk InferenceError{ .UnsatisfiableConcrete = .{
                        .lhs = try self.own(lhs),
                        .rhs = try self.own(rhs),
                    } };
                }
                for (lf.params, rf.params) |l, r| {
                    // contravariant: expected-param <: actual-param
                    try self.addConstraintWith(r, l, .Subtype, provenance);
                }
                try self.addConstraintWith(lf.return_type.*, rf.return_type.*, .Subtype, provenance);
                break :blk null;
            }
            // Parameterised generic on both sides with the same head:
            // reduce per-argument with variance-aware containment.
            if (lhs == .Generic and rhs == .Generic and
                std.mem.eql(u8, lhs.Generic.name, rhs.Generic.name) and
                lhs.Generic.args.len == rhs.Generic.args.len)
            {
                for (lhs.Generic.args, rhs.Generic.args) |l, r| {
                    if (l.is_star or r.is_star) {
                        continue;
                    }
                    const variance: Variance = vblk: {
                        if (l.variance == .Out or r.variance == .Out) break :vblk .Out;
                        if (l.variance == .In or r.variance == .In) break :vblk .In;
                        break :vblk .Invariant;
                    };
                    switch (variance) {
                        .Out => try self.addConstraintWith(l.ty, r.ty, .Subtype, provenance),
                        .In => try self.addConstraintWith(r.ty, l.ty, .Subtype, provenance),
                        // Both directions — i.e. equality on the type argument.
                        .Invariant => try self.addEquality(l.ty, r.ty, provenance),
                    }
                }
                break :blk null;
            }
            // Pure subtype check between resolved types.
            if (lhs.isSubtypeOf(rhs)) {
                break :blk null;
            }
            break :blk InferenceError{ .UnsatisfiableConcrete = .{
                .lhs = try self.own(lhs),
                .rhs = try self.own(rhs),
            } };
        };
        if (result) |e| {
            self.last_error_val = .{ .err = e, .provenance = provenance };
        }
        return result;
    }

    /// For every variable α with `S <: α` and `α <: T`, derive
    /// `S <: T`. Also derives equalities:
    ///
    /// 1. When the same concrete `S` appears as both an upper and a
    ///    lower bound of α (i.e. `S <: α ∧ α <: S`), record `α ≡ S`.
    /// 2. When two upper bounds on α share a parameterised head
    ///    (e.g. `α <: List<X>` and `α <: List<Int>`), pairwise-
    ///    invariant arguments yield equality constraints
    ///    (`X ≡ Int`). Same for two lower bounds.
    /// 3. Cycles `α <: β <: α` collapse both vars through union-find.
    ///
    /// Repeats until no fresh constraints / bounds are produced.
    pub fn incorporate(self: *ConstraintSystem) Allocator.Error!?InferenceError {
        const Pending = struct { lhs: Type, rhs: Type, kind: ConstraintKind, provenance: Provenance };
        var iterations: u32 = 0;
        while (true) {
            iterations += 1;
            if (iterations > 1024) {
                // Defensive cap. Reduction never invents fresh class
                // symbols, so termination is guaranteed in theory;
                // the cap catches buggy provenance cycles in practice.
                return null;
            }
            var new_constraints: std.ArrayList(Pending) = .empty;
            defer new_constraints.deinit(self.gpa);

            // (1) Classic transitive closure: S <: α ∧ α <: T ⇒ S <: T.
            //     Also: derive equality when the same concrete type
            //     appears as both bounds.
            {
                var it = self.bounds.iterator();
                while (it.next()) |entry| {
                    const v = entry.key_ptr.*;
                    const bs = entry.value_ptr;
                    for (bs.lower.items) |s| {
                        for (bs.upper.items) |t| {
                            try new_constraints.append(self.gpa, .{
                                .lhs = s,
                                .rhs = t,
                                .kind = .Subtype,
                                .provenance = Provenance.derived("incorporate"),
                            });
                        }
                    }
                    // (1a) Equality from same-type bound on both sides.
                    for (bs.lower.items) |s| {
                        if (!isInferenceVarType(s)) {
                            var found = false;
                            for (bs.upper.items) |t| {
                                if (t.eql(s)) {
                                    found = true;
                                    break;
                                }
                            }
                            if (found) {
                                try new_constraints.append(self.gpa, .{
                                    .lhs = .{ .TypeParam = try self.encode(v) },
                                    .rhs = s,
                                    .kind = .Equality,
                                    .provenance = Provenance.derived("equality-same-bound"),
                                });
                            }
                        }
                    }
                }
            }

            // (2) Equality derivation from paired generic bounds.
            //     For each var, pairs of upper or lower bounds sharing
            //     a parameterised head emit per-arg constraints.
            {
                var it = self.bounds.iterator();
                while (it.next()) |entry| {
                    const bs = entry.value_ptr;
                    try pairedGenericArgs(self.gpa, bs.upper.items, &new_constraints);
                    try pairedGenericArgs(self.gpa, bs.lower.items, &new_constraints);
                }
            }

            // (3) Cycle detection: α <: β AND β <: α (both vars).
            const cycles = try self.collectVarCycles();
            defer self.gpa.free(cycles);
            for (cycles) |pair| {
                try self.unionVars(pair[0], pair[1]);
            }

            const before_seen = self.seen.count();
            const before_pending = self.pending.items.len;
            for (new_constraints.items) |nc| {
                try self.addConstraintWith(nc.lhs, nc.rhs, nc.kind, nc.provenance);
            }
            if (self.pending.items.len == 0) {
                break;
            }
            if (try self.reduce()) |e| {
                return e;
            }
            if (self.pending.items.len == before_pending and self.seen.count() == before_seen) {
                break;
            }
        }
        return null;
    }

    /// Returns the arena-owned textual encoding of `v`.
    fn encode(self: *ConstraintSystem, v: InferenceVar) Allocator.Error![]const u8 {
        var it = self.var_names.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == v) {
                return entry.key_ptr.*;
            }
        }
        return std.fmt.allocPrint(self.arena(), "?{d}", .{v.int()});
    }

    fn pairedGenericArgs(
        gpa: Allocator,
        bounds: []const Type,
        out: anytype,
    ) Allocator.Error!void {
        var i: usize = 0;
        while (i < bounds.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < bounds.len) : (j += 1) {
                if (bounds[i] != .Generic or bounds[j] != .Generic) continue;
                const ag = bounds[i].Generic;
                const bg = bounds[j].Generic;
                if (!std.mem.eql(u8, ag.name, bg.name) or ag.args.len != bg.args.len) {
                    continue;
                }
                for (ag.args, bg.args) |l, r| {
                    if (l.is_star or r.is_star) {
                        continue;
                    }
                    if (l.variance == .Invariant and r.variance == .Invariant) {
                        try out.append(gpa, .{
                            .lhs = l.ty,
                            .rhs = r.ty,
                            .kind = .Equality,
                            .provenance = Provenance.derived("incorporate-generic-equality"),
                        });
                    }
                    // Out/Out is a deliberate no-op: the most-specific common
                    // subtype is left to the solver fixation step. Other
                    // combinations are skipped here too.
                }
            }
        }
    }

    /// Returns owned slice of cyclic var pairs; caller frees with `gpa`.
    fn collectVarCycles(self: *const ConstraintSystem) Allocator.Error![][2]InferenceVar {
        var out: std.ArrayList([2]InferenceVar) = .empty;
        errdefer out.deinit(self.gpa);
        var it = self.bounds.iterator();
        while (it.next()) |entry| {
            const av = entry.key_ptr.*;
            const bs_a = entry.value_ptr;
            for (bs_a.upper.items) |t| {
                if (self.isInferenceVar(t)) |bv| {
                    if (self.bounds.getPtr(bv)) |bs_b| {
                        for (bs_b.upper.items) |s| {
                            if (self.isInferenceVar(s)) |sv| {
                                if (sv == av) {
                                    try out.append(self.gpa, .{ av, bv });
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        }
        return out.toOwnedSlice(self.gpa);
    }

    /// Loops reduce + incorporate to a fixpoint.
    pub fn solveToFixpoint(self: *ConstraintSystem) Allocator.Error!?InferenceError {
        while (true) {
            if (try self.reduce()) |e| {
                return e;
            }
            const before = self.seen.count();
            if (try self.incorporate()) |e| {
                return e;
            }
            if (self.seen.count() == before and self.pending.items.len == 0) {
                break;
            }
        }
        return null;
    }

    /// Staged fixation. Builds the dependency graph `α →dep β` (β occurs
    /// in α's bounds), computes SCCs, fixes the variables in reverse
    /// topological order, substituting the resolved type into every
    /// remaining bound before moving on. This is the entry point that
    /// handles postponed variables: order-independent batches are fixed
    /// in parallel inside a stage, and an SCC of mutually-dependent vars
    /// is resolved together by repeated substitution until the fix
    /// points. The returned map and its `Type` values are arena-owned.
    pub fn solveStaged(self: *ConstraintSystem) Allocator.Error!ResolvedMap {
        var vars: std.ArrayList(InferenceVar) = .empty;
        defer vars.deinit(self.gpa);
        {
            var it = self.bounds.keyIterator();
            while (it.next()) |k| {
                try vars.append(self.gpa, k.*);
            }
        }

        var deps = std.AutoHashMap(InferenceVar, []InferenceVar).init(self.gpa);
        defer {
            var dit = deps.valueIterator();
            while (dit.next()) |slc| self.gpa.free(slc.*);
            deps.deinit();
        }
        for (vars.items) |v| {
            var targets: std.ArrayList(InferenceVar) = .empty;
            errdefer targets.deinit(self.gpa);
            const bs = self.bounds.getPtr(v).?;
            for (bs.lower.items) |t| {
                try collectVars(self.gpa, t, &self.var_names, &targets);
            }
            for (bs.upper.items) |t| {
                try collectVars(self.gpa, t, &self.var_names, &targets);
            }
            // Drop self-references, then sort + dedup.
            var k: usize = 0;
            while (k < targets.items.len) {
                if (targets.items[k] == v) {
                    _ = targets.orderedRemove(k);
                } else {
                    k += 1;
                }
            }
            std.mem.sort(InferenceVar, targets.items, {}, lessThanVar);
            const deduped = dedupSorted(targets.items);
            targets.shrinkRetainingCapacity(deduped);
            try deps.put(v, try targets.toOwnedSlice(self.gpa));
        }

        const sccs = try tarjanScc(self.gpa, vars.items, &deps);
        defer {
            for (sccs) |scc| self.gpa.free(scc);
            self.gpa.free(sccs);
        }

        var resolved = ResolvedMap.init(self.gpa);
        // Iterate SCCs in reverse (tarjan emits deepest-deps-first).
        var si: usize = sccs.len;
        while (si > 0) {
            si -= 1;
            const scc = sccs[si];
            // Inside an SCC, iterate: fix each var assuming current
            // substitution of the others; repeat until no var's
            // resolved type changes.
            var changed = true;
            var local_iters: u32 = 0;
            while (changed and local_iters < 64) {
                changed = false;
                for (scc) |v| {
                    // Postponed variables are skipped — the
                    // typechecker will re-feed constraints once the
                    // gating event clears.
                    if (self.bounds.getPtr(v)) |b| {
                        if (b.postponed != null) continue;
                    }
                    const pick = try self.fixVar(v, &resolved);
                    if (resolved.get(v)) |prev| {
                        if (prev.eql(pick)) continue;
                    }
                    try resolved.put(v, pick);
                    changed = true;
                }
                local_iters += 1;
            }
        }
        return resolved;
    }

    fn fixVar(self: *ConstraintSystem, v: InferenceVar, already_resolved: *const ResolvedMap) Allocator.Error!Type {
        const bs = self.bounds.getPtr(v) orelse return .Nothing;
        switch (bs.preference) {
            .PushDown => {
                var uppers: std.ArrayList(Type) = .empty;
                defer uppers.deinit(self.gpa);
                for (bs.upper.items) |t| {
                    const sub = try substituteVars(self.arena(), t, already_resolved, &self.var_names);
                    if (sub == .Nullable and sub.Nullable.* == .Any) continue;
                    if (self.isInferenceVar(sub) != null) continue;
                    try uppers.append(self.gpa, sub);
                }
                if (uppers.items.len == 0) {
                    const any = try self.arena().create(Type);
                    any.* = .Any;
                    return .{ .Nullable = any };
                }
                return Type.intersect(self.arena(), try self.arena().dupe(Type, uppers.items));
            },
            .PullUp => {
                var lowers: std.ArrayList(Type) = .empty;
                defer lowers.deinit(self.gpa);
                for (bs.lower.items) |t| {
                    const sub = try substituteVars(self.arena(), t, already_resolved, &self.var_names);
                    if (sub == .Nothing) continue;
                    if (self.isInferenceVar(sub) != null) continue;
                    try lowers.append(self.gpa, sub);
                }
                if (lowers.items.len == 0) {
                    return .Nothing;
                }
                return lubMany(self.arena(), lowers.items);
            },
        }
    }

    /// Picks a concrete substitution for every inference variable:
    /// push-down → GLB of upper bounds (= their intersection);
    /// pull-up (and default) → LUB of lower bounds. The returned map and
    /// its `Type` values are arena-owned.
    pub fn solve(self: *ConstraintSystem) Allocator.Error!ResolvedMap {
        var out = ResolvedMap.init(self.gpa);
        errdefer out.deinit();
        var it = self.bounds.iterator();
        while (it.next()) |entry| {
            const v = entry.key_ptr.*;
            const bs = entry.value_ptr;
            const candidate: Type = switch (bs.preference) {
                .PushDown => cblk: {
                    var uppers: std.ArrayList(Type) = .empty;
                    defer uppers.deinit(self.gpa);
                    for (bs.upper.items) |t| {
                        if (t == .Nullable and t.Nullable.* == .Any) continue;
                        try uppers.append(self.gpa, t);
                    }
                    if (uppers.items.len == 0) {
                        const any = try self.arena().create(Type);
                        any.* = .Any;
                        break :cblk .{ .Nullable = any };
                    }
                    break :cblk try Type.intersect(self.arena(), try self.arena().dupe(Type, uppers.items));
                },
                .PullUp => cblk: {
                    var lowers: std.ArrayList(Type) = .empty;
                    defer lowers.deinit(self.gpa);
                    for (bs.lower.items) |t| {
                        if (t == .Nothing) continue;
                        try lowers.append(self.gpa, t);
                    }
                    if (lowers.items.len == 0) {
                        break :cblk .Nothing;
                    }
                    break :cblk try lubMany(self.arena(), lowers.items);
                },
            };
            try out.put(v, candidate);
        }
        return out;
    }
};

fn lessThanVar(_: void, a: InferenceVar, b: InferenceVar) bool {
    return a.int() < b.int();
}

/// In-place dedup of an already-sorted slice. Returns the new length.
fn dedupSorted(items: []InferenceVar) usize {
    if (items.len == 0) return 0;
    var w: usize = 1;
    var r: usize = 1;
    while (r < items.len) : (r += 1) {
        if (items[r] != items[w - 1]) {
            items[w] = items[r];
            w += 1;
        }
    }
    return w;
}

/// LUB across a slice of resolved types. Conservative implementation:
/// returns the unique element when all entries are equal; otherwise
/// promotes to a common builtin, and falls back to `Any` / `Any?` for
/// unrelated class types. The result is allocated in `arena`.
pub fn lubMany(arena: Allocator, type_list: []const Type) Allocator.Error!Type {
    if (type_list.len == 0) {
        return .Nothing;
    }
    var any_nullable = false;
    for (type_list) |t| {
        if (t.isNullable()) any_nullable = true;
    }
    var acc = type_list[0].nonNull().*;
    for (type_list[1..]) |t| {
        acc = lubPair(acc, t.nonNull().*);
    }
    if (any_nullable) {
        return acc.asNullable(arena);
    }
    return acc;
}

fn isInferenceVarType(t: Type) bool {
    return switch (t) {
        .TypeParam => |name| name.len > 0 and name[0] == '?',
        else => false,
    };
}

/// Collects all inference variables appearing inside `t`.
fn collectVars(
    gpa: Allocator,
    t: Type,
    var_names: *const NameMap,
    out: *std.ArrayList(InferenceVar),
) Allocator.Error!void {
    switch (t) {
        .TypeParam => |name| {
            if (var_names.get(name)) |id| {
                try out.append(gpa, id);
            }
        },
        .Nullable, .Range => |inner| try collectVars(gpa, inner.*, var_names, out),
        .Function => |f| {
            for (f.params) |p| {
                try collectVars(gpa, p, var_names, out);
            }
            try collectVars(gpa, f.return_type.*, var_names, out);
        },
        .Generic => |g| {
            for (g.args) |a| {
                if (!a.is_star) {
                    try collectVars(gpa, a.ty, var_names, out);
                }
            }
        },
        .Intersection => |parts| {
            for (parts) |p| {
                try collectVars(gpa, p, var_names, out);
            }
        },
        else => {},
    }
}

/// Substitute resolved inference variables inside `t` with their
/// concrete types. Used during staged fixation when prior SCC's
/// variables have already been resolved. The result is arena-owned.
fn substituteVars(
    arena: Allocator,
    t: Type,
    resolved: *const std.AutoHashMap(InferenceVar, Type),
    var_names: *const NameMap,
) Allocator.Error!Type {
    switch (t) {
        .TypeParam => |name| {
            if (var_names.get(name)) |id| {
                if (resolved.get(id)) |r| {
                    return r.clone(arena);
                }
            }
            return t.clone(arena);
        },
        .Nullable => |inner| {
            const boxed = try arena.create(Type);
            boxed.* = try substituteVars(arena, inner.*, resolved, var_names);
            return .{ .Nullable = boxed };
        },
        .Range => |inner| {
            const boxed = try arena.create(Type);
            boxed.* = try substituteVars(arena, inner.*, resolved, var_names);
            return .{ .Range = boxed };
        },
        .Function => |f| {
            const params = try arena.alloc(Type, f.params.len);
            for (f.params, params) |p, *dst| {
                dst.* = try substituteVars(arena, p, resolved, var_names);
            }
            const ret = try arena.create(Type);
            ret.* = try substituteVars(arena, f.return_type.*, resolved, var_names);
            return .{ .Function = .{
                .params = params,
                .return_type = ret,
                .is_suspend = f.is_suspend,
            } };
        },
        .Generic => |g| {
            const args = try arena.alloc(GenericArg, g.args.len);
            for (g.args, args) |a, *dst| {
                if (a.is_star) {
                    dst.* = try a.clone(arena);
                } else {
                    dst.* = .{
                        .variance = a.variance,
                        .is_star = false,
                        .ty = try substituteVars(arena, a.ty, resolved, var_names),
                    };
                }
            }
            return .{ .Generic = .{
                .name = try arena.dupe(u8, g.name),
                .args = args,
            } };
        },
        .Intersection => |parts| {
            const out = try arena.alloc(Type, parts.len);
            for (parts, out) |p, *dst| {
                dst.* = try substituteVars(arena, p, resolved, var_names);
            }
            return .{ .Intersection = out };
        },
        else => return t.clone(arena),
    }
}

/// Mutable working set for `tarjanScc`'s depth-first traversal.
const TarjanState = struct {
    gpa: Allocator,
    idx_of: std.AutoHashMap(InferenceVar, usize),
    lowlink: std.AutoHashMap(InferenceVar, usize),
    on_stack: std.AutoHashMap(InferenceVar, bool),
    stack: std.ArrayList(InferenceVar),
    counter: usize,
    sccs: std.ArrayList([]InferenceVar),

    fn init(gpa: Allocator) TarjanState {
        return .{
            .gpa = gpa,
            .idx_of = std.AutoHashMap(InferenceVar, usize).init(gpa),
            .lowlink = std.AutoHashMap(InferenceVar, usize).init(gpa),
            .on_stack = std.AutoHashMap(InferenceVar, bool).init(gpa),
            .stack = .empty,
            .counter = 0,
            .sccs = .empty,
        };
    }

    fn deinit(self: *TarjanState) void {
        self.idx_of.deinit();
        self.lowlink.deinit();
        self.on_stack.deinit();
        self.stack.deinit(self.gpa);
        // sccs slices are handed to the caller; only free the outer list here
        // if the caller takes the slice. Caller owns the returned slice.
        self.sccs.deinit(self.gpa);
    }

    fn strongConnect(
        self: *TarjanState,
        v: InferenceVar,
        deps: *const std.AutoHashMap(InferenceVar, []InferenceVar),
    ) Allocator.Error!void {
        try self.idx_of.put(v, self.counter);
        try self.lowlink.put(v, self.counter);
        self.counter += 1;
        try self.stack.append(self.gpa, v);
        try self.on_stack.put(v, true);
        if (deps.get(v)) |ns| {
            for (ns) |w| {
                if (!self.idx_of.contains(w)) {
                    try self.strongConnect(w, deps);
                    const lw = self.lowlink.get(w).?;
                    const lv = self.lowlink.get(v).?;
                    try self.lowlink.put(v, @min(lv, lw));
                } else if (self.on_stack.get(w) orelse false) {
                    const iw = self.idx_of.get(w).?;
                    const lv = self.lowlink.get(v).?;
                    try self.lowlink.put(v, @min(lv, iw));
                }
            }
        }
        if (self.lowlink.get(v).? == self.idx_of.get(v).?) {
            var scc: std.ArrayList(InferenceVar) = .empty;
            errdefer scc.deinit(self.gpa);
            while (self.stack.pop()) |w| {
                try self.on_stack.put(w, false);
                try scc.append(self.gpa, w);
                if (w == v) break;
            }
            try self.sccs.append(self.gpa, try scc.toOwnedSlice(self.gpa));
        }
    }
};

/// Tarjan's SCC algorithm over inference variables. Returns the SCCs in
/// topological order (deepest dependencies first), so the staged
/// fixation can fix later batches once their dependencies resolve. The
/// returned slice and each inner slice are owned by `gpa`.
fn tarjanScc(
    gpa: Allocator,
    vars: []const InferenceVar,
    deps: *const std.AutoHashMap(InferenceVar, []InferenceVar),
) Allocator.Error![][]InferenceVar {
    var state = TarjanState.init(gpa);
    defer state.deinit();
    for (vars) |v| {
        if (!state.idx_of.contains(v)) {
            try state.strongConnect(v, deps);
        }
    }
    return state.sccs.toOwnedSlice(gpa);
}

fn lubPair(a: Type, b: Type) Type {
    if (a.eql(b)) {
        return a;
    }
    if (a == .Nothing) {
        return b;
    }
    if (b == .Nothing) {
        return a;
    }
    if (a.isSubtypeOf(b)) {
        return b;
    }
    if (b.isSubtypeOf(a)) {
        return a;
    }
    return .Any;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn nullableOf(arena: Allocator, t: Type) Type {
    const boxed = arena.create(Type) catch unreachable;
    boxed.* = t;
    return .{ .Nullable = boxed };
}

fn invariant(t: Type) GenericArg {
    return .{ .variance = .Invariant, .is_star = false, .ty = t };
}

fn outArg(t: Type) GenericArg {
    return .{ .variance = .Out, .is_star = false, .ty = t };
}

fn prov() Provenance {
    return Provenance.derived("test");
}

test "implicit bounds seeded" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const bs = try BoundSet.new(ar.allocator());
    var has_nothing = false;
    for (bs.lower.items) |t| {
        if (t == .Nothing) has_nothing = true;
    }
    try testing.expect(has_nothing);
    var has_nullable = false;
    for (bs.upper.items) |t| {
        if (t == .Nullable) has_nullable = true;
    }
    try testing.expect(has_nullable);
}

test "fresh var has distinct encoding" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    const a = try cs.fresh("A");
    const b = try cs.fresh("B");
    try testing.expect(!a[1].eql(b[1]));
}

test "reduce records upper bound for lhs var" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    const a = try cs.fresh("A");
    try cs.addConstraint(a[1], .Int);
    try testing.expect((try cs.reduce()) == null);
    const bs = cs.bounds.getPtr(a[0]).?;
    var found = false;
    for (bs.upper.items) |t| {
        if (t == .Int) found = true;
    }
    try testing.expect(found);
}

test "reduce records lower bound for rhs var" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    const a = try cs.fresh("A");
    try cs.addConstraint(.Int, a[1]);
    try testing.expect((try cs.reduce()) == null);
    const bs = cs.bounds.getPtr(a[0]).?;
    var found = false;
    for (bs.lower.items) |t| {
        if (t == .Int) found = true;
    }
    try testing.expect(found);
}

test "reduce resolved satisfied" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    try cs.addConstraint(.Int, .Any);
    try testing.expect((try cs.reduce()) == null);
}

test "reduce resolved unsatisfied" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    try cs.addConstraint(.Int, .String);
    const err = (try cs.reduce()).?;
    try testing.expect(err == .UnsatisfiableConcrete);
}

test "reduce nullable into nonnull fails" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    try cs.addConstraint(nullableOf(ar.allocator(), .Int), .Int);
    try testing.expect((try cs.reduce()) != null);
}

test "reduce intersection rhs fans out" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const inter: Type = .{ .Intersection = try ar.allocator().dupe(Type, &.{ .Int, .Any }) };
    try cs.addConstraint(.Int, inter);
    try testing.expect((try cs.reduce()) == null);
}

test "solve pullup picks lub of lowers" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    const a = try cs.fresh("A");
    try cs.addConstraint(.Int, a[1]);
    try cs.addConstraint(.Int, a[1]);
    try testing.expect((try cs.reduce()) == null);
    var sol = try cs.solve();
    defer sol.deinit();
    try testing.expect(sol.get(a[0]).?.eql(.Int));
}

test "solve pushdown picks glb of uppers" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    const a = try cs.fresh("A");
    cs.setPreference(a[0], .PushDown);
    try cs.addConstraint(a[1], .Int);
    try cs.addConstraint(a[1], .Any);
    try testing.expect((try cs.reduce()) == null);
    var sol = try cs.solve();
    defer sol.deinit();
    try testing.expect(sol.get(a[0]).?.eql(.Int));
}

test "incorporate propagates transitive constraint" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    const a = try cs.fresh("A");
    // Int <: a, a <: Any  => Int <: Any (already true; just check no error).
    try cs.addConstraint(.Int, a[1]);
    try cs.addConstraint(a[1], .Any);
    try testing.expect((try cs.solveToFixpoint()) == null);
}

test "lub pair promotes to any" {
    try testing.expect(lubPair(.Int, .String).eql(.Any));
}

test "lub lifts nullable" {
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try lubMany(a, &.{ .Int, nullableOf(a, .Int) });
    try testing.expect(r.eql(nullableOf(a, .Int)));
}

test "equality records both bounds" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    const a = try cs.fresh("A");
    try cs.addEquality(a[1], .Int, prov());
    try testing.expect((try cs.reduce()) == null);
    const bs = cs.bounds.getPtr(a[0]).?;
    var has_up = false;
    var has_lo = false;
    for (bs.upper.items) |t| {
        if (t == .Int) has_up = true;
    }
    for (bs.lower.items) |t| {
        if (t == .Int) has_lo = true;
    }
    try testing.expect(has_up);
    try testing.expect(has_lo);
}

test "equality unions two vars" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    const a = try cs.fresh("A");
    const b = try cs.fresh("B");
    try cs.addEquality(a[1], b[1], prov());
    // After equality, av and bv point to the same root.
    try testing.expect(cs.canonical(a[0]) == cs.canonical(b[0]));
}

test "nullable subtype emits both arms" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const arn = ar.allocator();
    const a = try cs.fresh("A");
    // (Int? <: A?). The reduction should produce both `Int <: A`
    // and a non-null projection step.
    try cs.addConstraint(nullableOf(arn, .Int), nullableOf(arn, a[1]));
    try testing.expect((try cs.reduce()) == null);
    const bs = cs.bounds.getPtr(a[0]).?;
    var found = false;
    for (bs.lower.items) |t| {
        if (t == .Int) found = true;
    }
    try testing.expect(found);
}

test "parameterised generic invariant produces equality" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const arn = ar.allocator();
    const a = try cs.fresh("A");
    // List<A> <: List<Int> — invariant arg implies A ≡ Int.
    const la: Type = .{ .Generic = .{ .name = "List", .args = try arn.dupe(GenericArg, &.{invariant(a[1])}) } };
    const li: Type = .{ .Generic = .{ .name = "List", .args = try arn.dupe(GenericArg, &.{invariant(.Int)}) } };
    try cs.addConstraint(la, li);
    try testing.expect((try cs.reduce()) == null);
    const bs = cs.bounds.getPtr(a[0]).?;
    var has_lo = false;
    var has_up = false;
    for (bs.lower.items) |t| {
        if (t == .Int) has_lo = true;
    }
    for (bs.upper.items) |t| {
        if (t == .Int) has_up = true;
    }
    try testing.expect(has_lo);
    try testing.expect(has_up);
}

test "parameterised generic out emits subtype only" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const arn = ar.allocator();
    const a = try cs.fresh("A");
    // List<out A> <: List<out Int> — covariant arg implies A <: Int.
    const la: Type = .{ .Generic = .{ .name = "List", .args = try arn.dupe(GenericArg, &.{outArg(a[1])}) } };
    const li: Type = .{ .Generic = .{ .name = "List", .args = try arn.dupe(GenericArg, &.{outArg(.Int)}) } };
    try cs.addConstraint(la, li);
    try testing.expect((try cs.reduce()) == null);
    const bs = cs.bounds.getPtr(a[0]).?;
    var has_up = false;
    var has_lo = false;
    for (bs.upper.items) |t| {
        if (t == .Int) has_up = true;
    }
    for (bs.lower.items) |t| {
        if (t == .Int) has_lo = true;
    }
    try testing.expect(has_up);
    try testing.expect(!has_lo);
}

test "incorporate derives equality from paired generic uppers" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    var ar = std.heap.ArenaAllocator.init(testing.allocator);
    defer ar.deinit();
    const arn = ar.allocator();
    const a = try cs.fresh("A");
    const t = try cs.fresh("T");
    // α <: List<T> and α <: List<Int> — invariant arg implies T ≡ Int.
    const lt: Type = .{ .Generic = .{ .name = "List", .args = try arn.dupe(GenericArg, &.{invariant(t[1])}) } };
    const li: Type = .{ .Generic = .{ .name = "List", .args = try arn.dupe(GenericArg, &.{invariant(.Int)}) } };
    try cs.addConstraint(a[1], lt);
    try cs.addConstraint(a[1], li);
    try testing.expect((try cs.solveToFixpoint()) == null);
    const bs = cs.bounds.getPtr(t[0]).?;
    var has_lo = false;
    var has_up = false;
    for (bs.lower.items) |x| {
        if (x == .Int) has_lo = true;
    }
    for (bs.upper.items) |x| {
        if (x == .Int) has_up = true;
    }
    try testing.expect(has_lo and has_up);
}

test "solve staged fixes dependent vars after independents" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    const a = try cs.fresh("A");
    const b = try cs.fresh("B");
    // A <: Int and B <: A. After fixation A = Int, then B = Int.
    try cs.addConstraint(.Int, a[1]);
    try cs.addConstraint(a[1], b[1]);
    try testing.expect((try cs.solveToFixpoint()) == null);
    var sol = try cs.solveStaged();
    defer sol.deinit();
    try testing.expect(sol.get(a[0]).?.eql(.Int));
    try testing.expect(sol.get(b[0]).?.eql(.Int));
}

test "solve staged handles independent vars in one stage" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    const a = try cs.fresh("A");
    const b = try cs.fresh("B");
    try cs.addConstraint(.Int, a[1]);
    try cs.addConstraint(.String, b[1]);
    try testing.expect((try cs.solveToFixpoint()) == null);
    var sol = try cs.solveStaged();
    defer sol.deinit();
    try testing.expect(sol.get(a[0]).?.eql(.Int));
    try testing.expect(sol.get(b[0]).?.eql(.String));
}

test "incorporate unions cyclic vars" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    const a = try cs.fresh("A");
    const b = try cs.fresh("B");
    try cs.addConstraint(a[1], b[1]);
    try cs.addConstraint(b[1], a[1]);
    try testing.expect((try cs.solveToFixpoint()) == null);
    try testing.expect(cs.canonical(a[0]) == cs.canonical(b[0]));
}

test "postponed var is not fixed by staged solve" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    const a = try cs.fresh("A");
    try cs.addConstraint(.Int, a[1]);
    cs.postpone(a[0], .Eta);
    try testing.expect((try cs.solveToFixpoint()) == null);
    {
        var sol = try cs.solveStaged();
        defer sol.deinit();
        // The postponed var was not fixed — it does not appear in
        // the solution map.
        try testing.expect(!sol.contains(a[0]));
    }
    // Clearing the postponement and re-running fixes it.
    cs.clearPostponed(a[0]);
    var sol2 = try cs.solveStaged();
    defer sol2.deinit();
    try testing.expect(sol2.get(a[0]).?.eql(.Int));
}

test "last error carries provenance" {
    var cs = ConstraintSystem.init(testing.allocator);
    defer cs.deinit();
    try cs.addConstraintWith(
        .Int,
        .String,
        .Subtype,
        .{ .CallSite = .{ .span = Span.init(span.FileId.from(0), 1, 2), .arg_idx = 7 } },
    );
    _ = try cs.reduce();
    const le = cs.lastError().?;
    try testing.expect(le.err == .UnsatisfiableConcrete);
    try testing.expect(le.provenance == .CallSite);
    try testing.expectEqual(@as(usize, 7), le.provenance.CallSite.arg_idx);
}
