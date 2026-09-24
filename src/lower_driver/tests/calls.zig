//! Package C2's tests: argument order, defaults, varargs, contexts,
//! receivers, super calls and the dispatch each call takes.
//!
//! The first tests check the argument mapping and the dispatch choice as
//! pure functions over hand-built records and a hand-built identity table.
//! The rest run programs end to end; each names the constructs of other
//! packages it relies on and is skipped until a probe program using them
//! prints what kotlinc prints. Every expected output is what kotlinc 2.4.20
//! prints for the same program.

const std = @import("std");
const span = @import("span");
const ast = @import("ast");
const lexer = @import("lexer");
const parser = @import("parser");
const sema = @import("sema");
const ir = @import("ir");
const driver = @import("../lower_driver.zig");

const lower = ir.lower_sema;
const call = lower.call;
const dispatch = lower.dispatch;
const ArgSource = sema.records.ArgSource;
const VarargPart = sema.records.VarargPart;
const CallRec = sema.records.CallRec;
const Sym = sema.Sym;
const testing = std.testing;

test {
    testing.refAllDecls(call);
    testing.refAllDecls(dispatch);
}

// ------------------------------------------------------ argument mapping --

test "an omitted argument sets its parameter's bit in the defaults mask" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = [_]ArgSource{ .{ .arg = 0 }, .default, .{ .arg = 1 } };
    try testing.expectEqualSlices(u32, &.{0b010}, try call.defaultMasks(a, &args, &.{ false, true, false }));
    const all = [_]ArgSource{ .default, .default };
    try testing.expectEqualSlices(u32, &.{0b11}, try call.defaultMasks(a, &all, &.{ true, true }));
    // Nothing omitted, no mask: the callee itself is called.
    const none = [_]ArgSource{ .{ .arg = 0 }, .{ .arg = 1 } };
    try testing.expectEqual(@as(usize, 0), (try call.defaultMasks(a, &none, &.{ true, true })).len);
}

test "defaults masks hold 32 parameters per word" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var args: [40]ArgSource = undefined;
    for (&args, 0..) |*x, i| x.* = .{ .arg = @intCast(i) };
    args[0] = .default;
    args[33] = .default;
    args[39] = .default;
    const has = [_]bool{true} ** 40;
    try testing.expectEqualSlices(u32, &.{ 1, (1 << 1) | (1 << 7) }, try call.defaultMasks(a, &args, &has));
    try testing.expectEqual(@as(u16, 2), call.maskWords(40));
    try testing.expectEqual(@as(u16, 1), call.maskWords(32));
    try testing.expectEqual(@as(u16, 2), call.maskWords(33));
}

test "a vararg given no element is omitted only when it declares a default" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const empty = [_]ArgSource{ .{ .arg = 0 }, .{ .vararg = &.{} } };
    try testing.expectEqualSlices(u32, &.{0b10}, try call.defaultMasks(a, &empty, &.{ false, true }));
    try testing.expectEqual(@as(usize, 0), (try call.defaultMasks(a, &empty, &.{ false, false })).len);
    const parts = [_]VarargPart{.{ .arg = 1, .spread = false }};
    const given = [_]ArgSource{ .{ .arg = 0 }, .{ .vararg = &parts } };
    try testing.expectEqual(@as(usize, 0), (try call.defaultMasks(a, &given, &.{ false, true })).len);
}

test "named arguments permute into declaration order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `f(b = x, a = y)` for `fun f(a, b)`: operand 1 fills `a`, 0 fills `b`.
    const named = [_]ArgSource{ .{ .arg = 1 }, .{ .arg = 0 } };
    try testing.expectEqualSlices(?u16, &.{ 1, 0 }, try call.permutation(a, &named, 2));
    // A vararg's elements and a default take no position of their own.
    const parts = [_]VarargPart{ .{ .arg = 0, .spread = false }, .{ .arg = 2, .spread = true } };
    const mixed = [_]ArgSource{ .{ .vararg = &parts }, .{ .arg = 1 }, .default, .receiver };
    try testing.expectEqualSlices(?u16, &.{ null, 1, null, null }, try call.permutation(a, &mixed, 3));
}

test "a record that skips or repeats an operand is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.Unsupported, call.permutation(a, &.{ .{ .arg = 0 }, .{ .arg = 0 } }, 2));
    try testing.expectError(error.Unsupported, call.permutation(a, &.{.{ .arg = 0 }}, 2));
    try testing.expectError(error.Unsupported, call.permutation(a, &.{.{ .arg = 3 }}, 1));
}

test "a frame's layout follows the calling convention" {
    const l: call.Layout = .{ .this = true, .hidden = 2, .contexts = 1, .ext = true, .values = 3, .reified = 1, .masks = 1 };
    try testing.expectEqual(@as(u16, 1), l.hiddenStart());
    try testing.expectEqual(@as(u16, 3), l.contextStart());
    try testing.expectEqual(@as(u16, 4), l.extIndex());
    try testing.expectEqual(@as(u16, 5), l.valueStart());
    try testing.expectEqual(@as(u16, 8), l.reifiedStart());
    try testing.expectEqual(@as(u16, 9), l.maskStart());
    try testing.expectEqual(@as(u16, 10), l.len());
}

// ------------------------------------------------- declarations and ids --

/// A program over a small `kotlin` layer, resolved, with an identity table
/// that gives symbol `i` function, class and slot `i`.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    s: *sema.Sema,
    m: ir.Module,
    br: ir.bridge.Bridge,
    prims: lower.operator.PrimTable = .{},
    p: lower.Program,

    const base_src =
        \\package kotlin
        \\public open class Any
        \\public class Unit
        \\public class Int
        \\public class String
        \\public class Boolean
        \\public class IntArray
        \\public class Array<T>
        \\public interface Function<out R>
        \\public abstract class Enum<E : Enum<E>>(name: String, ordinal: Int)
        \\internal fun __klio_arrayConcat(parts: Array<out Any>): Any
    ;

    fn init(src: []const u8) !*Fixture {
        const fx = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(fx);
        fx.arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer fx.arena.deinit();
        const a = fx.arena.allocator();
        var map = span.SourceMap.init(a);
        const s = try sema.Sema.init(a);
        try s.addFiles(&.{try parse(a, &map, "kotlin.kt", base_src, .base)});
        try s.addFiles(&.{try parse(a, &map, "main.kt", src, .program)});
        try s.resolveBodies(&.{.program});
        fx.s = s;
        fx.m = ir.Module.init(a);
        const n = s.syms.count();
        const func_of = try a.alloc(ir.FuncId, n);
        const class_of = try a.alloc(ir.ClassId, n);
        const slot_of = try a.alloc(ir.MethodSlotId, n);
        const native_of = try a.alloc(ir.NativeId, n);
        const origin = try a.alloc(ir.bridge.FuncOrigin, n);
        const sam_class_of = try a.alloc(ir.ClassId, n);
        for (0..n) |i| {
            const u: u32 = @intCast(i);
            func_of[i] = ir.FuncId.from(u);
            class_of[i] = ir.ClassId.from(u);
            slot_of[i] = ir.MethodSlotId.from(u);
            native_of[i] = .none;
            origin[i] = .{ .decl = Sym.from(u) };
            sam_class_of[i] = ir.ClassId.from(u + 10_000);
        }
        fx.br = .{
            .s = s,
            .m = &fx.m,
            .records = (try sema.output.build(s)).files,
            .func_of = func_of,
            .class_of = class_of,
            .slot_of = slot_of,
            .native_of = native_of,
            .origin = origin,
            .sam_class_of = sam_class_of,
        };
        fx.prims = .{};
        fx.p = .{ .a = a, .s = s, .br = &fx.br, .m = &fx.m, .prims = &fx.prims };
        return fx;
    }

    fn deinit(fx: *Fixture) void {
        fx.arena.deinit();
        testing.allocator.destroy(fx);
    }

    fn name(fx: *Fixture, n: []const u8) sema.Name {
        return fx.s.names.lookup(n).?;
    }

    /// A top-level declaration of package `demo`.
    fn top(fx: *Fixture, n: []const u8) !Sym {
        const s = fx.s;
        const pkg = s.syms.package_by_fqn.get(fx.name("demo")).?;
        const found = sema.scope.membersOf(s, pkg, fx.name(n));
        try testing.expect(found.len != 0);
        try sema.headers.functionHeader(s, found[0]);
        return found[0];
    }

    fn class(fx: *Fixture, n: []const u8) !Sym {
        var buf: [64]u8 = undefined;
        const c = fx.s.classByFqn(try std.fmt.bufPrint(&buf, "demo.{s}", .{n}));
        try testing.expect(c != .none);
        return c;
    }

    fn member(fx: *Fixture, cls: Sym, n: []const u8) !Sym {
        const found = sema.symbols.Symbols.members(&fx.s.syms.classInfo(cls).members, fx.name(n));
        try testing.expect(found.len != 0);
        if (fx.s.syms.kind(found[0]) == .function or fx.s.syms.kind(found[0]) == .constructor) {
            try sema.headers.functionHeader(fx.s, found[0]);
        }
        return found[0];
    }

    fn ctor(fx: *Fixture, cls: Sym) !Sym {
        const c = fx.s.syms.classInfo(cls).primary_ctor;
        try testing.expect(c != .none);
        try sema.headers.functionHeader(fx.s, c);
        return c;
    }

    fn choose(fx: *Fixture, callee: Sym, form: sema.records.CallForm) !dispatch.How {
        const rec: CallRec = .{ .callee = callee, .form = form };
        return dispatch.choose(&fx.p, &rec);
    }
};

fn parse(a: std.mem.Allocator, map: *span.SourceMap, path: []const u8, src: []const u8, origin: sema.Origin) !sema.SourceFile {
    const id = try map.add(path, src);
    const text = map.get(id).source;
    var lx = try lexer.Lexer.init(a, id, text);
    const lexed = try lx.tokenize();
    const p = parser.Parser.new(a, id, text, lexed.tokens, lexed.strings);
    const file = try a.create(ast.KotlinFile);
    file.* = p.parseFile();
    return .{ .ast = file, .path = path, .origin = origin };
}

const decls_src =
    \\package demo
    \\open class Base {
    \\    open fun f(x: Int): Int = x
    \\    fun g(): Int = f(2)
    \\    private fun h() {}
    \\    open fun Int.ext(y: Int): Int = y
    \\    inner class Inner(val v: Int)
    \\}
    \\class Final {
    \\    fun f() {}
    \\}
    \\interface I {
    \\    fun i(): Int
    \\}
    \\enum class E(val v: Int) {
    \\    A(1);
    \\    open fun e(): Int = v
    \\}
    \\object O {
    \\    fun o() {}
    \\}
    \\context(c: String) fun ctx(a: Int, b: Int) {}
    \\inline fun <reified T, U> r(x: U) {}
    \\fun String.top(a: Int) {}
    \\fun interface Op {
    \\    fun apply(x: Int): Int
    \\}
    \\fun three(a: Int, b: Int = 2, c: Int): Int = a
    \\fun ints(vararg xs: Int): Int = 0
    \\fun <T> any(vararg xs: T): Int = 0
;

test "a callee's frame puts its receiver, hidden values, contexts, extension receiver and reified values in order" {
    const fx = try Fixture.init(decls_src);
    defer fx.deinit();
    const base = try fx.class("Base");
    const f = call.layoutOf(&fx.p, try fx.member(base, "f"));
    try testing.expect(f.this and !f.ext);
    try testing.expectEqual(@as(u16, 1), f.valueStart());
    try testing.expectEqual(@as(u16, 2), f.len());
    // A member extension: `this`, then the extension receiver.
    const ext = call.layoutOf(&fx.p, try fx.member(base, "ext"));
    try testing.expect(ext.this and ext.ext);
    try testing.expectEqual(@as(u16, 1), ext.extIndex());
    try testing.expectEqual(@as(u16, 2), ext.valueStart());
    // An inner class's constructor: the instance, then the outer instance.
    const inner = call.layoutOf(&fx.p, try fx.ctor(try fx.class("Base.Inner")));
    try testing.expectEqual(@as(u16, 1), inner.hidden);
    try testing.expectEqual(@as(u16, 2), inner.valueStart());
    // An enum class's constructor: the instance, `name`, `ordinal`.
    const e = call.layoutOf(&fx.p, try fx.ctor(try fx.class("E")));
    try testing.expectEqual(@as(u16, 2), e.hidden);
    try testing.expectEqual(@as(u16, 3), e.valueStart());
    const ctx = call.layoutOf(&fx.p, try fx.top("ctx"));
    try testing.expect(!ctx.this);
    try testing.expectEqual(@as(u16, 1), ctx.contexts);
    try testing.expectEqual(@as(u16, 1), ctx.valueStart());
    const r = call.layoutOf(&fx.p, try fx.top("r"));
    try testing.expectEqual(@as(u16, 1), r.reified);
    try testing.expectEqual(@as(u16, 1), r.reifiedStart());
    const top = call.layoutOf(&fx.p, try fx.top("top"));
    try testing.expect(!top.this and top.ext);
    try testing.expectEqual(@as(u16, 1), top.valueStart());
    // `values()` is called on the class, not an instance.
    const values = call.layoutOf(&fx.p, try fx.member(try fx.class("E"), "values"));
    try testing.expect(!values.this);
}

test "dispatch is static for what nothing overrides, virtual or through an interface otherwise" {
    const fx = try Fixture.init(decls_src);
    defer fx.deinit();
    const base = try fx.class("Base");
    const f = try fx.member(base, "f");
    try testing.expectEqual(dispatch.How{ .virtual = ir.MethodSlotId.from(f.int()) }, try fx.choose(f, .plain));
    // `super` runs the named declaration.
    try testing.expectEqual(dispatch.How{ .static = ir.FuncId.from(f.int()) }, try fx.choose(f, .super_));
    const g = try fx.member(base, "g");
    try testing.expectEqual(dispatch.How{ .static = ir.FuncId.from(g.int()) }, try fx.choose(g, .plain));
    const h = try fx.member(base, "h");
    try testing.expectEqual(dispatch.How{ .static = ir.FuncId.from(h.int()) }, try fx.choose(h, .plain));
    const ext = try fx.member(base, "ext");
    try testing.expectEqual(dispatch.How{ .virtual = ir.MethodSlotId.from(ext.int()) }, try fx.choose(ext, .plain));
    const final_f = try fx.member(try fx.class("Final"), "f");
    try testing.expectEqual(dispatch.How{ .static = ir.FuncId.from(final_f.int()) }, try fx.choose(final_f, .plain));
    const iface = try fx.class("I");
    const i = try fx.member(iface, "i");
    const how_i = try fx.choose(i, .plain);
    try testing.expectEqual(ir.ClassId.from(iface.int()), how_i.interface.iface);
    try testing.expectEqual(ir.MethodSlotId.from(i.int()), how_i.interface.slot);
    // An enum class's open member can be overridden by an entry's body.
    const e = try fx.member(try fx.class("E"), "e");
    try testing.expectEqual(dispatch.How{ .virtual = ir.MethodSlotId.from(e.int()) }, try fx.choose(e, .plain));
    const o = try fx.member(try fx.class("O"), "o");
    try testing.expectEqual(dispatch.How{ .static = ir.FuncId.from(o.int()) }, try fx.choose(o, .plain));
    const top = try fx.top("top");
    try testing.expectEqual(dispatch.How{ .static = ir.FuncId.from(top.int()) }, try fx.choose(top, .plain));
    const r = try fx.top("r");
    try testing.expectEqual(dispatch.How{ .inline_ = ir.FuncId.from(r.int()) }, try fx.choose(r, .plain));
}

test "a native binding answers a call nothing overrides; an open native member stays virtual, and super runs its native directly" {
    const fx = try Fixture.init(decls_src);
    defer fx.deinit();
    const top = try fx.top("top");
    const f = try fx.member(try fx.class("Base"), "f");
    fx.br.native_of[top.int()] = ir.NativeId.from(7);
    fx.br.native_of[f.int()] = ir.NativeId.from(8);
    try testing.expectEqual(dispatch.How{ .native = ir.NativeId.from(7) }, try fx.choose(top, .plain));
    try testing.expectEqual(dispatch.How{ .virtual = ir.MethodSlotId.from(f.int()) }, try fx.choose(f, .plain));
    try testing.expectEqual(dispatch.How{ .super_native = ir.NativeId.from(8) }, try fx.choose(f, .super_));
}

test "a constructor call names its class; an invoke of a function value is a value call" {
    const fx = try Fixture.init(decls_src);
    defer fx.deinit();
    const inner = try fx.class("Base.Inner");
    const c = try fx.ctor(inner);
    const how = try fx.choose(c, .ctor);
    try testing.expectEqual(ir.ClassId.from(inner.int()), how.ctor.class);
    try testing.expectEqual(ir.FuncId.from(c.int()), how.ctor.ctor);
    try testing.expectEqual(dispatch.How{ .static = ir.FuncId.from(c.int()) }, try fx.choose(c, .super_delegation));
    const fn1 = fx.s.function_classes.get(1).?;
    const invoke = sema.symbols.Symbols.members(&fx.s.syms.classInfo(fn1).members, sema.wk.invoke)[0];
    try testing.expect(dispatch.isFunctionInvoke(fx.s, invoke));
    try testing.expectEqual(dispatch.How.value, try fx.choose(invoke, .value_invoke));
    // `f.invoke(x)` names the same `invoke` as a plain member call.
    try testing.expectEqual(dispatch.How.value, try fx.choose(invoke, .plain));
    // A class's own `invoke` operator is an ordinary member call.
    try testing.expect(!dispatch.isFunctionInvoke(fx.s, try fx.member(try fx.class("Base"), "f")));
    // `Op { ... }` constructs the interface's SAM class.
    const op = try fx.class("Op");
    const sam_ctor = fx.s.sam_ctors.get(op).?;
    const sam = try fx.choose(sam_ctor, .sam_ctor);
    try testing.expectEqual(ir.ClassId.from(op.int() + 10_000), sam.ctor.class);
    try testing.expectEqual(ir.FuncId.from(sam_ctor.int()), sam.ctor.ctor);
}

// ------------------------------------------------------ emitted IR shape --

/// What `emitCall` wrote: the call instruction last, and per position of
/// its argument run the register moved there.
const Emitted = struct {
    insts: []const ir.Inst,
    call: ir.Inst,
    srcs: []const ir.Reg,

    fn of(b: *lower.Builder, first: ir.Reg, n: u32) !Emitted {
        const insts = b.blocks.items[b.cur.int()].insts.items;
        const srcs = try b.p.a.alloc(ir.Reg, n);
        for (srcs, 0..) |*o, k| {
            const want = ir.Reg.from(first.int() + @as(u32, @intCast(k)));
            var found = false;
            for (insts) |inst| switch (inst) {
                .Move => |m| if (m.dst == want) {
                    o.* = m.src;
                    found = true;
                },
                else => {},
            };
            try testing.expect(found);
        }
        return .{ .insts = insts, .call = insts[insts.len - 1], .srcs = srcs };
    }

    /// The constant register `r` was given.
    fn constOf(e: Emitted, m: *const ir.Module, r: ir.Reg) ?ir.Const {
        for (e.insts) |inst| switch (inst) {
            .Const => |c| if (c.dst == r) return m.consts.items[c.value.int()],
            else => {},
        };
        return null;
    }
};

fn bodyBuilder(fx: *Fixture) !lower.Builder {
    return lower.Builder.init(&fx.p, 0, .none, ir.FuncId.from(0), .function);
}

test "operands move into declaration order and an omitted one goes through the defaults bridge" {
    const fx = try Fixture.init(decls_src);
    defer fx.deinit();
    const three = try fx.top("three");
    const n = fx.s.syms.count();
    fx.br.defaults_of = try fx.arena.allocator().alloc(ir.FuncId, n);
    @memset(fx.br.defaults_of, ir.FuncId.from(ir.bridge.NONE));
    fx.br.defaults_of[three.int()] = ir.FuncId.from(9000);
    var b = try bodyBuilder(fx);
    const r0 = b.newReg();
    const r1 = b.newReg();
    // `three(c = r0, a = r1)`: `b` is omitted.
    const rec: CallRec = .{ .callee = three, .form = .plain, .args = &.{ .{ .arg = 1 }, .default, .{ .arg = 0 } } };
    const dst = try call.emitCall(&b, &rec, .{ .exprs = &.{ null, null }, .regs = &.{ r0, r1 }, .receiver = null });
    const cs = (try Emitted.of(&b, lastCall(&b).args, 4));
    try testing.expectEqual(ir.FuncId.from(9000), cs.call.CallStatic.func);
    try testing.expectEqual(@as(u32, 4), cs.call.CallStatic.n_args);
    try testing.expectEqual(dst, cs.call.CallStatic.dst);
    try testing.expectEqual(r1, cs.srcs[0]);
    try testing.expect(cs.constOf(&fx.m, cs.srcs[1]).? == .Unit);
    try testing.expectEqual(r0, cs.srcs[2]);
    try testing.expectEqual(@as(i32, 0b010), cs.constOf(&fx.m, cs.srcs[3]).?.Int);
}

fn lastCall(b: *lower.Builder) struct { args: ir.Reg } {
    const insts = b.blocks.items[b.cur.int()].insts.items;
    return switch (insts[insts.len - 1]) {
        .CallStatic => |x| .{ .args = x.args },
        .RCallValue => |x| .{ .args = x.callee },
        .NewArray => |x| .{ .args = x.args },
        else => .{ .args = ir.Reg.from(0) },
    };
}

test "a call with every argument given calls the callee itself" {
    const fx = try Fixture.init(decls_src);
    defer fx.deinit();
    const three = try fx.top("three");
    var b = try bodyBuilder(fx);
    const r0 = b.newReg();
    const r1 = b.newReg();
    const r2 = b.newReg();
    const rec: CallRec = .{ .callee = three, .form = .plain, .args = &.{ .{ .arg = 0 }, .{ .arg = 1 }, .{ .arg = 2 } } };
    _ = try call.emitCall(&b, &rec, .{ .exprs = &.{ null, null, null }, .regs = &.{ r0, r1, r2 }, .receiver = null });
    const cs = try Emitted.of(&b, lastCall(&b).args, 3);
    try testing.expectEqual(ir.FuncId.from(three.int()), cs.call.CallStatic.func);
    try testing.expectEqualSlices(ir.Reg, &.{ r0, r1, r2 }, cs.srcs);
}

test "vararg elements pack into an array of the parameter's array class" {
    const fx = try Fixture.init(decls_src);
    defer fx.deinit();
    var b = try bodyBuilder(fx);
    const r0 = b.newReg();
    const r1 = b.newReg();
    const parts = [_]VarargPart{ .{ .arg = 0, .spread = false }, .{ .arg = 1, .spread = false } };
    const ints = try fx.top("ints");
    const rec: CallRec = .{ .callee = ints, .form = .plain, .args = &.{.{ .vararg = &parts }} };
    _ = try call.emitCall(&b, &rec, .{ .exprs = &.{ null, null }, .regs = &.{ r0, r1 }, .receiver = null });
    const insts = b.blocks.items[b.cur.int()].insts.items;
    var arr: ?ir.Inst = null;
    for (insts) |inst| if (inst == .NewArray) {
        arr = inst;
    };
    const na = arr.?.NewArray;
    try testing.expectEqual(ir.ClassId.from(fx.s.classByFqn("kotlin.IntArray").int()), na.class);
    try testing.expectEqual(@as(u32, 2), na.n_args);
    const packed_ = try Emitted.of(&b, na.args, 2);
    try testing.expectEqualSlices(ir.Reg, &.{ r0, r1 }, packed_.srcs);
    // A generic vararg holds an `Array`.
    var b2 = try bodyBuilder(fx);
    const x = b2.newReg();
    const one = [_]VarargPart{.{ .arg = 0, .spread = false }};
    const rec2: CallRec = .{ .callee = try fx.top("any"), .form = .plain, .args = &.{.{ .vararg = &one }} };
    _ = try call.emitCall(&b2, &rec2, .{ .exprs = &.{null}, .regs = &.{x}, .receiver = null });
    for (b2.blocks.items[b2.cur.int()].insts.items) |inst| if (inst == .NewArray) {
        try testing.expectEqual(ir.ClassId.from(fx.s.builtins.array.int()), inst.NewArray.class);
    };
}

test "a value invoke passes the function value, then its arguments" {
    const fx = try Fixture.init(decls_src);
    defer fx.deinit();
    const fn1 = fx.s.function_classes.get(1).?;
    const invoke = sema.symbols.Symbols.members(&fx.s.syms.classInfo(fn1).members, sema.wk.invoke)[0];
    var b = try bodyBuilder(fx);
    const value = b.newReg();
    const arg = b.newReg();
    const rec: CallRec = .{ .callee = invoke, .form = .value_invoke, .dispatch = .expr, .args = &.{.{ .arg = 0 }} };
    _ = try call.emitCall(&b, &rec, .{ .exprs = &.{null}, .regs = &.{arg}, .receiver = value });
    const cv = try Emitted.of(&b, lastCall(&b).args, 2);
    try testing.expectEqual(@as(u32, 1), cv.call.RCallValue.n_args);
    try testing.expectEqual(ir.Reg.from(cv.call.RCallValue.callee.int() + 1), cv.call.RCallValue.args);
    try testing.expectEqualSlices(ir.Reg, &.{ value, arg }, cv.srcs);
}

test "a call record that does not account for every operand fails its body" {
    const fx = try Fixture.init(decls_src);
    defer fx.deinit();
    var b = try bodyBuilder(fx);
    const r0 = b.newReg();
    const rec: CallRec = .{ .callee = try fx.top("three"), .form = .plain, .args = &.{ .{ .arg = 0 }, .{ .arg = 0 }, .{ .arg = 0 } } };
    try testing.expectError(error.Unsupported, call.emitCall(&b, &rec, .{ .exprs = &.{null}, .regs = &.{r0}, .receiver = null }));
    try testing.expectEqual(@as(usize, 1), fx.p.errors.items.len);
}

test "a callee the bridge gave no identity fails the choice" {
    const fx = try Fixture.init(decls_src);
    defer fx.deinit();
    const g = try fx.member(try fx.class("Base"), "g");
    fx.br.func_of[g.int()] = ir.FuncId.from(ir.bridge.NONE);
    try testing.expectError(error.Unsupported, fx.choose(g, .plain));
    try testing.expectError(error.Unrecorded, fx.choose(.none, .plain));
}

// ------------------------------------------- written calls through the spine --

/// A top-level function of `demo` lowered through the spine over sema's
/// records, and what it emitted.
const Lowered = struct {
    b: lower.Builder,
    fx: *Fixture,

    fn of(fx: *Fixture, name: []const u8) !Lowered {
        return ofSym(fx, try fx.top(name));
    }

    fn ofSym(fx: *Fixture, f: Sym) !Lowered {
        const fd = fx.s.syms.get(f).decl.function;
        var b = try lower.Builder.init(&fx.p, fx.s.syms.get(f).file, f, ir.FuncId.from(f.int()), .function);
        try lower.env.enter(&b);
        lower.body.lowerFunctionBody(&b, &fd.body.?) catch |err| {
            for (fx.p.errors.items) |le| std.debug.print("lowering error: {s}\n", .{le.msg});
            return err;
        };
        return .{ .b = b, .fx = fx };
    }

    /// Every instruction whose tag is `tag`, in block order.
    fn all(l: *const Lowered, comptime tag: std.meta.Tag(ir.Inst)) ![]const ir.Inst {
        var out: std.ArrayList(ir.Inst) = .empty;
        for (l.b.blocks.items) |blk| for (blk.insts.items) |inst| {
            if (inst == tag) try out.append(l.fx.p.a, inst);
        };
        return out.items;
    }

    /// The instruction that writes `r`, following moves.
    fn def(l: *const Lowered, r: ir.Reg) ?ir.Inst {
        for (l.b.blocks.items) |blk| for (blk.insts.items) |inst| switch (inst) {
            .Move => |m| if (m.dst == r) return l.def(m.src),
            .Const => |c| if (c.dst == r) return inst,
            .LoadParam => |x| if (x.dst == r) return inst,
            .LoadObject => |x| if (x.dst == r) return inst,
            else => {},
        };
        return null;
    }

    /// Run position `k` of a run starting at `first`, as the instruction
    /// that computed it.
    fn arg(l: *const Lowered, first: ir.Reg, k: u32) ?ir.Inst {
        return l.def(ir.Reg.from(first.int() + k));
    }

    /// The sources of every move into `r`, in block order.
    fn movedFrom(l: *const Lowered, r: ir.Reg) []const ir.Reg {
        var out: std.ArrayList(ir.Reg) = .empty;
        for (l.b.blocks.items) |blk| for (blk.insts.items) |inst| switch (inst) {
            .Move => |m| if (m.dst == r) out.append(l.fx.p.a, m.src) catch @panic("out of memory"),
            else => {},
        };
        return out.items;
    }

    fn intArg(l: *const Lowered, first: ir.Reg, k: u32) !i32 {
        const c = l.arg(first, k).?.Const;
        return l.fx.m.consts.items[c.value.int()].Int;
    }
};

const written_src =
    \\package demo
    \\object Counter {
    \\    fun bump(): Int = 1
    \\}
    \\class Box(val v: Int) {
    \\    fun get(): Int = v
    \\    companion object {
    \\        fun make(): Box = Box(3)
    \\    }
    \\}
    \\fun take(a: Int, b: Int): Int = a
    \\infix fun Int.join(k: Int): Int = k
    \\fun statics(box: Box?) {
    \\    Counter.bump()
    \\    Box.make()
    \\    take(b = 1, a = 2)
    \\    3 join 4
    \\    box?.get()
    \\}
    \\fun values(f: (Int) -> Int, g: Int.(Int) -> Int): Int {
    \\    f(1)
    \\    f.invoke(2)
    \\    return 5.g(3)
    \\}
;

test "a written call finds its receiver from the callee's shape" {
    const fx = try Fixture.init(written_src);
    defer fx.deinit();
    const l = try Lowered.of(fx, "statics");
    const calls = try l.all(.CallStatic);
    try testing.expectEqual(@as(usize, 5), calls.len);
    // `Counter.bump()` and `Box.make()`: the object, then the call on it.
    const bump = calls[0].CallStatic;
    try testing.expectEqual(ir.FuncId.from((try fx.member(try fx.class("Counter"), "bump")).int()), bump.func);
    try testing.expectEqual(ir.ClassId.from((try fx.class("Counter")).int()), l.arg(bump.args, 0).?.LoadObject.class);
    const make = calls[1].CallStatic;
    const companion = try fx.class("Box.Companion");
    try testing.expectEqual(ir.FuncId.from((try fx.member(companion, "make")).int()), make.func);
    try testing.expectEqual(ir.ClassId.from(companion.int()), l.arg(make.args, 0).?.LoadObject.class);
    // Named arguments in declaration order.
    const take = calls[2].CallStatic;
    try testing.expectEqual(@as(u32, 2), take.n_args);
    try testing.expectEqual(@as(i32, 2), try l.intArg(take.args, 0));
    try testing.expectEqual(@as(i32, 1), try l.intArg(take.args, 1));
    // An infix call's left operand is the extension receiver.
    const join = calls[3].CallStatic;
    try testing.expectEqual(@as(i32, 3), try l.intArg(join.args, 0));
    try testing.expectEqual(@as(i32, 4), try l.intArg(join.args, 1));
    // `box?.get()` on the parameter, past the null test.
    const get = calls[4].CallStatic;
    try testing.expectEqual(ir.FuncId.from((try fx.member(try fx.class("Box"), "get")).int()), get.func);
    try testing.expectEqual(@as(u16, 0), l.arg(get.args, 0).?.LoadParam.idx);
    try testing.expectEqual(@as(usize, 0), fx.p.errors.items.len);
}

test "an invoke passes the function value first and an extension function type's receiver next" {
    const fx = try Fixture.init(written_src);
    defer fx.deinit();
    const l = try Lowered.of(fx, "values");
    const invokes = try l.all(.RCallValue);
    try testing.expectEqual(@as(usize, 3), invokes.len);
    for (invokes[0..2], [_]i32{ 1, 2 }) |inst, want| {
        const x = inst.RCallValue;
        try testing.expectEqual(@as(u16, 0), l.def(x.callee).?.LoadParam.idx);
        try testing.expectEqual(@as(u32, 1), x.n_args);
        try testing.expectEqual(want, try l.intArg(x.args, 0));
    }
    // `5.g(3)`: `g`, then the receiver 5, then 3.
    const g = invokes[2].RCallValue;
    try testing.expectEqual(@as(u16, 1), l.def(g.callee).?.LoadParam.idx);
    try testing.expectEqual(@as(u32, 2), g.n_args);
    try testing.expectEqual(@as(i32, 5), try l.intArg(g.args, 0));
    try testing.expectEqual(@as(i32, 3), try l.intArg(g.args, 1));
}

const shapes_src =
    \\package demo
    \\open class A {
    \\    open fun f(): Int = 1
    \\}
    \\class B : A() {
    \\    override fun f(): Int = super.f()
    \\}
    \\interface I {
    \\    fun i(): Int
    \\}
    \\class Outer {
    \\    inner class Inner(val x: Int)
    \\}
    \\class S {
    \\    fun Int.sc(): Int = this
    \\    fun use(x: Int): Int = x.sc()
    \\}
    \\context(c: String) fun ctx(a: Int): Int = a
    \\context(c: String) fun caller(): Int = ctx(1)
    \\fun ints(vararg xs: Int): Int = 0
    \\fun shapes(a: A, i: I, o: Outer, arr: IntArray) {
    \\    a.f()
    \\    i.i()
    \\    o.Inner(2)
    \\    ints(1, *arr, 2)
    \\}
;

test "virtual, interface and constructor calls and a spread, from a written body" {
    const fx = try Fixture.init(shapes_src);
    defer fx.deinit();
    const l = try Lowered.of(fx, "shapes");
    const f = try fx.member(try fx.class("A"), "f");
    const virt = (try l.all(.RCallVirtual))[0].RCallVirtual;
    try testing.expectEqual(ir.MethodSlotId.from(f.int()), virt.slot);
    try testing.expectEqual(@as(u16, 0), l.arg(virt.args, 0).?.LoadParam.idx);
    const iface = try fx.class("I");
    const ic = (try l.all(.CallInterface))[0].CallInterface;
    try testing.expectEqual(ir.ClassId.from(iface.int()), ic.iface);
    try testing.expectEqual(@as(u16, 1), l.arg(ic.args, 0).?.LoadParam.idx);
    // An inner class's constructor takes the outer instance first.
    const inner = try fx.class("Outer.Inner");
    const new = (try l.all(.RNewInstance))[0].RNewInstance;
    try testing.expectEqual(ir.ClassId.from(inner.int()), new.class);
    try testing.expectEqual(ir.FuncId.from((try fx.ctor(inner)).int()), new.ctor);
    try testing.expectEqual(@as(u32, 2), new.n_args);
    try testing.expectEqual(@as(u16, 2), l.arg(new.args, 0).?.LoadParam.idx);
    try testing.expectEqual(@as(i32, 2), try l.intArg(new.args, 1));
    // `ints(1, *arr, 2)`: each run of elements is an array of its own, and
    // the base's join copies them and the spread into a new one.
    const arrays = try l.all(.NewArray);
    try testing.expectEqual(@as(usize, 3), arrays.len);
    const int_array = ir.ClassId.from(fx.s.classByFqn("kotlin.IntArray").int());
    try testing.expectEqual(int_array, arrays[0].NewArray.class);
    try testing.expectEqual(@as(i32, 1), try l.intArg(arrays[0].NewArray.args, 0));
    try testing.expectEqual(@as(i32, 2), try l.intArg(arrays[1].NewArray.args, 0));
    const parts = arrays[2].NewArray;
    try testing.expectEqual(ir.ClassId.from(fx.s.builtins.array.int()), parts.class);
    try testing.expectEqual(@as(u32, 3), parts.n_args);
    try testing.expectEqual(@as(u16, 3), l.arg(parts.args, 1).?.LoadParam.idx);
    const kotlin = fx.s.syms.package_by_fqn.get(fx.name("kotlin")).?;
    const helper = sema.scope.membersOf(fx.s, kotlin, fx.name(call.spread_helper))[0];
    const join = (try l.all(.CallStatic))[0].CallStatic;
    try testing.expectEqual(ir.FuncId.from(helper.int()), join.func);
    try testing.expectEqual(@as(u32, 1), join.n_args);
}

test "super, member extension and context arguments come from the enclosing body" {
    const fx = try Fixture.init(shapes_src);
    defer fx.deinit();
    // `super.f()` runs `A.f` on this instance.
    const b_f = try Lowered.ofSym(fx, try fx.member(try fx.class("B"), "f"));
    const sup = (try b_f.all(.CallStatic))[0].CallStatic;
    try testing.expectEqual(ir.FuncId.from((try fx.member(try fx.class("A"), "f")).int()), sup.func);
    try testing.expectEqual(@as(u16, 0), b_f.arg(sup.args, 0).?.LoadParam.idx);
    // `x.sc()` inside `S`: this `S`, then the extension receiver `x`.
    const use = try Lowered.ofSym(fx, try fx.member(try fx.class("S"), "use"));
    const sc = (try use.all(.CallStatic))[0].CallStatic;
    try testing.expectEqual(@as(u32, 2), sc.n_args);
    try testing.expectEqual(@as(u16, 0), use.arg(sc.args, 0).?.LoadParam.idx);
    try testing.expectEqual(@as(u16, 1), use.arg(sc.args, 1).?.LoadParam.idx);
    // `ctx(1)` takes the caller's context parameter.
    const caller = try Lowered.of(fx, "caller");
    const cx = (try caller.all(.CallStatic))[0].CallStatic;
    try testing.expectEqual(@as(u16, 0), caller.arg(cx.args, 0).?.LoadParam.idx);
    try testing.expectEqual(@as(i32, 1), try caller.intArg(cx.args, 1));
}

test "a defaults bridge gives an omitted parameter its default over the parameters before it" {
    const fx = try Fixture.init(
        \\package demo
        \\fun dflt(x: Int, y: Int = x, z: Int = y): Int = z
    );
    defer fx.deinit();
    const f = try fx.top("dflt");
    var b = try lower.Builder.init(&fx.p, fx.s.syms.get(f).file, f, ir.FuncId.from(9000), .defaults);
    try lower.env.enter(&b);
    try call.lowerDefaultsBridge(&b, f);
    const l: Lowered = .{ .b = b, .fx = fx };
    // One mask word after the three parameters, tested for `y` and `z`.
    var bits: std.ArrayList(i32) = .empty;
    for (try l.all(.BinOp)) |inst| {
        const x = inst.BinOp;
        if (x.op != .And) continue;
        try testing.expectEqual(@as(u16, 3), l.def(x.lhs).?.LoadParam.idx);
        try bits.append(fx.p.a, fx.m.consts.items[l.def(x.rhs).?.Const.value.int()].Int);
    }
    try testing.expectEqualSlices(i32, &.{ 0b010, 0b100 }, bits.items);
    // Then `dflt` itself, statically, over the parameters' final values.
    const c = (try l.all(.CallStatic))[0].CallStatic;
    try testing.expectEqual(ir.FuncId.from(f.int()), c.func);
    try testing.expectEqual(@as(u32, 3), c.n_args);
    try testing.expectEqual(@as(u16, 0), l.arg(c.args, 0).?.LoadParam.idx);
    // `y` holds its argument or, omitted, `x`; `z` holds its argument or `y`.
    const y_home = l.movedFrom(ir.Reg.from(c.args.int() + 1))[0];
    const z_home = l.movedFrom(ir.Reg.from(c.args.int() + 2))[0];
    const into_y = l.movedFrom(y_home);
    try testing.expectEqual(@as(usize, 2), into_y.len);
    try testing.expectEqual(@as(u16, 1), l.def(into_y[0]).?.LoadParam.idx);
    try testing.expectEqual(@as(u16, 0), l.def(into_y[1]).?.LoadParam.idx);
    const into_z = l.movedFrom(z_home);
    try testing.expectEqual(@as(usize, 2), into_z.len);
    try testing.expectEqual(@as(u16, 2), l.def(into_z[0]).?.LoadParam.idx);
    try testing.expectEqual(y_home, into_z[1]);
    // The bridge returns what `dflt` returned.
    var returned = false;
    for (l.b.blocks.items) |blk| if (blk.terminator) |t| switch (t) {
        .Return => |r| if (r) |reg| {
            returned = returned or reg == c.dst;
        },
        else => {},
    };
    try testing.expect(returned);
}

// ------------------------------------------------------------- executing --

/// What an executing test relies on beyond calls, each proved by a probe
/// program before the tests that need it run.
const Needs = enum { basic, classes, lambdas, inline_, suspend_ };

const probes = std.EnumArray(Needs, struct { src: []const u8, want: []const u8 }).init(.{
    .basic = .{
        .src =
        \\fun main() {
        \\    var i = 1
        \\    while (i < 3) { i = i + 1 }
        \\    if (i == 3) println("ok " + i)
        \\}
        ,
        .want = "ok 3\n",
    },
    .classes = .{
        .src =
        \\interface I { fun f(): Int }
        \\open class A(val x: Int) : I { override fun f(): Int = x }
        \\class B : A(2)
        \\object O { val y = 3 }
        \\fun main() { val i: I = B(); println(i.f() + O.y) }
        ,
        .want = "5\n",
    },
    .lambdas = .{
        .src =
        \\fun main() {
        \\    var n = 1
        \\    val f = { x: Int -> n = n + x; n }
        \\    println(f(2))
        \\}
        ,
        .want = "3\n",
    },
    .inline_ = .{
        .src =
        \\inline fun twice(f: () -> Unit) { f(); f() }
        \\fun main() { twice { println("x") } }
        ,
        .want = "x\nx\n",
    },
    .suspend_ = .{
        .src =
        \\suspend fun one(): Int = 1
        \\suspend fun main() { println(one()) }
        ,
        .want = "1\n",
    },
});

var probed: std.EnumArray(Needs, ?bool) = .initFill(null);

/// Whether the probe for `n` prints what it should, asked once.
fn ready(n: Needs) bool {
    if (probed.get(n)) |r| return r;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pr = probes.get(n);
    const ok = if (driver.run(arena.allocator(), &.{pr.src})) |out|
        out.result == .ok and std.mem.eql(u8, out.output, pr.want)
    else |_|
        false;
    probed.set(n, ok);
    return ok;
}

/// Runs `src` and expects `want`, once every construct in `needs` works.
fn expectRun(needs: []const Needs, src: []const u8, want: []const u8) !void {
    if (!ready(.basic)) return error.SkipZigTest;
    for (needs) |n| if (!ready(n)) return error.SkipZigTest;
    try driver.expectOutput(&.{src}, want);
}

test "a null function value passed for a nullable fun interface stays null" {
    try expectRun(&.{},
        \\fun interface Job { fun run(): Int }
        \\fun isNull(j: Job?): Boolean = j == null
        \\fun pick(none: Boolean): (() -> Int)? = if (none) null else { { 7 } }
        \\fun main() {
        \\    println(isNull(pick(true)))
        \\    println(isNull(pick(false)))
        \\}
    , "true\nfalse\n");
}

test "arguments are evaluated in source order and passed in declaration order" {
    try expectRun(&.{},
        \\fun trace(tag: String, v: Int): Int {
        \\    println(tag)
        \\    return v
        \\}
        \\fun f(a: Int, b: Int, c: Int): Int = a * 100 + b * 10 + c
        \\fun main() {
        \\    println(f(c = trace("c", 3), a = trace("a", 1), b = trace("b", 2)))
        \\}
    , "c\na\nb\n123\n");
}

test "a default reads the parameters before it and this" {
    try expectRun(&.{.classes},
        \\class Box(val base: Int) {
        \\    fun make(x: Int, y: Int = x + base, z: Int = y * 2): Int = x * 10000 + y * 100 + z
        \\}
        \\fun main() {
        \\    val b = Box(5)
        \\    println(b.make(1))
        \\    println(b.make(1, 2))
        \\    println(b.make(1, z = 3))
        \\}
    , "10612\n10204\n10603\n");
}

test "an override takes the default its overridden member declares" {
    try expectRun(&.{.classes},
        \\open class A {
        \\    open fun f(x: Int = 7): Int = x
        \\}
        \\class B : A() {
        \\    override fun f(x: Int): Int = x + 100
        \\}
        \\fun main() {
        \\    val a: A = B()
        \\    println(a.f())
        \\    println(B().f())
        \\    println(A().f())
        \\}
    , "107\n107\n7\n");
}

test "varargs pack their elements and copy a spread array" {
    try expectRun(&.{},
        \\fun count(vararg xs: Int): Int {
        \\    var t = 0
        \\    var i = 0
        \\    while (i < xs.size) {
        \\        t = t * 10 + xs[i]
        \\        i = i + 1
        \\    }
        \\    return t
        \\}
        \\fun <T> first(vararg xs: T): T = xs[0]
        \\fun mutate(vararg xs: Int) {
        \\    xs[0] = 9
        \\}
        \\fun main() {
        \\    println(count())
        \\    println(count(1, 2, 3))
        \\    val a = intArrayOf(4, 5)
        \\    println(count(1, *a, 6))
        \\    println(count(*a))
        \\    println(first("x", "y"))
        \\    mutate(*a)
        \\    println(a[0])
        \\}
    , "0\n123\n1456\n45\nx\n4\n");
}

test "a vararg given no element takes its default" {
    try expectRun(&.{},
        \\fun g(vararg xs: Int = intArrayOf(7, 8)): Int = xs.size * 10 + xs[0]
        \\fun main() {
        \\    println(g())
        \\    println(g(1))
        \\}
    , "27\n11\n");
}

test "a trailing lambda is the last argument" {
    try expectRun(&.{.lambdas},
        \\fun twice(x: Int, f: (Int) -> Int): Int = f(f(x))
        \\fun main() {
        \\    println(twice(3) { it * 2 })
        \\}
    , "12\n");
}

test "a context parameter is passed by the caller" {
    try expectRun(&.{ .classes, .lambdas },
        \\class Logger(val prefix: String) {
        \\    fun log(m: String) {
        \\        println(prefix + m)
        \\    }
        \\}
        \\context(l: Logger) fun work(x: Int) {
        \\    l.log("work " + x)
        \\}
        \\fun <T> run1(v: T, f: T.() -> Unit) {
        \\    v.f()
        \\}
        \\fun main() {
        \\    run1(Logger("> ")) { work(1) }
        \\}
    , "> work 1\n");
}

test "a member extension takes both receivers" {
    try expectRun(&.{.classes},
        \\class Scale(val k: Int) {
        \\    fun Int.scaled(): Int = this * k
        \\    fun apply(x: Int): Int = x.scaled()
        \\}
        \\fun main() {
        \\    println(Scale(3).apply(5))
        \\}
    , "15\n");
}

test "super calls run the named declaration on the enclosing instance" {
    try expectRun(&.{.classes},
        \\open class A {
        \\    open fun f(): String = "A"
        \\}
        \\open class B : A() {
        \\    override fun f(): String = "B" + super.f()
        \\    inner class C {
        \\        fun g(): String = super@B.f()
        \\    }
        \\}
        \\class D : B() {
        \\    override fun f(): String = "D" + super.f()
        \\}
        \\interface I {
        \\    fun h(): String = "I"
        \\}
        \\interface J {
        \\    fun h(): String = "J"
        \\}
        \\class K : I, J {
        \\    override fun h(): String = super<I>.h() + super<J>.h()
        \\}
        \\fun main() {
        \\    println(D().f())
        \\    println(D().C().g())
        \\    println(K().h())
        \\}
    , "DBA\nA\nIJ\n");
}

test "an interface call reaches the implementation a superclass supplies" {
    try expectRun(&.{.classes},
        \\interface Named {
        \\    fun name(): String
        \\}
        \\open class Base {
        \\    open fun name(): String = "class"
        \\}
        \\class Impl : Base(), Named
        \\fun main() {
        \\    val n: Named = Impl()
        \\    println(n.name())
        \\}
    , "class\n");
}

test "an interface call reaches a final member a grandparent class supplies" {
    try expectRun(&.{.classes},
        \\interface Named {
        \\    fun name(): String
        \\    fun tag(): String
        \\}
        \\open class Root {
        \\    fun name(): String = "root"
        \\}
        \\abstract class Mid : Root()
        \\class Impl : Mid(), Named {
        \\    override fun tag(): String = "impl"
        \\}
        \\fun main() {
        \\    val n: Named = Impl()
        \\    println(n.tag())
        \\    println(n.name())
        \\}
    , "impl\nroot\n");
}

test "a closure's toString names it as kotlinc's does and never calls it" {
    try expectRun(&.{ .classes, .lambdas },
        \\package demo
        \\fun foo(x: Int) = x
        \\class C(val p: Int) {
        \\    fun m() = 1
        \\    fun lam(): () -> Int = { p }
        \\}
        \\fun upTo(s: String, c: Char): String {
        \\    var out = ""
        \\    var i = 0
        \\    while (i < s.length && s[i] != c) {
        \\        out = out + s[i]
        \\        i = i + 1
        \\    }
        \\    return out
        \\}
        \\fun main() {
        \\    var calls = 0
        \\    val f: (Int) -> Unit = { calls = calls + 1 }
        \\    val text = f.toString()
        \\    val any: Any = f
        \\    println("" + calls + " " + (text == any.toString()) + " " + (text == "" + f))
        \\    println(upTo(text, '/'))
        \\    println(upTo(C(1).lam().toString(), '/'))
        \\    println(::foo)
        \\    println(::C)
        \\    println(C::m)
        \\    println(C(2)::m)
        \\    println(C::p)
        \\}
    , "0 true true\n" ++
        "demo.Test0Kt$$Lambda\n" ++
        "demo.C$$Lambda\n" ++
        "function foo (Kotlin reflection is not available)\n" ++
        "constructor (Kotlin reflection is not available)\n" ++
        "function m (Kotlin reflection is not available)\n" ++
        "function m (Kotlin reflection is not available)\n" ++
        "property p (Kotlin reflection is not available)\n");
}

test "a compareTo between primitives of different types compares in the wider type" {
    try expectRun(&.{},
        \\fun main() {
        \\    val big = 16777217
        \\    val f = 16777216f
        \\    val nan = 0.0f / 0.0f
        \\    println(big.compareTo(f))
        \\    println(big > f)
        \\    println(2.compareTo(2.0f))
        \\    println(2.5f.compareTo(2.5))
        \\    println(0.compareTo(-0.0f))
        \\    println(0.compareTo(0.0f))
        \\    println((-0.0).compareTo(0))
        \\    println(1.compareTo(nan))
        \\    println(nan.compareTo(nan))
        \\    println(1 < nan)
        \\    println(3L.compareTo(2.5f))
        \\}
    , "0\nfalse\n0\n0\n1\n0\n-1\n-1\n0\nfalse\n1\n");
}

test "a member without operator does not serve a convention" {
    try expectRun(&.{.classes},
        \\class V(val x: Int) {
        \\    fun plus(o: V): V = V(x * 100)
        \\}
        \\operator fun V.plus(o: V): V = V(x + o.x)
        \\fun main() {
        \\    println((V(1) + V(2)).x)
        \\    println(V(1).plus(V(2)).x)
        \\}
    , "3\n100\n");
}

test "a class name called without a matching constructor reaches the companion's invoke" {
    try expectRun(&.{.classes},
        \\class Shape(val a: Int, val b: Int) {
        \\    companion object {
        \\        operator fun invoke(n: Int): Shape = Shape(n, n * 2)
        \\    }
        \\}
        \\fun main() {
        \\    val s = Shape(3)
        \\    println(s.a + s.b)
        \\}
    , "9\n");
}

test "a suspend extension function value takes its receiver first" {
    try expectRun(&.{ .classes, .lambdas, .suspend_ },
        \\class Ctx(val base: Int)
        \\suspend fun <T> Ctx.go(block: suspend Ctx.(Int) -> T): T = block(7)
        \\suspend fun main() {
        \\    val c = Ctx(10)
        \\    println(c.go { base + it })
        \\    val f: suspend Ctx.(Int) -> Int = { base * it }
        \\    println(f(c, 3))
        \\    println(c.f(4))
        \\}
    , "17\n30\n40\n");
}

test "a host-bound member runs its native" {
    try expectRun(&.{},
        \\fun main() {
        \\    println("x".plus("y"))
        \\}
    , "xy\n");
}

test "overridden members run through virtual and interface calls" {
    try expectRun(&.{.classes},
        \\interface Shape {
        \\    fun area(): Int
        \\    fun describe(): String = "shape " + area()
        \\}
        \\abstract class Poly(val n: Int) : Shape {
        \\    override fun describe(): String = "poly " + n + " " + area()
        \\}
        \\class Sq(val s: Int) : Poly(4) {
        \\    override fun area(): Int = s * s
        \\}
        \\class Circle(val r: Int) : Shape {
        \\    override fun area(): Int = 3 * r * r
        \\}
        \\fun main() {
        \\    val xs: Array<Shape> = arrayOf(Sq(2), Circle(1))
        \\    println(xs[0].describe())
        \\    println(xs[1].describe())
        \\    val p: Poly = Sq(3)
        \\    println(p.area())
        \\}
    , "poly 4 4\nshape 3\n9\n");
}

test "extension functions take their receiver, a nullable one included" {
    try expectRun(&.{.classes},
        \\fun Int.twice(): Int = this * 2
        \\fun String?.orDash(): String = if (this == null) "-" else this
        \\class W(val v: Int)
        \\fun W.plusOne(): Int = v + 1
        \\fun main() {
        \\    println(5.twice())
        \\    val s: String? = null
        \\    println(s.orDash())
        \\    println("x".orDash())
        \\    println(W(4).plusOne())
        \\}
    , "10\n-\nx\n5\n");
}

test "invoke on function values, on objects and on extension function types" {
    try expectRun(&.{ .classes, .lambdas },
        \\class Adder(val k: Int) {
        \\    operator fun invoke(x: Int): Int = x + k
        \\}
        \\fun main() {
        \\    val f: (Int) -> Int = { it * 3 }
        \\    println(f(2))
        \\    println(f.invoke(4))
        \\    val add = Adder(10)
        \\    println(add(5))
        \\    val g: Int.(Int) -> Int = { this - it }
        \\    println(g(10, 3))
        \\    println(10.g(4))
        \\    val h = { x: Int -> { y: Int -> x * y } }
        \\    println(h(2)(5))
        \\}
    , "6\n12\n15\n7\n6\n10\n");
}

test "a constructor with defaults runs through its defaults bridge" {
    try expectRun(&.{.classes},
        \\class P(val a: Int, val b: Int = a + 1, val c: String = "c")
        \\fun main() {
        \\    val p = P(1)
        \\    println(p.b)
        \\    println(p.c)
        \\    val q = P(1, c = "z")
        \\    println(q.b)
        \\    println(q.c)
        \\}
    , "2\nc\n2\nz\n");
}

test "secondary constructors delegate on the instance being built" {
    try expectRun(&.{.classes},
        \\open class Base(val tag: String) {
        \\    init {
        \\        println("base " + tag)
        \\    }
        \\}
        \\class Item(val n: Int, tag: String) : Base(tag) {
        \\    init {
        \\        println("item " + n)
        \\    }
        \\    constructor(n: Int) : this(n, "d" + n) {
        \\        println("secondary " + n)
        \\    }
        \\    constructor() : this(0) {
        \\        println("empty")
        \\    }
        \\}
        \\open class Root(val x: Int)
        \\class S : Root {
        \\    constructor(y: Int) : super(y * 2)
        \\}
        \\fun main() {
        \\    Item()
        \\    println(S(4).x)
        \\}
    , "base d0\nitem 0\nsecondary 0\nempty\n8\n");
}

test "a SAM constructor and a SAM-converted argument wrap the function value" {
    try expectRun(&.{ .classes, .lambdas },
        \\fun interface Op {
        \\    fun apply(x: Int): Int
        \\}
        \\fun run(op: Op, v: Int): Int = op.apply(v)
        \\fun main() {
        \\    val o = Op { it + 1 }
        \\    println(o.apply(1))
        \\    println(run({ x -> x * 5 }, 2))
        \\    val f: (Int) -> Int = { it - 1 }
        \\    println(run(f, 5))
        \\}
    , "2\n10\n4\n");
}

test "an inner class is constructed on its outer instance" {
    try expectRun(&.{.classes},
        \\class Outer(val o: Int) {
        \\    inner class Inner(val i: Int) {
        \\        fun sum(): Int = o + i
        \\    }
        \\    fun make(): Inner = Inner(5)
        \\}
        \\fun main() {
        \\    val out = Outer(1)
        \\    println(out.Inner(2).sum())
        \\    println(out.make().sum())
        \\}
    , "3\n6\n");
}

test "a data class copy keeps the properties it is not given" {
    try expectRun(&.{.classes},
        \\data class Pt(val x: Int, val y: Int)
        \\fun main() {
        \\    val p = Pt(1, 2).copy(y = 5)
        \\    println(p.x)
        \\    println(p.y)
        \\}
    , "1\n5\n");
}

test "a call through an object or companion qualifier reads the singleton" {
    try expectRun(&.{.classes},
        \\object Counter {
        \\    var n = 0
        \\    fun bump(): Int {
        \\        n = n + 1
        \\        return n
        \\    }
        \\}
        \\class K {
        \\    companion object {
        \\        fun make(): Int = 42
        \\    }
        \\}
        \\fun main() {
        \\    Counter.bump()
        \\    println(Counter.bump())
        \\    println(K.make())
        \\}
    , "2\n42\n");
}

test "a local function is passed its captures" {
    try expectRun(&.{.lambdas},
        \\fun main() {
        \\    var total = 0
        \\    fun add(x: Int) {
        \\        total = total + x
        \\    }
        \\    add(3)
        \\    add(4)
        \\    println(total)
        \\    fun fact(n: Int): Int = if (n <= 1) 1 else n * fact(n - 1)
        \\    println(fact(5))
        \\}
    , "7\n120\n");
}

test "an infix call takes its left operand as the receiver" {
    try expectRun(&.{},
        \\infix fun Int.join(k: Int): Int = this * 100 + k
        \\fun main() {
        \\    println(3 join 4)
        \\}
    , "304\n");
}

test "a safe call is skipped on null" {
    try expectRun(&.{.classes},
        \\class N(val v: Int) {
        \\    fun get(): Int = v
        \\}
        \\fun main() {
        \\    val a: N? = N(4)
        \\    val b: N? = null
        \\    println(a?.get())
        \\    println(b?.get())
        \\}
    , "4\nnull\n");
}

test "a lambda that captures nothing is one instance, and a reference is one callable per adaptation" {
    try driver.expectOutput(&.{
        \\fun noCapture(cb: () -> Unit = {}): Any = cb
        \\fun capturing(n: Int): Any = { println(n) }
        \\fun target(x: Int, y: Int = 0): Int = x + y
        \\fun take1(fn: (Int) -> Int): Any = fn
        \\fun take2(fn: (Int, Int) -> Int): Any = fn
        \\fun main() {
        \\    println(noCapture() === noCapture())
        \\    println(capturing(1) === capturing(1))
        \\    println(take1(::target) == take1(::target))
        \\    println(take1(::target) == take2(::target))
        \\    println(take2(::target) == take2(::target))
        \\}
    }, "true\nfalse\ntrue\nfalse\ntrue\n");
}

test "a reference to an open or abstract property reads the receiver's implementation" {
    try driver.expectOutput(&.{
        \\interface Named { val name: String }
        \\class A : Named { override val name = "a" }
        \\open class B { open val v: Int get() = 1 }
        \\class C : B() { override val v: Int get() = 2 }
        \\fun main() {
        \\    val r = Named::name
        \\    println(r.get(A()))
        \\    println(r(A()))
        \\    val f: (B) -> Int = B::v
        \\    println(f(C()))
        \\    println(f(B()))
        \\}
    }, "a\na\n2\n1\n");
}

test "an actual takes the defaults its expect declares" {
    try driver.expectOutput(&.{
        \\expect fun make(a: Int, b: Int = 2): Int
        \\expect fun twice(a: Int, b: Int = a * 2): Int
        \\expect class Box(n: Int = 5) {
        \\    fun get(k: Int = 10): Int
        \\}
        ,
        \\actual fun make(a: Int, b: Int): Int = a + b
        \\actual fun twice(a: Int, b: Int): Int = a + b
        \\actual class Box actual constructor(val n: Int) {
        \\    actual fun get(k: Int): Int = n + k
        \\}
        \\fun main() {
        \\    println(make(1))
        \\    println(twice(3))
        \\    println(Box().get())
        \\    println(Box(1).get(2))
        \\}
    }, "3\n9\n15\n3\n");
}

test "an adapter that fails before naming an expression reports at its reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const an = try driver.analyze(a, &.{
        \\fun twice(x: Int): Int = x * 2
        \\fun main() {
        \\    val f = ::twice
        \\    println(f(21))
        \\}
    });
    // The adapter `::twice` allocated, made to take a parameter more than
    // its target: its lowering refuses it before any expression.
    var adapter: ?ir.FuncId = null;
    for (an.br.origin, 0..) |o, i| {
        if (o == .adapter) adapter = ir.FuncId.from(@intCast(i));
    }
    const fid = adapter orelse return error.TestUnexpectedResult;
    const f = &an.br.m.funcs.items[fid.int()];
    const widened = try a.alloc(@TypeOf(f.params[0]), f.params.len + 1);
    @memcpy(widened[0..f.params.len], f.params);
    widened[f.params.len] = f.params[0];
    f.params = widened;
    const prog = try lower.lowerProgram(a, an.s, an.br);
    for (prog.errors.items) |le| {
        if (le.func != fid) continue;
        const src = an.map.getChecked(le.span.file) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("test0.kt", src.path);
        try testing.expectEqual(@as(u32, 3), src.lineCol(le.span.start).line);
        return;
    }
    return error.TestUnexpectedResult;
}

test "a compound assignment and an increment reach a member through an object or companion qualifier" {
    try driver.expectOutput(&.{
        \\object A {
        \\    var r = 1
        \\}
        \\class C {
        \\    companion object {
        \\        var r = 1
        \\    }
        \\}
        \\fun main() {
        \\    A.r += 10
        \\    A.r++
        \\    val before = ++A.r
        \\    C.r += 1
        \\    val old = C.r--
        \\    C.Companion.r *= 5
        \\    println(A.r)
        \\    println(before)
        \\    println(C.r)
        \\    println(old)
        \\}
    }, "13\n13\n5\n2\n");
}

test "a lambda in an object or companion reaches its fields and super through the singleton" {
    try driver.expectOutput(&.{
        \\fun <T> call(f: () -> T): T = f()
        \\class My {
        \\    companion object {
        \\        val my: String = "O"
        \\            get() = call { field } + "K"
        \\        private var hidden: Int = 1
        \\            get() = call { field * 10 }
        \\        fun hiddenValue() = hidden
        \\    }
        \\}
        \\object Counter {
        \\    var count: Int = 5
        \\        get() = call { field + 1 }
        \\}
        \\open class A {
        \\    open fun test(s: String) = s + "A"
        \\}
        \\object B : A() {
        \\    override fun test(s: String) = "fail"
        \\    val doTest = { super.test("O") }
        \\}
        \\class D : A() {
        \\    val viaLambda = { super.test("K") }
        \\}
        \\fun main() {
        \\    println(My.my)
        \\    println(My.hiddenValue())
        \\    println(Counter.count)
        \\    println(B.doTest())
        \\    println(D().viaLambda())
        \\}
    }, "OK\n10\n6\nOA\nKA\n");
}

test "a catch of a reified type parameter tests the type the call passed, in clause order" {
    try driver.expectOutput(&.{
        \\inline fun <reified E : Throwable> classify(block: () -> Unit): String {
        \\    try {
        \\        block()
        \\        return "none"
        \\    } catch (e: E) {
        \\        return "caught " + e.message
        \\    } catch (e: IllegalArgumentException) {
        \\        return "argument " + e.message
        \\    } finally {
        \\        println("finally")
        \\    }
        \\}
        \\inline fun <reified E : Throwable?> nullable(): String {
        \\    try {
        \\        throw IllegalStateException("a")
        \\    } catch (e: E & Any) {
        \\        return "nullable " + e.message
        \\    }
        \\}
        \\fun main() {
        \\    println(classify<IllegalStateException> { throw IllegalStateException("s") })
        \\    println(classify<IllegalStateException> { throw IllegalArgumentException("i") })
        \\    println(classify<RuntimeException> { throw IllegalArgumentException("r") })
        \\    try {
        \\        classify<IllegalStateException> { throw UnsupportedOperationException("u") }
        \\    } catch (e: UnsupportedOperationException) {
        \\        println("passed through " + e.message)
        \\    }
        \\    println(nullable<IllegalStateException?>())
        \\}
    }, "finally\ncaught s\nfinally\nargument i\nfinally\ncaught r\nfinally\npassed through u\nnullable a\n");
}

test "a prefix increment reads a property or an index again after writing it" {
    try driver.expectOutput(&.{
        \\var log = ""
        \\object A {
        \\    var x = 0
        \\        get() = field.also { log += "get;" }
        \\        set(value) {
        \\            log += "set;"
        \\            field = value
        \\        }
        \\}
        \\class Grid {
        \\    var cell = 5
        \\    operator fun get(i: Int): Int = cell.also { log += "get$i;" }
        \\    operator fun set(i: Int, v: Int) {
        \\        log += "set$i;"
        \\        cell = v
        \\    }
        \\}
        \\fun getA() = A.also { log += "getA;" }
        \\fun main() {
        \\    val a = ++getA().x
        \\    println("$a $log")
        \\    log = ""
        \\    val b = getA().x--
        \\    println("$b $log")
        \\    log = ""
        \\    val g = Grid()
        \\    val c = ++g[3]
        \\    println("$c $log")
        \\    log = ""
        \\    var local = 7
        \\    val d = --local
        \\    println("$d $local")
        \\    log = ""
        \\    val e = ++A.x
        \\    println("$e $log")
        \\}
    }, "1 getA;get;set;get;\n1 getA;get;set;\n6 get3;set3;get3;\n6 6\n1 get;set;get;\n");
}

test "a tailrec call leaving arguments out, or returning from an inline lambda, jumps" {
    try driver.expectOutput(&.{
        \\var counter = 0
        \\fun next(): Int = counter++
        \\tailrec fun countDown(n: Int, step: Int = 1, trace: String = "t$n"): String {
        \\    if (n <= 0) return trace
        \\    return countDown(n - step)
        \\}
        \\tailrec fun sides(x: Int = 0, y: Int = next(), z: Int = y + next()): String {
        \\    if (x >= 3) return "x=$x y=$y z=$z counter=$counter"
        \\    return sides(z = next(), x = x + 1)
        \\}
        \\class Loop {
        \\    private inline fun act(action: () -> Unit) = action()
        \\    private var left = 50000
        \\    tailrec fun run(): Int {
        \\        if (left < 5) return left
        \\        act {
        \\            left--
        \\            return run()
        \\        }
        \\        return left
        \\    }
        \\}
        \\open class Base {
        \\    open fun foo(s: String = "OK") = s
        \\}
        \\class Over : Base() {
        \\    override tailrec fun foo(s: String): String = if (s == "OK") s else foo()
        \\}
        \\fun main() {
        \\    println(countDown(50000))
        \\    println(sides(0, 10, 20))
        \\    println(Loop().run())
        \\    println(Over().foo("FAIL"))
        \\}
    }, "t0\nx=3 y=5 z=4 counter=6\n4\nOK\n");
}

test "a return with a value from a constructor still gives the instance" {
    try driver.expectOutput(&.{
        \\class A {
        \\    val prop: Int
        \\    constructor(arg: Boolean) {
        \\        if (arg) {
        \\            prop = 1
        \\            return Unit
        \\        }
        \\        prop = 2
        \\    }
        \\}
        \\fun main() {
        \\    println(A(true).prop)
        \\    println(A(false).prop)
        \\}
    }, "1\n2\n");
}

test "a data object hashes as its qualified name" {
    try driver.expectOutput(&.{
        \\data object Top {
        \\    data object Inner
        \\}
        \\fun main() {
        \\    println(Top.hashCode() == "Top".hashCode())
        \\    println(Top.Inner.hashCode() == "Top.Inner".hashCode())
        \\    println(Top.Inner)
        \\}
    }, "true\ntrue\nInner\n");
}

test "a value class sets its properties before its supertype initializes" {
    try driver.expectOutput(&.{
        \\var log = ""
        \\abstract value class Base(a: Int) {
        \\    abstract val i: Int
        \\    init {
        \\        log += "Base(a=$a, i=$i) "
        \\    }
        \\}
        \\value class Derived(override val i: Int) : Base(i + 1) {
        \\    init {
        \\        log += "Derived($i)"
        \\    }
        \\}
        \\fun main() {
        \\    Derived(42)
        \\    println(log)
        \\}
    }, "Base(a=43, i=42) Derived(42)\n");
}

test "an annotation instance renders its qualified name, a data class its simple one" {
    try driver.expectOutput(&.{
        \\package test
        \\annotation class One<T>()
        \\annotation class Named(val s: String, val n: Int)
        \\class Outer {
        \\    annotation class Inner(val v: Int)
        \\}
        \\data class D(val a: Int)
        \\fun main() {
        \\    println(One<String>())
        \\    println(Named("x", 2))
        \\    println(Outer.Inner(3))
        \\    println(D(1))
        \\}
    }, "@test.One()\n@test.Named(s=x, n=2)\n@test.Outer.Inner(v=3)\nD(a=1)\n");
}

test "a fun interface inheriting its abstract method converts a lambda to it" {
    try driver.expectOutput(&.{
        \\fun interface Base {
        \\    fun doStuff(): String
        \\}
        \\fun interface I : Base
        \\fun interface G<T> {
        \\    fun foo(t: T): T
        \\}
        \\fun interface C : G<Char>
        \\fun runI(i: I) = i.doStuff()
        \\fun main() {
        \\    println(runI { "i" })
        \\    val c = C { it + 2 }
        \\    println(c.foo('A'))
        \\    val b: Base = I { "base" }
        \\    println(b.doStuff())
        \\}
    }, "i\nC\nbase\n");
}

// kotlinc 2.4.20 prints the same.
test "a fun interface wrapper equals a wrapper over an equal function and hashes as it" {
    try driver.expectOutput(&.{
        \\fun interface Action { fun run() }
        \\fun id(f: Action): Any = f
        \\class C {
        \\    fun a() {}
        \\    fun b() {}
        \\}
        \\fun top() {}
        \\fun main() {
        \\    val c = C()
        \\    println(id(c::a) == id(c::a))
        \\    println(id(c::a).hashCode() == id(c::a).hashCode())
        \\    println(id(c::a) == id(c::b))
        \\    println(id(C()::a) == id(c::a))
        \\    println(id(::top) == id(::top))
        \\    val f = { println("x") }
        \\    println(id(f) == id(f))
        \\    println(id { } == id { })
        \\    val w = id(c::a)
        \\    println(w == w)
        \\    println(w.equals(null))
        \\}
    }, "true\ntrue\nfalse\nfalse\ntrue\ntrue\nfalse\ntrue\nfalse\n");
}

test "a class's superclass initializes its companion first, as the JVM's class initialization" {
    try driver.expectOutput(&.{
        \\var l = ""
        \\open class B1 {
        \\    init { l += "B1.init " }
        \\    companion object { init { l += "B1.C " } }
        \\}
        \\class A1 : B1() {
        \\    init { l += "A1.init " }
        \\    companion object { init { l += "A1.C " } }
        \\}
        \\open class B2 {
        \\    companion object { init { l += "B2.C " } }
        \\}
        \\class A2 : B2() {
        \\    companion object { init { l += "A2.C " } }
        \\}
        \\open class M3 {
        \\    companion object { init { l += "M3.C " } }
        \\}
        \\open class N3 : M3()
        \\class O3 : N3() {
        \\    init { l += "O3.init " }
        \\}
        \\fun main() {
        \\    A1()
        \\    println(l)
        \\    l = ""
        \\    A2
        \\    println(l)
        \\    l = ""
        \\    O3()
        \\    println(l)
        \\}
    }, "B1.C A1.C B1.init A1.init \nB2.C A2.C \nM3.C O3.init \n");
}

test "an initializer that sets a field to its default is dropped, as on the JVM" {
    try driver.expectOutput(&.{
        \\val a = run { b = 5; s = "set"; n = 7L; neg = 3.0; 1 }
        \\var b = 0
        \\var s: String? = null
        \\var n = 0L
        \\var neg = -0.0
        \\object Obj {
        \\    val first = run { later = 9; 1 }
        \\    var later = 0
        \\}
        \\class Foo(v: Int) {
        \\    init { setValue(v) }
        \\    fun setValue(x: Int) {
        \\        field = x
        \\        flag = true
        \\        ch = 'z'
        \\        nonDefault = x
        \\        viaExpr = x
        \\    }
        \\    var field: Int = 0
        \\    var flag = false
        \\    var ch = '\u0000'
        \\    var nonDefault = 1
        \\    var viaExpr = 0 + 0
        \\}
        \\fun main() {
        \\    println("$a $b $s $n $neg")
        \\    println(Obj.later)
        \\    val f = Foo(4)
        \\    println("${f.field} ${f.flag} ${f.ch} ${f.nonDefault} ${f.viaExpr}")
        \\}
    }, "1 5 set 7 -0.0\n9\n4 true z 1 4\n");
}

// kotlinc 2.4.20 prints the same for these two files as Test0Kt and Test1Kt.
test "a failed initializer throws ExceptionInInitializerError, then NoClassDefFoundError naming its JVM class" {
    try driver.expectOutput(&.{
        \\import cfg.limit
        \\class Outer {
        \\    object Inner {
        \\        val v: Int = compute()
        \\    }
        \\}
        \\fun compute(): Int { throw IllegalStateException("bad") }
        \\fun report(tag: String, e: Throwable) {
        \\    println(tag + " " + (e is java.lang.ExceptionInInitializerError) + " " + (e is java.lang.NoClassDefFoundError) + " " + e.message)
        \\    val c = e.cause
        \\    println("  cause " + (c is IllegalStateException) + " " + (c is java.lang.ExceptionInInitializerError))
        \\}
        \\fun main() {
        \\    try { println(limit) } catch (e: Throwable) { report("file first", e) }
        \\    try { println(limit) } catch (e: Throwable) { report("file later", e) }
        \\    try { println(Outer.Inner.v) } catch (e: Throwable) { report("object first", e) }
        \\    try { println(Outer.Inner.v) } catch (e: Throwable) { report("object later", e) }
        \\}
        ,
        \\package cfg
        \\val limit: Int = fail()
        \\fun fail(): Int { throw IllegalStateException("bad") }
    },
        \\file first true false null
        \\  cause true false
        \\file later false true Could not initialize class cfg.Test1Kt
        \\  cause false true
        \\object first true false null
        \\  cause true false
        \\object later false true Could not initialize class Outer$Inner
        \\  cause false true
        \\
    );
}

test "a file's JvmName annotation does not rename its facade" {
    try driver.expectOutput(&.{
        \\import cfg.limit
        \\fun main() {
        \\    try { println(limit) } catch (e: Throwable) {}
        \\    try { println(limit) } catch (e: Throwable) { println(e.message) }
        \\}
        ,
        \\@file:JvmName("Config")
        \\package cfg
        \\val limit: Int = fail()
        \\fun fail(): Int { throw IllegalStateException("bad") }
    }, "Could not initialize class cfg.Test1Kt\n");
}
