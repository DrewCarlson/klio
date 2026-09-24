//! Package B's tests: identities, dispatch and ancestor tables, field
//! layouts, captures and cells, over the miniature base and a program.

const std = @import("std");
const sema = @import("sema");
const ir = @import("ir");
const runtime = @import("runtime");

const driver = @import("../lower_driver.zig");

const Sym = sema.Sym;
const Bridge = ir.bridge.Bridge;
const CaptureKey = ir.bridge.CaptureKey;
const ClassId = ir.ClassId;
const FuncId = ir.FuncId;

const Fx = struct {
    arena: *std.heap.ArenaAllocator,
    an: driver.Analysis,

    fn init(sources: []const []const u8) !Fx {
        return initWith(sources, .{});
    }

    fn initWith(sources: []const []const u8, opts: driver.AnalyzeOptions) !Fx {
        const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer {
            arena.deinit();
            std.testing.allocator.destroy(arena);
        }
        const an = try driver.analyzeWith(arena.allocator(), sources, opts);
        const census = try an.census(arena.allocator(), .program);
        if (census.len != 0) {
            std.debug.print("unresolved:\n{s}", .{census});
            return error.TestUnexpectedResult;
        }
        return .{ .arena = arena, .an = an };
    }

    fn deinit(self: *Fx) void {
        self.arena.deinit();
        std.testing.allocator.destroy(self.arena);
    }

    fn br(self: *const Fx) *Bridge {
        return self.an.br;
    }

    fn s(self: *const Fx) *sema.Sema {
        return self.an.s;
    }

    fn class(self: *const Fx, fqn: []const u8) !Sym {
        const c = self.s().classByFqn(fqn);
        if (c == .none) {
            std.debug.print("no class {s}\n", .{fqn});
            return error.TestUnexpectedResult;
        }
        return c;
    }

    fn cid(self: *const Fx, fqn: []const u8) !ClassId {
        return self.br().classOf(try self.class(fqn));
    }

    /// The member `name` `cls` itself declares; the first when overloaded.
    fn member(self: *const Fx, cls: Sym, name: []const u8) !Sym {
        const s_ = self.s();
        if (s_.names.lookup(name)) |n| {
            for (sema.symbols.Symbols.members(&s_.syms.classInfo(cls).members, n)) |m| {
                if (s_.syms.owner(m) == cls) return m;
            }
        }
        std.debug.print("no member {s}\n", .{name});
        return error.TestUnexpectedResult;
    }

    fn memberOf(self: *const Fx, fqn: []const u8, name: []const u8) !Sym {
        return self.member(try self.class(fqn), name);
    }

    fn func(self: *const Fx, fqn: []const u8, name: []const u8) !FuncId {
        return self.br().funcOf(try self.memberOf(fqn, name));
    }

    /// The overload of `name` class `fqn` declares whose first parameter
    /// is named `param`.
    fn overload(self: *const Fx, fqn: []const u8, name: []const u8, param: []const u8) !FuncId {
        const s_ = self.s();
        const cls = try self.class(fqn);
        if (s_.names.lookup(name)) |n| {
            for (sema.symbols.Symbols.members(&s_.syms.classInfo(cls).members, n)) |m| {
                if (s_.syms.owner(m) != cls or s_.syms.kind(m) != .function) continue;
                const ps = s_.syms.functionInfo(m).params;
                if (ps.len != 0 and std.mem.eql(u8, s_.str(s_.syms.name(ps[0])), param)) return self.br().funcOf(m);
            }
        }
        std.debug.print("no {s}.{s}({s})\n", .{ fqn, name, param });
        return error.TestUnexpectedResult;
    }

    /// A symbol of `kind` named `name` declared in a program file.
    fn programSym(self: *const Fx, kind: sema.symbols.Kind, name: []const u8) !Sym {
        const s_ = self.s();
        var i: u32 = 1;
        while (i < s_.syms.count()) : (i += 1) {
            const sym = Sym.from(i);
            if (s_.syms.kind(sym) != kind) continue;
            if (!std.mem.eql(u8, s_.str(s_.syms.name(sym)), name)) continue;
            const f = s_.syms.get(sym).file;
            if (f < s_.files.items.len and s_.files.items[f].origin == .program) return sym;
        }
        std.debug.print("no {s} {s}\n", .{ @tagName(kind), name });
        return error.TestUnexpectedResult;
    }

    /// The local a committed record declares under `name`.
    fn local(self: *const Fx, name: []const u8) !Sym {
        const s_ = self.s();
        for (self.an.out.files) |fr| for (fr.refs) |r| {
            if (r.kind != .decl or r.target == .none) continue;
            if (s_.syms.kind(r.target) != .local) continue;
            if (std.mem.eql(u8, s_.str(s_.syms.name(r.target)), name)) return r.target;
        };
        std.debug.print("no local {s}\n", .{name});
        return error.TestUnexpectedResult;
    }

    /// The lambdas and anonymous functions of the program with ids, in id order.
    fn lambdas(self: *const Fx) ![]const Sym {
        const s_ = self.s();
        var out: std.ArrayList(Sym) = .empty;
        for (self.br().origin) |o| switch (o) {
            .lambda => |f| {
                const file = s_.syms.get(f).file;
                if (s_.files.items[file].origin != .program) continue;
                if (s_.syms.get(f).decl == .function) continue;
                try out.append(self.arena.allocator(), f);
            },
            else => {},
        };
        return out.items;
    }

    fn dispatch(self: *const Fx, c: ClassId, slot_func: FuncId) ?FuncId {
        return self.br().m.method_dispatch.get((@as(u64, c.int()) << 32) | slot_func.int());
    }

    fn captures(self: *const Fx, f: FuncId) []const CaptureKey {
        return self.br().capturesOf(f);
    }

    fn keyName(self: *const Fx, k: CaptureKey) []const u8 {
        const s_ = self.s();
        return switch (k) {
            .local => |l| s_.str(s_.syms.name(l)),
            .receiver => |r| s_.str(s_.syms.name(r.owner)),
        };
    }

    fn expectCaptures(self: *const Fx, keys: []const CaptureKey, want: []const []const u8) !void {
        var got: std.ArrayList(u8) = .empty;
        const a = self.arena.allocator();
        for (keys, 0..) |k, i| {
            if (i != 0) try got.appendSlice(a, ", ");
            try got.appendSlice(a, self.keyName(k));
        }
        var exp: std.ArrayList(u8) = .empty;
        for (want, 0..) |w, i| {
            if (i != 0) try exp.appendSlice(a, ", ");
            try exp.appendSlice(a, w);
        }
        try std.testing.expectEqualStrings(exp.items, got.items);
    }
};

test "every declaration gets an id, and the ids are dense" {
    var fx = try Fx.init(&.{
        \\package demo
        \\open class Base(val x: Int, var y: Int) {
        \\    open fun f(): Int = x
        \\    val z = 2
        \\}
        \\class Sub : Base(1, 2) { override fun f(): Int = 3 }
        \\object Obj { fun g() = 1 }
        \\enum class Color { RED, GREEN }
        \\fun top(a: Int = 1) = a
        \\val topVal = 5
        \\fun main() {
        \\    val l = { 1 }
        \\    fun local() = 2
        \\    println(l() + local())
        \\}
    });
    defer fx.deinit();
    const br = fx.br();
    const m = br.m;
    try std.testing.expectEqual(br.origin.len, m.funcs.items.len);
    for (m.funcs.items, 0..) |f, i| try std.testing.expectEqual(@as(u32, @intCast(i)), f.id.int());
    try std.testing.expectEqual(br.class_origin.len, m.classes.items.len);
    for (m.classes.items, 0..) |c, i| try std.testing.expectEqual(@as(u32, @intCast(i)), c.id.int());
    try std.testing.expectEqual(m.classes.items.len, m.resolved.?.classes.len);

    const base = try fx.class("demo.Base");
    _ = br.classOf(base);
    _ = try fx.func("demo.Base", "f");
    _ = br.funcOf(fx.s().syms.classInfo(base).primary_ctor);
    const x = try fx.member(base, "x");
    const y = try fx.member(base, "y");
    _ = br.getterOf(x);
    try std.testing.expect(br.setterOf(x) == null);
    try std.testing.expect(br.setterOf(y) != null);
    _ = try fx.func("demo.Sub", "f");
    _ = try fx.func("demo.Obj", "g");
    try std.testing.expect(br.staticOf(try fx.memberOf("demo.Color", "RED")) != null);
    try std.testing.expect(br.staticOf(try fx.memberOf("demo.Color", "GREEN")) != null);
    const top = try fx.programSym(.function, "top");
    _ = br.funcOf(top);
    try std.testing.expect(br.defaultsOf(top) != null);
    try std.testing.expect(br.staticOf(try fx.programSym(.property, "topVal")) != null);
    _ = br.funcOf(try fx.programSym(.function, "local"));
    try std.testing.expectEqual(@as(usize, 1), (try fx.lambdas()).len);
    // Every shell is kept off the tiers that cannot run the new instructions.
    for (m.funcs.items) |f| try std.testing.expectEqual(@as(u8, 1), f.leaf_hopeless);
}

test "the same sources give the same ids, and the base keeps its ids under another program" {
    const p1 = &.{
        \\package demo
        \\class A { fun f() = 1 }
        \\fun main() { println(A().f()) }
    };
    const p2 = &.{
        \\package other
        \\interface I { fun g(): Int }
        \\class B : I { override fun g() = 2 }
        \\fun h() = listOf(1, 2).map { it + 1 }
        \\fun main() { println(B().g()) }
    };
    var one = try Fx.init(p1);
    defer one.deinit();
    var again = try Fx.init(p1);
    defer again.deinit();
    var other = try Fx.init(p2);
    defer other.deinit();

    const b1 = one.br();
    const b2 = again.br();
    try std.testing.expectEqual(b1.origin.len, b2.origin.len);
    for (b1.origin, b2.origin) |x, y| try std.testing.expect(std.meta.eql(x, y));
    try std.testing.expectEqualSlices(FuncId, b1.func_of, b2.func_of);
    try std.testing.expectEqualSlices(ClassId, b1.class_of, b2.class_of);
    try std.testing.expectEqualSlices(u32, b1.field_of, b2.field_of);

    // The base layer's ids: equal counts, and each id names the same
    // declaration, whatever the program.
    const e1 = b1.layer_ends[0];
    const e3 = other.br().layer_ends[0];
    try std.testing.expectEqual(e1, e3);
    var i: u32 = 0;
    while (i < e1.funcs) : (i += 1) {
        try std.testing.expectEqualStrings(b1.m.funcs.items[i].fqn, other.br().m.funcs.items[i].fqn);
        try std.testing.expectEqual(std.meta.activeTag(b1.origin[i]), std.meta.activeTag(other.br().origin[i]));
    }
    i = 0;
    while (i < e1.classes) : (i += 1) {
        try std.testing.expectEqualStrings(b1.m.classes.items[i].fqn, other.br().m.classes.items[i].fqn);
    }
    // The base's global symbols number the same way, so their arrays agree.
    const base_syms = one.an.layers[0].syms;
    try std.testing.expectEqual(base_syms, other.an.layers[0].syms);
    try std.testing.expectEqualSlices(FuncId, b1.func_of[0..base_syms], other.br().func_of[0..base_syms]);
    // The program's ids follow the base's.
    const a_f = try one.func("demo.A", "f");
    try std.testing.expect(a_f.int() >= e1.funcs);
}

test "dispatch follows override links, one entry per root of a diamond" {
    var fx = try Fx.init(&.{
        \\package demo
        \\interface I {
        \\    fun f(): String = "I.f"
        \\    fun g(): String
        \\}
        \\interface J { fun f(): String = "J.f" }
        \\abstract class A {
        \\    abstract fun h(): Int
        \\    open fun k(): Int = 1
        \\}
        \\open class B : A(), I, J {
        \\    override fun f(): String = "B.f"
        \\    override fun g(): String = "B.g"
        \\    override fun h(): Int = 2
        \\}
        \\class C : B() { override fun k(): Int = 3 }
        \\class D : I { override fun g(): String = "D.g" }
        \\fun main() {}
    });
    defer fx.deinit();
    const br = fx.br();
    const i_f = try fx.func("demo.I", "f");
    const j_f = try fx.func("demo.J", "f");
    const b_f = try fx.func("demo.B", "f");
    const a_h = try fx.func("demo.A", "h");
    const a_k = try fx.func("demo.A", "k");
    const B = try fx.cid("demo.B");
    const C = try fx.cid("demo.C");
    const A = try fx.cid("demo.A");
    const D = try fx.cid("demo.D");
    // A member overriding two roots answers both.
    try std.testing.expectEqual(b_f, fx.dispatch(B, i_f).?);
    try std.testing.expectEqual(b_f, fx.dispatch(B, j_f).?);
    // Its slot is one of the roots.
    const sl = br.slotOf(b_f).?.int();
    try std.testing.expect(sl == i_f.int() or sl == j_f.int());
    // A subclass inherits entries it does not override.
    try std.testing.expectEqual(b_f, fx.dispatch(C, i_f).?);
    try std.testing.expectEqual(try fx.func("demo.C", "k"), fx.dispatch(C, a_k).?);
    try std.testing.expectEqual(a_k, fx.dispatch(B, a_k).?);
    // An abstract root has an id and no entry of its own.
    try std.testing.expect(br.origin[a_h.int()] == .abstract);
    try std.testing.expect(fx.dispatch(A, a_h) == null);
    try std.testing.expectEqual(try fx.func("demo.B", "h"), fx.dispatch(B, a_h).?);
    // An interface default serves a class that does not override it.
    try std.testing.expectEqual(i_f, fx.dispatch(D, i_f).?);
    // `Any`'s members reach every class, bound to their natives.
    const to_string = try fx.func("kotlin.Any", "toString");
    try std.testing.expectEqual(to_string, fx.dispatch(C, to_string).?);
    try std.testing.expect(br.m.resolved.?.func_native[to_string.int()] != .none);
    // The native names the slot it implements, so a call site bound to it
    // can run a receiver's override.
    const r = br.m.resolved.?;
    try std.testing.expectEqual(to_string.int(), r.natives[r.func_native[to_string.int()].int()].slot);
}

test "a class slot sits at one vtable index down its subclasses, an interface's in the table each class keeps for it" {
    var fx = try Fx.init(&.{
        \\package demo
        \\interface I {
        \\    fun f(): String = "I.f"
        \\    fun g(): String
        \\}
        \\abstract class A {
        \\    abstract fun h(): Int
        \\    open fun k(): Int = 1
        \\}
        \\open class B : A(), I {
        \\    override fun g(): String = "B.g"
        \\    override fun h(): Int = 2
        \\    open fun m(): Int = 4
        \\}
        \\class C : B() { override fun k(): Int = 3; override fun m(): Int = 5 }
        \\open class X { open fun q(): Int = 7 }
        \\fun main() {}
    });
    defer fx.deinit();
    const r = fx.br().m.resolved.?;
    const i_f = try fx.func("demo.I", "f");
    const i_g = try fx.func("demo.I", "g");
    const a_h = try fx.func("demo.A", "h");
    const a_k = try fx.func("demo.A", "k");
    const b_m = try fx.func("demo.B", "m");
    const to_string = try fx.func("kotlin.Any", "toString");
    const I = try fx.cid("demo.I");
    const A = try fx.cid("demo.A");
    const B = try fx.cid("demo.B");
    const C = try fx.cid("demo.C");
    const slot = ir.MethodSlotId.fromFunc;
    // `Any`'s slots lead every vtable; a class's own follow its superclass's.
    try std.testing.expect(r.slot_index[a_k.int()] >= 3);
    try std.testing.expect(r.slot_index[b_m.int()] >= r.classes[A.int()].vtable.len);
    try std.testing.expectEqual(r.classes[B.int()].vtable.len, r.classes[C.int()].vtable.len);
    try std.testing.expectEqual(ir.resolved.NONE, r.slot_iface[a_k.int()]);
    // An interface's slots are its own, at their place among its members.
    try std.testing.expectEqual(I.int(), r.slot_iface[i_f.int()]);
    try std.testing.expectEqual(I.int(), r.slot_iface[i_g.int()]);
    try std.testing.expect(r.slot_index[i_f.int()] != r.slot_index[i_g.int()]);
    // Every lookup agrees with the dispatch entries it was made from.
    for ([_]ir.ClassId{ A, B, C }) |c| {
        for ([_]FuncId{ i_f, i_g, a_h, a_k, b_m, to_string }) |root| {
            try std.testing.expectEqual(fx.dispatch(c, root), ir.resolved.slotTarget(r, c, slot(root)));
        }
    }
    try std.testing.expectEqual(try fx.func("demo.C", "m"), ir.resolved.slotTarget(r, C, slot(b_m)).?);
    try std.testing.expect(ir.resolved.slotTarget(r, A, slot(a_h)) == null);
    // A class outside `A`'s chain keeps its own slot at the index of one of
    // `A`'s, and answers nothing for `A`'s.
    const X = try fx.cid("demo.X");
    const x_q = try fx.func("demo.X", "q");
    const shared = for ([_]FuncId{ a_h, a_k }) |f| {
        if (r.slot_index[f.int()] == r.slot_index[x_q.int()]) break f;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(ir.resolved.slotTarget(r, X, slot(shared)) == null);
    try std.testing.expectEqual(x_q, ir.resolved.slotTarget(r, X, slot(x_q)).?);
}

test "ancestors are the sorted closure of supertypes, Any included" {
    var fx = try Fx.init(&.{
        \\package demo
        \\interface I
        \\open class A : I
        \\class B : A()
        \\fun main() {}
    });
    defer fx.deinit();
    const m = fx.br().m;
    const B = try fx.cid("demo.B");
    const anc = m.class_ancestors.items[B.int()];
    for ([_][]const u8{ "demo.B", "demo.A", "demo.I", "kotlin.Any" }) |fqn| {
        try std.testing.expect(m.classIsA(B, try fx.cid(fqn)));
    }
    try std.testing.expect(!m.classIsA(try fx.cid("demo.A"), B));
    var prev: u32 = 0;
    for (anc, 0..) |c, i| {
        if (i != 0) try std.testing.expect(c.int() > prev);
        prev = c.int();
    }
}

test "a class's run-time def names its ancestors, so the host's by-name subtype tests answer" {
    var fx = try Fx.init(&.{
        \\package demo
        \\interface I
        \\open class A : I
        \\class B : A()
        \\fun main() {}
    });
    defer fx.deinit();
    const r = fx.br().m.resolved orelse return error.TestUnexpectedResult;
    const def = r.classes[(try fx.cid("demo.B")).int()].def;
    const g = def.borrow();
    defer g.deinit();
    for ([_][]const u8{ "B", "A", "demo.A", "I", "demo.I", "kotlin.Any" }) |name| {
        try std.testing.expect(g.get().isSubtypeOf(std.testing.allocator, name));
    }
    try std.testing.expect(!g.get().isSubtypeOf(std.testing.allocator, "demo.C"));
}

test "a data class's run-time def lists its constructor properties, so host equality compares them" {
    var fx = try Fx.init(&.{
        \\package demo
        \\data class P(val a: Int, var b: String, c: Int = 0)
        \\class Q(val a: Int)
        \\fun main() {}
    });
    defer fx.deinit();
    const r = fx.br().m.resolved orelse return error.TestUnexpectedResult;
    const p_id = try fx.cid("demo.P");
    const def = r.classes[p_id.int()].def.asPtrConst();
    try std.testing.expectEqual(@as(usize, 2), def.primary_params.len);
    try std.testing.expectEqualStrings("a", def.primary_params[0].name);
    try std.testing.expectEqual(@as(?bool, false), def.primary_params[0].property);
    try std.testing.expectEqualStrings("b", def.primary_params[1].name);
    try std.testing.expectEqual(@as(?bool, true), def.primary_params[1].property);
    try std.testing.expectEqual(@as(usize, 0), r.classes[(try fx.cid("demo.Q")).int()].def.asPtrConst().primary_params.len);

    const a = fx.arena.allocator();
    const x = try ir.resolved.instantiate(a, r, p_id, 1);
    const y = try ir.resolved.instantiate(a, r, p_id, 2);
    const z = try ir.resolved.instantiate(a, r, p_id, 3);
    for ([_]runtime.Value{ x, y, z }, [_]i32{ 1, 2, 1 }) |v, n| {
        const g = v.Instance.borrowMut();
        defer g.deinit();
        try std.testing.expect(g.get().set("a", .{ .Int = n }));
    }
    try std.testing.expect(!runtime.Value.structuralEq(&x, &y));
    try std.testing.expect(runtime.Value.structuralEq(&x, &z));
}

test "layouts: superclass slots first, the outer instance, stored properties only" {
    var fx = try Fx.init(&.{
        \\package demo
        \\open class Base(val a: Int) {
        \\    val b: Int = 1
        \\    open val c: Int get() = 5
        \\    var d = "x"
        \\}
        \\class Sub(override val c: Int) : Base(0) {
        \\    val e = 2
        \\    val f: Int get() = 1
        \\}
        \\class Outer {
        \\    val o = 1
        \\    inner class Inner { val i = 2 }
        \\}
        \\class Deleg { val lz by lazy { 3 } }
        \\interface Named { val name: String }
        \\class N : Named { override val name: String get() = "n" }
        \\class F { var g: Int = 0
        \\    get() = field + 1
        \\    set(v) { field = v * 2 } }
        \\class H { val h: Int get() = 7 }
        \\fun main() {}
    });
    defer fx.deinit();
    const br = fx.br();
    const base = try fx.class("demo.Base");
    const sub = try fx.class("demo.Sub");
    try std.testing.expectEqual(@as(?u32, 0), br.fieldOf(try fx.member(base, "a")));
    try std.testing.expectEqual(@as(?u32, 1), br.fieldOf(try fx.member(base, "b")));
    try std.testing.expectEqual(@as(?u32, null), br.fieldOf(try fx.member(base, "c")));
    try std.testing.expectEqual(@as(?u32, 2), br.fieldOf(try fx.member(base, "d")));
    // A constructor `override val` is a declared member with its own slot.
    try std.testing.expectEqual(@as(?u32, 3), br.fieldOf(try fx.member(sub, "c")));
    try std.testing.expectEqual(@as(?u32, 4), br.fieldOf(try fx.member(sub, "e")));
    try std.testing.expectEqual(@as(?u32, null), br.fieldOf(try fx.member(sub, "f")));
    try std.testing.expectEqual(@as(u32, 5), br.slotCount(br.classOf(sub)));
    const seeds = br.m.resolved.?.classes[br.classOf(base).int()].seeds;
    try std.testing.expectEqualSlices(ir.SlotSeed, &.{ .int, .int, .null_ref }, seeds);
    // An inner class's outer instance precedes its own properties.
    const inner = try fx.class("demo.Outer.Inner");
    try std.testing.expectEqual(@as(?u32, 0), br.outerSlot(br.classOf(inner)));
    try std.testing.expectEqual(@as(?u32, 1), br.fieldOf(try fx.member(inner, "i")));
    try std.testing.expectEqual(@as(?u32, null), br.outerSlot(try fx.cid("demo.Outer")));
    // A delegated property stores its delegate, not a value.
    const lz = try fx.memberOf("demo.Deleg", "lz");
    try std.testing.expectEqual(@as(?u32, null), br.fieldOf(lz));
    try std.testing.expectEqual(@as(?u32, 0), br.delegateFieldOf(lz));
    // An accessor-only override contributes no slot.
    try std.testing.expectEqual(@as(u32, 0), br.slotCount(try fx.cid("demo.N")));
    // An accessor that reads `field` makes one; one that does not, none.
    try std.testing.expectEqual(@as(?u32, 0), br.fieldOf(try fx.memberOf("demo.F", "g")));
    try std.testing.expectEqual(@as(u32, 0), br.slotCount(try fx.cid("demo.H")));
}

test "accessors: one getter per property, a setter per var, slots from the property's roots" {
    var fx = try Fx.init(&.{
        \\package demo
        \\interface Shape { val area: Int }
        \\open class Sq(val side: Int) : Shape {
        \\    override val area: Int get() = side * side
        \\    open var label: String = "sq"
        \\}
        \\class Big(side: Int) : Sq(side) {
        \\    override var label: String = "big"
        \\}
        \\fun main() {}
    });
    defer fx.deinit();
    const br = fx.br();
    const shape_area = try fx.memberOf("demo.Shape", "area");
    const sq_area = try fx.memberOf("demo.Sq", "area");
    const sq_label = try fx.memberOf("demo.Sq", "label");
    const big_label = try fx.memberOf("demo.Big", "label");
    try std.testing.expect(br.origin[br.getterOf(shape_area).int()] == .abstract);
    try std.testing.expectEqual(br.getterOf(shape_area).int(), br.slotOf(br.getterOf(sq_area)).?.int());
    const Big = try fx.cid("demo.Big");
    try std.testing.expectEqual(br.getterOf(sq_area), fx.dispatch(Big, br.getterOf(shape_area)).?);
    try std.testing.expectEqual(br.getterOf(big_label), fx.dispatch(Big, br.getterOf(sq_label)).?);
    try std.testing.expectEqual(br.setterOf(big_label).?, fx.dispatch(Big, br.setterOf(sq_label).?).?);
    // A subclass that stores the property again gets its own slot.
    try std.testing.expect(br.fieldOf(big_label).? != br.fieldOf(sq_label).?);
}

test "delegated members forward through a slot holding the delegate" {
    var fx = try Fx.init(&.{
        \\package demo
        \\interface Greeter {
        \\    fun greet(): String
        \\    val name: String
        \\}
        \\class Impl : Greeter {
        \\    override fun greet() = "hi"
        \\    override val name = "impl"
        \\}
        \\class Wrapper(g: Greeter) : Greeter by g
        \\fun main() {}
    });
    defer fx.deinit();
    const br = fx.br();
    const s = fx.s();
    const wrapper = try fx.class("demo.Wrapper");
    const greet = try fx.member(wrapper, "greet");
    const name = try fx.member(wrapper, "name");
    try std.testing.expect(s.syms.functionInfo(greet).forwards != .none);
    try std.testing.expect(br.origin[br.funcOf(greet).int()] == .decl);
    try std.testing.expect(br.origin[br.getterOf(name).int()] == .getter);
    try std.testing.expectEqual(@as(?u32, 0), br.delegateSlot(wrapper, 0));
    const W = br.classOf(wrapper);
    try std.testing.expectEqual(br.funcOf(greet), fx.dispatch(W, try fx.func("demo.Greeter", "greet")).?);
    try std.testing.expectEqual(br.getterOf(name), fx.dispatch(W, br.getterOf(try fx.memberOf("demo.Greeter", "name"))).?);
}

test "a lambda resolved speculatively and then committed gets exactly one id" {
    // `none { ... }` is an argument whose type is open until `head`'s
    // expected type fixes it: sema resolves it once in a buffer it drops,
    // then again for real.
    var fx = try Fx.init(&.{
        \\package demo
        \\fun <T> none(f: () -> Unit): List<T> {
        \\    f()
        \\    return emptyList()
        \\}
        \\fun <T> head(xs: List<T>): T? = null
        \\fun main() {
        \\    val x: String? = head(none { println(1) })
        \\    println(x)
        \\}
    });
    defer fx.deinit();
    const s = fx.s();
    const lams = try fx.lambdas();
    try std.testing.expectEqual(@as(usize, 1), lams.len);
    const lit = s.syms.get(lams[0]).decl.lambda;
    var made: usize = 0;
    var ids: usize = 0;
    var i: u32 = 1;
    while (i < s.syms.count()) : (i += 1) {
        const d = s.syms.get(Sym.from(i)).decl;
        if (d != .lambda or d.lambda != lit) continue;
        made += 1;
        if (fx.br().funcOfOpt(Sym.from(i)) != null) ids += 1;
    }
    try std.testing.expect(made >= 2);
    try std.testing.expectEqual(@as(usize, 1), ids);
}

test "captures of nested lambdas, a recursive local function and a local class" {
    var fx = try Fx.init(&.{
        \\package demo
        \\fun main() {
        \\    val a = 1
        \\    var b = 2
        \\    val outer = {
        \\        val c = 3
        \\        val inner = { a + b + c }
        \\        inner()
        \\    }
        \\    fun rec(n: Int): Int = if (n == 0) a else rec(n - 1)
        \\    fun helper() = b
        \\    class Local { fun m() = helper() + a }
        \\    b = 5
        \\    println(outer() + rec(3) + Local().m())
        \\}
    });
    defer fx.deinit();
    const br = fx.br();
    const lams = try fx.lambdas();
    try std.testing.expectEqual(@as(usize, 2), lams.len);
    // The outer lambda holds what the inner one needs from outside it.
    try fx.expectCaptures(fx.captures(br.funcOf(lams[0])), &.{ "a", "b" });
    try fx.expectCaptures(fx.captures(br.funcOf(lams[1])), &.{ "a", "b", "c" });
    // A recursive local function knows its captures before its body lowers.
    const rec = try fx.programSym(.function, "rec");
    try fx.expectCaptures(fx.captures(br.funcOf(rec)), &.{"a"});
    try fx.expectCaptures(fx.captures(br.funcOf(try fx.programSym(.function, "helper"))), &.{"b"});
    // A local class holds what its members read and what the local
    // functions they call capture, after its own slots.
    const local = br.classOf(try fx.programSym(.class, "Local"));
    try fx.expectCaptures(br.class_captures[local.int()], &.{ "a", "b" });
    try std.testing.expectEqual(@as(u32, 0), br.capture_base[local.int()]);
    // Its constructor takes them after `this`.
    const ctor = br.funcOf(fx.s().syms.classInfo(try fx.programSym(.class, "Local")).primary_ctor);
    try std.testing.expectEqual(@as(usize, 3), br.m.funcs.items[ctor.int()].params.len);
    // A lifted local function takes its captures first.
    try std.testing.expectEqual(@as(usize, 2), br.m.funcs.items[br.funcOf(rec).int()].params.len);
    // The lambda's parameters are its own: none here.
    try std.testing.expectEqual(@as(usize, 0), br.m.funcs.items[br.funcOf(lams[0]).int()].params.len);
}

test "a var a nested body reads is a cell, a captured val is not" {
    var fx = try Fx.init(&.{
        \\package demo
        \\fun main() {
        \\    val a = 1
        \\    var b = 2
        \\    var c = 3
        \\    val late: Int
        \\    late = 4
        \\    val f = { a + b + late }
        \\    c = c + 1
        \\    b = 3
        \\    println(f() + c)
        \\}
    });
    defer fx.deinit();
    const br = fx.br();
    try std.testing.expect(!br.isCell(try fx.local("a")));
    try std.testing.expect(br.isCell(try fx.local("b")));
    // Not captured: a register.
    try std.testing.expect(!br.isCell(try fx.local("c")));
    // A `val` assigned after its declaration and captured.
    try std.testing.expect(br.isCell(try fx.local("late")));
}

test "a lambda in a member captures the class's this; one reading field captures it too" {
    var fx = try Fx.init(&.{
        \\package demo
        \\class K(val x: Int) {
        \\    fun f(): () -> Int = { x + 1 }
        \\    var y: Int = 0
        \\        get() = run { field + 1 }
        \\}
        \\fun main() {}
    });
    defer fx.deinit();
    const br = fx.br();
    const lams = try fx.lambdas();
    try std.testing.expectEqual(@as(usize, 2), lams.len);
    for (lams) |l| {
        const caps = fx.captures(br.funcOf(l));
        try std.testing.expectEqual(@as(usize, 1), caps.len);
        try std.testing.expect(caps[0] == .receiver and caps[0].receiver.kind == .class_this);
        try std.testing.expectEqual(try fx.class("demo.K"), caps[0].receiver.owner);
    }
}

test "natives bind bodyless declarations by their FQN, once" {
    var fx = try Fx.init(&.{"fun main() {}"});
    defer fx.deinit();
    const br = fx.br();
    const r = br.m.resolved.?;
    const string = try fx.class("kotlin.String");
    const length = try fx.member(string, "length");
    // A builtin's bodyless property reads through its native getter.
    try std.testing.expect(br.nativeOf(length) != .none);
    try std.testing.expect(br.fieldOf(length) == null);
    try std.testing.expect(r.func_native[br.getterOf(length).int()] != .none);
    // A declaration with a body is never bound.
    const plus = br.funcOf(try fx.member(string, "plus"));
    try std.testing.expectEqual(ir.NativeId.none, r.func_native[plus.int()]);
    // Each native is named by the declaration it serves.
    const n = r.func_native[(try fx.func("kotlin.Any", "toString")).int()];
    try std.testing.expectEqualStrings("kotlin.Any.toString", r.natives[n.int()].name);
    // The host classes name the primitives' classes.
    try std.testing.expectEqual(try fx.cid("kotlin.Int"), r.host_class.int.?);
    try std.testing.expectEqual(try fx.cid("kotlin.String"), r.host_class.string.?);
    try std.testing.expectEqual(try fx.cid("kotlin.Function1"), r.host_class.function[1]);
    try std.testing.expectEqual(try fx.func("kotlin.Function1", "invoke"), FuncId.from(r.host_class.invoke_slot[1].int()));
}

test "statics, init units and singletons" {
    var fx = try Fx.init(&.{
        \\package demo
        \\val first = 1
        \\var second: String = "s"
        \\val computed: Int get() = 3
        \\enum class Color { RED, GREEN }
        \\object Registry { val n = 1 }
        \\class Owner { companion object { val k = 2 } }
        \\fun main() {}
    });
    defer fx.deinit();
    const br = fx.br();
    const r = br.m.resolved.?;
    const first = br.staticOf(try fx.programSym(.property, "first")).?;
    const second = br.staticOf(try fx.programSym(.property, "second")).?;
    try std.testing.expect(br.staticOf(try fx.programSym(.property, "computed")) == null);
    try std.testing.expectEqual(ir.SlotSeed.int, r.statics[first.int()].seed);
    // One unit per file, holding its statics.
    try std.testing.expectEqual(r.statics[first.int()].unit, r.statics[second.int()].unit);
    const file_unit = r.statics[first.int()].unit;
    try std.testing.expect(br.units[file_unit] == .file);
    // One unit per enum class, holding its entries.
    const red = br.staticOf(try fx.memberOf("demo.Color", "RED")).?;
    const unit = r.statics[red.int()].unit;
    try std.testing.expect(br.units[unit] == .enum_class);
    try std.testing.expect(br.origin[r.init_units[unit].func.int()] == .init_unit);
    // An object and a companion construct through their constructors.
    const reg = try fx.class("demo.Registry");
    try std.testing.expectEqual(br.funcOf(fx.s().syms.classInfo(reg).primary_ctor).int(), r.classes[br.classOf(reg).int()].object_ctor);
    const comp = fx.s().syms.classInfo(try fx.class("demo.Owner")).companion;
    try std.testing.expect(r.classes[br.classOf(comp).int()].object_ctor != ir.NO_FUNC);
}

test "a fun interface gets a SAM class implementing its method" {
    var fx = try Fx.init(&.{
        \\package demo
        \\fun interface Action { fun run(x: Int): Int }
        \\fun main() {
        \\    val a = Action { it + 1 }
        \\    println(a.run(1))
        \\}
    });
    defer fx.deinit();
    const br = fx.br();
    const action = try fx.class("demo.Action");
    const sam = br.samClassOf(action).?;
    const ctor = br.samCtorOf(action).?;
    const method = br.samMethodOf(action).?;
    try std.testing.expect(br.origin[ctor.int()] == .sam_ctor);
    try std.testing.expectEqual(method, fx.dispatch(sam, try fx.func("demo.Action", "run")).?);
    try std.testing.expect(br.m.classIsA(sam, br.classOf(action)));
    try std.testing.expectEqual(@as(u32, 1), br.slotCount(sam));
    try std.testing.expectEqual(@as(usize, 2), br.m.funcs.items[method.int()].params.len);
}

test "callable references share an adapter per target, type and bound kind" {
    var fx = try Fx.init(&.{
        \\package demo
        \\fun twice(x: Int) = x * 2
        \\fun main() {
        \\    val f = ::twice
        \\    val g = ::twice
        \\    println(f(1) + g(2))
        \\}
    });
    defer fx.deinit();
    const br = fx.br();
    try std.testing.expectEqual(@as(usize, 1), br.adapters.len);
    var n: usize = 0;
    var it = br.adapter_at.valueIterator();
    while (it.next()) |f| {
        try std.testing.expect(br.origin[f.int()] == .adapter);
        try std.testing.expectEqual(@as(usize, 1), br.m.funcs.items[f.int()].params.len);
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "an override uses the defaults bridge of the declaration it overrides" {
    var fx = try Fx.init(&.{
        \\package demo
        \\open class P { open fun f(x: Int = 1, y: Int = 2) = x + y }
        \\class Q : P() { override fun f(x: Int, y: Int) = x * y }
        \\fun main() {}
    });
    defer fx.deinit();
    const br = fx.br();
    const pf = try fx.memberOf("demo.P", "f");
    const d = br.defaultsOf(pf).?;
    try std.testing.expect(br.origin[d.int()] == .defaults);
    try std.testing.expectEqual(d, br.defaultsOf(try fx.memberOf("demo.Q", "f")).?);
    // this, x, y, one mask.
    try std.testing.expectEqual(@as(usize, 4), br.m.funcs.items[d.int()].params.len);
}

test "the calling convention sizes every shell's parameters" {
    var fx = try Fx.init(&.{
        \\package demo
        \\class Outer { inner class In(val v: Int) }
        \\enum class E(val code: Int) { A(1) }
        \\fun Int.ext(y: Int) = this + y
        \\class M { fun Int.memberExt() = this }
        \\val String.size2: Int get() = length
        \\inline fun <reified T> isIt(x: Any) = x is T
        \\fun main() {}
    });
    defer fx.deinit();
    const br = fx.br();
    const params = struct {
        fn of(b: *Bridge, f: FuncId) usize {
            return b.m.funcs.items[f.int()].params.len;
        }
    }.of;
    const s = fx.s();
    // this, the outer instance, v.
    try std.testing.expectEqual(@as(usize, 3), params(br, br.funcOf(s.syms.classInfo(try fx.class("demo.Outer.In")).primary_ctor)));
    // this, name, ordinal, code.
    try std.testing.expectEqual(@as(usize, 4), params(br, br.funcOf(s.syms.classInfo(try fx.class("demo.E")).primary_ctor)));
    // The extension receiver, y.
    try std.testing.expectEqual(@as(usize, 2), params(br, br.funcOf(try fx.programSym(.function, "ext"))));
    // this, the extension receiver.
    try std.testing.expectEqual(@as(usize, 2), params(br, try fx.func("demo.M", "memberExt")));
    // The extension receiver.
    try std.testing.expectEqual(@as(usize, 1), params(br, br.getterOf(try fx.programSym(.property, "size2"))));
    // x, the reified type value.
    try std.testing.expectEqual(@as(usize, 2), params(br, br.funcOf(try fx.programSym(.function, "isIt"))));
}

test "an inherited member implements the interface member its substituted parameter types equal, not one that erases alike" {
    var fx = try Fx.init(&.{
        \\package demo
        \\open class A<T> {
        \\    fun foo(t: T) = "O"
        \\    fun foo(at: A<T>) = "K"
        \\}
        \\interface C<E> {
        \\    fun foo(e: E): String
        \\    fun foo(ae: A<E>): String
        \\}
        \\interface D { fun foo(aas: A<A<String>>): String }
        \\class B : A<A<String>>(), C<A<String>>, D
        \\fun main() {}
    });
    defer fx.deinit();
    const b = try fx.cid("demo.B");
    const a_t = try fx.overload("demo.A", "foo", "t");
    const a_at = try fx.overload("demo.A", "foo", "at");
    // `C.foo(e: E)` is `foo(A<String>)`: `A.foo(t: T)` with T = A<String>.
    try std.testing.expectEqual(a_t, fx.dispatch(b, try fx.overload("demo.C", "foo", "e")).?);
    // `C.foo(ae: A<E>)` and `D.foo` are `foo(A<A<String>>)`: `A.foo(at: A<T>)`,
    // though `A.foo(t: T)` takes an `A` too.
    try std.testing.expectEqual(a_at, fx.dispatch(b, try fx.overload("demo.C", "foo", "ae")).?);
    try std.testing.expectEqual(a_at, fx.dispatch(b, try fx.overload("demo.D", "foo", "aas")).?);
}

fn declineAll(host: *anyopaque, a: std.mem.Allocator, args: []const runtime.Value) std.mem.Allocator.Error!?ir.eval.EvalResult {
    _ = host;
    _ = a;
    _ = args;
    return null;
}

fn baseTwiceOnly(key: []const u8) ?ir.resolved.HostTry {
    return if (std.mem.eql(u8, key, "demo.Base.twice")) declineAll else null;
}

test "a fast path the host has for a declaration fronts its body, and the body stays" {
    var fx = try Fx.initWith(&.{
        \\package demo
        \\open class Base { open fun twice(x: Int): Int = x * 2 }
        \\class Derived : Base()
        \\class Other { fun twice(x: Int): Int = x + x }
        \\fun main() { println(Derived().twice(3) + Other().twice(1)) }
    }, .{ .host_tries = baseTwiceOnly });
    defer fx.deinit();
    const r = fx.br().m.resolved.?;
    const base_twice = try fx.func("demo.Base", "twice");
    const other_twice = try fx.func("demo.Other", "twice");
    const nid = r.func_try[base_twice.int()];
    try std.testing.expect(nid != .none);
    try std.testing.expect(r.natives[nid.int()].host_try != null);
    try std.testing.expectEqual(ir.resolved.NativeTable.tries, r.natives[nid.int()].table);
    // No native replaces the body, so it runs where the fast path declines.
    try std.testing.expectEqual(ir.NativeId.none, r.func_native[base_twice.int()]);
    // A declaration the host has no fast path for gets none.
    try std.testing.expectEqual(ir.NativeId.none, r.func_try[other_twice.int()]);
    // A class inheriting the member dispatches to the fronted declaration.
    try std.testing.expectEqual(base_twice, fx.dispatch(try fx.cid("demo.Derived"), base_twice).?);
}
