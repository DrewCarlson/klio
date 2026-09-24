//! Whether a `when` covers every value of its subject. A subject of type
//! `Boolean`, an enum or a sealed class or interface has a finite set of
//! cases: `true` and `false`, the entries, the sealed hierarchy's leaves
//! (a class, an object, an enum's entries), and `null` for a type that
//! admits it. A branch's patterns cover cases: `is T` the cases that are
//! `T`s, `!is T` those that are not, a value pattern naming an object, an
//! entry, `null` or a Boolean literal that case. Any other subject is
//! covered only by `else` or by `is` a supertype of it.

const std = @import("std");

const sema_mod = @import("sema.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");
const headers = @import("headers.zig");
const subtyping = @import("subtyping.zig");
const scope = @import("scope.zig");

const Allocator = std.mem.Allocator;
const Sema = sema_mod.Sema;
const Sym = symbols.Sym;
const TypeId = types.TypeId;

/// What one pattern of a branch without a guard covers.
pub const Cover = union(enum) {
    none,
    /// `else`.
    all,
    is_type: TypeId,
    not_is: TypeId,
    /// An object or an enum entry named as a value.
    value: Sym,
    null_,
    bool_: bool,
};

const Case = struct {
    kind: Kind,
    sym: Sym = .none,
    flag: bool = false,

    const Kind = enum { class_, object, entry, null_, bool_ };
};

/// The cases no pattern covers, by the names kotlinc gives them (`is B`,
/// `C`, `Y`, `null`, `false`); an empty list when the subject's values
/// cannot be listed and nothing covers them all. Null when the `when` is
/// exhaustive.
pub fn missing(s: *Sema, subject: TypeId, covers: []const Cover) Allocator.Error!?[]const []const u8 {
    for (covers) |c| if (c == .all) return null;
    if (s.types.isErr(subject)) return null;
    const nn = try s.types.makeNotNull(subject);
    // A smart cast's intersection is covered when one of its parts is.
    const parts: []const TypeId = switch (s.types.get(nn)) {
        .intersection => |p| p,
        else => &.{nn},
    };
    var first: ?[]const []const u8 = null;
    for (parts) |part| {
        const m = try missingFor(s, if (s.types.isNullable(subject)) try s.types.makeNullable(part) else part, subject, covers);
        const names = m orelse return null;
        if (first == null or (first.?.len == 0 and names.len != 0)) first = names;
    }
    return first;
}

fn missingFor(s: *Sema, t: TypeId, subject: TypeId, covers: []const Cover) Allocator.Error!?[]const []const u8 {
    var cases: std.ArrayList(Case) = .empty;
    var seen: std.AutoHashMapUnmanaged(Sym, void) = .empty;
    if (!try casesOf(s, t, &cases, &seen)) {
        if (try coversWhole(s, subject, covers)) return null;
        return &.{};
    }
    if (try subtyping.admitsNull(s, subject)) try cases.append(s.arena, .{ .kind = .null_ });
    var names: std.ArrayList([]const u8) = .empty;
    for (cases.items) |c| {
        if (try covered(s, c, covers)) continue;
        try names.append(s.arena, try caseName(s, c));
    }
    if (names.items.len == 0) return null;
    return names.items;
}

/// Whether a `when` used as a statement must still be exhaustive: its
/// subject is a `Boolean`, an enum or a sealed type.
pub fn requiredForStatement(s: *Sema, subject: TypeId) Allocator.Error!bool {
    if (subject == .none or s.types.isErr(subject)) return false;
    const cls = s.types.classSym(try s.types.makeNotNull(subject));
    if (cls == .none) return false;
    return enumerableClass(s, cls);
}

/// `'when' expression must be exhaustive. Add the 'is B' branch or an
/// 'else' branch.`, naming what `missing` found.
pub fn message(s: *Sema, names: []const []const u8) Allocator.Error![]const u8 {
    const head = "'when' expression must be exhaustive. ";
    if (names.len == 0) return std.fmt.allocPrint(s.arena, "{s}Add an 'else' branch.", .{head});
    var list: std.ArrayList(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i != 0) try list.appendSlice(s.arena, ", ");
        try list.print(s.arena, "'{s}'", .{n});
    }
    return std.fmt.allocPrint(s.arena, "{s}Add the {s} {s} or an 'else' branch.", .{ head, list.items, if (names.len == 1) "branch" else "branches" });
}

fn enumerableClass(s: *Sema, cls: Sym) bool {
    if (cls == s.builtins.boolean) return true;
    if (s.syms.kind(cls) != .class) return false;
    return s.syms.classInfo(cls).kind == .enum_class or isSealed(s, cls);
}

/// A sealed class, or a sealed interface, whose modality stays abstract.
fn isSealed(s: *Sema, cls: Sym) bool {
    if (s.syms.flags(cls).modality == .sealed) return true;
    return switch (s.syms.get(cls).decl) {
        .class => |c| c.is_sealed,
        else => false,
    };
}

/// The cases of a value of type `t`, its `null` aside; false when they
/// cannot be listed.
fn casesOf(s: *Sema, t: TypeId, out: *std.ArrayList(Case), seen: *std.AutoHashMapUnmanaged(Sym, void)) Allocator.Error!bool {
    const nn = try s.types.makeNotNull(t);
    switch (s.types.get(nn)) {
        .class => |c| {
            if (!enumerableClass(s, c.sym)) return false;
            if (c.sym == s.builtins.boolean) {
                try out.append(s.arena, .{ .kind = .bool_, .flag = true });
                try out.append(s.arena, .{ .kind = .bool_, .flag = false });
            } else if (s.syms.classInfo(c.sym).kind == .enum_class) {
                for (s.syms.classInfo(c.sym).enum_entries) |e| try out.append(s.arena, .{ .kind = .entry, .sym = e });
            } else {
                try leaves(s, c.sym, out, seen);
            }
            return true;
        },
        // A type parameter's values are its bound's.
        .param => |p| {
            for (try headers.typeParamBounds(s, p.sym)) |b| {
                if (try casesOf(s, b, out, seen)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// The leaves of sealed `cls`'s hierarchy, in declaration order: a sealed
/// subtype stands for its own leaves, an enum for its entries.
fn leaves(s: *Sema, cls: Sym, out: *std.ArrayList(Case), seen: *std.AutoHashMapUnmanaged(Sym, void)) Allocator.Error!void {
    for (try inheritors(s, cls)) |k| {
        if ((try seen.getOrPut(s.arena, k)).found_existing) continue;
        const info = s.syms.classInfo(k);
        if (info.kind == .object or info.kind == .companion) {
            try out.append(s.arena, .{ .kind = .object, .sym = k });
        } else if (info.kind == .enum_class) {
            for (info.enum_entries) |e| try out.append(s.arena, .{ .kind = .entry, .sym = e });
        } else if (isSealed(s, k)) {
            try leaves(s, k, out, seen);
        } else {
            try out.append(s.arena, .{ .kind = .class_, .sym = k });
        }
    }
}

/// The classes that name sealed `cls` among their supertypes: every one
/// is declared in its package.
pub fn inheritors(s: *Sema, cls: Sym) Allocator.Error![]const Sym {
    if (s.sealed_inheritors.get(cls)) |hit| return hit;
    var out: std.ArrayList(Sym) = .empty;
    var pkg = s.syms.owner(cls);
    while (pkg != .none and s.syms.kind(pkg) != .package) pkg = s.syms.owner(pkg);
    if (pkg != .none) {
        var it = s.syms.packageInfo(pkg).members.iterator();
        while (it.next()) |e| for (e.value_ptr.items) |m| try collectInheritors(s, cls, m, &out);
    }
    std.mem.sort(Sym, out.items, {}, struct {
        fn lt(_: void, a: Sym, b: Sym) bool {
            return a.int() < b.int();
        }
    }.lt);
    try s.sealed_inheritors.put(s.arena, cls, out.items);
    return out.items;
}

fn collectInheritors(s: *Sema, cls: Sym, k: Sym, out: *std.ArrayList(Sym)) Allocator.Error!void {
    if (s.syms.kind(k) != .class or !scope.visible(s, k)) return;
    if (k != cls) for (try headers.supertypes(s, k)) |st| {
        if (s.types.classSym(st) != cls) continue;
        try out.append(s.arena, k);
        break;
    };
    var it = s.syms.classInfo(k).members.iterator();
    while (it.next()) |e| for (e.value_ptr.items) |m| try collectInheritors(s, cls, m, out);
}

fn covered(s: *Sema, c: Case, covers: []const Cover) Allocator.Error!bool {
    for (covers) |cv| switch (cv) {
        .none => {},
        .all => return true,
        .null_ => if (c.kind == .null_) return true,
        .bool_ => |b| if (c.kind == .bool_ and c.flag == b) return true,
        .value => |v| if ((c.kind == .object or c.kind == .entry) and c.sym == v) return true,
        .is_type => |t| if (try caseIs(s, c, t)) return true,
        .not_is => |t| if (!try caseIs(s, c, t)) return true,
    };
    return false;
}

/// Whether case `c` is a `t`.
fn caseIs(s: *Sema, c: Case, t: TypeId) Allocator.Error!bool {
    if (s.types.isErr(t)) return false;
    if (c.kind == .null_) return s.types.isNullable(t);
    const want = s.types.classSym(try s.types.makeNotNull(t));
    if (want == .none) return false;
    if (want == s.builtins.any) return true;
    const cls = switch (c.kind) {
        .bool_ => s.builtins.boolean,
        .entry => s.syms.entryInfo(c.sym).enum_class,
        else => c.sym,
    };
    return cls == want or try subtyping.isSubclass(s, cls, want);
}

/// Whether an `is` pattern takes every value of `subject`: its type is a
/// supertype of the subject's, with `null` covered too where the subject
/// admits it.
fn coversWhole(s: *Sema, subject: TypeId, covers: []const Cover) Allocator.Error!bool {
    const nn = try s.types.makeNotNull(subject);
    var values = false;
    var null_ok = !try subtyping.admitsNull(s, subject);
    for (covers) |cv| switch (cv) {
        .is_type => |t| {
            if (try subtyping.isSubtype(s, nn, try s.types.makeNotNull(t))) values = true;
            if (s.types.isNullable(t)) null_ok = true;
        },
        .null_ => null_ok = true,
        else => {},
    };
    return values and null_ok;
}

fn caseName(s: *Sema, c: Case) Allocator.Error![]const u8 {
    return switch (c.kind) {
        .null_ => "null",
        .bool_ => if (c.flag) "true" else "false",
        .class_ => std.fmt.allocPrint(s.arena, "is {s}", .{s.str(s.syms.name(c.sym))}),
        .object, .entry => s.str(s.syms.name(c.sym)),
    };
}
