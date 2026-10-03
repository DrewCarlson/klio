//! Callable references: function, bound member, property and constructor
//! references, class literals, and the adapters that bind and adapt them.
//!
//! A function or constructor reference is a `FunctionRef` over the adapter
//! the bridge allocated for it, whose body calls the target with the
//! reference's parameters, a bound receiver (capture 0) in the place the
//! target takes it. A reference to a local function or local class carries
//! their captures too, as a closure over the adapter. A property reference
//! is an `RPropertyRef` over the property's accessors.

const std = @import("std");
const span = @import("span");
const ast = @import("ast");
const sema = @import("sema");

const ir = @import("../../ir.zig");
const bridge = @import("../../core/bridge.zig");
const builder = @import("builder.zig");
const records = @import("records.zig");
const env = @import("env.zig");
const body = @import("body.zig");
const coerce = @import("coerce.zig");
const call = @import("call.zig");
const dispatch = @import("dispatch.zig");
const types = @import("types.zig");
const name_mod = @import("name.zig");

const Builder = builder.Builder;
const Error = records.Error;
const CallRec = records.CallRec;
const RefRec = records.RefRec;
const FuncId = ir.FuncId;
const Reg = ir.Reg;
const Sym = sema.Sym;

/// A `PropertyRef` or `MemberRef`: a callable reference, or a class
/// literal (`C::class`, `x::class`, a reified `T::class`).
pub fn lowerCallableRef(b: *Builder, e: *const ast.Expr) Error!Reg {
    const id = e.id();
    if (sema.output.ref(b.recs, id)) |rr| return reference(b, e, &rr) else |_| {}
    const t = try b.typeTest(id);
    switch (t.kind) {
        .class_literal => return types.classValue(b, t.ty),
        .class_of => {
            const recv = switch (e.*) {
                .MemberRef => |m| m.receiver,
                else => return b.fail(e.span(), "`::class` of no value", .{}),
            };
            // A scalar class's value answers its class boxed.
            const v = try coerce.coerce(b, try body.lowerExpr(b, recv), b.exprType(recv.id()), .none);
            const dst = b.newReg();
            try b.emit(.{ .ClassOf = .{ .dst = dst, .src = v } });
            return dst;
        },
        else => return b.fail(e.span(), "a reference whose record is a type test", .{}),
    }
}

/// An accessor's root slot, by the function it names, for a reference that
/// dispatches on its receiver; the accessor itself otherwise.
fn rootOf(br: *const bridge.Bridge, f: ir.FuncId, virtual: bool) ir.FuncId {
    if (!virtual) return f;
    const slot = br.slotOf(f) orelse return f;
    return ir.FuncId.from(slot.int());
}

fn reference(b: *Builder, e: *const ast.Expr, rr: *const RefRec) Error!Reg {
    const s = b.p.s;
    const br = b.p.br;
    const bound = try boundValue(b, e, rr);
    switch (s.syms.kind(rr.target)) {
        .property => {
            const dst = b.newReg();
            const n = try b.p.m.internConst(b.p.a, .{ .String = s.str(s.syms.name(rr.target)) });
            // An overridable member's accessors by their root slots, which
            // the receiver's class dispatches.
            const virtual = env.hasThis(s, rr.target) and !name_mod.finalMember(s, rr.target);
            const getter = rootOf(br, br.getterOf(rr.target), virtual);
            const setter: u32 = if (br.setterOf(rr.target)) |f| rootOf(br, f, virtual).int() else ir.NO_FUNC;
            try b.emit(.{ .RPropertyRef = .{ .dst = dst, .getter = getter, .setter = setter, .bound = bound, .name = n } });
            return dst;
        },
        .function, .constructor => {},
        else => return b.fail(e.span(), "a reference to `{s}`", .{s.str(s.syms.name(rr.target))}),
    }
    const adapter = br.adapterFor(b.file, e.id());
    if (adapter.int() == bridge.NONE) return b.fail(e.span(), "a function reference without an adapter", .{});
    const target = br.funcOfOpt(rr.target) orelse return b.fail(e.span(), "`{s}` has no id", .{s.str(s.syms.name(rr.target))});
    const caps = br.capturesOf(adapter);
    const dst = b.newReg();
    if (caps.len == 0) {
        try b.emit(.{ .FunctionRef = .{ .dst = dst, .adapter = adapter, .target = target, .bound = bound } });
        return dst;
    }
    var regs: std.ArrayList(Reg) = .empty;
    if (bound) |r| try regs.append(b.sa, r);
    try regs.appendSlice(b.sa, try env.materializeCaptures(b, caps));
    try b.emit(.{ .MakeClosure = .{ .dst = dst, .func = adapter, .captures = regs.items } });
    return dst;
}

/// The receiver a reference binds: the value written before `::`, an
/// implicit receiver the record names, or none.
fn boundValue(b: *Builder, e: *const ast.Expr, rr: *const RefRec) Error!?Reg {
    switch (rr.bound) {
        .expr => {
            const recv = switch (e.*) {
                .MemberRef => |m| m.receiver,
                else => return b.fail(e.span(), "a bound reference without a receiver", .{}),
            };
            return try body.lowerExpr(b, recv);
        },
        .implicit => |im| return try env.receiver(b, im.kind, im.owner),
        .none => {},
    }
    return switch (rr.extension) {
        .implicit => |im| try env.receiver(b, im.kind, im.owner),
        // `x::ext`: the value written before `::` is the extension receiver.
        .expr => switch (e.*) {
            .MemberRef => |m| try body.lowerExpr(b, m.receiver),
            else => b.fail(e.span(), "a bound extension reference without a receiver", .{}),
        },
        .none => null,
    };
}

/// The body of adapter `adapter` (`Bridge.adapters`): its parameters are
/// the reference's function type's; a bound receiver is capture 0, a local
/// target's captures follow it.
pub fn lowerAdapter(b: *Builder, adapter: u32) Error!void {
    const s = b.p.s;
    const br = b.p.br;
    const a = b.sa;
    const ad = br.adapters[adapter];
    const target = ad.target;
    const lay = call.layoutOf(b.p, target);
    const is_ctor = s.syms.kind(target) == .constructor;
    const arity: u16 = @intCast(paramCount(b));
    const n_values = lay.values;
    const ref = refOf(b, ad);
    const adapt = if (ref) |x| x.adapt else sema.records.RefAdapt{};
    // A vararg the reference's parameters fill element by element: the
    // values before it, its elements, and defaults for every one after.
    const vararg_at: ?u16 = if (adapt.vararg_elems) varargIndex(s, target) else null;
    const given_values: u16 = if (vararg_at) |vi| vi + 1 else n_values - @min(n_values, adapt.defaults);
    // What the target takes as receivers, and how many the reference's
    // parameters supply.
    const receivers: u16 = if (is_ctor)
        @intFromBool(env.outerOf(s, s.syms.owner(target)) != null)
    else
        @as(u16, @intFromBool(lay.this)) + @intFromBool(lay.ext);
    const params_receivers: u16 = if (vararg_at != null)
        receivers - @min(receivers, @as(u16, @intFromBool(ad.bound != .none)))
    else
        arity -| given_values;
    if (params_receivers > receivers) return b.fail(b.cur_span, "a reference with more parameters than its target takes", .{});
    const n_bound = receivers - params_receivers;
    if (n_bound > 1) return b.fail(b.cur_span, "a reference binding two receivers", .{});
    if (lay.contexts != 0) return b.fail(b.cur_span, "a reference to a function with context parameters", .{});
    // A reified type parameter takes the type the reference's expected
    // type fixed, recorded with the reference.
    const type_args: []const sema.TypeId = if (ref) |x| x.type_args else &.{};
    if (lay.reified != 0 and type_args.len == 0) return b.fail(b.cur_span, "a reference to a function with reified type parameters and no type arguments", .{});

    var cap: u16 = 0;
    var param: u16 = 0;
    const bound: ?Reg = if (n_bound == 1) try loadCapture(b, &cap) else null;
    var bound_used = false;
    var run: std.ArrayList(Reg) = .empty;
    if (is_ctor) {
        const cls = s.syms.owner(target);
        if (env.outerOf(s, cls) != null) {
            try run.append(a, if (bound) |r| blk: {
                bound_used = true;
                break :blk r;
            } else try loadParam(b, &param));
        }
        switch (s.syms.classInfo(cls).kind) {
            .enum_class, .enum_entry => return b.fail(b.cur_span, "a reference to an enum constructor", .{}),
            else => {},
        }
        // A local class's captures, after the bound receiver.
        for (br.capturesOf(b.func)) |_| try run.append(a, try loadCapture(b, &cap));
    } else {
        if (lay.this) {
            try run.append(a, if (bound != null and !bound_used) blk: {
                bound_used = true;
                break :blk bound.?;
            } else try loadParam(b, &param));
        }
        // A local target's captures.
        if (lay.hidden != 0) {
            var k: u16 = 0;
            while (k < lay.hidden) : (k += 1) try run.append(a, try loadCapture(b, &cap));
        }
        if (lay.ext) {
            try run.append(a, if (bound != null and !bound_used) blk: {
                bound_used = true;
                break :blk bound.?;
            } else try loadParam(b, &param));
        }
    }
    var k: u16 = 0;
    if (vararg_at) |vi| {
        while (k < vi) : (k += 1) try run.append(a, try loadParam(b, &param));
        const elems = arity -| (params_receivers + vi);
        var regs: std.ArrayList(Reg) = .empty;
        var e: u16 = 0;
        while (e < elems) : (e += 1) try regs.append(a, try loadParam(b, &param));
        const vp = s.syms.functionInfo(target).params[vi];
        const arr_t = try s.varargArrayType(s.syms.paramInfo(vp).ty);
        const arr_cls = br.classOfOpt(s.types.classSym(arr_t)) orelse return b.fail(b.cur_span, "the array a vararg parameter takes has no class", .{});
        const arr = b.newReg();
        try b.emit(.{ .NewArray = .{ .dst = arr, .class = arr_cls, .args = try b.run(regs.items), .n_args = @intCast(regs.items.len) } });
        try run.append(a, arr);
        k = vi + 1;
    } else {
        while (k < given_values) : (k += 1) try run.append(a, try loadParam(b, &param));
    }
    // Trailing parameters the reference leaves to their defaults.
    var masks: []u32 = &.{};
    var reified: std.ArrayList(Reg) = .empty;
    if (lay.reified != 0) {
        for (s.syms.functionInfo(target).type_params, 0..) |tp, i| {
            if (!s.syms.flags(tp).reified) continue;
            if (i >= type_args.len) return b.fail(b.cur_span, "a reference to a function with reified type parameters and no type arguments", .{});
            try reified.append(a, try types.typeValue(b, type_args[i]));
        }
    }
    if (given_values < n_values) {
        masks = try a.alloc(u32, call.maskWords(n_values));
        @memset(masks, 0);
        k = given_values;
        while (k < n_values) : (k += 1) {
            try run.append(a, try b.unit());
            masks[k / 32] |= @as(u32, 1) << @intCast(k % 32);
        }
    }
    try run.appendSlice(a, reified.items);
    for (masks) |w| try run.append(a, try b.emitConst(.{ .Int = @bitCast(w) }));

    const dst = b.newReg();
    const first = try b.run(run.items);
    const n: u32 = @intCast(run.items.len);
    if (is_ctor) {
        const cls = s.syms.owner(target);
        const c = br.classOfOpt(cls) orelse return b.fail(b.cur_span, "`{s}` has no class id", .{s.str(s.syms.name(cls))});
        const f = if (masks.len != 0) br.defaultsOf(target) orelse return noDefaults(b, target) else br.funcOf(target);
        try b.emit(.{ .RNewInstance = .{ .dst = dst, .class = c, .ctor = f, .args = first, .n_args = n } });
    } else {
        // A fun interface's SAM constructor (`::Supplier`) makes an
        // instance of the interface's SAM class, as a call of it does.
        const form: sema.records.CallForm = if (sema.render.samInterface(s, target) != null) .sam_ctor else .plain;
        var how = dispatch.choose(b.p, &CallRec{ .callee = target, .form = form }) catch
            return b.fail(b.cur_span, "`{s}` has no identity to call", .{s.str(s.syms.name(target))});
        // A reference to `enumEntries<E>` and its kin is `E`'s own member,
        // which the reference's type fixes, as a call of one is.
        if (call.enumIntrinsicOf(s, target)) |which| if (which != .entries_intrinsic and type_args.len == 1) {
            const cls = s.types.classSym(type_args[0]);
            if (cls == .none) return b.fail(b.cur_span, "a reference to `{s}` of a type parameter", .{s.str(s.syms.name(target))});
            const v = try call.enumIntrinsicCall(b, which, cls, run.items[0 .. run.items.len - reified.items.len - masks.len]);
            b.terminate(.{ .Return = if (adapt.drop_result) try b.unit() else v });
            return;
        };
        // A reference runs an inline function's ordinary body.
        switch (how) {
            .inline_ => |f| how = .{ .static = f },
            else => {},
        }
        if (masks.len != 0) how = .{ .static = br.defaultsOf(target) orelse return noDefaults(b, target) };
        try dispatch.emitHow(b, how, dst, first, n);
    }
    b.terminate(.{ .Return = if (adapt.drop_result) try b.unit() else dst });
}

fn varargIndex(s: *sema.Sema, f: Sym) ?u16 {
    for (s.syms.functionInfo(f).params, 0..) |p, i| {
        if (s.syms.flags(p).vararg) return @intCast(i);
    }
    return null;
}

fn noDefaults(b: *Builder, target: Sym) Error {
    const s = b.p.s;
    return b.fail(b.cur_span, "`{s}` has no defaults bridge", .{s.str(s.syms.name(target))});
}

/// The record of the references sharing this adapter, whose adaptation
/// and type arguments they all have: the first naming it.
/// Where a failure of adapter `adapter` is reported: the first reference
/// of its shape, whose lowering allocated it.
pub fn referenceSite(p: *const builder.Program, adapter: u32) span.Span {
    const ad = p.br.adapters[adapter];
    for (p.br.records) |fr| for (fr.refs) |r| switch (r.detail) {
        .ref => |x| if (x.target == ad.target and x.ty == ad.ty and std.meta.activeTag(x.bound) == ad.bound) return r.anchor,
        else => {},
    };
    return builder.zero_span;
}

fn refOf(b: *Builder, ad: bridge.Adapter) ?*const sema.records.RefRec {
    for (b.p.br.records) |fr| for (fr.refs) |r| switch (r.detail) {
        .ref => |x| if (x.target == ad.target and x.ty == ad.ty and std.meta.activeTag(x.bound) == ad.bound) return x,
        else => {},
    };
    return null;
}

fn paramCount(b: *const Builder) usize {
    return b.p.m.funcs.items[b.func.int()].params.len;
}

fn loadParam(b: *Builder, next: *u16) Error!Reg {
    const dst = b.newReg();
    try b.emit(.{ .LoadParam = .{ .dst = dst, .idx = next.* } });
    next.* += 1;
    return dst;
}

fn loadCapture(b: *Builder, next: *u16) Error!Reg {
    const dst = b.newReg();
    try b.emit(.{ .LoadCapture = .{ .dst = dst, .idx = next.* } });
    next.* += 1;
    return dst;
}
