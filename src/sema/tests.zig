//! Sema over small programs: each test parses Kotlin source against a
//! miniature `kotlin` package and checks the symbols, types and census.

const std = @import("std");
const span = @import("span");
const ast = @import("ast");
const lexer = @import("lexer");
const parser = @import("parser");

const sema_mod = @import("sema.zig");
const headers = @import("headers.zig");
const subtyping = @import("subtyping.zig");
const render = @import("render.zig");
const records = @import("records.zig");

const Sema = sema_mod.Sema;

/// The builtins a test needs, declared the way the base set declares them.
pub const mini_kotlin =
    \\package kotlin
    \\public open class Any {
    \\    public open fun toString(): String = ""
    \\    public open operator fun equals(other: Any?): Boolean = false
    \\    public open fun hashCode(): Int = 0
    \\}
    \\public class Nothing private constructor()
    \\public object Unit
    \\public class Boolean { public operator fun not(): Boolean = this }
    \\public class Int : Number(), Comparable<Int> {
    \\    public operator fun plus(other: Int): Int = this
    \\    public operator fun plus(other: Long): Long = TODO()
    \\    public operator fun times(other: Int): Int = this
    \\    public operator fun compareTo(other: Int): Int = 0
    \\    public fun toLong(): Long = TODO()
    \\}
    \\public class Long : Number(), Comparable<Long> {
    \\    public operator fun plus(other: Long): Long = this
    \\    public operator fun compareTo(other: Long): Int = 0
    \\}
    \\public class Double : Number(), Comparable<Double>
    \\public class Byte : Number(), Comparable<Byte>
    \\public class Short : Number(), Comparable<Short>
    \\public fun <T> arrayOf(vararg elements: T): Array<T> = TODO()
    \\public abstract class Number
    \\public interface Comparable<in T> { public operator fun compareTo(other: T): Int }
    \\public interface CharSequence { public val length: Int }
    \\public class String : Comparable<String>, CharSequence {
    \\    public operator fun plus(other: Any?): String = this
    \\    public override val length: Int get() = 0
    \\}
    \\public class Array<T>
    \\public abstract class Enum<E : Enum<E>>(name: String, ordinal: Int) : Comparable<E> {
    \\    public val name: String get() = ""
    \\    public override operator fun compareTo(other: E): Int = 0
    \\}
    \\public interface Function<out R>
    \\public open class Throwable
    \\public fun TODO(): Nothing = throw Throwable()
    \\public fun Any?.toString(): String = ""
    \\public operator fun String?.plus(other: Any?): String = ""
    \\
;

/// Scope functions and a few generic extensions, as the stdlib declares
/// them.
pub const mini_standard =
    \\package kotlin
    \\public inline fun <T, R> with(receiver: T, block: T.() -> R): R = receiver.block()
    \\public inline fun <T> T.apply(block: T.() -> Unit): T { block(); return this }
    \\public inline fun <T, R> T.let(block: (T) -> R): R = block(this)
    \\public inline fun <R> run(block: () -> R): R = block()
    \\public inline fun <T, R> context(with: T, block: context(T) () -> R): R = block(with)
    \\public fun <T> emptyList(): kotlin.collections.List<T> = TODO()
    \\public fun <T : Comparable<T>> maxOf(a: T, b: T): T = a
    \\public fun maxOf(a: Int, b: Int): Int = a
    \\
;

pub const mini_collections =
    \\package kotlin.collections
    \\public interface Iterator<out T> { public operator fun next(): T; public operator fun hasNext(): Boolean }
    \\public interface Iterable<out T> { public operator fun iterator(): Iterator<T> }
    \\public interface Collection<out E> : Iterable<E> { public val size: Int }
    \\public interface List<out E> : Collection<E> { public operator fun get(index: Int): E }
    \\public interface MutableList<E> : List<E> { public fun add(element: E): Boolean }
    \\public interface Map<K, out V> { public interface Entry<out K, out V> { public val key: K } }
    \\public open class ArrayList<E> : MutableList<E> {
    \\    override val size: Int get() = 0
    \\    override fun get(index: Int): E = TODO()
    \\    override fun add(element: E): Boolean = true
    \\    override fun iterator(): Iterator<E> = TODO()
    \\}
    \\public fun <T> listOf(vararg elements: T): List<T> = TODO()
    \\public inline fun <T, R> Iterable<T>.map(transform: (T) -> R): List<R> = TODO()
    \\public fun <T> Iterable<T>.first(): T = TODO()
    \\public fun <T> List<T>.first(): T = TODO()
    \\
;

pub const Fixture = struct {
    /// Heap-allocated: the analysis holds an allocator into it, so the
    /// arena must not move when the fixture is returned by value.
    arena: *std.heap.ArenaAllocator,
    map: span.SourceMap,
    s: *Sema,

    pub fn deinit(self: *Fixture) void {
        self.arena.deinit();
        std.testing.allocator.destroy(self.arena);
    }

    pub fn class(self: *Fixture, fqn: []const u8) sema_mod.Sym {
        return self.s.classByFqn(fqn);
    }

    pub fn typeText(self: *Fixture, t: sema_mod.TypeId) []const u8 {
        return render.typeStr(self.s, self.arena.allocator(), t) catch "?";
    }

    /// Resolves the program files' bodies.
    pub fn resolve(self: *Fixture) !void {
        try self.s.resolveBodies(&.{.program});
    }

    /// The first program file's text.
    fn programText(self: *Fixture) []const u8 {
        return self.map.get(span.FileId.from(3)).source;
    }

    /// The reference anchored where `needle` points in the first program
    /// file: at its first occurrence, offset by a `^` inside it when it has
    /// one (`"b.^size()"` is the `size` of `b.size()`). Several references
    /// can share an anchor (the read of `a` and the `plus` of `a + 1`);
    /// `kind` picks one, and without it the anchor must hold exactly one.
    pub fn refAt(self: *Fixture, needle: []const u8, kind: ?records.RefKind) !records.Ref {
        var buf: [256]u8 = undefined;
        const caret = std.mem.indexOfScalar(u8, needle, '^');
        const text_needle = if (caret) |c| blk: {
            @memcpy(buf[0..c], needle[0..c]);
            @memcpy(buf[c .. needle.len - 1], needle[c + 1 ..]);
            break :blk buf[0 .. needle.len - 1];
        } else needle;
        const off = std.mem.indexOf(u8, self.programText(), text_needle) orelse {
            std.debug.print("`{s}` is not in the program\n", .{needle});
            return error.TestUnexpectedResult;
        };
        const at = off + (caret orelse 0);
        var found: ?records.Ref = null;
        var n: usize = 0;
        for (self.s.refs.items) |r| {
            if (r.file != 3 or r.anchor.start != at) continue;
            if (kind) |k| if (r.kind != k) continue;
            if (found == null) found = r;
            n += 1;
        }
        if (n == 1) return found.?;
        std.debug.print("{d} references at `{s}`:\n", .{ n, needle });
        for (self.s.refs.items) |r| {
            if (r.file != 3 or r.anchor.start != at) continue;
            const id = render.callableId(self.s, self.arena.allocator(), r.target) catch "?";
            std.debug.print("  {s} {s}\n", .{ @tagName(r.kind), id });
        }
        return error.TestUnexpectedResult;
    }

    /// The node of the expression starting where `needle` points, as
    /// `refAt` finds a position, for an expression with no reference (a
    /// literal).
    pub fn exprAt(self: *Fixture, needle: []const u8) !ast.NodeId {
        var buf: [256]u8 = undefined;
        const caret = std.mem.indexOfScalar(u8, needle, '^');
        const text_needle = if (caret) |c| blk: {
            @memcpy(buf[0..c], needle[0..c]);
            @memcpy(buf[c .. needle.len - 1], needle[c + 1 ..]);
            break :blk buf[0 .. needle.len - 1];
        } else needle;
        const off = std.mem.indexOf(u8, self.programText(), text_needle) orelse return error.TestUnexpectedResult;
        const at = off + (caret orelse 0);
        for (self.s.expr_types.items) |et| {
            if (et.file == 3 and et.sp.start == at) return et.node;
        }
        return error.TestUnexpectedResult;
    }

    pub fn ref(self: *Fixture, needle: []const u8) !records.Ref {
        return self.refAt(needle, null);
    }

    /// Asserts the reference at `needle` (of `kind`, when given) resolved
    /// to the declaration whose id renders as `want` (`demo/f`,
    /// `kotlin/Int.plus`).
    pub fn expectRef(self: *Fixture, needle: []const u8, kind: ?records.RefKind, want: []const u8) !void {
        const r = try self.refAt(needle, kind);
        const got = try render.callableId(self.s, self.arena.allocator(), r.target);
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("`{s}`: want {s}, got {s}\n", .{ needle, want, got });
            return error.TestUnexpectedResult;
        }
    }

    pub fn expectTarget(self: *Fixture, needle: []const u8, want: []const u8) !void {
        return self.expectRef(needle, null, want);
    }

    pub fn expectClean(self: *Fixture) !void {
        var n: u64 = 0;
        for (self.s.census.sites.items) |site| {
            if (site.file != 3) continue;
            n += 1;
            std.debug.print("unresolved: {s} {s}\n", .{ @tagName(site.reason), site.detail });
        }
        try std.testing.expectEqual(@as(u64, 0), n);
    }
};

/// Parses the builtins and `sources` (program files) into a fresh analysis.
pub fn fixture(sources: []const []const u8) !Fixture {
    const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    var fx = Fixture{ .arena = arena, .map = undefined, .s = undefined };
    errdefer fx.deinit();
    const a = fx.arena.allocator();
    fx.map = span.SourceMap.init(a);
    var files: std.ArrayList(sema_mod.SourceFile) = .empty;
    try addSource(a, &fx.map, &files, "mini/kotlin.kt", mini_kotlin, .base);
    try addSource(a, &fx.map, &files, "mini/collections.kt", mini_collections, .base);
    try addSource(a, &fx.map, &files, "mini/standard.kt", mini_standard, .base);
    for (sources, 0..) |src, i| {
        const path = try std.fmt.allocPrint(a, "test{d}.kt", .{i});
        try addSource(a, &fx.map, &files, path, src, .program);
    }
    fx.s = try Sema.init(a);
    try fx.s.addFiles(files.items);
    return fx;
}

/// `fixture`, with `generated` added after `sources` as a compiler
/// plugin's files.
pub fn fixtureGenerated(sources: []const []const u8, generated: []const []const u8) !Fixture {
    const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    var fx = Fixture{ .arena = arena, .map = undefined, .s = undefined };
    errdefer fx.deinit();
    const a = fx.arena.allocator();
    fx.map = span.SourceMap.init(a);
    var files: std.ArrayList(sema_mod.SourceFile) = .empty;
    try addSource(a, &fx.map, &files, "mini/kotlin.kt", mini_kotlin, .base);
    try addSource(a, &fx.map, &files, "mini/collections.kt", mini_collections, .base);
    try addSource(a, &fx.map, &files, "mini/standard.kt", mini_standard, .base);
    for (sources, 0..) |src, i| {
        const path = try std.fmt.allocPrint(a, "test{d}.kt", .{i});
        try addSource(a, &fx.map, &files, path, src, .program);
    }
    for (generated, 0..) |src, i| {
        const path = try std.fmt.allocPrint(a, "generated{d}.kt", .{i});
        try addSource(a, &fx.map, &files, path, src, .program);
        files.items[files.items.len - 1].generated = true;
    }
    fx.s = try Sema.init(a);
    try fx.s.addFiles(files.items);
    return fx;
}

fn addSource(a: std.mem.Allocator, map: *span.SourceMap, files: *std.ArrayList(sema_mod.SourceFile), path: []const u8, src: []const u8, origin: sema_mod.Origin) !void {
    const id = try map.add(path, src);
    const text = map.get(id).source;
    var lx = try lexer.Lexer.init(a, id, text);
    const lexed = try lx.tokenize();
    const p = parser.Parser.new(a, id, text, lexed.tokens, lexed.strings);
    const file_ast = try a.create(ast.KotlinFile);
    file_ast.* = p.parseFile();
    try files.append(a, .{ .ast = file_ast, .path = path, .origin = origin });
}

test "declarations get symbols with fully qualified names" {
    var fx = try fixture(&.{
        \\package demo
        \\class Outer { class Nested; inner class Inner; companion object { val k = 1 } }
        \\object Single
        \\enum class Color { RED, GREEN }
        \\typealias Ints = List<Int>
    });
    defer fx.deinit();
    const s = fx.s;
    const outer = fx.class("demo.Outer");
    try std.testing.expect(outer != .none);
    try std.testing.expect(fx.class("demo.Outer.Nested") != .none);
    try std.testing.expect(fx.class("demo.Outer.Inner") != .none);
    try std.testing.expect(s.syms.flags(fx.class("demo.Outer.Inner")).inner);
    const comp = s.syms.classInfo(outer).companion;
    try std.testing.expect(comp != .none);
    try std.testing.expectEqual(sema_mod.symbols.ClassKind.companion, s.syms.classInfo(comp).kind);
    try std.testing.expectEqual(sema_mod.symbols.ClassKind.object, s.syms.classInfo(fx.class("demo.Single")).kind);
    const color = fx.class("demo.Color");
    try std.testing.expectEqual(@as(usize, 2), s.syms.classInfo(color).enum_entries.len);
    try std.testing.expect(s.classByFqn("demo.Ints") != .none);
}

test "headers resolve supertypes, receivers and qualified nested types" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Shape { class Unit }
        \\open class Base<T>(val t: T)
        \\class Box : Base<String>("x"), Shape
        \\fun Shape.Unit.area(): Int = 1
        \\fun <K, V> Map.Entry<K, V>.firstKey(): K = key
        \\val <T> List<T>.lastIndex: Int get() = 0
    });
    defer fx.deinit();
    const s = fx.s;
    try headers.resolveAllHeaders(s);
    try std.testing.expectEqual(@as(u64, 0), s.census.count(.unresolved_type));
    const box = fx.class("demo.Box");
    const sts = try headers.supertypes(s, box);
    try std.testing.expectEqual(@as(usize, 2), sts.len);
    try std.testing.expectEqualStrings("demo.Base<kotlin.String>", fx.typeText(sts[0]));
    try std.testing.expectEqualStrings("demo.Shape", fx.typeText(sts[1]));
}

test "an unknown type is reported once and becomes the error type" {
    var fx = try fixture(&.{
        \\package demo
        \\fun f(x: Missing): Int = 1
    });
    defer fx.deinit();
    try headers.resolveAllHeaders(fx.s);
    try std.testing.expectEqual(@as(u64, 1), fx.s.census.count(.unresolved_type));
}

test "subtyping walks the class graph with variance" {
    var fx = try fixture(&.{
        \\package demo
        \\open class Animal
        \\class Cat : Animal()
        \\val cats: List<Cat> = TODO()
        \\val animals: List<Animal> = TODO()
        \\val mcats: MutableList<Cat> = TODO()
        \\val manimals: MutableList<Animal> = TODO()
        \\val cmp: Comparable<Animal> = TODO()
        \\val ccmp: Comparable<Cat> = TODO()
    });
    defer fx.deinit();
    const s = fx.s;
    try headers.resolveAllHeaders(s);
    const prop = struct {
        fn ty(f: *Fixture, name: []const u8) !sema_mod.TypeId {
            const pkg = f.s.syms.package_by_fqn.get(f.s.names.lookup("demo").?).?;
            const n = f.s.names.lookup(name).?;
            const sym = sema_mod.scope.membersOf(f.s, pkg, n)[0];
            return headers.propertyType(f.s, sym);
        }
    }.ty;
    const cats = try prop(&fx, "cats");
    const animals = try prop(&fx, "animals");
    const mcats = try prop(&fx, "mcats");
    const manimals = try prop(&fx, "manimals");
    // `List` is covariant, `MutableList` invariant.
    try std.testing.expect(try subtyping.isSubtype(s, cats, animals));
    try std.testing.expect(!try subtyping.isSubtype(s, animals, cats));
    try std.testing.expect(!try subtyping.isSubtype(s, mcats, manimals));
    try std.testing.expect(try subtyping.isSubtype(s, mcats, cats));
    // `Comparable` is contravariant.
    try std.testing.expect(try subtyping.isSubtype(s, try prop(&fx, "cmp"), try prop(&fx, "ccmp")));
    try std.testing.expect(!try subtyping.isSubtype(s, try prop(&fx, "ccmp"), try prop(&fx, "cmp")));
    // Nullability and the top type.
    try std.testing.expect(try subtyping.isSubtype(s, cats, s.t.any));
    try std.testing.expect(!try subtyping.isSubtype(s, try s.types.makeNullable(cats), s.t.any));
    try std.testing.expect(try subtyping.isSubtype(s, s.t.nothing, cats));
    const cat = try headers.selfType(s, fx.class("demo.Cat"));
    const animal = try headers.selfType(s, fx.class("demo.Animal"));
    try std.testing.expectEqualStrings("demo.Animal", fx.typeText(try subtyping.commonSupertype(s, &.{ cat, animal })));
}

test "overloads pick the most specific candidate and literals adapt" {
    var fx = try fixture(&.{
        \\package demo
        \\fun f(x: Any): Int = 1
        \\fun f(x: Int): Int = 2
        \\fun g(x: Long): Int = 3
        \\fun use(n: Number) {
        \\    f(1)
        \\    f("s")
        \\    g(1)
        \\    val a = 1 + 2L
        \\    maxOf(1, 2)
        \\    maxOf("a", "b")
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const f_int = try fx.ref("f(1)");
    const f_any = try fx.ref("f(\"s\")");
    try std.testing.expect(f_int.target != f_any.target);
    try std.testing.expectEqualStrings("kotlin.Int", fx.typeText(try headers.paramType(s, s.syms.functionInfo(f_int.target).params[0])));
    try std.testing.expectEqualStrings("kotlin.Any", fx.typeText(try headers.paramType(s, s.syms.functionInfo(f_any.target).params[0])));
    // An integer literal passed where a `Long` is expected is a `Long`.
    try fx.expectTarget("g(1)", "demo/g");
    const plus = try fx.refAt("= ^1 + 2L", .op);
    try std.testing.expectEqualStrings("kotlin.Long", fx.typeText(try headers.paramType(s, s.syms.functionInfo(plus.target).params[0])));
    // The non-generic overload is more specific for two `Int`s.
    const m1 = try fx.ref("maxOf(1");
    const m2 = try fx.ref("maxOf(\"a\"");
    try std.testing.expectEqual(@as(usize, 0), s.syms.functionInfo(m1.target).type_params.len);
    try std.testing.expectEqual(@as(usize, 1), s.syms.functionInfo(m2.target).type_params.len);
}

test "a member wins over an extension and the nearest extension receiver wins" {
    var fx = try fixture(&.{
        \\package demo
        \\class Box { fun size(): Int = 1 }
        \\fun Box.size(): Int = 2
        \\fun Box.extra(): Int = 3
        \\fun Any.extra(): Int = 4
        \\fun use(b: Box, xs: List<Int>) {
        \\    b.size()
        \\    b.extra()
        \\    xs.first()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("b.^size()", "demo/Box.size");
    const ex = try fx.ref("b.^extra()");
    try std.testing.expect(ex.extension == .expr);
    try std.testing.expectEqualStrings("demo.Box", fx.typeText(fx.s.syms.functionInfo(ex.target).receiver));
    // `List<T>.first` is more specific than `Iterable<T>.first`.
    const fr = try fx.ref("xs.^first()");
    try std.testing.expectEqualStrings("kotlin.collections.List<T>", fx.typeText(fx.s.syms.functionInfo(fr.target).receiver));
}

test "lambdas with receivers bring implicit receivers into scope" {
    var fx = try fixture(&.{
        \\package demo
        \\class Box { val count: Int = 0; fun grow(): Int = 1 }
        \\fun use(b: Box) {
        \\    with(b) { grow() }
        \\    b.apply { count }
        \\    b.let { it.grow() }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("with(b)", "kotlin/with");
    const g = try fx.ref("{ ^grow() }");
    try fx.expectTarget("{ ^grow() }", "demo/Box.grow");
    try std.testing.expect(g.dispatch == .implicit);
    try std.testing.expectEqual(records.ImplicitKind.lambda, g.dispatch.implicit.kind);
    try fx.expectTarget("b.^apply", "kotlin/apply");
    try fx.expectTarget("{ ^count }", "demo/Box.count");
    try fx.expectTarget("b.^let", "kotlin/let");
    try fx.expectTarget("it.^grow()", "demo/Box.grow");
}

test "generic calls infer through lambdas and nested calls" {
    var fx = try fixture(&.{
        \\package demo
        \\class Box(val n: Int) { fun twice(): Int = n * 2 }
        \\fun use() {
        \\    val boxes = listOf(Box(1), Box(2))
        \\    val ns = boxes.map { it.twice() }
        \\    ns.map { it + 1 }
        \\    val empty: List<String> = emptyList()
        \\    empty.map { it.length }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("Box(1)", "demo/Box.<init>");
    try fx.expectTarget("it.^twice()", "demo/Box.twice");
    try fx.expectRef("{ ^it + 1 }", .op, "kotlin/Int.plus");
    try fx.expectTarget("it.^length", "kotlin/String.length");
}

test "smart casts narrow locals, stable member paths and when branches" {
    var fx = try fixture(&.{
        \\package demo
        \\open class Shape
        \\class Circle(val r: Int) : Shape()
        \\class Square(val side: Int) : Shape()
        \\class Holder(val shape: Shape, val name: String?)
        \\fun area(s: Shape, h: Holder): Int {
        \\    if (s is Circle) s.r
        \\    if (h.shape is Square) h.shape.side
        \\    if (h.name != null) h.name.length
        \\    return when (s) {
        \\        is Circle -> s.radius()
        \\        is Square -> s.side
        \\        else -> 0
        \\    }
        \\}
        \\fun Circle.radius(): Int = r
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("Circle) s.^r", "demo/Circle.r");
    try fx.expectTarget("h.shape.^side", "demo/Square.side");
    try fx.expectTarget("h.name.^length", "kotlin/String.length");
    try fx.expectTarget("s.^radius()", "demo/radius");
    try fx.expectTarget("-> s.^side", "demo/Square.side");
}

test "elvis joins its sides and a nullable receiver sees only extensions" {
    var fx = try fixture(&.{
        \\package demo
        \\fun use(a: String?, b: String) {
        \\    (a ?: b).length
        \\    a.toString()
        \\    a + 1
        \\    a?.length
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget(").^length", "kotlin/String.length");
    const ts = try fx.ref("a.^toString()");
    try std.testing.expect(ts.extension == .expr);
    try fx.expectTarget("a.^toString()", "kotlin/toString");
    try fx.expectRef("^a + 1", .op, "kotlin/plus");
    try fx.expectTarget("a?.^length", "kotlin/String.length");
}

test "companions, objects and enum entries resolve as values and invoke targets" {
    var fx = try fixture(&.{
        \\package demo
        \\class Maker { companion object { operator fun invoke(n: Int): Int = n; val zero = 0 } }
        \\object Registry { fun lookup(): Int = 1 }
        \\enum class Color { RED, GREEN; fun code(): Int = 1 }
        \\fun use() {
        \\    Maker(3)
        \\    Maker.zero
        \\    Registry.lookup()
        \\    Color.RED.code()
        \\    Color.values()
        \\    Color.valueOf("RED")
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("Maker(3)", .object, "demo/Maker.Companion");
    try fx.expectRef("Maker(3)", .invoke, "demo/Maker.Companion.invoke");
    try fx.expectTarget("Maker.^zero", "demo/Maker.Companion.zero");
    try fx.expectTarget("Registry.^lookup()", "demo/Registry.lookup");
    try fx.expectTarget("Color.^RED.code", "demo/Color.RED");
    try fx.expectTarget("RED.^code()", "demo/Color.code");
    try fx.expectTarget("Color.^values()", "demo/Color.values");
    try fx.expectTarget("Color.^valueOf(", "demo/Color.valueOf");
}

test "data classes get synthesized members and destructuring" {
    var fx = try fixture(&.{
        \\package demo
        \\data class Point(val x: Int, val y: Int)
        \\fun use(p: Point) {
        \\    val (a, b) = p
        \\    p.copy(y = 2)
        \\    p.component1()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const c1 = try fx.refAt("(^a, b)", .component);
    try std.testing.expectEqual(records.RefKind.component, c1.kind);
    try fx.expectRef("(^a, b)", .component, "demo/Point.component1");
    try fx.expectRef("(a, ^b)", .component, "demo/Point.component2");
    try fx.expectTarget("p.^copy(", "demo/Point.copy");
    try fx.expectTarget("p.^component1()", "demo/Point.component1");
}

test "local classes and functions resolve inside their block" {
    var fx = try fixture(&.{
        \\package demo
        \\fun use(): Int {
        \\    class Local(val v: Int) { fun get(): Int = v }
        \\    fun helper(x: Int): Int = x + 1
        \\    val l = Local(2)
        \\    return helper(l.get())
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const ctor = try fx.ref("Local(2)");
    try std.testing.expectEqual(records.RefKind.ctor, ctor.kind);
    const h = try fx.ref("helper(l");
    try std.testing.expectEqual(sema_mod.symbols.Kind.function, s.syms.kind(h.target));
    try std.testing.expectEqualStrings("helper", s.str(s.syms.name(h.target)));
    const g = try fx.ref("l.^get()");
    try std.testing.expectEqualStrings("get", s.str(s.syms.name(g.target)));
    try std.testing.expect(g.dispatch == .expr);
}

test "a fun interface gets a SAM constructor" {
    var fx = try fixture(&.{
        \\package demo
        \\fun interface Action { fun run(x: Int): Int }
        \\fun use(): Int {
        \\    val a = Action { it + 1 }
        \\    return a.run(2)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    _ = try fx.refAt("= ^Action {", .call);
    try fx.expectRef("{ ^it + 1 }", .op, "kotlin/Int.plus");
    try fx.expectTarget("a.^run(2)", "demo/Action.run");
}

test "safe calls on a nullable type parameter use its bound" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Named { val name: String }
        \\fun <K : Named> show(k: K?): Int? = k?.name?.length
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("k?.^name", "demo/Named.name");
    try fx.expectTarget("name?.^length", "kotlin/String.length");
}

test "every site is recorded once" {
    var fx = try fixture(&.{
        \\package demo
        \\object Config { val depth: Int = 1 }
        \\class Node(val next: Node?) { fun at(i: Int): Int = i }
        \\fun use(n: Node) = n.next?.at(Config.depth + 1)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(std.testing.allocator);
    for (fx.s.refs.items) |r| {
        if (r.file != 3) continue;
        const key = (@as(u64, r.anchor.start) << 32) | @as(u64, @intFromEnum(r.kind));
        const gop = try seen.getOrPut(std.testing.allocator, key);
        if (gop.found_existing) {
            std.debug.print("duplicate {s} at {d}\n", .{ @tagName(r.kind), r.anchor.start });
            return error.TestUnexpectedResult;
        }
    }
    try fx.expectRef("(^Config.", .object, "demo/Config");
    try fx.expectTarget("Config.^depth", "demo/Config.depth");
    try fx.expectTarget("n.^next", "demo/Node.next");
    try fx.expectTarget("?.^at(", "demo/Node.at");
}

test "member extensions overload by their receiver type" {
    var fx = try fixture(&.{
        \\package demo
        \\class Dp
        \\interface Density {
        \\    fun Int.toDp(): Dp = Dp()
        \\    fun Long.toDp(): Dp = Dp()
        \\}
        \\fun Density.use() {
        \\    3.toDp()
        \\    3L.toDp()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const a = try fx.ref("3.^toDp()");
    const b = try fx.ref("3L.^toDp()");
    try std.testing.expectEqualStrings("kotlin.Int", fx.typeText(s.syms.functionInfo(a.target).receiver));
    try std.testing.expectEqualStrings("kotlin.Long", fx.typeText(s.syms.functionInfo(b.target).receiver));
    // The dispatch receiver is the extension receiver of `use`.
    try std.testing.expect(a.dispatch == .implicit);
    try std.testing.expectEqual(records.ImplicitKind.extension, a.dispatch.implicit.kind);
}

test "imported enum entries resolve by their simple name" {
    var fx = try fixture(&.{
        \\package demo
        \\import demo.Color.RED
        \\import demo.Color.*
        \\enum class Color { RED, GREEN }
        \\fun pick(c: Color): Int = when (c) {
        \\    RED -> 1
        \\    GREEN -> 2
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("^RED ->", .object, "demo/Color.RED");
    try fx.expectRef("^GREEN ->", .object, "demo/Color.GREEN");
}

test "a package imported twice is imported once" {
    var fx = try fixture(&.{
        \\package demo
        \\import other.*
        \\import other.*
        \\import other.Thing
        \\import other.Thing
        \\fun use() = Thing(1)
        \\fun star() = Other(2)
    ,
        \\package other
        \\class Thing(val n: Int)
        \\class Other(val n: Int)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("= ^Thing(1)", "other/Thing.<init>");
    try fx.expectTarget("= ^Other(2)", "other/Other.<init>");
}

test "this inside a class nested in a local class is the nested class" {
    var fx = try fixture(&.{
        \\package demo
        \\fun take(x: Inner): Int = 1
        \\interface Inner { fun tag(): Int }
        \\fun use(): Int {
        \\    class Local {
        \\        inner class Part : Inner {
        \\            override fun tag(): Int = take(this)
        \\        }
        \\    }
        \\    return 0
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("= ^take(this)", "demo/take");
}
test "this in an object's property initializer inside a local class" {
    var fx = try fixture(&.{
        \\package demo
        \\fun take(x: Inner): Int = 1
        \\interface Inner
        \\fun use(): Int {
        \\    class Local {
        \\        object Part : Inner {
        \\            val t: Int = take(this)
        \\        }
        \\    }
        \\    return 0
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("= ^take(this)", "demo/take");
}

test "context arguments come from context parameters, receivers and contextual lambdas" {
    var fx = try fixture(&.{
        \\package demo
        \\class Logger { fun log(m: String): Int = 1 }
        \\class Config(val depth: Int)
        \\context(logger: Logger) fun note(m: String): Int = logger.log(m)
        \\context(logger: Logger, cfg: Config) fun deep(): Int = cfg.depth
        \\context(_: Logger) fun viaParam(): Int = note("param")
        \\fun viaWith(l: Logger): Int = with(l) { note("with") }
        \\fun viaLambda(l: Logger, c: Config): Int = context(l) { context(c) { deep() } }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const p = try fx.ref("= ^note(\"param\")");
    try std.testing.expectEqual(@as(usize, 1), p.contexts.len);
    try std.testing.expectEqual(records.ImplicitKind.context, p.contexts[0].implicit.kind);
    const w = try fx.ref("{ ^note(\"with\")");
    try std.testing.expectEqual(records.ImplicitKind.lambda, w.contexts[0].implicit.kind);
    const d = try fx.ref("{ ^deep() }");
    try std.testing.expectEqual(@as(usize, 2), d.contexts.len);
    // Each context comes from the lambda that supplies its type.
    try std.testing.expect(d.contexts[0].implicit.owner != d.contexts[1].implicit.owner);
    try std.testing.expectEqual(sema_mod.symbols.Kind.local, s.syms.kind(d.contexts[0].implicit.owner));
}

test "a call without its context argument does not apply" {
    var fx = try fixture(&.{
        \\package demo
        \\class Logger
        \\context(logger: Logger) fun note(m: String): Int = 1
        \\fun missing(): Int = note("x")
    });
    defer fx.deinit();
    try fx.resolve();
    try std.testing.expectEqual(@as(u64, 1), fx.s.census.count(.no_applicable));
}

test "contextual function values take their contexts explicitly or from the scope" {
    var fx = try fixture(&.{
        \\package demo
        \\fun call(f: context(String, Int) (Boolean) -> Unit) {
        \\    f("s", 1, true)
        \\    context("t") { with(2) { f(false) } }
        \\}
        \\fun anon(): Int {
        \\    val a = context(x: String) fun (): Int { return x.length }
        \\    return a("hello")
        \\}
        \\fun plain(g: context(String) (Int) -> Int): Int = g("s", 1)
        \\fun pass(): Int = plain(fun(s: String, n: Int) = n)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const explicit = try fx.refAt("^f(\"s\", 1, true)", .invoke);
    try std.testing.expectEqual(@as(usize, 0), explicit.contexts.len);
    const implicit = try fx.refAt("{ ^f(false) }", .invoke);
    try std.testing.expectEqual(@as(usize, 2), implicit.contexts.len);
    try std.testing.expectEqual(records.ImplicitKind.context, implicit.contexts[0].implicit.kind);
    try std.testing.expectEqual(records.ImplicitKind.lambda, implicit.contexts[1].implicit.kind);
    try fx.expectTarget("x.^length", "kotlin/String.length");
}

test "constructors through type aliases infer the alias's parameters" {
    var fx = try fixture(&.{
        \\package demo
        \\class Pair2<T1, T2>(val x1: T1, val x2: T2)
        \\typealias ST<T> = Pair2<String, T>
        \\class Cell<T>(val x: T)
        \\typealias AliasedCell<TT> = Cell<TT>
        \\typealias CStr = Cell<String>
        \\fun use(): Int {
        \\    val st = ST<Int>("O", 1)
        \\    val cell = AliasedCell(42)
        \\    return st.x2 + cell.x + CStr("c").x.length
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("= ^ST<Int>(", .ctor, "demo/Pair2.<init>");
    try fx.expectRef("x.^length", .read, "kotlin/String.length");
}

test "an inner class's constructor takes its outer instance" {
    var fx = try fixture(&.{
        \\package demo
        \\class Outer<T>(val seed: T) {
        \\    inner class Inner(val p: T)
        \\    fun make(): Inner = Inner(seed)
        \\}
        \\fun use(o: Outer<String>): Int = o.Inner("x").p.length
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const inside = try fx.refAt("= ^Inner(seed)", .ctor);
    try std.testing.expect(inside.dispatch == .implicit);
    try std.testing.expectEqual(records.ImplicitKind.class_this, inside.dispatch.implicit.kind);
    const outside = try fx.refAt("o.^Inner(", .ctor);
    try std.testing.expect(outside.dispatch == .expr);
    try fx.expectTarget("p.^length", "kotlin/String.length");
}

test "constructor references: local, inner bound and unbound, through aliases" {
    var fx = try fixture(&.{
        \\package demo
        \\class Outer(val tag: String) {
        \\    inner class Inner(val n: Int) { fun describe(): String = tag }
        \\    typealias Alias = Inner
        \\    fun viaAlias(): Int = (::Alias)(3).n
        \\}
        \\fun use(outer: Outer): Int {
        \\    class Local(val v: Int)
        \\    val make = ::Local
        \\    val unbound = Outer::Inner
        \\    val bound = outer::Inner
        \\    return make(1).v + unbound(outer, 2).n + bound(3).n
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const local = try fx.refAt("= ::^Local", .ref);
    try std.testing.expectEqual(sema_mod.symbols.Kind.constructor, fx.s.syms.kind(local.target));
    try fx.expectRef("Outer::^Inner", .ref, "demo/Outer.Inner.<init>");
    const bound = try fx.refAt("outer::^Inner", .ref);
    try std.testing.expect(bound.dispatch == .expr);
    try fx.expectRef("(::^Alias)", .ref, "demo/Outer.Inner.<init>");
}

test "an inner class of a generic class extends another inner class" {
    var fx = try fixture(&.{
        \\package demo
        \\abstract class Base<out E> {
        \\    abstract fun at(i: Int): E
        \\    fun iterator(): Iterator<E> = Impl()
        \\    private open inner class Impl : Iterator<E> {
        \\        override fun hasNext(): Boolean = true
        \\        override fun next(): E = at(0)
        \\    }
        \\    private inner class Sub(val start: Int) : Impl()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "an inherited inner class takes the subclass's view of its outer's arguments" {
    var fx = try fixture(&.{
        \\package demo
        \\open class Select<R> {
        \\    inner class Clause(val r: R)
        \\    val clauses: MutableList<Clause> = TODO()
        \\}
        \\class Unbiased<Q> : Select<Q>() {
        \\    fun add(c: Clause): Boolean = clauses.add(c)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("clauses.^add(c)", "kotlin/collections/MutableList.add");
}

test "an explicit backing field smart-casts reads inside its class" {
    var fx = try fixture(&.{
        \\package demo
        \\class Cart {
        \\    val items: List<String>
        \\        field = ArrayList<String>()
        \\    fun add(item: String): Boolean = items.add(item)
        \\}
        \\fun outside(c: Cart): Int = c.items.size
        \\val history: List<String>
        \\    field = ArrayList<String>()
        \\fun note(): Boolean = history.add("x")
        \\interface Base {
        \\    val a: Any
        \\        get() = "not OK"
        \\}
        \\class Derived : Base {
        \\    final override val a: Any
        \\        field: MutableList<String> = ArrayList<String>()
        \\    fun usage(): Boolean = a.add("x")
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("items.^add(item)", "kotlin/collections/ArrayList.add");
    try fx.expectTarget("history.^add(", "kotlin/collections/ArrayList.add");
    try fx.expectTarget("a.^add(\"x\")", "kotlin/collections/MutableList.add");
}

test "type parameters with different bounds overload" {
    var fx = try fixture(&.{
        \\package demo
        \\interface A
        \\open class B : A
        \\open class C : A
        \\abstract class X {
        \\    fun <S1 : A> foo(s: S1): Int = 1
        \\    abstract fun <S2 : B> foo(s: S2): Int
        \\    abstract fun <S3 : C> foo(s: S3): Int
        \\}
        \\class Y : X() {
        \\    override fun <S4 : B> foo(s: S4): Int = 2
        \\    override fun <S5 : C> foo(s: S5): Int = 3
        \\}
        \\fun use(): Int = Y().foo(C())
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.ref("().^foo(C())");
    const tp = fx.s.syms.functionInfo(r.target).type_params[0];
    try std.testing.expectEqualStrings("S5", fx.s.str(fx.s.syms.name(tp)));
}

test "integer literals adopt the element type an expected array gives" {
    var fx = try fixture(&.{
        \\package demo
        \\class Sensor(val id: Short, val offset: Long, val samples: Array<Byte>)
        \\fun use(): Sensor = Sensor(7, 12, arrayOf(1, 2, 3))
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "members record what they override" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Shape { val name: String; fun area(): Int; fun scale(k: Int): Int = k }
        \\abstract class Base : Shape {
        \\    override fun area(): Int = 0
        \\    open fun scale(k: Long): Int = 1
        \\}
        \\class Square(override val name: String) : Base() {
        \\    override fun area(): Int = 4
        \\    override fun scale(k: Int): Int = 2
        \\}
        \\class Box<E> : ArrayList<E>() {
        \\    override fun get(index: Int): E = TODO()
        \\}
    });
    defer fx.deinit();
    const s = fx.s;
    try headers.resolveAllHeaders(s);
    const mem = struct {
        fn of(f: *Fixture, cls: []const u8, name: []const u8, nth: usize) sema_mod.Sym {
            const n = f.s.names.lookup(name).?;
            return sema_mod.scope.membersOf(f.s, f.class(cls), n)[nth];
        }
        fn id(f: *Fixture, sym: sema_mod.Sym) []const u8 {
            return render.callableId(f.s, f.arena.allocator(), sym) catch "?";
        }
    };
    // Square.area overrides Base.area, which overrides Shape.area.
    const sq_area = try sema_mod.members.overridden(s, mem.of(&fx, "demo.Square", "area", 0));
    try std.testing.expectEqual(@as(usize, 1), sq_area.len);
    try std.testing.expectEqualStrings("demo/Base.area", mem.id(&fx, sq_area[0]));
    const base_area = try sema_mod.members.overridden(s, mem.of(&fx, "demo.Base", "area", 0));
    try std.testing.expectEqualStrings("demo/Shape.area", mem.id(&fx, base_area[0]));
    // scale(Int) overrides the interface's, not Base's scale(Long).
    const sq_scale = try sema_mod.members.overridden(s, mem.of(&fx, "demo.Square", "scale", 0));
    try std.testing.expectEqual(@as(usize, 1), sq_scale.len);
    try std.testing.expectEqualStrings("demo/Shape.scale", mem.id(&fx, sq_scale[0]));
    try std.testing.expectEqual(@as(usize, 0), (try sema_mod.members.overridden(s, mem.of(&fx, "demo.Base", "scale", 0))).len);
    // A constructor property overrides the interface property.
    const name = try sema_mod.members.overridden(s, mem.of(&fx, "demo.Square", "name", 0));
    try std.testing.expectEqualStrings("demo/Shape.name", mem.id(&fx, name[0]));
    // Through generic supertypes: Box.get overrides ArrayList.get.
    const get = try sema_mod.members.overridden(s, mem.of(&fx, "demo.Box", "get", 0));
    try std.testing.expectEqualStrings("kotlin/collections/ArrayList.get", mem.id(&fx, get[0]));
}

test "a member overrides each member its class inherits alike from two supertypes" {
    var fx = try fixture(&.{
        \\package demo
        \\open class A<T> { open var size: T = TODO() }
        \\interface C { var size: Int }
        \\open class B : C, A<Int>()
        \\open class D : B() { override var size: Int = 117 }
    });
    defer fx.deinit();
    const s = fx.s;
    try headers.resolveAllHeaders(s);
    const n = s.names.lookup("size").?;
    const d_size = sema_mod.scope.membersOf(s, fx.class("demo.D"), n)[0];
    const roots = try sema_mod.members.overridden(s, d_size);
    try std.testing.expectEqual(@as(usize, 2), roots.len);
    var ids: [2][]const u8 = undefined;
    for (roots, &ids) |r, *id| id.* = try render.callableId(s, fx.arena.allocator(), r);
    std.mem.sort([]const u8, &ids, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    try std.testing.expectEqualStrings("demo/A.size", ids[0]);
    try std.testing.expectEqualStrings("demo/C.size", ids[1]);
}

test "a call's variable below a builder's variable is left to the builder" {
    var fx = try fixture(&.{
        \\package app
        \\class Scope<T> {
        \\    fun yield(x: T) {}
        \\    fun yieldAll(xs: List<T>) {}
        \\}
        \\fun <T> build(block: Scope<T>.() -> Unit): List<T> = TODO()
        \\fun <E> none(): List<E> = TODO()
        \\fun use() = build { yield(4); yieldAll(none()) }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const b = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("= ^build {", .call)).node);
    try std.testing.expectEqualStrings("kotlin.Int", fx.typeText(b.type_args[0]));
    const n = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("yieldAll(^none())", .call)).node);
    try std.testing.expectEqualStrings("kotlin.Int", fx.typeText(n.type_args[0]));
}

test "a value known null in one branch and not null in the other stays nullable after both" {
    var fx = try fixture(&.{
        \\package app
        \\fun use(counter: Int?): Int? {
        \\    val s = if (counter == null) "" else "_"
        \\    return counter
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    try std.testing.expectEqualStrings("kotlin.Int?", fx.typeText(out.files[3].typeOf(try fx.exprAt("return ^counter"))));
}

test "an expect class's defaults name the actual class's members" {
    var fx = try fixture(&.{
        \\package app
        \\class Config(val grace: Long)
        \\expect class Server {
        \\    val config: Config
        \\    fun stop(grace: Long = config.grace)
        \\}
        \\actual class Server {
        \\    actual val config: Config get() = Config(1L)
        \\    actual fun stop(grace: Long) {}
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.refAt("= ^config.grace", .read);
    const actual = fx.class("app.Server");
    try std.testing.expect(!fx.s.syms.flags(actual).expect);
    try std.testing.expectEqual(actual, fx.s.syms.owner(r.target));
}

test "klio is a default import below kotlin's" {
    var fx = try fixture(&.{
        \\package app
        \\fun use() = IllegalStateException("x")
    ,
        \\package klio
        \\open class IllegalStateException(message: String?) : Throwable()
    ,
        \\package kotlin
        \\open class IllegalStateException(message: String?) : Throwable()
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("= ^IllegalStateException(", .ctor, "kotlin/IllegalStateException.<init>");
}

test "an import that names nothing is reported though nothing uses it" {
    var fx = try fixture(&.{
        \\package app
        \\import kotlin.nothingHere
        \\class A
    });
    defer fx.deinit();
    try fx.resolve();
    try expectMessages(&fx, &.{"unresolved import `kotlin.nothingHere`"});
}

test "a raw is check infers each type argument the subject can give" {
    var fx = try fixture(&.{
        \\package app
        \\open class Pipeline<S : Any, C : Any>
        \\open class CallPipeline : Pipeline<Any, String>()
        \\open class Node : CallPipeline()
        \\interface Plugin<in P : Pipeline<*, String>, out B : Any, F : Any> {
        \\    fun install(pipeline: P, configure: B.() -> Unit): F
        \\}
        \\interface ScopedPlugin<B : Any, F : Any> : Plugin<CallPipeline, B, F>
        \\private fun <B : Any, F : Any> Node.installInto(plugin: ScopedPlugin<B, F>, configure: B.() -> Unit = {}): F = plugin.install(this, configure)
        \\fun <P : Pipeline<*, String>, B : Any, F : Any> P.install(plugin: Plugin<P, B, F>, configure: B.() -> Unit = {}): F {
        \\    if (this is Node && plugin is ScopedPlugin) { return installInto(plugin, configure) }
        \\    return plugin.install(this, configure)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("return ^installInto(", .call, "app/installInto");
}

test "the base layer numbers its symbols the same way whatever follows it" {
    var digests: [2]u64 = undefined;
    var counts: [2]u32 = undefined;
    const programs = [_][]const u8{
        \\package demo
        \\fun interface Action { fun run(x: Int): Int }
        \\fun use(): Int = Action { it }.run(1) + listOf({ a: Int, b: Int -> a }).size
    ,
        \\package other
        \\fun f(): Int = 1
    };
    for (programs, 0..) |p, k| {
        const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer {
            arena.deinit();
            std.testing.allocator.destroy(arena);
        }
        const a = arena.allocator();
        var map = span.SourceMap.init(a);
        var base: std.ArrayList(sema_mod.SourceFile) = .empty;
        try addSource(a, &map, &base, "mini/kotlin.kt", mini_kotlin, .base);
        try addSource(a, &map, &base, "mini/collections.kt", mini_collections, .base);
        try addSource(a, &map, &base, "mini/standard.kt", mini_standard, .base);
        var prog: std.ArrayList(sema_mod.SourceFile) = .empty;
        try addSource(a, &map, &prog, "test0.kt", p, .program);
        const s = try Sema.init(a);
        try s.addFiles(base.items);
        counts[k] = @intCast(s.syms.count());
        try s.addFiles(prog.items);
        try s.resolveBodies(&.{.program});
        digests[k] = s.prefixDigest(counts[k]);
        // Function classes exist before any body asks for one.
        try std.testing.expect(s.function_classes.count() > sema_mod.Sema.eager_arity);
    }
    try std.testing.expectEqual(counts[0], counts[1]);
    try std.testing.expectEqual(digests[0], digests[1]);
}

test "annotations resolve by identity" {
    var fx = try fixture(&.{
        \\package androidx.compose.runtime
        \\annotation class Composable
    ,
        \\package demo
        \\import androidx.compose.runtime.Composable as C
        \\annotation class Composable
        \\@C fun real() {}
        \\@Composable fun namesake() {}
        \\val content: @C () -> Unit = {}
        \\val plain: @Composable () -> Unit = {}
        \\val title: String @C get() = ""
    });
    defer fx.deinit();
    const s = fx.s;
    try headers.resolveAllHeaders(s);
    const pkg = s.syms.package_by_fqn.get(s.names.lookup("demo").?).?;
    const one = struct {
        fn of(f: *Fixture, p: sema_mod.Sym, name: []const u8) sema_mod.Sym {
            return sema_mod.scope.membersOf(f.s, p, f.s.names.lookup(name).?)[0];
        }
    };
    try std.testing.expect(s.syms.flags(one.of(&fx, pkg, "real")).composable);
    try std.testing.expect(!s.syms.flags(one.of(&fx, pkg, "namesake")).composable);
    try std.testing.expect(s.syms.flags(one.of(&fx, pkg, "title")).composable);
    const content = try headers.propertyType(s, one.of(&fx, pkg, "content"));
    const plain = try headers.propertyType(s, one.of(&fx, pkg, "plain"));
    try std.testing.expect(s.types.get(content).class.attrs.composable);
    try std.testing.expect(!s.types.get(plain).class.attrs.composable);
}

test "a bare callable reference binds the implicit receiver it goes through" {
    var fx = try fixture(&.{
        \\package demo
        \\class Host(val base: Int) {
        \\    fun member(): Int = base
        \\    fun refs(): Int {
        \\        val m = ::member
        \\        val d = ::describe
        \\        return m() + d()
        \\    }
        \\}
        \\fun Host.describe(): Int = base
        \\fun Int.twice(): Int = this * 2
        \\fun use(): Int = with(3) { (::twice)() }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const m = try fx.refAt("::^member", .ref);
    try std.testing.expectEqual(records.ImplicitKind.class_this, m.dispatch.implicit.kind);
    const d = try fx.refAt("::^describe", .ref);
    try std.testing.expect(d.dispatch == .none);
    try std.testing.expectEqual(records.ImplicitKind.class_this, d.extension.implicit.kind);
    const t = try fx.refAt("::^twice", .ref);
    try std.testing.expectEqual(records.ImplicitKind.lambda, t.extension.implicit.kind);
}

test "invoke on a call's result and a lambda assigned by index are resolved once" {
    var fx = try fixture(&.{
        \\package demo
        \\class Registry { operator fun set(k: String, v: (Int) -> Int) {} }
        \\fun adder(n: Int): (Int) -> Int = { it + n }
        \\fun use(r: Registry): Int {
        \\    r["k"] = { x -> x + 1 }
        \\    return adder(1)(2)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("^adder(1)(2)", .invoke, "kotlin/Function1.invoke");
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(std.testing.allocator);
    for (fx.s.refs.items) |r| {
        if (r.file != 3) continue;
        const key = (@as(u64, r.anchor.start) << 32) | @as(u64, @intFromEnum(r.kind));
        const gop = try seen.getOrPut(std.testing.allocator, key);
        if (gop.found_existing) {
            std.debug.print("duplicate {s} at {d}\n", .{ @tagName(r.kind), r.anchor.start });
            return error.TestUnexpectedResult;
        }
    }
}

test "a nested class ranks above a top-level class of the same name" {
    var fx = try fixture(&.{
        \\package demo
        \\class Wrong { fun tag(): Int = 0 }
        \\class Right { fun tag(): Int = 1 }
        \\open class Base { val p: Right = Right() }
        \\class Holder : Base()
        \\class Unrelated {
        \\    class Holder { val p = Wrong() }
        \\    fun nested(): Int = Holder().p.tag()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("= ^Holder().p", .ctor, "demo/Unrelated.Holder.<init>");
    try fx.expectTarget("p.^tag()", "demo/Wrong.tag");
}

test "a class gets the members it delegates with by" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Greeter { val tag: String; fun greet(name: String): String }
        \\class Plain : Greeter { override val tag = "p"; override fun greet(name: String) = name }
        \\class Wrapped(g: Greeter) : Greeter by g
        \\class Loud(g: Greeter) : Greeter by g { override fun greet(name: String) = name }
        \\class Names(xs: List<String>) : List<String> by xs
        \\fun use(w: Wrapped, l: Loud, n: Names): Int = w.greet("a").length + w.tag.length + l.tag.length + l.greet("b").length + n.get(0).length
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    try fx.expectTarget("w.^greet(", "demo/Wrapped.greet");
    try fx.expectTarget("w.^tag", "demo/Wrapped.tag");
    try fx.expectTarget("l.^tag", "demo/Loud.tag");
    try fx.expectTarget("l.^greet(", "demo/Loud.greet");
    const g = try fx.ref("w.^greet(");
    try std.testing.expect(s.syms.flags(g.target).synthetic);
    try std.testing.expectEqualStrings("demo/Greeter.greet", try render.callableId(s, fx.arena.allocator(), s.syms.functionInfo(g.target).forwards));
    // Seen through the delegated supertype's arguments: `get` returns String.
    try fx.expectTarget("n.^get(0)", "demo/Names.get");
    try fx.expectTarget("get(0).^length", "kotlin/String.length");
}

test "records and expression types are indexed by node" {
    var fx = try fixture(&.{
        \\package demo
        \\class Box(val n: Int) { operator fun get(i: Int): Int = n + i }
        \\data class P(val a: Int, val b: Int)
        \\fun use(b: Box, xs: List<Int>): Int {
        \\    var total = b[1] + b.n
        \\    for (x in xs) total += x
        \\    val (p, q) = P(1, 2)
        \\    val s = "$total and ${p + q}"
        \\    return if (s.length > 0 && xs.first() != null) total else -1
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const out = try sema_mod.output.build(s);
    try std.testing.expectEqual(@as(u32, 0), out.orphans);
    try std.testing.expectEqual(@as(u64, 0), s.census.count(.unrecorded));
    // Every record of the program is reachable through its node, and its
    // node's records are the ones anchored inside that node.
    const fr = &out.files[3];
    var n_refs: usize = 0;
    for (s.refs.items) |r| if (r.file == 3) {
        n_refs += 1;
        var found = false;
        for (fr.at(r.node)) |x| {
            if (x.anchor.start == r.anchor.start and x.kind == r.kind and x.target == r.target) found = true;
        }
        try std.testing.expect(found);
    };
    try std.testing.expectEqual(n_refs, fr.refs.len);
    // `b[1] + b.n`: the addition's node holds `plus`, and its type is Int.
    const plus = try fx.refAt("= ^b[1] + b.n", .op);
    try std.testing.expectEqualStrings("kotlin.Int", fx.typeText(fr.typeOf(plus.node)));
    // `for` holds iterator, hasNext and next on one node.
    const it = try fx.refAt("for (x in ^xs)", .iterator);
    try std.testing.expect(fr.one(it.node, .has_next) != null);
    try std.testing.expect(fr.one(it.node, .next) != null);
    // `$total` is its own node.
    const tot = try fx.refAt("\"^$total", .read);
    try std.testing.expectEqualStrings("kotlin.Int", fx.typeText(fr.typeOf(tot.node)));
}

test "an expression resolved without its record is reported" {
    var fx = try fixture(&.{
        \\package demo
        \\fun use(): Long = 1 + 2L
    });
    defer fx.deinit();
    try fx.resolve();
    // Drop the program's records, as a resolution that forgot to record
    // would leave them.
    var kept: std.ArrayList(records.Ref) = .empty;
    for (fx.s.refs.items) |r| if (r.file != 3) try kept.append(fx.arena.allocator(), r);
    fx.s.refs = kept;
    _ = try sema_mod.output.build(fx.s);
    try std.testing.expectEqual(@as(u64, 1), fx.s.census.count(.unrecorded));
}

test "equality and comparisons always record their operator" {
    var fx = try fixture(&.{
        \\package demo
        \\enum class Orientation { Vertical, Horizontal }
        \\class M(val o: Orientation) { val isVertical = o == Orientation.Vertical }
        \\fun even(x: Int): Boolean = x * 2 == 0
        \\fun cmp(v: Double, w: Long): Boolean = w > 0
        \\fun lam(xs: List<Int>): List<Boolean> = xs.map { it * 2 == 0 }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    _ = try sema_mod.output.build(fx.s);
    for (fx.s.census.sites.items) |site| if (site.reason == .unrecorded) {
        const src = fx.map.get(span.FileId.from(3)).source;
        std.debug.print("unrecorded at `{s}`\n", .{src[site.sp.start..site.sp.end]});
    };
    try std.testing.expectEqual(@as(u64, 0), fx.s.census.count(.unrecorded));
}

test "call records map each parameter to its operand" {
    var fx = try fixture(&.{
        \\package demo
        \\fun f(a: Int, b: String = "x", vararg rest: Int, flag: Boolean = false): Int = a
        \\fun <T> id(t: T): T = t
        \\open class Box<T>(val t: T)
        \\typealias IntBox = Box<Int>
        \\class Sub : Box<String>("s")
        \\fun interface Action { fun run(x: Int): Int }
        \\fun take(a: Action): Int = 1
        \\fun use(g: Int.(String) -> Int): Int {
        \\    f(1, "y", 2, 3, flag = true)
        \\    f(b = "z", a = 2)
        \\    id<String>("s")
        \\    id(1)
        \\    IntBox(3)
        \\    take { it }
        \\    3.g("s")
        \\    return 1 + id(2)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const out = try sema_mod.output.build(s);
    const fr = &out.files[3];
    const R = records;
    const callAt = struct {
        fn at(f: *Fixture, o: *const sema_mod.output.FileRecords, needle: []const u8, kind: R.RefKind) !R.CallRec {
            const r = try f.refAt(needle, kind);
            return sema_mod.output.call(f.s, o, r.node);
        }
    }.at;
    {
        const c = try callAt(&fx, fr, "^f(1, \"y\"", .call);
        try std.testing.expectEqual(R.CallForm.plain, c.form);
        try std.testing.expectEqual(@as(usize, 4), c.args.len);
        try std.testing.expectEqual(@as(u16, 0), c.args[0].arg);
        try std.testing.expectEqual(@as(u16, 1), c.args[1].arg);
        try std.testing.expectEqual(@as(usize, 2), c.args[2].vararg.len);
        try std.testing.expectEqual(@as(u16, 3), c.args[2].vararg[1].arg);
        try std.testing.expectEqual(@as(u16, 4), c.args[3].arg);
    }
    {
        const c = try callAt(&fx, fr, "^f(b = ", .call);
        try std.testing.expectEqual(@as(u16, 1), c.args[0].arg);
        try std.testing.expectEqual(@as(u16, 0), c.args[1].arg);
        try std.testing.expectEqual(@as(usize, 0), c.args[2].vararg.len);
        try std.testing.expect(c.args[3] == .default);
    }
    try std.testing.expectEqualStrings("kotlin.String", fx.typeText((try callAt(&fx, fr, "^id<String>", .call)).type_args[0]));
    try std.testing.expectEqualStrings("kotlin.Int", fx.typeText((try callAt(&fx, fr, "^id(1)", .call)).type_args[0]));
    {
        const c = try callAt(&fx, fr, "^IntBox(3)", .ctor);
        try std.testing.expectEqual(R.CallForm.ctor, c.form);
        try std.testing.expectEqualStrings("kotlin.Int", fx.typeText(c.type_args[0]));
    }
    {
        const c = try callAt(&fx, fr, ": ^Box<String>(\"s\")", .ctor);
        try std.testing.expectEqual(R.CallForm.super_delegation, c.form);
        try std.testing.expectEqualStrings("kotlin.String", fx.typeText(c.type_args[0]));
    }
    {
        const c = try callAt(&fx, fr, "^take {", .call);
        try std.testing.expectEqualStrings("Action", s.str(s.syms.name(c.conv[0].sam)));
    }
    {
        const c = try callAt(&fx, fr, "3.^g(", .invoke);
        try std.testing.expectEqual(R.CallForm.value_invoke, c.form);
        try std.testing.expect(c.args[0] == .receiver);
        try std.testing.expectEqual(@as(u16, 0), c.args[1].arg);
    }
    {
        const c = try callAt(&fx, fr, "return ^1 + id(2)", .op);
        try std.testing.expectEqual(@as(u16, 0), c.args[0].arg);
        try std.testing.expect(c.dispatch == .expr);
    }
}

test "this, returns, declarations, type tests, lambdas and groups have records" {
    var fx = try fixture(&.{
        \\package demo
        \\fun interface Action { fun run(x: Int): Int }
        \\class Box(var n: Int) { operator fun get(i: Int): Int = n; operator fun set(i: Int, v: Int) {} }
        \\class Outer {
        \\    val tag = 1
        \\    inner class In { fun t(): Int = this@Outer.tag + this.hashCode() }
        \\}
        \\fun use(a: Any, b: Box, xs: List<Int>): Int {
        \\    val local = 1
        \\    fun helper(x: Int): Int { return x }
        \\    val act = Action { it + local }
        \\    val sum = xs.map { v -> v * 2 }
        \\    for (x in xs) b[0] += x
        \\    b.n += 1
        \\    if (a is String) return a.length
        \\    val s = a as? Box
        \\    val o = object : Action { override fun run(x: Int): Int = x }
        \\    try { helper(1) } catch (e: Throwable) { }
        \\    when (val w = a) { is Int -> return w }
        \\    return helper(act.run(2)) + (sum.first())
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const out = try sema_mod.output.build(s);
    try std.testing.expectEqual(@as(u64, 0), s.census.count(.unrecorded));
    const fr = &out.files[3];
    const O = sema_mod.output;
    const R = records;
    {
        const r = try fx.refAt("^this@Outer", .this_);
        const rv = try O.recv(fr, r.node);
        try std.testing.expectEqual(R.ImplicitKind.class_this, rv.kind);
        try std.testing.expectEqualStrings("Outer", s.str(s.syms.name(rv.owner)));
    }
    {
        const r = try fx.refAt("{ ^return x }", .return_);
        try std.testing.expectEqualStrings("helper", s.str(s.syms.name(try O.returnTarget(fr, r.node))));
    }
    {
        const r = try fx.refAt("val ^local = 1", .decl);
        try std.testing.expectEqual(sema_mod.symbols.Kind.local, s.syms.kind(try O.decl(fr, r.node)));
    }
    {
        const r = try fx.refAt("^{ it + local }", .decl);
        const l = try O.lambda(fr, r.node);
        try std.testing.expect(l.it != .none);
        // `Action { }` is the SAM constructor; the lambda is its function.
        try std.testing.expectEqual(sema_mod.symbols.Sym.none, l.sam);
        const ctor = try fx.refAt("= ^Action {", .call);
        try std.testing.expectEqual(R.CallForm.sam_ctor, (try O.call(s, fr, ctor.node)).form);
        const m = try fx.refAt("^{ v -> v * 2 }", .decl);
        try std.testing.expectEqual(@as(usize, 1), (try O.lambda(fr, m.node)).params.len);
    }
    {
        const r = try fx.refAt("for (x in ^xs)", .iterator);
        const g = try O.forGroup(s, fr, r.node);
        try std.testing.expectEqualStrings("next", s.str(s.syms.name(g.next.callee)));
    }
    {
        const r = try fx.refAt("^b[0] += x", .get);
        const c = try O.compound(s, fr, r.node);
        try std.testing.expect(c.get != null and c.set != null);
        try std.testing.expectEqualStrings("plus", s.str(s.syms.name(c.op.callee)));
        const p = try fx.refAt("b.^n += 1", .read);
        const pc = try O.compound(s, fr, p.node);
        try std.testing.expect(pc.read != null and pc.write != null);
    }
    {
        const r = try fx.refAt("a is ^String", .type_test);
        const t = try O.typeTest(fr, r.node);
        try std.testing.expectEqual(R.TypeTestKind.is_, t.kind);
        const c = try fx.refAt("a as? ^Box", .type_test);
        try std.testing.expectEqual(R.TypeTestKind.as_safe, (try O.typeTest(fr, c.node)).kind);
        const k = try fx.refAt("(e: ^Throwable)", .type_test);
        const kt = try O.typeTest(fr, k.node);
        try std.testing.expectEqual(R.TypeTestKind.catch_, kt.kind);
        try std.testing.expect(kt.binding != .none);
    }
    {
        const r = try fx.refAt("when (val ^w = a)", .decl);
        const w = try O.decl(fr, r.node);
        try std.testing.expectEqual(sema_mod.symbols.Kind.local, s.syms.kind(w));
        try std.testing.expectEqualStrings("w", s.str(s.syms.name(w)));
    }
    {
        const r = try fx.refAt("= ^object : Action", .decl);
        try std.testing.expectEqual(sema_mod.symbols.Kind.class, s.syms.kind(try O.decl(fr, r.node)));
    }
}

test "a lambda is labeled by the function it is passed to, or by its own label" {
    var fx = try fixture(&.{
        \\package demo
        \\inline fun <T> Iterable<T>.each(action: (T) -> Unit) {}
        \\class Acc { var n = 0 }
        \\fun use(xs: List<Int>): Int {
        \\    xs.each { if (it < 0) return@each }
        \\    xs.each lit@{ if (it > 9) return@lit }
        \\    return Acc().apply { n = this@apply.n + 1 }.n
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const out = try sema_mod.output.build(s);
    try std.testing.expectEqual(@as(u64, 0), s.census.count(.unrecorded));
    const fr = &out.files[3];
    const r1 = try fx.refAt("^return@each", .return_);
    try std.testing.expectEqual(sema_mod.symbols.Kind.function, s.syms.kind(try sema_mod.output.returnTarget(fr, r1.node)));
    try std.testing.expectEqual(sema_mod.names.wk.anonymous, s.syms.name(try sema_mod.output.returnTarget(fr, r1.node)));
    _ = try fx.refAt("^return@lit", .return_);
    const t = try fx.refAt("^this@apply", .this_);
    try std.testing.expectEqual(records.ImplicitKind.lambda, (try sema_mod.output.recv(fr, t.node)).kind);
}

test "destructuring entries, loop variables and when patterns are found by position" {
    var fx = try fixture(&.{
        \\package demo
        \\data class P(val a: Int, val b: Int, val c: Int)
        \\fun use(p: P, xs: List<Int>, x: Any): Int {
        \\    val (first, _, third) = p
        \\    for (item in xs) {}
        \\    return when (x) { is String -> 1; 3 -> 2; else -> first + third }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const out = try sema_mod.output.build(s);
    const fr = &out.files[3];
    const O = sema_mod.output;
    const text = fx.map.get(span.FileId.from(3)).source;
    const at = struct {
        fn off(t: []const u8, needle: []const u8) u32 {
            return @intCast(std.mem.indexOf(u8, t, needle).?);
        }
    }.off;
    const node = (try fx.refAt("(^first, _", .decl)).node;
    const e0 = (try O.destructureEntry(s, fr, node, at(text, "first, _"))).?;
    try std.testing.expect(e0.local != .none and e0.call != null);
    try std.testing.expect((try O.destructureEntry(s, fr, node, at(text, "_, third"))) == null);
    try std.testing.expectEqualStrings("component3", s.str(s.syms.name((try O.destructureEntry(s, fr, node, at(text, "third) ="))).?.call.?.callee)));
    // `_` calls no component2.
    for (fr.at(node)) |r| if (r.kind == .component) try std.testing.expect(!std.mem.eql(u8, s.str(s.syms.name(r.target)), "component2"));
    const loop = try fx.refAt("for (^item", .decl);
    try std.testing.expectEqualStrings("item", s.str(s.syms.name(loop.target)));
    // Both patterns hang off the `when`'s node, found by their offsets.
    const w = (try fx.refAt("^is String", .type_test)).node;
    const is_pat = try O.whenPattern(s, fr, w, at(text, "is String"));
    try std.testing.expectEqual(records.TypeTestKind.is_, is_pat.type_test.kind);
    const eq_pat = try O.whenPattern(s, fr, w, at(text, "3 -> 2"));
    try std.testing.expectEqualStrings("equals", s.str(s.syms.name(eq_pat.equals.callee)));
}

test "callable references record their binding, type and adaptation" {
    var fx = try fixture(&.{
        \\package demo
        \\class Host(val base: Int) { fun add(x: Int): Int = base + x }
        \\fun scale(x: Int, k: Int = 2): Int = x * k
        \\fun run(f: (Int) -> Unit) {}
        \\fun use(h: Host): Int {
        \\    val bound = h::add
        \\    run(::scale)
        \\    return bound(1)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const out = try sema_mod.output.build(s);
    const fr = &out.files[3];
    const b = try sema_mod.output.ref(fr, (try fx.refAt("h::^add", .ref)).node);
    try std.testing.expect(b.bound == .expr);
    try std.testing.expectEqualStrings("kotlin.Function1<kotlin.Int, kotlin.Int>", fx.typeText(b.ty));
    const sc = try sema_mod.output.ref(fr, (try fx.refAt("run(::^scale)", .ref)).node);
    try std.testing.expectEqual(@as(u16, 1), sc.adapt.defaults);
    try std.testing.expect(sc.adapt.drop_result);
}

test "an inner class type written with its outer's arguments" {
    var fx = try fixture(&.{
        \\package demo
        \\class Outer<T> {
        \\    inner class Inner(val p: T)
        \\    typealias TAtoInner = Outer<String>.Inner
        \\}
        \\fun len(x: Outer<String>.Inner): Int = x.p.length
        \\fun viaAlias(o: Outer<String>, a: Outer.TAtoInner): Int = a.p.length
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("x.p.^length", "kotlin/String.length");
    try fx.expectTarget("a.p.^length", "kotlin/String.length");
}

test "each negation written with a folded !! token has its own anchor" {
    var fx = try fixture(&.{
        \\package demo
        \\fun odd(p: Boolean): Boolean = !!!!!p
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    var starts: std.ArrayList(u32) = .empty;
    defer starts.deinit(std.testing.allocator);
    for (fx.s.refs.items) |r| {
        if (r.file != 3 or r.kind != .op) continue;
        for (starts.items) |x| try std.testing.expect(x != r.anchor.start);
        try starts.append(std.testing.allocator, r.anchor.start);
    }
    try std.testing.expectEqual(@as(usize, 5), starts.items.len);
}

test "a member's type parameter bounded by its class's parameter sees the receiver's argument" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Cont<in T> {
        \\    fun <R : T> resume(value: R, onCancel: ((Throwable, R) -> Unit)?)
        \\}
        \\fun use(c: Cont<Int>) = c.resume(1) { _, v -> v + 1 }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("c.^resume(", "demo/Cont.resume");
}

test "a common supertype joins the arguments of a shared class by variance" {
    var fx = try fixture(&.{
        \\package demo
        \\open class Animal
        \\class Cat : Animal()
        \\class Dog : Animal()
        \\interface Flow<out T>
        \\fun <T> both(a: T, b: T): T = a
        \\fun <T> collect(xs: Array<out Flow<T>>): T = TODO()
        \\fun use(c: List<Cat>, d: List<Dog>, mc: MutableList<Cat>, md: MutableList<Dog>, fc: Flow<Cat>, fd: Flow<Dog>) {
        \\    val l = both(c, d)
        \\    val m = both(mc, md)
        \\    val a = collect(arrayOf(fc, fd))
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const out = try sema_mod.output.build(s);
    const fr = &out.files[3];
    const ty = struct {
        fn of(f: *Fixture, o: *const sema_mod.output.FileRecords, needle: []const u8) ![]const u8 {
            const r = try f.refAt(needle, .call);
            return f.typeText(o.typeOf(r.node));
        }
    }.of;
    try std.testing.expectEqualStrings("kotlin.collections.List<demo.Animal>", try ty(&fx, fr, "= ^both(c, d)"));
    try std.testing.expectEqualStrings("kotlin.collections.MutableList<out demo.Animal>", try ty(&fx, fr, "= ^both(mc, md)"));
    try std.testing.expectEqualStrings("demo.Animal", try ty(&fx, fr, "= ^collect("));
}

test "a low-priority overload yields to any other applicable candidate" {
    var fx = try fixture(&.{
        \\package demo
        \\import kotlin.internal.*
        \\class Date(val y: Int, val m: Int, val d: Int)
        \\@LowPriorityInOverloadResolution
        \\fun Date(y: Int, m: Int, d: Int): Date = Date(y = y, m = m, d = d)
        \\fun use(): Date = Date(2024, 1, 2)
    ,
        \\package kotlin.internal
        \\internal annotation class LowPriorityInOverloadResolution
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("= ^Date(2024", .ctor, "demo/Date.<init>");
}

test "a low-priority primary constructor yields to a function of its class's name" {
    var fx = try fixture(&.{
        \\package demo
        \\import kotlin.internal.*
        \\class MyString(val value: String)
        \\class Baz
        \\@LowPriorityInOverloadResolution
        \\constructor(val s: String) {
        \\    constructor(s: MyString): this(s.value)
        \\}
        \\fun Baz(s: String) = Baz(MyString(s + "!"))
        \\fun use() = Baz("hello")
    ,
        \\package kotlin.internal
        \\internal annotation class LowPriorityInOverloadResolution
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("= ^Baz(\"hello\")", .call, "demo/Baz");
}

test "a function reference is a KFunctionN: invocable, a FunctionN, and named" {
    var fx = try fixture(&.{
        \\package demo
        \\fun twice(x: Int): Int = x * 2
        \\fun apply(f: (Int) -> Int): Int = f(1)
        \\fun use(): Int {
        \\    val r = ::twice
        \\    return apply(::twice) + r(3) + r.name.length
        \\}
    ,
        \\package kotlin.reflect
        \\public interface KCallable<out R> { public val name: String }
        \\public interface KFunction<out R> : KCallable<R>, Function<R>
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const out = try sema_mod.output.build(s);
    const r = try sema_mod.output.ref(&out.files[3], (try fx.refAt("val r = ::^twice", .ref)).node);
    try std.testing.expectEqualStrings("kotlin.reflect.KFunction1<kotlin.Int, kotlin.Int>", fx.typeText(r.ty));
    try fx.expectRef("r.^name", .read, "kotlin/reflect/KCallable.name");
    try fx.expectRef("^r(3)", .invoke, "kotlin/Function1.invoke");
}

test "a lambda's result is analyzed against what the call already fixes" {
    var fx = try fixture(&.{
        \\package demo
        \\fun <T> nulls(n: Int): Array<T?> = TODO()
        \\fun <T> combine(xs: List<T>, factory: () -> Array<T?>?): T = TODO()
        \\fun use(xs: List<String>): String = combine(xs, { nulls(xs.size) })
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "an actual may add inline to its expect but not drop it" {
    var fx = try fixture(&.{
        \\package demo
        \\expect fun plain(): Int
        \\actual inline fun plain(): Int = 1
        \\expect inline fun marked(): Int
        \\actual fun marked(): Int = 2
    });
    defer fx.deinit();
    try std.testing.expectEqual(@as(u64, 1), fx.s.census.count(.expect_actual_mismatch));
    const site = for (fx.s.census.sites.items) |site| {
        if (site.reason == .expect_actual_mismatch) break site;
    } else unreachable;
    try std.testing.expect(std.mem.startsWith(u8, site.detail, "marked"));
}

test "a cast smart-casts its subject for the rest of the block" {
    var fx = try fixture(&.{
        \\package demo
        \\class Emitter(val cont: Int)
        \\fun use(e: Any): Int {
        \\    e as Emitter
        \\    return e.cont
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("e.^cont", "demo/Emitter.cont");
}

test "an integer literal branch joins an integral branch it fits" {
    var fx = try fixture(&.{
        \\package demo
        \\const val BIT = 1L
        \\fun flag(c: Boolean, n: Long): Long = (if (c) BIT else 0) + n
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    // `plus` resolved on a `Long` receiver: the `if` is a `Long`.
    for (fx.s.refs.items) |r| if (r.file == 3 and r.kind == .op) {
        try std.testing.expectEqualStrings("kotlin/Long.plus", try render.callableId(fx.s, fx.arena.allocator(), r.target));
    };
}

test "overloads chosen by the lambda's result type" {
    var fx = try fixture(&.{
        \\package demo
        \\@OverloadResolutionByLambdaReturnType
        \\fun String.replaceFirst(transform: (Int) -> Int): String = this
        \\@OverloadResolutionByLambdaReturnType
        \\fun String.replaceFirst(transform: (Int) -> CharSequence): String = this
        \\fun cap(s: String): String = s.replaceFirst { if (it > 0) "a" else it.toString() }
    ,
        \\package kotlin
        \\public annotation class OverloadResolutionByLambdaReturnType
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.ref("s.^replaceFirst {");
    const p = fx.s.syms.functionInfo(r.target).params[0];
    try std.testing.expectEqualStrings("kotlin.Function1<kotlin.Int, kotlin.CharSequence>", fx.typeText(try headers.paramType(fx.s, p)));
}

test "a call used as a receiver completes on its own inside an argument" {
    var fx = try fixture(&.{
        \\package demo
        \\class Pair<out A, out B>(val first: A, val second: B)
        \\infix fun <A, B> A.to(that: B): Pair<A, B> = Pair(this, that)
        \\fun <K, V> Iterable<Pair<K, V>>.toMap(): Map<K, V> = TODO()
        \\fun <T> keep(x: T): T = x
        \\fun show(x: Any?): Int = 1
        \\fun use(): Int = show(listOf("a" to 1, "b" to 2).toMap())
        \\fun nested(): Int = keep(listOf("a" to 1)).first().second + 1
        \\fun literal(): Int = show(listOf(1).first().times(2))
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget(").^toMap()", "demo/toMap");
    try fx.expectTarget("first().^times(2)", "kotlin/Int.times");
    try fx.expectRef("^keep(listOf(\"a\" to 1)).first().second + 1", .op, "kotlin/Int.plus");
}

test "super names a supertype's inner class constructor" {
    var fx = try fixture(&.{
        \\package demo
        \\open class A(val value: String) {
        \\    inner class B(val s: String) { val result: String = value }
        \\}
        \\class C : A("c") {
        \\    fun viaSuper() = super.B("y")
        \\}
        \\fun use(c: C): Int = c.viaSuper().result.length
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("super.^B(", .ctor, "demo/A.B.<init>");
}

test "an expression of extension-function type invoked takes an implicit receiver" {
    var fx = try fixture(&.{
        \\package demo
        \\class Scope { fun onDraw(): String = "" }
        \\class Node {
        \\    var block: (Scope.() -> String)? = null
        \\    val scope = Scope()
        \\    fun direct(): Scope = scope.apply { block!!() }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.refAt("{ ^block!!() }", .invoke);
    try std.testing.expect(r.extension == .implicit);
}

test "an enum class that names interfaces still extends Enum" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Shape
        \\enum class Kind : Shape { A, B }
        \\fun <T : Enum<T>> pick(values: Array<T>): T = TODO()
        \\fun use(): Int = pick(Kind.values()).name.length
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("= ^pick(", "demo/pick");
    try fx.expectTarget(".^name.length", "kotlin/Enum.name");
}

test "a member typed before its class body reaches it sees the scope the class resolves in" {
    var fx = try fixture(&.{
        \\package demo
        \\fun show(x: Any?): Int = 1
        \\fun use(): Int {
        \\    val discount = 5
        \\    val audit = object {
        \\        init { show(opened) }
        \\        val opened = discount + 1
        \\    }
        \\    var count = 0
        \\    class Tracked(val label: String, seed: Int) {
        \\        init { show(doubled + twice()) }
        \\        val doubled = count * seed
        \\        fun twice() = count * 2
        \\    }
        \\    return Tracked("a", 2).twice()
        \\}
        \\class Top(seed: Int) {
        \\    init { show(y) }
        \\    val y = seed + 1
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const d = try fx.refAt("= ^discount + 1", .read);
    try std.testing.expectEqual(sema_mod.symbols.Kind.local, fx.s.syms.kind(d.target));
}

test "callable references bind objects and implicit receivers and fit the expected type" {
    var fx = try fixture(&.{
        \\package demo
        \\object Truth { fun test(v: Any?): Boolean = true }
        \\class Host(val name: String) {
        \\    fun member(): String = name
        \\    fun refs(): Int {
        \\        val m = ::member
        \\        val d = ::describe
        \\        return m().length + d().length
        \\    }
        \\}
        \\fun Host.describe(): String = name
        \\sealed class P
        \\class PN(val n: Int) : P()
        \\class PS(val s: String) : P()
        \\fun P(value: Int?): P = PN(0)
        \\fun P(value: String?): P = PS("")
        \\fun use(): Boolean {
        \\    val t = Truth::test
        \\    val ps = listOf("a").map(::P)
        \\    return t(ps)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    try fx.expectRef("^Truth::test", .object, "demo/Truth");
    // Bound to the object as an implicit receiver, in the record too.
    const t = try fx.refAt("Truth::^test", .ref);
    try std.testing.expect(t.dispatch == .implicit and t.dispatch.implicit.kind == .object);
    try std.testing.expect(t.detail.ref.bound == .implicit and t.detail.ref.bound.implicit.kind == .object);
    const m = try fx.refAt("::^member", .ref);
    try std.testing.expect(m.dispatch == .implicit);
    const d = try fx.refAt("::^describe", .ref);
    try std.testing.expect(d.extension == .implicit);
    const p = try fx.refAt("map(::^P)", .ref);
    try std.testing.expectEqualStrings("kotlin.String?", fx.typeText(try headers.paramType(s, s.syms.functionInfo(p.target).params[0])));
}

test "a reference or lambda passed for a fun interface must fit its method" {
    var fx = try fixture(&.{
        \\package demo
        \\fun interface Cmp<T> { fun compare(a: T, b: T): Int }
        \\class Event(val time: Int, val count: Int)
        \\fun <T> pick(a: T, b: T, vararg selectors: (T) -> Any?): Int = 1
        \\fun <T, K> pick(a: T, b: T, cmp: Cmp<in K>, selector: (T) -> K): Int = 2
        \\fun byRef(): Int = pick(Event(1, 2), Event(2, 3), Event::time, Event::count)
        \\fun byLambda(): Int = pick(Event(1, 2), Event(2, 3), { it.time }, { it.count })
        \\fun bySam(): Int = pick(Event(1, 2), Event(2, 3), Cmp<Int> { a, b -> 0 }, Event::count)
    ,
        \\package kotlin.reflect
        \\public interface KProperty<out V>
        \\public interface KProperty0<out V> : KProperty<V>, () -> V
        \\public interface KProperty1<T, out V> : KProperty<V>, (T) -> V
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const r = try fx.ref("= ^pick(Event(1, 2), Event(2, 3), Event::time");
    try std.testing.expect(s.syms.flags(s.syms.functionInfo(r.target).params[2]).vararg);
    const l = try fx.ref("= ^pick(Event(1, 2), Event(2, 3), { it.time }");
    try std.testing.expect(s.syms.flags(s.syms.functionInfo(l.target).params[2]).vararg);
    const c = try fx.ref("= ^pick(Event(1, 2), Event(2, 3), Cmp");
    try std.testing.expectEqual(@as(usize, 4), s.syms.functionInfo(c.target).params.len);
}

test "callable reference arguments adapt to defaults, varargs and a Unit result" {
    var fx = try fixture(&.{
        \\package demo
        \\fun greet(name: String, punctuation: String = "!"): String = name
        \\fun join(vararg parts: String, separator: String = "-"): String = separator
        \\fun useOne(f: (String) -> String): String = f("hi")
        \\fun useNone(f: () -> String): String = f()
        \\fun useTwo(f: (String, String) -> String): String = f("a", "b")
        \\fun useArray(f: (Array<String>) -> String): String = TODO()
        \\fun run(f: () -> Unit) {}
        \\fun use() {
        \\    useOne(::greet)
        \\    useNone(::join)
        \\    useTwo(::join)
        \\    useArray(::join)
        \\    fun bump(by: Int = 5): Int { return by }
        \\    run(::bump)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a lambda is labeled by the call it is passed to or its own label" {
    var fx = try fixture(&.{
        \\package demo
        \\class Report(val title: String)
        \\class Builder(val report: Report)
        \\fun build(block: Builder.() -> Unit): Unit = Builder(Report("q")).block()
        \\interface Named { val name: String }
        \\fun use(r: Report) {
        \\    build {
        \\        val named = object : Named {
        \\            override val name: String get() = this@build.report.title
        \\        }
        \\    }
        \\    with(r, outer@{ this@outer.title })
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("this@build.^report", "demo/Builder.report");
    try fx.expectTarget("this@outer.^title", "demo/Report.title");
}

test "a lambda whose result jumps infers Nothing" {
    var fx = try fixture(&.{
        \\package demo
        \\fun <R> call(block: () -> R): R = block()
        \\fun use(): Int {
        \\    fun inner(): Int {
        \\        call { if (true) return@inner 7 else return@inner 8 }
        \\        return 0
        \\    }
        \\    return inner()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a member's type parameter bound sees the receiver's type arguments" {
    var fx = try fixture(&.{
        \\package demo
        \\abstract class Base
        \\open class Open : Base()
        \\class Builder<B : Any> {
        \\    fun <T : B> sub(): Int = 1
        \\    fun <T : B> pass(t: T): T = t
        \\}
        \\fun use(b: Builder<Base>): Int = b.sub<Open>()
        \\fun infer(b: Builder<Base>): Open = b.pass(Open())
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("b.^sub<Open>()", "demo/Builder.sub");
}

test "a common supertype joins type arguments" {
    var fx = try fixture(&.{
        \\package demo
        \\open class Animal
        \\class Cat : Animal()
        \\class Dog : Animal()
        \\interface Ser<T>
        \\class Str : Ser<String>
        \\val cats: List<Cat> = TODO()
        \\val dogs: List<Dog> = TODO()
        \\val mcats: MutableList<Cat> = TODO()
        \\val mdogs: MutableList<Dog> = TODO()
        \\val str: Str = TODO()
        \\val anySer: Ser<*> = TODO()
    });
    defer fx.deinit();
    const s = fx.s;
    try headers.resolveAllHeaders(s);
    const prop = struct {
        fn ty(f: *Fixture, name: []const u8) !sema_mod.TypeId {
            const pkg = f.s.syms.package_by_fqn.get(f.s.names.lookup("demo").?).?;
            const sym = sema_mod.scope.membersOf(f.s, pkg, f.s.names.lookup(name).?)[0];
            return headers.propertyType(f.s, sym);
        }
    }.ty;
    try std.testing.expectEqualStrings("kotlin.collections.List<demo.Animal>", fx.typeText(try subtyping.commonSupertype(s, &.{ try prop(&fx, "cats"), try prop(&fx, "dogs") })));
    try std.testing.expectEqualStrings("kotlin.collections.MutableList<out demo.Animal>", fx.typeText(try subtyping.commonSupertype(s, &.{ try prop(&fx, "mcats"), try prop(&fx, "mdogs") })));
    try std.testing.expectEqualStrings("demo.Ser<*>", fx.typeText(try subtyping.commonSupertype(s, &.{ try prop(&fx, "str"), try prop(&fx, "anySer") })));
}

test "a low-priority overload yields to another applicable candidate" {
    var fx = try fixture(&.{
        \\package demo
        \\import kotlin.internal.*
        \\class Stamp(val y: Int, val m: Int)
        \\@LowPriorityInOverloadResolution
        \\fun Stamp(y: Int, monthNumber: Int): Stamp = Stamp(y, monthNumber)
        \\@LowPriorityInOverloadResolution
        \\fun only(x: Int): Int = x
        \\fun use(): Int = Stamp(1, 2).y + only(3)
    ,
        \\package kotlin.internal
        \\internal annotation class LowPriorityInOverloadResolution
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("= ^Stamp(1, 2)", .ctor, "demo/Stamp.<init>");
    try fx.expectTarget("^only(3)", "demo/only");
}

test "an indexed assignment's value binds to set's last parameter" {
    var fx = try fixture(&.{
        \\package demo
        \\class Table {
        \\    operator fun get(name: String, width: Int = 8): String = name
        \\    operator fun set(name: String, sep: String = ":", value: String) {}
        \\}
        \\object Grid {
        \\    operator fun get(vararg idx: Int): Int = 0
        \\    operator fun set(vararg idx: Int, value: Int) {}
        \\}
        \\fun use(t: Table) {
        \\    t["k"] = "v"
        \\    t["k"] += "v"
        \\    Grid[1, 2, 3] = 4
        \\    Grid[1, 2] += 1
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("t[\"k\"] = \"v\"", .set, "demo/Table.set");
    try fx.expectRef("Grid[1, 2, 3] = 4", .set, "demo/Grid.set");
}

test "an actual takes its expect's parameter defaults" {
    var fx = try fixture(&.{
        \\package demo
        \\expect fun make(x: Int, y: Int = 2): Int
        \\actual fun make(x: Int, y: Int): Int = x
        \\expect class Box(v: Int = 0) {
        \\    fun get(k: Int = 1): Int
        \\}
        \\actual class Box actual constructor(v: Int) {
        \\    actual fun get(k: Int): Int = k
        \\}
        \\fun use(): Int = make(1) + Box().get()
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const m = try fx.refAt("= ^make(1)", .call);
    try std.testing.expect(fx.s.syms.flags(m.target).actual);
}

test "a declaration deprecated as hidden is never a candidate" {
    var fx = try fixture(&.{
        \\package demo
        \\@Deprecated("use the other", level = DeprecationLevel.HIDDEN)
        \\fun para(text: String, ellipsis: Boolean = false): Int = 1
        \\fun para(text: String, overflow: Int = 0): Int = 2
        \\class Box {
        \\    @Deprecated("use the other", level = DeprecationLevel.HIDDEN)
        \\    constructor(a: Int, b: Boolean = false)
        \\    constructor(a: Int, c: Int = 0)
        \\}
        \\@other.Deprecated("a namesake", level = HIDDEN)
        \\fun kept(x: Int): Int = x
        \\fun use(): Int {
        \\    Box(1)
        \\    return para("t") + kept(1)
        \\}
    ,
        \\package kotlin
        \\public enum class DeprecationLevel { WARNING, ERROR, HIDDEN }
        \\public annotation class Deprecated(val message: String, val level: DeprecationLevel = DeprecationLevel.WARNING)
    ,
        \\package other
        \\annotation class Deprecated(val message: String, val level: Int = 0)
        \\const val HIDDEN: Int = 2
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const p = try fx.refAt("^para(\"t\")", .call);
    try std.testing.expect(!s.syms.flags(p.target).hidden);
    const b = try fx.refAt("^Box(1)", .ctor);
    try std.testing.expect(!s.syms.flags(b.target).hidden);
}

test "a generic call in argument position is inferred with the parameter it is passed to" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Ser<T>
        \\class Str : Ser<String>
        \\class Ctx<T : Any>(val k: Int, val fallback: Ser<T>?, val args: Array<Ser<*>>)
        \\fun take(a: Array<Ser<*>>): Int = 1
        \\fun show(x: Int): Int = 1
        \\fun show(x: Any?): Int = 2
        \\fun use(): Ctx<String> = Ctx(1, null, arrayOf(Str()))
        \\fun direct(): Int = take(arrayOf(Str())) + show(listOf("a").map { it.length })
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const sh = try fx.refAt("^show(listOf", .call);
    try std.testing.expectEqualStrings("kotlin.Any?", fx.typeText(try headers.paramType(s, s.syms.functionInfo(sh.target).params[0])));
    // The nested call's record holds its type argument as the enclosing
    // call fixed it.
    const out = try sema_mod.output.build(s);
    const inner = try sema_mod.output.call(s, &out.files[3], (try fx.refAt("take(^arrayOf(", .call)).node);
    try std.testing.expectEqualStrings("demo.Ser<*>", fx.typeText(inner.type_args[0]));
}

test "an elvis takes its left side's non-null part, in an argument or a local" {
    var fx = try fixture(&.{
        \\package demo
        \\fun <T> MutableList<T>.removeLastOrNull(): T? = TODO()
        \\fun <T> Array<out T>.getOrNull(index: Int): T? = TODO()
        \\class State(val position: Int)
        \\fun take(s: String): Int = 1
        \\fun loop(options: MutableList<State>, names: Array<String?>): Int {
        \\    while (true) {
        \\        val state = options.removeLastOrNull() ?: break
        \\        val name = names.getOrNull(0) ?: "x"
        \\        return state.position + take(name) + take(names.getOrNull(1) ?: "y")
        \\    }
        \\    return 0
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("state.^position", "demo/State.position");
}

test "a builder's type argument is inferred from the calls in its lambda" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Scope<T> { fun send(x: T) }
        \\fun <T> build(block: Scope<T>.() -> Unit): List<T> = TODO()
        \\fun direct(): Int = build { send(1); send(2) }.first() + 1
        \\fun nested(): Int = build { run { send("a") } }.first().length
        \\class Cont<T>
        \\fun <T> suspendIt(block: (Cont<T>) -> Unit): T = TODO()
        \\fun viaAssign(): Int {
        \\    var saved: Cont<Int>? = null
        \\    val v = suspendIt { c -> saved = c }
        \\    return v + 1
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("^build { send(1)", .op, "kotlin/Int.plus");
    try fx.expectTarget("first().^length", "kotlin/String.length");
    try fx.expectRef("return ^v + 1", .op, "kotlin/Int.plus");
}

test "an actual's omitted argument takes its expect's default, resolved in the expect's scope" {
    var fx = try fixture(&.{
        \\package demo
        \\val base = 2
        \\expect fun make(x: Int, y: Int = base + 1): Int
        \\actual fun make(x: Int, y: Int): Int = x + y
        \\expect class Box(n: Int = base) { fun get(k: Int = base): Int }
        \\actual class Box actual constructor(val n: Int) { actual fun get(k: Int): Int = n + k }
        \\fun use(): Int = make(1) + Box().get()
    });
    defer fx.deinit();
    try fx.resolve();
    try std.testing.expectEqual(@as(u64, 0), fx.s.census.count(.no_applicable));
    const s = fx.s;
    const r = try fx.refAt("= ^make(1)", .call);
    const p = s.syms.functionInfo(r.target).params[1];
    const from = s.syms.paramInfo(p).default_from;
    try std.testing.expect(from != .none);
    // The expect's default expression was resolved: `base` and `+` have records.
    try fx.expectRef("y: Int = ^base + 1", .read, "demo/base");
    try fx.expectRef("y: Int = ^base + 1", .op, "kotlin/Int.plus");
    // Expect class member and constructor defaults resolve too.
    try fx.expectRef("fun get(k: Int = ^base)", .read, "demo/base");
    try fx.expectRef("class Box(n: Int = ^base)", .read, "demo/base");
    const g = try fx.refAt("Box().^get()", .call);
    try std.testing.expect(s.syms.paramInfo(s.syms.functionInfo(g.target).params[0]).default_from != .none);
}

test "the expected type reaches a generic call through !!" {
    var fx = try fixture(&.{
        \\package demo
        \\inline fun <reified R> restore(v: Any?): R? = v as R?
        \\fun restored(x: Any?): Int {
        \\    val s: String = restore(x)!!
        \\    return s.length
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a spread argument is not applicable to a parameter that is not a vararg" {
    var fx = try fixture(&.{
        \\package demo
        \\fun <T> remember2(key1: Any?, calculation: () -> T): T = calculation()
        \\fun <T> remember2(vararg keys: Any?, calculation: () -> T): T = calculation()
        \\fun effect(vararg keys: Any?): Int = remember2(*keys) { 1 }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.refAt("= ^remember2(*keys)", .call);
    try std.testing.expect(fx.s.syms.flags(fx.s.syms.functionInfo(r.target).params[0]).vararg);
}

test "a lambda prefers the function-type overload to the SAM-converted one" {
    var fx = try fixture(&.{
        \\package demo
        \\class Scope
        \\fun interface Handler { suspend fun Scope.invoke() }
        \\fun String.input(key1: Any?, block: suspend Scope.() -> Unit): String = "lambda"
        \\fun String.input(key1: Any?, block: Handler): String = "sam"
        \\fun callInput(): String = "x".input(Unit) { }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.refAt("\"x\".^input(Unit)", .call);
    const p = fx.s.syms.functionInfo(r.target).params[1];
    try std.testing.expectEqualStrings("kotlin.coroutines.SuspendFunction1<demo.Scope, kotlin.Unit>", fx.typeText(try sema_mod.headers.paramType(fx.s, p)));
}

test "an unqualified super call takes the superclass's override over Any's through an interface" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Data
        \\abstract class Base { override fun toString(): String = "base" }
        \\class Table : Base(), Data, Iterable<Int> {
        \\    override fun iterator(): Iterator<Int> = emptyList<Int>().iterator()
        \\    fun debug(): String = super.toString()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("super.^toString()", .call, "demo/Base.toString");
}

test "a property of extension-function type invoked bare takes an implicit receiver" {
    var fx = try fixture(&.{
        \\package demo
        \\class Scope { val tag = "s" }
        \\class Holder(val builder: Scope.(String) -> Unit) {
        \\    fun run(scope: Scope) = with(scope) { builder("x") }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.refAt("{ ^builder(\"x\") }", .invoke);
    const O = sema_mod.output;
    const out = try O.build(fx.s);
    const c = try O.call(fx.s, &out.files[out.files.len - 1], r.node);
    try std.testing.expect(c.args[0] == .receiver);
}

test "klio and kotlin.jvm are imported by default" {
    var fx = try fixture(&.{
        \\package demo
        \\object O { @JvmStatic fun f() {} }
        \\fun use() { Thread().start() }
    ,
        \\package klio
        \\class Thread { fun start() {} }
    ,
        \\package kotlin.jvm
        \\annotation class JvmStatic
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("^Thread().start()", .ctor, "klio/Thread.<init>");
}

test "smart casts follow the data flow: assignments, branch merges, elvis jumps and safe chains" {
    var fx = try fixture(&.{
        \\package demo
        \\class Bitmap(val width: Int)
        \\class Canvas(val bitmap: Bitmap)
        \\class Content(val contentType: String?)
        \\sealed class Focus {
        \\    class Ring(val outer: Int) : Focus()
        \\    object None : Focus()
        \\}
        \\class Config(val focus: Focus)
        \\fun need(b: Bitmap): Int = b.width
        \\fun send(c: Content): Int = 1
        \\fun draw(w: Int, start: Bitmap?, canvas: Canvas?): Int {
        \\    var target = start
        \\    var tc = canvas
        \\    if (target == null || tc == null || w > target.width) {
        \\        target = Bitmap(w)
        \\        tc = Canvas(target)
        \\    }
        \\    return need(target) + need(tc.bitmap)
        \\}
        \\fun assigned(): Int {
        \\    var b: Bitmap? = null
        \\    if (b == null) b = Bitmap(1)
        \\    return b.width
        \\}
        \\fun elvis(x: Bitmap?): Int {
        \\    x ?: return 0
        \\    return x.width
        \\}
        \\fun chain(c: Content?): Int = if (c?.contentType != null) send(c) else 0
        \\fun inLet(b: Bitmap?): Int? = b?.let { need(b) }
        \\fun ring(c: Config?): Int = if (c?.focus is Focus.Ring) c.focus.outer else 0
        \\fun reassigned(): Int {
        \\    var a: Any = "s"
        \\    a = 1
        \\    return a.plus(1)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a smart cast from one branch does not survive a merge with a branch that undoes it" {
    var fx = try fixture(&.{
        \\package demo
        \\class Bitmap(val width: Int)
        \\fun pick(b: Bitmap): Int = 1
        \\fun pick(b: Bitmap?): Int = 2
        \\fun f(flag: Boolean, x: Bitmap?): Int {
        \\    var b = x
        \\    if (flag) { b = Bitmap(1) } else { b = null }
        \\    return pick(b)
        \\}
        \\fun g(flag: Boolean, x: Bitmap?): Int {
        \\    var b = x
        \\    if (flag) b = Bitmap(1) else b = Bitmap(2)
        \\    return pick(b)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    // `b` may be null after the first merge, and is not after the second.
    const f = try fx.refAt("return ^pick(b)", .call);
    try std.testing.expectEqualStrings("demo.Bitmap?", fx.typeText(try sema_mod.headers.paramType(s, s.syms.functionInfo(f.target).params[0])));
    const text = fx.programText();
    const second = std.mem.lastIndexOf(u8, text, "pick(b)").?;
    for (s.refs.items) |r| {
        if (r.file != 3 or r.anchor.start != second or r.kind != .call) continue;
        try std.testing.expectEqualStrings("demo.Bitmap", fx.typeText(try sema_mod.headers.paramType(s, s.syms.functionInfo(r.target).params[0])));
    }
}

test "a call's contract smart-casts its arguments" {
    var fx = try fixture(&.{
        \\package demo
        \\fun pick(x: String): Int = 1
        \\fun pick(x: String?): Int = 2
        \\fun pick(x: Any): Int = 3
        \\fun a(s: String?): Int {
        \\    if (!s.isNullOrEmpty()) return pick(s)
        \\    return 0
        \\}
        \\fun b(s: String?): Int {
        \\    requireNotNull(s)
        \\    return pick(s)
        \\}
        \\fun c(s: Any): Int {
        \\    require(s is String && s.length > 0) { "not a string" }
        \\    return pick(s)
        \\}
        \\fun d(s: Any): Int {
        \\    check(s is String)
        \\    return pick(s)
        \\}
    ,
        \\package demo
        \\fun CharSequence?.isNullOrEmpty(): Boolean {
        \\    contract { returns(false) implies (this@isNullOrEmpty != null) }
        \\    return this == null || this.length == 0
        \\}
        \\fun <T : Any> requireNotNull(value: T?): T {
        \\    contract { returns() implies (value != null) }
        \\    return value!!
        \\}
        \\inline fun require(value: Boolean, lazyMessage: () -> Any) {
        \\    contract { returns() implies value }
        \\}
        \\fun check(value: Boolean) {
        \\    contract { returns() implies value }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    var n: usize = 0;
    for (s.refs.items) |r| {
        if (r.file != 3 or r.kind != .call) continue;
        if (!std.mem.eql(u8, s.str(s.syms.name(r.target)), "pick")) continue;
        try std.testing.expectEqualStrings("kotlin.String", fx.typeText(try sema_mod.headers.paramType(s, s.syms.functionInfo(r.target).params[0])));
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), n);
}

test "a cast to a generic class written bare takes its arguments from the operand" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Holder<T> { fun get(): T }
        \\class Box<T>(val v: T) : Holder<T> {
        \\    override fun get(): T = v
        \\    fun rewrap(r: List<T>): T = r[0]
        \\}
        \\fun <T> reopen(h: Holder<T>, r: List<T>): T = (h as Box).rewrap(r)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a try's catch result joins with its body's" {
    var fx = try fixture(&.{
        \\package demo
        \\class Uncompleted : Throwable()
        \\fun cleanup(): List<Throwable> = listOf(Throwable())
        \\fun report(rest: List<Throwable>): Int = rest.size
        \\fun use(): Int {
        \\    val exceptions = try { cleanup() } catch (_: Uncompleted) { emptyList() }
        \\    return report(exceptions)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a class name on the left of :: names its companion's member, bound to the companion" {
    var fx = try fixture(&.{
        \\package demo
        \\class Names(val names: List<String>) {
        \\    companion object {
        \\        val FULL = Names(listOf("a", "b"))
        \\        fun parse(s: String): Names = Names(listOf(s))
        \\    }
        \\}
        \\fun <T> apply(s: String, f: (String) -> T): T = f(s)
        \\fun use(): Names {
        \\    val full = Names::FULL
        \\    return apply("x", Names::parse)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    try fx.expectRef("Names::^FULL", .ref, "demo/Names.Companion.FULL");
    try fx.expectRef("apply(\"x\", Names::^parse)", .ref, "demo/Names.Companion.parse");
    const o = try fx.refAt("apply(\"x\", ^Names::parse)", .object);
    try std.testing.expectEqualStrings("Companion", s.str(s.syms.name(o.target)));
}

test "a delegate is inferred with its property's declared type" {
    var fx = try fixture(&.{
        \\package demo
        \\class Holder<T>(var value: T) {
        \\    operator fun getValue(thisRef: Any?, p: Any?): T = value
        \\    operator fun setValue(thisRef: Any?, p: Any?, v: T) { value = v }
        \\}
        \\fun <T> holder(initial: T): Holder<T> = Holder(initial)
        \\class Box<T>(var v: T)
        \\fun <T> boxOf(v: T): Box<T> = Box(v)
        \\operator fun <T> Box<T>.getValue(thisRef: Any?, property: Any?): T = v
        \\operator fun <T> Box<T>.setValue(thisRef: Any?, property: Any?, value: T) { v = value }
        \\class Pipeline {
        \\    var interceptors: List<String>? by holder(null)
        \\    var name: String? by boxOf(null)
        \\}
        \\fun local(): Int {
        \\    var count: Int? by boxOf(null)
        \\    count = 1
        \\    return 0
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a lambda assigned through an indexed set takes its parameter types from set's value" {
    var fx = try fixture(&.{
        \\package demo
        \\class Client(val name: String)
        \\class Table<K, V> { operator fun set(key: K, value: V) {} }
        \\fun install(plugins: Table<String, (Client) -> Int>) {
        \\    plugins["k"] = { scope -> scope.name.length }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "members imported from an object are called and read on the object" {
    var fx = try fixture(&.{
        \\package demo
        \\import demo.Obj.x
        \\import demo.Obj.f
        \\import demo.Obj.ext
        \\object Obj {
        \\    val x = 1
        \\    fun f(): Int = 2
        \\    fun Int.ext(): Int = 3
        \\}
        \\var backing = 0
        \\var tracked: Int
        \\    get() = backing
        \\    set(v) { backing = v }
        \\fun use(): Int {
        \\    val lazyish by lazyOf(1)
        \\    return x + f() + 4.ext() + lazyish
        \\}
        \\class Cell<T>(val v: T) { operator fun getValue(thisRef: Any?, p: Any?): T = v }
        \\fun <T> lazyOf(v: T): Cell<T> = Cell(v)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const R = records;
    inline for (.{ .{ "return ^x +", R.RefKind.read }, .{ "+ ^f() +", R.RefKind.call }, .{ "4.^ext()", R.RefKind.call } }) |c| {
        const r = try fx.refAt(c[0], c[1]);
        try std.testing.expect(r.dispatch == .implicit);
        try std.testing.expectEqual(R.ImplicitKind.object, r.dispatch.implicit.kind);
        try std.testing.expectEqualStrings("Obj", s.str(s.syms.name(r.dispatch.implicit.owner)));
    }
    // The setter's value parameter has a declaration record.
    const v = try fx.refAt("set(^v)", .decl);
    try std.testing.expectEqualStrings("v", s.str(s.syms.name(v.target)));
    // A delegated local's symbol points at its property.
    const d = try fx.refAt("val ^lazyish", .decl);
    try std.testing.expect(s.syms.get(d.target).decl == .local_prop);
}

test "a plain function value passed for a suspend function type is converted" {
    var fx = try fixture(&.{
        \\package demo
        \\class App
        \\class Builder {
        \\    fun module(body: suspend App.() -> Unit) {}
        \\}
        \\fun use(b: Builder) {
        \\    val m: App.() -> Unit = { }
        \\    b.module(m)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const O = sema_mod.output;
    const out = try O.build(fx.s);
    const r = try fx.refAt("b.^module(m)", .call);
    const c = try O.call(fx.s, &out.files[3], r.node);
    try std.testing.expect(c.conv[0] == .suspend_);
}

test "a local function does not hide an outer local value of its name" {
    var fx = try fixture(&.{
        \\package demo
        \\fun <T> scope(block: () -> T): T = block()
        \\fun use(): Boolean = scope {
        \\    val retry: (Int) -> Boolean = { it < 3 }
        \\    fun retry(n: Int, check: (Int) -> Boolean): Boolean = check(n)
        \\    scope {
        \\        val perRequest: ((Int) -> Boolean)? = null
        \\        val retry = perRequest ?: retry
        \\        retry(1, retry)
        \\    }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const r = try fx.refAt("?: ^retry", .read);
    try std.testing.expectEqual(sema_mod.symbols.Kind.local, s.syms.kind(r.target));
    // Called with two arguments, `retry` is the local function.
    const c = try fx.refAt("^retry(1, retry)", .call);
    try std.testing.expectEqual(sema_mod.symbols.Kind.function, s.syms.kind(c.target));
}

test "a qualified type names a type alias in another package" {
    var fx = try fixture(&.{
        \\package app.application
        \\@Deprecated("moved", level = DeprecationLevel.ERROR)
        \\typealias EventHandler<T> = lib.events.EventHandler<T>
        \\fun fire(h: lib.events.EventHandler<String>) = h("x")
    ,
        \\package lib.events
        \\typealias EventHandler<T> = (T) -> Unit
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a type parameter bounded by another's nullable form fits it without the null" {
    var fx = try fixture(&.{
        \\package demo
        \\fun <T : Any> g(x: T?): Int = 1
        \\fun <T : Any, E : T?> f(e: E): Int = g<T>(e)
        \\class W<T : Any, E : T?>(val e: E)
        \\fun <T : Any, E : T?> h(e: E): W<T, E> = W<T, E>(e)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a star argument to a type alias projects the places its parameter is an argument" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Strategy<in T>
        \\typealias Provider<Base> = (value: Base) -> Strategy<Base>?
        \\class Box<K, V> { operator fun set(k: K, v: V) {} }
        \\class Module {
        \\    private val providers: Box<String, Provider<*>> = Box()
        \\    fun <Base : Any> register(name: String, p: (value: Base) -> Strategy<Base>?) {
        \\        providers[name] = p
        \\    }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a lambda in a branch of an argument is typed by the parameter" {
    var fx = try fixture(&.{
        \\package demo
        \\class Scope
        \\class Span(val n: Int)
        \\fun items(count: Int, span: (Scope.(index: Int) -> Span)? = null, content: (Int) -> Unit) {}
        \\fun <T> itemsOf(list: List<T>, span: (Scope.(item: T) -> Span)? = null) =
        \\    items(list.size, span = if (span != null) { { span(list[it]) } } else null) { }
        \\fun take(f: (String) -> Int) = f("a")
        \\fun use(flag: Boolean) = take(if (flag) { s -> s.length } else { s -> s.hashCode() })
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a member extension property coexists with a member property of its name" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Composition
        \\abstract class CompositionContext { internal open val composition: Composition? get() = null }
        \\class CompositionImpl(val parent: CompositionContext) : Composition
        \\interface CompositionInstance { val parent: CompositionInstance? }
        \\internal class DataImpl(val composition: Composition) : CompositionInstance {
        \\    override val parent: CompositionInstance?
        \\        get() = composition.parent?.let { DataImpl(it) }
        \\    private val Composition.context
        \\        get() = (this as? CompositionImpl)?.parent
        \\    private val Composition.parent
        \\        get() = context?.composition
        \\}
        \\class Density(val density: Int) {
        \\    val Int.dp: Int get() = this * density
        \\    val String.dp: Int get() = length * density
        \\    fun both(): Int = 2.dp + "ab".dp
        \\}
        \\interface Scope
        \\object Inst : Scope
        \\inline fun run(content: Scope.() -> Unit) { Inst.content() }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "an extension property of function type is invoked on its receiver" {
    var fx = try fixture(&.{
        \\package demo
        \\class ColorSpace
        \\class Conv<A>(val a: A)
        \\class Color { companion object }
        \\val Color.Companion.VectorConverter: (colorSpace: ColorSpace) -> Conv<Color>
        \\    get() = { Conv(Color()) }
        \\class Scope
        \\val Scope.handler: (Int) -> String get() = { it.toString() }
        \\fun use(cs: ColorSpace, s: Scope): Conv<Color> {
        \\    val h = s.handler(1)
        \\    return Color.VectorConverter(cs)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.refAt("s.^handler(1)", .read);
    try std.testing.expect(r.extension == .expr);
    const c = try fx.refAt("Color.^VectorConverter(cs)", .read);
    try std.testing.expect(c.extension == .expr);
}

test "an inner class is constructed bare on an extension receiver of its outer class" {
    var fx = try fixture(&.{
        \\package demo
        \\class Outer<X> {
        \\    inner class State<T>(val initialValue: T) { fun update(v: T) {} }
        \\    fun add(s: State<*>) {}
        \\}
        \\fun <T> Outer<Int>.animate(v: T): T {
        \\    val st = run { State(v) }
        \\    if (v != st.initialValue) st.update(v)
        \\    add(st)
        \\    return st.initialValue
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.refAt("run { ^State(v) }", .ctor);
    try std.testing.expect(r.dispatch == .implicit);
    try std.testing.expectEqual(records.ImplicitKind.extension, r.dispatch.implicit.kind);
}

test "branches join when the expected type is a lambda result still being inferred" {
    var fx = try fixture(&.{
        \\package demo
        \\class ObjectList<T>
        \\fun <T> emptyObjectList(): ObjectList<T> = ObjectList()
        \\fun <T> objectListOf(v: T): ObjectList<T> = ObjectList()
        \\fun <R> synchronized(lock: Any, block: () -> R): R = block()
        \\fun use(flag: Boolean, lock: Any): ObjectList<String> {
        \\    val v = synchronized(lock) {
        \\        if (flag) {
        \\            val x = objectListOf("a")
        \\            x
        \\        } else emptyObjectList()
        \\    }
        \\    return v
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a fun interface's abstract method may be inherited from a generic supertype" {
    var fx = try fixture(&.{
        \\package demo
        \\interface StyleScope { fun shape(v: Int) }
        \\fun interface CustomStyle<S> { fun S.applyStyle() }
        \\fun interface Style : CustomStyle<StyleScope> {
        \\    companion object : Style { override fun StyleScope.applyStyle() {} }
        \\}
        \\fun styleable(style: Style): Int = 0
        \\fun use() = styleable { shape(1) }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "an open branch below a closed one shares its type arguments" {
    var fx = try fixture(&.{
        \\package demo
        \\interface FiniteAnimationSpec<T>
        \\class SnapSpec<T>(val d: Int) : FiniteAnimationSpec<T>
        \\fun <T> snap(delayMillis: Int = 0): SnapSpec<T> = SnapSpec(delayMillis)
        \\class IntOffset(val x: Int)
        \\fun slideIn(animationSpec: FiniteAnimationSpec<IntOffset>, initialOffset: (Int) -> IntOffset): Int = 0
        \\fun use(a: Any?): Int {
        \\    val spec = a as? FiniteAnimationSpec<IntOffset> ?: snap()
        \\    return slideIn(animationSpec = spec, initialOffset = { IntOffset(it) })
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a safe chain equal to a non-null literal is not null, and a lambda does not fit a rigid T" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Job { val isActive: Boolean; fun cancel(); suspend fun join() }
        \\interface Flow<T>
        \\interface FlowCollector<T> { suspend fun emit(value: T) }
        \\inline fun <T, R> Flow<T>.transform(crossinline transform: suspend FlowCollector<R>.(value: T) -> Unit): Flow<R> = TODO()
        \\inline fun <T, R> Flow<T>.map(crossinline transform: suspend (value: T) -> R): Flow<R> = transform { value ->
        \\    return@transform emit(transform(value))
        \\}
        \\fun use(delayJob: Job?) {
        \\    val job = delayJob
        \\    if (job?.isActive == true) job.cancel()
        \\    if (job?.isActive != true) return
        \\    job.cancel()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "x as? T that is not null makes x a T" {
    var fx = try fixture(&.{
        \\package demo
        \\class El(val flag: Boolean)
        \\fun pick(x: El): Int = 1
        \\fun pick(x: Any?): Int = 2
        \\fun eq(other: Any?): Int {
        \\    val o = other as? El ?: return 0
        \\    return pick(other)
        \\}
        \\fun viaIf(other: Any?): Int = if (other as? El != null) pick(other) else 0
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    var n: usize = 0;
    for (s.refs.items) |r| {
        if (r.file != 3 or r.kind != .call) continue;
        if (!std.mem.eql(u8, s.str(s.syms.name(r.target)), "pick")) continue;
        try std.testing.expectEqualStrings("demo.El", fx.typeText(try sema_mod.headers.paramType(s, s.syms.functionInfo(r.target).params[0])));
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "a val initialized from a safe chain being not null makes the chain's receiver not null" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Coords { val isAttached: Boolean }
        \\interface Selectable { fun getLayoutCoordinates(): Coords?; fun getHandlePosition(start: Boolean): Int }
        \\fun update(startSelectable: Selectable?): Int? {
        \\    val startLayoutCoordinates = startSelectable?.getLayoutCoordinates()
        \\    return startLayoutCoordinates?.let { c -> startSelectable.getHandlePosition(start = true) }
        \\}
        \\fun update2(s: Selectable?): Int {
        \\    val c = s?.getLayoutCoordinates()
        \\    if (c != null) return s.getHandlePosition(true)
        \\    return 0
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a val assigned after its declaration is narrowed by the assignment" {
    var fx = try fixture(&.{
        \\package demo
        \\class Bitmap(val w: Int)
        \\class Canvas(val b: Bitmap) { fun draw() {} }
        \\interface Job { fun join() }
        \\fun launch(block: () -> Unit): Job = TODO()
        \\fun paint(spread: Int, j: Job) {
        \\    val pathBitmap: Bitmap?
        \\    if (spread > 0) {
        \\        pathBitmap = Bitmap(1)
        \\        Canvas(pathBitmap).draw()
        \\    } else {
        \\        pathBitmap = null
        \\    }
        \\    val cancelJob: Job?
        \\    if (spread > 1) cancelJob = launch { } else cancelJob = j
        \\    launch { cancelJob.join() }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a lambda returned from a lambda argument is typed by the enclosing parameter" {
    var fx = try fixture(&.{
        \\package demo
        \\class Scope
        \\class Span(val n: Int)
        \\val DefaultSpan: Scope.(Int) -> Span = { Span(1) }
        \\class Interval(val key: ((index: Int) -> Any)?, val span: Scope.(Int) -> Span, val item: Scope.(Int) -> Unit)
        \\fun item(key: Any?, span: (Scope.() -> Span)?, content: Scope.() -> Unit) =
        \\    Interval(
        \\        key = key?.let { { key } },
        \\        span = span?.let { { span() } } ?: DefaultSpan,
        \\        item = { content() },
        \\    )
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "type parameters whose bounds admit null join to a nullable type" {
    var fx = try fixture(&.{
        \\package demo
        \\class Node(val buf: Array<Any?>)
        \\fun <K, V> make(k1: K, v1: V, flag: Boolean): Node {
        \\    val nodeBuffer = if (flag) { arrayOf(k1, v1) } else { arrayOf(v1, k1) }
        \\    return Node(nodeBuffer)
        \\}
        \\fun <K, V> make3(k1: K, v1: V): Node { val b = arrayOf(k1, v1); return Node(b) }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "vararg overloads, imported member extension properties and anonymous types that escape" {
    var fx = try fixture(&.{
        \\package demo
        \\import demo.Units.Companion.twice
        \\interface Sink { fun tag(vararg parts: String): String = "v"; fun tag(only: String): String = "o" }
        \\class Units { companion object { val Int.twice: Int get() = this * 2 } }
        \\interface DrawContext { var canvas: String }
        \\class ScopeImpl {
        \\    val drawContext = object : DrawContext { override var canvas: String = "" }
        \\    private val own = object : DrawContext { override var canvas: String = ""; val extra = 1 }
        \\    fun e(): Int = own.extra
        \\}
        \\fun use(s: Sink, sc: ScopeImpl): Int {
        \\    s.tag("a")
        \\    sc.drawContext.canvas = "x"
        \\    return 21.twice
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const t = try fx.refAt("s.^tag(\"a\")", .call);
    try std.testing.expect(!s.syms.flags(s.syms.functionInfo(t.target).params[0]).vararg);
    const w = try fx.refAt("21.^twice", .read);
    try std.testing.expect(w.dispatch == .implicit);
    try fx.expectRef("sc.drawContext.^canvas = ", .write, "demo/DrawContext.canvas");
}

test "enclosing locals rank above an object's members, and member bodies do not see constructor parameters" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Src { fun make(): String }
        \\fun plain(make: () -> String): Src = object : Src {
        \\    override fun make(): String = make()
        \\}
        \\class Box(init: Int) {
        \\    private var init: Int? = init
        \\    val v: Int get() = init!! + 1
        \\    fun w(): Int = init!! + 2
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const m = try fx.refAt("= ^make()\n", .invoke);
    _ = m;
    const g = try fx.refAt("get() = ^init!!", .read);
    try std.testing.expectEqual(sema_mod.symbols.Kind.property, s.syms.kind(g.target));
    const f = try fx.refAt("w(): Int = ^init!!", .read);
    try std.testing.expectEqual(sema_mod.symbols.Kind.property, s.syms.kind(f.target));
    const i = try fx.refAt("Int? = ^init", .read);
    try std.testing.expect(s.syms.kind(i.target) != .property);
}

test "objects and object expressions that delegate get forwarding members" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Sink2 { fun flush(): String; fun close(): String }
        \\class Buf : Sink2 { override fun flush() = "f"; override fun close() = "c" }
        \\object Named : Sink2 by Buf()
        \\fun use(): String {
        \\    val s = object : Sink2 by Buf() {}
        \\    val t = object : Sink2 by Buf() { override fun close() = "own" }
        \\    return s.flush() + t.close() + t.flush() + Named.flush()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const a = try fx.refAt("s.^flush()", .call);
    try std.testing.expectEqual(records.RefKind.call, a.kind);
    try std.testing.expect(s.syms.classInfo(s.syms.owner(a.target)).kind == .anonymous);
    const n = try fx.refAt("Named.^flush()", .call);
    try std.testing.expectEqualStrings("Named", s.str(s.syms.name(s.syms.owner(n.target))));
}

test "a lambda's and a reference's recorded types take their solved variables" {
    var fx = try fixture(&.{
        \\package demo
        \\fun <T, R> List<T>.mapTo(f: (T) -> R): List<R> = TODO()
        \\fun twice(x: Int): Int = x * 2
        \\fun use(xs: List<Int>): List<Int> {
        \\    val a = xs.mapTo { it + 1 }
        \\    return xs.mapTo(::twice)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const O = sema_mod.output;
    const out = try O.build(fx.s);
    const fr = &out.files[3];
    const l = try fx.refAt("mapTo ^{ it + 1 }", .decl);
    try std.testing.expectEqualStrings("kotlin.Function1<kotlin.Int, kotlin.Int>", fx.typeText((try O.lambda(fr, l.node)).fn_type));
    const r = try fx.refAt("mapTo(::^twice)", .ref);
    try std.testing.expect(std.mem.indexOfScalar(u8, fx.typeText((try O.ref(fr, r.node)).ty), '?') == null);
}

test "synthesized members say what they are, and copy's parameters name their properties" {
    var fx = try fixture(&.{
        \\package demo
        \\data class P(val x: Int, val y: String)
        \\enum class E { A }
        \\fun use(p: P): P = p.copy(x = 1)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const c = try fx.refAt("p.^copy(x = 1)", .call);
    try std.testing.expectEqual(sema_mod.symbols.Synth.data_copy, s.syms.functionInfo(c.target).synth);
    const ps = s.syms.functionInfo(c.target).params;
    try std.testing.expectEqualStrings("x", s.str(s.syms.name(s.syms.paramInfo(ps[0]).default_prop)));
    try std.testing.expectEqualStrings("y", s.str(s.syms.name(s.syms.paramInfo(ps[1]).default_prop)));
    try std.testing.expectEqual(sema_mod.symbols.Kind.property, s.syms.kind(s.syms.paramInfo(ps[1]).default_prop));
}

test "a SAM lambda sees a vararg as its array, and inner-class aliases work on explicit receivers" {
    var fx = try fixture(&.{
        \\package demo
        \\fun interface IntFolder { fun fold(vararg values: Int): Int }
        \\val size: IntFolder = IntFolder { values -> 0 }
        \\class Outer<T> {
        \\    inner class Inner(val p: T)
        \\    typealias TAtoInner = Outer<String>.Inner
        \\    fun fromInside(): String {
        \\        val self = Outer<String>()
        \\        val a = self.TAtoInner("inside")
        \\        val ref = self::TAtoInner
        \\        return a.p + ref("ref").p
        \\    }
        \\}
        \\typealias InnerAlias<K> = Outer<K>.Inner
        \\val starRef: Any = Outer<*>::fromInside
        \\fun use(outer: Outer<String>): String {
        \\    val bound = Outer<String>::InnerAlias
        \\    return bound(outer, "b").p
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const O = sema_mod.output;
    const out = try O.build(fx.s);
    const l = try fx.refAt("IntFolder ^{ values -> 0 }", .decl);
    const p = (try O.lambda(&out.files[3], l.node)).params[0];
    try std.testing.expect(std.mem.indexOf(u8, fx.typeText(fx.s.syms.localInfo(p).ty), "Array") != null);
}

test "a lambda's written parameter types rule out a candidate that passes others" {
    var fx = try fixture(&.{
        \\package demo
        \\class Sb { fun add(x: Any?) {} }
        \\inline fun Sb.forEachIndexed(block: (index: Int, element: String) -> Unit) {}
        \\fun sb(block: Sb.() -> Unit): Int = 0
        \\class Table {
        \\    inline fun forEachIndexed(block: (index: Int, element: Long) -> Unit) {}
        \\    fun render(): Int = sb { forEachIndexed { index: Int, element: Long -> add(element) } }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("sb { ^forEachIndexed {", .call, "demo/Table.forEachIndexed");
}

test "this in an object expression's supertype arguments is the enclosing receiver" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Scope { val tag: String }
        \\abstract class Provider(val scope: Scope) { abstract fun make(): String }
        \\fun Scope.build(): Provider = object : Provider(this) { override fun make() = scope.tag }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.refAt("Provider(^this)", .this_);
    const O = sema_mod.output;
    const out = try O.build(fx.s);
    const rv = try O.recv(&out.files[3], r.node);
    try std.testing.expectEqual(records.ImplicitKind.extension, rv.kind);
}

test "a variable with only upper bounds is fixed at the most specific of them" {
    var fx = try fixture(&.{
        \\package demo
        \\class ColorFilter
        \\class Props { var colorFilter: ColorFilter? = null; fun hasId(id: Int) = true }
        \\inline fun <T : Any> Props.hasOrNull(id: Int, read: Props.() -> T): T? = if (hasId(id)) read() else null
        \\class Layer { var colorFilter: ColorFilter? = null }
        \\fun apply(layer: Layer, resolved: Props) {
        \\    with(layer) { colorFilter = resolved.hasOrNull(4) { colorFilter!! } }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a compound assignment's lambda takes the operator's parameter type" {
    var fx = try fixture(&.{
        \\package demo
        \\class Colors(val iconColor: Int)
        \\class Handlers { operator fun plusAssign(h: (Colors) -> Unit) {} }
        \\fun build(hs: Handlers) {
        \\    hs += { colors -> colors.iconColor }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a backtick-escaped underscore in a destructuring binds a name" {
    var fx = try fixture(&.{
        \\package demo
        \\data class P(val a: Int, val b: Int)
        \\fun f(p: P): Int {
        \\    val [`_`, d] = p
        \\    val [_, e] = p
        \\    return `_` + d + e
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "inference follows kotlinc for Any-expected branches and bounds over other type parameters" {
    var fx = try fixture(&.{
        \\package demo
        \\class Tc<U, in T : U>(val time: Long, val c: List<U>)
        \\fun <E> closed(): List<E> = TODO()
        \\fun g(b: Boolean, x: List<String>): Any? = if (b) closed() else x
        \\fun h(c: List<Int>): Any { val t = Tc(1L, c); return t }
        \\fun f(): Any? = closed()
    });
    defer fx.deinit();
    try fx.resolve();
    // Only `f` is refused, as kotlinc refuses it: nothing tells E there.
    var n: usize = 0;
    for (fx.s.census.sites.items) |site| {
        if (site.file != 3) continue;
        try std.testing.expectEqual(sema_mod.census.Reason.uninferred, site.reason);
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "a when's later branches see every earlier pattern failed" {
    var fx = try fixture(&.{
        \\package demo
        \\object Invalidated
        \\class Box(val n: Int)
        \\fun pick(x: Any): Int = 1
        \\fun pick(x: Any?): Int = 2
        \\fun f(instance: Any?, a: Box?, b: Box?): Int {
        \\    when (instance) {
        \\        null, Invalidated -> {}
        \\        else -> return pick(instance)
        \\    }
        \\    return when { a == null, b == null -> 0; else -> a.n + b.n }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.refAt("return ^pick(instance)", .call);
    try std.testing.expectEqualStrings("kotlin.Any", fx.typeText(try sema_mod.headers.paramType(fx.s, fx.s.syms.functionInfo(r.target).params[0])));
}

test "a delegate is expected to be the interface it implements" {
    var fx = try fixture(&.{
        \\package demo
        \\open class AnimationVector
        \\interface Spec<V : AnimationVector> { fun go(): Int }
        \\class Floaty<V : AnimationVector>(val a: Int) : Spec<V> { override fun go() = a }
        \\class Spring<V : AnimationVector>(a: Int) : Spec<V> by Floaty(a)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a property typed early leaves its setter for the class's pass" {
    var fx = try fixture(&.{
        \\package demo
        \\class Node(val block: () -> Int) { fun invalidate() {} }
        \\class Border(widthParameter: Int, brushParameter: Int) {
        \\    var width = widthParameter
        \\        set(value) { field = value; node.invalidate() }
        \\    var brush = brushParameter
        \\        set(value) { field = value; node.invalidate() }
        \\    private val node = Node { width + brush }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "!! on a call left open fixes it at what flows into it" {
    var fx = try fixture(&.{
        \\package demo
        \\class Mgr(val a: Int)
        \\object Saver { fun restore(v: Any): Mgr? = null }
        \\class State(val text: String, val mgr: Mgr)
        \\fun restoreState(text: Any?, saved: Any?): State =
        \\    State(text = text as String, mgr = with(Saver) { restore(saved!!) }!!)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a lambda returning T? against an expected List<T> fixes R from the expectation" {
    var fx = try fixture(&.{
        \\package demo
        \\inline fun <T, R : Any> Iterable<T>.mapNotNull(transform: (T) -> R?): List<R> = TODO()
        \\fun <T> now(xs: List<Any?>): List<T> = xs.mapNotNull { it as? T }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const r = try fx.refAt("^mapNotNull {", .call);
    const c = try sema_mod.output.call(fx.s, &out.files[3], r.node);
    try std.testing.expectEqualStrings("T & Any", fx.typeText(c.type_args[1]));
}

test "a type argument inferred from a generic call's result is recorded solved" {
    var fx = try fixture(&.{
        \\package demo
        \\inline fun <reified T> describe(value: T): Int = 1
        \\fun show(a: Any?) {}
        \\fun use() { show(describe(listOf(1, 2))) }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const r = try fx.refAt("^describe(listOf", .call);
    const c = try sema_mod.output.call(fx.s, &out.files[3], r.node);
    try std.testing.expectEqualStrings("kotlin.collections.List<kotlin.Int>", fx.typeText(c.type_args[0]));
}

test "a low-priority member yields to an extension of a later level" {
    var fx = try fixture(&.{
        \\package demo
        \\import kotlin.internal.*
        \\class Builder<R> {
        \\    @LowPriorityInOverloadResolution
        \\    fun onTimeout(timeMillis: Long, block: () -> R): Unit = onTimeout(timeMillis, block)
        \\    @LowPriorityInOverloadResolution
        \\    fun only(x: Int): Int = x
        \\}
        \\fun <R> Builder<R>.onTimeout(timeMillis: Long, block: () -> R): Unit {}
        \\fun use(b: Builder<Int>): Int {
        \\    b.onTimeout(100) { 1 }
        \\    return b.only(2)
        \\}
    ,
        \\package kotlin.internal
        \\internal annotation class LowPriorityInOverloadResolution
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("= ^onTimeout(timeMillis", .call, "demo/onTimeout");
    try fx.expectRef("b.^onTimeout(100", .call, "demo/onTimeout");
    try fx.expectRef("b.^only(2", .call, "demo/Builder.only");
}

test "a lambda's generic result takes the type its call's bound gives" {
    var fx = try fixture(&.{
        \\package demo
        \\public inline fun <M, R> M.ifEmpty(defaultValue: () -> R): R where M : Map<*, *>, M : R = this
        \\public fun <K, V> emptyMap(): Map<K, V> = TODO()
        \\public fun <K, V> mutableMapOf(): MutableMap<K, V> = TODO()
        \\public interface MutableMap<K, V> : Map<K, V>
        \\fun names(): Map<String, Int> {
        \\    val builder: MutableMap<String, Int> = mutableMapOf()
        \\    return builder.ifEmpty { emptyMap() }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "equal to a stable value that is not null, the other side is not null" {
    var fx = try fixture(&.{
        \\package demo
        \\class D(val name: String)
        \\fun take(x: D): String = x.name
        \\class Holder(private val poly: D?) {
        \\    fun same(d: D): String = if (d === poly) take(poly) else ""
        \\    fun equal(d: D): String = if (poly == d) take(poly) else ""
        \\    fun differ(d: D): String = if (d !== poly) "" else take(poly)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a reference qualified by a companion is bound to the companion object" {
    var fx = try fixture(&.{
        \\package demo
        \\class D(val n: Int) { companion object { val ONE = D(1); fun of(n: Int) = D(n) } }
        \\fun use(): Int {
        \\    val f = D.Companion::of
        \\    val g = D::of
        \\    return f(1).n + g(2).n + D.Companion::ONE.get().n + D.Companion::ONE.name.length
        \\}
    ,
        \\package kotlin.reflect
        \\public interface KCallable<out R> { public val name: String }
        \\public interface KProperty<out V> : KCallable<V>
        \\public interface KProperty0<out V> : KProperty<V>, () -> V { public fun get(): V }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    for ([_][]const u8{ "D.Companion::^of", "D::^of", "D.Companion::^ONE" }) |needle| {
        const r = try fx.refAt(needle, .ref);
        const b = r.detail.ref.bound;
        try std.testing.expect(b == .implicit and b.implicit.kind == .object);
        try std.testing.expectEqualStrings("Companion", fx.s.str(fx.s.syms.name(b.implicit.owner)));
    }
}

test "an external class and an external function keep the modifier" {
    var fx = try fixture(&.{
        \\package demo
        \\public external class Worker {
        \\    public val name: String
        \\    public fun join()
        \\}
        \\external fun hostCount(): Int
        \\class Plain
        \\fun use(w: Worker): Int = w.name.length + hostCount()
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    try std.testing.expect(s.syms.flags(s.classByFqn("demo.Worker")).external);
    try std.testing.expect(!s.syms.flags(s.classByFqn("demo.Plain")).external);
    try std.testing.expect(s.syms.flags((try fx.refAt("+ ^hostCount()", .call)).target).external);
}

test "an enum entry without arguments calls the constructor that takes none" {
    var fx = try fixture(&.{
        \\package demo
        \\enum class Tag {
        \\    A, B(2);
        \\    val weight: Int
        \\    constructor() { weight = 1 }
        \\    constructor(w: Int) { weight = w }
        \\}
        \\enum class Plain { X, Y }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    for ([_][]const u8{ "^A, B(2)", "A, ^B(2)", "^X, Y" }) |needle| {
        const r = try fx.refAt(needle, .ctor);
        const c = try sema_mod.output.call(fx.s, &out.files[3], r.node);
        try std.testing.expect(c.callee != .none);
    }
}

test "an unbound reference's receiver is not one of the target's parameters when adapting" {
    var fx = try fixture(&.{
        \\package demo
        \\class Counter(val base: Int) {
        \\    fun add(n: Int, vararg more: Int): Int = base + n
        \\    fun scaled(n: Int, by: Int = 2): Int = n * by
        \\}
        \\fun useBound(f: (Counter, Int) -> Int): Int = f(Counter(10), 4)
        \\fun useExt(f: Counter.(Int) -> Int): Int = Counter(1).f(2)
        \\fun use(): Int = useBound(Counter::add) + useExt(Counter::add) + useBound(Counter::scaled)
        \\fun report(title: String, vararg items: String, footer: String = "end"): String = title
        \\fun useThree(f: (String, String, String, String) -> String): String = f("E", "7", "8", "9")
        \\fun useArray(f: (String, Array<String>) -> String): String = f("E", arrayOf())
        \\fun useOne(f: (String) -> String): String = f("E")
        \\fun more(): String = useThree(::report) + useArray(::report) + useOne(::report)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const a1 = (try fx.refAt("useBound(Counter::^add)", .ref)).detail.ref.adapt;
    try std.testing.expect(a1.vararg_elems);
    const a2 = (try fx.refAt("useExt(Counter::^add)", .ref)).detail.ref.adapt;
    try std.testing.expect(a2.vararg_elems);
    const a3 = (try fx.refAt("Counter::^scaled", .ref)).detail.ref.adapt;
    try std.testing.expectEqual(@as(u16, 1), a3.defaults);
    // Past the vararg: elements, then the defaulted `footer`.
    const r3 = (try fx.refAt("useThree(::^report)", .ref)).detail.ref.adapt;
    try std.testing.expect(r3.vararg_elems);
    try std.testing.expectEqual(@as(u16, 1), r3.defaults);
    const ra = (try fx.refAt("useArray(::^report)", .ref)).detail.ref.adapt;
    try std.testing.expect(!ra.vararg_elems);
    try std.testing.expectEqual(@as(u16, 1), ra.defaults);
    const r1 = (try fx.refAt("useOne(::^report)", .ref)).detail.ref.adapt;
    try std.testing.expect(r1.vararg_elems);
    try std.testing.expectEqual(@as(u16, 1), r1.defaults);
}

test "a reference to a generic function records the type arguments its expected type fixes" {
    var fx = try fixture(&.{
        \\package demo
        \\inline fun <reified T> wrap(x: T): List<T> = listOf(x)
        \\fun <K, V> pairOf(k: K, v: V): Pair<K, V> = TODO()
        \\class Pair<A, B>
        \\fun useWrap(f: (String) -> List<String>): Int = 1
        \\fun usePair(f: (Int, String) -> Pair<Int, String>): Int = 2
        \\fun use(): Int = useWrap(::wrap) + usePair(::pairOf)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    _ = try sema_mod.output.build(fx.s);
    const w = (try fx.refAt("useWrap(::^wrap)", .ref)).detail.ref;
    try std.testing.expectEqual(@as(usize, 1), w.type_args.len);
    try std.testing.expectEqualStrings("kotlin.String", fx.typeText(w.type_args[0]));
    const p = (try fx.refAt("usePair(::^pairOf)", .ref)).detail.ref;
    try std.testing.expectEqualStrings("kotlin.Int", fx.typeText(p.type_args[0]));
    try std.testing.expectEqualStrings("kotlin.String", fx.typeText(p.type_args[1]));
}

test "an annotation class gets equals, hashCode and toString of its own" {
    var fx = try fixture(&.{
        \\package demo
        \\annotation class Tag(val name: String, val weight: Int)
        \\fun use(a: Tag, b: Tag): String = if (a == b && a.hashCode() == b.hashCode()) a.toString() else ""
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const tag = s.classByFqn("demo.Tag");
    const R = sema_mod.symbols.Synth;
    for ([_]struct { n: []const u8, k: R }{ .{ .n = "equals", .k = .annotation_equals }, .{ .n = "hashCode", .k = .annotation_hash_code }, .{ .n = "toString", .k = .annotation_to_string } }) |want| {
        const ms = sema_mod.symbols.Symbols.members(&s.syms.classInfo(tag).members, s.names.lookup(want.n).?);
        try std.testing.expectEqual(@as(usize, 1), ms.len);
        try std.testing.expectEqual(want.k, s.syms.functionInfo(ms[0]).synth);
    }
    try fx.expectRef("a.^toString()", .call, "demo/Tag.toString");
}

test "a literal whose upper bound is a variable takes the integral type that variable's bound asks for" {
    var fx = try fixture(&.{
        \\package demo
        \\class Two<out A, out B>(val a: A, val b: B)
        \\infix fun <A, B> A.to(that: B): Two<A, B> = Two(this, that)
        \\fun <K, V> mapOfTwo(vararg pairs: Two<K, V>): Map<K, V> = TODO()
        \\fun <T> arrayOfT(vararg elements: T): Array<T> = TODO()
        \\class Sensor(val samples: Array<Byte>)
        \\fun use() {
        \\    val m: Map<String, Long> = mapOfTwo("a" to 1, "b" to 2)
        \\    val s = Sensor(arrayOfT(1, 2, 3))
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const fr = &out.files[3];
    const to = try sema_mod.output.call(fx.s, fr, (try fx.refAt("\"a\" ^to 1", .call)).node);
    try std.testing.expectEqualStrings("kotlin.Long", fx.typeText(to.type_args[1]));
    const arr = try sema_mod.output.call(fx.s, fr, (try fx.refAt("^arrayOfT(1", .call)).node);
    try std.testing.expectEqualStrings("kotlin.Byte", fx.typeText(arr.type_args[0]));
    // The literals themselves take those types.
    try std.testing.expectEqualStrings("kotlin.Long", fx.typeText(fr.typeOf(try fx.exprAt("\"a\" to ^1"))));
    try std.testing.expectEqualStrings("kotlin.Byte", fx.typeText(fr.typeOf(try fx.exprAt("arrayOfT(1, ^2"))));
}

test "a variable that is only another variable's lower bound takes that variable's type" {
    var fx = try fixture(&.{
        \\package demo
        \\enum class Level { LOW, HIGH }
        \\fun <T> same(expected: T, actual: T): Boolean = expected == actual
        \\inline fun <reified T> decode(s: String): T = TODO()
        \\fun use(): Boolean = same(Level.LOW, decode("LOW"))
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const fr = &out.files[3];
    const c = try sema_mod.output.call(fx.s, fr, (try fx.refAt("^same(Level", .call)).node);
    try std.testing.expectEqualStrings("demo.Level", fx.typeText(c.type_args[0]));
    const d = try sema_mod.output.call(fx.s, fr, (try fx.refAt("LOW, ^decode(", .call)).node);
    try std.testing.expectEqualStrings("demo.Level", fx.typeText(d.type_args[0]));
}

test "a name-based `_ = prop` entry reads the property and binds nothing" {
    var fx = try fixture(&.{
        \\package demo
        \\object Counter {
        \\    var reads = 0
        \\    val counted: Int get() { reads = reads + 1; return reads }
        \\}
        \\fun use(): Int {
        \\    (val _ = counted, val r = reads) = Counter
        \\    return r
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("_ = ^counted", .read, "demo/Counter.counted");
    try fx.expectRef("r = ^reads", .read, "demo/Counter.reads");
}

test "composable lambdas carry the attribute and composable calls are marked" {
    var fx = try fixture(&.{
        \\package demo
        \\import androidx.compose.runtime.Composable
        \\@Composable fun Text(s: String) {}
        \\fun plain(s: String) {}
        \\@Composable fun Box(content: @Composable () -> Unit) { content(); content.invoke() }
        \\@Composable fun Row(content: @Composable Int.() -> Unit) { 1.content() }
        \\fun use(flag: Boolean) {
        \\    val c = @Composable { Text("a") }
        \\    val d: @Composable () -> Unit = { Text("b") }
        \\    val e = if (flag) d else c
        \\    Box { Text("c") }
        \\    plain("x")
        \\    val f = { plain("y") }
        \\    f()
        \\}
    ,
        \\package androidx.compose.runtime
        \\annotation class Composable
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const fr = &out.files[3];
    const s = fx.s;
    const comp = struct {
        fn call(f: *Fixture, o: *const sema_mod.output.FileRecords, needle: []const u8, kind: records.RefKind) !bool {
            const r = try f.refAt(needle, kind);
            return (try sema_mod.output.call(f.s, o, r.node)).composable;
        }
        fn lambda(f: *Fixture, needle: []const u8) !bool {
            const r = try f.refAt(needle, .decl);
            return f.s.types.get(r.detail.lambda.fn_type).class.attrs.composable;
        }
    };
    try std.testing.expect(try comp.call(&fx, fr, "{ ^Text(\"a\") }", .call));
    try std.testing.expect(!try comp.call(&fx, fr, "^plain(\"x\")", .call));
    try std.testing.expect(try comp.call(&fx, fr, "^content(); content", .invoke));
    try std.testing.expect(try comp.call(&fx, fr, "content.^invoke()", .call));
    try std.testing.expect(try comp.call(&fx, fr, "1.^content()", .invoke));
    try std.testing.expect(!try comp.call(&fx, fr, "^f()", .invoke));
    try std.testing.expect(try comp.lambda(&fx, "val c = @Composable ^{"));
    try std.testing.expect(try comp.lambda(&fx, "= ^{ Text(\"b\") }"));
    try std.testing.expect(try comp.lambda(&fx, "Box ^{"));
    try std.testing.expect(!try comp.lambda(&fx, "val f = ^{"));
    _ = s;
}

test "a statement that is an annotated lambda keeps its annotations" {
    var fx = try fixture(&.{
        \\package demo
        \\import androidx.compose.runtime.Composable
        \\@Composable fun Text(s: String) {}
        \\val getter = { n: Int ->
        \\    @Composable {
        \\        Text("a")
        \\    }
        \\}
    ,
        \\package androidx.compose.runtime
        \\annotation class Composable
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.refAt("@Composable ^{", .decl);
    try std.testing.expect(fx.s.types.get(r.detail.lambda.fn_type).class.attrs.composable);
}

test "a lambda converted to a fun interface whose method is composable is composable" {
    var fx = try fixture(&.{
        \\package demo
        \\import androidx.compose.runtime.Composable
        \\fun interface Decorator { @Composable fun Decoration(inner: @Composable () -> Unit) }
        \\val Default = Decorator { it() }
    ,
        \\package androidx.compose.runtime
        \\annotation class Composable
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.refAt("Decorator ^{ it() }", .decl);
    try std.testing.expect(fx.s.types.get(r.detail.lambda.fn_type).class.attrs.composable);
}

test "a postponed argument waits for the lambda whose result gives its expected type" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Cmp<in T> { fun compare(a: T, b: T): Int }
        \\fun <T> compareBy(selector: (T) -> Int): Cmp<T> = TODO()
        \\fun <T, R> Iterable<T>.minOfWith(comparator: Cmp<in R>, selector: (T) -> R): R = TODO()
        \\fun use(xs: List<String>): String = xs.minOfWith(compareBy { it.length }) { it }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a vararg element passed a receiver lambda takes its receiver from the explicit element type" {
    var fx = try fixture(&.{
        \\package demo
        \\class Op<C>(val description: String, val flag: Boolean = true, val function: C.() -> Unit)
        \\class Box { fun add(s: String) {} }
        \\class Other
        \\fun Other.add(s: String) {}
        \\fun ops() = listOf<Op<Box>>(
        \\    Op("add()") { add("e") },
        \\    Op("other", flag = false) { add("f") },
        \\)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a deferred call argument fits only parameters that take what it returns" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Cmp<in T> { fun compare(a: T, b: T): Int }
        \\fun <T> compareBy(selector: (T) -> Comparable<*>?): Cmp<T> = TODO()
        \\fun <T : Comparable<T>> maxOf(a: T, b: T, c: T): T = a
        \\fun <T> maxOf(a: T, b: T, comparator: Cmp<in T>): T = a
        \\fun <T> maxOf(a: T, vararg other: T, comparator: Cmp<in T>): T = a
        \\class Item(val name: String)
        \\fun use(x: Item, y: Item): Item = maxOf(x, y, compareBy { it.name })
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "extension function types join at the lower receiver and stay extension types" {
    var fx = try fixture(&.{
        \\package demo
        \\open class Coll { fun size(): Int = 0 }
        \\class Lst : Coll() { fun first(): Int = 0 }
        \\fun <T> pick(a: T, b: T): T = a
        \\fun use(x: Coll.() -> Unit, y: Lst.() -> Unit, l: Lst) {
        \\    val op = pick(x, y)
        \\    l.op()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("= ^pick(", .call)).node);
    const t = c.type_args[0];
    try std.testing.expect(fx.s.types.get(t).class.attrs.ext_fn);
    try std.testing.expectEqualStrings("demo.Lst", fx.typeText(fx.s.types.argsOf(t)[0].ty));
}

test "an integer literal against a bound naming the variable waits for the variable" {
    var fx = try fixture(&.{
        \\package demo
        \\fun <T : Comparable<T>> expectMinMax(min: T, max: T, elements: Array<T>) {}
        \\fun use() { expectMinMax(1, 5L, arrayOf(1, 2, 5L)) }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("^expectMinMax(1", .call)).node);
    try std.testing.expectEqualStrings("kotlin.Long", fx.typeText(c.type_args[0]));
}

test "an integer literal does not fit a generic type its classes never reach" {
    var fx = try fixture(&.{
        \\package demo
        \\fun <T> pick(x: List<T>): String = "list"
        \\fun pick(x: Int): String = "int"
        \\fun use() { pick(1) }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("^pick(1", .call)).node);
    try std.testing.expectEqual(@as(usize, 0), c.type_args.len);
}

test "a non-generic candidate beats a generic one neither is more specific than" {
    var fx = try fixture(&.{
        \\package demo
        \\class Big
        \\class Item { fun big() = Big() }
        \\class Items(val xs: List<Item>) : Iterable<Item> { override fun iterator() = xs.iterator() }
        \\fun <T> Iterable<T>.total(selector: (T) -> Int): Int = 0
        \\fun Items.total(selector: (Item) -> Big): Big = Big()
        \\fun use(b: Items) = b.total { it.big() }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.refAt("b.^total", .call);
    try std.testing.expectEqual(@as(usize, 0), fx.s.syms.functionInfo(r.target).type_params.len);
}

test "a call inside a builder lambda fixes its variables from types naming the builder's" {
    var fx = try fixture(&.{
        \\package demo
        \\interface Entry<K> { val key: K }
        \\interface Scope<K> { fun put(k: K); val entries: List<Entry<K>> }
        \\fun <K> build(block: Scope<K>.() -> Unit): List<K> = TODO()
        \\fun <T> List<T>.pick(p: (T) -> Boolean): T = TODO()
        \\fun take(e: Entry<String>) {}
        \\fun use(): Int = build {
        \\    put("a")
        \\    val e = entries.pick { it.key == "a" }
        \\    take(e)
        \\}.first().length
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("it.^key", "demo/Entry.key");
    try fx.expectTarget("first().^length", "kotlin/String.length");
}

test "a call in argument position keeps open what its result's bounds name" {
    var fx = try fixture(&.{
        \\package demo
        \\class Box<A>
        \\interface Src<out K>
        \\fun <K, M : Box<in K>> Src<K>.into(destination: M): M = destination
        \\fun take(b: Box<String?>) {}
        \\fun use(s: Src<String>) { take(s.into(Box())) }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("^Box())", .ctor)).node);
    try std.testing.expectEqualStrings("kotlin.String?", fx.typeText(c.type_args[0]));
}

test "a deferred call on a receiver fits only parameters its result class can reach" {
    var fx = try fixture(&.{
        \\package demo
        \\class Op<C>(val name: String, val function: C.() -> Unit)
        \\fun <T> List<T>.join(element: T): List<T> = this
        \\fun <T> List<T>.join(elements: List<T>): List<T> = this
        \\fun <T> List<T>.join(elements: Array<out T>): List<T> = this
        \\fun use(ops: List<Op<List<String>>>) {
        \\    ops.join(ops.map { Op(it.name) { size } })
        \\    ops + ops.map { Op(it.name) { size } }
        \\}
        \\operator fun <T> List<T>.plus(elements: List<T>): List<T> = this
        \\operator fun <T> List<T>.plus(elements: Array<out T>): List<T> = this
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.refAt("ops.^join", .call);
    const p = fx.s.syms.functionInfo(r.target).params[0];
    try std.testing.expectEqualStrings("kotlin.collections.List<T>", fx.typeText(try sema_mod.headers.paramType(fx.s, p)));
}

test "a literal a lambda gives beside a Byte is a Byte" {
    var fx = try fixture(&.{
        \\package demo
        \\fun take(b: Byte) {}
        \\fun use(a: Byte) {
        \\    take(a.let { if (it == a) 1 else it })
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a delegate is inferred with its getValue, the property's owner as thisRef" {
    var fx = try fixture(&.{
        \\package demo
        \\fun interface Prop<in T, out V> { operator fun getValue(thisRef: T, property: Any?): V }
        \\fun interface Provider<T, D> { operator fun provideDelegate(thisRef: T, property: Any?): D }
        \\typealias PropProvider<T, V> = Provider<T, Prop<T, V>>
        \\class Owner {
        \\    val a by Prop { _, _ -> "a" }
        \\    val n = "x"
        \\    private val provider = PropProvider { owner: Owner, _ -> Prop { _, _ -> owner.n } }
        \\    val b by provider
        \\}
        \\fun use(o: Owner) = o.a.length + o.b.length
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("o.a.^length", "kotlin/String.length");
    try fx.expectTarget("o.b.^length", "kotlin/String.length");
}

test "a variable below another open one takes that one's lower bounds too" {
    var fx = try fixture(&.{
        \\package demo
        \\class Acc(val n: Int)
        \\class Box<V>(val start: V)
        \\fun fail(msg: String): Nothing = TODO()
        \\fun <R, M : Box<R>> List<String>.fold(destination: M, init: (key: String) -> R, op: (acc: R) -> R): M = destination
        \\fun use(xs: List<String>, start: Acc) {
        \\    xs.fold(Box(start), { k -> fail(k) }, { acc -> Acc(acc.n + 1) })
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("acc.^n", "demo/Acc.n");
}

test "an enum's static functions resolve bare in its companion" {
    var fx = try fixture(&.{
        \\package demo
        \\enum class Mode {
        \\    A, B;
        \\    companion object {
        \\        fun all() = values()
        \\        fun byName(s: String) = valueOf(s)
        \\    }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("^values()", "demo/Mode.values");
    try fx.expectTarget("^valueOf(s)", "demo/Mode.valueOf");
}

test "a constructor the call site cannot see leaves the function named like its class" {
    var fx = try fixture(&.{
        \\package demo
        \\sealed class Period { abstract val days: Int }
        \\class DatePart(override val days: Int) : Period()
        \\fun Period(days: Int = 0): Period = DatePart(days)
        \\class Priv private constructor() {
        \\    companion object {
        \\        fun make() = Priv()
        \\        operator fun invoke(n: Int = 0): Priv = make()
        \\    }
        \\}
        \\fun use() {
        \\    val p = Period()
        \\    val q = Priv()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("p = ^Period()", "demo/Period");
    try fx.expectRef("make() = ^Priv()", .ctor, "demo/Priv.<init>");
    try fx.expectRef("q = ^Priv()", .invoke, "demo/Priv.Companion.invoke");
}

test "an expected type that leaves no type arguments is dropped, not the candidate" {
    var fx = try fixture(&.{
        \\package demo
        \\class Oops(msg: String) : Throwable()
        \\fun <T : Throwable> fails(make: () -> T, block: () -> Unit): T = TODO()
        \\fun <T : Throwable> fails(make: () -> T, message: String?, block: () -> Unit): T = TODO()
        \\inline fun group(block: () -> Unit) { block() }
        \\fun use() {
        \\    group {
        \\        fails({ Oops("a") }) { throw Oops("x") }
        \\    }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "arithmetic over integer literals is an integer literal where it is used" {
    var fx = try fixture(&.{
        \\package demo
        \\fun seconds(epochSeconds: Long, adjustment: Long = 0): Long = epochSeconds + adjustment
        \\fun <T> same(expected: T, actual: T): Boolean = expected == actual
        \\fun use() {
        \\    seconds(7 * 60 * 60, adjustment = 1)
        \\    same(678575 + 40587, 719162L)
        \\    val n = 3 * 4
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("^same(678575", .call)).node);
    try std.testing.expectEqualStrings("kotlin.Long", fx.typeText(c.type_args[0]));
}

test "an annotation class written without parentheses has its implicit constructor" {
    var fx = try fixture(&.{
        \\package demo
        \\annotation class Marker
        \\fun use(): Any = Marker()
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("^Marker()", .ctor, "demo/Marker.<init>");
}

test "a class literal argument is typed before candidates are chosen" {
    var fx = try fixture(&.{
        \\package demo
        \\import kotlin.reflect.KClass
        \\open class Base(val id: Int)
        \\fun <T : Any> get(base: KClass<in T>, value: T): String = "value"
        \\fun <T : Any> get(base: KClass<in T>, name: String?): String = "name"
        \\fun <B : Any> register(kind: KClass<B>, provider: (value: B) -> Int) {}
        \\fun use() {
        \\    get(Base::class, "x")
        \\    register(Base::class) { value -> value.id }
        \\}
        ,
        \\package kotlin.reflect
        \\interface KClass<T : Any>
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("value.^id", "demo/Base.id");
}

test "a lambda typed against a type variable waits for the call it is an argument of" {
    var fx = try fixture(&.{
        \\package demo
        \\class G2<S>(initial: S, val fs: List<String.(S) -> Unit>)
        \\fun <T> listOne(vararg xs: T): List<T> = TODO()
        \\fun use() = G2(1, listOne({ _ -> length }))
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("^length", "kotlin/String.length");
}

test "a receiver that may be null reads the extension on its nullable type, not the member" {
    var fx = try fixture(&.{
        \\package demo
        \\class Data(var weight: Int, val align: Align?)
        \\class Align(val isRelative: Boolean)
        \\val Data?.weight: Int get() = this?.weight ?: 0
        \\val Data?.align: Align? get() = this?.align
        \\val Data?.isRelative: Boolean get() = this.align?.isRelative ?: false
        \\fun use(none: Data?, d: Data) {
        \\    val a = none.weight
        \\    val b = d.weight
        \\    val c = none?.weight
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("a = none.^weight", "demo/weight");
    try fx.expectTarget("b = d.^weight", "demo/Data.weight");
    try fx.expectTarget("c = none?.^weight", "demo/Data.weight");
    try fx.expectTarget("this.^align?", "demo/align");
}

test "a class declared in a body sees the type parameters in scope there" {
    var fx = try fixture(&.{
        \\package demo
        \\fun <T> wrap(x: T): T {
        \\    class Local(val item: T)
        \\    return Local(x).item
        \\}
        \\class Outer<T>(val v: T) {
        \\    val prop: Any?
        \\    init {
        \\        class Inner(val w: T)
        \\        prop = Inner(v)
        \\    }
        \\    class Nested { fun <T> f(t: T) = t }
        \\}
        \\fun <T4> test(t: T4) {
        \\    class OuterLocal<T5> {
        \\        fun g(value: T4) {
        \\            class InnerLocal(val x: T4)
        \\        }
        \\    }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("Local(x).^item", "demo/Local.item");
}

test "a collection literal calls what the type expected of it chooses" {
    var fx = try fixture(&.{
        \\package demo
        \\class MyList(val data: String) {
        \\    companion object {
        \\        operator fun of(vararg strs: String) = MyList("")
        \\        operator fun of(s1: String, s2: String) = MyList("O")
        \\        fun of(s1: String) = MyList("K")
        \\    }
        \\}
        \\class Box<T>(val items: Array<out T>) {
        \\    companion object { operator fun <K> of(vararg xs: K) = Box(xs) }
        \\}
        \\fun show(m: MyList) = m.data
        \\fun <U> first(b: Box<U>): U = TODO()
        \\fun count(c: Collection<Int>): Int = c.size
        \\fun use() {
        \\    val a: MyList = ["a", "b"]
        \\    val b: MyList = ["a"]
        \\    val l = [1, 2]
        \\    val arr: Array<String> = ["x"]
        \\    show(["x", "y"])
        \\    first(["s"]).length
        \\    count([1])
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const a = try fx.refAt("a: MyList = ^[", .call);
    try std.testing.expectEqual(@as(usize, 2), s.syms.functionInfo(a.target).params.len);
    const b = try fx.refAt("b: MyList = ^[", .call);
    try std.testing.expect(s.syms.flags(s.syms.functionInfo(b.target).params[0]).vararg);
    try fx.expectRef("l = ^[", .call, "kotlin/collections/listOf");
    try fx.expectRef("arr: Array<String> = ^[", .call, "kotlin/arrayOf");
    const sh = try fx.refAt("show(^[", .call);
    try std.testing.expectEqual(@as(usize, 2), s.syms.functionInfo(sh.target).params.len);
    try fx.expectTarget("first([\"s\"]).^length", "kotlin/String.length");
    try fx.expectRef("count(^[", .call, "kotlin/collections/listOf");
}

test "a value whose type extends a function type is suspend and SAM converted" {
    var fx = try fixture(&.{
        \\package demo
        \\fun interface KRunnable { fun invoke() }
        \\fun interface SuspendRunnable { suspend fun invoke() }
        \\object Ok : () -> Unit { override fun invoke() {} }
        \\class Test : () -> String { override fun invoke(): String = "OK" }
        \\fun foo(k: KRunnable) = 1
        \\fun isNull(r: KRunnable?): Boolean = r == null
        \\fun nullableFun(): (() -> Unit)? = null
        \\fun susp(s: SuspendRunnable) = 2
        \\suspend fun useSuspendFun(fn: suspend () -> String) = fn()
        \\fun <T> both(x: T) where T : () -> Unit, T : (Boolean) -> Unit { foo(x) }
        \\suspend fun use() {
        \\    foo(Ok)
        \\    isNull(nullableFun())
        \\    val f: () -> Unit = {}
        \\    susp(f)
        \\    useSuspendFun(Test())
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const O = sema_mod.output;
    const out = try O.build(fx.s);
    const sam_sites = [_][]const u8{ "^foo(Ok)", "^isNull(nullableFun())", "^susp(f)", "{ ^foo(x) }" };
    for (sam_sites) |site| {
        const c = try O.call(fx.s, &out.files[3], (try fx.refAt(site, .call)).node);
        try std.testing.expect(c.conv[0] == .sam);
    }
    const c = try O.call(fx.s, &out.files[3], (try fx.refAt("^useSuspendFun(Test())", .call)).node);
    try std.testing.expect(c.conv[0] == .suspend_);
}

test "an argument whose lambda was typed by its own body waits for the parameter's type" {
    var fx = try fixture(&.{
        \\package demo
        \\fun interface Comparator<T> { fun compare(a: T, b: T): Int }
        \\fun String.compareTo(other: String, ignoreCase: Boolean = false): Int = 0
        \\class Box<T>(val a: T, val b: T) { fun cmp(comparator: Comparator<T>): Int = comparator.compare(a, b) }
        \\fun <T> top(a: T, b: T, comparator: Comparator<T>): Int = comparator.compare(a, b)
        \\fun use() {
        \\    Box(1, 4).cmp(Comparator { p0, p1 -> p0.compareTo(p1) })
        \\    top(1, 4, Comparator { x0, x1 -> x0.compareTo(x1) })
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("p0.^compareTo(p1)", "kotlin/Int.compareTo");
    try fx.expectTarget("x0.^compareTo(x1)", "kotlin/Int.compareTo");
}

test "a call a lambda returns keeps its variables open for the call its result is passed to" {
    var fx = try fixture(&.{
        \\package demo
        \\class X<T>(val x: T)
        \\fun useX(x: X<String?>): String = ""
        \\fun <T> call(fn: () -> T) = fn()
        \\fun use() = useX(call { X("OK") })
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("^X(\"OK\")", .ctor)).node);
    try std.testing.expectEqualStrings("kotlin.String?", fx.typeText(c.type_args[0]));
}

test "a receiver that may be null offers no members to a bare call or a reference" {
    var fx = try fixture(&.{
        \\package demo
        \\class K(val x: String)
        \\fun K?.foo() = toString()
        \\fun <T> get(t: T): () -> String = t::toString
        \\fun K.bar() = toString()
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("K?.foo() = ^toString()", "kotlin/toString");
    try fx.expectTarget("t::^toString", "kotlin/toString");
    try fx.expectTarget("K.bar() = ^toString()", "kotlin/Any.toString");
}

test "a negated condition calls its operand's not" {
    var fx = try fixture(&.{
        \\package demo
        \\class B
        \\operator fun B.not(): Boolean = false
        \\fun use() { if (!!!B()) {} }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("if (!!^!B())", .op, "demo/not");
    try fx.expectRef("if (!^!!B())", .op, "kotlin/Boolean.not");
    try fx.expectRef("if (^!!!B())", .op, "kotlin/Boolean.not");
}

test "an infix call names only infix functions" {
    var fx = try fixture(&.{
        \\package demo
        \\class A { fun join(a: String): Int = 1; infix fun pair(a: String): Int = 2 }
        \\infix fun A.join(a: String): String = ""
        \\fun use() {
        \\    val x = A() join "K"
        \\    val y = A().join("K")
        \\    val z = A() pair "K"
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("A() ^join \"K\"", "demo/join");
    try fx.expectTarget("A().^join(\"K\")", "demo/A.join");
    try fx.expectTarget("A() ^pair \"K\"", "demo/A.pair");
}

test "a local function's context parameters are its callers' to pass" {
    var fx = try fixture(&.{
        \\package demo
        \\context(a: String) fun qux(): String = a
        \\fun use(): String {
        \\    context(s: String)
        \\    fun f() = s
        \\    context(a: String)
        \\    fun local(): String = qux()
        \\    return with("OK") { f() + local() }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const r = try fx.refAt("fun f() = ^s", .read);
    try std.testing.expectEqual(sema_mod.symbols.Kind.value_param, s.syms.kind(r.target));
    const c = try fx.refAt("{ ^f() +", .call);
    try std.testing.expectEqual(@as(usize, 1), c.contexts.len);
    // `qux()` in `local` takes `local`'s own context, not the one `with` gives.
    const q = try fx.refAt("= ^qux()", .call);
    try std.testing.expect(q.contexts[0] == .implicit and q.contexts[0].implicit.kind == .context);
}

test "a fun interface method's context parameters are its function type's contexts" {
    var fx = try fixture(&.{
        \\package demo
        \\class A(val v: String)
        \\fun interface Sam { context(a: A) fun accept(s: String): String }
        \\fun f(a: A, s: String) = a.v + s
        \\context(ctx: T) fun <T> implicit(): T = ctx
        \\fun use() {
        \\    val sam = Sam(::f)
        \\    val sam2 = Sam { s: String -> implicit<A>().v + s }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("implicit<A>().^v", "demo/A.v");
}

test "an enum entry's arguments see the enum's static scope, not its this" {
    var fx = try fixture(&.{
        \\package demo
        \\enum class Foo(val f: String) {
        \\    Alpha(run { "alpha" + k });
        \\    fun <R> run(block: () -> R): R = block()
        \\    companion object { val k = "k" }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("Alpha(^run {", "kotlin/run");
    try fx.expectTarget("\"alpha\" + ^k", "demo/Foo.Companion.k");
}

test "a variable's non-null part stays non-null once the variable is fixed" {
    var fx = try fixture(&.{
        \\package demo
        \\fun <T, R : Any> List<T>.mapNN(transform: (T) -> R?): List<R> = TODO()
        \\fun <T, R> T.run2(block: T.() -> R): R = block()
        \\fun <T> same(a: T, b: T): Boolean = true
        \\fun use(xs: List<String?>) = same(listOf(2), xs.mapNN { it?.run2 { if (length != 0) length else null } })
        \\interface TI<R> { fun emit(r: R); fun get(): R }
        \\fun <R1> build(block: TI<R1>.() -> Unit) {}
        \\fun use2() = build {
        \\    emit(1)
        \\    emit(null)
        \\    val x = get()
        \\    if (x != null) x.hashCode()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("x.^hashCode()", "kotlin/Any.hashCode");
}

test "a property access passes its context arguments, and needs them in scope" {
    var fx = try fixture(&.{
        \\package demo
        \\class C(val a: String)
        \\context(c: C) val C.property: String get() = "ctx=" + c.a + " this=" + this.a
        \\class A
        \\context(a: A) val b: String get() = "with-context"
        \\val b: String get() = "plain"
        \\var x = ""
        \\context(c: String) var foo: String
        \\    get() = x
        \\    set(value) { x = c + value }
        \\fun use() {
        \\    with(C("context")) { C("receiver").property }
        \\    b
        \\    with("O") { foo = "K"; foo }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    try std.testing.expectEqual(@as(usize, 1), (try fx.refAt(".^property }", .read)).contexts.len);
    const b = try fx.refAt("    ^b\n", .read);
    try std.testing.expectEqual(@as(usize, 0), s.syms.propertyInfo(b.target).context_params.len);
    try std.testing.expectEqual(@as(usize, 1), (try fx.refAt("{ ^foo = \"K\"", .write)).contexts.len);
    try std.testing.expectEqual(@as(usize, 1), (try fx.refAt("; ^foo }", .read)).contexts.len);
}

test "an object qualifier of a written member records the object on its own node" {
    var fx = try fixture(&.{
        \\package demo
        \\class N { operator fun inc(): N = this }
        \\object C { var c = N() }
        \\class Foo { companion object { var n = 0 } }
        \\fun use() { C.c++; Foo.n += 1 }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const out = try sema_mod.output.build(s);
    const text = fx.map.get(span.FileId.from(3)).source;
    for ([_][]const u8{ "C.c++", "Foo.n +=" }) |needle| {
        const at = std.mem.indexOf(u8, text, needle).?;
        // The write's object is on the qualifier's node, an expression
        // resolved as a qualifier, which has no type of its own; not on
        // the node of the operator call.
        var op_node: ast.NodeId = .none;
        for (s.refs.items) |r| {
            if (r.file == 3 and (r.kind == .inc or r.kind == .op)) op_node = r.node;
        }
        var on_qualifier = false;
        for (s.refs.items) |r| {
            if (r.file != 3 or r.anchor.start != at or r.kind != .object) continue;
            if (r.node != op_node and out.files[3].typeOf(r.node) == .none) on_qualifier = true;
        }
        try std.testing.expect(on_qualifier);
    }
}

test "Int is more specific than Long, Short and Byte whatever the argument" {
    var fx = try fixture(&.{
        \\package demo
        \\fun f(x: Int): String = "Int"
        \\fun f(x: Long): Int = 1
        \\fun g(x: Int?): String = "Int?"
        \\fun g(x: Long): Int = 1
        \\fun h(x: Long): Int = 1
        \\fun h(x: Short): Int = 2
        \\fun use() {
        \\    val a = f(throw Throwable()).length
        \\    val b = g(1).length
        \\    h(1)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectTarget("f(throw Throwable()).^length", "kotlin/String.length");
    try fx.expectTarget("g(1).^length", "kotlin/String.length");
    // `f` is not ambiguous, `h(1)` is: `Long` and `Short` are unrelated.
    var ambiguous: std.ArrayList(u8) = .empty;
    for (fx.s.census.sites.items) |site| {
        if (site.file == 3 and site.reason == .ambiguous) try ambiguous.append(fx.arena.allocator(), site.detail[0]);
    }
    try std.testing.expectEqualStrings("h", ambiguous.items);
}

test "a variable equal to a builder's is fixed to it, not joined with what flows into it" {
    var fx = try fixture(&.{
        \\package demo
        \\interface MEntry<K, V> { val key: K; val value: V }
        \\interface MMap<K, V> { val entries: List<MEntry<K, V>> }
        \\operator fun <K, V> MMap<K, V>.set(key: K, value: V) {}
        \\fun <K, V> buildMap(block: MMap<K, V>.() -> Unit): Map<K, V> = TODO()
        \\fun <T> assertEquals(expected: T, actual: T) {}
        \\fun take(label: String, entry: MEntry<String, Int>) {}
        \\fun use() {
        \\    buildMap {
        \\        this["a"] = 1
        \\        val e = this.entries.first()
        \\        this["c"] = 30
        \\        assertEquals("b", e.key)
        \\        assertEquals(20, e.value)
        \\        take("x", e)
        \\    }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a call whose argument's lambda waits for it waits for the call it is passed to" {
    var fx = try fixture(&.{
        \\package demo
        \\fun interface Comparator<T> { fun compare(a: T, b: T): Int }
        \\fun <T> Array<out T>.sortedWith(comparator: Comparator<in T>): List<T> = TODO()
        \\fun <T : Any> nullsLast(comparator: Comparator<in T>): Comparator<T?> = TODO()
        \\fun <T> compareByDescending(selector: (T) -> Comparable<*>?): Comparator<T> = TODO()
        \\fun use(a: Array<String?>) {
        \\    fun String.nullIfEmpty() = if (this.length == 0) null else this
        \\    a.sortedWith(nullsLast(compareByDescending { it.nullIfEmpty() }))
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("it.^nullIfEmpty()", "demo/nullIfEmpty");
}

test "a builder call deferred to a parameter nothing constrains still types its variable" {
    var fx = try fixture(&.{
        \\package demo
        \\class Spec<T>
        \\class Config<T> { infix fun T.at(time: Int): Int = time }
        \\fun <T> keyframes(init: Config<T>.() -> Unit): Spec<T> = TODO()
        \\class Repeat<T>(val s: Spec<T>)
        \\fun <T> infiniteRepeatable(animation: Spec<T>): Repeat<T> = TODO()
        \\fun take(r: Repeat<Double>) {}
        \\val spec get() = infiniteRepeatable(animation = keyframes { 1.0 at 0 })
        \\fun use() = take(spec)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "an adapted reference records the type arguments its fit inferred" {
    var fx = try fixture(&.{
        \\package demo
        \\inline fun <reified T> rf(a: T, vararg b: String, c: Int = 0): Int = 0
        \\fun conv(ref: Int.(Array<String>, Int) -> Unit) = ref
        \\fun use() = conv(::rf)
        ,
        \\package kotlin.reflect
        \\interface KFunction<out R> : Function<R>
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.refAt("::^rf", .ref);
    const rec = r.detail.ref;
    try std.testing.expectEqual(@as(usize, 1), rec.type_args.len);
    try std.testing.expectEqualStrings("kotlin.Int", fx.typeText(rec.type_args[0]));
    // The array is passed whole, `c` takes the third argument, and the
    // result is dropped for `Unit`.
    try std.testing.expect(!rec.adapt.vararg_elems);
    try std.testing.expectEqual(@as(u16, 0), rec.adapt.defaults);
    try std.testing.expect(rec.adapt.drop_result);
}

test "a builder's statements so far decide a candidate and a receiver's members" {
    var fx = try fixture(&.{
        \\package demo
        \\class Target { fun hello(): Int = 1 }
        \\class Different
        \\class Buildee<TV> { fun set(v: TV) {}; fun get(): TV = TODO() }
        \\fun <PTV> build(block: Buildee<PTV>.() -> Unit): Buildee<PTV> = TODO()
        \\fun consume(v: Target): Int = 1
        \\fun consume(v: Different): String = ""
        \\fun <EFT> Buildee<EFT>.materialize(): EFT = TODO()
        \\val Buildee<Target>.sourced: Target get() = Target()
        \\fun take(v: Target) {}
        \\fun use() {
        \\    build { set(Target()); consume(get()) }
        \\    build { set(Target()); get().hello() }
        \\    build { fun source(): Buildee<Target> = this }
        \\    build { fun source(p: Buildee<Target> = this) {} }
        \\    build { take(materialize()) }
        \\    build { this.sourced }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("^consume(get())", .call, "demo/consume");
    try fx.expectTarget("get().^hello()", "demo/Target.hello");
}

test "a call that suspend converts no argument is more specific than one that does" {
    var fx = try fixture(&.{
        \\package demo
        \\fun take(sus: suspend () -> String): Int = 1
        \\fun take(plain: () -> String): String = ""
        \\fun use(g: () -> String) {
        \\    val x = take(g)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const r = try fx.refAt("^take(g)", .call);
    const p = s.syms.functionInfo(r.target).params[0];
    try std.testing.expectEqualStrings("plain", s.str(s.syms.name(p)));
}

test "a reference with no receiver names no extension but through an implicit receiver" {
    var fx = try fixture(&.{
        \\package demo
        \\fun String.deco(): String = this
        \\fun deco(): Int = 1
        \\fun Int.only(): Int = this
        \\fun String.inside() {
        \\    val h = ::deco
        \\}
        \\fun use() {
        \\    val g = ::deco
        \\    val k = ::only
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    const s = fx.s;
    const g = try fx.refAt("g = ::^deco", null);
    try std.testing.expect(s.syms.functionInfo(g.target).receiver == .none);
    const h = try fx.refAt("h = ::^deco", null);
    try std.testing.expect(s.syms.functionInfo(h.target).receiver != .none);
    var n: usize = 0;
    for (s.census.sites.items) |site| {
        if (site.file != 3) continue;
        n += 1;
        try std.testing.expect(std.mem.indexOf(u8, site.detail, "only") != null);
    }
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "a context parameter smart cast by a check passes as its narrowed type" {
    var fx = try fixture(&.{
        \\package demo
        \\context(s: String) fun bar(): String = s
        \\context(ctx: Any) fun test(): String {
        \\    if (ctx is String) return bar()
        \\    return "no"
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const c = try fx.refAt("return ^bar()", .call);
    try std.testing.expectEqual(@as(usize, 1), c.contexts.len);
    try std.testing.expect(c.contexts[0] == .implicit and c.contexts[0].implicit.kind == .context);
    try std.testing.expectEqualStrings("ctx", s.str(s.syms.name(c.contexts[0].implicit.owner)));
}

/// The diagnostic messages of the program's sites, in order.
fn siteMessages(fx: *Fixture) ![]const []const u8 {
    const a = fx.arena.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    for (fx.s.census.sites.items) |site| {
        const fc = fx.s.fileOf(site.file) orelse continue;
        if (fc.origin != .program) continue;
        try out.append(a, try sema_mod.diagnose.message(fx.s, a, site));
    }
    return out.items;
}

fn expectMessages(fx: *Fixture, want: []const []const u8) !void {
    const got = try siteMessages(fx);
    errdefer for (got) |m| std.debug.print("message: {s}\n", .{m});
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "two declarations of one signature conflict at each declaration" {
    var fx = try fixture(&.{
        \\package app
        \\fun greet(who: String): String = who
        \\fun greet(name: String): Int = 1
        \\fun greet(n: Int): String = ""
        \\val x: Int = 1
        \\val x: String = ""
        \\private fun own(): Int = 1
        \\class C { fun m(a: Int) {}; fun m(b: Int) {} }
        \\class D
        \\interface D
    ,
        \\package app
        \\private fun own(): Int = 2
    });
    defer fx.deinit();
    try fx.resolve();
    try expectMessages(&fx, &.{
        "conflicting overloads: `greet(String)` is declared twice",
        "conflicting overloads: `greet(String)` is declared twice",
        "conflicting declarations: `val x` is declared twice",
        "conflicting declarations: `val x` is declared twice",
        "conflicting overloads: `m(Int)` is declared twice",
        "conflicting overloads: `m(Int)` is declared twice",
        "redeclaration: `D` is declared twice",
        "redeclaration: `D` is declared twice",
    });
    for (fx.s.census.sites.items) |site| {
        const fc = fx.s.fileOf(site.file) orelse continue;
        if (fc.origin != .program) continue;
        try std.testing.expectEqual(@as(usize, 2), site.syms.len);
    }
}

test "an expect of the program no actual implements reports itself" {
    var fx = try fixture(&.{
        \\package p1
        \\expect fun render(n: Int): String
        \\expect fun paired(n: Int): String
        \\actual fun paired(n: Int): String = ""
        \\expect fun <T> listOf(vararg elements: T): List<T>
    });
    defer fx.deinit();
    try fx.resolve();
    try expectMessages(&fx, &.{
        "`p1.render` is an `expect` with no `actual`",
        "`p1.listOf` is an `expect` with no `actual`",
    });
}

test "an unresolved call names the one package whose import would resolve it" {
    var fx = try fixture(&.{
        \\package app
        \\fun main() { f(); g(); h() }
    ,
        \\package liba
        \\fun f(): String = ""
        \\fun g(): String = ""
    ,
        \\package libb
        \\fun g(): String = ""
        \\fun String.h(): String = ""
    });
    defer fx.deinit();
    try fx.resolve();
    try expectMessages(&fx, &.{
        "unresolved reference `f`; add `import liba.f`",
        "unresolved reference `g`",
        "unresolved reference `h`",
    });
}

test "a member extension the call cannot see does not shadow the library's" {
    var fx = try fixture(&.{
        \\package app
        \\open class Base {
        \\    private fun String.trimmed(): Int = 1
        \\    protected fun String.padded(): Int = 2
        \\    private fun secret(): Int = 3
        \\    fun own(s: String) = s.trimmed()
        \\    companion object { fun peek(b: Base) = b.secret() }
        \\}
        \\class Sub : Base() {
        \\    fun check(s: String) = s.trimmed()
        \\    fun check2(s: String) = s.padded()
        \\}
        \\fun String.trimmed(): String = this
        \\fun String.padded(): String = this
        \\fun use(b: Base) {
        \\    with(b) { "a".trimmed(); "a".padded() }
        \\    b.secret()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectRef("= s.^trimmed()\n    companion", .call, "app/Base.trimmed");
    try fx.expectRef("check(s: String) = s.^trimmed()", .call, "app/trimmed");
    try fx.expectRef("check2(s: String) = s.^padded()", .call, "app/Base.padded");
    try fx.expectRef("{ \"a\".^trimmed()", .call, "app/trimmed");
    try fx.expectRef("\"a\".^padded() }", .call, "app/padded");
    try fx.expectRef("b.^secret() }", .call, "app/Base.secret");
    try expectMessages(&fx, &.{"cannot access 'fun secret(): Int': it is private in 'Base'."});
}

test "a type parameter that is not reified cannot be a reified type argument" {
    var fx = try fixture(&.{
        \\package app
        \\inline fun <reified R> make(a: R): List<R> = listOf(a)
        \\fun <T> choose(a: T): List<T> = make(a)
        \\inline fun <reified U> fine(a: U): List<U> = make(a)
        \\fun <T> explicit(a: T): List<T> = make<T>(a)
        \\fun concrete(): List<Int> = make(1)
    });
    defer fx.deinit();
    try fx.resolve();
    try expectMessages(&fx, &.{
        "cannot use `T` as a reified type argument of `make`; use a class instead",
        "cannot use `T` as a reified type argument of `make`; use a class instead",
    });
}

test "a reified type argument inferred as an intersection is refused" {
    var fx = try fixture(&.{
        \\package app
        \\interface A
        \\interface B
        \\class AB : A, B
        \\class BA : B, A
        \\class In<in K>
        \\inline fun <reified K> show(x: K, y: K) {}
        \\fun use() {
        \\    show(AB(), BA())
        \\    show(In<A>(), In<B>())
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try expectMessages(&fx, &.{
        "the reified type argument `K` of `show` was inferred as the intersection `A & B`; write the type argument explicitly",
    });
}

test "an unqualified super property is the one supertype that implements it" {
    var fx = try fixture(&.{
        \\package app
        \\open class Base
        \\interface I {
        \\    val p: String get() = "I.p"
        \\}
        \\class D : Base(), I {
        \\    override val p: String get() = "D.p"
        \\    fun viaSuper() = super.p
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("super.^p", null, "app/I.p");
}

test "a reference to a fun interface names its SAM constructor" {
    var fx = try fixture(&.{
        \\package app
        \\fun interface Supplier<T> { fun get(): T }
        \\fun use() {
        \\    val ctor: (() -> String) -> Supplier<String> = ::Supplier
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const r = try fx.refAt("::^Supplier", null);
    try std.testing.expectEqual(sema_mod.symbols.Kind.function, fx.s.syms.kind(r.target));
    try std.testing.expect(fx.s.syms.flags(r.target).synthetic);
}

test "a top-level val of the program smart casts" {
    var fx = try fixture(&.{
        \\package app
        \\val minus: Any = -1
        \\var changing: Any = 1
        \\fun use(): Int {
        \\    if (minus is Int) return minus + 1
        \\    if (changing is Int) return changing + 1
        \\    return 0
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    // Only the `var` is not smart cast: `minus + 1` is `Int.plus`.
    try expectMessages(&fx, &.{"`Any` has no `operator fun plus` that accepts (Int)"});
}

test "a catch and a finally see what the try may have assigned before it threw" {
    var fx = try fixture(&.{
        \\package app
        \\open class Exception
        \\fun use(): Int {
        \\    var x: Any = "OK"
        \\    try {
        \\        x = 42
        \\    } catch (e: Exception) {
        \\        x.plus(1)
        \\        x = 43
        \\    } finally {
        \\        x.plus(2)
        \\    }
        \\    var y: Any = 1
        \\    try {
        \\        y = 2
        \\    } catch (e: Exception) {
        \\        y = 3
        \\    }
        \\    return y.plus(3)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    // `x` may still be the `String` in the catch and the finally: neither
    // `plus` is `Int.plus`.
    var n: usize = 0;
    for (fx.s.census.sites.items) |site| {
        if (site.file != 3) continue;
        n += 1;
        try std.testing.expectEqualStrings("plus", site.name);
    }
    try std.testing.expectEqual(@as(usize, 2), n);
    // Both the body and the catch leave `y` an `Int`.
    try fx.expectRef("y.^plus(3)", .call, "kotlin/Int.plus");
}

test "a finally does not see what the body and catches leave when they complete" {
    var fx = try fixture(&.{
        \\package app
        \\open class Exception
        \\class Error
        \\fun test1(): Int {
        \\    var x: Any = "OK"
        \\    try {
        \\        throw Error()
        \\        x = 42
        \\    } catch (e: Exception) {
        \\        x = 43
        \\    } finally {
        \\        x.plus(1)
        \\    }
        \\    return x.plus(2)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    // In the finally `x` may be the `String`; past it, the catch left an
    // `Int`.
    var n: usize = 0;
    for (fx.s.census.sites.items) |site| {
        if (site.file == 3) n += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), n);
    try fx.expectRef("x.^plus(2)", .call, "kotlin/Int.plus");
}

test "a member extension property's delegate sees its class's this" {
    var fx = try fixture(&.{
        \\package app
        \\class A(val prop: String) {
        \\    val A.x: String by ::prop
        \\}
        \\fun use() = with(A("OK")) { A("fail").x }
    });
    defer fx.deinit();
    try fx.resolve();
    const r = try fx.refAt("::^prop", null);
    const recv = if (r.dispatch == .implicit) r.dispatch else r.extension;
    try std.testing.expect(recv == .implicit and recv.implicit.kind == .class_this);
    // Read on a value, `x` takes it as its extension receiver and the
    // `with` receiver as its dispatch receiver.
    const x = try fx.refAt(".^x }", .read);
    try std.testing.expect(x.extension == .expr);
    try std.testing.expect(x.dispatch == .implicit and x.dispatch.implicit.kind == .lambda);
}

test "is T? keeps a nullable value nullable" {
    var fx = try fixture(&.{
        \\package app
        \\fun eq(a: Any?, b: Any?): Boolean = if (a is Double && b is Double?) a == b else false
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const fr = &out.files[3];
    try std.testing.expectEqualStrings("kotlin.Double?", fx.typeText(fr.typeOf(try fx.exprAt("a == ^b"))));
}

test "a callable reference passed for a fun interface is SAM converted" {
    var fx = try fixture(&.{
        \\package app
        \\fun interface IntConsumer { fun accept(t: Int) }
        \\fun run2(c: IntConsumer) = c.accept(1)
        \\fun intRef(x: Int) {}
        \\fun use() = run2(::intRef)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const c = try fx.refAt("= ^run2(::intRef)", .call);
    try std.testing.expect(c.detail.call.conv[0] == .sam);
}

test "an integer literal takes the integral type a type parameter's declared bound names" {
    var fx = try fixture(&.{
        \\package app
        \\class Box<T : Long>(val v: T)
        \\fun use() = Box(4)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const fr = &out.files[3];
    const c = try sema_mod.output.call(fx.s, fr, (try fx.refAt("^Box(4)", .ctor)).node);
    try std.testing.expectEqualStrings("kotlin.Long", fx.typeText(c.type_args[0]));
}

test "a literal in a generic call's argument keeps its declared bound for the enclosing call" {
    var fx = try fixture(&.{
        \\package app
        \\class Box<T : Long>(val v: T)
        \\fun <T> id(x: T) = x
        \\fun use() = id(Box(4))
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const fr = &out.files[3];
    const c = try sema_mod.output.call(fx.s, fr, (try fx.refAt("id(^Box(4))", .ctor)).node);
    try std.testing.expectEqualStrings("kotlin.Long", fx.typeText(c.type_args[0]));
    const o = try sema_mod.output.call(fx.s, fr, (try fx.refAt("= ^id(", .call)).node);
    try std.testing.expectEqualStrings("app.Box<kotlin.Long>", fx.typeText(o.type_args[0]));
}

test "a variable only open variables bound waits for the lambda that gives it" {
    var fx = try fixture(&.{
        \\package app
        \\interface Cmp<in T>
        \\fun <T : Comparable<T>> nat(): Cmp<T> = TODO()
        \\fun <R> pick(c: Cmp<in R>, sel: () -> R): R = sel()
        \\fun use() = pick(nat()) { 1 }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const fr = &out.files[3];
    const c = try sema_mod.output.call(fx.s, fr, (try fx.refAt("= ^pick(", .call)).node);
    try std.testing.expectEqualStrings("kotlin.Int", fx.typeText(c.type_args[0]));
}

test "the left operand of in is contains' argument" {
    var fx = try fixture(&.{
        \\package app
        \\class LongR { operator fun contains(l: Long): Boolean = true }
        \\fun use() = 5 in LongR()
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const fr = &out.files[3];
    try std.testing.expectEqualStrings("kotlin.Long", fx.typeText(fr.typeOf(try fx.exprAt("^5 in"))));
}

test "a named argument for a vararg passes an array whole" {
    var fx = try fixture(&.{
        \\package app
        \\fun foo(vararg x: String, y: Int): Int = y
        \\fun use() = foo(x = arrayOf("a", "b"), y = 1)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const c = try fx.refAt("^foo(x =", .call);
    const src = c.detail.call.args[0];
    try std.testing.expect(src == .vararg and src.vararg.len == 1 and src.vararg[0].spread);
}

test "a reference on a nullable type takes the nullable receiver" {
    var fx = try fixture(&.{
        \\package app
        \\class A { fun own(): String = "" }
        \\fun A?.foo(): String = "foo"
        \\fun use() {
        \\    val f: (A?) -> String = A?::foo
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("A?::^foo", null, "app/foo");
    // The function the reference makes takes an `A?`.
    const r = try fx.refAt("A?::^foo", null);
    const params = fx.s.types.argsOf(r.detail.ref.ty);
    try std.testing.expect(params.len == 2 and fx.s.types.isNullable(params[0].ty));
}

test "a class sees the protected members its companion inherits" {
    var fx = try fixture(&.{
        \\package app
        \\open class A { protected fun foo(): Int = 1 }
        \\class B {
        \\    companion object : A()
        \\    fun bar() = foo()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("= ^foo()", .call, "app/A.foo");
}

test "an OptionalExpectation annotation class needs no actual" {
    var fx = try fixture(&.{
        \\package kotlin
        \\annotation class OptionalExpectation
        \\@OptionalExpectation
        \\expect annotation class Optional()
        \\expect annotation class Required()
    });
    defer fx.deinit();
    try fx.resolve();
    try expectMessages(&fx, &.{"`kotlin.Required` is an `expect` with no `actual`"});
}

test "a class's function takes the defaults another supertype's declares" {
    var fx = try fixture(&.{
        \\package app
        \\interface I { fun f(x: String = "1"): String }
        \\open class A { open fun f(x: String): String = x }
        \\class B : A(), I
        \\interface Foo { fun foo(a: Int = 1): Int }
        \\interface FooChain : Foo
        \\open class Impl { fun foo(a: Int): Int = a }
        \\class FooImpl : FooChain, Impl()
        \\fun use() {
        \\    B().f()
        \\    B().f("x")
        \\    FooImpl().foo()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    // Leaving `x` to its default, the call is I's `f`, dispatched to A's.
    try fx.expectRef("B().^f()", .call, "app/I.f");
    try fx.expectRef("B().^f(\"x\")", .call, "app/A.f");
    try fx.expectRef("FooImpl().^foo()", .call, "app/Foo.foo");
}

test "a type argument written _ is inferred" {
    var fx = try fixture(&.{
        \\package app
        \\class Box<A, B>(val b: B)
        \\fun <K, T> foo(x: (K) -> T): T = TODO()
        \\fun use() {
        \\    val x = foo<Int, _> { it.toLong() }
        \\    val b = Box<Int, _>("OK")
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const fr = &out.files[3];
    const f = try sema_mod.output.call(fx.s, fr, (try fx.refAt("^foo<Int, _>", .call)).node);
    try std.testing.expectEqualStrings("kotlin.Long", fx.typeText(f.type_args[1]));
    const b = try sema_mod.output.call(fx.s, fr, (try fx.refAt("^Box<Int, _>", .ctor)).node);
    try std.testing.expectEqualStrings("kotlin.String", fx.typeText(b.type_args[1]));
}

test "a member of an object expression keeps an object expression's type" {
    var fx = try fixture(&.{
        \\package app
        \\class A(val v: Int)
        \\fun use(): Int {
        \\    val c = object { val b = object { val a = A(1) } }
        \\    return c.b.a.v
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("c.b.a.^v", .read, "app/A.v");
}

test "a class's supertypes do not see its nested classifiers" {
    var fx = try fixture(&.{
        \\package app
        \\interface Base<A> { fun foo(): String = "OK" }
        \\class MyClass(val prop: app.Base<app.Base<Int>>) : Base<Base<Int>> by prop {
        \\    interface Base
        \\}
        \\fun use(d: MyClass) = d.foo()
        \\open class OtherClass {
        \\    fun bar(): String = "OK"
        \\    private class OtherClass<T>
        \\}
        \\class Derived : OtherClass()
        \\fun use2() = Derived().bar()
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("d.^foo()", .call, "app/Base.foo");
    try fx.expectRef("Derived().^bar()", .call, "app/OtherClass.bar");
}

test "a smart cast implicit receiver offers the member extensions of its cast type" {
    var fx = try fixture(&.{
        \\package app
        \\class Bob {
        \\    fun Bob.bar(): String = "OK"
        \\    val Bob.baz: String get() = "OK"
        \\}
        \\fun Any.foo(): String = if (this is Bob) bar() + baz else ""
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("^bar() +", .call, "app/Bob.bar");
}

test "a member extension property extends its class's type argument" {
    var fx = try fixture(&.{
        \\package app
        \\class Test<T> {
        \\    val T.foo: T get() = this
        \\}
        \\fun use(): String = with(Test<String>()) { "OK".foo }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("\"OK\".^foo", .read, "app/Test.foo");
}

test "this labeled with an enum entry's name is the entry" {
    var fx = try fixture(&.{
        \\package app
        \\enum class A {
        \\    X {
        \\        val x = "OK"
        \\        inner class Inner { fun foo() = this@X.x }
        \\        override val test = Inner().foo()
        \\    };
        \\    abstract val test: String
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a contract's implied is-check smart casts the call's receiver" {
    var fx = try fixture(&.{
        \\package app
        \\import kotlin.contracts.contract
        \\sealed class Status<out T> {
        \\    class Error<out T>(val error: String) : Status<T>()
        \\}
        \\fun <T> Status<T>.isError(): Boolean {
        \\    contract { returns(true) implies (this@isError is Status.Error) }
        \\    return this is Status.Error
        \\}
        \\fun <T> use(s: Status<T>): String = if (s.isError()) s.error else ""
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectRef("s.^error", .read, "app/Status.Error.error");
}

test "a lambda with a return without a value returns Unit and coerces its last statement" {
    var fx = try fixture(&.{
        \\package app
        \\fun <K> materialize(): K = TODO()
        \\fun <R> run(block: () -> R): R = block()
        \\fun use(b: Boolean) {
        \\    val r = run { if (b) return@run; 42 }
        \\    run { if (b) return@run; materialize() }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const fr = &out.files[3];
    const r = try sema_mod.output.call(fx.s, fr, (try fx.refAt("= ^run {", .call)).node);
    try std.testing.expectEqualStrings("kotlin.Unit", fx.typeText(r.type_args[0]));
    const m = try sema_mod.output.call(fx.s, fr, (try fx.refAt("return@run; ^materialize()", .call)).node);
    try std.testing.expectEqualStrings("kotlin.Unit", fx.typeText(m.type_args[0]));
}

test "super in an object expression's header is the enclosing class's" {
    var fx = try fixture(&.{
        \\package app
        \\interface A { fun foo(): String }
        \\class AImpl(val z: String) : A { override fun foo(): String = z }
        \\open class AFabric { open fun createA(): A = AImpl("OK") }
        \\class AWrapperFabric : AFabric() {
        \\    override fun createA(): A = AImpl("fail")
        \\    fun createMyA(): A = object : A by super.createA() {}
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("super.^createA()", .call, "app/AFabric.createA");
}

test "an inner class of an object expression sees the class declaring the expression" {
    var fx = try fixture(&.{
        \\package app
        \\class C {
        \\    val k = "K"
        \\    private val o = object {
        \\        inner class Inner { val x = "O" + k }
        \\        val innerX = Inner().x
        \\    }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("\"O\" + ^k", .read, "app/C.k");
}

test "is with a bare type alias infers the alias's type arguments" {
    var fx = try fixture(&.{
        \\package app
        \\sealed class C<out T, out U>
        \\class B<out U>(val x: U) : C<Nothing, U>()
        \\typealias Z<U> = B<U>
        \\fun baz(x: String): String = x
        \\fun use(y: C<Int, String>): String = if (y is Z) baz(y.x) else ""
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a labeled anonymous function names itself and its receiver" {
    var fx = try fixture(&.{
        \\package app
        \\class A(val x: String)
        \\val <T> T.a: T.() -> String
        \\    get() = fun1@ fun T.(): String { return (this@fun1 as A).x + (this@a as A).x }
        \\fun withLabel() = l@ fun (): Boolean { return@l true }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "an extension property's delegate takes its extension receiver as thisRef" {
    var fx = try fixture(&.{
        \\package app
        \\import kotlin.reflect.KProperty
        \\class UserDataProperty<in R>(val key: String) {
        \\    operator fun getValue(thisRef: R, desc: KProperty<*>): String = key
        \\    operator fun setValue(thisRef: R, desc: KProperty<*>, value: String?) {}
        \\}
        \\var String.calc: String by UserDataProperty("K")
    ,
        \\package kotlin.reflect
        \\public interface KCallable<out R> { public val name: String }
        \\public interface KProperty<out V> : KCallable<V>
        \\public interface KProperty0<out V> : KProperty<V>, () -> V { public fun get(): V }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const fr = &out.files[3];
    const c = try sema_mod.output.call(fx.s, fr, (try fx.refAt("^UserDataProperty(\"K\")", .ctor)).node);
    try std.testing.expectEqualStrings("kotlin.String", fx.typeText(c.type_args[0]));
}

test "nested generic calls fix every level however deep" {
    var fx = try fixture(&.{
        \\package app
        \\class W<T>(val v: T)
        \\fun <T> wrap(v: T): W<T> = W(v)
        \\fun W<W<W<W<W<W<W<W<W<W<Int>>>>>>>>>>.depth() = "OK"
        \\fun use() = wrap(wrap(wrap(wrap(wrap(wrap(wrap(wrap(wrap(wrap(1)))))))))).depth()
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "two overloads of one class stay two through a substitution that erases them alike" {
    var fx = try fixture(&.{
        \\package app
        \\open class A<T> {
        \\    fun foo(x: T) = "O"
        \\    fun foo(x: A<T>) = "K"
        \\}
        \\class B : A<A<String>>()
        \\fun use(x: A<String>, y: A<A<String>>) = B().foo(x) + B().foo(y) + y.foo(y)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a reference to an extension function is called on a receiver" {
    var fx = try fixture(&.{
        \\package app
        \\fun Int.plusOne(x: Int) = this + x
        \\class A
        \\fun A?.foo(): String = "O"
        \\fun use(): String {
        \\    val p = Int::plusOne
        \\    val a = A?::foo
        \\    return a(null) + null.a() + (3.p(4) + p(1, 2))
        \\}
    ,
        \\package kotlin.reflect
        \\public interface KCallable<out R> { public val name: String }
        \\public interface KFunction<out R> : KCallable<R>, Function<R>
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("null.^a()", .invoke, "kotlin/Function1.invoke");
}

test "a reference names the local function a local variable of its name does not hide" {
    var fx = try fixture(&.{
        \\package app
        \\fun top(x: String): String = x
        \\fun use(): String {
        \\    fun h(x: Int): String = "i"
        \\    fun h(x: String): String = x
        \\    val a: (Int) -> String = ::h
        \\    val b: (String) -> String = ::h
        \\    fun f(x: String): String = x
        \\    val f = f("O")
        \\    val g = ::f
        \\    val top = 1
        \\    val t = ::top
        \\    return a(1) + b("s") + g(f) + t("x")
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const s = fx.s;
    const a = try fx.refAt("(Int) -> String = ::^h", .ref);
    try std.testing.expectEqual(s.t.int, try sema_mod.headers.paramType(s, s.syms.functionInfo(a.target).params[0]));
    const b = try fx.refAt("(String) -> String = ::^h", .ref);
    try std.testing.expectEqual(s.t.string, try sema_mod.headers.paramType(s, s.syms.functionInfo(b.target).params[0]));
    try std.testing.expectEqual(sema_mod.symbols.Kind.function, s.syms.kind((try fx.refAt("g = ::^f", .ref)).target));
    try fx.expectRef("t = ::^top", .ref, "app/top");
}

test "a reference to a generic extension takes the type arguments its receiver fixes" {
    var fx = try fixture(&.{
        \\package app
        \\class Box<T>(val v: T)
        \\fun <T> T.self(): T = this
        \\val <T> Box<T>.inner: T get() = v
        \\var <T> T.fn: T.() -> String
        \\    get() = TODO()
        \\    set(value) {}
        \\fun use(): Int {
        \\    val r = Int::self
        \\    val s = Box<String>::inner
        \\    val b = Box("xy")::inner
        \\    val q = 41::self
        \\    val a = Int::fn
        \\    return r(41) + s(Box("ab")).length + b().length + q() + a.get(1)(1).length
        \\}
    ,
        \\package kotlin.reflect
        \\public interface KCallable<out R> { public val name: String }
        \\public interface KFunction<out R> : KCallable<R>, Function<R>
        \\public interface KProperty<out V> : KCallable<V>
        \\public interface KProperty0<out V> : KProperty<V>, () -> V { public fun get(): V }
        \\public interface KProperty1<T, out V> : KProperty<V>, (T) -> V { public fun get(receiver: T): V }
        \\public interface KMutableProperty1<T, V> : KProperty1<T, V> { public fun set(receiver: T, value: V) }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "an object's alias written with type arguments is a type on the left of a reference" {
    var fx = try fixture(&.{
        \\package app
        \\object SomeObject { fun foo(): String = "OK" }
        \\typealias OnSomeObject<T> = SomeObject
        \\class Box<T>(val v: T) { fun get(): T = v }
        \\typealias Boxed<T> = Box<List<T>>
        \\fun use(): String {
        \\    val withTypeArgument = OnSomeObject<Any>::foo
        \\    val withoutTypeArgument = OnSomeObject::foo
        \\    val g = Boxed<String>::get
        \\    return withTypeArgument(SomeObject) + withoutTypeArgument() + g(Box(listOf("a")))[0]
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "an elvis's left side is expected to be the nullable type expected of it" {
    var fx = try fixture(&.{
        \\package app
        \\interface PsiElement {
        \\    fun <T : PsiElement> findChildByType(i: Int): T? = null
        \\}
        \\class Leaf : PsiElement {
        \\    fun element(): PsiElement = findChildByType(42) ?: this
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("= ^findChildByType(42)", .call)).node);
    try std.testing.expectEqualStrings("app.PsiElement", fx.typeText(c.type_args[0]));
}

test "an override may write its type parameter's bounds in another order" {
    var fx = try fixture(&.{
        \\package app
        \\interface A
        \\interface B
        \\interface C
        \\interface X {
        \\    fun <T> foo(t: T): String where T : A, T : B
        \\    fun <T> foo(t: T): String where T : C, T : Any
        \\}
        \\class Y : X {
        \\    override fun <T> foo(t: T): String where T : B, T : A = "1"
        \\    override fun <T> foo(t: T): String where T : Any, T : C = "2"
        \\}
        \\fun use(ab: Any, c: C): String {
        \\    val y = Y()
        \\    val x = object : A, B {}
        \\    return y.foo(x) + y.foo(c)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "of two extension properties the one on the more specific receiver is read" {
    var fx = try fixture(&.{
        \\package app
        \\class A
        \\class B { operator fun invoke(f: B.() -> Unit) = 2 }
        \\open class C
        \\val C.attr: A get() = A()
        \\open class D : C()
        \\val D.attr: B get() = B()
        \\fun use(d: D): Int {
        \\    val b: B = d.attr
        \\    return d.attr {}
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "this in an object expression's supertype arguments is the supertype's companion" {
    var fx = try fixture(&.{
        \\package app
        \\open class W(a: W.Companion) { companion object }
        \\open class V(a: String)
        \\fun String.test(): Int {
        \\    val o = object : W(this) {}
        \\    val p = object : V(this) {}
        \\    return 1
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try std.testing.expectEqualStrings("Companion", fx.s.str(fx.s.syms.name((try fx.refAt("W(^this)", .this_)).target)));
    try std.testing.expectEqualStrings("test", fx.s.str(fx.s.syms.name((try fx.refAt("V(^this)", .this_)).target)));
}

test "a lambda is checked against the type arguments written on the call" {
    var fx = try fixture(&.{
        \\package app
        \\class TypeToken<T>
        \\interface Ctx<C : Any> {
        \\    companion object {
        \\        operator fun <C : Any> invoke(type: TypeToken<C>, value: C): Ctx<C> = TODO()
        \\        operator fun <C : Any> invoke(type: TypeToken<C>, getValue: () -> C): Ctx<C> = TODO()
        \\    }
        \\}
        \\fun <C : Any> lazyCtx(getContext: () -> C): Ctx<C> = Ctx<C>(TypeToken()) { getContext() }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a variable below two unrelated types is their intersection" {
    var fx = try fixture(&.{
        \\package app
        \\class In<in K>
        \\fun <E> intersect(vararg x: In<E>): E = TODO()
        \\fun use(): Any? = intersect(In<Int>(), In<String>())
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("= ^intersect(", .call)).node);
    try std.testing.expect(fx.s.types.get(c.type_args[0]) == .intersection);
}

test "contravariant arguments join at their intersection" {
    var fx = try fixture(&.{
        \\package app
        \\class In<in K>
        \\interface A
        \\interface B
        \\fun <T> pick(a: T, b: T): T = a
        \\fun joined() = pick(In<A>(), In<B>())
        \\fun empty() = pick(In<Int>(), In<String>())
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("joined() = ^pick(", .call)).node);
    try std.testing.expect(fx.s.types.get(fx.s.types.argsOf(c.type_args[0])[0].ty) == .intersection);
    // No class is both an `Int` and a `String`: `In<*>`.
    const e = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("empty() = ^pick(", .call)).node);
    try std.testing.expect(fx.s.types.argsOf(e.type_args[0])[0].variance == .star);
}

test "a variable whose join overshoots its upper bound is that bound" {
    var fx = try fixture(&.{
        \\package app
        \\class In<in K>
        \\fun <E> intersect(vararg x: In<E>): E = TODO()
        \\fun array(): Any? = intersect(x = arrayOf(In<Int>(), In<String>()))
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a class that is not a value does not hide an imported object of its name" {
    var fx = try fixture(&.{
        \\package app
        \\import app.A.B.*
        \\private enum class C { E1 }
        \\class A {
        \\    private class B { object C }
        \\    fun test() { C }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("test() { ^C }", .object, "app/A.B.C");
}

test "an argument's branches left open take their type from the parameter" {
    var fx = try fixture(&.{
        \\package app
        \\interface MList<T> : List<T>
        \\fun <T> none(): List<T> = TODO()
        \\fun <T> mlist(): MList<T> = TODO()
        \\class Holder(val list: List<String>?)
        \\fun use(c: Boolean) {
        \\    Holder(if (c) none() else mlist())
        \\    Holder(if (c) none() else null)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("else ^mlist()", .call)).node);
    try std.testing.expectEqualStrings("kotlin.String", fx.typeText(c.type_args[0]));
}

test "a member of a smart cast's part is the override another part declares" {
    var fx = try fixture(&.{
        \\package app
        \\interface A<T> { fun foo(x: T?) {} }
        \\interface B : A<String> { override fun foo(x: String?) }
        \\fun <T> bar(x: A<in T>) {
        \\    if (x is B) x.foo(null)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("x.^foo(null)", .call, "app/B.foo");
}

test "an object expression's type carries the type parameters in scope" {
    var fx = try fixture(&.{
        \\package app
        \\interface Some<T>
        \\class Test {
        \\    private fun <T : Any> T.self() = object {
        \\        fun calc(): T = this@self
        \\    }
        \\    fun box(): Int = 1.self().calc() + 1
        \\}
        \\object Container {
        \\    private fun <T> someMethod() = object : Some<T> {}
        \\    class SomeClass : Some<SomeClass> by someMethod()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a data object declares no copy of its own" {
    var fx = try fixture(&.{
        \\package app
        \\data object A { fun copy() = "O" }
        \\data object B { fun copy(test: String) = test }
        \\fun use(): String = A.copy() + B.copy("K")
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("A.^copy()", .call, "app/A.copy");
}

test "an alias of an inner class infers its parameters from the outer instance" {
    var fx = try fixture(&.{
        \\package app
        \\class Foo<T> {
        \\    inner class Inner(val p: String)
        \\    inner class Inner2<T2>
        \\}
        \\typealias InnerAlias<K> = Foo<K>.Inner
        \\typealias InnerAlias3<K, K2> = Foo<K2>.Inner2<K>
        \\fun use(): String {
        \\    val foo = Foo<String>()
        \\    foo.InnerAlias3<Int, String>()
        \\    return foo.InnerAlias("OK").p
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("foo.^InnerAlias(\"OK\")", .ctor)).node);
    try std.testing.expectEqualStrings("kotlin.String", fx.typeText(c.type_args[0]));
}

test "a value equal to null is a Nothing? as well as its type" {
    var fx = try fixture(&.{
        \\package app
        \\fun String?.foo(): String = this ?: "OK"
        \\fun f(i: Int?, s: String?): String {
        \\    if (s == null) {
        \\        val n: Int? = s?.length
        \\    }
        \\    if (i == null) return i.foo()
        \\    return "x"
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("i.^foo()", .call, "app/foo");
}

test "provideDelegate takes the instance declaring the property" {
    var fx = try fixture(&.{
        \\package app
        \\object CommonCase {
        \\    interface Fas<D, E, R>
        \\    fun <D, E, R> delegate(): Fas<D, E, R> = TODO()
        \\    operator fun <D, E, R> Fas<D, E, R>.provideDelegate(host: D, p: Any?): Fas<D, E, R> = this
        \\    operator fun <D, E, R> Fas<D, E, R>.getValue(receiver: E, p: Any?): R = TODO()
        \\    val Long.test2: String by delegate<CommonCase, Long, String>()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "an operator extension applies only within its type parameters' bounds" {
    var fx = try fixture(&.{
        \\package app
        \\open class MyClass(val value: String)
        \\operator fun <P : MyClass> P.provideDelegate(host: Any?, p: Any): P = this
        \\operator fun <V> V.getValue(receiver: Any?, p: Any): V = this
        \\val testO by MyClass("O")
        \\val testK by "K"
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
}

test "a lower bound naming an open variable fits below the type its variable is fixed to" {
    var fx = try fixture(&.{
        \\package app
        \\interface Box<out E>
        \\fun <E : Comparable<E>> make(): Box<E> = TODO()
        \\fun <T> same(a: T, b: T): Boolean = true
        \\fun consume(x: Any?) {}
        \\fun use(b: Box<String>) {
        \\    consume(same(b, make()))
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("same(b, ^make())", .call)).node);
    try std.testing.expectEqualStrings("kotlin.String", fx.typeText(c.type_args[0]));
}

test "a literal branch takes the integral type the branches join to" {
    var fx = try fixture(&.{
        \\package app
        \\fun big(n: Int): Long = 1L
        \\fun use(c: Boolean, d: Boolean, x: Long?, n: Int) {
        \\    val a = if (c) big(n) else 0
        \\    val b = if (c) 5L else if (d) { 1 } else -2
        \\    val e = when { c -> 3L; else -> 4 }
        \\    val f = x ?: 6
        \\    takeLong(if (c) 7 else 8)
        \\}
        \\fun takeLong(x: Long) {}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const fr = &out.files[3];
    for ([_][]const u8{ "else ^0", "{ ^1 }", "else ^-2", "else -^2", "else -> ^4", "?: ^6", "(c) ^7", "else ^8" }) |needle| {
        try std.testing.expectEqualStrings("kotlin.Long", fx.typeText(fr.typeOf(try fx.exprAt(needle))));
    }
}

test "an in-projected argument is a lower bound of an invariant parameter" {
    var fx = try fixture(&.{
        \\package app
        \\fun <T> Array<out T>.copyTo(destination: Array<T>): Array<T> = destination
        \\fun <T> exactly(value: T) {}
        \\fun use(source: Array<out Int>, dest: Array<in Number>) {
        \\    val c = source.copyTo(dest)
        \\    exactly<Array<in Number>>(c)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("source.^copyTo(dest)", .call)).node);
    try std.testing.expectEqualStrings("kotlin.Number", fx.typeText(c.type_args[0]));
}

test "a variable below one fixed to a type is at most that type" {
    var fx = try fixture(&.{
        \\package app
        \\fun <T> passThrough(array: Array<T>): Array<T> = array
        \\fun <T> none(): Array<T> = TODO()
        \\fun <T> eq(a: Array<out T>?, b: Array<out T>?): Boolean = true
        \\fun consume(b: Boolean) {}
        \\fun use(expected: Array<Int>) {
        \\    consume(eq(expected, passThrough(none())))
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("passThrough(^none())", .call)).node);
    try std.testing.expectEqualStrings("kotlin.Int", fx.typeText(c.type_args[0]));
}

test "type parameters bounded by each other wait for the lambda that gives one" {
    var fx = try fixture(&.{
        \\package app
        \\interface Service<Self : Service<Self, TEvent>, in TEvent : Event<Self>>
        \\interface Event<out T : Service<out T, *>>
        \\fun <TService : Service<TService, TEvent>, TEvent : Event<TService>> event(handler: (TEvent) -> Unit) {}
        \\class SomeService : Service<SomeService, SomeService.SomeEvent> {
        \\    class SomeEvent : Event<SomeService>
        \\}
        \\fun use() {
        \\    event { someEvent: SomeService.SomeEvent -> }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("^event {", .call)).node);
    try std.testing.expectEqualStrings("app.SomeService", fx.typeText(c.type_args[0]));
}

test "a type parameter and its definitely non-null form join to the parameter" {
    var fx = try fixture(&.{
        \\package app
        \\interface Spec<T>
        \\class Spring<T>(val t: T?) : Spec<T>
        \\fun <T> spring(t: T?): Spring<T> = Spring(t)
        \\fun <T, N : Any> use(spec: Spec<T>, th: T?, n: N) {
        \\    val j = if (th != null) spring(th) else spec
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const fr = &out.files[3];
    try std.testing.expectEqualStrings("app.Spec<out T>", fx.typeText(fr.typeOf(try fx.exprAt("= ^if (th != null)"))));
    const s = fx.s;
    const pkg = s.syms.package_by_fqn.get(s.names.lookup("app").?).?;
    const f = sema_mod.scope.membersOf(s, pkg, s.names.lookup("use").?)[0];
    const tps = s.syms.functionInfo(f).type_params;
    const t = try s.types.intern(.{ .param = .{ .sym = tps[0], .nullable = false } });
    const t_q = try s.types.makeNullable(t);
    const t_nn = try s.types.definitelyNotNull(t);
    const n = try s.types.intern(.{ .param = .{ .sym = tps[1], .nullable = false } });
    const n_nn = try s.types.definitelyNotNull(n);
    try std.testing.expect(try subtyping.isSubtype(s, t_nn, t));
    try std.testing.expect(!try subtyping.isSubtype(s, t, t_nn));
    try std.testing.expect(!try subtyping.isSubtype(s, t_q, t));
    try std.testing.expect(try subtyping.isSubtype(s, t, t_q));
    try std.testing.expect(try subtyping.isSubtype(s, n, n_nn));
    try std.testing.expectEqualStrings("T", fx.typeText(try subtyping.commonSupertype(s, &.{ t_nn, t })));
    try std.testing.expectEqualStrings("T?", fx.typeText(try subtyping.commonSupertype(s, &.{ t_nn, t_q })));
}

test "a delegate's getValue takes its type parameters from the property's type" {
    var fx = try fixture(&.{
        \\package app
        \\class Holder<V>(val v: V)
        \\operator fun <V, V1 : V> Holder<V>.getValue(thisRef: Any?, p: Any?): V1 = TODO()
        \\fun use(h: Holder<Any?>) {
        \\    val n: Int by h
        \\    val s: String? by h
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const fr = &out.files[3];
    const n = try sema_mod.output.callOf(fx.s, fr, (try fx.refAt("Int by ^h", .get_value)).node, .get_value);
    try std.testing.expectEqualStrings("kotlin.Int", fx.typeText(n.type_args[1]));
    const q = try sema_mod.output.callOf(fx.s, fr, (try fx.refAt("String? by ^h", .get_value)).node, .get_value);
    try std.testing.expectEqualStrings("kotlin.String?", fx.typeText(q.type_args[1]));
}

test "a delegate whose getValue returns what the property cannot hold is reported" {
    var fx = try fixture(&.{
        \\package app
        \\interface P
        \\interface B
        \\class Box<T>(val v: T) { operator fun getValue(thisRef: Any?, p: Any?): T = v }
        \\fun <T> box(f: () -> T): Box<T> = Box(f())
        \\fun enc(): B = TODO()
        \\fun pee(): P = TODO()
        \\abstract class Base { abstract val q: P }
        \\class C : Base() {
        \\    override val q: P by box { enc() }
        \\    val ok: P by box { pee() }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try expectMessages(&fx, &.{"the delegate's `getValue` returns `B`, but the property is a `P`"});
}

test "a member an object inherits is imported from the object" {
    var fx = try fixture(&.{
        \\package app
        \\import app.C.f
        \\import app.C.fromClass
        \\import app.C.fromInterface
        \\import app.C.genericFromSuper
        \\interface I<G> {
        \\    fun <T> T.fromInterface(): T = this
        \\    fun genericFromSuper(g: G) = g
        \\}
        \\open class BaseClass {
        \\    val <T> T.fromClass: T get() = this
        \\}
        \\object C : BaseClass(), I<String> {
        \\    fun f(s: Int) = 1
        \\}
        \\fun use() {
        \\    f(1)
        \\    9.fromInterface()
        \\    "10".fromClass
        \\    genericFromSuper("11")
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const c = fx.class("app.C");
    for ([_][]const u8{ "^f(1)", "9.^fromInterface()", "\"10\".^fromClass", "^genericFromSuper(\"11\")" }) |needle| {
        const r = try fx.ref(needle);
        try std.testing.expect(r.dispatch == .implicit and r.dispatch.implicit.kind == .object and r.dispatch.implicit.owner == c);
    }
    try fx.expectTarget("\"10\".^fromClass", "app/BaseClass.fromClass");
    try fx.expectTarget("^genericFromSuper(\"11\")", "app/I.genericFromSuper");
    const out = try sema_mod.output.build(fx.s);
    try std.testing.expectEqualStrings("kotlin.String", fx.typeText(out.files[3].typeOf(try fx.exprAt("^genericFromSuper(\"11\")"))));
}

test "an import of a name an object and its supertypes do not declare is unresolved" {
    var fx = try fixture(&.{
        \\package app
        \\import app.O.nope
        \\open class Base { fun yes() = 1 }
        \\object O : Base()
        \\fun use() = O.yes()
    });
    defer fx.deinit();
    try fx.resolve();
    try expectMessages(&fx, &.{"unresolved import `app.O.nope`"});
}

test "a reference on a class is bound to its companion when the class's own member does not fit" {
    var fx = try fixture(&.{
        \\package app
        \\open class A {
        \\    fun instance() = true
        \\    companion object : A() { fun companion() = true }
        \\}
        \\fun call(f: () -> Boolean) = f()
        \\fun callParameter(f: (A) -> Boolean, p: A) = f(p)
        \\fun use() {
        \\    call(A::instance)
        \\    callParameter(A::instance, A)
        \\    val u = A::instance
        \\    call(A::companion)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const comp = fx.class("app.A.Companion");
    for ([_][]const u8{ "call(A::^instance)", "call(A::^companion)" }) |needle| {
        const r = try fx.refAt(needle, .ref);
        try std.testing.expect(r.detail.ref.bound == .implicit and r.detail.ref.bound.implicit.owner == comp);
    }
    try std.testing.expectEqual(comp, (try fx.refAt("call(^A::instance)", .object)).target);
    try std.testing.expectEqual(comp, (try fx.refAt("call(^A::companion)", .object)).target);
    for ([_][]const u8{ "callParameter(A::^instance", "u = A::^instance" }) |needle| {
        const r = try fx.refAt(needle, .ref);
        try std.testing.expect(r.detail.ref.bound != .implicit);
    }
}

test "a private member of a supertype is not inherited" {
    var fx = try fixture(&.{
        \\package app
        \\open class X(private val n: String) {
        \\    fun foo(): String = object : X("inner") { fun print(): String = n }.print()
        \\}
        \\interface A { val c: String get() = "OK" }
        \\interface B { private val c: String get() = "FAIL" }
        \\open class C { private val c: String = "FAIL" }
        \\open class D : C(), A, B { val b = c }
        \\fun use() = D().c
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const n = try fx.ref("String = ^n }");
    try std.testing.expect(n.dispatch == .implicit and n.dispatch.implicit.owner == fx.class("app.X"));
    try fx.expectTarget("val b = ^c", "app/A.c");
    try fx.expectTarget("D().^c", "app/A.c");
}

test "a delegate's call takes the property's type before its references are resolved" {
    var fx = try fixture(&.{
        \\package app
        \\class IC<T : String>(val ok: T? = null)
        \\class Lz<T>(val v: T)
        \\fun <T> lz(f: () -> T): Lz<T> = Lz(f())
        \\operator fun <T> Lz<T>.getValue(thisRef: Any?, p: Any?): T = v
        \\fun use() {
        \\    val c: IC<String> by lz(::IC)
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const fr = &out.files[3];
    const c = try sema_mod.output.call(fx.s, fr, (try fx.refAt("^lz(::IC)", .call)).node);
    try std.testing.expectEqualStrings("app.IC<kotlin.String>", fx.typeText(c.type_args[0]));
}

test "a delegate's provideDelegate is inferred through to its getValue" {
    var fx = try fixture(&.{
        \\package app
        \\class Lz<T>(val v: T)
        \\operator fun <T> Lz<T>.getValue(thisRef: Any?, p: Any?): T = v
        \\interface DelegateProvider<out T> {
        \\    operator fun provideDelegate(receiver: Any?, prop: Any?): Lz<T>
        \\}
        \\fun <Value : Any> delegate(): DelegateProvider<Value> = TODO()
        \\fun use() {
        \\    val value: String by delegate()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("by ^delegate()", .call)).node);
    try std.testing.expectEqualStrings("kotlin.String", fx.typeText(c.type_args[0]));
}

test "a data class inherits the Any members a superclass makes final" {
    var fx = try fixture(&.{
        \\package app
        \\abstract class Base {
        \\    final override fun toString() = "OK"
        \\    final override fun hashCode() = 42
        \\}
        \\open class Open { override fun toString() = "open" }
        \\data class D(val x: String) : Base()
        \\data object O : Open()
        \\fun use(d: D) = d.toString() + d.hashCode() + d.equals(d) + O.toString()
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("d.^toString()", "app/Base.toString");
    try fx.expectTarget("d.^hashCode()", "app/Base.hashCode");
    try fx.expectTarget("d.^equals(d)", "app/D.equals");
    try fx.expectTarget("O.^toString()", "app/O.toString");
}

test "a builder's variable is inferred from what an anonymous function, a getter and a delegation declare" {
    var fx = try fixture(&.{
        \\package app
        \\class TargetType
        \\interface Buildee<TV>
        \\fun <PTV> build(instructions: Buildee<PTV>.() -> Unit): Buildee<PTV> = TODO()
        \\fun a() = build { fun(): Buildee<TargetType> = this }
        \\fun b() = build {
        \\    class LocalClass {
        \\        val p: Buildee<TargetType>
        \\            get() = this@build
        \\    }
        \\}
        \\fun c() = build { class Source : Buildee<TargetType> by this@build }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const fr = &out.files[3];
    for ([_][]const u8{ "a() = ^build", "b() = ^build", "c() = ^build" }) |n| {
        const c = try sema_mod.output.call(fx.s, fr, (try fx.refAt(n, .call)).node);
        try std.testing.expectEqualStrings("app.TargetType", fx.typeText(c.type_args[0]));
    }
}

test "a value smart cast to a subclass keeps the private members of its class" {
    var fx = try fixture(&.{
        \\package app
        \\open class Base {
        \\    fun foo(): String = when (this) {
        \\        is Derived -> baz()
        \\        else -> "fail"
        \\    }
        \\    fun other(x: Base) = if (x is Derived) x.baz() else "no"
        \\    private fun baz(): String = "OK"
        \\}
        \\class Derived : Base()
        \\abstract class Base2 {
        \\    fun foo(): String = when (this) {
        \\        is Derived2 -> qux()
        \\        else -> "fail"
        \\    }
        \\    private fun Derived2.qux(): String = "OK"
        \\}
        \\class Derived2 : Base2()
        \\abstract class Snap {
        \\    abstract val obs: Int
        \\    private fun p() = 1
        \\    fun f(x: Snap?) { if (x is Mut) x.obs = 2 }
        \\}
        \\class Mut : Snap() { override var obs: Int = 0 }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("-> ^baz()", "app/Base.baz");
    try fx.expectTarget("x.^baz()", "app/Base.baz");
    try fx.expectTarget("-> ^qux()", "app/Base2.qux");
    // The override the subclass declares is still the member.
    try fx.expectTarget("x.^obs = 2", "app/Mut.obs");
}

test "a builder's variable stays open for every lambda of the call" {
    var fx = try fixture(&.{
        \\package app
        \\open class TargetTypeBase
        \\class TargetType : TargetTypeBase()
        \\fun consumeTargetTypeBase(value: TargetTypeBase) {}
        \\fun consumeTargetType(value: TargetType) {}
        \\class Buildee<TV>
        \\fun <PTV> parallelBuild(a: Buildee<PTV>.(PTV) -> Unit, b: Buildee<PTV>.(PTV) -> Unit): Buildee<PTV> = TODO()
        \\fun use() = parallelBuild({ consumeTargetTypeBase(it) }, { consumeTargetType(it) })
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    const out = try sema_mod.output.build(fx.s);
    const c = try sema_mod.output.call(fx.s, &out.files[3], (try fx.refAt("= ^parallelBuild(", .call)).node);
    try std.testing.expectEqualStrings("app.TargetType", fx.typeText(c.type_args[0]));
}

test "a supertype's private member is found and refused as invisible" {
    var fx = try fixture(&.{
        \\package app
        \\open class Base {
        \\    private val privateState: String = "B"
        \\    private var counter: Int = 0
        \\    private fun helper(x: Int): String = "h"
        \\}
        \\class Derived(val derivedState: Int) : Base()
        \\fun write(value: Derived) = value.privateState
        \\fun bump(value: Derived) { value.counter = 2 }
        \\fun call(value: Derived) = value.helper(1)
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectTarget("value.^privateState", "app/Base.privateState");
    try fx.expectTarget("value.^helper(1)", "app/Base.helper");
    try expectMessages(&fx, &.{
        "cannot access 'val privateState: String': it is private in 'Base'.",
        "cannot access 'var counter: Int': it is private in 'Base'.",
        "cannot access 'fun helper(x: Int): String': it is private in 'Base'.",
    });
}

test "a compiler plugin's generated code reads a supertype's private property" {
    var fx = try fixtureGenerated(&.{
        \\package app
        \\open class Base { private val privateState: String = "B" }
        \\class Derived(val derivedState: Int) : Base()
    }, &.{
        \\package app
        \\fun write(value: Derived) = value.privateState
    });
    defer fx.deinit();
    try fx.resolve();
    try expectMessages(&fx, &.{});
}

test "a class inheriting a val and a var of one type has the var" {
    var fx = try fixture(&.{
        \\package app
        \\abstract class A { abstract val x: String }
        \\interface B { var x: String }
        \\abstract class C : A(), B
        \\fun test(c: C) { c.x = "OK" }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("c.^x = ", "app/B.x");
}

test "a when that a value can fall through is reported where it must match" {
    var fx = try fixture(&.{
        \\package app
        \\sealed interface S
        \\data class A(val n: Int) : S
        \\data class B(val s: String) : S
        \\object C : S
        \\sealed class T : S
        \\class T1 : T()
        \\class T2 : T()
        \\enum class E { X, Y, Z }
        \\fun p() {}
        \\fun f1(x: S): String = when (x) {
        \\    is A -> "A"
        \\}
        \\fun f2(x: S?): String = when (x) {
        \\    is A -> "A"
        \\    is B -> "B"
        \\    C -> "C"
        \\    is T -> "T"
        \\}
        \\fun f3(e: E?): String = when (e) {
        \\    E.X -> "x"
        \\}
        \\fun f4(b: Boolean?): String = when (b) {
        \\    true -> "t"
        \\    false -> "f"
        \\}
        \\fun f5(x: Any): String = when {
        \\    x is String -> "s"
        \\}
        \\fun f6(x: S) {
        \\    when (x) {
        \\        is A -> p()
        \\    }
        \\}
        \\fun ok1(x: S): String = when (x) {
        \\    !is A -> "n"
        \\    is A -> "a"
        \\}
        \\fun <V : S> ok2(x: V): String = when (x) {
        \\    is A -> "A"
        \\    is B -> "B"
        \\    C -> "C"
        \\    is T -> "T"
        \\}
        \\fun ok3(x: Any): String = if (x is S) when (x) {
        \\    is A, is B, C, is T -> "x"
        \\} else "no"
        \\fun ok4(x: S?): String = when (x) {
        \\    is A? -> "a"
        \\    is B, C, is T1, is T2 -> "b"
        \\}
        \\fun ok5(i: Int) {
        \\    when (i) {
        \\        1 -> p()
        \\    }
        \\    run { when (i) { 1 -> p() } }
        \\    if (i > 0) when (i) { 1 -> p() }
        \\    while (i > 5) when (i) { 1 -> p() }
        \\}
        \\fun ok6(e: E): Int {
        \\    val r = when (e) {
        \\        E.X -> 1
        \\        E.Y -> 2
        \\        E.Z -> 3
        \\    }
        \\    return r
        \\}
        \\fun ok7(x: Any): String = when (x) {
        \\    is Any -> "any"
        \\}
        \\fun d1(b: Boolean): Int {
        \\    if (b == false) return 1
        \\    return when (b) { true -> 2 }
        \\}
        \\fun d2(b: Boolean?): Int {
        \\    if ((b == true) == false) return 1
        \\    return when (b) { true -> 2 }
        \\}
        \\fun d3(b: Boolean?): Int {
        \\    if ((b == true) == true) return 1
        \\    return when (b) {
        \\        null -> 2
        \\        false -> 3
        \\    }
        \\}
        \\fun d4(e: E): Int {
        \\    if (e == E.X) return 1
        \\    if (e == E.Y) return 2
        \\    return when (e) { E.Z -> 3 }
        \\}
        \\fun d5(x: S): String {
        \\    if (x is A) return "a"
        \\    (x is B) && throw Throwable()
        \\    return when (x) {
        \\        C -> "c"
        \\        is T -> "t"
        \\    }
        \\}
        \\fun d6(x: S): String {
        \\    var y = x
        \\    if (y is A) return "a"
        \\    y = x
        \\    return when (y) {
        \\        is B -> "b"
        \\        C -> "c"
        \\        is T -> "t"
        \\    }
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try expectMessages(&fx, &.{
        "'when' expression must be exhaustive. Add the 'is B', 'C', 'is T1', 'is T2' branches or an 'else' branch.",
        "'when' expression must be exhaustive. Add the 'null' branch or an 'else' branch.",
        "'when' expression must be exhaustive. Add the 'Y', 'Z', 'null' branches or an 'else' branch.",
        "'when' expression must be exhaustive. Add the 'null' branch or an 'else' branch.",
        "'when' expression must be exhaustive. Add an 'else' branch.",
        "'when' expression must be exhaustive. Add the 'is B', 'C', 'is T1', 'is T2' branches or an 'else' branch.",
        // Past an assignment, what was ruled out before no longer is.
        "'when' expression must be exhaustive. Add the 'is A' branch or an 'else' branch.",
    });
}

test "a when guard sees its pattern's smart cast and gives the body its own" {
    var fx = try fixture(&.{
        \\package app
        \\sealed interface S
        \\class A(val n: Int) : S
        \\class B(val s: String) : S
        \\fun f(x: S, y: String?): Int = when (x) {
        \\    is A if x.n > 0 -> x.n
        \\    is B if y != null -> y.length
        \\    is A -> 0
        \\    is B -> 1
        \\}
        \\fun g(x: S): Int = when (x) {
        \\    is A if x.n > 0 -> 1
        \\    is B -> 2
        \\}
        \\fun h(i: Int): Int = when {
        \\    i > 0 if i < 10 -> 1
        \\    else -> 2
        \\}
        \\fun k(x: S): Int = when (x) {
        \\    is A, is B if true -> 1
        \\    else -> 2
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectTarget("if x.^n > 0 -> x.n", "app/A.n");
    try fx.expectTarget("-> y.^length", "kotlin/String.length");
    try expectMessages(&fx, &.{
        "'when' expression must be exhaustive. Add the 'is A' branch or an 'else' branch.",
        "guard statements are only allowed in 'when' with subject.",
        "use of comma in 'when' condition with guard statement is not allowed.",
    });
}

test "a when's later branches see the subject as the earlier failed type tests leave it" {
    var fx = try fixture(&.{
        \\package app
        \\fun f(x: Any): Int = when (x) {
        \\    !is String -> 0
        \\    else -> x.length
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("x.^length", "kotlin/String.length");
}

test "a vararg parameter's default is typed as its array" {
    var fx = try fixture(&.{
        \\package app
        \\annotation class Ann(vararg val arg: String = [])
        \\fun f(vararg xs: String = ["a"]) = xs
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectRef("arg: String = ^[", .call, "kotlin/arrayOf");
    try fx.expectRef("xs: String = ^[", .call, "kotlin/arrayOf");
}

test "an unresolved member names the type it was looked up on" {
    var fx = try fixture(&.{
        \\package app
        \\class Box<T>
        \\fun use(b: Box<String>, f: (Int) -> String?) {
        \\    b.size
        \\    b.grow(1)
        \\    f.size
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try expectMessages(&fx, &.{
        "unresolved reference `size` on `Box<String>`",
        "unresolved reference `grow` on `Box<String>`",
        "unresolved reference `size` on `(Int) -> String?`",
    });
}

test "a call no candidate accepts lists them, and an ambiguous one names both" {
    var fx = try fixture(&.{
        \\package app
        \\fun f(a: String): Int = 1
        \\fun f(a: Int, b: Int): Int = 2
        \\fun g(a: Int, b: Long = 0L): Int = 1
        \\fun g(a: Int, c: Int = 0): Int = 2
        \\fun <T> make(): List<T> = TODO()
        \\fun use() {
        \\    f(true)
        \\    g(1)
        \\    make()
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try expectMessages(&fx, &.{
        "none of the candidates for `f` accept (Boolean):\n    fun f(a: String): Int\n    fun f(a: Int, b: Int): Int",
        "`g` is ambiguous: `fun g(a: Int, b: Long): Int`, `fun g(a: Int, c: Int): Int`",
        "cannot infer the type argument `T` of `make`; write it explicitly",
    });
}

test "a member with a supertype member's signature needs `override`" {
    var fx = try fixture(&.{
        \\package app
        \\open class Base {
        \\    open val x: Int = 1
        \\    open fun f(a: Int) {}
        \\    fun g() {}
        \\    private fun p() {}
        \\    open fun <T> gen(t: T) {}
        \\    open fun h(a: List<String>) {}
        \\}
        \\interface I {
        \\    fun i(): Int
        \\    val q: String get() = ""
        \\}
        \\class D(val x: Int) : Base(), I {
        \\    fun f(a: Int) {}
        \\    fun f(a: String) {}
        \\    fun g() {}
        \\    fun p() {}
        \\    fun <T> gen(t: T) {}
        \\    fun h(a: List<Int>) {}
        \\    fun i(): Int = 0
        \\    private val q: String = "q"
        \\    fun toString(): String = ""
        \\    companion object {
        \\        fun f(a: Int) {}
        \\    }
        \\}
        \\class E : Base() {
        \\    override val x: Int = 2
        \\    override fun f(a: Int) {}
        \\    fun p() {}
        \\    override fun toString(): String = ""
        \\}
        \\interface P {
        \\    @kotlin.internal.PlatformDependent
        \\    fun f(): String = "FAIL"
        \\}
        \\class F : P {
        \\    fun f() = "OK"
        \\}
    ,
        \\package kotlin.internal
        \\internal annotation class PlatformDependent
    });
    defer fx.deinit();
    try fx.resolve();
    try expectMessages(&fx, &.{
        "`x` hides member of supertype `Base` and needs an `override` modifier",
        "`f` hides member of supertype `Base` and needs an `override` modifier",
        "`g` hides member of supertype `Base` and needs an `override` modifier",
        "`gen` hides member of supertype `Base` and needs an `override` modifier",
        "`i` hides member of supertype `I` and needs an `override` modifier",
        "`q` hides member of supertype `I` and needs an `override` modifier",
        "`toString` hides member of supertype `Any` and needs an `override` modifier",
    });
}

test "a smart cast on an inherited property sees it as its receiver does" {
    var fx = try fixture(&.{
        \\package demo
        \\open class Subject<out T>(val actual: T?)
        \\class StringSubject(a: String?) : Subject<String>(a)
        \\fun StringSubject.len(): Int = if (actual == null) -1 else actual.length
        \\fun StringSubject.lenThis(): Int = if (this.actual == null) -1 else actual.length
        \\class Inside(a: String?) : Subject<String>(a) {
        \\    fun len(): Int = if (actual != null) actual.length else -1
        \\}
    ,
        \\package demo
        \\class String { val length: Int get() = 0 }
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("else actual.^length", "demo/String.length");
}

test "a smart cast on an inherited property keeps its type parameter's bound" {
    var fx = try fixture(&.{
        \\package demo
        \\open class Subject<out T>(val actual: T?)
        \\class ComparableSubject<T : Comparable<T>>(a: T?) : Subject<T>(a)
        \\fun <T : Comparable<T>> ComparableSubject<T>.greaterThan(other: T?): Boolean {
        \\    requireNotNull(actual)
        \\    requireNotNull(other)
        \\    return actual > other
        \\}
        \\fun <T : Comparable<T>> ComparableSubject<T>.compareWith(other: T): Int {
        \\    if (actual == null) return -2
        \\    return actual.compareTo(other)
        \\}
    ,
        \\package demo
        \\interface Comparable<in T> { operator fun compareTo(other: T): Int }
        \\fun <T : Any> requireNotNull(value: T?): T {
        \\    contract { returns() implies (value != null) }
        \\    return value!!
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try fx.expectClean();
    try fx.expectTarget("actual.^compareTo(other)", "demo/Comparable.compareTo");
}

test "a type alias of an inner class is found in scope, not among the receiver's members" {
    var fx = try fixture(&.{
        \\package app
        \\class Outer<T>(val id: String) {
        \\    inner class Inner(val p: T)
        \\    typealias TAtoInner = Outer<String>.Inner
        \\    fun inside(): String {
        \\        val unbound = Outer<String>::TAtoInner
        \\        val bound = Outer<String>("b")::TAtoInner
        \\        return unbound(Outer("u"), "x").p + bound("y").p + Outer<String>("c").TAtoInner("z").p
        \\    }
        \\}
        \\fun outside(o: Outer<String>) {
        \\    o.TAtoInner("x")
        \\    val bound = o::TAtoInner
        \\    val unbound = Outer<String>::TAtoInner
        \\}
    });
    defer fx.deinit();
    try fx.resolve();
    try expectMessages(&fx, &.{
        "unresolved reference `TAtoInner` on `Outer<String>`",
        "unresolved reference `TAtoInner`",
        "unresolved reference `TAtoInner`",
    });
}
