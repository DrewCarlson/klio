//! Inner / nested class scoping: outer-this resolution, qualified
//! this@Outer, inner-class members capturing outer fields.

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

test "inner class reads outer private computed property" {
    const src =
        \\
        \\open class Outer(private val cause: String?) {
        \\    private val receiveException: String get() = cause ?: "closed"
        \\    inner class Iterator {
        \\        fun next(): String = receiveException
        \\    }
        \\}
        \\class Derived : Outer(null)
        \\fun main() {
        \\    println(Derived().Iterator().next())
        \\}
        \\
    ;
    try assertKlio("inner_outer_private_getter", src, "closed\n");
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

// A bare `Inner()` inside a receiver lambda must capture this@Outer as its
// outer, not the lambda's receiver: inside Inner's body, `tag` resolves
// lexically to the enclosing class instance, and the `with` subject is not
// in scope there. The outer is selected by the inner class's enclosing
// class, so the innermost unrelated receiver (`Other`) is never captured.
test "inner_class_constructed_inside_with_lambda" {
    const src =
        \\
        \\class Other(val hintv: String) {
        \\    fun hint(): String = "other-" + hintv
        \\}
        \\class Outer(val tag: String) {
        \\    inner class Inner {
        \\        fun show(): String = "outer-" + tag
        \\    }
        \\    fun viaWith(x: Other): String = with(x) { Inner().show() + ":" + hint() }
        \\}
        \\fun main() {
        \\    println(Outer("T").viaWith(Other("o")))
        \\}
        \\
    ;
    try assertKlio("inner_with_lambda", src, "outer-T:other-o\n");
}

// The same selection inside an HOF lambda: the lambda frame has no `this`
// param, so the outer comes from the enclosing implicit-receiver chain.
test "inner_class_constructed_inside_map_lambda" {
    const src =
        \\
        \\class Outer(val tag: String) {
        \\    inner class Inner {
        \\        fun show(): String = "outer-" + tag
        \\    }
        \\    fun viaMap(): String = listOf(1).map { Inner().show() }.first()
        \\}
        \\fun main() {
        \\    println(Outer("M").viaMap())
        \\}
        \\
    ;
    try assertKlio("inner_map_lambda", src, "outer-M\n");
}

// The with-subject declaring a property with the same name as the outer's
// must NOT shadow it inside Inner's body: `tag` in `show()` resolves
// lexically to this@Outer, never to the with-subject, in every
// construction context (with-lambda, map-of-with, with-of-map).
test "inner_class_in_with_lambda_ignores_shadowing_subject" {
    const src =
        \\
        \\class Other(val tag: String)
        \\class Outer(val tag: String) {
        \\    inner class Inner {
        \\        fun show(): String = "outer-" + tag
        \\    }
        \\    fun viaWith(x: Other): String = with(x) { Inner().show() }
        \\    fun viaMapWith(x: Other): String = listOf(1).map { with(x) { Inner().show() } }.first()
        \\    fun viaWithMap(x: Other): String = with(x) { listOf(1).map { Inner().show() }.first() }
        \\}
        \\fun main() {
        \\    val o = Outer("T")
        \\    println(o.viaWith(Other("WRONG")))
        \\    println(o.viaMapWith(Other("WRONG")))
        \\    println(o.viaWithMap(Other("WRONG")))
        \\}
        \\
    ;
    try assertKlio("inner_with_shadow", src, "outer-T\nouter-T\nouter-T\n");
}

// A lambda whose body touches nothing of the enclosing instance except
// the bare `Inner()` construction itself still depends on this@Outer:
// the construction forces the `this` capture (as kotlinc's `this$0`
// does), so the outer binds even through a user-defined HOF whose own
// frame carries no receiver.
test "inner_class_constructed_inside_user_hof_lambda" {
    const src =
        \\
        \\fun apply1(f: () -> String): String = f()
        \\class Outer(val tag: String) {
        \\    inner class Inner {
        \\        fun show(): String = "outer-" + tag
        \\    }
        \\    fun viaUserHof(): String = apply1 { Inner().show() }
        \\}
        \\fun main() {
        \\    println(Outer("U").viaUserHof())
        \\}
        \\
    ;
    try assertKlio("inner_user_hof", src, "outer-U\n");
}

// Two levels of `inner`: C inside B inside A. A bare `C()` in a member of
// B — directly or inside a `with` over an unrelated A instance — captures
// the B instance, and C's body reaches both `b` (via outer) and `a` (via
// outer.outer).
test "inner_class_two_level_nesting" {
    const src =
        \\
        \\class A(val a: String) {
        \\    inner class B(val b: String) {
        \\        inner class C {
        \\            fun show(): String = a + "/" + b
        \\        }
        \\        fun mkC(): C = C()
        \\        fun mkCInWith(x: A): String = with(x) { C().show() }
        \\    }
        \\    fun mkB(s: String): B = B(s)
        \\}
        \\fun main() {
        \\    val b = A("a1").mkB("b1")
        \\    println(b.mkC().show())
        \\    println(b.mkCInWith(A("a2")))
        \\}
        \\
    ;
    try assertKlio("inner_two_level", src, "a1/b1\na1/b1\n");
}

// An Inner constructed inside a lambda and *escaping* the enclosing
// member must still carry its outer link: resolution outside the member
// has no enclosing-receiver chain to rescue an unstamped instance.
test "inner_class_escapes_lambda_with_outer" {
    const src =
        \\
        \\class Outer(val tag: String) {
        \\    inner class Inner {
        \\        fun show(): String = "outer-" + tag
        \\    }
        \\    fun makeViaLambda(): Inner = listOf(1).map { Inner() }.first()
        \\}
        \\fun main() {
        \\    val i = Outer("E").makeViaLambda()
        \\    println(i.show())
        \\}
        \\
    ;
    try assertKlio("inner_escape_lambda", src, "outer-E\n");
}

// A member of Inner constructing a sibling `Inner()` means
// `this@Outer.Inner()`: the outer comes through the dispatch receiver's own
// outer link, never through an unrelated receiver inherited from a caller
// frame. The `with(w)` subject in main is not a receiver in scope inside
// `sibling()`'s body, so it must not be captured even though it is the
// innermost entry on the dynamically-inherited chain. kotlinc-native
// 2.3.10 prints outer=A for all four lines.
test "sibling_inner_construction_ignores_caller_receivers" {
    const src =
        \\
        \\class Outer(val tag: String) {
        \\    inner class Inner {
        \\        fun sibling(): Inner = Inner()
        \\        fun siblingViaLambda(): Inner = listOf(1).map { Inner() }.first()
        \\        fun show(): String = "outer=" + tag
        \\    }
        \\    fun mk(): Inner = Inner()
        \\}
        \\fun main() {
        \\    val inner = Outer("A").mk()
        \\    val w = Outer("W")
        \\    println(inner.sibling().show())
        \\    println(with(w) { inner.sibling() }.show())
        \\    println(inner.siblingViaLambda().show())
        \\    println(with(w) { inner.siblingViaLambda() }.show())
        \\}
        \\
    ;
    try assertKlio("inner_sibling_polluted_chain", src, "outer=A\nouter=A\nouter=A\nouter=A\n");
}

// Member declaration order is semantically irrelevant: a lambda inside one
// inner class constructing a sibling inner class declared LATER in the
// body must capture the enclosing `this` exactly as the earlier-declared
// order does. Pins the construction-site capture rule against the
// reserve-stub `is_inner` (a forward-referenced class is only a stub when
// the lambda lowers).
test "later_declared_sibling_inner_class_from_lambda" {
    const src =
        \\
        \\class OuterAB(val tag: String) {
        \\    inner class A1 { fun mkB(): B1 = listOf(1).map { B1() }.first() }
        \\    inner class B1 { fun show(): String = "outer=" + tag }
        \\    fun mkA(): A1 = A1()
        \\}
        \\class OuterBA(val tag: String) {
        \\    inner class B2 { fun show(): String = "outer=" + tag }
        \\    inner class A2 { fun mkB(): B2 = listOf(1).map { B2() }.first() }
        \\    fun mkA(): A2 = A2()
        \\}
        \\fun main() {
        \\    println(OuterAB("T").mkA().mkB().show())
        \\    println(OuterBA("T").mkA().mkB().show())
        \\    println(with(OuterAB("W")) { OuterAB("U").mkA().mkB() }.show())
        \\}
        \\
    ;
    try assertKlio("inner_sibling_decl_order", src, "outer=T\nouter=T\nouter=U\n");
}

// A `with` subject of the enclosing class IS the innermost receiver in
// scope, so it supplies the outer — `with(w) { Inner() }` constructs
// `w.Inner()` whether written in a member of Outer or of Inner.
// kotlinc-native 2.3.10 prints outer=W for both.
test "with_subject_of_enclosing_class_supplies_outer" {
    const src =
        \\
        \\class Outer(val tag: String) {
        \\    inner class Inner {
        \\        fun show(): String = "outer=" + tag
        \\        fun viaWith(w: Outer): Inner = with(w) { Inner() }
        \\    }
        \\    fun mk(): Inner = Inner()
        \\    fun viaWith(w: Outer): Inner = with(w) { Inner() }
        \\}
        \\fun main() {
        \\    val a = Outer("A")
        \\    val w = Outer("W")
        \\    println(a.mk().viaWith(w).show())
        \\    println(a.viaWith(w).show())
        \\}
        \\
    ;
    try assertKlio("inner_with_outer_subject", src, "outer=W\nouter=W\n");
}

// A `with` subject brings only itself into scope, never its own enclosing
// instances: a subject that is an Inner of a DIFFERENT Outer must not leak
// that Outer as the new sibling's outer — the construction resolves
// through the member's own `this@Outer`. kotlinc-native 2.3.10: outer=A.
test "with_subject_outer_links_not_in_scope" {
    const src =
        \\
        \\class Outer(val tag: String) {
        \\    inner class Inner { fun show(): String = "outer=" + tag }
        \\    fun mk(): Inner = Inner()
        \\    fun viaWithInner(i: Inner): Inner = with(i) { Inner() }
        \\}
        \\fun main() {
        \\    val a = Outer("A")
        \\    val xi = Outer("X").mk()
        \\    println(a.viaWithInner(xi).show())
        \\}
        \\
    ;
    try assertKlio("inner_with_inner_subject", src, "outer=A\n");
}

// Inside a member of Inner, `with(x) { Inner() }` over an unrelated
// subject reaches this@Outer through the dispatch receiver's outer link —
// the receivers in scope are the subject, this@Inner, and this@Outer.
// kotlinc-native 2.3.10: outer=A.
test "with_unrelated_subject_in_inner_member_reaches_outer" {
    const src =
        \\
        \\class Other(val o: String)
        \\class Outer(val tag: String) {
        \\    inner class Inner {
        \\        fun show(): String = "outer=" + tag
        \\        fun viaWith(x: Other): Inner = with(x) { Inner() }
        \\    }
        \\    fun mk(): Inner = Inner()
        \\}
        \\fun main() {
        \\    println(Outer("A").mk().viaWith(Other("x")).show())
        \\}
        \\
    ;
    try assertKlio("inner_with_other_in_inner", src, "outer=A\n");
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

test "inner_class_super_constructor_reads_outer_field" {
    const src =
        \\
        \\open class Base(val value: Int)
        \\class Outer(val seed: Int) {
        \\    inner class Derived : Base(seed)
        \\    fun make(): Derived = Derived()
        \\}
        \\fun main() {
        \\    println(Outer(42).make().value)
        \\}
        \\
    ;
    try assertKlio("inner_super_outer", src, "42\n");
}
