//! Kotlin type system.
//!
//! Provides a `Type` enum that models the slice of the Kotlin type system the
//! interpreter currently consumes: the primitive builtins, `Unit`, `Any`,
//! `Nothing`, nullability via `T?`, function types, and integer ranges.
//! Full user-class generics are represented through `Type.Generic`; anything
//! that would require type-parameter machinery we don't yet implement is
//! modeled as `Type.Unresolved`.

const std = @import("std");
const ast = @import("ast");

const Allocator = std.mem.Allocator;

pub const TypeRef = ast.TypeRef;

/// Kotlin type-constraint system: inference variables, bound sets, the
/// constraint pool, and reduction / incorporation / fixation passes.
pub const constraints = @import("constraints.zig");

/// Variance marker on a generic instantiation argument.
pub const Variance = enum {
    Invariant,
    Out,
    In,

    pub const default: Variance = .Invariant;

    pub fn fromAst(v: ast.Variance) Variance {
        return switch (v) {
            .Invariant => .Invariant,
            .Out => .Out,
            .In => .In,
        };
    }
};

/// A single type argument inside a `Type.Generic` instantiation, carrying
/// the use-site projection (`out`/`in`/invariant) so subtyping can apply
/// the right variance per pair.
pub const GenericArg = struct {
    variance: Variance,
    /// `*` star-projection. When true, `ty` is `Type.Any` (read view).
    is_star: bool,
    ty: Type,

    pub fn eql(self: GenericArg, other: GenericArg) bool {
        return self.variance == other.variance and
            self.is_star == other.is_star and
            self.ty.eql(other.ty);
    }

    pub fn clone(self: GenericArg, allocator: Allocator) Allocator.Error!GenericArg {
        return .{
            .variance = self.variance,
            .is_star = self.is_star,
            .ty = try self.ty.clone(allocator),
        };
    }

    pub fn deinit(self: *GenericArg, allocator: Allocator) void {
        self.ty.deinit(allocator);
    }
};

/// The function-type payload of `Type.Function`.
pub const FunctionType = struct {
    params: []Type,
    return_type: *Type,
    /// Distinguishes `suspend (T) -> R` from `(T) -> R`. These are distinct
    /// function types; one is not assignable to the other.
    is_suspend: bool,
    /// The extension receiver's head name for `T.() -> R` shapes; null for
    /// plain function types. Carried so a receiver lambda checked against
    /// this type can bind `this` to the right class.
    receiver_head: ?[]const u8 = null,
};

/// A Kotlin type.
pub const Type = union(enum) {
    Unit,
    Boolean,
    Byte,
    Short,
    Int,
    Long,
    UByte,
    UShort,
    UInt,
    ULong,
    Float,
    Double,
    Char,
    String,
    Any,
    Nothing,
    Nullable: *Type,
    Function: FunctionType,
    Range: *Type,
    /// Reference to a generic type parameter declared on an enclosing
    /// function or class (`T`, `E`, …). Treated as `Unresolved`-compatible
    /// for subtyping unless the checker has a binding.
    TypeParam: []const u8,
    /// Instantiation of a generic class: `Box<Int>`, `List<out Any>`, …
    /// The base name is the simple class name; for builtin instantiations
    /// like `List<Int>` we keep the short name.
    Generic: struct {
        name: []const u8,
        args: []GenericArg,
    },
    /// Intersection of two or more types: `A & B`. The greatest lower bound
    /// of two types is their intersection. Smart-cast composition
    /// (`if (x is A && x is B)`) materializes one. Subtyping:
    /// `T <: A & B` iff `T <: A ∧ T <: B`; `A & B <: T` iff some component
    /// is a subtype of `T`. Intersections are kept normalized (flattened,
    /// no `Any`/`Unresolved`/duplicate components) by `Type.intersect`.
    Intersection: []Type,
    /// A type the resolver could not name. Treated as compatible with
    /// everything for the purposes of error recovery so unrelated errors do
    /// not cascade.
    Unresolved,

    /// Structural equality.
    pub fn eql(self: Type, other: Type) bool {
        if (@as(std.meta.Tag(Type), self) != @as(std.meta.Tag(Type), other)) {
            return false;
        }
        return switch (self) {
            .Unit, .Boolean, .Byte, .Short, .Int, .Long, .UByte, .UShort, .UInt, .ULong, .Float, .Double, .Char, .String, .Any, .Nothing, .Unresolved => true,
            .Nullable => |inner| inner.eql(other.Nullable.*),
            .Range => |inner| inner.eql(other.Range.*),
            .TypeParam => |name| std.mem.eql(u8, name, other.TypeParam),
            .Function => |f| blk: {
                const g = other.Function;
                if (f.is_suspend != g.is_suspend) break :blk false;
                if (f.params.len != g.params.len) break :blk false;
                for (f.params, g.params) |a, b| {
                    if (!a.eql(b)) break :blk false;
                }
                break :blk f.return_type.eql(g.return_type.*);
            },
            .Generic => |gen| blk: {
                const o = other.Generic;
                if (!std.mem.eql(u8, gen.name, o.name)) break :blk false;
                if (gen.args.len != o.args.len) break :blk false;
                for (gen.args, o.args) |a, b| {
                    if (!a.eql(b)) break :blk false;
                }
                break :blk true;
            },
            .Intersection => |parts| blk: {
                const o = other.Intersection;
                if (parts.len != o.len) break :blk false;
                for (parts, o) |a, b| {
                    if (!a.eql(b)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    /// Deep copy. The result owns its heap data; free it with `deinit`.
    pub fn clone(self: Type, allocator: Allocator) Allocator.Error!Type {
        return switch (self) {
            .Unit, .Boolean, .Byte, .Short, .Int, .Long, .UByte, .UShort, .UInt, .ULong, .Float, .Double, .Char, .String, .Any, .Nothing, .Unresolved => self,
            .Nullable => |inner| .{ .Nullable = try boxClone(allocator, inner) },
            .Range => |inner| .{ .Range = try boxClone(allocator, inner) },
            .TypeParam => |name| .{ .TypeParam = try allocator.dupe(u8, name) },
            .Function => |f| .{ .Function = .{
                .params = try cloneSlice(allocator, f.params),
                .return_type = try boxClone(allocator, f.return_type),
                .is_suspend = f.is_suspend,
            } },
            .Generic => |gen| blk: {
                const args = try allocator.alloc(GenericArg, gen.args.len);
                for (gen.args, args) |src, *dst| dst.* = try src.clone(allocator);
                break :blk .{ .Generic = .{
                    .name = try allocator.dupe(u8, gen.name),
                    .args = args,
                } };
            },
            .Intersection => |parts| .{ .Intersection = try cloneSlice(allocator, parts) },
        };
    }

    /// Free heap data owned by this type. A no-op for scalar variants.
    pub fn deinit(self: *Type, allocator: Allocator) void {
        switch (self.*) {
            .Nullable, .Range => |inner| {
                inner.deinit(allocator);
                allocator.destroy(inner);
            },
            .TypeParam => |name| allocator.free(name),
            .Function => |*f| {
                for (f.params) |*p| p.deinit(allocator);
                allocator.free(f.params);
                f.return_type.deinit(allocator);
                allocator.destroy(f.return_type);
            },
            .Generic => |*gen| {
                allocator.free(gen.name);
                for (gen.args) |*a| a.deinit(allocator);
                allocator.free(gen.args);
            },
            .Intersection => |parts| {
                for (parts) |*p| p.deinit(allocator);
                allocator.free(parts);
            },
            else => {},
        }
    }

    /// Strip a single `Nullable` wrapper if present.
    pub fn nonNull(self: *const Type) *const Type {
        return switch (self.*) {
            .Nullable => |inner| inner,
            else => self,
        };
    }

    /// `true` if values of this type can be `null`.
    pub fn isNullable(self: Type) bool {
        return self == .Nullable;
    }

    /// Wrap in `Nullable` unless already nullable. Consumes `self`; on the
    /// already-nullable path it is returned unchanged, so no allocation
    /// happens.
    pub fn asNullable(self: Type, allocator: Allocator) Allocator.Error!Type {
        if (self.isNullable()) return self;
        const boxed = try allocator.create(Type);
        boxed.* = self;
        return .{ .Nullable = boxed };
    }

    /// Intersection constructor with normalization. Flattens nested
    /// intersections, drops `Any` / `Unresolved` (they are no-ops in a
    /// greatest-lower-bound), and removes any component whose supertype is
    /// already present. A single-component result collapses to that
    /// component; an empty intersection collapses to `Any` (the degenerate
    /// identity element).
    ///
    /// Takes ownership of `parts` (both the slice and its elements) and frees
    /// the slice; elements are either moved into the result or freed.
    pub fn intersect(allocator: Allocator, parts: []Type) Allocator.Error!Type {
        var flat: std.ArrayList(Type) = .empty;
        defer flat.deinit(allocator);
        try flat.ensureTotalCapacity(allocator, parts.len);
        for (parts) |p| {
            switch (p) {
                .Intersection => |inner| {
                    // Move the inner components up a level, then free the now
                    // empty intersection slice.
                    try flat.appendSlice(allocator, inner);
                    allocator.free(inner);
                },
                .Any, .Unresolved => {
                    var tmp = p;
                    tmp.deinit(allocator);
                },
                else => try flat.append(allocator, p),
            }
        }
        allocator.free(parts);

        // Drop duplicates and supertypes-of-members.
        var keep: std.ArrayList(Type) = .empty;
        defer keep.deinit(allocator);
        outer: for (flat.items) |t| {
            for (keep.items) |k| {
                if (k.isSubtypeOf(t)) {
                    var tmp = t;
                    tmp.deinit(allocator);
                    continue :outer;
                }
            }
            // Remove kept components that are supertypes of `t`.
            var i: usize = 0;
            while (i < keep.items.len) {
                if (t.isSubtypeOf(keep.items[i])) {
                    var removed = keep.orderedRemove(i);
                    removed.deinit(allocator);
                } else {
                    i += 1;
                }
            }
            try keep.append(allocator, t);
        }

        switch (keep.items.len) {
            0 => return .Any,
            1 => return keep.items[0],
            else => return .{ .Intersection = try keep.toOwnedSlice(allocator) },
        }
    }

    /// Subtyping check covering the rules currently consumed by typeck:
    ///
    /// * `Nothing <: T` for every `T`.
    /// * `T <: T?` for every non-null `T`.
    /// * `Any` is the top of the non-null lattice; `Any?` is the absolute top.
    /// * `Nullable(A) <: Nullable(B)` iff `A <: B`.
    /// * Function types are compared by arity, contravariant params and
    ///   covariant return.
    /// * `Unresolved` is compatible with everything in both directions to
    ///   avoid cascading errors.
    pub fn isSubtypeOf(self: Type, other: Type) bool {
        if (self == .Unresolved or other == .Unresolved) {
            return true;
        }
        // Type parameters act as permissive wildcards at the subtype boundary
        // unless both sides name the same parameter. The constraint solver
        // narrows them when inference runs; outside of inference the checker
        // keeps user code parity-stable.
        if (self == .TypeParam or other == .TypeParam) {
            if (self == .TypeParam and other == .TypeParam) {
                return std.mem.eql(u8, self.TypeParam, other.TypeParam);
            }
            return true;
        }
        if (self.eql(other)) {
            return true;
        }
        if (self == .Nothing) {
            return true;
        }
        // Intersection on the right: must be a subtype of every component.
        if (other == .Intersection) {
            for (other.Intersection) |p| {
                if (!self.isSubtypeOf(p)) return false;
            }
            return true;
        }
        // Intersection on the left: any component being a subtype suffices.
        if (self == .Intersection) {
            for (self.Intersection) |p| {
                if (p.isSubtypeOf(other)) return true;
            }
            return false;
        }
        if (other == .Nullable) {
            return self.nonNull().isSubtypeOf(other.Nullable.*);
        }
        if (self == .Nullable) {
            return false;
        }
        if (other == .Any) {
            return !self.isNullable();
        }
        switch (self) {
            .Function => |lf| {
                if (other != .Function) return false;
                const rf = other.Function;
                // Suspending and non-suspending function types are distinct;
                // neither is a subtype of the other. (Passing a *lambda
                // literal* to a `suspend` parameter is a separate
                // assignability conversion handled at the call site, not
                // general subtyping.)
                if (lf.is_suspend != rf.is_suspend) return false;
                if (lf.params.len != rf.params.len) return false;
                for (lf.params, rf.params) |l, r| {
                    if (!r.isSubtypeOf(l)) return false;
                }
                return lf.return_type.isSubtypeOf(rf.return_type.*);
            },
            .Range => |a| {
                if (other != .Range) return false;
                return a.isSubtypeOf(other.Range.*);
            },
            .Generic => |ag| {
                if (other != .Generic) return false;
                const bg = other.Generic;
                if (!std.mem.eql(u8, ag.name, bg.name) or ag.args.len != bg.args.len) {
                    return false;
                }
                for (ag.args, bg.args) |l, r| {
                    if (l.is_star or r.is_star) continue;
                    const variance: Variance = blk: {
                        if (l.variance == .Out or r.variance == .Out) break :blk .Out;
                        if (l.variance == .In or r.variance == .In) break :blk .In;
                        break :blk .Invariant;
                    };
                    const ok = switch (variance) {
                        .Out => l.ty.isSubtypeOf(r.ty),
                        .In => r.ty.isSubtypeOf(l.ty),
                        // Type parameters and unresolved slots stay
                        // permissive wildcards inside type-argument lists,
                        // matching the top-level rule above.
                        .Invariant => l.ty.eql(r.ty) or
                            l.ty == .TypeParam or r.ty == .TypeParam or
                            l.ty == .Unresolved or r.ty == .Unresolved,
                    };
                    if (!ok) return false;
                }
                return true;
            },
            else => return false,
        }
    }

    pub fn format(self: Type, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .Unit => try writer.writeAll("Unit"),
            .Boolean => try writer.writeAll("Boolean"),
            .Byte => try writer.writeAll("Byte"),
            .Short => try writer.writeAll("Short"),
            .Int => try writer.writeAll("Int"),
            .Long => try writer.writeAll("Long"),
            .UByte => try writer.writeAll("UByte"),
            .UShort => try writer.writeAll("UShort"),
            .UInt => try writer.writeAll("UInt"),
            .ULong => try writer.writeAll("ULong"),
            .Float => try writer.writeAll("Float"),
            .Double => try writer.writeAll("Double"),
            .Char => try writer.writeAll("Char"),
            .String => try writer.writeAll("String"),
            .Any => try writer.writeAll("Any"),
            .Nothing => try writer.writeAll("Nothing"),
            .Nullable => |inner| try writer.print("{f}?", .{inner.*}),
            .Function => |f| {
                if (f.is_suspend) try writer.writeAll("suspend ");
                try writer.writeAll("(");
                for (f.params, 0..) |p, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print("{f}", .{p});
                }
                try writer.print(") -> {f}", .{f.return_type.*});
            },
            .Range => |inner| try writer.print("Range<{f}>", .{inner.*}),
            .TypeParam => |name| try writer.writeAll(name),
            .Generic => |gen| {
                try writer.writeAll(gen.name);
                try writer.writeAll("<");
                for (gen.args, 0..) |a, i| {
                    if (i > 0) try writer.writeAll(", ");
                    if (a.is_star) {
                        try writer.writeAll("*");
                    } else {
                        switch (a.variance) {
                            .Out => try writer.writeAll("out "),
                            .In => try writer.writeAll("in "),
                            .Invariant => {},
                        }
                        try writer.print("{f}", .{a.ty});
                    }
                }
                try writer.writeAll(">");
            },
            .Intersection => |parts| {
                for (parts, 0..) |p, i| {
                    if (i > 0) try writer.writeAll(" & ");
                    try writer.print("{f}", .{p});
                }
            },
            .Unresolved => try writer.writeAll("<unresolved>"),
        }
    }

    /// Render to an owned string. Caller frees the result.
    pub fn toString(self: Type, allocator: Allocator) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        self.format(&aw.writer) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }
};

fn boxClone(allocator: Allocator, src: *const Type) Allocator.Error!*Type {
    const out = try allocator.create(Type);
    out.* = try src.clone(allocator);
    return out;
}

fn cloneSlice(allocator: Allocator, src: []const Type) Allocator.Error![]Type {
    const out = try allocator.alloc(Type, src.len);
    for (src, out) |s, *d| d.* = try s.clone(allocator);
    return out;
}

/// Errors produced by the typing utilities. These are data, not Zig errors.
pub const TypeError = union(enum) {
    UnknownType: []const u8,
    Mismatch: struct { lhs: Type, rhs: Type },

    pub fn deinit(self: *TypeError, allocator: Allocator) void {
        switch (self.*) {
            .UnknownType => {},
            .Mismatch => |*m| {
                m.lhs.deinit(allocator);
                m.rhs.deinit(allocator);
            },
        }
    }
};

/// `union(enum)` result for the typing utilities: a `Type` on success or a
/// `TypeError` data value on failure.
pub const TypeResult = union(enum) {
    ok: Type,
    err: TypeError,

    pub fn isOk(self: TypeResult) bool {
        return self == .ok;
    }
};

/// Look up a builtin by short name (`Int`) or fully qualified name
/// (`kotlin.Int`). Returns `null` if unknown.
pub fn builtinByName(name: []const u8) ?Type {
    const short = if (std.mem.startsWith(u8, name, "kotlin."))
        name["kotlin.".len..]
    else
        name;
    const map = .{
        .{ "Unit", Type.Unit },
        .{ "Boolean", Type.Boolean },
        .{ "Byte", Type.Byte },
        .{ "Short", Type.Short },
        .{ "Int", Type.Int },
        .{ "Long", Type.Long },
        .{ "UByte", Type.UByte },
        .{ "UShort", Type.UShort },
        .{ "UInt", Type.UInt },
        .{ "ULong", Type.ULong },
        .{ "Float", Type.Float },
        .{ "Double", Type.Double },
        .{ "Char", Type.Char },
        .{ "String", Type.String },
        .{ "Any", Type.Any },
        .{ "Nothing", Type.Nothing },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, short, entry[0])) return entry[1];
    }
    return null;
}

/// Convert an AST `TypeRef` into a `Type`. Unknown names yield an error.
pub fn convertTypeRef(allocator: Allocator, t: *const TypeRef) Allocator.Error!TypeResult {
    if (builtinByName(t.name.name)) |ty| {
        const out = if (t.nullable) try ty.asNullable(allocator) else ty;
        return .{ .ok = out };
    }
    return .{ .err = .{ .UnknownType = try allocator.dupe(u8, t.name.name) } };
}

/// Like `convertTypeRef` but returns `Type.Unresolved` for unknown names.
///
/// User-defined generic types (`Box<T>`, `Producer<T>`, …) are kept as
/// `Type.Unresolved` so subtyping stays permissive; variance and bound
/// enforcement happens declaration-side in the type checker. The
/// `Type.Generic` form is reserved for cases where the checker explicitly
/// builds it (e.g. for declaration-aware variance composition in a future
/// pass).
pub fn convertTypeRefLossy(allocator: Allocator, t: *const TypeRef) Allocator.Error!Type {
    if (std.mem.eql(u8, t.name.name, "*")) {
        return .Any;
    }
    if (t.function) |ft| {
        const params = try allocator.alloc(Type, ft.params.len);
        for (ft.params, params) |*p, *out| out.* = try convertTypeRefLossy(allocator, p);
        const ret = try allocator.create(Type);
        ret.* = try convertTypeRefLossy(allocator, &ft.ret);
        const func: Type = .{ .Function = .{
            .params = params,
            .return_type = ret,
            .is_suspend = ft.is_suspend,
        } };
        return if (t.nullable) try func.asNullable(allocator) else func;
    }
    const base: Type = builtinByName(t.name.name) orelse .Unresolved;
    return if (t.nullable) try base.asNullable(allocator) else base;
}

/// Unify two concrete types. With no generics, unification is structural
/// equality with `Unresolved` acting as a wildcard. The result owns its heap
/// data; on error the returned `TypeError` owns clones of the mismatched
/// operands.
pub fn unify(allocator: Allocator, lhs: *const Type, rhs: *const Type) Allocator.Error!TypeResult {
    if (lhs.* == .Unresolved) {
        return .{ .ok = try rhs.clone(allocator) };
    }
    if (rhs.* == .Unresolved) {
        return .{ .ok = try lhs.clone(allocator) };
    }
    if (lhs.eql(rhs.*)) {
        return .{ .ok = try lhs.clone(allocator) };
    }
    if (lhs.* == .Nullable and rhs.* == .Nullable) {
        const inner = try unify(allocator, lhs.Nullable, rhs.Nullable);
        switch (inner) {
            .ok => |ty| {
                const boxed = try allocator.create(Type);
                boxed.* = ty;
                return .{ .ok = .{ .Nullable = boxed } };
            },
            .err => return inner,
        }
    }
    if (lhs.* == .Function and rhs.* == .Function) {
        const lf = lhs.Function;
        const rf = rhs.Function;
        if (lf.params.len == rf.params.len and lf.is_suspend == rf.is_suspend) {
            var params: std.ArrayList(Type) = .empty;
            errdefer {
                for (params.items) |*p| p.deinit(allocator);
                params.deinit(allocator);
            }
            try params.ensureTotalCapacity(allocator, lf.params.len);
            for (lf.params, rf.params) |*a, *b| {
                const r = try unify(allocator, a, b);
                switch (r) {
                    .ok => |ty| try params.append(allocator, ty),
                    .err => |e| {
                        for (params.items) |*p| p.deinit(allocator);
                        params.deinit(allocator);
                        return .{ .err = e };
                    },
                }
            }
            const ret_res = try unify(allocator, lf.return_type, rf.return_type);
            switch (ret_res) {
                .ok => |rt| {
                    const boxed = try allocator.create(Type);
                    boxed.* = rt;
                    return .{ .ok = .{ .Function = .{
                        .params = try params.toOwnedSlice(allocator),
                        .return_type = boxed,
                        .is_suspend = lf.is_suspend,
                    } } };
                },
                .err => |e| {
                    for (params.items) |*p| p.deinit(allocator);
                    params.deinit(allocator);
                    return .{ .err = e };
                },
            }
        }
    }
    if (lhs.* == .Range and rhs.* == .Range) {
        const inner = try unify(allocator, lhs.Range, rhs.Range);
        switch (inner) {
            .ok => |ty| {
                const boxed = try allocator.create(Type);
                boxed.* = ty;
                return .{ .ok = .{ .Range = boxed } };
            },
            .err => return inner,
        }
    }
    return .{ .err = .{ .Mismatch = .{
        .lhs = try lhs.clone(allocator),
        .rhs = try rhs.clone(allocator),
    } } };
}

const testing = std.testing;
const span = @import("span");

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

// Typed scalar `Type` values for tests. A bare `Type.Int` denotes the union's
// tag, not a `Type` value, so these give methods a real receiver and an
// address for the `*const Type` parameters.
const t_int: Type = .Int;
const t_string: Type = .String;
const t_unresolved: Type = .Unresolved;
const t_nothing: Type = .Nothing;

fn ident(name: []const u8) ast.Ident {
    return .{
        .name = name,
        .span = span.Span.init(span.FileId.from(0), 0, @intCast(name.len)),
    };
}

fn typeRef(name: []const u8, nullable: bool) TypeRef {
    return .{
        .name = ident(name),
        .nullable = nullable,
        .span = span.Span.init(span.FileId.from(0), 0, 0),
        .type_args = &.{},
        .function = null,
        .definitely_non_null = false,
        .annotations = &.{},
        .qualified_path = null,
    };
}

fn box(a: Allocator, t: Type) *Type {
    const p = a.create(Type) catch unreachable;
    p.* = t;
    return p;
}

fn nullableOf(a: Allocator, t: Type) Type {
    return .{ .Nullable = box(a, t) };
}

fn expectRenders(t: Type, expected: []const u8) !void {
    var ar = arena();
    defer ar.deinit();
    const s = try t.toString(ar.allocator());
    try testing.expectEqualStrings(expected, s);
}

test "builtin lookup short names" {
    const cases = .{
        .{ "Unit", Type.Unit },
        .{ "Boolean", Type.Boolean },
        .{ "Byte", Type.Byte },
        .{ "Short", Type.Short },
        .{ "Int", Type.Int },
        .{ "Long", Type.Long },
        .{ "Float", Type.Float },
        .{ "Double", Type.Double },
        .{ "Char", Type.Char },
        .{ "String", Type.String },
        .{ "Any", Type.Any },
        .{ "Nothing", Type.Nothing },
    };
    inline for (cases) |c| {
        try testing.expect(builtinByName(c[0]).?.eql(c[1]));
    }
}

test "builtin lookup fqn" {
    try testing.expect(builtinByName("kotlin.Int").?.eql(.Int));
    try testing.expect(builtinByName("kotlin.String").?.eql(.String));
}

test "builtin lookup unknown" {
    try testing.expect(builtinByName("Banana") == null);
    try testing.expect(builtinByName("kotlin.collections.List") == null);
}

test "display renders types" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectRenders(.Int, "Int");
    try expectRenders(nullableOf(a, .Int), "Int?");
    const f = Type{ .Function = .{
        .params = try a.dupe(Type, &.{ .Int, .String }),
        .return_type = box(a, .Boolean),
        .is_suspend = false,
    } };
    try expectRenders(f, "(Int, String) -> Boolean");
    const s = Type{ .Function = .{
        .params = try a.dupe(Type, &.{.Int}),
        .return_type = box(a, .Boolean),
        .is_suspend = true,
    } };
    try expectRenders(s, "suspend (Int) -> Boolean");
    try expectRenders(.{ .Range = box(a, .Int) }, "Range<Int>");
}

test "nothing is bottom of everything" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const cases = [_]Type{
        .Int,
        .String,
        .Any,
        nullableOf(a, .Int),
        nullableOf(a, .Any),
    };
    for (cases) |t| {
        try testing.expect(t_nothing.isSubtypeOf(t));
    }
}

test "any is top of non-null lattice" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expect(t_int.isSubtypeOf(.Any));
    try testing.expect(t_string.isSubtypeOf(.Any));
    try testing.expect(!nullableOf(a, .Int).isSubtypeOf(.Any));
    try testing.expect(nullableOf(a, .Int).isSubtypeOf(nullableOf(a, .Any)));
}

test "non null promotes to nullable" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try testing.expect(t_int.isSubtypeOf(nullableOf(a, .Int)));
    try testing.expect(!nullableOf(a, .Int).isSubtypeOf(.Int));
}

test "function subtyping is variance aware" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const id_int = Type{ .Function = .{
        .params = try a.dupe(Type, &.{.Int}),
        .return_type = box(a, .Int),
        .is_suspend = false,
    } };
    const id_any_in_int_out = Type{ .Function = .{
        .params = try a.dupe(Type, &.{.Any}),
        .return_type = box(a, .Int),
        .is_suspend = false,
    } };
    try testing.expect(id_any_in_int_out.isSubtypeOf(id_int));
    try testing.expect(!id_int.isSubtypeOf(id_any_in_int_out));
    // Suspending and non-suspending function types are distinct; neither is a
    // subtype of the other.
    const id_int_susp = Type{ .Function = .{
        .params = try a.dupe(Type, &.{.Int}),
        .return_type = box(a, .Int),
        .is_suspend = true,
    } };
    try testing.expect(!id_int.isSubtypeOf(id_int_susp));
    try testing.expect(!id_int_susp.isSubtypeOf(id_int));
}

test "unresolved is compatible everywhere" {
    try testing.expect(t_unresolved.isSubtypeOf(.Int));
    try testing.expect(t_int.isSubtypeOf(.Unresolved));
}

test "unify identical returns input" {
    var ar = arena();
    defer ar.deinit();
    const r = try unify(ar.allocator(), &t_int, &t_int);
    try testing.expect(r.isOk());
    try testing.expect(r.ok.eql(.Int));
}

test "unify incompatible errors" {
    var ar = arena();
    defer ar.deinit();
    const r = try unify(ar.allocator(), &t_int, &t_string);
    try testing.expect(r == .err);
    try testing.expect(r.err == .Mismatch);
}

test "unify with unresolved picks concrete" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const r1 = try unify(a, &t_unresolved, &t_int);
    try testing.expect(r1.ok.eql(.Int));
    const r2 = try unify(a, &t_int, &t_unresolved);
    try testing.expect(r2.ok.eql(.Int));
}

test "unify nested function types" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const lhs = Type{ .Function = .{
        .params = try a.dupe(Type, &.{.Int}),
        .return_type = box(a, .Unresolved),
        .is_suspend = false,
    } };
    const rhs = Type{ .Function = .{
        .params = try a.dupe(Type, &.{.Int}),
        .return_type = box(a, .String),
        .is_suspend = false,
    } };
    const r = try unify(a, &lhs, &rhs);
    try testing.expect(r.isOk());
    const expected = Type{ .Function = .{
        .params = try a.dupe(Type, &.{.Int}),
        .return_type = box(a, .String),
        .is_suspend = false,
    } };
    try testing.expect(r.ok.eql(expected));
}

test "convert type ref known and nullable" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const t1 = typeRef("Int", false);
    const r1 = try convertTypeRef(a, &t1);
    try testing.expect(r1.ok.eql(.Int));
    const t2 = typeRef("Int", true);
    const r2 = try convertTypeRef(a, &t2);
    try testing.expect(r2.ok.eql(nullableOf(a, .Int)));
}

test "convert type ref unknown errors" {
    var ar = arena();
    defer ar.deinit();
    const t = typeRef("Widget", false);
    const r = try convertTypeRef(ar.allocator(), &t);
    try testing.expect(r == .err);
    try testing.expect(r.err == .UnknownType);
    try testing.expectEqualStrings("Widget", r.err.UnknownType);
}

test "convert type ref lossy falls back to unresolved" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const t1 = typeRef("Widget", false);
    const r1 = try convertTypeRefLossy(a, &t1);
    try testing.expect(r1.eql(.Unresolved));
    const t2 = typeRef("Int", true);
    const r2 = try convertTypeRefLossy(a, &t2);
    try testing.expect(r2.eql(nullableOf(a, .Int)));
}

test "intersect drops any and unresolved" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const parts = try a.dupe(Type, &.{ .Int, .Any, .Unresolved });
    const r = try Type.intersect(a, parts);
    try testing.expect(r.eql(.Int));
}

test "intersect flattens nested" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const inner = try Type.intersect(a, try a.dupe(Type, &.{ .Int, .String }));
    const outer = try Type.intersect(a, try a.dupe(Type, &.{ inner, .Boolean }));
    try testing.expect(outer == .Intersection);
    try testing.expectEqual(@as(usize, 3), outer.Intersection.len);
}

test "intersect drops supertype components" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const r = try Type.intersect(a, try a.dupe(Type, &.{ .Int, .Any }));
    try testing.expect(r.eql(.Int));
}

test "intersect subtype must satisfy every part" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const i = try Type.intersect(a, try a.dupe(Type, &.{ .Int, nullableOf(a, .Int) }));
    // Int <: Int & Int? (both parts satisfied)
    try testing.expect(t_int.isSubtypeOf(i));
}

test "intersect left any part suffices for supertype" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const i = Type{ .Intersection = try a.dupe(Type, &.{ .Int, .String }) };
    try testing.expect(i.isSubtypeOf(.Any));
}

test "intersect display" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const i = Type{ .Intersection = try a.dupe(Type, &.{ .Int, .String }) };
    try expectRenders(i, "Int & String");
}

test "as nullable is idempotent" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const t = try t_int.asNullable(a);
    const t2 = try t.asNullable(a);
    try testing.expect(t2.eql(t));
}

test {
    testing.refAllDecls(constraints);
}


/// Declarations the checker cannot see in source because they arrived as a
/// prebuilt image (the stdlib-image path hands over a built module and never
/// parses pack sources). Published by the image loader before the eager pass,
/// consumed once by `typecheckModule`.
pub const ExternDecls = struct {
    classes: std.StringHashMap(void),
    fn_return_class: std.StringHashMap([]const u8),
};

pub var pending_extern_decls: ?ExternDecls = null;
