//! Programs over a baked base: the miniature base is bridged and lowered
//! alone, then a program extends that bridge (`bridge.buildOver`) as a run
//! over a loaded base image does. Each program prints the same over the
//! baked base as over the whole one; every expected output is what kotlinc
//! 2.4.20 prints.

const std = @import("std");
const sema = @import("sema");
const ir = @import("ir");

const driver = @import("../lower_driver.zig");

const bridge = ir.bridge;
const Sym = sema.Sym;
const testing = std.testing;

fn skipUnbuilt(err: anyerror) anyerror {
    return if (err == error.Unsupported) error.SkipZigTest else err;
}

test "the program's ids follow every id of the baked base, which keeps its entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const baked = try driver.bake(a);
    const n_funcs = baked.br.origin.len;
    const n_classes = baked.br.class_origin.len;
    const origins = try a.dupe(bridge.FuncOrigin, baked.br.origin);
    const slots = try a.dupe(ir.MethodSlotId, baked.br.slot_of);
    const class_of = try a.dupe(ir.ClassId, baked.br.class_of[0..baked.layer.syms]);
    const layouts = try a.dupe([]const bridge.Slot, baked.br.layout);
    const r0 = baked.br.m.resolved.?.*;
    const an = try driver.analyzeOver(a, &baked, &.{
        \\open class Shape(val name: String) : Comparable<Shape> {
        \\    open fun area(): Int = 0
        \\    override fun compareTo(other: Shape): Int = area() - other.area()
        \\}
        \\class Square(val side: Int) : Shape("square") {
        \\    override fun area(): Int = side * side
        \\}
        \\fun main() { println(Square(2).area()) }
    });
    const br = an.br;
    try testing.expect(br == baked.br);
    // The base's entries are unchanged.
    try testing.expectEqualSlices(ir.MethodSlotId, slots, br.slot_of[0..n_funcs]);
    try testing.expectEqualSlices(ir.ClassId, class_of, br.class_of[0..baked.layer.syms]);
    for (origins, br.origin[0..n_funcs]) |x, y| try testing.expect(std.meta.eql(x, y));
    for (layouts, br.layout[0..n_classes]) |x, y| try testing.expectEqual(x.ptr, y.ptr);
    const r = br.m.resolved.?;
    try testing.expectEqual(r0.natives.len <= r.natives.len, true);
    for (r0.natives, r.natives[0..r0.natives.len]) |x, y| try testing.expectEqualStrings(x.name, y.name);
    try testing.expectEqual(n_funcs, br.m.funcs.items.len - (br.origin.len - n_funcs));
    try testing.expectEqual(br.origin.len, br.m.funcs.items.len);
    try testing.expectEqual(br.class_origin.len, br.m.classes.items.len);
    try testing.expectEqual(br.class_origin.len, r.classes.len);
    try testing.expectEqual(br.origin.len, r.func_native.len);
    // The program's classes and functions come after the base's.
    const square = an.s.classByFqn("Square");
    try testing.expect(square != .none);
    try testing.expect(br.classOf(square).int() >= n_classes);
    const area = blk: {
        const n = an.s.names.lookup("area").?;
        break :blk sema.symbols.Symbols.members(&an.s.syms.classInfo(square).members, n)[0];
    };
    try testing.expect(br.funcOf(area).int() >= n_funcs);
    // A program class's ancestors reach the base's `Comparable` and `Any`.
    const cmp = br.classOf(an.s.classByFqn("kotlin.Comparable"));
    const any = br.classOf(an.s.classByFqn("kotlin.Any"));
    try testing.expect(br.m.classIsA(br.classOf(square), cmp));
    try testing.expect(br.m.classIsA(br.classOf(square), any));
    try testing.expectEqual(br.layer_ends[0].funcs, @as(u32, @intCast(n_funcs)));
}

test "program classes extend and implement the baked base's classes" {
    driver.expectOutputOver(&.{
        \\open class Shape(val name: String) : Comparable<Shape> {
        \\    open fun area(): Int = 0
        \\    override fun compareTo(other: Shape): Int = area() - other.area()
        \\    override fun toString(): String = name + "(" + area() + ")"
        \\}
        \\class Square(val side: Int) : Shape("square") {
        \\    override fun area(): Int = side * side
        \\}
        \\class Rect(val w: Int, val h: Int) : Shape("rect") {
        \\    override fun area(): Int = w * h
        \\}
        \\class Oops(val code: Int) : IllegalStateException("code " + code) {
        \\    override val message: String? get() = "oops " + code
        \\}
        \\fun main() {
        \\    val shapes = listOf(Square(3), Rect(2, 5), Square(1))
        \\    println(shapes)
        \\    println(Square(3) > Rect(2, 4))
        \\    try { throw Oops(7) } catch (e: IllegalStateException) { println(e) }
        \\    println(Oops(2).message)
        \\}
    }, "[square(9), rect(10), square(1)]\ntrue\nOops: oops 7\noops 2\n") catch |e| return skipUnbuilt(e);
}

test "lambdas, the baked base's inline functions and a non-local return" {
    driver.expectOutputOver(&.{
        \\fun firstEven(xs: List<Int>): Int {
        \\    xs.forEach { if (it % 2 == 0) return it }
        \\    return -1
        \\}
        \\fun main() {
        \\    val xs = listOf(1, 2, 3, 4, 5)
        \\    var total = 0
        \\    xs.forEach { total += it }
        \\    println(total)
        \\    println(xs.map { it * it }.filter { it > 4 })
        \\    println(firstEven(listOf(3, 5, 8, 9)))
        \\    val sb = 10.let { it + 1 }.also { total += it }
        \\    println(sb)
        \\    println(total)
        \\    repeat(2) { println("r" + it) }
        \\    val add = { x: Int, y: Int -> x + y + total }
        \\    println(add(1, 2))
        \\}
    }, "15\n[9, 16, 25]\n8\n11\n26\nr0\nr1\n29\n") catch |e| return skipUnbuilt(e);
}

test "objects, companions, enums, data classes and delegated properties over a baked base" {
    driver.expectOutputOver(&.{
        \\object Counter {
        \\    var n = 0
        \\    fun next(): Int { n += 1; return n }
        \\}
        \\class Box(val v: Int) {
        \\    companion object { val made = Box(0) }
        \\}
        \\enum class Color(val rgb: Int) { RED(1), GREEN(2), BLUE(4) }
        \\data class Point(val x: Int, val y: Int)
        \\val greeting: String by lazy { println("computing"); "hello" }
        \\val table = listOf(1 to "one", 2 to "two")
        \\fun main() {
        \\    Counter.next(); Counter.next()
        \\    println(Counter.n)
        \\    println(Box.made.v)
        \\    println(Color.GREEN.rgb + Color.BLUE.ordinal)
        \\    println(Color.valueOf("RED"))
        \\    val p = Point(1, 2)
        \\    println(p)
        \\    println(p.copy(y = 5) == Point(1, 5))
        \\    val (x, y) = p
        \\    println(x + y)
        \\    println(greeting)
        \\    println(greeting)
        \\    println(table[1].second)
        \\}
    }, "2\n0\n4\nRED\nPoint(x=1, y=2)\ntrue\n3\ncomputing\nhello\nhello\ntwo\n") catch |e| return skipUnbuilt(e);
}

test "references, fun interfaces, local and inner classes over a baked base" {
    driver.expectOutputOver(&.{
        \\fun interface Op { fun apply(x: Int): Int }
        \\fun twice(x: Int): Int = x * 2
        \\class Outer(val base: Int) {
        \\    inner class Inner(val k: Int) { fun sum(): Int = base + k }
        \\}
        \\fun main() {
        \\    val f = ::twice
        \\    println(f(21))
        \\    println(listOf(1, 2, 3).map(::twice))
        \\    val op = Op { it + 100 }
        \\    println(op.apply(1))
        \\    val offset = 5
        \\    class Local(val v: Int) { fun shifted(): Int = v + offset }
        \\    println(Local(1).shifted())
        \\    println(Outer(10).Inner(3).sum())
        \\    val pair = Pair("a", 1)
        \\    println(pair.first + pair.second)
        \\}
    }, "42\n[2, 4, 6]\n101\n6\n13\na1\n") catch |e| return skipUnbuilt(e);
}

test "constants read through an object qualifier initialize nothing, the baked base's included" {
    driver.expectOutputOver(&.{
        \\const val LIMIT = Int.MAX_VALUE - 7
        \\object Config {
        \\    init { println("Config initialized") }
        \\    const val NAME = "cfg"
        \\}
        \\class Holder {
        \\    companion object {
        \\        init { println("Companion initialized") }
        \\        const val K = 3
        \\    }
        \\}
        \\fun cfg(): Config { println("cfg()"); return Config }
        \\fun main() {
        \\    println(Int.MAX_VALUE)
        \\    println(Long.MIN_VALUE + 1L)
        \\    println(LIMIT)
        \\    println(Config.NAME + Int.MIN_VALUE)
        \\    println(Holder.K)
        \\    println(Holder.Companion.K)
        \\    println(cfg().NAME)
        \\}
    }, "2147483647\n-9223372036854775807\n2147483640\ncfg-2147483648\n3\n3\ncfg()\nConfig initialized\ncfg\n") catch |e| return skipUnbuilt(e);
}
