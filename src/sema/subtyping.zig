//! Subtyping over the declared class graph, with declaration-site and
//! use-site variance, nullability, type-parameter bounds and intersections.

const std = @import("std");

const sema_mod = @import("sema.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");
const headers = @import("headers.zig");

const Allocator = std.mem.Allocator;
const Sema = sema_mod.Sema;
const Sym = symbols.Sym;
const TypeId = types.TypeId;

/// `a <: b`. The error type is a subtype and a supertype of everything, so
/// an unresolved reference does not cascade into a second report.
pub fn isSubtype(s: *Sema, a: TypeId, b: TypeId) Allocator.Error!bool {
    if (a == b) return true;
    const ts = &s.types;
    if (ts.isErr(a) or ts.isErr(b)) return true;
    const ta = ts.get(a);
    const tb = ts.get(b);
    if (tb == .intersection) {
        for (tb.intersection) |part| if (!try isSubtype(s, a, part)) return false;
        return true;
    }
    switch (ta) {
        .intersection => |parts| {
            for (parts) |part| if (try isSubtype(s, part, b)) return true;
            return false;
        },
        .int_lit => |lit| return intLitFits(s, lit, b),
        else => {},
    }
    // Nothing is below everything; Nothing? below every nullable type.
    if (isNothing(s, a)) return !ts.isNullable(a) or nullableOrParam(s, b);
    // A nullable type fits only a type that admits null.
    if (ts.isNullable(a) and !try admitsNull(s, b)) return false;
    if (isAnyQ(s, b)) return true;
    const a_nn = try ts.makeNotNull(a);
    switch (ts.get(a_nn)) {
        .param => |p| {
            // `T` fits `T?`, and fits `T & Any` only when it has no null
            // to lose (a `T : Any`).
            if (tb == .param and tb.param.sym == p.sym) {
                if (tb.param.nullable) return true;
                if (ts.isNullable(a)) return false;
                return !tb.param.dnn or (ta == .param and ta.param.dnn) or !try admitsNull(s, a_nn);
            }
            // `E & Any` fits through its bound without the null: `E : T?`
            // makes `E & Any` a `T`.
            const dnn = ta == .param and ta.param.dnn;
            for (try headers.typeParamBounds(s, p.sym)) |bound| {
                const bb = if (dnn) try ts.makeNotNull(bound) else try withNullOf(s, bound, a);
                if (try isSubtype(s, bb, b)) return true;
            }
            return false;
        },
        .class => |ca| {
            const b_nn = try ts.makeNotNull(b);
            switch (ts.get(b_nn)) {
                .class => |cb| {
                    const up = (try supertypeWithClass(s, a_nn, cb.sym)) orelse return false;
                    return argsContain(s, cb.sym, ts.argsOf(up), cb.args);
                },
                .param => |pb| {
                    // A class type fits a type parameter only as `T & Any`
                    // style bound reasoning never proves; the parameter is
                    // opaque.
                    _ = pb;
                    _ = ca;
                    return false;
                },
                else => return false,
            }
        },
        else => return false,
    }
}

fn withNullOf(s: *Sema, t: TypeId, like: TypeId) Allocator.Error!TypeId {
    return if (s.types.isNullable(like)) s.types.makeNullable(t) else t;
}

fn isNothing(s: *Sema, t: TypeId) bool {
    return s.types.classSym(t) == s.builtins.nothing and s.builtins.nothing != .none;
}

fn isAnyQ(s: *Sema, t: TypeId) bool {
    return s.types.classSym(t) == s.builtins.any and s.builtins.any != .none and s.types.isNullable(t);
}

fn nullableOrParam(s: *Sema, t: TypeId) bool {
    return s.types.isNullable(t) or s.types.get(t) == .param;
}

/// Whether `t` admits `null`: a nullable type, or a type parameter whose
/// bounds do.
pub fn admitsNull(s: *Sema, t: TypeId) Allocator.Error!bool {
    const ts = &s.types;
    if (ts.isNullable(t)) return true;
    switch (ts.get(t)) {
        .param => |p| {
            if (p.dnn) return false;
            for (try headers.typeParamBounds(s, p.sym)) |b| if (!try admitsNull(s, b)) return false;
            return true;
        },
        .intersection => |parts| {
            for (parts) |part| if (!try admitsNull(s, part)) return false;
            return true;
        },
        .err => return true,
        else => return false,
    }
}

fn intLitFits(s: *Sema, lit: types.IntLit, b: TypeId) Allocator.Error!bool {
    const t = s.t;
    const cands = [_]struct { on: bool, ty: TypeId }{
        .{ .on = lit.int, .ty = t.int },
        .{ .on = lit.long, .ty = t.long },
        .{ .on = lit.short, .ty = t.short },
        .{ .on = lit.byte, .ty = t.byte },
        .{ .on = lit.uint, .ty = t.uint },
        .{ .on = lit.ulong, .ty = t.ulong },
        .{ .on = lit.ushort, .ty = t.ushort },
        .{ .on = lit.ubyte, .ty = t.ubyte },
    };
    for (cands) |c| {
        if (c.on and try isSubtype(s, c.ty, b)) return true;
    }
    return false;
}

/// The supertype of `t` (a non-null class type) whose class is `target`,
/// with `t`'s arguments substituted through the hierarchy; null when `t`
/// does not extend `target`.
pub fn supertypeWithClass(s: *Sema, t: TypeId, target: Sym) Allocator.Error!?TypeId {
    var seen: std.AutoHashMapUnmanaged(Sym, void) = .empty;
    return supertypeWalk(s, t, target, &seen);
}

fn supertypeWalk(s: *Sema, t: TypeId, target: Sym, seen: *std.AutoHashMapUnmanaged(Sym, void)) Allocator.Error!?TypeId {
    const ts = &s.types;
    const c = switch (ts.get(t)) {
        .class => |c| c,
        else => return null,
    };
    if (c.sym == target) return t;
    if ((try seen.getOrPut(s.arena, c.sym)).found_existing) return null;
    const subst = try classSubst(s, t);
    for (try headers.supertypes(s, c.sym)) |st| {
        const inst = try ts.substitute(st, &subst);
        if (try supertypeWalk(s, inst, target, seen)) |hit| return hit;
    }
    return null;
}

/// The substitution a class type applies to its class's type parameters.
/// A star projection maps to the parameter's first bound.
pub fn classSubst(s: *Sema, t: TypeId) Allocator.Error!types.Subst {
    var subst: types.Subst = .empty;
    const c = switch (s.types.get(t)) {
        .class => |c| c,
        else => return subst,
    };
    const tps = try headers.classTypeParams(s, c.sym);
    for (tps, 0..) |tp, i| {
        if (i >= c.args.len) break;
        const arg = c.args[i];
        const ty = if (arg.variance == .star) blk: {
            const bounds = try headers.typeParamBounds(s, tp);
            break :blk if (bounds.len != 0) bounds[0] else s.t.any_q;
        } else arg.ty;
        try subst.put(s.arena, tp, ty);
    }
    return subst;
}

/// Whether `have`'s arguments fit `want`'s for class `cls`, reading each
/// position's variance from the use site and then the declaration.
fn argsContain(s: *Sema, cls: Sym, have: []const types.Arg, want: []const types.Arg) Allocator.Error!bool {
    const tps = try headers.classTypeParams(s, cls);
    for (want, 0..) |w, i| {
        if (w.variance == .star) continue;
        if (i >= have.len) return true;
        const h = have[i];
        const decl_var: types.Variance = if (i < tps.len) s.syms.typeParamInfo(tps[i]).variance else .inv;
        const v: types.Variance = if (w.variance != .inv) w.variance else decl_var;
        if (h.variance == .star) {
            if (v == .in) return false;
            if (v == .out) {
                const bound = if (i < tps.len) blk: {
                    const bs = try headers.typeParamBounds(s, tps[i]);
                    break :blk if (bs.len != 0) bs[0] else s.t.any_q;
                } else s.t.any_q;
                if (!try isSubtype(s, bound, w.ty)) return false;
                continue;
            }
            return false;
        }
        switch (v) {
            .out => if (h.variance == .in or !try isSubtype(s, h.ty, w.ty)) return false,
            .in => if (h.variance == .out or !try isSubtype(s, w.ty, h.ty)) return false,
            .inv => {
                if (h.variance != .inv) return false;
                if (!try isSubtype(s, h.ty, w.ty) or !try isSubtype(s, w.ty, h.ty)) return false;
            },
            .star => {},
        }
    }
    return true;
}

/// Types are equal as types: mutual subtypes.
pub fn equivalent(s: *Sema, a: TypeId, b: TypeId) Allocator.Error!bool {
    if (a == b) return true;
    return try isSubtype(s, a, b) and try isSubtype(s, b, a);
}

/// A common supertype of `ts`: the first candidate every type fits, walking
/// the first type's supertypes breadth first, nullable when any input is.
pub fn commonSupertype(s: *Sema, list: []const TypeId) Allocator.Error!TypeId {
    return commonSupertypeAt(s, list, 0);
}

/// The common supertype, arguments joined to `depth` levels of nesting;
/// deeper ones are star projections, which ends the recursion a type like
/// `Comparable<T>` would start.
fn commonSupertypeAt(s: *Sema, list: []const TypeId, depth: u8) Allocator.Error!TypeId {
    if (list.len == 0) return s.t.nothing;
    var any_nullable = false;
    var non_nothing: std.ArrayList(TypeId) = .empty;
    for (list) |t| {
        if (s.types.isErr(t)) return t;
        if (s.types.isNullable(t)) any_nullable = true;
        if (isNothing(s, t)) continue;
        try non_nothing.append(s.arena, try s.types.makeNotNull(t));
    }
    if (non_nothing.items.len == 0) return if (any_nullable) s.t.nothing_q else s.t.nothing;
    const first = non_nothing.items[0];
    var result: TypeId = s.t.any;
    // One type every other fits below is the answer: `T & Any` and `T`
    // join to `T`.
    const top: ?TypeId = for (non_nothing.items) |c| {
        if (try allFit(s, non_nothing.items, c)) break c;
    } else null;
    if (top) |t| {
        result = t;
    } else {
        // The classes every type extends, found from the first type's
        // hierarchy; the minimal ones, each with its arguments joined, are
        // the answer (several are an intersection: `ArrayList<T>` and a
        // `RandomAccess` list join to `List<T> & RandomAccess`).
        var common: std.ArrayList(Sym) = .empty;
        var queue: std.ArrayList(Sym) = .empty;
        var seen: std.AutoHashMapUnmanaged(Sym, void) = .empty;
        try classRoots(s, first, &queue);
        var qi: usize = 0;
        while (qi < queue.items.len) : (qi += 1) {
            const cls = queue.items[qi];
            if ((try seen.getOrPut(s.arena, cls)).found_existing) continue;
            var all = true;
            for (non_nothing.items) |t| {
                if (try viewAs(s, t, cls) == null) {
                    all = false;
                    break;
                }
            }
            if (all) {
                try common.append(s.arena, cls);
                continue;
            }
            for (try headers.supertypes(s, cls)) |st| {
                const sc = s.types.classSym(st);
                if (sc != .none) try queue.append(s.arena, sc);
            }
        }
        var minimal: std.ArrayList(TypeId) = .empty;
        for (common.items, 0..) |a, i| {
            if (s.builtins.any != .none and a == s.builtins.any) continue;
            var dominated = false;
            for (common.items, 0..) |b, j| {
                if (i == j or a == b) continue;
                if (try isSubclass(s, b, a)) {
                    dominated = true;
                    break;
                }
            }
            if (dominated) continue;
            try minimal.append(s.arena, try joinedClass(s, a, non_nothing.items, depth));
        }
        if (minimal.items.len == 1) {
            result = minimal.items[0];
        } else if (minimal.items.len > 1) {
            result = try s.types.intern(.{ .intersection = minimal.items });
        }
        // A joined class stands for every input: a type parameter whose
        // bound admits null (`K` and `V` join to `Any?`) makes it nullable.
        for (non_nothing.items) |t| {
            if (s.types.get(t) == .param and try admitsNull(s, t)) any_nullable = true;
        }
    }
    return if (any_nullable) s.types.makeNullable(result) else result;
}

/// The classes a type is made of: its own, a type parameter's bounds', an
/// intersection's parts'.
fn classRoots(s: *Sema, t: TypeId, out: *std.ArrayList(Sym)) Allocator.Error!void {
    switch (s.types.get(t)) {
        .class => |c| try out.append(s.arena, c.sym),
        .param => |p| for (try headers.typeParamBounds(s, p.sym)) |b| try classRoots(s, b, out),
        .intersection => |parts| for (parts) |part| try classRoots(s, part, out),
        else => {},
    }
}

/// `t` seen as class `cls`: its supertype with that class, through a type
/// parameter's bounds or an intersection's parts; null when it has none.
fn viewAs(s: *Sema, t: TypeId, cls: Sym) Allocator.Error!?TypeId {
    const nn = try s.types.makeNotNull(t);
    switch (s.types.get(nn)) {
        .class => return supertypeWithClass(s, nn, cls),
        .param => |p| {
            for (try headers.typeParamBounds(s, p.sym)) |b| {
                if (try viewAs(s, b, cls)) |v| return v;
            }
            return null;
        },
        .intersection => |parts| {
            for (parts) |part| {
                if (try viewAs(s, part, cls)) |v| return v;
            }
            return null;
        },
        else => return null,
    }
}

/// Whether no class can be below every one of `parts`: two classes neither
/// of which extends the other (one class has one superclass), or a final
/// class and an interface it does not implement.
fn emptyIntersection(s: *Sema, parts: []const TypeId) Allocator.Error!bool {
    for (parts, 0..) |x, i| for (parts[i + 1 ..]) |y| {
        const xc = s.types.classSym(try s.types.makeNotNull(x));
        const yc = s.types.classSym(try s.types.makeNotNull(y));
        if (xc == .none or yc == .none) continue;
        if (try isSubclass(s, xc, yc) or try isSubclass(s, yc, xc)) continue;
        const x_iface = s.syms.classInfo(xc).kind == .interface;
        const y_iface = s.syms.classInfo(yc).kind == .interface;
        if (!x_iface and !y_iface) return true;
        if (!x_iface and s.syms.flags(xc).modality == .final) return true;
        if (!y_iface and s.syms.flags(yc).modality == .final) return true;
    };
    return false;
}

fn isSubclass(s: *Sema, sub: Sym, sup: Sym) Allocator.Error!bool {
    return try supertypeWithClass(s, try headers.selfType(s, sub), sup) != null;
}

/// Class `cls` with each argument joined over `types`' views of it: equal
/// arguments stay; a covariant parameter takes their common supertype, an
/// invariant one an `out` projection of it, a contravariant one a star.
fn joinedClass(s: *Sema, cls: Sym, list: []const TypeId, depth: u8) Allocator.Error!TypeId {
    const tps = try headers.classTypeParams(s, cls);
    if (tps.len == 0) return headers.selfType(s, cls);
    const views = try s.arena.alloc([]const types.Arg, list.len);
    for (list, views) |t, *v| v.* = s.types.argsOf((try viewAs(s, t, cls)).?);
    const args = try s.arena.alloc(types.Arg, tps.len);
    for (tps, args, 0..) |tp, *out, i| {
        var same = true;
        var star = false;
        for (views) |v| {
            if (i >= v.len or v[i].variance == .star) {
                star = true;
                break;
            }
            if (v[i].variance != views[0][i].variance or v[i].ty != views[0][i].ty) same = false;
        }
        if (star) {
            out.* = .{ .variance = .star, .ty = .none };
            continue;
        }
        if (same) {
            out.* = views[0][i];
            continue;
        }
        const decl = s.syms.typeParamInfo(tp).variance;
        const tys = try s.arena.alloc(TypeId, views.len);
        for (views, tys) |v, *t| t.* = v[i].ty;
        // A contravariant argument joins at the lowest of them, when one
        // is below every other (`(MutableCollection<E>) -> Unit` and
        // `(MutableList<E>) -> Unit` join to `(MutableList<E>) -> Unit`),
        // else at their intersection (`In<A>` and `In<B>` join to
        // `In<A & B>`), or a star when no type is below them all (`In<Int>`
        // and `In<String>` join to `In<*>`).
        if (decl == .in) {
            out.* = .{ .variance = .star, .ty = .none };
            var parts: std.ArrayList(TypeId) = .empty;
            for (views, tys) |v, t| {
                if (v[i].variance == .out) break;
                switch (s.types.get(t)) {
                    .intersection => |ps| try parts.appendSlice(s.arena, ps),
                    else => try parts.append(s.arena, t),
                }
            } else if (!try emptyIntersection(s, parts.items)) {
                out.* = .{ .variance = .inv, .ty = try s.types.intern(.{ .intersection = parts.items }) };
            }
            for (tys) |low| {
                var below = true;
                for (tys) |other| {
                    if (!try isSubtype(s, low, other)) {
                        below = false;
                        break;
                    }
                }
                if (below) {
                    out.* = .{ .variance = .inv, .ty = low };
                    break;
                }
            }
            continue;
        }
        if (depth >= 2) {
            out.* = .{ .variance = .star, .ty = .none };
            continue;
        }
        const lub = try commonSupertypeAt(s, tys, depth + 1);
        out.* = .{ .variance = if (decl == .out) .inv else .out, .ty = lub };
    }
    // A function type's marks (an extension receiver, contexts) carry over
    // when every input has them.
    var attrs: ?types.Attrs = null;
    for (list) |t| {
        const c = switch (s.types.get(t)) {
            .class => |c| c,
            else => {
                attrs = .{};
                break;
            },
        };
        if (c.sym != cls) {
            attrs = .{};
            break;
        }
        if (attrs) |a| {
            if (@as(u8, @bitCast(a)) != @as(u8, @bitCast(c.attrs))) {
                attrs = .{};
                break;
            }
        } else attrs = c.attrs;
    }
    return s.types.classAttrs(cls, args, false, attrs orelse .{});
}

fn isAnyType(s: *Sema, t: TypeId) bool {
    return s.builtins.any != .none and s.types.classSym(t) == s.builtins.any;
}

fn allFit(s: *Sema, list: []const TypeId, cand: TypeId) Allocator.Error!bool {
    for (list) |t| if (!try isSubtype(s, t, cand)) return false;
    return true;
}
