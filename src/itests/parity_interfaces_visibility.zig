//! Interface contracts, default methods, fun interfaces, and access through
//! upcast/downcast.
//! Ported from the Rust suite.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_parity_interfaces_visibility";

// One arena shared by every test in this file. The pipeline installs
// process-global tables (inline-fn ASTs, the enclosing-`this` stack, ...)
// backed by the build allocator; a fresh per-test arena would free that
// memory out from under the still-live globals and the next run would touch
// freed pages. A single file-scoped arena keeps them valid across all tests,
// and stays off the leak-checking test allocator (which would abort on the
// pipeline's intentional arena lifetime). Mirrors the e2e harness.
var shared_arena: ?std.heap.ArenaAllocator = null;

fn arenaAllocator() std.mem.Allocator {
    if (shared_arena) |*a| {
        // Reset the per-program arena so each program's allocations are
        // reclaimed instead of accumulating across this file's tests. Safe:
        // the cross-program globals are page_allocator-backed, not this arena.
        _ = a.reset(.retain_capacity);
    } else {
        shared_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
    return shared_arena.?.allocator();
}

fn assertKlio(name: []const u8, src: []const u8, expected: []const u8) !void {
    const a = arenaAllocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.Io.Dir.cwd().createDirPath(io, TMP_DIR) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });

    const res = try parity.runWithPacks(a, io, path);
    switch (res) {
        .ok => |got| try std.testing.expectEqualStrings(expected, got),
        .err => |m| {
            std.debug.print("klio run failed for `{s}`: {s}\n", .{ name, m });
            return error.KlioRunFailed;
        },
    }
}

test "diamond_inheritance_explicit_super" {
    const src =
        \\
        \\interface A { fun ping(): String = "A" }
        \\interface B { fun ping(): String = "B" }
        \\class C : A, B {
        \\    override fun ping(): String = super<A>.ping() + super<B>.ping()
        \\}
        \\fun main() { println(C().ping()) }
        \\
    ;
    try assertKlio("diamond", src, "AB\n");
}

test "fun_interface_lambda_conversion" {
    const src =
        \\
        \\fun interface IntPred { fun test(x: Int): Boolean }
        \\fun count(xs: List<Int>, p: IntPred): Int = xs.count { p.test(it) }
        \\fun main() {
        \\    val evens = count(listOf(1,2,3,4,5,6)) { it % 2 == 0 }
        \\    println(evens)
        \\}
        \\
    ;
    try assertKlio("fun_iface", src, "3\n");
}

test "interface_property_via_getter" {
    const src =
        \\
        \\interface Named { val name: String; val length: Int get() = name.length }
        \\class P(override val name: String) : Named
        \\fun main() {
        \\    val p = P("kotlin")
        \\    println("${p.name},${p.length}")
        \\}
        \\
    ;
    try assertKlio("iface_prop", src, "kotlin,6\n");
}

test "abstract_with_protected_concrete" {
    const src =
        \\
        \\abstract class Shape {
        \\    abstract fun area(): Double
        \\    fun describe(): String = "area=${area()}"
        \\}
        \\class Circle(val r: Double) : Shape() { override fun area(): Double = r * r * 3.14 }
        \\class Sq(val s: Double) : Shape() { override fun area(): Double = s * s }
        \\fun main() {
        \\    val xs: List<Shape> = listOf(Circle(2.0), Sq(3.0))
        \\    println(xs.joinToString(";") { it.describe() })
        \\}
        \\
    ;
    try assertKlio("abstract_concrete", src, "area=12.56;area=9.0\n");
}

test "upcast_then_downcast_safe" {
    const src =
        \\
        \\open class Animal(val name: String)
        \\class Dog(name: String, val breed: String) : Animal(name)
        \\fun main() {
        \\    val a: Animal = Dog("Rex", "Pug")
        \\    val d = a as? Dog
        \\    val cat = a as? Cat
        \\    println("${d?.breed},${cat?.name}")
        \\}
        \\class Cat(name: String) : Animal(name)
        \\
    ;
    try assertKlio("upcast_safe", src, "Pug,null\n");
}

test "sealed_class_exhaustive_when" {
    const src =
        \\
        \\sealed class Event {
        \\    class Click(val x: Int, val y: Int) : Event()
        \\    class Key(val k: Char) : Event()
        \\    object Tick : Event()
        \\}
        \\fun render(e: Event): String = when (e) {
        \\    is Event.Click -> "click(${e.x},${e.y})"
        \\    is Event.Key -> "key=${e.k}"
        \\    Event.Tick -> "tick"
        \\}
        \\fun main() {
        \\    val xs = listOf(Event.Click(1,2), Event.Key('a'), Event.Tick)
        \\    println(xs.joinToString("|") { render(it) })
        \\}
        \\
    ;
    try assertKlio("sealed_exh", src, "click(1,2)|key=a|tick\n");
}

test "interface_implementation_through_property_delegation" {
    const src =
        \\
        \\interface Pinger { fun ping(): String }
        \\class DelegPinger(p: Pinger) : Pinger by p
        \\class HelloP : Pinger { override fun ping(): String = "Hello" }
        \\fun main() {
        \\    val p = DelegPinger(HelloP())
        \\    println(p.ping())
        \\}
        \\
    ;
    try assertKlio("iface_deleg", src, "Hello\n");
}

test "data_class_component_n" {
    const src =
        \\
        \\data class Point(val x: Int, val y: Int, val z: Int)
        \\fun main() {
        \\    val p = Point(1,2,3)
        \\    val (a, b, c) = p
        \\    println("$a,$b,$c")
        \\}
        \\
    ;
    try assertKlio("dest_data", src, "1,2,3\n");
}
