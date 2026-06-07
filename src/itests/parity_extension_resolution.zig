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
