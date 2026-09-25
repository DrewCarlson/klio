//! Package C4's tests: construction, statics, objects, enums, data
//! classes, delegation, lambdas, local functions and callable references.
//!
//! The first tests lower programs over the miniature base and check the
//! instructions a body gets; the rest run programs end to end and are
//! skipped while the VM's arms are not built. Every expected output is what
//! kotlinc 2.4.20 prints for the same program.

const std = @import("std");
const sema = @import("sema");
const ir = @import("ir");

const driver = @import("../lower_driver.zig");

const lower = ir.lower_sema;
const Sym = sema.Sym;
const FuncId = ir.FuncId;
const testing = std.testing;

/// A program analyzed and lowered over the miniature base.
const Fx = struct {
    arena: *std.heap.ArenaAllocator,
    an: driver.Analysis,
    prog: lower.Program,

    fn init(src: []const u8) !Fx {
        const arena = try testing.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer {
            arena.deinit();
            testing.allocator.destroy(arena);
        }
        const al = arena.allocator();
        const an = try driver.analyze(al, &.{src});
        const census = try an.census(al, .program);
        if (census.len != 0) {
            std.debug.print("unresolved:\n{s}", .{census});
            return error.TestUnexpectedResult;
        }
        const prog = try lower.lowerProgram(al, an.s, an.br);
        return .{ .arena = arena, .an = an, .prog = prog };
    }

    fn deinit(self: *Fx) void {
        self.arena.deinit();
        testing.allocator.destroy(self.arena);
    }

    fn a(self: *const Fx) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Each lowering error in `files`, one per line, with the function it
    /// is in.
    fn errors(self: *const Fx, program_only: bool) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const s = self.an.s;
        for (self.prog.errors.items) |le| {
            const f = &self.an.br.m.funcs.items[le.func.int()];
            if (program_only) {
                const sym: Sym = switch (self.an.br.origin[le.func.int()]) {
                    .decl, .getter, .setter, .defaults, .lambda, .sam_ctor, .sam_method, .abstract, .restart => |x| x,
                    else => .none,
                };
                if (sym != .none) {
                    const file = s.syms.get(sym).file;
                    if (file < s.files.items.len and s.files.items[file].origin != .program) continue;
                }
            }
            try out.print(self.a(), "{s}: {s}\n", .{ f.fqn, le.msg });
        }
        return out.items;
    }

    fn expectNoErrors(self: *const Fx) !void {
        const e = try self.errors(false);
        if (e.len != 0) std.debug.print("lowering errors:\n{s}", .{e});
        try testing.expectEqualStrings("", e);
    }

    fn class(self: *const Fx, fqn: []const u8) !Sym {
        const c = self.an.s.classByFqn(fqn);
        if (c == .none) {
            std.debug.print("no class {s}\n", .{fqn});
            return error.TestUnexpectedResult;
        }
        return c;
    }

    fn member(self: *const Fx, cls: Sym, name: []const u8) !Sym {
        const s = self.an.s;
        if (s.names.lookup(name)) |n| {
            for (sema.symbols.Symbols.members(&s.syms.classInfo(cls).members, n)) |m| {
                if (s.syms.owner(m) == cls) return m;
            }
        }
        std.debug.print("no member {s}\n", .{name});
        return error.TestUnexpectedResult;
    }

    /// The top-level function `name` of the program.
    fn topLevel(self: *const Fx, name: []const u8) !Sym {
        const s = self.an.s;
        var i: u32 = 1;
        while (i < s.syms.count()) : (i += 1) {
            const sym = Sym.from(i);
            if (s.syms.kind(sym) != .function) continue;
            const owner = s.syms.owner(sym);
            if (owner == .none or s.syms.kind(owner) != .package) continue;
            const f = s.syms.get(sym).file;
            if (f >= s.files.items.len or s.files.items[f].origin != .program) continue;
            if (std.mem.eql(u8, s.str(s.syms.name(sym)), name)) return sym;
        }
        std.debug.print("no function {s}\n", .{name});
        return error.TestUnexpectedResult;
    }

    fn ctorOf(self: *const Fx, fqn: []const u8) !FuncId {
        const c = try self.class(fqn);
        return self.an.br.funcOf(self.an.s.syms.classInfo(c).primary_ctor);
    }

    fn listing(self: *const Fx, f: FuncId) ![]const u8 {
        return list(self.a(), self.an.br.m, &self.an.br.m.funcs.items[f.int()]);
    }

    /// Whether `f`'s body holds an instruction of `tag`.
    fn has(self: *const Fx, f: FuncId, tag: std.meta.Tag(ir.Inst)) bool {
        for (self.an.br.m.funcs.items[f.int()].blocks) |blk| {
            for (blk.insts) |inst| if (std.meta.activeTag(inst) == tag) return true;
        }
        return false;
    }

    fn count(self: *const Fx, f: FuncId, tag: std.meta.Tag(ir.Inst)) usize {
        var n: usize = 0;
        for (self.an.br.m.funcs.items[f.int()].blocks) |blk| {
            for (blk.insts) |inst| {
                if (std.meta.activeTag(inst) == tag) n += 1;
            }
        }
        return n;
    }
};

/// One line per instruction and terminator, blocks headed `bN:` after the
/// first.
fn list(a: std.mem.Allocator, m: *const ir.Module, f: *const ir.Func) ![]const u8 {
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
                .Const => |x| switch (m.consts.items[x.value.int()]) {
                    .String => |str| try out.print(a, "r{d} = \"{s}\"", .{ x.dst.int(), str }),
                    .Int => |v| try out.print(a, "r{d} = {d}", .{ x.dst.int(), v }),
                    else => |c| try out.print(a, "r{d} = const {s}", .{ x.dst.int(), @tagName(c) }),
                },
                .MakeCell => |x| try out.print(a, "r{d} = cell r{d}", .{ x.dst.int(), x.src.int() }),
                .GetFieldSlot => |x| try out.print(a, "r{d} = r{d}.#{d}", .{ x.dst.int(), x.obj.int(), x.slot }),
                .SetFieldSlot => |x| try out.print(a, "r{d}.#{d} = r{d}", .{ x.obj.int(), x.slot, x.value.int() }),
                .LoadStatic => |x| try out.print(a, "r{d} = static {d}", .{ x.dst.int(), x.static.int() }),
                .StoreStatic => |x| try out.print(a, "static {d} = r{d}", .{ x.static.int(), x.value.int() }),
                .LoadObject => |x| try out.print(a, "r{d} = object {s}", .{ x.dst.int(), m.classes.items[x.class.int()].name }),
                .CallStatic => |x| try out.print(a, "r{d} = call {s}(r{d}..{d})", .{ x.dst.int(), m.funcs.items[x.func.int()].fqn, x.args.int(), x.n_args }),
                .RCallVirtual => |x| try out.print(a, "r{d} = virtual {s}(r{d}..{d})", .{ x.dst.int(), m.funcs.items[x.slot.int()].fqn, x.args.int(), x.n_args }),
                .CallInterface => |x| try out.print(a, "r{d} = interface {s}(r{d}..{d})", .{ x.dst.int(), m.funcs.items[x.slot.int()].fqn, x.args.int(), x.n_args }),
                .RCallValue => |x| try out.print(a, "r{d} = invoke r{d}(r{d}..{d})", .{ x.dst.int(), x.callee.int(), x.args.int(), x.n_args }),
                .RNewInstance => |x| try out.print(a, "r{d} = new {s} {s}(r{d}..{d})", .{ x.dst.int(), m.classes.items[x.class.int()].name, m.funcs.items[x.ctor.int()].name, x.args.int(), x.n_args }),
                .MakeClosure => |x| {
                    try out.print(a, "r{d} = closure {s}(", .{ x.dst.int(), m.funcs.items[x.func.int()].fqn });
                    for (x.captures, 0..) |c, k| try out.print(a, "{s}r{d}", .{ if (k == 0) "" else ", ", c.int() });
                    try out.append(a, ')');
                },
                .FunctionRef => |x| try out.print(a, "r{d} = ref {s}", .{ x.dst.int(), m.funcs.items[x.target.int()].fqn }),
                .RPropertyRef => |x| try out.print(a, "r{d} = property ref {s}", .{ x.dst.int(), m.consts.items[x.name.int()].String }),
                .NewArray => |x| try out.print(a, "r{d} = array(r{d}..{d})", .{ x.dst.int(), x.args.int(), x.n_args }),
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
            .Throw => |r| try out.print(a, "throw r{d}", .{r.int()}),
            else => |t| try out.print(a, "{s}", .{@tagName(t)}),
        }
        try out.append(a, '\n');
    }
    return out.items;
}

test "every body of the miniature base lowers" {
    var fx = try Fx.init("fun main() {}");
    defer fx.deinit();
    try fx.expectNoErrors();
    // Every body with an id that is not abstract or native is written.
    const br = fx.an.br;
    const r = br.m.resolved.?;
    for (br.origin, 0..) |o, i| {
        if (o == .abstract or r.func_native[i] != .none) continue;
        if (o == .decl) {
            const d = o.decl;
            const fl = fx.an.s.syms.flags(d);
            if (fx.an.s.syms.kind(d) == .function and !fl.has_body and !fl.synthetic and fx.prog.prims.get(d) == null) continue;
        }
        if (!fx.prog.lowered.isSet(i)) {
            std.debug.print("not lowered: {s}\n", .{br.m.funcs.items[i].fqn});
            return error.TestUnexpectedResult;
        }
    }
}

// ---------------------------------------------------------- executing ----

/// Runs `src` and expects exactly `want`; skipped while a package the
/// program needs is not built.
fn expectRun(src: []const u8, want: []const u8) !void {
    driver.expectOutput(&.{src}, want) catch |err| {
        if (err == error.Unsupported) return error.SkipZigTest;
        return err;
    };
}

fn expectThrow(src: []const u8, fqn: []const u8) !void {
    driver.expectThrows(&.{src}, fqn) catch |err| {
        if (err == error.Unsupported) return error.SkipZigTest;
        return err;
    };
}

test "an open base's body property holds its seed while an override reads it during the base constructor" {
    try expectRun(
        \\open class Base {
        \\    init { describe() }
        \\    open fun describe() { println("base") }
        \\}
        \\class Derived : Base() {
        \\    val label: String = "set"
        \\    val count: Int = 3
        \\    override fun describe() { println("derived " + label + " " + count) }
        \\}
        \\fun main() {
        \\    Derived().describe()
        \\}
    ,
        \\derived null 0
        \\derived set 3
        \\
    );
}

test "initializers and init blocks run in source order after the supertype's" {
    try expectRun(
        \\open class A(val x: Int) {
        \\    init { println("A init " + x) }
        \\}
        \\class B(y: Int) : A(y * 2) {
        \\    val first = trace("first")
        \\    init { println("B init " + y) }
        \\    val second = trace("second")
        \\    fun trace(s: String): String {
        \\        println(s)
        \\        return s
        \\    }
        \\}
        \\fun main() {
        \\    val b = B(5)
        \\    println(b.x)
        \\}
    ,
        \\A init 10
        \\first
        \\B init 5
        \\second
        \\10
        \\
    );
}

test "an interface default overriding the one a superclass inherits is the more specific" {
    try expectRun(
        \\interface I { fun f(): String = "I" }
        \\interface J : I { override fun f(): String = "J" }
        \\abstract class A : I
        \\open class B : A(), J
        \\class C : B()
        \\abstract class K : I { override fun f(): String = "K" }
        \\class L : K()
        \\fun main() {
        \\    println(B().f())
        \\    val i: I = C()
        \\    println(i.f())
        \\    val l: I = L()
        \\    println(l.f())
        \\}
    , "J\nJ\nK\n");
}

test "an extension property's delegate receives the receiver as thisRef" {
    try expectRun(
        \\class Box(var n: Int)
        \\class Twice {
        \\    operator fun getValue(thisRef: Box, p: kotlin.reflect.KProperty<*>): Int = thisRef.n * 2
        \\    operator fun setValue(thisRef: Box, p: kotlin.reflect.KProperty<*>, v: Int) { thisRef.n = v / 2 }
        \\}
        \\var Box.doubled by Twice()
        \\fun main() {
        \\    val b = Box(4)
        \\    println(b.doubled)
        \\    b.doubled = 20
        \\    println(b.n)
        \\}
    , "8\n10\n");
}

test "enumValues and enumValueOf, called or referenced, are the enum class's own members" {
    try expectRun(
        \\enum class Color { RED, GREEN }
        \\fun main() {
        \\    println(enumValues<Color>().size)
        \\    println(enumValueOf<Color>("GREEN"))
        \\    val all: () -> Array<Color> = ::enumValues
        \\    println(all()[1])
        \\    val byName: (String) -> Color = ::enumValueOf
        \\    println(byName("RED"))
        \\}
    , "2\nGREEN\nGREEN\nRED\n");
}

test "enumValues and enumValueOf of a reified type parameter are the argument's own members at each inline copy" {
    try expectRun(
        \\enum class Color { RED, GREEN, BLUE }
        \\enum class Size { S, M }
        \\class Holder<E : Enum<E>>(val name: String, val values: Array<E>)
        \\inline fun <reified E : Enum<E>> holder(name: String): Holder<E> = Holder(name, enumValues())
        \\inline fun <reified E : Enum<E>> parse(s: String): E = enumValueOf<E>(s)
        \\inline fun <reified E : Enum<E>> last(): E = holder<E>("x").values[enumValues<E>().size - 1]
        \\fun main() {
        \\    val h = holder<Color>("c")
        \\    println(h.name + " " + h.values.size + " " + h.values[2])
        \\    println(parse<Color>("GREEN"))
        \\    println(last<Color>())
        \\    println(last<Size>())
        \\}
    , "c 3 BLUE\nGREEN\nBLUE\nM\n");
}

test "an enum class initializes its entries and then its companion on first use, valueOf included" {
    try expectRun(
        \\var log = ""
        \\enum class Color(val code: Int) {
        \\    RED(1), GREEN(2);
        \\    init { log += "C.$name;" }
        \\    companion object {
        \\        init { log += "comp;" }
        \\        fun first() = RED
        \\    }
        \\}
        \\enum class Level {
        \\    LOW;
        \\    init { log += "L;" }
        \\    companion object {
        \\        init { log += "LC;" }
        \\    }
        \\}
        \\enum class Mode {
        \\    ON;
        \\    init { log += "M;" }
        \\    companion object {
        \\        init { log += "MC;" }
        \\        fun describe() = "mode"
        \\    }
        \\}
        \\fun main() {
        \\    val c = Color.GREEN
        \\    println(log + c.code)
        \\    log = ""
        \\    println(Color.first())
        \\    println(log)
        \\    try {
        \\        Level.valueOf("X")
        \\    } catch (e: IllegalArgumentException) {
        \\        log += "caught;"
        \\    }
        \\    println(log)
        \\    log = ""
        \\    println(Mode.describe())
        \\    println(log)
        \\}
    , "C.RED;C.GREEN;comp;2\nRED\n\nL;LC;caught;\nmode\nM;MC;\n");
}

test "an inner class of a local class reaches the local class's captures through its outer instance" {
    try expectRun(
        \\fun run(): String {
        \\    var log = ""
        \\    var first: Any? = null
        \\    for (t in arrayOf("1", "2")) {
        \\        class C {
        \\            val y = t
        \\            inner class D {
        \\                fun copyOuter() = C()
        \\                fun both() = "($y;$t)"
        \\            }
        \\        }
        \\        if (first == null) first = C()
        \\        val c = first as C
        \\        log += c.D().copyOuter().y + c.D().both() + " "
        \\    }
        \\    return log
        \\}
        \\fun main() {
        \\    println(run())
        \\}
    , "1(1;1) 1(1;1) \n");
}

test "a class's companion initializes at its first instantiation, before the instance" {
    try expectRun(
        \\var log = ""
        \\class Engine {
        \\    init { log += "instance;" }
        \\    companion object {
        \\        init { log += "companion;" }
        \\    }
        \\}
        \\fun main() {
        \\    Engine()
        \\    Engine()
        \\    println(log)
        \\}
    , "companion;instance;instance;\n");
}

test "a cast to a definitely non-null type parameter throws on null" {
    try expectRun(
        \\fun <T> definitely(t: T) = t as (T & Any)
        \\fun main() {
        \\    println(definitely("value"))
        \\    try {
        \\        definitely<Any?>(null)
        \\        println("no exception")
        \\    } catch (e: NullPointerException) {
        \\        println("NPE")
        \\    }
        \\}
    , "value\nNPE\n");
}

test "isInitialized reads a lateinit property's storage without its check" {
    try expectRun(
        \\lateinit var top: String
        \\class Box {
        \\    lateinit var name: String
        \\    fun ready() = this::name.isInitialized
        \\}
        \\fun main() {
        \\    println(::top.isInitialized)
        \\    top = "x"
        \\    println(::top.isInitialized)
        \\    val b = Box()
        \\    println(b.ready())
        \\    b.name = "n"
        \\    println(b::name.isInitialized)
        \\}
    , "false\ntrue\nfalse\ntrue\n");
}

test "an enum entry's body reads its own name as the instance being built" {
    try expectRun(
        \\abstract class Holder(val kind: Kind)
        \\enum class Kind {
        \\    PLAIN {
        \\        inner class Wrapper : Holder(PLAIN)
        \\        val wrapper = Wrapper()
        \\        override fun same() = wrapper.kind === this
        \\    };
        \\    abstract fun same(): Boolean
        \\}
        \\fun main() {
        \\    println(Kind.PLAIN.same())
        \\}
    , "true\n");
}

test "a constructor without a delegation calls the superclass constructor that takes no arguments" {
    try expectRun(
        \\open class Base {
        \\    val note: String
        \\    constructor() { note = "none" }
        \\    constructor(n: String) { note = n }
        \\}
        \\class Sub : Base {
        \\    constructor()
        \\    constructor(x: Int) : super("x" + x)
        \\}
        \\open class WithDefaults(val k: Int = 7)
        \\class Defaulted : WithDefaults {
        \\    constructor()
        \\}
        \\fun main() {
        \\    println(Sub().note)
        \\    println(Sub(2).note)
        \\    println(Defaulted().k)
        \\}
    , "none\nx2\n7\n");
}

test "a secondary constructor delegates to the primary and then runs its body" {
    try expectRun(
        \\class P(val a: Int, val b: Int) {
        \\    constructor(a: Int) : this(a, a * 10) {
        \\        println("secondary " + a)
        \\    }
        \\    init { println("primary " + a + " " + b) }
        \\}
        \\class Q {
        \\    val v: Int
        \\    constructor(x: Int) {
        \\        v = x + 1
        \\    }
        \\}
        \\fun main() {
        \\    val p = P(2)
        \\    println(p.a + p.b)
        \\    println(Q(4).v)
        \\}
    ,
        \\primary 2 20
        \\secondary 2
        \\22
        \\5
        \\
    );
}

test "an inner class binds its outer instance and a nested class has none" {
    try expectRun(
        \\class Outer(val name: String) {
        \\    inner class Inner(val n: Int) {
        \\        fun show() = name + n
        \\    }
        \\    class Nested {
        \\        fun show() = "nested"
        \\    }
        \\    fun make() = Inner(2)
        \\}
        \\fun main() {
        \\    val o = Outer("o")
        \\    println(o.make().show())
        \\    println(o.Inner(3).show())
        \\    println(Outer.Nested().show())
        \\}
    ,
        \\o2
        \\o3
        \\nested
        \\
    );
}

test "an object and a companion are made once, on first use" {
    try expectRun(
        \\object Registry {
        \\    init { println("registry") }
        \\    var count = 0
        \\}
        \\class Color(val v: Int) {
        \\    companion object {
        \\        init { println("companion") }
        \\        val Unspecified = Color(-1)
        \\    }
        \\}
        \\fun main() {
        \\    println("start")
        \\    Registry.count = Registry.count + 1
        \\    Registry.count = Registry.count + 1
        \\    println(Registry.count)
        \\    println(Color.Unspecified.v)
        \\    println(Color.Unspecified === Color.Unspecified)
        \\}
    ,
        \\start
        \\registry
        \\2
        \\companion
        \\-1
        \\true
        \\
    );
}

test "enum entries with arguments and bodies, values, valueOf and ordinal" {
    try expectRun(
        \\enum class Op(val sign: String) {
        \\    PLUS("+") {
        \\        override fun apply(a: Int, b: Int) = a + b
        \\    },
        \\    TIMES("*") {
        \\        override fun apply(a: Int, b: Int) = a * b
        \\    };
        \\    abstract fun apply(a: Int, b: Int): Int
        \\}
        \\enum class Dir { NORTH, SOUTH }
        \\fun main() {
        \\    for (op in Op.values()) println(op.name + " " + op.sign + " " + op.ordinal + " " + op.apply(3, 4))
        \\    println(Dir.valueOf("SOUTH").ordinal)
        \\    println(Dir.NORTH)
        \\    println(Dir.NORTH == Dir.valueOf("NORTH"))
        \\    println(Dir.values().size)
        \\}
    ,
        \\PLUS + 0 7
        \\TIMES * 1 12
        \\1
        \\NORTH
        \\true
        \\2
        \\
    );
}

test "valueOf of a name no entry has throws IllegalArgumentException" {
    try expectThrow(
        \\enum class Dir { NORTH }
        \\fun main() {
        \\    Dir.valueOf("UP")
        \\}
    , "kotlin.IllegalArgumentException");
}

test "a data class compares, hashes and prints by its properties, copies and destructures" {
    try expectRun(
        \\data class Point(val x: Int, val y: String)
        \\fun main() {
        \\    val p = Point(1, "a")
        \\    val q = Point(1, "a")
        \\    println(p == q)
        \\    println(p === q)
        \\    println(p.hashCode() == q.hashCode())
        \\    println(p)
        \\    val r = p.copy(y = "b")
        \\    println(r)
        \\    println(p == r)
        \\    val (x, y) = r
        \\    println(x.toString() + y)
        \\}
    ,
        \\true
        \\false
        \\true
        \\Point(x=1, y=a)
        \\Point(x=1, y=b)
        \\false
        \\1b
        \\
    );
}

test "a data class and an annotation print an array property by its elements" {
    try expectRun(
        \\data class D(val xs: IntArray, val n: Int)
        \\annotation class A(val xs: IntArray)
        \\fun main() {
        \\    println(D(intArrayOf(1, 2), 3))
        \\    println(A(intArrayOf(4)))
        \\}
    ,
        \\D(xs=[1, 2], n=3)
        \\@A(xs=[4])
        \\
    );
}

test "a class delegating an interface forwards to its delegate" {
    try expectRun(
        \\interface Greeter {
        \\    fun greet(who: String): String
        \\    val tag: String
        \\}
        \\class Plain : Greeter {
        \\    override fun greet(who: String) = "hi " + who
        \\    override val tag = "plain"
        \\}
        \\class Loud(g: Greeter) : Greeter by g {
        \\    override val tag = "loud"
        \\}
        \\fun main() {
        \\    val l: Greeter = Loud(Plain())
        \\    println(l.greet("x"))
        \\    println(l.tag)
        \\}
    ,
        \\hi x
        \\loud
        \\
    );
}

test "a local class reads a captured val and var" {
    try expectRun(
        \\fun main() {
        \\    val base = 10
        \\    var bump = 1
        \\    class Counter(val start: Int) {
        \\        fun next() = start + base + bump
        \\    }
        \\    val c = Counter(5)
        \\    println(c.next())
        \\    bump = 100
        \\    println(c.next())
        \\}
    ,
        \\16
        \\115
        \\
    );
}

test "an object expression implements an interface and captures this and a local" {
    try expectRun(
        \\interface Shape { fun area(): Int }
        \\class Box(val side: Int) {
        \\    fun shape(extra: Int): Shape = object : Shape {
        \\        override fun area() = side * side + extra
        \\    }
        \\}
        \\fun main() {
        \\    println(Box(3).shape(1).area())
        \\}
    ,
        \\10
        \\
    );
}

test "lambdas: a captured var, a receiver lambda, an untyped initializer" {
    try expectRun(
        \\class Acc(var total: Int)
        \\fun build(f: Acc.() -> Unit): Int {
        \\    val a = Acc(0)
        \\    a.f()
        \\    return a.total
        \\}
        \\fun main() {
        \\    var n = 0
        \\    val inc = { n = n + 1 }
        \\    inc()
        \\    inc()
        \\    println(n)
        \\    println(build { total = total + 5 })
        \\    val sq = { x: Int -> x * x }
        \\    println(sq(7))
        \\}
    ,
        \\2
        \\5
        \\49
        \\
    );
}

test "a fun interface's default method calls its method on the lambda's wrapper" {
    try expectRun(
        \\fun interface Source {
        \\    fun next(): Int
        \\    fun twice(): Int = next() + next()
        \\}
        \\fun main() {
        \\    var i = 0
        \\    val s = Source { i = i + 1; i }
        \\    println(s.twice())
        \\}
    ,
        \\3
        \\
    );
}

test "a local function recurses and reads what it captures" {
    try expectRun(
        \\fun main() {
        \\    val step = 2
        \\    fun count(n: Int): Int = if (n <= 0) 0 else 1 + count(n - step)
        \\    println(count(9))
        \\}
    ,
        \\5
        \\
    );
}

test "references to a function, a bound member, a property and a constructor" {
    try expectRun(
        \\class Pt(val x: Int) {
        \\    fun plus(d: Int) = x + d
        \\}
        \\fun twice(n: Int) = n * 2
        \\fun apply(f: (Int) -> Int, v: Int) = f(v)
        \\fun main() {
        \\    println(apply(::twice, 4))
        \\    val p = Pt(10)
        \\    println(apply(p::plus, 5))
        \\    val getX = Pt::x
        \\    println(getX(Pt(3)))
        \\    val make = ::Pt
        \\    println(make(8).x)
        \\    val named: kotlin.reflect.KCallable<Int> = Pt::x
        \\    println(named.name)
        \\}
    ,
        \\8
        \\15
        \\3
        \\8
        \\x
        \\
    );
}

test "a fun interface's SAM constructor referenced makes an instance of it" {
    try expectRun(
        \\fun interface Supplier<T> { fun get(): T }
        \\fun main() {
        \\    val ctor: (() -> String) -> Supplier<String> = ::Supplier
        \\    println(ctor { "OK" }.get())
        \\}
    ,
        \\OK
        \\
    );
}

test "a reference passed for a fun interface is wrapped in it" {
    try expectRun(
        \\fun interface IntConsumer { fun accept(t: Int) }
        \\fun run2(c: IntConsumer) = c.accept(1)
        \\fun intRef(x: Int) = println("intRef " + x)
        \\fun main() {
        \\    run2(::intRef)
        \\}
    ,
        \\intRef 1
        \\
    );
}

test "two references to one function are equal and hash alike; two lambdas are not" {
    try expectRun(
        \\class K(val v: Int) {
        \\    fun get() = v
        \\}
        \\fun twice(n: Int) = n * 2
        \\fun main() {
        \\    val f = ::twice
        \\    val g = ::twice
        \\    println(f == g)
        \\    println(f.hashCode() == g.hashCode())
        \\    val k = K(1)
        \\    println(k::get == k::get)
        \\    println(k::get == K(1)::get)
        \\    val l1 = { 1 }
        \\    val l2 = { 1 }
        \\    println(l1 == l2)
        \\    println(l1 == l1)
        \\}
    ,
        \\true
        \\true
        \\true
        \\false
        \\false
        \\true
        \\
    );
}

test "a member extension of a fun interface receives its extension receiver" {
    try expectRun(
        \\fun interface Scale {
        \\    fun Int.scaled(): Int
        \\}
        \\fun use(s: Scale): Int = with(s) { 5.scaled() }
        \\fun main() {
        \\    println(use(Scale { this * 3 }))
        \\}
    ,
        \\15
        \\
    );
}

test "a constructor reference used with receiver syntax" {
    try expectRun(
        \\class Box(val n: Int)
        \\fun main() {
        \\    val mk: Int.() -> Box = ::Box
        \\    println(5.mk().n)
        \\}
    ,
        \\5
        \\
    );
}

test "a delegated member property reads its delegate once" {
    try expectRun(
        \\class Holder {
        \\    val v: Int by lazy {
        \\        println("computing")
        \\        42
        \\    }
        \\}
        \\fun main() {
        \\    val h = Holder()
        \\    println(h.v)
        \\    println(h.v)
        \\}
    ,
        \\computing
        \\42
        \\42
        \\
    );
}

test "a lambda passed for a fun interface is wrapped once, by the call" {
    var fx = try Fx.init(
        \\fun interface Action { fun run(x: Int): Int }
        \\fun call(a: Action) = a.run(1)
        \\fun main() {
        \\    println(call { it + 1 })
        \\}
    );
    defer fx.deinit();
    try fx.expectNoErrors();
    const main = fx.an.br.funcOf(try fx.topLevel("main"));
    try testing.expectEqual(@as(usize, 1), fx.count(main, .MakeClosure));
    try testing.expectEqual(@as(usize, 1), fx.count(main, .RNewInstance));
}

test "an enum class's init unit makes each entry with its name and ordinal" {
    var fx = try Fx.init(
        \\enum class E(val code: Int) { A(1), B(2) { override fun toString() = "b" } }
        \\fun main() {}
    );
    defer fx.deinit();
    try fx.expectNoErrors();
    const br = fx.an.br;
    const e = try fx.class("E");
    const a_static = br.staticOf(try fx.member(e, "A")).?;
    const unit = br.m.resolved.?.statics[a_static.int()].unit;
    try testing.expectEqualStrings(
        \\  r0 = "A"
        \\  r1 = 0
        \\  r6 = 1
        \\  r4 = r0
        \\  r5 = r1
        \\  r2 = new E <init>(r4..3)
        \\  static 0 = r2
        \\  r7 = "B"
        \\  r8 = 1
        \\  r10 = r7
        \\  r11 = r8
        \\  r9 = new $B <init>(r10..2)
        \\  static 1 = r9
        \\  return
        \\
    , try fx.listing(br.m.resolved.?.init_units[unit].func));
}

test "a constructor stores its parameters' properties, then runs initializers in order" {
    var fx = try Fx.init(
        \\open class Base(val a: Int)
        \\class C(val x: Int, y: Int) : Base(y) {
        \\    val z = x * 2
        \\    init { println(z + y) }
        \\}
        \\fun main() {}
    );
    defer fx.deinit();
    try fx.expectNoErrors();
    const listing = try fx.listing(try fx.ctorOf("C"));
    // The supertype call on this, then `x` into its slot, then `z`.
    const super_at = std.mem.indexOf(u8, listing, "call Base.<init>").?;
    const x_at = std.mem.indexOf(u8, listing, ".#1 = ").?;
    const z_at = std.mem.indexOf(u8, listing, ".#2 = ").?;
    try testing.expect(super_at < x_at and x_at < z_at);
    try testing.expect(std.mem.endsWith(u8, listing, "return r0\n"));
}

test "a bound reference to an extension function binds its receiver" {
    try expectRun(
        \\fun Int.plus1(): Int = this + 1
        \\fun String.twice(n: Int): String = if (n <= 1) this else this + twice(n - 1)
        \\fun main() {
        \\    val f = 5::plus1
        \\    println(f())
        \\    val g = "ab"::twice
        \\    println(g(3))
        \\    val h = Int::plus1
        \\    println(h(9))
        \\}
    ,
        \\6
        \\ababab
        \\10
        \\
    );
}

test "an annotation instance equals, hashes and renders by its members" {
    try expectRun(
        \\annotation class Tag(val name: String, val weight: Int = 1)
        \\fun main() {
        \\    val a = Tag("alpha", 3)
        \\    val b = Tag("alpha", 3)
        \\    println(a == b)
        \\    println(a == Tag("beta"))
        \\    println(a.hashCode() == b.hashCode())
        \\    println(Tag("x").hashCode() == (127 * "name".hashCode() xor "x".hashCode()) + (127 * "weight".hashCode() xor 1))
        \\    println(a)
        \\}
    , "true\nfalse\ntrue\ntrue\n@Tag(name=alpha, weight=3)\n");
}

test "a collection override taking a narrower type answers a value of another type without running" {
    try expectRun(
        \\class Names : List<String> {
        \\    override val size: Int get() = 1
        \\    override fun isEmpty(): Boolean = false
        \\    override fun contains(element: String): Boolean = element.length == 3
        \\    override fun get(index: Int): String = "abc"
        \\    override fun indexOf(element: String): Int = if (element.length == 3) 0 else -1
        \\    override fun iterator(): Iterator<String> = throw IllegalStateException()
        \\}
        \\class Lengths : Map<String, Int> {
        \\    override val size: Int get() = 0
        \\    override fun get(key: String): Int? = key.length
        \\}
        \\fun main() {
        \\    val names: Collection<Any?> = Names()
        \\    println(names.contains("abc"))
        \\    println(names.contains(7))
        \\    println(names.contains(null))
        \\    val list: List<Any?> = Names()
        \\    println(list.indexOf(3))
        \\    println(list.indexOf("xyz"))
        \\    val map: Map<Any?, Int> = Lengths()
        \\    println(map.get("four"))
        \\    println(map.get(4))
        \\}
    , "true\nfalse\nfalse\n-1\n0\n4\nnull\n");
}

test "a collection override taking a non-null Any answers null without running" {
    try expectRun(
        \\object Always : Map<Any, Any> {
        \\    override val size: Int get() = 1
        \\    override fun get(key: Any): Any? = "v"
        \\}
        \\class Maybe : Map<Any?, Any> {
        \\    override val size: Int get() = 1
        \\    override fun get(key: Any?): Any? = "v"
        \\}
        \\fun main() {
        \\    val always = Always as Map<Any?, Any?>
        \\    println(always.get(null))
        \\    println(always.get(1))
        \\    val maybe = Maybe() as Map<Any?, Any?>
        \\    println(maybe.get(null))
        \\}
    , "null\nv\nv\n");
}
