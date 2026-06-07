//! Inner / nested class scoping: outer-this resolution, qualified
//! this@Outer, inner-class members capturing outer fields.
//! Ported from the Rust suite.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_parity_inner_classes";

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

test "nested_class_independent_of_outer" {
    const src =
        \\
        \\class Outer {
        \\    class Nested {
        \\        fun tag(): String = "N"
        \\    }
        \\    fun make(): Nested = Nested()
        \\}
        \\fun main() {
        \\    val n = Outer().make()
        \\    val n2 = Outer.Nested()
        \\    println("${n.tag()},${n2.tag()}")
        \\}
        \\
    ;
    try assertKlio("nested_class", src, "N,N\n");
}

test "inner_class_captures_outer_this" {
    const src =
        \\
        \\class Outer(val tag: String) {
        \\    inner class Inner {
        \\        fun render(): String = "outer=$tag"
        \\    }
        \\    fun mk(): Inner = Inner()
        \\}
        \\fun main() {
        \\    val i = Outer("hello").mk()
        \\    println(i.render())
        \\}
        \\
    ;
    try assertKlio("inner_class", src, "outer=hello\n");
}

test "this_at_label_in_inner_class" {
    const src =
        \\
        \\class Outer(val tag: String) {
        \\    inner class Inner {
        \\        val tag: String = "inner"
        \\        fun render(): String = "${this.tag}|${this@Outer.tag}"
        \\    }
        \\}
        \\fun main() {
        \\    println(Outer("OUT").Inner().render())
        \\}
        \\
    ;
    try assertKlio("this_at_label", src, "inner|OUT\n");
}

test "nested_object_singleton" {
    const src =
        \\
        \\class Container {
        \\    object Holder {
        \\        fun greet(): String = "hi"
        \\    }
        \\}
        \\fun main() {
        \\    println(Container.Holder.greet())
        \\}
        \\
    ;
    try assertKlio("nested_obj", src, "hi\n");
}

test "inner_class_member_calls_outer_method" {
    const src =
        \\
        \\class Outer(val n: Int) {
        \\    fun double(): Int = n * 2
        \\    inner class Inner {
        \\        fun work(): Int = double() + 1  // bare call to enclosing class's method
        \\    }
        \\}
        \\fun main() {
        \\    println(Outer(5).Inner().work())
        \\}
        \\
    ;
    try assertKlio("inner_calls_outer", src, "11\n");
}

test "sealed_class_with_nested_data_subclasses" {
    const src =
        \\
        \\sealed class Tree {
        \\    data class Leaf(val v: Int) : Tree()
        \\    data class Branch(val l: Tree, val r: Tree) : Tree()
        \\}
        \\fun sum(t: Tree): Int = when (t) {
        \\    is Tree.Leaf -> t.v
        \\    is Tree.Branch -> sum(t.l) + sum(t.r)
        \\}
        \\fun main() {
        \\    val t = Tree.Branch(Tree.Leaf(1), Tree.Branch(Tree.Leaf(2), Tree.Leaf(3)))
        \\    println(sum(t))
        \\}
        \\
    ;
    try assertKlio("sealed_tree", src, "6\n");
}

test "inner_class_calls_outer_member_extension" {
    const src =
        \\
        \\class Calc {
        \\    val base = 10
        \\    fun Int.boost(): Int = this * base
        \\    inner class Inner {
        \\        fun work(): String = (1..3).map { it.boost() }.joinToString(",")
        \\    }
        \\}
        \\fun main() {
        \\    println(Calc().Inner().work())
        \\}
        \\
    ;
    try assertKlio("inner_outer_ext", src, "10,20,30\n");
}

test "inner_class_calls_outer_member_extension_on_string" {
    const src =
        \\
        \\class Wrap {
        \\    val sep = "::"
        \\    fun String.adorn(): String = "[$this$sep$this]"
        \\    inner class Builder {
        \\        fun render(xs: List<String>): String =
        \\            xs.joinToString(",") { it.adorn() }
        \\    }
        \\}
        \\fun main() {
        \\    println(Wrap().Builder().render(listOf("a", "b")))
        \\}
        \\
    ;
    try assertKlio("inner_outer_ext_str", src, "[a::a],[b::b]\n");
}

test "anon_object_inherits_concrete_method_from_abstract" {
    const src =
        \\
        \\abstract class Shape {
        \\    abstract fun area(): Int
        \\    fun describe(): String = "area=${area()}"
        \\}
        \\fun rect(w: Int, h: Int): Shape = object : Shape() {
        \\    override fun area(): Int = w * h
        \\}
        \\fun triangle(b: Int, h: Int): Shape = object : Shape() {
        \\    override fun area(): Int = b * h / 2
        \\}
        \\fun main() {
        \\    println(rect(3, 4).describe())
        \\    println(triangle(6, 5).describe())
        \\}
        \\
    ;
    try assertKlio("anon_abstract_concrete", src, "area=12\narea=15\n");
}

test "anon_object_subclass_uses_inherited_helper_in_lambda" {
    const src =
        \\
        \\abstract class Worker {
        \\    abstract fun item(): Int
        \\    fun pipeline(): String =
        \\        (1..3).joinToString(",") { "${it}:${item()}" }
        \\}
        \\fun make(seed: Int): Worker = object : Worker() {
        \\    override fun item(): Int = seed * seed
        \\}
        \\fun main() {
        \\    println(make(2).pipeline())
        \\    println(make(3).pipeline())
        \\}
        \\
    ;
    try assertKlio("anon_abstract_pipeline", src, "1:4,2:4,3:4\n1:9,2:9,3:9\n");
}

test "inner_class_init_block_sees_outer_field" {
    const src =
        \\
        \\class Listener
        \\class Bus {
        \\    val listeners = mutableListOf<Listener>()
        \\    inner class Subscription(val l: Listener) {
        \\        init { listeners.add(l) }
        \\        fun unsubscribe() { listeners.remove(l) }
        \\    }
        \\    fun subscribe(l: Listener): Subscription = Subscription(l)
        \\}
        \\fun main() {
        \\    val b = Bus()
        \\    val s1 = b.subscribe(Listener())
        \\    val s2 = b.subscribe(Listener())
        \\    println(b.listeners.size)
        \\    s1.unsubscribe()
        \\    println(b.listeners.size)
        \\    s2.unsubscribe()
        \\    println(b.listeners.size)
        \\}
        \\
    ;
    try assertKlio("inner_init_outer", src, "2\n1\n0\n");
}
