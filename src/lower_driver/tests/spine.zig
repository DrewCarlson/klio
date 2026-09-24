//! Package C1's tests: the builder, the record lookups, receivers and
//! locals, bodies, statements and names.
//!
//! Each test resolves a program with sema, gives the symbols it lowers ids
//! in a bridge built by hand, lowers one body, and compares the IR written
//! against the expected listing.

const std = @import("std");
const span = @import("span");
const ast = @import("ast");
const lexer = @import("lexer");
const parser = @import("parser");
const sema = @import("sema");
const ir = @import("ir");

const lower = ir.lower_sema;
const bridge = ir.bridge;
const Sym = sema.Sym;
const FuncId = ir.FuncId;

/// The declarations the programs below use, in the style of the base set.
const test_base =
    \\package kotlin
    \\public open class Any
    \\public class Nothing private constructor()
    \\public object Unit
    \\public class Boolean
    \\public class Int
    \\public class String
    \\public open class Throwable
    \\public interface Function<out R>
    \\public inline fun <T, R> with(receiver: T, block: T.() -> R): R = receiver.block()
    \\public inline fun <T, R> T.let(block: (T) -> R): R = block(this)
    \\
;

const test_reflect =
    \\package kotlin.reflect
    \\public interface KProperty<out V>
    \\public interface KProperty0<out V> : KProperty<V>
    \\
;

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

const NONE = bridge.NONE;

/// A program resolved by sema, with a bridge whose ids the test assigns.
const Fx = struct {
    arena: *std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    s: *sema.Sema,
    m: *ir.Module,
    br: *bridge.Bridge,
    p: *lower.Program,
    n_funcs: u32 = 0,
    n_classes: u32 = 0,
    /// The bridge's capture lists, writable.
    captures_of: [][]const bridge.CaptureKey,
    class_captures: [][]const bridge.CaptureKey,

    const max_ids = 64;
    /// The program's file, after the two base files.
    const prog_file = 2;

    fn init(src: []const u8) !Fx {
        const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
        const a = arena.allocator();
        const map = try a.create(span.SourceMap);
        map.* = span.SourceMap.init(a);
        const s = try sema.Sema.init(a);
        try s.addFiles(&.{
            try parse(a, map, "base.kt", test_base, .base),
            try parse(a, map, "reflect.kt", test_reflect, .base),
            try parse(a, map, "main.kt", src, .program),
        });
        try s.resolveBodies(&.{.program});
        const out = try sema.output.build(s);

        const m = try a.create(ir.Module);
        m.* = ir.Module.init(a);
        const n = s.syms.count();
        const br = try a.create(bridge.Bridge);
        br.* = .{ .s = s, .m = m, .records = out.files };
        br.func_of = try filled(a, FuncId, n, FuncId.from(NONE));
        br.getter_of = try filled(a, FuncId, n, FuncId.from(NONE));
        br.setter_of = try filled(a, FuncId, n, FuncId.from(NONE));
        br.defaults_of = try filled(a, FuncId, n, FuncId.from(NONE));
        br.class_of = try filled(a, ir.ClassId, n, ir.ClassId.from(NONE));
        br.static_of = try filled(a, ir.StaticId, n, ir.StaticId.from(NONE));
        br.field_of = try filled(a, u32, n, NONE);
        br.origin = try a.alloc(bridge.FuncOrigin, max_ids);
        br.slot_of = try filled(a, ir.MethodSlotId, max_ids, ir.MethodSlotId.from(NONE));
        const captures_of = try filled(a, []const bridge.CaptureKey, max_ids, &.{});
        br.captures_of = captures_of;
        br.outer_slot = try filled(a, u32, max_ids, NONE);
        const class_captures = try filled(a, []const bridge.CaptureKey, max_ids, &.{});
        br.class_captures = class_captures;
        br.capture_base = try filled(a, u32, max_ids, NONE);
        br.cells = try std.DynamicBitSetUnmanaged.initEmpty(a, n);

        const prims = try a.create(lower.operator.PrimTable);
        prims.* = .{};
        const p = try a.create(lower.Program);
        p.* = .{ .a = a, .s = s, .br = br, .m = m, .prims = prims };
        return .{ .arena = arena, .a = a, .s = s, .m = m, .br = br, .p = p, .captures_of = captures_of, .class_captures = class_captures };
    }

    fn deinit(fx: *Fx) void {
        fx.arena.deinit();
        std.testing.allocator.destroy(fx.arena);
    }

    fn filled(a: std.mem.Allocator, comptime T: type, n: usize, v: T) ![]T {
        const out = try a.alloc(T, n);
        @memset(out, v);
        return out;
    }

    fn name(fx: *Fx, str: []const u8) sema.Name {
        return fx.s.names.lookup(str) orelse std.debug.panic("no name `{s}`", .{str});
    }

    fn class(fx: *Fx, fqn: []const u8) Sym {
        const c = fx.s.classByFqn(fqn);
        std.debug.assert(c != .none);
        return c;
    }

    /// The declaration `member` of class or package `owner`; the last one
    /// when several share the name.
    fn member(fx: *Fx, owner: Sym, member_name: []const u8) Sym {
        const index = switch (fx.s.syms.kind(owner)) {
            .class => &fx.s.syms.classInfo(owner).members,
            else => &fx.s.syms.packageInfo(owner).members,
        };
        const list = sema.Symbols.members(index, fx.name(member_name));
        std.debug.assert(list.len != 0);
        return list[list.len - 1];
    }

    fn top(fx: *Fx, member_name: []const u8) Sym {
        return fx.member(fx.s.syms.root_package, member_name);
    }

    /// A function shell for `origin`, as the bridge makes one.
    fn func(fx: *Fx, origin: bridge.FuncOrigin) !FuncId {
        const id = FuncId.from(fx.n_funcs);
        fx.n_funcs += 1;
        fx.br.origin[id.int()] = origin;
        try fx.m.funcs.append(fx.a, .{
            .id = id,
            .name = "f",
            .fqn = "f",
            .params = &.{},
            .return_ty = .{ .name = "", .nullable = true, .args = &.{} },
            .n_locals = 0,
            .blocks = &.{},
            .entry = ir.BlockId.from(0),
            .is_suspend = false,
        });
        switch (origin) {
            .decl, .lambda => |s| fx.br.func_of[s.int()] = id,
            .getter => |s| fx.br.getter_of[s.int()] = id,
            .setter => |s| fx.br.setter_of[s.int()] = id,
            else => {},
        }
        return id;
    }

    fn classId(fx: *Fx, cls: Sym) ir.ClassId {
        if (fx.br.class_of[cls.int()].int() != NONE) return fx.br.class_of[cls.int()];
        const id = ir.ClassId.from(fx.n_classes);
        fx.n_classes += 1;
        fx.br.class_of[cls.int()] = id;
        return id;
    }

    /// Lowers `f` and returns its listing, or the errors it failed with.
    fn lower_(fx: *Fx, f: FuncId) ![]const u8 {
        try lower.body.lowerBody(fx.p, f);
        if (fx.p.errors.items.len != 0) {
            var out: std.ArrayList(u8) = .empty;
            for (fx.p.errors.items) |e| try out.print(fx.a, "error: {s}\n", .{e.msg});
            return out.items;
        }
        return listing(fx.a, fx.m, &fx.m.funcs.items[f.int()]);
    }

    /// A builder over `owner`'s body, entered, for lowering one expression
    /// of a body another package owns.
    fn builderFor(fx: *Fx, owner: Sym, kind: lower.builder.BodyKind) !*lower.Builder {
        const f = try fx.func(switch (kind) {
            .getter => .{ .getter = owner },
            .setter => .{ .setter = owner },
            .lambda, .local_fun => .{ .lambda = owner },
            else => .{ .decl = owner },
        });
        const b = try fx.a.create(lower.Builder);
        b.* = try lower.Builder.init(fx.p, fx.s.syms.get(owner).file, owner, f, kind);
        try lower.env.enter(b);
        return b;
    }

    /// Finishes a builder with `v` as its return value and lists it.
    fn finishWith(fx: *Fx, b: *lower.Builder, v: ?ir.Reg) ![]const u8 {
        b.terminate(.{ .Return = v });
        try b.finish();
        return listing(fx.a, fx.m, &fx.m.funcs.items[b.func.int()]);
    }
};

/// One line per instruction and terminator, blocks headed `bN:` after the
/// first.
fn listing(a: std.mem.Allocator, m: *const ir.Module, f: *const ir.Func) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (f.blocks, 0..) |blk, i| {
        if (i != 0) try out.print(a, "b{d}:\n", .{i});
        for (blk.insts) |inst| {
            // A source position marker, for stack traces.
            if (inst == .Trace) continue;
            try out.appendSlice(a, "  ");
            switch (inst) {
                .LoadParam => |x| try out.print(a, "r{d} = param {d}", .{ x.dst.int(), x.idx }),
                .LoadCapture => |x| try out.print(a, "r{d} = capture {d}", .{ x.dst.int(), x.idx }),
                .Move => |x| try out.print(a, "r{d} = r{d}", .{ x.dst.int(), x.src.int() }),
                .Const => |x| try out.print(a, "r{d} = const {s}", .{ x.dst.int(), @tagName(m.consts.items[x.value.int()]) }),
                .MakeCell => |x| try out.print(a, "r{d} = cell r{d}", .{ x.dst.int(), x.src.int() }),
                .CellGet => |x| try out.print(a, "r{d} = get r{d}", .{ x.dst.int(), x.cell.int() }),
                .CellSet => |x| try out.print(a, "set r{d} = r{d}", .{ x.cell.int(), x.value.int() }),
                .GetFieldSlot => |x| try out.print(a, "r{d} = r{d}.#{d}", .{ x.dst.int(), x.obj.int(), x.slot }),
                .SetFieldSlot => |x| try out.print(a, "r{d}.#{d} = r{d}", .{ x.obj.int(), x.slot, x.value.int() }),
                .LoadStatic => |x| try out.print(a, "r{d} = static {d}", .{ x.dst.int(), x.static.int() }),
                .StoreStatic => |x| try out.print(a, "static {d} = r{d}", .{ x.static.int(), x.value.int() }),
                .LoadObject => |x| try out.print(a, "r{d} = object {d}", .{ x.dst.int(), x.class.int() }),
                .LateinitCheck => |x| try out.print(a, "r{d} = lateinit r{d}", .{ x.dst.int(), x.src.int() }),
                .CallStatic => |x| try out.print(a, "r{d} = call f{d}(r{d}..{d})", .{ x.dst.int(), x.func.int(), x.args.int(), x.n_args }),
                .RCallVirtual => |x| try out.print(a, "r{d} = virtual {d}(r{d}..{d})", .{ x.dst.int(), x.slot.int(), x.args.int(), x.n_args }),
                .CallInterface => |x| try out.print(a, "r{d} = interface {d}(r{d}..{d})", .{ x.dst.int(), x.slot.int(), x.args.int(), x.n_args }),
                .BinOp => |x| try out.print(a, "r{d} = r{d} {s} r{d}", .{ x.dst.int(), x.lhs.int(), @tagName(x.op), x.rhs.int() }),
                else => |x| try out.print(a, "{s}", .{@tagName(x)}),
            }
            try out.append(a, '\n');
        }
        try out.appendSlice(a, "  ");
        switch (blk.terminator) {
            .Return => |r| if (r) |v| try out.print(a, "return r{d}", .{v.int()}) else try out.appendSlice(a, "return"),
            .Goto => |t| try out.print(a, "goto b{d}", .{t.int()}),
            .Branch => |br| try out.print(a, "if r{d} b{d} else b{d}", .{ br.cond.int(), br.t.int(), br.f.int() }),
            else => |t| try out.print(a, "{s}", .{@tagName(t)}),
        }
        try out.append(a, '\n');
    }
    return out.items;
}

test "a builder reads its file's records and a node without one is unrecorded" {
    var fx = try Fx.init("fun main() {}");
    defer fx.deinit();
    try std.testing.expectEqual(@as(usize, 3), fx.br.records.len);
    const b = try fx.builderFor(fx.top("main"), .function);
    try std.testing.expectEqual(&fx.br.records[Fx.prog_file], b.recs);
    try std.testing.expectError(error.Unrecorded, b.call(ast.NodeId.from(1)));
    try std.testing.expectEqual(ast.NodeId.from(1), b.miss.?.node);
    try std.testing.expectError(error.Unrecorded, b.name(.none));
    try std.testing.expectEqual(sema.TypeId.none, b.exprType(.none));
}

test "parameters load once in the entry block; a val is its value and a var a register of its own" {
    var fx = try Fx.init(
        \\fun f(a: Int, b: Int) {
        \\    val x = a
        \\    var y = x
        \\    y = b
        \\    y = x
        \\}
    );
    defer fx.deinit();
    const f = try fx.func(.{ .decl = fx.top("f") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = r0
        \\  r2 = param 1
        \\  r1 = r2
        \\  r1 = r0
        \\  return
        \\
    , try fx.lower_(f));
}

test "an expression body returns its value" {
    var fx = try Fx.init("fun id(a: Int) = a");
    defer fx.deinit();
    const f = try fx.func(.{ .decl = fx.top("id") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  return r0
        \\
    , try fx.lower_(f));
}

test "reading a var copies it, so a later write does not change the value read" {
    var fx = try Fx.init(
        \\fun f(a: Int, b: Int): Int {
        \\    var y = a
        \\    val z = y
        \\    y = b
        \\    z
        \\}
    );
    defer fx.deinit();
    const f = try fx.func(.{ .decl = fx.top("f") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = r0
        \\  r2 = r1
        \\  r3 = param 1
        \\  r1 = r3
        \\  return
        \\
    , try fx.lower_(f));
}

test "a final member property is read and written through its field on this" {
    var fx = try Fx.init(
        \\class C(val a: Int, var b: Int) {
        \\    fun f() { b = a }
        \\}
    );
    defer fx.deinit();
    const c = fx.class("C");
    _ = fx.classId(c);
    fx.br.field_of[fx.member(c, "a").int()] = 0;
    fx.br.field_of[fx.member(c, "b").int()] = 1;
    const f = try fx.func(.{ .decl = fx.member(c, "f") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = r0.#0
        \\  r0.#1 = r1
        \\  return
        \\
    , try fx.lower_(f));
}

test "an open property is read through its getter's slot and a custom getter is called" {
    var fx = try Fx.init(
        \\abstract class D {
        \\    abstract val v: Int
        \\    val w: Int get() = v
        \\    fun g() = v
        \\    fun h() = w
        \\}
    );
    defer fx.deinit();
    const d = fx.class("D");
    _ = fx.classId(d);
    const v_get = try fx.func(.{ .getter = fx.member(d, "v") });
    fx.br.slot_of[v_get.int()] = ir.MethodSlotId.fromFunc(v_get);
    const w_get = try fx.func(.{ .getter = fx.member(d, "w") });
    const g = try fx.func(.{ .decl = fx.member(d, "g") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = r0
        \\  r2 = virtual 0(r1..1)
        \\  return r2
        \\
    , try fx.lower_(g));
    const h = try fx.func(.{ .decl = fx.member(d, "h") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = r0
        \\  r2 = call f1(r1..1)
        \\  return r2
        \\
    , try fx.lower_(h));
    _ = w_get;
}

test "a property declared in an interface is read through the interface" {
    var fx = try Fx.init(
        \\interface I { val n: Int }
        \\fun k(i: I) = i.n
    );
    defer fx.deinit();
    const i = fx.class("I");
    _ = fx.classId(i);
    const n_get = try fx.func(.{ .getter = fx.member(i, "n") });
    fx.br.slot_of[n_get.int()] = ir.MethodSlotId.fromFunc(n_get);
    const k = try fx.func(.{ .decl = fx.top("k") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = r0
        \\  r2 = interface 0(r1..1)
        \\  return r2
        \\
    , try fx.lower_(k));
}

test "a read and a write of one property resolve differently: plain read, setter write" {
    var fx = try Fx.init(
        \\class E(var q: Int) {
        \\    var r: Int = q
        \\        set(v) { field = v }
        \\    fun f() { r = r }
        \\}
    );
    defer fx.deinit();
    const e = fx.class("E");
    _ = fx.classId(e);
    const r = fx.member(e, "r");
    fx.br.field_of[fx.member(e, "q").int()] = 0;
    fx.br.field_of[r.int()] = 1;
    _ = try fx.func(.{ .getter = r });
    const r_set = try fx.func(.{ .setter = r });
    const f = try fx.func(.{ .decl = fx.member(e, "f") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = r0.#1
        \\  r2 = r0
        \\  r3 = r1
        \\  r4 = call f1(r2..2)
        \\  return
        \\
    , try fx.lower_(f));
    // The setter's `field` is the property's own slot on `this`.
    const b = try fx.builderFor(r, .setter);
    try std.testing.expectEqual(@as(?u16, 1), b.env.setter_value);
    const pd = fx.s.syms.get(r).decl.property;
    const st = pd.setter.?.body.Block.stmts[0].Assign;
    const rec = b.nameAt(st.id, st.target.Path.segments[0].span.start).?;
    try std.testing.expectEqual(sema.records.NameKind.backing_field, rec.kind);
    const v = try b.unit();
    try lower.name.write(b, &rec, null, v);
    _ = r_set;
    try std.testing.expectEqualStrings(
        \\  r0 = const Unit
        \\  r1 = param 0
        \\  r1.#1 = r0
        \\  return
        \\
    , try fx.finishWith(b, null));
}

test "a top-level lateinit property is its static, checked when read" {
    var fx = try Fx.init(
        \\lateinit var s: String
        \\fun k() = s
    );
    defer fx.deinit();
    fx.br.static_of[fx.top("s").int()] = ir.StaticId.from(3);
    const k = try fx.func(.{ .decl = fx.top("k") });
    try std.testing.expectEqualStrings(
        \\  r0 = static 3
        \\  r1 = lateinit r0
        \\  return r1
        \\
    , try fx.lower_(k));
}

test "this of an outer class is read through the inner instance's outer slot" {
    var fx = try Fx.init(
        \\class O(val x: Int) {
        \\    inner class I {
        \\        fun g() = x
        \\        fun h() = this@O
        \\    }
        \\}
    );
    defer fx.deinit();
    const o = fx.class("O");
    const i = fx.class("O.I");
    _ = fx.classId(o);
    const ic = fx.classId(i);
    fx.br.outer_slot[ic.int()] = 0;
    fx.br.field_of[fx.member(o, "x").int()] = 0;
    const g = try fx.func(.{ .decl = fx.member(i, "g") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = r0.#0
        \\  r2 = r1.#0
        \\  return r2
        \\
    , try fx.lower_(g));
    const h = try fx.func(.{ .decl = fx.member(i, "h") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = r0.#0
        \\  return r1
        \\
    , try fx.lower_(h));
}

test "an extension receiver is its function's parameter after the contexts" {
    var fx = try Fx.init(
        \\class P(val x: Int)
        \\fun P.ext(y: Int) = this
        \\fun P.ext2() = x
    );
    defer fx.deinit();
    const p = fx.class("P");
    _ = fx.classId(p);
    fx.br.field_of[fx.member(p, "x").int()] = 0;
    const ext = try fx.func(.{ .decl = fx.top("ext") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  return r0
        \\
    , try fx.lower_(ext));
    const ext2 = try fx.func(.{ .decl = fx.top("ext2") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = r0.#0
        \\  return r1
        \\
    , try fx.lower_(ext2));
}

test "an object and its members, an enum entry and a companion constant" {
    var fx = try Fx.init(
        \\object Obj { lateinit var z: String }
        \\enum class Color { RED }
        \\class K { companion object { lateinit var c: String } }
        \\fun q() = Obj.z
        \\fun r() = Color.RED
        \\fun t() = K.c
        \\fun u() = Obj
    );
    defer fx.deinit();
    const obj = fx.class("Obj");
    try std.testing.expectEqual(@as(u32, 0), fx.classId(obj).int());
    fx.br.field_of[fx.member(obj, "z").int()] = 2;
    const color = fx.class("Color");
    fx.br.static_of[fx.member(color, "RED").int()] = ir.StaticId.from(7);
    const comp = fx.class("K.Companion");
    try std.testing.expectEqual(@as(u32, 1), fx.classId(comp).int());
    fx.br.field_of[fx.member(comp, "c").int()] = 0;
    const q = try fx.func(.{ .decl = fx.top("q") });
    try std.testing.expectEqualStrings(
        \\  r0 = object 0
        \\  r1 = r0.#2
        \\  r2 = lateinit r1
        \\  return r2
        \\
    , try fx.lower_(q));
    const r = try fx.func(.{ .decl = fx.top("r") });
    try std.testing.expectEqualStrings(
        \\  r0 = static 7
        \\  return r0
        \\
    , try fx.lower_(r));
    const t = try fx.func(.{ .decl = fx.top("t") });
    try std.testing.expectEqualStrings(
        \\  r0 = object 1
        \\  r1 = r0.#0
        \\  r2 = lateinit r1
        \\  return r2
        \\
    , try fx.lower_(t));
    const u = try fx.func(.{ .decl = fx.top("u") });
    try std.testing.expectEqualStrings(
        \\  r0 = object 0
        \\  return r0
        \\
    , try fx.lower_(u));
}

test "a member of an object reads its own this as parameter 0" {
    var fx = try Fx.init(
        \\object Obj {
        \\    lateinit var z: String
        \\    fun g() = z
        \\}
    );
    defer fx.deinit();
    const obj = fx.class("Obj");
    _ = fx.classId(obj);
    fx.br.field_of[fx.member(obj, "z").int()] = 0;
    const g = try fx.func(.{ .decl = fx.member(obj, "g") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = r0.#0
        \\  r2 = lateinit r1
        \\  return r2
        \\
    , try fx.lower_(g));
}

test "a safe member read is null when its receiver is" {
    var fx = try Fx.init(
        \\class P(val x: Int)
        \\fun sf(p: P?) = p?.x
    );
    defer fx.deinit();
    const p = fx.class("P");
    _ = fx.classId(p);
    fx.br.field_of[fx.member(p, "x").int()] = 0;
    const sf = try fx.func(.{ .decl = fx.top("sf") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = const Null
        \\  r2 = r0 IdentEq r1
        \\  if r2 b1 else b2
        \\b1:
        \\  r3 = r1
        \\  goto b3
        \\b2:
        \\  r4 = r0.#0
        \\  r3 = r4
        \\  goto b3
        \\b3:
        \\  return r3
        \\
    , try fx.lower_(sf));
}

test "a captured var lives in a cell the closure reads and writes" {
    var fx = try Fx.init(
        \\fun m(a: Int) {
        \\    var c = a
        \\    val f = { c = c }
        \\}
    );
    defer fx.deinit();
    const m_sym = fx.top("m");
    const c = findLocal(&fx, m_sym, "c");
    fx.br.cells.set(c.int());
    // The enclosing body makes the cell and hands the cell itself over.
    const b = try fx.builderFor(m_sym, .function);
    const pd = fx.s.syms.get(m_sym).decl.function;
    try lower.body.lowerStmt(b, &pd.body.?.Block.stmts[0]);
    const caps = try lower.env.materializeCaptures(b, &.{.{ .local = c }});
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = cell r0
        \\  return r1
        \\
    , try fx.finishWith(b, caps[0]));

    // The lambda reads and writes through its captured cell.
    const lam = pd.body.?.Block.stmts[1].Decl.Property.init.?.Lambda;
    const rec = try b.lambda(lam.id);
    const lf = try fx.func(.{ .lambda = rec.func });
    fx.captures_of[lf.int()] = &.{.{ .local = c }};
    var lb = try lower.Builder.init(fx.p, Fx.prog_file, rec.func, lf, .lambda);
    try lower.env.enter(&lb);
    _ = try lower.body.lowerStmts(&lb, lam.body.stmts);
    try std.testing.expectEqualStrings(
        \\  r0 = capture 0
        \\  r1 = get r0
        \\  set r0 = r1
        \\  return
        \\
    , try fx.finishWith(&lb, null));
}

test "a lambda's receiver and parameters are its closure's parameters" {
    var fx = try Fx.init(
        \\class P(val x: Int)
        \\fun w(p: P) = with(p) { x }
        \\fun l(p: P) = p.let { q -> q.x }
    );
    defer fx.deinit();
    const p = fx.class("P");
    _ = fx.classId(p);
    fx.br.field_of[fx.member(p, "x").int()] = 0;
    inline for (.{ "w", "l" }) |fname| {
        const fd = fx.s.syms.get(fx.top(fname)).decl.function;
        const call = fd.body.?.Expr.Call;
        const lam = call.args[call.args.len - 1].Lambda;
        const b0 = try fx.builderFor(fx.top(fname), .function);
        const rec = try b0.lambda(lam.id);
        const lf = try fx.func(.{ .lambda = rec.func });
        var lb = try lower.Builder.init(fx.p, Fx.prog_file, rec.func, lf, .lambda);
        try lower.env.enter(&lb);
        const v = try lower.body.lowerBlock(&lb, &lam.body);
        try std.testing.expectEqualStrings(
            \\  r0 = param 0
            \\  r1 = r0.#0
            \\  return r1
            \\
        , try fx.finishWith(&lb, v));
    }
}

test "a member of a local class reads a captured value from its slot" {
    var fx = try Fx.init(
        \\fun lc(a: Int) {
        \\    class L { fun g() = a }
        \\}
    );
    defer fx.deinit();
    const lc = fx.top("lc");
    const a = fx.s.syms.functionInfo(lc).params[0];
    const l = localClass(&fx, lc, "L");
    const lcid = fx.classId(l);
    fx.class_captures[lcid.int()] = &.{.{ .local = a }};
    fx.br.capture_base[lcid.int()] = 2;
    const g = try fx.func(.{ .decl = fx.member(l, "g") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = r0.#2
        \\  return r1
        \\
    , try fx.lower_(g));
}

test "a closure reads a captured this, and a local function takes its captures first" {
    var fx = try Fx.init(
        \\class C(val a: Int) {
        \\    fun f() = { a }
        \\}
        \\fun g(p: Int, q: Int) {
        \\    fun loc(r: Int) = p
        \\}
    );
    defer fx.deinit();
    const c = fx.class("C");
    _ = fx.classId(c);
    fx.br.field_of[fx.member(c, "a").int()] = 0;
    const fd = fx.s.syms.get(fx.member(c, "f")).decl.function;
    const lam = fd.body.?.Expr.Lambda;
    const b0 = try fx.builderFor(fx.member(c, "f"), .function);
    const rec = try b0.lambda(lam.id);
    const lf = try fx.func(.{ .lambda = rec.func });
    fx.captures_of[lf.int()] = &.{.{ .receiver = .{ .kind = .class_this, .owner = c } }};
    // The enclosing member hands over its `this`.
    const caps = try lower.env.materializeCaptures(b0, fx.captures_of[lf.int()]);
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  return r0
        \\
    , try fx.finishWith(b0, caps[0]));
    var lb = try lower.Builder.init(fx.p, Fx.prog_file, rec.func, lf, .lambda);
    try lower.env.enter(&lb);
    const v = (try lower.body.lowerStmts(&lb, lam.body.stmts)).?;
    try std.testing.expectEqualStrings(
        \\  r0 = capture 0
        \\  r1 = r0.#0
        \\  return r1
        \\
    , try fx.finishWith(&lb, v));

    const g = fx.top("g");
    const p = fx.s.syms.functionInfo(g).params[0];
    const loc_decl = fx.s.syms.get(g).decl.function.body.?.Block.stmts[0].Decl;
    var bg = try lower.Builder.init(fx.p, Fx.prog_file, g, try fx.func(.{ .decl = g }), .function);
    const loc = try bg.decl(loc_decl.Function.id);
    const lfn = try fx.func(.{ .lambda = loc });
    fx.captures_of[lfn.int()] = &.{.{ .local = p }};
    var lb2 = try lower.Builder.init(fx.p, Fx.prog_file, loc, lfn, .local_fun);
    try lower.env.enter(&lb2);
    try lower.body.lowerFunctionBody(&lb2, &loc_decl.Function.body.?);
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  return r0
        \\
    , try fx.finishWith(&lb2, null));
    try std.testing.expectEqual(@as(u16, 1), lb2.env.values_at);
}

test "a constructor takes this, the outer instance, and its parameters after them" {
    var fx = try Fx.init(
        \\class O(val x: Int) {
        \\    inner class I(z: Int) {
        \\        val y = x
        \\        val w = z
        \\    }
        \\}
        \\enum class E(v: Int) {
        \\    A(v = 1);
        \\    val u = v
        \\}
    );
    defer fx.deinit();
    const o = fx.class("O");
    const i = fx.class("O.I");
    _ = fx.classId(o);
    _ = fx.classId(i);
    fx.br.field_of[fx.member(o, "x").int()] = 0;
    const ctor = fx.s.syms.classInfo(i).primary_ctor;
    const b = try fx.builderFor(ctor, .ctor);
    const y = fx.s.syms.get(fx.member(i, "y")).decl.property;
    const w = fx.s.syms.get(fx.member(i, "w")).decl.property;
    const vy = try lower.body.lowerExpr(b, y.init.?);
    const vw = try lower.body.lowerExpr(b, w.init.?);
    try std.testing.expectEqualStrings(
        \\  r0 = param 1
        \\  r1 = r0.#0
        \\  r2 = param 2
        \\  r3 = r1
        \\  return r2
        \\
    , try fx.finishWith(b, blk: {
        try b.emit(.{ .Move = .{ .dst = b.newReg(), .src = vy } });
        break :blk vw;
    }));

    const e = fx.class("E");
    _ = fx.classId(e);
    const eb = try fx.builderFor(fx.s.syms.classInfo(e).primary_ctor, .ctor);
    const u = fx.s.syms.get(fx.member(e, "u")).decl.property;
    const vu = try lower.body.lowerExpr(eb, u.init.?);
    try std.testing.expectEqualStrings(
        \\  r0 = param 3
        \\  return r0
        \\
    , try fx.finishWith(eb, vu));
}

test "a context parameter, a super read, an extension property and a top-level getter" {
    var fx = try Fx.init(
        \\class Ctx(val n: Int)
        \\context(c: Ctx) fun cf(a: Int) = c.n
        \\open class B(open val v: Int)
        \\class D(q: Int) : B(q) {
        \\    override val v: Int get() = super.v
        \\}
        \\class P(val x: Int)
        \\val P.px: Int get() = x
        \\fun ep(p: P) = p.px
        \\lateinit var s: String
        \\val tp: String get() = s
        \\fun tg() = tp
    );
    defer fx.deinit();
    const ctx = fx.class("Ctx");
    _ = fx.classId(ctx);
    fx.br.field_of[fx.member(ctx, "n").int()] = 0;
    const cf = try fx.func(.{ .decl = fx.top("cf") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = r0.#0
        \\  return r1
        \\
    , try fx.lower_(cf));

    const bcls = fx.class("B");
    _ = fx.classId(bcls);
    _ = fx.classId(fx.class("D"));
    fx.br.field_of[fx.member(bcls, "v").int()] = 0;
    const dv = fx.member(fx.class("D"), "v");
    const gb = try fx.builderFor(dv, .getter);
    const getter_body = &fx.s.syms.get(dv).decl.property.getter.?.body.Expr;
    const sv = try lower.body.lowerExpr(gb, getter_body);
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = r0.#0
        \\  return r1
        \\
    , try fx.finishWith(gb, sv));

    const p = fx.class("P");
    _ = fx.classId(p);
    const px_get = try fx.func(.{ .getter = fx.top("px") });
    const ep = try fx.func(.{ .decl = fx.top("ep") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = r0
        \\  r2 = call f2(r1..1)
        \\  return r2
        \\
    , try fx.lower_(ep));
    try std.testing.expectEqual(@as(u32, 2), px_get.int());

    const tp_get = try fx.func(.{ .getter = fx.top("tp") });
    const tg = try fx.func(.{ .decl = fx.top("tg") });
    try std.testing.expectEqualStrings(
        \\  r0 = call f4(r0..0)
        \\  return r0
        \\
    , try fx.lower_(tg));
    try std.testing.expectEqual(@as(u32, 4), tp_get.int());
}

test "templates name a value or this; assignments through paths, members and a safe receiver" {
    var fx = try Fx.init(
        \\object Obj { lateinit var z: String }
        \\class P(var x: Int) {
        \\    fun t(a: Int) = "$a $this"
        \\}
        \\fun w(s: String, p: P?, a: Int) {
        \\    Obj.z = s
        \\    p?.x = a
        \\}
    );
    defer fx.deinit();
    const obj = fx.class("Obj");
    _ = fx.classId(obj);
    fx.br.field_of[fx.member(obj, "z").int()] = 0;
    const p = fx.class("P");
    _ = fx.classId(p);
    fx.br.field_of[fx.member(p, "x").int()] = 0;

    const t = fx.member(p, "t");
    const tb = try fx.builderFor(t, .function);
    const parts = fx.s.syms.get(t).decl.function.body.?.Expr.StringTemplate.parts;
    const va = try lower.name.lowerTemplateName(tb, &parts[0].ShortInterp);
    const vt = try lower.name.lowerTemplateName(tb, &parts[2].ShortInterp);
    try std.testing.expectEqualStrings(
        \\  r0 = param 1
        \\  r1 = param 0
        \\  r2 = r0
        \\  return r1
        \\
    , try fx.finishWith(tb, blk: {
        try tb.emit(.{ .Move = .{ .dst = tb.newReg(), .src = va } });
        break :blk vt;
    }));

    const w = try fx.func(.{ .decl = fx.top("w") });
    try std.testing.expectEqualStrings(
        \\  r0 = object 0
        \\  r1 = param 0
        \\  r0.#0 = r1
        \\  r2 = param 1
        \\  r3 = const Null
        \\  r4 = r2 IdentEq r3
        \\  r5 = param 2
        \\  if r4 b1 else b2
        \\b1:
        \\  goto b3
        \\b2:
        \\  r2.#0 = r5
        \\  goto b3
        \\b3:
        \\  return
        \\
    , try fx.lower_(w));
}

test "a local declared without a value holds null until assigned, and a lateinit local is checked" {
    var fx = try Fx.init(
        \\fun f(a: Int, s: String): String {
        \\    val x: Int
        \\    x = a
        \\    lateinit var t: String
        \\    t = s
        \\    t
        \\}
    );
    defer fx.deinit();
    const f = try fx.func(.{ .decl = fx.top("f") });
    try std.testing.expectEqualStrings(
        \\  r0 = const Null
        \\  r1 = r0
        \\  r2 = param 0
        \\  r1 = r2
        \\  r3 = r0
        \\  r4 = param 1
        \\  r3 = r4
        \\  r5 = r3
        \\  r6 = lateinit r5
        \\  return
        \\
    , try fx.lower_(f));
}

test "a member extension called in a with block takes the block's receiver as its dispatch receiver" {
    var fx = try Fx.init(
        \\class P(val x: Int) { fun Int.scaled() = x }
        \\fun w(p: P, n: Int) = with(p) { n.scaled() }
    );
    defer fx.deinit();
    const p = fx.class("P");
    _ = fx.classId(p);
    const scaled = try fx.func(.{ .decl = fx.member(p, "scaled") });
    const fd = fx.s.syms.get(fx.top("w")).decl.function;
    const call = fd.body.?.Expr.Call;
    const lam = call.args[call.args.len - 1].Lambda;
    const b0 = try fx.builderFor(fx.top("w"), .function);
    const rec = try b0.lambda(lam.id);
    const lf = try fx.func(.{ .lambda = rec.func });
    // `n` is the enclosing function's parameter, captured.
    const n = fx.s.syms.functionInfo(fx.top("w")).params[1];
    fx.captures_of[lf.int()] = &.{.{ .local = n }};
    var lb = try lower.Builder.init(fx.p, Fx.prog_file, rec.func, lf, .lambda);
    try lower.env.enter(&lb);
    const v = (try lower.body.lowerStmts(&lb, lam.body.stmts)).?;
    try std.testing.expectEqualStrings(
        \\  r0 = capture 0
        \\  r1 = param 0
        \\  r2 = r1
        \\  r3 = r0
        \\  r4 = call f0(r2..2)
        \\  return r4
        \\
    , try fx.finishWith(&lb, v));
    try std.testing.expectEqual(@as(u32, 0), scaled.int());
}

test "destructuring binds each entry's componentN; a delegated local reads through getValue" {
    var fx = try Fx.init(
        \\data class Pt(val x: Int, val y: Int)
        \\fun d(p: Pt) {
        \\    val (a, _) = p
        \\    val b = a
        \\}
        \\class D(val v: Int) {
        \\    operator fun getValue(t: Any?, p: kotlin.reflect.KProperty<*>): Int = v
        \\}
        \\fun dl(del: D) {
        \\    val x by del
        \\    val y = x
        \\}
    );
    defer fx.deinit();
    const pt = fx.class("Pt");
    _ = fx.classId(pt);
    const c1 = try fx.func(.{ .decl = fx.member(pt, "component1") });
    const d = try fx.func(.{ .decl = fx.top("d") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = r0
        \\  r2 = call f0(r1..1)
        \\  return
        \\
    , try fx.lower_(d));
    try std.testing.expectEqual(@as(u32, 0), c1.int());

    _ = fx.classId(fx.class("D"));
    const gv = try fx.func(.{ .decl = fx.member(fx.class("D"), "getValue") });
    const dl = try fx.func(.{ .decl = fx.top("dl") });
    try std.testing.expectEqualStrings(
        \\  r0 = param 0
        \\  r1 = const Null
        \\  RPropertyRef
        \\  r3 = r0
        \\  r4 = r1
        \\  r5 = r2
        \\  r6 = call f2(r3..3)
        \\  return
        \\
    , try fx.lower_(dl));
    try std.testing.expectEqual(@as(u32, 2), gv.int());
}

test "a reified type parameter's value is a local loaded after the value parameters" {
    var fx = try Fx.init(
        \\class Box(val v: Int) {
        \\    inline fun <reified T, U> has(x: Any?, u: U) = x
        \\}
    );
    defer fx.deinit();
    const has = fx.member(fx.class("Box"), "has");
    const b = try fx.builderFor(has, .function);
    const tps = fx.s.syms.functionInfo(has).type_params;
    try std.testing.expect(b.locals.get(tps[1]) == null);
    const home = b.locals.get(tps[0]).?;
    try std.testing.expectEqualStrings(
        \\  r0 = param 3
        \\  return r0
        \\
    , try fx.finishWith(b, home.reg));
}

test "a node without its record fails the body naming it" {
    var fx = try Fx.init("fun bad() = nope");
    defer fx.deinit();
    const f = try fx.func(.{ .decl = fx.top("bad") });
    const got = try fx.lower_(f);
    try std.testing.expect(std.mem.startsWith(u8, got, "error: node "));
    try std.testing.expect(std.mem.endsWith(u8, got, "has no name record\n"));
    try std.testing.expect(f.int() >= fx.p.lowered.bit_length or !fx.p.lowered.isSet(f.int()));
    try std.testing.expectEqual(@as(usize, 0), fx.m.funcs.items[f.int()].blocks.len);
}

test "statements after a return are not lowered and a dead block ends unreachable" {
    var fx = try Fx.init("fun f(a: Int) {}");
    defer fx.deinit();
    const b = try fx.builderFor(fx.top("f"), .function);
    b.terminate(.{ .Return = null });
    // Code emitted after a terminator goes to a block nothing reaches, and
    // the terminator stays.
    const v = try b.emitConst(.Unit);
    b.terminate(.{ .Return = v });
    try b.finish();
    try std.testing.expectEqualStrings(
        \\  return
        \\b1:
        \\  r0 = const Unit
        \\  return r0
        \\
    , try listing(fx.a, fx.m, &fx.m.funcs.items[b.func.int()]));
}

/// The local named `n` declared in `owner`'s body.
fn findLocal(fx: *Fx, owner: Sym, n: []const u8) Sym {
    const want = fx.name(n);
    for (1..fx.s.syms.count()) |i| {
        const s = Sym.from(@intCast(i));
        if (fx.s.syms.kind(s) == .local and fx.s.syms.owner(s) == owner and fx.s.syms.name(s) == want) return s;
    }
    std.debug.panic("no local `{s}`", .{n});
}

/// The local class named `n` declared in `owner`'s body.
fn localClass(fx: *Fx, owner: Sym, n: []const u8) Sym {
    const want = fx.name(n);
    for (1..fx.s.syms.count()) |i| {
        const s = Sym.from(@intCast(i));
        if (fx.s.syms.kind(s) == .class and fx.s.syms.owner(s) == owner and fx.s.syms.name(s) == want) return s;
    }
    std.debug.panic("no local class `{s}`", .{n});
}

// ---------------------------------------------------------- executing ----
//
// Programs run through parse, sema, the bridge, this lowering and the VM
// over the executable base. The expected output is what kotlinc prints.

const driver = @import("../lower_driver.zig");

/// Runs `src` and expects exactly `want`; skipped while the driver is not
/// built.
fn expectRun(src: []const u8, want: []const u8) !void {
    driver.expectOutput(&.{src}, want) catch |err| {
        if (err == error.Unsupported) return error.SkipZigTest;
        return err;
    };
}

test "hello world" {
    try expectRun(
        \\fun main() { println("hi") }
    , "hi\n");
}

test "locals, reassignment and parameters" {
    try expectRun(
        \\fun add(a: Int, b: Int): Int {
        \\    val sum = a + b
        \\    var acc = sum
        \\    acc = acc * 2
        \\    return acc
        \\}
        \\fun main() {
        \\    var x = 1
        \\    val y = x
        \\    x = 5
        \\    println(y)
        \\    println(x)
        \\    println(add(2, 3))
        \\    val z: Int
        \\    if (x > 2) z = 1 else z = 2
        \\    println(z)
        \\}
    , "1\n5\n10\n1\n");
}

test "a top-level property read before its initializer runs holds its seed" {
    try expectRun(
        \\val a: Int = b + 1
        \\val b: Int = 10
        \\var c = 0
        \\fun main() {
        \\    println(a)
        \\    println(b)
        \\    c = c + 2
        \\    println(c)
        \\}
    , "1\n10\n2\n");
}

test "member properties through their field, a getter, and a setter using field" {
    try expectRun(
        \\class Box(val w: Int, var h: Int) {
        \\    val area: Int get() = w * h
        \\    var label: String = "box"
        \\        set(v) { field = "[" + v + "]" }
        \\    var reads = 0
        \\    val counted: Int = 5
        \\        get() { reads = reads + 1; return field }
        \\}
        \\fun main() {
        \\    val b = Box(2, 3)
        \\    println(b.area)
        \\    b.h = 5
        \\    println(b.area)
        \\    println(b.label)
        \\    b.label = "big"
        \\    println(b.label)
        \\    println(b.counted + b.counted)
        \\    println(b.reads)
        \\}
    , "6\n10\nbox\n[big]\n10\n2\n");
}

test "an explicit backing field's initializer fills a top-level and a member property" {
    try expectRun(
        \\val history: List<String>
        \\    field = mutableListOf<String>()
        \\class Meter {
        \\    val reading: Number
        \\        field: Int = 40
        \\    fun bump(): Int = reading + 2
        \\}
        \\fun main() {
        \\    history.add("a")
        \\    history.add("b")
        \\    println(history.size)
        \\    println(Meter().bump())
        \\}
    , "2\n42\n");
}

test "the nearest class declaring a property decides whether its field or a getter answers" {
    try expectRun(
        \\open class Base { open val name: String get() = "base" }
        \\class Derived : Base() { override val name: String = "derived" }
        \\open class Tagged(open val label: String)
        \\class Counted(label: String, val n: Int) : Tagged(label) {
        \\    override val label: String get() = "counted " + n
        \\}
        \\fun show(b: Base) = println(b.name)
        \\fun main() {
        \\    show(Base())
        \\    show(Derived())
        \\    val t: Tagged = Counted("x", 3)
        \\    println(t.label)
        \\    println(Tagged("y").label)
        \\}
    , "base\nderived\ncounted 3\ny\n");
}

test "extension receivers of functions and properties" {
    try expectRun(
        \\class P(val x: Int)
        \\fun P.twice() = x * 2
        \\val P.half: Int get() = x / 2
        \\fun Int.scaled() = this * 10
        \\fun main() {
        \\    val p = P(8)
        \\    println(p.twice())
        \\    println(p.half)
        \\    println(3.scaled())
        \\}
    , "16\n4\n30\n");
}

test "this@Outer in an inner class" {
    try expectRun(
        \\class Outer(val name: String) {
        \\    inner class Inner(val n: Int) {
        \\        fun show() = this@Outer.name + " " + n + " " + name
        \\    }
        \\}
        \\fun main() { println(Outer("o").Inner(1).show()) }
    , "o 1 o\n");
}

test "implicit receivers from with, a let parameter, and a member extension on the with subject" {
    try expectRun(
        \\class P(val x: Int) { fun Int.scaled() = this * x }
        \\fun main() {
        \\    val p = P(3)
        \\    println(with(p) { x + 1 })
        \\    println(p.let { q -> q.x * 2 })
        \\    println(with(p) { 5.scaled() })
        \\}
    , "4\n6\n15\n");
}

test "a captured var is mutated by lambdas" {
    try expectRun(
        \\fun twice(f: () -> Unit) { f(); f() }
        \\fun main() {
        \\    var count = 0
        \\    twice { count = count + 1 }
        \\    val inc = { count = count + 10 }
        \\    inc()
        \\    println(count)
        \\}
    , "12\n");
}

test "objects, a companion constant and enum entries" {
    try expectRun(
        \\object Counter {
        \\    var n = 0
        \\    fun bump() { n = n + 1 }
        \\}
        \\class Color(val rgb: Int) {
        \\    companion object { val Unspecified = Color(-1) }
        \\}
        \\enum class Dir { N, S }
        \\fun main() {
        \\    Counter.bump()
        \\    Counter.bump()
        \\    println(Counter.n)
        \\    println(Color.Unspecified.rgb)
        \\    println(Dir.S.name)
        \\}
    , "2\n-1\nS\n");
}

test "destructuring by componentN, skipping an underscore" {
    try expectRun(
        \\data class Pt(val x: Int, val y: Int)
        \\fun main() {
        \\    val (a, b) = Pt(1, 2)
        \\    println(a + b)
        \\    val (_, c) = Pt(3, 4)
        \\    println(c)
        \\    val (k, v) = 1 to "one"
        \\    println(v + k)
        \\}
    , "3\n4\none1\n");
}

test "a delegated local reads through its delegate" {
    try expectRun(
        \\fun main() {
        \\    val v by lazy { println("init"); 42 }
        \\    println("before")
        \\    println(v)
        \\    println(v)
        \\}
    , "before\ninit\n42\n42\n");
}

test "lateinit properties and safe member access" {
    try expectRun(
        \\class L { lateinit var s: String }
        \\class N(var v: Int)
        \\fun main() {
        \\    val l = L()
        \\    try { println(l.s) } catch (e: UninitializedPropertyAccessException) { println("uninit") }
        \\    l.s = "set"
        \\    println(l.s)
        \\    var n: N? = null
        \\    println(n?.v)
        \\    n?.v = 5
        \\    n = N(1)
        \\    n?.v = 7
        \\    println(n?.v)
        \\}
    , "uninit\nset\nnull\n7\n");
}

test "an increment or compound assignment through a safe receiver does nothing past null" {
    try expectRun(
        \\class Node(val parent: Node?) {
        \\    var count: Int = 0
        \\        set(value) {
        \\            if (field != value) {
        \\                if (value > 0 && field == 0) parent?.count++
        \\                if (value == 0 && field > 0) parent?.count--
        \\                field = value
        \\            }
        \\        }
        \\    var plain = 0
        \\}
        \\var reads = 0
        \\fun find(n: Node?): Node? { reads = reads + 1; return n }
        \\fun main() {
        \\    val root = Node(null)
        \\    val leaf = Node(Node(root))
        \\    leaf.count++
        \\    println(root.count)
        \\    leaf.count--
        \\    println(root.count)
        \\    var none: Node? = null
        \\    println(none?.plain++)
        \\    println(++none?.plain)
        \\    none?.plain += 2
        \\    println(find(root)?.plain++)
        \\    println(--find(root)?.plain)
        \\    find(root)?.plain += 5
        \\    find(null)?.plain -= 5
        \\    println(root.plain)
        \\    println(reads)
        \\}
    , "1\n0\nnull\nnull\n0\n0\n5\n4\n");
}

test "a local class reads a value it captured" {
    try expectRun(
        \\fun main() {
        \\    val base = 10
        \\    class Adder(val n: Int) { fun sum() = base + n }
        \\    println(Adder(5).sum())
        \\}
    , "15\n");
}

test "closures, local functions and nested inner classes reach what they captured" {
    try expectRun(
        \\class Counter(val start: Int) {
        \\    var n = start
        \\    fun adder(): () -> Int = { n = n + 1; n }
        \\    inner class View(val label: String) {
        \\        inner class Deep { fun show() = label + ":" + n }
        \\    }
        \\}
        \\fun outerFun(p: Int): Int {
        \\    var acc = p
        \\    fun add(k: Int) { acc = acc + k + p }
        \\    add(1)
        \\    add(2)
        \\    return acc
        \\}
        \\fun main() {
        \\    val c = Counter(5)
        \\    val f = c.adder()
        \\    println(f())
        \\    println(f())
        \\    println(c.View("v").Deep().show())
        \\    println(outerFun(10))
        \\}
    , "6\n7\nv:7\n33\n");
}

test "super property reads, this in a template, a setter using field in an object, a local lateinit" {
    try expectRun(
        \\open class B { open val v: Int get() = 1 }
        \\class D : B() { override val v: Int get() = super.v + 10 }
        \\class W(val v: Int) {
        \\    override fun toString() = "W" + v
        \\    fun me() = "<$this>"
        \\}
        \\object Store {
        \\    var hits = 0
        \\    var value: Int = 0
        \\        set(x) { hits = hits + 1; field = x }
        \\}
        \\fun late(): String {
        \\    lateinit var s: String
        \\    s = "ok"
        \\    return s
        \\}
        \\fun main() {
        \\    println(D().v)
        \\    println(W(3).me())
        \\    Store.value = 4
        \\    Store.value = 5
        \\    println(Store.value)
        \\    println(Store.hits)
        \\    println(late())
        \\}
    , "11\n<W3>\n5\n2\nok\n");
}
