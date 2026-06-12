//! Extension function resolution: top-level vs member, generic
//! extension, extension on nullable, extension dispatched on
//! interface. Ported from the Rust suite.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_extension_resolution";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


/// Run `src` through the klio pipeline and assert stdout equals `expected`.
/// An arena over the page allocator is used per test so the leak-checking
/// testing allocator never backs the pipeline (it would abort on the
/// intentional arena lifetime).
fn assertKlio(name: []const u8, src: []const u8, expected: []const u8) !void {
    // Reset the per-program arena so each program's ASTs/IR/packs/VM graph
    // is reclaimed instead of accumulating across this file's tests. Safe:
    // the cross-program globals are page_allocator-backed, not this arena.
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();

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

test "extension_on_nullable_type" {
    const src =
        \\
        \\fun String?.orDefault(d: String): String = this ?: d
        \\fun main() {
        \\    val a: String? = "hi"
        \\    val b: String? = null
        \\    println("${a.orDefault("X")}|${b.orDefault("X")}")
        \\}
        \\
    ;
    try assertKlio("ext_nullable", src, "hi|X\n");
}

test "extension_with_generic_bound" {
    const src =
        \\
        \\fun <T : Comparable<T>> List<T>.middle(): T = this[size / 2]
        \\fun main() {
        \\    println("${listOf(1,2,3,4,5).middle()}|${listOf("a","b","c").middle()}")
        \\}
        \\
    ;
    try assertKlio("ext_generic_bound", src, "3|b\n");
}

test "extension_dispatched_on_interface" {
    const src =
        \\
        \\interface Named { val name: String }
        \\fun Named.shout(): String = name.uppercase() + "!"
        \\class P(override val name: String) : Named
        \\fun main() { println(P("kotlin").shout()) }
        \\
    ;
    try assertKlio("ext_iface", src, "KOTLIN!\n");
}

test "extension_chain_calls" {
    const src =
        \\
        \\fun String.first(): String = substring(0, 1)
        \\fun String.uppercased(): String = uppercase()
        \\fun String.banner(): String = first().uppercased() + ":" + uppercase()
        \\fun main() { println("kotlin".banner()) }
        \\
    ;
    try assertKlio("ext_chain", src, "K:KOTLIN\n");
}

test "extension_with_receiver_lambda_arg" {
    const src =
        \\
        \\fun <T> T.alsoLog(tag: String): T {
        \\    println("[$tag]$this")
        \\    return this
        \\}
        \\fun main() {
        \\    val x = "hi".alsoLog("L1").alsoLog("L2")
        \\    println("done:$x")
        \\}
        \\
    ;
    try assertKlio("ext_log", src, "[L1]hi\n[L2]hi\ndone:hi\n");
}

test "extension_member_property" {
    const src =
        \\
        \\val String.firstChar: Char get() = this[0]
        \\fun main() { println("abc".firstChar) }
        \\
    ;
    try assertKlio("ext_member_prop", src, "a\n");
}

test "extension_with_default_arg" {
    const src =
        \\
        \\fun String.padTo(n: Int, fill: Char = ' '): String {
        \\    val k = n - length
        \\    return if (k > 0) this + fill.toString().repeat(k) else this
        \\}
        \\fun main() {
        \\    println("[${"hi".padTo(5)}|${"hi".padTo(5, '*')}]")
        \\}
        \\
    ;
    try assertKlio("ext_default", src, "[hi   |hi***]\n");
}

test "extension_explicit_call_via_qualifier" {
    const src =
        \\
        \\fun Int.plusOne(): Int = this + 1
        \\fun Long.plusOne(): Long = this + 1
        \\fun main() {
        \\    val a: Int = 5.plusOne()
        \\    val b: Long = 5L.plusOne()
        \\    println("$a|$b")
        \\}
        \\
    ;
    try assertKlio("ext_qualifier", src, "6|6\n");
}

test "with_receiver_member_extension_visible_in_lambda" {
    const src =
        \\
        \\class A {
        \\    val tag = "T"
        \\    fun List<Int>.show(): String = joinToString(",") { "$tag:$it" }
        \\}
        \\fun main() {
        \\    val a = A()
        \\    val r = with(a) { listOf(1, 2, 3).show() }
        \\    println(r)
        \\}
        \\
    ;
    try assertKlio("with_member_ext", src, "T:1,T:2,T:3\n");
}

test "with_receiver_member_extension_virtual_override" {
    const src =
        \\
        \\open class Animal {
        \\    open val sound: String = "?"
        \\    open fun List<Int>.tagged(): String = joinToString(",") { "$sound:$it" }
        \\}
        \\class Dog : Animal() {
        \\    override val sound: String = "woof"
        \\}
        \\fun main() {
        \\    val d = Dog()
        \\    val r = with(d) { listOf(1, 2, 3).tagged() }
        \\    println(r)
        \\}
        \\
    ;
    try assertKlio("with_member_ext_virtual", src, "woof:1,woof:2,woof:3\n");
}

test "inline_member_extension_via_with_block" {
    const src =
        \\
        \\class Repo {
        \\    val tag = "R"
        \\    fun emit(s: String): String = "$tag:$s"
        \\    inline fun List<Int>.summary(prefix: String): String =
        \\        prefix + ":" + joinToString(",") { emit("$it") }
        \\}
        \\fun main() {
        \\    val r = Repo()
        \\    with(r) { println(listOf(1, 2, 3).summary("nums")) }
        \\}
        \\
    ;
    try assertKlio("inline_member_ext_with", src, "nums:R:1,R:2,R:3\n");
}

test "inline_member_extension_on_int_in_method_body" {
    const src =
        \\
        \\class Container {
        \\    val cap = "X"
        \\    inline fun Int.tag(): String = "$cap-$this"
        \\    fun render(xs: List<Int>): String = xs.joinToString(",") { it.tag() }
        \\}
        \\fun main() {
        \\    println(Container().render(listOf(1, 2, 3)))
        \\}
        \\
    ;
    try assertKlio("inline_member_ext_int", src, "X-1,X-2,X-3\n");
}

test "inline_dsl_block_with_nested_groups" {
    const src =
        \\
        \\class Builder {
        \\    val items = mutableListOf<String>()
        \\    inline fun group(name: String, body: Builder.() -> Unit): Builder {
        \\        items.add("<$name>")
        \\        this.body()
        \\        items.add("</$name>")
        \\        return this
        \\    }
        \\    fun text(s: String): Builder { items.add(s); return this }
        \\    fun result(): String = items.joinToString("")
        \\}
        \\fun main() {
        \\    val b = Builder()
        \\        .group("root") {
        \\            text("A")
        \\            group("inner") { text("B"); text("C") }
        \\            text("D")
        \\        }
        \\    println(b.result())
        \\}
        \\
    ;
    try assertKlio("inline_dsl_nested", src, "<root>A<inner>BC</inner>D</root>\n");
}

test "inline_non_local_return_through_nested_blocks" {
    const src =
        \\
        \\inline fun trace(label: String, block: () -> Unit) {
        \\    println(">$label")
        \\    block()
        \\    println("<$label")
        \\}
        \\fun outer(): String {
        \\    val sb = StringBuilder()
        \\    trace("a") {
        \\        sb.append("a1;")
        \\        trace("b") {
        \\            sb.append("b1;")
        \\            for (i in 1..3) {
        \\                if (i == 2) return sb.toString() + "early"
        \\                sb.append("i=$i;")
        \\            }
        \\        }
        \\        sb.append("a2;")
        \\    }
        \\    return sb.toString() + "end"
        \\}
        \\fun main() { println(outer()) }
        \\
    ;
    try assertKlio("inline_nonlocal_return", src, ">a\n>b\na1;b1;i=1;early\n");
}

test "crossinline_lambda_used_after_return" {
    const src =
        \\
        \\inline fun <T> withRetry(n: Int, crossinline factory: () -> T, validate: (T) -> Boolean): T? {
        \\    for (i in 1..n) {
        \\        val v = factory()
        \\        if (validate(v)) return v
        \\    }
        \\    return null
        \\}
        \\fun main() {
        \\    var counter = 0
        \\    val v = withRetry(5, factory = { counter++; counter }) { it > 3 }
        \\    println("v=$v,tries=$counter")
        \\}
        \\
    ;
    try assertKlio("crossinline_retry", src, "v=4,tries=4\n");
}

test "flat_map_to_inline_extension_against_user_list" {
    const src =
        \\
        \\inline fun <T, R> List<T>.flatMapTo(out: MutableList<R>, transform: (T) -> List<R>): MutableList<R> {
        \\    for (x in this) out.addAll(transform(x))
        \\    return out
        \\}
        \\fun main() {
        \\    val out = mutableListOf<Int>()
        \\    listOf("ab", "cde").flatMapTo(out) { s -> s.map { it.code } }
        \\    println(out)
        \\}
        \\
    ;
    try assertKlio("flat_map_to_inline", src, "[97, 98, 99, 100, 101]\n");
}

test "member_extension_unary_operator_on_primitive" {
    const src =
        \\
        \\class Builder(val items: MutableList<Int> = mutableListOf()) {
        \\    operator fun Int.unaryPlus() { items.add(this) }
        \\    fun work() { +1; +2; +3 }
        \\    fun render(): String = items.joinToString(",")
        \\}
        \\fun main() {
        \\    val b = Builder()
        \\    b.work()
        \\    println(b.render())
        \\}
        \\
    ;
    try assertKlio("member_ext_unary_primitive", src, "1,2,3\n");
}

test "bare_ext_inline_call_in_class_method_binds_enclosing_class_receiver" {
    // Same-name inline extensions on two unrelated receivers, bare-
    // called (with a non-local return forcing the splice) from each
    // class's methods: the enclosing class is the implicit receiver, so
    // A's method splices `A.label` and B's splices `B.label` (kotlinc:
    // got:A / got:B) — never the first-declared candidate. Both
    // declaration orders pin order-independence.
    const a_first =
        \\var tag = ""
        \\class A {
        \\    fun m() { label { println("got:" + tag); return } }
        \\}
        \\class B {
        \\    fun m() { label { println("got:" + tag); return } }
        \\}
        \\inline fun A.label(f: () -> Unit) { tag = "A"; f() }
        \\inline fun B.label(f: () -> Unit) { tag = "B"; f() }
        \\fun main() { A().m(); B().m() }
        \\
    ;
    const b_first =
        \\var tag = ""
        \\class A {
        \\    fun m() { label { println("got:" + tag); return } }
        \\}
        \\class B {
        \\    fun m() { label { println("got:" + tag); return } }
        \\}
        \\inline fun B.label(f: () -> Unit) { tag = "B"; f() }
        \\inline fun A.label(f: () -> Unit) { tag = "A"; f() }
        \\fun main() { A().m(); B().m() }
        \\
    ;
    try assertKlio("ext_inline_class_recv_a_first", a_first, "got:A\ngot:B\n");
    try assertKlio("ext_inline_class_recv_b_first", b_first, "got:A\ngot:B\n");
}

test "suspend_inline_ext_twins_bind_by_enclosing_class_receiver" {
    // The suspend-inline variant: a `suspend inline` extension must
    // splice (its continuation capture is only correct inlined), and
    // the splice must still pick the enclosing class's extension, not
    // the first-declared one (kotlinc: got:A / got:B). The completion
    // is an anonymous object whose `override val context =
    // EmptyCoroutineContext` initializer must bind the singleton —
    // also pinning anon-object property inits that read a global
    // object by bare name.
    const src =
        \\import kotlin.coroutines.*
        \\
        \\var tag = ""
        \\class A {
        \\    suspend fun m() { label { println("got:" + tag) } }
        \\}
        \\class B {
        \\    suspend fun m() { label { println("got:" + tag) } }
        \\}
        \\suspend inline fun A.label(f: () -> Unit) { tag = "A"; f() }
        \\suspend inline fun B.label(f: () -> Unit) { tag = "B"; f() }
        \\
        \\fun run(block: suspend () -> Unit) {
        \\    block.startCoroutine(object : Continuation<Unit> {
        \\        override val context = EmptyCoroutineContext
        \\        override fun resumeWith(result: Result<Unit>) {}
        \\    })
        \\}
        \\fun main() {
        \\    run { A().m(); B().m() }
        \\}
        \\
    ;
    try assertKlio("suspend_inline_ext_class_recv", src, "got:A\ngot:B\n");
}

test "base_class_extension_accepts_subclass_method_receiver" {
    // The receiver match walks the supertype chain: `B : A()` accepts
    // `A.label` for B's methods (kotlinc: got:A) — including when an
    // unrelated receiver's extension is declared first (kotlinc still
    // got:A) — and B's own extension outranks the base one when both
    // exist (kotlinc: got:B).
    const base_only =
        \\var tag = ""
        \\open class A
        \\class B : A() {
        \\    fun m() { label { println("got:" + tag); return } }
        \\}
        \\inline fun A.label(f: () -> Unit) { tag = "A"; f() }
        \\fun main() { B().m() }
        \\
    ;
    const unrelated_first =
        \\var tag = ""
        \\open class A
        \\class C
        \\class B : A() {
        \\    fun m() { label { println("got:" + tag); return } }
        \\}
        \\inline fun C.label(f: () -> Unit) { tag = "C"; f() }
        \\inline fun A.label(f: () -> Unit) { tag = "A"; f() }
        \\fun main() { B().m() }
        \\
    ;
    const derived_wins =
        \\var tag = ""
        \\open class A
        \\class B : A() {
        \\    fun m() { label { println("got:" + tag); return } }
        \\}
        \\inline fun A.label(f: () -> Unit) { tag = "A"; f() }
        \\inline fun B.label(f: () -> Unit) { tag = "B"; f() }
        \\fun main() { B().m() }
        \\
    ;
    try assertKlio("ext_inline_super_recv", base_only, "got:A\n");
    try assertKlio("ext_inline_super_recv_unrelated_first", unrelated_first, "got:A\n");
    try assertKlio("ext_inline_super_recv_derived_wins", derived_wins, "got:B\n");
}

// Extension resolution inside an interface-extension body is STATIC:
// `this` is declared as the interface, so a bare same-name extension
// call binds the interface's extension even when the runtime value is a
// delegating wrapper carrying its own extension. The direct call on the
// wrapper still binds the wrapper's extension by its static type.
// kotlinc-verified both directions (the DispatchedContinuation shape).
test "ext_static_receiver_in_iface_ext_body" {
    const src =
        \\interface I5 { fun member(): String }
        \\class Impl5 : I5 { override fun member() = "impl" }
        \\class W5(i: I5) : I5 by i
        \\
        \\fun I5.describe() = "on-iface"
        \\fun W5.describe() = "on-wrapper"
        \\fun I5.helper() = "ext:" + describe()
        \\
        \\fun main() {
        \\    val w = W5(Impl5())
        \\    println(w.describe())
        \\    println(w.helper())
        \\}
        \\
    ;
    try assertKlio("ext_static_recv_iface_body", src, "on-wrapper\next:on-iface\n");
}

// A receiver-walk PROBE that is inapplicable by parameter type must fall
// through to the outer receiver — kotlinc resolves `f("x")` to
// `A.f(String)`; `B.f(Int)` is not a candidate and must not run (its
// throw is the proof it ran). The ran-and-threw direction is pinned by
// the sibling test below: an applicable candidate that throws owns its
// control flow. kotlinc-verified both directions.
test "bare_call_inapplicable_inner_candidate_falls_through" {
    const src =
        \\class A { fun f(s: String) = "outer:" + s }
        \\class B { fun f(n: Int): String { throw IllegalStateException("inner ran") } }
        \\
        \\fun main() {
        \\    with(A()) {
        \\        with(B()) {
        \\            println(f("x"))
        \\        }
        \\    }
        \\}
        \\
    ;
    try assertKlio("bare_call_inapplicable_inner", src, "outer:x\n");
}

test "bare_call_applicable_inner_candidate_throw_propagates" {
    const src =
        \\class C { fun g(): String { throw IllegalStateException("boom1") } }
        \\class D { fun g() = "outer-d" }
        \\
        \\fun main() {
        \\    try {
        \\        with(D()) {
        \\            with(C()) {
        \\                println(g())
        \\            }
        \\        }
        \\    } catch (e: IllegalStateException) {
        \\        println("caught " + e.message)
        \\    }
        \\}
        \\
    ;
    try assertKlio("bare_call_ran_throw_propagates", src, "caught boom1\n");
}
