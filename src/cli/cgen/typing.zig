//! The machine type of every register of one body. A register is a
//! mutable local: its definitions are joined, and one that holds values of
//! two kinds is a reference, boxed at each definition. Solved to a fixed
//! point, since a definition's kind follows its operands'.

const std = @import("std");
const ir = @import("ir");

const ctype = @import("ctype.zig");
const sig_mod = @import("sig.zig");
const Ty = ctype.Ty;
const Sig = sig_mod.Sig;
const Sigs = sig_mod.Sigs;

const Allocator = std.mem.Allocator;
const ClassId = ir.ClassId;
const Reg = ir.Reg;

/// A register's kind while the solve runs: nothing seen yet, one kind, or
/// a reference because its definitions disagree.
const Kind = union(enum) {
    none,
    ty: Ty,

    fn join(a: Kind, b: Kind) Kind {
        return switch (a) {
            .none => b,
            .ty => |x| switch (b) {
                .none => a,
                .ty => |y| if (x == y) a else .{ .ty = .object },
            },
        };
    }
};

/// The static class a reference register holds, where every definition
/// agrees on one.
const Cls = union(enum) {
    none,
    known: ClassId,
    many,

    fn join(a: Cls, b: Cls) Cls {
        return switch (a) {
            .none => b,
            .many => .many,
            .known => |x| switch (b) {
                .none => a,
                .many => .many,
                .known => |y| if (x == y) a else .many,
            },
        };
    }
};

pub const Typing = struct {
    tys: []Ty,
    cls: []?ClassId,

    pub fn deinit(self: *Typing, a: Allocator) void {
        a.free(self.tys);
        a.free(self.cls);
    }
};

/// The result kind of a primitive binary operator over operands of kinds
/// `l` and `r`, as Kotlin types it; null when an operand is a reference,
/// which the runtime computes.
pub fn binResult(op: ir.BinOp, l: Ty, r: Ty) ?Ty {
    switch (op) {
        .Eq, .NotEq, .Less, .LessEq, .Greater, .GreaterEq, .BoxedEq, .BoxedNotEq, .IdentEq, .IdentNeq => return .boolean,
        .StringConcat, .RangeTo, .RangeUntil, .DownTo, .Elvis => return .object,
        else => {},
    }
    if (l == .object or r == .object) return null;
    switch (op) {
        .And, .Or, .Xor => {
            if (l == .boolean and r == .boolean) return .boolean;
            if (l == r) return l;
            return null;
        },
        // The shift count is an Int; the result keeps the left operand's kind.
        .Shl, .Shr, .UShr => return if (l == .i32 or l == .i64 or l == .u32 or l == .u64) l else null,
        .Add, .Sub, .Mul, .Div, .Mod => return arith(op, l, r),
        .Pow => return .f64,
        else => return null,
    }
}

/// Kotlin's arithmetic result kinds: the wider of the two, `Int` for the
/// narrow integers, and `Char` arithmetic as `Char` plus `Int` gives it.
fn arith(op: ir.BinOp, l: Ty, r: Ty) ?Ty {
    if (l == .char or r == .char) {
        if (l == .char and r == .char) return if (op == .Sub) .i32 else null;
        if (l == .char and (r == .i32 or r == .short or r == .byte)) return if (op == .Add or op == .Sub) .char else null;
        if (r == .char and l == .i32 and op == .Add) return .char;
        return null;
    }
    if (l.isUnsigned() or r.isUnsigned()) {
        if (!l.isUnsigned() or !r.isUnsigned()) return null;
        if (l == .u64 or r == .u64) return .u64;
        return .u32;
    }
    if (!l.isNumeric() or !r.isNumeric()) return null;
    if (l == .f64 or r == .f64) return .f64;
    if (l == .f32 or r == .f32) return .f32;
    if (l == .i64 or r == .i64) return .i64;
    return .i32;
}

/// The result kind of a unary operator on a value of kind `t`; null for a
/// reference.
pub fn unResult(op: ir.UnOp, t: Ty) ?Ty {
    if (t == .object) return null;
    return switch (op) {
        // `-b` on a Byte or Short is an Int.
        .Neg, .Plus => switch (t) {
            .short, .byte => .i32,
            .char, .boolean, .unit => null,
            else => t,
        },
        .Inc, .Dec => switch (t) {
            .boolean, .unit => null,
            else => t,
        },
    };
}

pub const Ctx = struct {
    sigs: *Sigs,
    f: *const ir.Func,
    sig: Sig,
};

/// Solves the kinds of `f`'s registers.
pub fn solve(a: Allocator, ctx: Ctx) Allocator.Error!Typing {
    const f = ctx.f;
    const n = f.n_locals;
    const kinds = try a.alloc(Kind, n);
    defer a.free(kinds);
    @memset(kinds, .none);
    const cls = try a.alloc(Cls, n);
    defer a.free(cls);
    @memset(cls, .none);
    var changed = true;
    var rounds: u32 = 0;
    while (changed and rounds < 64) : (rounds += 1) {
        changed = false;
        for (f.blocks) |*blk| {
            for (blk.h().catches) |h| {
                if (try define(kinds, cls, h.exception_reg, .{ .ty = .object }, .{ .known = h.class })) changed = true;
            }
            for (blk.insts) |*inst| {
                if (try step(ctx, kinds, cls, inst)) changed = true;
            }
        }
    }
    const tys = try a.alloc(Ty, n);
    const out_cls = try a.alloc(?ClassId, n);
    for (kinds, cls, tys, out_cls) |k, c, *t, *oc| {
        t.* = switch (k) {
            .none => .unit,
            .ty => |x| x,
        };
        oc.* = if (t.* == .object) switch (c) {
            .known => |id| id,
            else => null,
        } else null;
    }
    return .{ .tys = tys, .cls = out_cls };
}

fn define(kinds: []Kind, cls: []Cls, r: Reg, k: Kind, c: Cls) Allocator.Error!bool {
    const i = r.int();
    if (i >= kinds.len) return false;
    const nk = kinds[i].join(k);
    const nc = cls[i].join(c);
    const moved = !std.meta.eql(nk, kinds[i]) or !std.meta.eql(nc, cls[i]);
    kinds[i] = nk;
    cls[i] = nc;
    return moved;
}

fn kindOf(kinds: []const Kind, r: Reg) ?Ty {
    const i = r.int();
    if (i >= kinds.len) return .object;
    return switch (kinds[i]) {
        .none => null,
        .ty => |t| t,
    };
}

fn clsOf(cls: []const Cls, r: Reg) Cls {
    const i = r.int();
    if (i >= cls.len) return .many;
    return cls[i];
}

fn objOf(c: ?ClassId) Cls {
    return if (c) |id| .{ .known = id } else .many;
}

fn step(ctx: Ctx, kinds: []Kind, cls: []Cls, inst: *const ir.Inst) Allocator.Error!bool {
    const sigs = ctx.sigs;
    const T = struct {
        fn ty(t: Ty) Kind {
            return .{ .ty = t };
        }
    };
    switch (inst.*) {
        .Const => |x| {
            const c = ctx.sigs.m.consts.items[x.value.int()];
            return define(kinds, cls, x.dst, T.ty(ctype.constTy(c)), .many);
        },
        .LoadParam => |x| {
            const t: Ty = if (x.idx < ctx.sig.params.len) ctx.sig.params[x.idx] else .object;
            const c: ?ClassId = if (x.idx < ctx.sig.param_cls.len) ctx.sig.param_cls[x.idx] else null;
            return define(kinds, cls, x.dst, T.ty(t), objOf(c));
        },
        .Move => |x| {
            const t = kindOf(kinds, x.src) orelse return false;
            return define(kinds, cls, x.dst, T.ty(t), clsOf(cls, x.src));
        },
        inline .LoadCapture, .MakeCell, .CellGet => |x| return define(kinds, cls, x.dst, T.ty(.object), .many),
        .GetFieldSlot => |x| {
            const t: Ty = switch (clsOf(cls, x.obj)) {
                .known => |c| sigs.fieldTy(c, x.slot),
                .none => return false,
                .many => .object,
            };
            return define(kinds, cls, x.dst, T.ty(t), .many);
        },
        .LoadStatic => |x| return define(kinds, cls, x.dst, T.ty(sigs.staticTy(x.static)), .many),
        .LoadObject => |x| return define(kinds, cls, x.dst, T.ty(.object), .{ .known = x.class }),
        .RNewInstance => |x| {
            // A host-backed class's native constructor makes a host value.
            const native = sigs.r.func_native.len > x.ctor.int() and sigs.r.func_native[x.ctor.int()] != .none;
            return define(kinds, cls, x.dst, T.ty(.object), if (native) .many else .{ .known = x.class });
        },
        inline .MakeClosure, .FunctionRef, .RPropertyRef, .ClassLiteral, .ClassOf, .NewArray, .ArrayGet, .RCallValue => |x| return define(kinds, cls, x.dst, T.ty(.object), .many),
        inline .RInstanceOf, .InstanceOfDyn, .Not => |x| return define(kinds, cls, x.dst, T.ty(.boolean), .many),
        .RCast => |x| {
            if (!x.safe and !x.nullable) if (hostScalar(sigs, x.class)) |t| return define(kinds, cls, x.dst, T.ty(t), .many);
            return define(kinds, cls, x.dst, T.ty(.object), .{ .known = x.class });
        },
        .CastDyn => |x| return define(kinds, cls, x.dst, T.ty(.object), .many),
        inline .NotNullAssert, .LateinitCheck => |x| {
            const t = kindOf(kinds, x.src) orelse return false;
            return define(kinds, cls, x.dst, T.ty(t), clsOf(cls, x.src));
        },
        .BinOp => |x| {
            const l = kindOf(kinds, x.lhs) orelse return false;
            const r = kindOf(kinds, x.rhs) orelse return false;
            return define(kinds, cls, x.dst, T.ty(binResult(x.op, l, r) orelse .object), .many);
        },
        .UnOp => |x| {
            const t = kindOf(kinds, x.operand) orelse return false;
            return define(kinds, cls, x.dst, T.ty(unResult(x.op, t) orelse .object), .many);
        },
        .CallStatic => |x| {
            const sg = try sigs.of(x.func);
            const t: Ty = if (sigs.r.func_native.len > x.func.int() and sigs.r.func_native[x.func.int()] != .none) try sigs.nativeRet(sigs.r.func_native[x.func.int()]) else sg.ret;
            return define(kinds, cls, x.dst, T.ty(t), objOf(sg.ret_cls));
        },
        .CallNative => |x| return define(kinds, cls, x.dst, T.ty(try sigs.nativeRet(x.native)), .many),
        .RCallVirtual => |x| {
            const sg = try sigs.of(ir.FuncId.from(x.slot.int()));
            return define(kinds, cls, x.dst, T.ty(sg.ret), objOf(sg.ret_cls));
        },
        .CallInterface => |x| {
            const sg = try sigs.of(ir.FuncId.from(x.slot.int()));
            return define(kinds, cls, x.dst, T.ty(sg.ret), objOf(sg.ret_cls));
        },
        else => return false,
    }
}

/// The scalar kind a host class's non-null values are, for a cast to it.
fn hostScalar(sigs: *Sigs, c: ClassId) ?Ty {
    const h = &sigs.r.host_class;
    const pairs = [_]struct { ?ClassId, Ty }{
        .{ h.int, .i32 },     .{ h.long, .i64 },   .{ h.double, .f64 }, .{ h.float, .f32 },
        .{ h.boolean, .boolean }, .{ h.char, .char }, .{ h.short, .short }, .{ h.byte, .byte },
        .{ h.uint, .u32 },    .{ h.ulong, .u64 },  .{ h.ushort, .u16 }, .{ h.ubyte, .u8 },
    };
    for (pairs) |p| {
        if (p[0]) |hc| if (hc == c) return p[1];
    }
    return null;
}

test "arithmetic kinds follow Kotlin's operator signatures" {
    try std.testing.expectEqual(Ty.i32, binResult(.Add, .i32, .i32).?);
    try std.testing.expectEqual(Ty.i64, binResult(.Mul, .i32, .i64).?);
    try std.testing.expectEqual(Ty.f64, binResult(.Div, .f32, .f64).?);
    try std.testing.expectEqual(Ty.i32, binResult(.Add, .byte, .short).?);
    try std.testing.expectEqual(Ty.char, binResult(.Add, .char, .i32).?);
    try std.testing.expectEqual(Ty.i32, binResult(.Sub, .char, .char).?);
    try std.testing.expectEqual(Ty.u32, binResult(.Add, .u8, .u8).?);
    try std.testing.expectEqual(Ty.boolean, binResult(.Less, .object, .i32).?);
    try std.testing.expect(binResult(.Add, .object, .i32) == null);
    try std.testing.expectEqual(Ty.i64, binResult(.Shl, .i64, .i32).?);
    try std.testing.expectEqual(Ty.i32, unResult(.Neg, .byte).?);
    try std.testing.expectEqual(Ty.byte, unResult(.Inc, .byte).?);
}
