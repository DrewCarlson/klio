//! Value classes held as their number (`plans/value-classes.md`). A scalar
//! class's value is its underlying number wherever its static type is the
//! class itself, and the boxed instance anywhere else. The register an
//! expression lowers to holds the representation of the expression's static
//! type, so a value converts only where it enters or leaves a place of
//! another type, and every such place converts through `coerce`.

const std = @import("std");
const sema = @import("sema");

const ir = @import("../../ir.zig");
const builder = @import("builder.zig");
const classes = @import("classes.zig");
const operator = @import("operator.zig");
const records = @import("records.zig");

const Builder = builder.Builder;
const Error = records.Error;
const Reg = ir.Reg;
const Sym = sema.Sym;
const TypeId = sema.TypeId;

/// A class held as its number: the class and the field its instance keeps
/// the number in.
pub const Scalar = struct { class: ir.ClassId, slot: u32 };

/// The scalar class a value of static type `t` is held as the number of:
/// `t` is that class, not nullable, or an intersection one of whose parts
/// is (a smart cast).
pub fn scalarOf(b: *Builder, t: TypeId) Error!?Scalar {
    if (t == .none) return null;
    const s = b.p.s;
    switch (s.types.get(t)) {
        .class => |c| {
            if (c.nullable) return null;
            return scalarClass(b, c.sym);
        },
        .intersection => |parts| {
            for (parts) |p| if (try scalarOf(b, p)) |sc| return sc;
            return null;
        },
        else => return null,
    }
}

/// Whether `cls` is held as its number: a final value class declared
/// outside `kotlin.*`, extending no class, whose one field holds a primitive
/// other than `String`, or an unsigned number.
pub fn scalarClass(b: *Builder, cls: Sym) Error!?Scalar {
    if (cls == .none) return null;
    const p = b.p;
    if (p.scalar_classes.get(cls)) |known| return known;
    const answer = try decide(b, cls);
    try p.scalar_classes.put(p.a, cls, answer);
    return answer;
}

fn decide(b: *Builder, cls: Sym) Error!?Scalar {
    const s = b.p.s;
    if (s.syms.kind(cls) != .class) return null;
    const fl = s.syms.flags(cls);
    if (!fl.value or fl.modality != .final) return null;
    if (std.mem.startsWith(u8, s.str(s.syms.classInfo(cls).fqn), "kotlin.")) return null;
    // A value class extending another (`FullValueClasses`) has its
    // superclass's initialization to run.
    for (try sema.headers.supertypes(s, cls)) |st| {
        const sup = s.types.classSym(st);
        if (sup == .none or sup == s.builtins.any) continue;
        if (s.syms.kind(sup) == .class and s.syms.classInfo(sup).kind != .interface) return null;
    }
    const prop = classes.valueProperty(b, cls) orelse return null;
    const slot = b.p.br.fieldOf(prop) orelse return null;
    const id = b.p.br.classOfOpt(cls) orelse return null;
    const t = try sema.headers.propertyType(s, prop);
    if (s.types.isNullable(t)) return null;
    const number = if (operator.primOf(s, t)) |prim| prim != .string else operator.unsignedOf(s, t) != null;
    if (!number) return null;
    return .{ .class = id, .slot = slot };
}

/// The type of the number a value of scalar class type `t` holds; `.none`
/// when `t` is no scalar class.
pub fn numberType(b: *Builder, t: TypeId) Error!TypeId {
    if ((try scalarOf(b, t)) == null) return .none;
    const s = b.p.s;
    const cls = switch (s.types.get(t)) {
        .class => |c| c.sym,
        else => return .none,
    };
    const prop = classes.valueProperty(b, cls) orelse return .none;
    return sema.headers.propertyType(s, prop);
}

/// The scalar class whose value property `p` is: reading it is the number.
pub fn valuePropertyOf(b: *Builder, p: Sym) Error!?Scalar {
    const s = b.p.s;
    const cls = s.syms.owner(p);
    if (cls == .none or s.syms.kind(cls) != .class) return null;
    const sc = (try scalarClass(b, cls)) orelse return null;
    if (classes.valueProperty(b, cls) != p) return null;
    return sc;
}

/// `r`, a value of static type `from`, as a value of static type `to`
/// (`.none`: a place a value is always boxed in): boxed where `from` is a
/// scalar class and `to` is not, unboxed where `to` is one. Both are the
/// value itself when it is in that form already, so a value of a scalar
/// class's type may be in either form; one of any other type is never a
/// bare number.
pub fn coerce(b: *Builder, r: Reg, from: TypeId, to: TypeId) Error!Reg {
    return convert(b, r, try scalarOf(b, from), try scalarOf(b, to));
}

/// `coerce` between the scalar classes (or none) the two types are.
pub fn convert(b: *Builder, r: Reg, from: ?Scalar, to: ?Scalar) Error!Reg {
    if (to) |ts| {
        if (from) |fs| if (fs.class == ts.class) return r;
        return unbox(b, r, ts);
    }
    if (from) |fs| return box(b, r, fs);
    return r;
}

/// The declarations at the top of `f`'s override family: those it
/// overrides, directly or not, that override nothing; `f` itself when it
/// overrides nothing.
fn roots(b: *Builder, f: Sym) Error![]const Sym {
    const p = b.p;
    if (p.family_roots.get(f)) |known| return known;
    var out: std.ArrayList(Sym) = .empty;
    try collectRoots(b, f, &out, 0);
    const list = try out.toOwnedSlice(p.a);
    try p.family_roots.put(p.a, f, list);
    return list;
}

fn collectRoots(b: *Builder, f: Sym, out: *std.ArrayList(Sym), depth: u8) Error!void {
    const over = if (depth < 32) try sema.members.overridden(b.p.s, f) else &.{};
    if (over.len == 0) {
        for (out.items) |x| if (x == f) return;
        return out.append(b.p.a, f);
    }
    for (over) |o| try collectRoots(b, o, out, depth + 1);
}

const Position = union(enum) { param: usize, result, receiver };

/// The scalar class the value at `pos` of `f` is held as the number of:
/// the one every root of `f`'s override family declares there, as the JVM
/// gives an override its root's signature. A generic root (`compareTo(other:
/// T)`) holds it boxed, and so does a family whose roots disagree.
fn familyHeld(b: *Builder, f: Sym, pos: Position) Error!?Scalar {
    if (f == .none) return null;
    const rs = try roots(b, f);
    var agreed: ?Scalar = null;
    for (rs, 0..) |r, i| {
        const t = (try positionType(b, r, pos)) orelse return null;
        const sc = try scalarOf(b, t);
        if (i == 0) {
            agreed = sc;
            continue;
        }
        if (sc == null or agreed == null or sc.?.class != agreed.?.class) return null;
    }
    return agreed;
}

fn positionType(b: *Builder, f: Sym, pos: Position) Error!?TypeId {
    const s = b.p.s;
    return switch (pos) {
        .param => |i| blk: {
            if (s.syms.kind(f) != .function and s.syms.kind(f) != .constructor) break :blk null;
            const params = s.syms.functionInfo(f).params;
            if (i >= params.len) break :blk null;
            break :blk try sema.headers.paramType(s, params[i]);
        },
        .result => switch (s.syms.kind(f)) {
            .function => try sema.headers.returnType(s, f),
            .property => try sema.headers.propertyType(s, f),
            else => null,
        },
        .receiver => try sema.headers.receiverType(s, f),
    };
}

/// The scalar class parameter `p` of `f` is held as the number of.
pub fn paramHeld(b: *Builder, f: Sym, p: Sym) Error!?Scalar {
    const s = b.p.s;
    const k = s.syms.kind(f);
    if (k != .function and k != .constructor) return scalarOf(b, try sema.headers.paramType(s, p));
    const params = s.syms.functionInfo(f).params;
    const i = std.mem.indexOfScalar(Sym, params, p) orelse return scalarOf(b, try sema.headers.paramType(s, p));
    if (k == .constructor) return scalarOf(b, try sema.headers.paramType(s, p));
    return familyHeld(b, f, .{ .param = i });
}

/// The scalar class `f`'s result is held as the number of (a constructor's:
/// its class).
pub fn returnHeld(b: *Builder, f: Sym) Error!?Scalar {
    const s = b.p.s;
    return switch (s.syms.kind(f)) {
        .constructor => scalarClass(b, s.syms.owner(f)),
        .function, .property => familyHeld(b, f, .result),
        else => null,
    };
}

/// The scalar class `f`'s extension receiver is held as the number of.
pub fn receiverHeld(b: *Builder, f: Sym) Error!?Scalar {
    return familyHeld(b, f, .receiver);
}

/// The scalar class member `f`'s dispatch receiver is held as the number
/// of: its class's. A member of a scalar class is final and called on its
/// number; one dispatch reaches on a box unboxes `this` as it starts.
pub fn dispatchHeld(b: *Builder, f: Sym) Error!?Scalar {
    const s = b.p.s;
    const owner = s.syms.owner(f);
    if (owner == .none or s.syms.kind(owner) != .class) return null;
    return scalarClass(b, owner);
}

/// Whether `f` is a function literal: a closure over it is called through
/// its function type, whose parameters and result are generic.
pub fn isLiteral(b: *Builder, f: Sym) bool {
    return switch (b.p.s.syms.get(f).decl) {
        .lambda, .anon_fun => true,
        else => false,
    };
}

/// The scalar class a `return` to `f` gives its value as the number of:
/// none for a function literal, else `returnHeld`.
pub fn returnTo(b: *Builder, f: Sym) Error!?Scalar {
    if (f == .none or isLiteral(b, f)) return null;
    return returnHeld(b, f);
}

/// The scalar class the implicit receiver `r` is a value of.
pub fn implicitScalar(b: *Builder, r: sema.records.Receiver) Error!?Scalar {
    const s = b.p.s;
    const im = switch (r) {
        .implicit => |im| im,
        else => return null,
    };
    return switch (im.kind) {
        .class_this => scalarClass(b, im.owner),
        .extension => scalarOf(b, try sema.headers.receiverType(s, im.owner)),
        .lambda => scalarOf(b, s.syms.functionInfo(im.owner).receiver),
        .context => scalarOf(b, try sema.headers.paramType(s, im.owner)),
        else => null,
    };
}

/// The instance of `sc` over the number in `r` (or `r` itself when it is
/// one already).
pub fn box(b: *Builder, r: Reg, sc: Scalar) Error!Reg {
    const dst = b.newReg();
    try b.emit(.{ .BoxValue = .{ .dst = dst, .src = r, .class = sc.class, .slot = sc.slot } });
    return dst;
}

/// The number an instance of `sc` in `r` holds (or `r` itself when it is
/// a number already).
pub fn unbox(b: *Builder, r: Reg, sc: Scalar) Error!Reg {
    if (b.unboxed.get(r)) |c| if (c == sc.class) return r;
    const dst = b.newReg();
    try b.emit(.{ .UnboxValue = .{ .dst = dst, .src = r, .class = sc.class, .slot = sc.slot } });
    try b.unboxed.put(b.p.a, dst, sc.class);
    return dst;
}
