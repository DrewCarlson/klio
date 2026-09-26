//! Member lookup on a type: every member named `n` a value of that type
//! has, declared or inherited, each with the substitution that maps its
//! declaring class's type parameters to the receiver's arguments. A member
//! a subclass overrides is hidden by the override, so the nearest
//! declaration answers first.

const std = @import("std");
const ast = @import("ast");

const sema_mod = @import("sema.zig");
const symbols = @import("symbols.zig");
const types = @import("types.zig");
const names_mod = @import("names.zig");
const headers = @import("headers.zig");
const subtyping = @import("subtyping.zig");
const scope = @import("scope.zig");

const Allocator = std.mem.Allocator;
const Sema = sema_mod.Sema;
const Sym = symbols.Sym;
const TypeId = types.TypeId;
const Name = names_mod.Name;

pub const Member = struct {
    sym: Sym,
    /// The declaring class's type parameters mapped to the receiver's
    /// arguments, as seen through the hierarchy.
    subst: *const types.Subst,
    /// Distance from the receiver's class; 0 for a member it declares.
    depth: u16,
    /// A function of another supertype with this one's signature that
    /// declares default values this one does not: the class inherits one
    /// function from both (`class B : A(), I` where A's `f(x: String)`
    /// implements I's `f(x: String = "1")`), and a call takes I's defaults.
    defaults: Sym = .none,
};

pub const Want = enum { callable, function, property, classifier };

pub const LookupKey = struct { recv: TypeId, name: Name, want: Want, every: bool = false, with_private: bool = false, all: bool = false };

fn wanted(s: *Sema, m: Sym, want: Want) bool {
    const k = s.syms.kind(m);
    return switch (want) {
        .callable => k == .function or k == .property,
        .function => k == .function,
        .property => k == .property or k == .enum_entry,
        .classifier => k == .class or k == .type_alias,
    };
}

/// Members named `n` on values of type `recv` (nullability ignored: a safe
/// call and a smart cast both look members up on the non-null type).
pub fn lookup(s: *Sema, recv: TypeId, n: Name, want: Want) Allocator.Error![]const Member {
    // A pure function of its arguments once a layer's members are
    // collected: kept per receiver type, name and kind.
    const key: LookupKey = .{ .recv = recv, .name = n, .want = want };
    if (s.lookup_memo.get(key)) |hit| return hit;
    const found = try lookupUncached(s, recv, n, want, false, false);
    try s.lookup_memo.put(s.arena, key, found);
    return found;
}

/// `lookup`, taking a supertype's private members too, which a subtype
/// does not inherit: what an access names when nothing else answers.
/// kotlinc finds such a member and refuses it as invisible.
pub fn lookupWithPrivate(s: *Sema, recv: TypeId, n: Name, want: Want) Allocator.Error![]const Member {
    const key: LookupKey = .{ .recv = recv, .name = n, .want = want, .with_private = true };
    if (s.lookup_memo.get(key)) |hit| return hit;
    const found = try lookupUncached(s, recv, n, want, false, true);
    try s.lookup_memo.put(s.arena, key, found);
    return found;
}

/// `lookup`, keeping every member two supertypes at one distance declare
/// alike where `lookup` keeps the one the class is taken to inherit: a
/// member that overrides them overrides each (`D : B` where `B : C,
/// A<Int>()` gets `size` from both).
pub fn lookupEvery(s: *Sema, recv: TypeId, n: Name, want: Want) Allocator.Error![]const Member {
    const key: LookupKey = .{ .recv = recv, .name = n, .want = want, .every = true };
    if (s.lookup_memo.get(key)) |hit| return hit;
    const found = try lookupUncached(s, recv, n, want, true, false);
    try s.lookup_memo.put(s.arena, key, found);
    return found;
}

/// Every member named `n` in `recv`'s class and its supertypes, however
/// near, nothing one hides left out, and members deprecated as hidden
/// among them: what an override may override and what implements an
/// abstract member. Members a subtype does not inherit (private, static,
/// an `expect` its `actual` supersedes) are left out.
pub fn lookupOverridable(s: *Sema, recv: TypeId, n: Name, want: Want) Allocator.Error![]const Member {
    const key: LookupKey = .{ .recv = recv, .name = n, .want = want, .all = true };
    if (s.lookup_memo.get(key)) |hit| return hit;
    var out: std.ArrayList(Member) = .empty;
    var seen: std.AutoHashMapUnmanaged(Sym, void) = .empty;
    var frontier: std.ArrayList(TypeId) = .empty;
    try pushRoots(s, &frontier, recv);
    var depth: u16 = 0;
    while (frontier.items.len != 0) : (depth += 1) {
        var next: std.ArrayList(TypeId) = .empty;
        for (frontier.items) |t| {
            const c = switch (s.types.get(t)) {
                .class => |c| c,
                else => continue,
            };
            if ((try seen.getOrPut(s.arena, c.sym)).found_existing) continue;
            const subst = try s.arena.create(types.Subst);
            subst.* = try subtyping.classSubst(s, t);
            for (scope.membersOf(s, c.sym, n)) |m| {
                if (!wanted(s, m, want)) continue;
                const f = s.syms.flags(m);
                if (f.superseded) continue;
                if (depth > 0 and f.visibility == .private) continue;
                try out.append(s.arena, .{ .sym = m, .subst = subst, .depth = depth });
            }
            for (try headers.supertypes(s, c.sym)) |st| {
                try next.append(s.arena, try s.types.substitute(st, subst));
            }
        }
        frontier = next;
    }
    try s.lookup_memo.put(s.arena, key, out.items);
    return out.items;
}

fn lookupUncached(s: *Sema, recv: TypeId, n: Name, want: Want, every: bool, with_private: bool) Allocator.Error![]const Member {
    var out: std.ArrayList(Member) = .empty;
    var seen: std.AutoHashMapUnmanaged(Sym, void) = .empty;
    var frontier: std.ArrayList(TypeId) = .empty;
    try pushRoots(s, &frontier, recv);
    const roots = frontier.items.len;
    var depth: u16 = 0;
    while (frontier.items.len != 0) : (depth += 1) {
        var next: std.ArrayList(TypeId) = .empty;
        for (frontier.items) |t| {
            const c = switch (s.types.get(t)) {
                .class => |c| c,
                else => continue,
            };
            if ((try seen.getOrPut(s.arena, c.sym)).found_existing) continue;
            const subst = try s.arena.create(types.Subst);
            subst.* = try subtyping.classSubst(s, t);
            for (scope.membersOf(s, c.sym, n)) |m| {
                if (!wanted(s, m, want)) continue;
                if (!scope.visible(s, m)) continue;
                // A private member is not inherited: a subclass's `n` is
                // not its superclass's `private val n`, even where the
                // superclass's body could read it (an object expression
                // extending the class it is written in reads the outer
                // instance's `n`).
                if (depth > 0 and !with_private and s.syms.flags(m).visibility == .private) continue;
                if (!every) if (try sameDepthConflict(s, out.items, m, subst, depth)) |i| {
                    // Two supertypes at the same distance declare the
                    // member: the one with the more specific result is
                    // the one the class inherits (`MutableCollection`'s
                    // `iterator()` over `List`'s).
                    const cand: Member = .{ .sym = m, .subst = subst, .depth = depth };
                    const other = out.items[i];
                    // Of two where one overrides the other (the parts of
                    // an intersection, one a smart cast narrowed to its
                    // subclass), the override is the member.
                    if (try overridesTransitively(s, m, other.sym)) {
                        out.items[i] = cand;
                    } else if (!try overridesTransitively(s, other.sym, m)) {
                        if (try moreSpecificResult(s, cand, other)) out.items[i] = cand;
                    }
                    try takeDefaults(s, &out.items[i], if (out.items[i].sym == m) other.sym else m);
                    continue;
                };
                if (try hiddenBy(s, out.items, m, subst, if (every) depth else null)) |i| {
                    try takeDefaults(s, &out.items[i], m);
                    continue;
                }
                try out.append(s.arena, .{ .sym = m, .subst = subst, .depth = depth });
            }
            for (try headers.supertypes(s, c.sym)) |st| {
                try next.append(s.arena, try s.types.substitute(st, subst));
            }
        }
        frontier = next;
    }
    // Through an intersection (`x: A<in T>` smart cast to `B : A<String>`)
    // each part offers its members; one another part's member overrides
    // is that member (`B.foo` over `A.foo`).
    if (roots > 1 and out.items.len > 1) {
        var kept: std.ArrayList(Member) = .empty;
        for (out.items, 0..) |m, i| {
            const k = s.syms.kind(m.sym);
            const overridden_here = for (out.items, 0..) |f, j| {
                if (i == j or s.syms.kind(f.sym) != k) continue;
                if (k != .function and k != .property) continue;
                if (try overridesTransitively(s, f.sym, m.sym)) break true;
            } else false;
            if (!overridden_here) try kept.append(s.arena, m);
        }
        return kept.items;
    }
    return out.items;
}

fn pushRoots(s: *Sema, frontier: *std.ArrayList(TypeId), t: TypeId) Allocator.Error!void {
    switch (s.types.get(t)) {
        .class => try frontier.append(s.arena, try s.types.makeNotNull(t)),
        .param => |p| {
            for (try headers.typeParamBounds(s, p.sym)) |b| try pushRoots(s, frontier, b);
        },
        .intersection => |parts| for (parts) |part| try pushRoots(s, frontier, part),
        else => {},
    }
}

/// The index of a member another class found at the same depth declares
/// that `m` would override if they were in one class: the same kind and
/// signature. Two members of one class are overloads.
fn sameDepthConflict(s: *Sema, found: []const Member, m: Sym, m_subst: *const types.Subst, depth: u16) Allocator.Error!?usize {
    const mk = s.syms.kind(m);
    for (found, 0..) |f, i| {
        if (f.depth != depth or s.syms.kind(f.sym) != mk) continue;
        if (s.syms.owner(f.sym) == s.syms.owner(m)) continue;
        if (mk == .property) {
            if (try samePropertyReceiver(s, f.sym, f.subst, m, m_subst)) return i;
            continue;
        }
        if (mk != .function) return i;
        if (try sameSignature(s, f.sym, f.subst, m, m_subst)) return i;
    }
    return null;
}

/// Properties of one name are the same property when both are plain or
/// both extend the same receiver type: `val parent` and a member
/// extension `val Composition.parent` coexist, as do `Int.dp` and
/// `Float.dp`.
fn samePropertyReceiver(s: *Sema, a: Sym, a_subst: *const types.Subst, b: Sym, b_subst: *const types.Subst) Allocator.Error!bool {
    try headers.propertyHeader(s, a);
    try headers.propertyHeader(s, b);
    const ar = s.syms.propertyInfo(a).receiver;
    const br = s.syms.propertyInfo(b).receiver;
    if ((ar == .none) != (br == .none)) return false;
    if (ar == .none) return true;
    return sameErasure(s, try s.types.substitute(ar, a_subst), try s.types.substitute(br, b_subst));
}

fn moreSpecificResult(s: *Sema, a: Member, b: Member) Allocator.Error!bool {
    const at = try memberType(s, a);
    const bt = try memberType(s, b);
    if (s.types.isErr(at) or s.types.isErr(bt)) return false;
    // Of two properties, a `var` is more specific than a `val` whose type
    // it fits, and a `val` never more than a `var`: `abstract class C :
    // A(), B` with `A`'s `val x: String` and `B`'s `var x: String` has a
    // settable `x`.
    if (s.syms.kind(a.sym) == .property and s.syms.kind(b.sym) == .property) {
        const a_var = s.syms.flags(a.sym).mutable;
        const b_var = s.syms.flags(b.sym).mutable;
        if (a_var != b_var) return a_var and try subtyping.isSubtype(s, at, bt);
        if (a_var) return false;
    }
    return (try subtyping.isSubtype(s, at, bt)) and !(try subtyping.isSubtype(s, bt, at));
}

/// Whether a member already found (nearer the receiver) overrides `m`: the
/// same kind and, for a function, the same parameter types after
/// substitution. Properties do not overload, so any nearer property of the
/// name hides it.
/// The index of a found member that hides `m`: one of its kind and, for a
/// function, its signature; for a property, its receiver.
fn hiddenBy(s: *Sema, found: []const Member, m: Sym, m_subst: *const types.Subst, below: ?u16) Allocator.Error!?usize {
    const mk = s.syms.kind(m);
    for (found, 0..) |f, i| {
        const fk = s.syms.kind(f.sym);
        if (fk != mk) continue;
        // Only a nearer member hides one where every one is kept.
        if (below) |d| if (f.depth >= d) continue;
        // A member of the same class is an overload, never an override.
        if (s.syms.owner(f.sym) == s.syms.owner(m)) continue;
        if (mk == .property) {
            if (try samePropertyReceiver(s, f.sym, f.subst, m, m_subst)) return i;
            continue;
        }
        if (mk != .function) return i;
        if (try sameSignature(s, f.sym, f.subst, m, m_subst)) return i;
    }
    return null;
}

/// `kept` stands for `other` too: when `other` declares default values
/// and `kept` declares none, a call of `kept` takes `other`'s.
fn takeDefaults(s: *Sema, kept: *Member, other: Sym) Allocator.Error!void {
    if (kept.defaults != .none or kept.sym == other) return;
    if (s.syms.kind(kept.sym) != .function or s.syms.kind(other) != .function) return;
    if (declaresDefaults(s, kept.sym) or !declaresDefaults(s, other)) return;
    kept.defaults = other;
}

fn declaresDefaults(s: *Sema, f: Sym) bool {
    for (s.syms.functionInfo(f).params) |p| {
        if (s.syms.flags(p).has_default) return true;
    }
    return false;
}

/// Same value-parameter types and same receiver, after each side's
/// substitution. Type parameters of the functions themselves compare by
/// position.
pub fn sameSignature(s: *Sema, a: Sym, a_subst: *const types.Subst, b: Sym, b_subst: *const types.Subst) Allocator.Error!bool {
    return signaturesMatch(s, a, a_subst, b, b_subst, false);
}

/// `sameSignature`, with the value-parameter types equal as written, type
/// arguments included: `f(a: List<Int>)` does not have the signature of
/// `f(a: List<String>)`.
pub fn sameSignatureExactly(s: *Sema, a: Sym, a_subst: *const types.Subst, b: Sym, b_subst: *const types.Subst) Allocator.Error!bool {
    return signaturesMatch(s, a, a_subst, b, b_subst, true);
}

fn signaturesMatch(s: *Sema, a: Sym, a_subst: *const types.Subst, b: Sym, b_subst: *const types.Subst, exact: bool) Allocator.Error!bool {
    try headers.functionHeader(s, a);
    try headers.functionHeader(s, b);
    const ai = s.syms.functionInfo(a);
    const bi = s.syms.functionInfo(b);
    if (ai.params.len != bi.params.len) return false;
    if (ai.type_params.len != bi.type_params.len) return false;
    if ((ai.receiver == .none) != (bi.receiver == .none)) return false;
    // `f(vararg x: String)` takes an array: it overloads `f(x: String)`.
    for (ai.params, bi.params) |ap, bp| {
        if (s.syms.flags(ap).vararg != s.syms.flags(bp).vararg) return false;
    }
    // Map b's own type parameters onto a's so `fun <T> f(x: T)` overrides
    // `fun <U> f(x: U)`.
    var bs = try cloneSubst(s, b_subst);
    for (ai.type_params, bi.type_params) |atp, btp| {
        try bs.put(s.arena, btp, try s.types.param(atp, false));
    }
    // Type parameters with different bounds make different signatures:
    // `fun <T : B> f(t: T)` and `fun <T : C> f(t: T)` overload. The bounds
    // are a set: `where T : A, T : B` is `where T : B, T : A`.
    for (ai.type_params, bi.type_params) |atp, btp| {
        const ab = try headers.typeParamBounds(s, atp);
        const bb = try headers.typeParamBounds(s, btp);
        if (ab.len != bb.len) return false;
        const used = try s.arena.alloc(bool, bb.len);
        @memset(used, false);
        for (ab) |x| {
            const xs = try s.types.substitute(x, a_subst);
            const j = for (bb, 0..) |y, j| {
                if (used[j]) continue;
                if (try sameErasure(s, xs, try s.types.substitute(y, &bs))) break j;
            } else return false;
            used[j] = true;
        }
    }
    // Member extensions differ by their receiver type as much as by a
    // parameter (`Int.toDp()` and `Float.toDp()` in `Density`).
    if (ai.receiver != .none) {
        const ar = try s.types.substitute(ai.receiver, a_subst);
        const br = try s.types.substitute(bi.receiver, &bs);
        if (!try sameErasure(s, ar, br)) return false;
    }
    for (ai.params, bi.params) |ap, bp| {
        const at = try s.types.substitute(try headers.paramType(s, ap), a_subst);
        const bt = try s.types.substitute(try headers.paramType(s, bp), &bs);
        if (!try sameErasure(s, at, bt)) return false;
        if (exact and !try subtyping.equivalent(s, at, bt)) return false;
    }
    return true;
}

fn cloneSubst(s: *Sema, src: *const types.Subst) Allocator.Error!types.Subst {
    var out: types.Subst = .empty;
    var it = src.iterator();
    while (it.next()) |e| try out.put(s.arena, e.key_ptr.*, e.value_ptr.*);
    return out;
}

/// Two parameter types that an override must match: equal classes (and
/// nullability), or type parameters of the same position.
fn sameErasure(s: *Sema, a: TypeId, b: TypeId) Allocator.Error!bool {
    if (a == b) return true;
    if (s.types.isErr(a) or s.types.isErr(b)) return true;
    const ta = s.types.get(a);
    const tb = s.types.get(b);
    if (ta == .class and tb == .class) {
        return ta.class.sym == tb.class.sym and ta.class.nullable == tb.class.nullable;
    }
    if (ta == .param and tb == .param) return ta.param.sym == tb.param.sym;
    return subtyping.equivalent(s, a, b);
}

/// The members of `m`'s class's supertypes that `m`, a member function or
/// property, overrides directly: in each supertype, the nearest member of
/// the same name (and, for a function, the same signature). A member that
/// overrides nothing is the root of its virtual slot.
/// Whether `m` overrides `base`, directly or through other overrides.
pub fn overridesTransitively(s: *Sema, m: Sym, base: Sym) Allocator.Error!bool {
    for (try overridden(s, m)) |o| {
        if (o == base) return true;
        if (try overridesTransitively(s, o, base)) return true;
    }
    return false;
}

pub fn overridden(s: *Sema, m: Sym) Allocator.Error![]const Sym {
    const k = s.syms.kind(m);
    if (k != .function and k != .property) return &.{};
    const cached = if (k == .function) s.syms.functionInfo(m).overrides else s.syms.propertyInfo(m).overrides;
    if (cached) |c| return c;
    var out: std.ArrayList(Sym) = .empty;
    const cls = s.syms.owner(m);
    if (cls != .none and s.syms.kind(cls) == .class and !s.syms.flags(m).static) {
        const want: Want = if (k == .function) .function else .property;
        const none_subst = try s.arena.create(types.Subst);
        none_subst.* = .empty;
        const self_t = try headers.selfType(s, cls);
        const self_subst = try subtyping.classSubst(s, self_t);
        for (try headers.supertypes(s, cls)) |st_decl| {
            const st = try s.types.substitute(st_decl, &self_subst);
            // Through each supertype, the nearest member of the signature;
            // one deprecated as hidden is overridden too.
            var visible_found = false;
            for (try lookupEvery(s, st, s.syms.name(m), want)) |cand| {
                if (s.syms.kind(cand.sym) != k) continue;
                if (s.syms.flags(cand.sym).static) continue;
                if (k == .function and !try sameSignature(s, m, none_subst, cand.sym, cand.subst)) continue;
                if (k == .property and !try sameExtensionReceiver(s, m, cand.sym, cand.subst)) continue;
                visible_found = true;
                if (std.mem.indexOfScalar(Sym, out.items, cand.sym) == null) try out.append(s.arena, cand.sym);
            }
            if (visible_found) continue;
            for (try lookupOverridable(s, st, s.syms.name(m), want)) |cand| {
                if (s.syms.kind(cand.sym) != k or !s.syms.flags(cand.sym).hidden) continue;
                if (s.syms.flags(cand.sym).static) continue;
                if (k == .function and !try sameSignature(s, m, none_subst, cand.sym, cand.subst)) continue;
                if (k == .property and !try sameExtensionReceiver(s, m, cand.sym, cand.subst)) continue;
                if (std.mem.indexOfScalar(Sym, out.items, cand.sym) == null) try out.append(s.arena, cand.sym);
            }
        }
    }
    if (k == .function) s.syms.functionInfo(m).overrides = out.items else s.syms.propertyInfo(m).overrides = out.items;
    return out.items;
}

/// The member of a supertype that `m`, a member function or property
/// declared without `override`, has the signature of: a function with the
/// same parameter types, a property with the same receiver. kotlinc
/// requires `override` on `m`. A supertype's private member is not
/// inherited, so `m` does not hide it, and neither does it hide one only
/// some platforms declare (`@PlatformDependent`).
pub fn hiddenSupertypeMember(s: *Sema, m: Sym) Allocator.Error!Sym {
    const k = s.syms.kind(m);
    const cls = s.syms.owner(m);
    if (k != .function and k != .property) return .none;
    if (cls == .none or s.syms.kind(cls) != .class) return .none;
    const want: Want = if (k == .function) .function else .property;
    const none_subst = try s.arena.create(types.Subst);
    none_subst.* = .empty;
    const self_subst = try subtyping.classSubst(s, try headers.selfType(s, cls));
    for (try headers.supertypes(s, cls)) |st_decl| {
        const st = try s.types.substitute(st_decl, &self_subst);
        for (try lookupEvery(s, st, s.syms.name(m), want)) |cand| {
            if (s.syms.kind(cand.sym) != k) continue;
            const cf = s.syms.flags(cand.sym);
            if (cf.static or cf.visibility == .private) continue;
            if (k == .function and !try sameSignatureExactly(s, m, none_subst, cand.sym, cand.subst)) continue;
            if (k == .property and !try sameExtensionReceiver(s, m, cand.sym, cand.subst)) continue;
            if (try platformDependent(s, cand.sym)) continue;
            return cand.sym;
        }
    }
    return .none;
}

fn platformDependent(s: *Sema, m: Sym) Allocator.Error!bool {
    const anns: []const ast.Annotation = switch (s.syms.get(m).decl) {
        .function => |f| f.annotations,
        .property => |p| p.annotations,
        else => return false,
    };
    return headers.annotatedWith(s, .{ .decl = m, .file = s.syms.get(m).file }, anns, s.builtins.platform_dependent);
}

/// Two member properties with the same name override when both or neither
/// are extensions, on the same receiver type.
fn sameExtensionReceiver(s: *Sema, a: Sym, b: Sym, b_subst: *const types.Subst) Allocator.Error!bool {
    try headers.propertyHeader(s, a);
    try headers.propertyHeader(s, b);
    const ar = s.syms.propertyInfo(a).receiver;
    const br = s.syms.propertyInfo(b).receiver;
    if ((ar == .none) != (br == .none)) return false;
    if (ar == .none) return true;
    return sameErasure(s, ar, try s.types.substitute(br, b_subst));
}

/// Whether a function is an `operator`: declared so, or overriding one
/// that is (an override does not repeat the modifier).
pub fn isOperator(s: *Sema, f: Sym) Allocator.Error!bool {
    const fl = s.syms.flags(f);
    if (fl.operator) return true;
    if (!fl.override) return false;
    if (s.operator_memo.get(f)) |v| return v;
    try s.operator_memo.put(s.arena, f, false);
    const cls = s.syms.owner(f);
    if (cls == .none or s.syms.kind(cls) != .class) return false;
    const none_subst = try s.arena.create(types.Subst);
    none_subst.* = .empty;
    for (try headers.supertypes(s, cls)) |st| {
        for (try lookup(s, st, s.syms.name(f), .function)) |m| {
            if (!try sameSignature(s, f, none_subst, m.sym, m.subst)) continue;
            if (try isOperator(s, m.sym)) {
                try s.operator_memo.put(s.arena, f, true);
                return true;
            }
        }
    }
    return false;
}

/// `ms` without the member extension properties (`val A.x` declared in a
/// class): one is read on an extension receiver, with an instance of its
/// class an implicit receiver, not as a member of the value it is read on.
pub fn withoutExtensionProperties(s: *Sema, ms: []const Member) Allocator.Error![]const Member {
    var ext: usize = 0;
    for (ms) |m| {
        if (s.syms.kind(m.sym) != .property) continue;
        try headers.propertyHeader(s, m.sym);
        if (s.syms.propertyInfo(m.sym).receiver != .none) ext += 1;
    }
    if (ext == 0) return ms;
    var out: std.ArrayList(Member) = .empty;
    for (ms) |m| {
        if (s.syms.kind(m.sym) == .property and s.syms.propertyInfo(m.sym).receiver != .none) continue;
        try out.append(s.arena, m);
    }
    return out.items;
}

/// Whether a function can be called infix: declared `infix`, or
/// overriding one that is (an override does not repeat the modifier).
pub fn isInfix(s: *Sema, f: Sym) Allocator.Error!bool {
    const fl = s.syms.flags(f);
    if (fl.infix) return true;
    if (!fl.override) return false;
    for (try overridden(s, f)) |o| {
        if (s.syms.kind(o) == .function and try isInfix(s, o)) return true;
    }
    return false;
}

/// The member type of a member as seen through the receiver: its declared
/// type with the declaring class's parameters substituted.
pub fn memberType(s: *Sema, m: Member) Allocator.Error!TypeId {
    return switch (s.syms.kind(m.sym)) {
        .property => s.types.substitute(try headers.propertyType(s, m.sym), m.subst),
        .function => s.types.substitute(try headers.returnType(s, m.sym), m.subst),
        .enum_entry => headers.selfType(s, s.syms.entryInfo(m.sym).enum_class),
        else => s.types.errType(),
    };
}
