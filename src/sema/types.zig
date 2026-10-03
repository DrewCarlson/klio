//! Types by identity. A class type names its class symbol, a type-parameter
//! type names its parameter symbol, and every type is interned, so two
//! `TypeId`s are equal exactly when the types are.
//!
//! Function types are class types of the `kotlin.FunctionN` family (and
//! `SuspendFunctionN`), with `attrs` recording an extension receiver or
//! context parameters, the way the compiler itself represents them. That
//! keeps subtyping and substitution uniform over every class type.

const std = @import("std");

const symbols_mod = @import("symbols.zig");

const Allocator = std.mem.Allocator;
const Sym = symbols_mod.Sym;

pub const TypeId = enum(u32) {
    none = 0,
    _,

    pub fn int(self: TypeId) u32 {
        return @intFromEnum(self);
    }
    pub fn from(i: u32) TypeId {
        return @enumFromInt(i);
    }
};

pub const Variance = enum(u2) { inv, out, in, star };

pub const Arg = struct {
    variance: Variance,
    /// `.none` for a star projection.
    ty: TypeId,
};

pub const Attrs = packed struct(u8) {
    /// `A.() -> B`: the first type argument is the receiver.
    ext_fn: bool = false,
    /// `@Composable` on a function type.
    composable: bool = false,
    /// Leading `context(A, B)` parameters of a function type.
    context_count: u4 = 0,
    _pad: u2 = 0,
};

pub const ClassType = struct {
    sym: Sym,
    args: []const Arg,
    nullable: bool,
    attrs: Attrs = .{},
};

pub const ParamType = struct {
    sym: Sym,
    nullable: bool,
    /// `T & Any`.
    dnn: bool = false,
};

/// The type of an integer literal before an expected type picks one: the
/// set of integral types the value fits.
pub const IntLit = packed struct(u8) {
    int: bool = false,
    long: bool = false,
    short: bool = false,
    byte: bool = false,
    uint: bool = false,
    ulong: bool = false,
    ushort: bool = false,
    ubyte: bool = false,
};

pub const Type = union(enum) {
    /// Index 0; never produced.
    none,
    class: ClassType,
    param: ParamType,
    intersection: []const TypeId,
    int_lit: IntLit,
    /// An inference variable of a constraint system; `T?` opened is the
    /// variable with `nullable` set.
    variable: Var,
    /// A reference the analysis could not resolve. Compatible with every
    /// type, so one missing declaration reports once, and counted by the
    /// census wherever it is produced.
    err,
};

/// `nullable`: `V?`. `dnn`: `V & Any`, the variable's non-null part, which
/// a fixed `V` makes definitely not null.
pub const Var = struct { id: u32, nullable: bool = false, dnn: bool = false };

pub const Subst = std.AutoHashMapUnmanaged(Sym, TypeId);

/// The intern map's context: an id hashes and compares as the type it
/// names.
const Interning = struct {
    items: []const Type,

    pub fn hash(self: Interning, id: TypeId) u64 {
        return hashType(self.items[id.int()]);
    }

    pub fn eql(_: Interning, a: TypeId, b: TypeId) bool {
        return a == b;
    }
};

/// Looks a type up in the intern map by its structure.
const Probe = struct {
    items: []const Type,

    pub fn hash(_: Probe, t: Type) u64 {
        return hashType(t);
    }

    pub fn eql(self: Probe, t: Type, id: TypeId) bool {
        return typeEql(t, self.items[id.int()]);
    }
};

/// A type's hash in the intern map: each of its words mixed in, then the
/// whole spread over every bit, since the map takes a slot from the low
/// bits and a tag from the high ones. The map is only probed, never walked,
/// so nothing depends on the order the hash gives.
fn hashType(t: Type) u64 {
    var h: u64 = @intFromEnum(std.meta.activeTag(t));
    switch (t) {
        .none, .err => {},
        .class => |c| {
            h = mixWord(h, @as(u64, c.sym.int()) << 16 | @as(u64, @intFromBool(c.nullable)) << 8 | @as(u8, @bitCast(c.attrs)));
            for (c.args) |arg| h = mixWord(h, @as(u64, arg.ty.int()) << 2 | @intFromEnum(arg.variance));
        },
        .param => |p| h = mixWord(h, @as(u64, p.sym.int()) << 2 | @as(u64, @intFromBool(p.nullable)) << 1 | @intFromBool(p.dnn)),
        .intersection => |parts| for (parts) |x| {
            h = mixWord(h, x.int());
        },
        .int_lit => |l| h = mixWord(h, @as(u8, @bitCast(l))),
        .variable => |v| h = mixWord(h, @as(u64, v.id) << 2 | @as(u64, @intFromBool(v.nullable)) << 1 | @intFromBool(v.dnn)),
    }
    h ^= h >> 33;
    h *%= 0xff51afd7ed558ccd;
    h ^= h >> 33;
    h *%= 0xc4ceb9fe1a85ec53;
    h ^= h >> 33;
    return h;
}

inline fn mixWord(h: u64, w: u64) u64 {
    return std.math.rotl(u64, (h ^ w) *% 0x9e3779b97f4a7c15, 31);
}

fn typeEql(a: Type, b: Type) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .none, .err => true,
        .class => |x| blk: {
            const y = b.class;
            if (x.sym != y.sym or x.nullable != y.nullable or @as(u8, @bitCast(x.attrs)) != @as(u8, @bitCast(y.attrs)) or x.args.len != y.args.len) break :blk false;
            for (x.args, y.args) |p, q| if (p.variance != q.variance or p.ty != q.ty) break :blk false;
            break :blk true;
        },
        .param => |x| x.sym == b.param.sym and x.nullable == b.param.nullable and x.dnn == b.param.dnn,
        .intersection => |x| std.mem.eql(TypeId, x, b.intersection),
        .int_lit => |x| @as(u8, @bitCast(x)) == @as(u8, @bitCast(b.int_lit)),
        .variable => |x| x.id == b.variable.id and x.nullable == b.variable.nullable and x.dnn == b.variable.dnn,
    };
}

/// Room for the parts of a type about to be interned, which copies them:
/// on the stack for up to 16, else from `fallback`. One `get`, one `free`.
pub fn PartsBuf(comptime T: type) type {
    return struct {
        stack: [16]T = undefined,
        fallback: Allocator,

        const Self = @This();

        pub fn init(fallback: Allocator) Self {
            return .{ .fallback = fallback };
        }

        pub fn get(self: *Self, n: usize) Allocator.Error![]T {
            if (n <= self.stack.len) return self.stack[0..n];
            return self.fallback.alloc(T, n);
        }

        pub fn free(self: *Self, xs: []T) void {
            if (xs.len > self.stack.len) self.fallback.free(xs);
        }
    };
}

pub const ArgBuf = PartsBuf(Arg);
pub const TypeBuf = PartsBuf(TypeId);

pub const TypeStore = struct {
    arena: Allocator,
    items: std.ArrayList(Type) = .empty,
    /// Every type by its structure: the map holds ids, and hashes and
    /// compares the types they name (`Interning`).
    intern_map: std.HashMapUnmanaged(TypeId, void, Interning, 80) = .empty,
    err_id: TypeId = .none,

    pub fn init(arena: Allocator) Allocator.Error!TypeStore {
        var ts = TypeStore{ .arena = arena };
        try ts.items.append(arena, .none);
        ts.err_id = try ts.intern(.err);
        return ts;
    }

    /// A store holding `items` as a store that interned them would: a base
    /// image's types, read back.
    pub fn fromItems(arena: Allocator, items: std.ArrayList(Type), err_id: TypeId) Allocator.Error!TypeStore {
        var ts = TypeStore{ .arena = arena, .items = items, .err_id = err_id };
        try ts.intern_map.ensureTotalCapacityContext(arena, @intCast(items.items.len), ts.interning());
        for (1..items.items.len) |i| ts.intern_map.putAssumeCapacityNoClobberContext(TypeId.from(@intCast(i)), {}, ts.interning());
        return ts;
    }

    /// Room for `extra` more types: a table regrown to them rehashes
    /// every type it holds.
    pub fn reserve(self: *TypeStore, extra: usize) Allocator.Error!void {
        try self.items.ensureUnusedCapacity(self.arena, extra);
        try self.intern_map.ensureUnusedCapacityContext(self.arena, @intCast(extra), self.interning());
    }

    pub fn get(self: *const TypeStore, t: TypeId) Type {
        return self.items.items[t.int()];
    }

    pub fn errType(self: *const TypeStore) TypeId {
        return self.err_id;
    }

    pub fn isErr(self: *const TypeStore, t: TypeId) bool {
        return t == self.err_id;
    }

    fn interning(self: *const TypeStore) Interning {
        return .{ .items = self.items.items };
    }

    pub fn intern(self: *TypeStore, t: Type) Allocator.Error!TypeId {
        const gop = try self.intern_map.getOrPutContextAdapted(self.arena, t, Probe{ .items = self.items.items }, self.interning());
        if (gop.found_existing) return gop.key_ptr.*;
        const stored: Type = switch (t) {
            .class => |c| .{ .class = .{ .sym = c.sym, .args = try self.arena.dupe(Arg, c.args), .nullable = c.nullable, .attrs = c.attrs } },
            .intersection => |parts| .{ .intersection = try self.arena.dupe(TypeId, parts) },
            else => t,
        };
        const id = TypeId.from(@intCast(self.items.items.len));
        // The slot is claimed; the id it names must exist before the map
        // hashes it again (a later growth rehashes every id).
        gop.key_ptr.* = id;
        try self.items.append(self.arena, stored);
        return id;
    }

    pub fn class(self: *TypeStore, sym: Sym, args: []const Arg, nullable: bool) Allocator.Error!TypeId {
        return self.intern(.{ .class = .{ .sym = sym, .args = args, .nullable = nullable } });
    }

    pub fn classAttrs(self: *TypeStore, sym: Sym, args: []const Arg, nullable: bool, attrs: Attrs) Allocator.Error!TypeId {
        return self.intern(.{ .class = .{ .sym = sym, .args = args, .nullable = nullable, .attrs = attrs } });
    }

    pub fn param(self: *TypeStore, sym: Sym, nullable: bool) Allocator.Error!TypeId {
        return self.intern(.{ .param = .{ .sym = sym, .nullable = nullable } });
    }

    pub fn isNullable(self: *const TypeStore, t: TypeId) bool {
        return switch (self.get(t)) {
            .class => |c| c.nullable,
            .param => |p| p.nullable,
            .variable => |v| v.nullable,
            // Null is below an intersection whose every part admits it
            // (`Int? & Nothing?` for an `Int?` known to be null).
            .intersection => |parts| for (parts) |p| {
                if (!self.isNullable(p)) break false;
            } else parts.len != 0,
            else => false,
        };
    }

    /// `t?`.
    pub fn makeNullable(self: *TypeStore, t: TypeId) Allocator.Error!TypeId {
        return self.withNullability(t, true);
    }

    /// `t` without its `?`. For a type parameter this is the plain `T`, not
    /// `T & Any`, which `definitelyNotNull` builds.
    pub fn makeNotNull(self: *TypeStore, t: TypeId) Allocator.Error!TypeId {
        return self.withNullability(t, false);
    }

    pub fn withNullability(self: *TypeStore, t: TypeId, nullable: bool) Allocator.Error!TypeId {
        return switch (self.get(t)) {
            .class => |c| if (c.nullable == nullable) t else self.intern(.{ .class = .{ .sym = c.sym, .args = c.args, .nullable = nullable, .attrs = c.attrs } }),
            .param => |p| if (p.nullable == nullable) t else self.intern(.{ .param = .{ .sym = p.sym, .nullable = nullable, .dnn = p.dnn and !nullable } }),
            .variable => |v| if (v.nullable == nullable) t else self.intern(.{ .variable = .{ .id = v.id, .nullable = nullable } }),
            .intersection => |parts| blk: {
                if (nullable) break :blk t;
                var out: std.ArrayList(TypeId) = .empty;
                for (parts) |p| try out.append(self.arena, try self.withNullability(p, false));
                break :blk self.intern(.{ .intersection = out.items });
            },
            else => t,
        };
    }

    /// `T & Any` for a type parameter or an inference variable, the
    /// non-null form otherwise.
    pub fn definitelyNotNull(self: *TypeStore, t: TypeId) Allocator.Error!TypeId {
        return switch (self.get(t)) {
            .param => |p| self.intern(.{ .param = .{ .sym = p.sym, .nullable = false, .dnn = true } }),
            .variable => |v| self.intern(.{ .variable = .{ .id = v.id, .dnn = true } }),
            else => self.makeNotNull(t),
        };
    }

    /// Replaces every type parameter `s` maps. Nullability composes: `T?`
    /// with `T := String?` is `String?`, with `T := String` is `String?`.
    pub fn substitute(self: *TypeStore, t: TypeId, s: *const Subst) Allocator.Error!TypeId {
        if (s.count() == 0) return t;
        switch (self.get(t)) {
            .param => |p| {
                const repl = s.get(p.sym) orelse return t;
                if (p.nullable) return self.makeNullable(repl);
                if (p.dnn) return self.definitelyNotNull(repl);
                return repl;
            },
            .class => |c| {
                if (c.args.len == 0) return t;
                var changed = false;
                var buf: ArgBuf = .init(std.heap.smp_allocator);
                const out = try buf.get(c.args.len);
                defer buf.free(out);
                for (c.args, out) |arg, *o| {
                    o.* = arg;
                    if (arg.variance == .star) continue;
                    o.ty = try self.substitute(arg.ty, s);
                    if (o.ty != arg.ty) changed = true;
                }
                if (!changed) return t;
                return self.intern(.{ .class = .{ .sym = c.sym, .args = out, .nullable = c.nullable, .attrs = c.attrs } });
            },
            .intersection => |parts| {
                var changed = false;
                var buf: TypeBuf = .init(std.heap.smp_allocator);
                const out = try buf.get(parts.len);
                defer buf.free(out);
                for (parts, out) |p, *o| {
                    o.* = try self.substitute(p, s);
                    if (o.* != p) changed = true;
                }
                if (!changed) return t;
                return self.intern(.{ .intersection = out });
            },
            else => return t,
        }
    }

    /// The class symbol of a class type, `.none` otherwise.
    pub fn classSym(self: *const TypeStore, t: TypeId) Sym {
        return switch (self.get(t)) {
            .class => |c| c.sym,
            else => .none,
        };
    }

    pub fn argsOf(self: *const TypeStore, t: TypeId) []const Arg {
        return switch (self.get(t)) {
            .class => |c| c.args,
            else => &.{},
        };
    }
};

test "the intern hash tells apart types that differ in any part" {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(std.testing.allocator);
    var n: usize = 0;
    const variances = [_]Variance{ .inv, .out, .in, .star };
    var sym: u32 = 1;
    while (sym < 200) : (sym += 1) {
        for ([_]bool{ false, true }) |nullable| {
            try seen.put(std.testing.allocator, hashType(.{ .param = .{ .sym = Sym.from(sym), .nullable = nullable } }), {});
            try seen.put(std.testing.allocator, hashType(.{ .variable = .{ .id = sym, .nullable = nullable } }), {});
            n += 2;
            for (variances) |v| {
                var arg: u32 = 1;
                while (arg < 20) : (arg += 1) {
                    const args = [_]Arg{ .{ .variance = v, .ty = TypeId.from(arg) }, .{ .variance = .inv, .ty = TypeId.from(sym) } };
                    try seen.put(std.testing.allocator, hashType(.{ .class = .{ .sym = Sym.from(sym), .args = &args, .nullable = nullable } }), {});
                    try seen.put(std.testing.allocator, hashType(.{ .class = .{ .sym = Sym.from(sym), .args = args[0..1], .nullable = nullable } }), {});
                    n += 2;
                }
            }
        }
    }
    try std.testing.expectEqual(n, seen.count());
    // Equal structures hash alike wherever their parts live.
    const a = [_]Arg{.{ .variance = .out, .ty = TypeId.from(7) }};
    var b: [1]Arg = undefined;
    b[0] = a[0];
    try std.testing.expectEqual(hashType(.{ .class = .{ .sym = Sym.from(3), .args = &a, .nullable = true } }), hashType(.{ .class = .{ .sym = Sym.from(3), .args = &b, .nullable = true } }));
}

test "types intern structurally and substitute" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var ts = try TypeStore.init(arena.allocator());
    const list = Sym.from(10);
    const int = Sym.from(11);
    const tp = Sym.from(12);
    const int_t = try ts.class(int, &.{}, false);
    try std.testing.expectEqual(int_t, try ts.class(int, &.{}, false));
    const int_q = try ts.makeNullable(int_t);
    try std.testing.expect(int_q != int_t);
    try std.testing.expectEqual(int_t, try ts.makeNotNull(int_q));
    const t_t = try ts.param(tp, false);
    const list_t = try ts.class(list, &.{.{ .variance = .inv, .ty = t_t }}, false);
    var s: Subst = .empty;
    try s.put(arena.allocator(), tp, int_q);
    const list_int = try ts.substitute(list_t, &s);
    try std.testing.expectEqual(try ts.class(list, &.{.{ .variance = .inv, .ty = int_q }}, false), list_int);
    const t_q = try ts.param(tp, true);
    try std.testing.expectEqual(int_q, try ts.substitute(t_q, &s));
    try std.testing.expect(ts.isErr(ts.errType()));
}
