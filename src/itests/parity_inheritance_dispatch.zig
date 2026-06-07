//! Inheritance + dispatch parity: super calls, diamond, generic
//! inheritance, abstract/final/open interplay, companion through subclass.
//! Ported from the Rust suite.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_parity_inheritance_dispatch";

// One arena shared by every test in this file. The pipeline installs
// process-global tables (inline-fn ASTs, the enclosing-`this` stack, ...)
// backed by the build allocator; a fresh per-test arena would free that
// memory out from under the still-live globals and the next run would touch
// freed pages. A single file-scoped arena keeps them valid across all tests,
// and stays off the leak-checking test allocator (which would abort on the
// pipeline's intentional arena lifetime). Mirrors the e2e harness.
var shared_arena: ?std.heap.ArenaAllocator = null;

fn arenaAllocator() std.mem.Allocator {
    if (shared_arena == null) {
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

test "super_call_in_override" {
    const src =
        \\
        \\open class A { open fun n(): String = "A" }
        \\open class B : A() { override fun n(): String = "B-" + super.n() }
        \\class C : B() { override fun n(): String = "C-" + super.n() }
        \\fun main() { println(C().n()) }
        \\
    ;
    try assertKlio("super_call", src, "C-B-A\n");
}

test "interface_with_default_overridden" {
    const src =
        \\
        \\interface I { fun g(): String = "I" }
        \\open class B : I { override fun g(): String = "B-" + super.g() }
        \\class C : B() { override fun g(): String = "C-" + super.g() }
        \\fun main() { println(C().g()) }
        \\
    ;
    try assertKlio("iface_default", src, "C-B-I\n");
}

test "generic_open_class_subclass_specialized" {
    const src =
        \\
        \\open class Container<T>(val v: T) { open fun render(): String = "$v" }
        \\class IntC(v: Int) : Container<Int>(v) { override fun render(): String = "Int($v)" }
        \\class StrC(v: String) : Container<String>(v) { override fun render(): String = "Str($v)" }
        \\fun describe(c: Container<*>): String = c.render()
        \\fun main() {
        \\    println("${describe(IntC(3))}|${describe(StrC("hi"))}")
        \\}
        \\
    ;
    try assertKlio("generic_open", src, "Int(3)|Str(hi)\n");
}

test "abstract_method_chain" {
    const src =
        \\
        \\abstract class Drawable {
        \\    abstract fun area(): Int
        \\    fun describe(): String = "area=${area()}"
        \\}
        \\class Sq(val s: Int) : Drawable() { override fun area(): Int = s * s }
        \\class Rect(val w: Int, val h: Int) : Drawable() { override fun area(): Int = w * h }
        \\fun main() {
        \\    val xs: List<Drawable> = listOf(Sq(3), Rect(2,5))
        \\    println(xs.joinToString(";") { it.describe() })
        \\}
        \\
    ;
    try assertKlio("abstract_chain", src, "area=9;area=10\n");
}

test "open_property_overridden_with_init" {
    const src =
        \\
        \\open class P { open val tag: String = "base" }
        \\class Q : P() { override val tag: String = "sub" }
        \\fun main() { val p: P = Q(); println(p.tag) }
        \\
    ;
    try assertKlio("open_property", src, "sub\n");
}

test "companion_inherited_via_class_ref" {
    const src =
        \\
        \\open class Base { companion object { fun bye(): String = "BB" } }
        \\class Sub : Base()
        \\fun main() {
        \\    println(Sub.bye())  // Kotlin allows accessing inherited companion thru class ref
        \\}
        \\
    ;
    try assertKlio("companion_inherit", src, "BB\n");
}

test "polymorphic_collection_dispatch" {
    const src =
        \\
        \\open class Animal { open fun voice(): String = "?" }
        \\class Dog : Animal() { override fun voice(): String = "woof" }
        \\class Cat : Animal() { override fun voice(): String = "meow" }
        \\class Snake : Animal() { override fun voice(): String = "hiss" }
        \\fun main() {
        \\    val pets: List<Animal> = listOf(Dog(), Cat(), Snake(), Dog())
        \\    println(pets.joinToString(",") { it.voice() })
        \\}
        \\
    ;
    try assertKlio("polymorphic", src, "woof,meow,hiss,woof\n");
}

test "deep_inheritance_with_init_order" {
    const src =
        \\
        \\open class A {
        \\    init { println("A.init") }
        \\    val x = "A.x".also { println("A.x") }
        \\}
        \\open class B : A() {
        \\    init { println("B.init") }
        \\    val y = "B.y".also { println("B.y") }
        \\}
        \\class C : B() {
        \\    init { println("C.init") }
        \\    val z = "C.z".also { println("C.z") }
        \\}
        \\fun main() { val c = C(); println("done:${c.x}${c.y}${c.z}") }
        \\
    ;
    try assertKlio(
        "deep_init_order",
        src,
        "A.init\nA.x\nB.init\nB.y\nC.init\nC.z\ndone:A.xB.yC.z\n",
    );
}

test "override_with_more_specific_generic" {
    const src =
        \\
        \\open class Producer<T> { open fun make(): T? = null }
        \\class IntP : Producer<Int>() { override fun make(): Int = 42 }
        \\fun main() {
        \\    val p: Producer<Int> = IntP()
        \\    println(p.make())
        \\}
        \\
    ;
    try assertKlio("override_specific", src, "42\n");
}

test "private_member_not_overridden" {
    const src =
        \\
        \\open class P {
        \\    private fun hidden(): String = "P-hidden"
        \\    open fun show(): String = hidden()
        \\}
        \\class S : P() {
        \\    fun hidden(): String = "S-hidden"  // not actually an override (P.hidden is private)
        \\    override fun show(): String = "S:" + super.show()
        \\}
        \\fun main() { println(S().show()) }
        \\
    ;
    try assertKlio("private_not_overridden", src, "S:P-hidden\n");
}
