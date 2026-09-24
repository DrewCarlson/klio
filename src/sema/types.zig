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

pub const TypeStore = struct {
    arena: Allocator,
    items: std.ArrayList(Type) = .empty,
    intern_map: std.StringHashMapUnmanaged(TypeId) = .empty,
    key_buf: std.ArrayList(u8) = .empty,
    err_id: TypeId = .none,

    pub fn init(arena: Allocator) Allocator.Error!TypeStore {
        var ts = TypeStore{ .arena = arena };
        try ts.items.append(arena, .none);
        ts.err_id = try ts.intern(.err);
        return ts;
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

    fn keyOf(self: *TypeStore, t: Type) Allocator.Error![]const u8 {
        self.key_buf.clearRetainingCapacity();
        const w = struct {
            fn int(buf: *std.ArrayList(u8), a: Allocator, v: u32) Allocator.Error!void {
                try buf.appendSlice(a, std.mem.asBytes(&v));
            }
        };
        const a = self.arena;
        try self.key_buf.append(a, @intFromEnum(std.meta.activeTag(t)));
        switch (t) {
            .none, .err => {},
            .class => |c| {
                try w.int(&self.key_buf, a, c.sym.int());
                try self.key_buf.append(a, @intFromBool(c.nullable));
                try self.key_buf.append(a, @bitCast(c.attrs));
                try w.int(&self.key_buf, a, @intCast(c.args.len));
                for (c.args) |arg| {
                    try self.key_buf.append(a, @intFromEnum(arg.variance));
                    try w.int(&self.key_buf, a, arg.ty.int());
                }
            },
            .param => |p| {
                try w.int(&self.key_buf, a, p.sym.int());
                try self.key_buf.append(a, @intFromBool(p.nullable));
                try self.key_buf.append(a, @intFromBool(p.dnn));
            },
            .intersection => |parts| {
                try w.int(&self.key_buf, a, @intCast(parts.len));
                for (parts) |p| try w.int(&self.key_buf, a, p.int());
            },
            .int_lit => |l| try self.key_buf.append(a, @bitCast(l)),
            .variable => |v| {
                try w.int(&self.key_buf, a, v.id);
                try self.key_buf.append(a, @intFromBool(v.nullable));
                try self.key_buf.append(a, @intFromBool(v.dnn));
            },
        }
        return self.key_buf.items;
    }

    pub fn intern(self: *TypeStore, t: Type) Allocator.Error!TypeId {
        const key = try self.keyOf(t);
        if (self.intern_map.get(key)) |id| return id;
        const owned_key = try self.arena.dupe(u8, key);
        const stored: Type = switch (t) {
            .class => |c| .{ .class = .{ .sym = c.sym, .args = try self.arena.dupe(Arg, c.args), .nullable = c.nullable, .attrs = c.attrs } },
            .intersection => |parts| .{ .intersection = try self.arena.dupe(TypeId, parts) },
            else => t,
        };
        const id = TypeId.from(@intCast(self.items.items.len));
        try self.items.append(self.arena, stored);
        try self.intern_map.put(self.arena, owned_key, id);
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
                const out = try self.arena.alloc(Arg, c.args.len);
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
                const out = try self.arena.alloc(TypeId, parts.len);
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
