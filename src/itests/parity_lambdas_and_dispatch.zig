//! Lambda + dispatch parity: lambda over receiver, lambda inside
//! generic dispatch, suspended lambda captures, member-ref to
//! generic methods, scope function chaining with explicit this@.
//!
//! Ported from the Rust suite.
const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_lambdas_and_dispatch";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


/// Run an embedded program through the real pack pipeline and assert its
/// stdout equals `expected`. Uses an arena per test so the leak-checking
/// test allocator never backs the pipeline.
fn assertKlio(name: []const u8, src: []const u8, expected: []const u8) !void {
    // Reset the per-program arena so each program's ASTs/IR/packs/VM graph
    // is reclaimed instead of accumulating across this file's tests. Safe:
    // the cross-program globals are page_allocator-backed, not this arena.
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, TMP_DIR) catch |e| {
        std.debug.print("lambdas_and_dispatch {s}: mkdir failed {s}\n", .{ name, @errorName(e) });
        return error.KlioRunFailed;
    };
    const path = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name });
    cwd.writeFile(io, .{ .sub_path = path, .data = src }) catch |e| {
        std.debug.print("lambdas_and_dispatch {s}: write failed {s}\n", .{ name, @errorName(e) });
        return error.KlioRunFailed;
    };

    const res = try parity.runWithPacks(a, io, path);
    switch (res) {
        .ok => |got| try std.testing.expectEqualStrings(expected, got),
        .err => |m| {
            std.debug.print("lambdas_and_dispatch {s}: klio run failed: {s}\n", .{ name, m });
            return error.KlioRunFailed;
        },
    }
}

test "function_reference_to_extension" {
    const src =
        \\
        \\fun String.shout(): String = this.uppercase() + "!"
        \\fun main() {
        \\    val xs = listOf("hi", "yo")
        \\    println(xs.joinToString(",", transform = String::shout))
        \\}
        \\
    ;
    try assertKlio("fnref_ext", src, "HI!,YO!\n");
}

test "member_reference_bound" {
    const src =
        \\
        \\class Box(val v: Int) { fun show(): String = "Box($v)" }
        \\fun main() {
        \\    val b = Box(7)
        \\    val ref = b::show
        \\    println(ref())
        \\}
        \\
    ;
    try assertKlio("memref_bound", src, "Box(7)\n");
}

test "lambda_with_two_receivers_via_this_at_label" {
    const src =
        \\
        \\class Outer {
        \\    val tag = "OUT"
        \\    fun build(): String {
        \\        return with(StringBuilder()) {
        \\            append(this@Outer.tag)
        \\            append("|")
        \\            append(this.length.toString())
        \\            toString()
        \\        }
        \\    }
        \\}
        \\fun main() { println(Outer().build()) }
        \\
    ;
    try assertKlio("two_receivers", src, "OUT|4\n");
}

test "lambda_in_subclass_calls_super" {
    const src =
        \\
        \\open class Base { open fun ping(): String = "base" }
        \\class Sub : Base() {
        \\    override fun ping(): String = "sub-${super.ping()}"
        \\    fun chain(): String = listOf(1,2).joinToString(",") { ping() + "-$it" }
        \\}
        \\fun main() { println(Sub().chain()) }
        \\
    ;
    try assertKlio("lambda_super", src, "sub-base-1,sub-base-2\n");
}

test "higher_order_local_fn_dispatch" {
    const src =
        \\
        \\fun main() {
        \\    fun mul(k: Int): (Int) -> Int = { x -> x * k }
        \\    val twice = mul(2)
        \\    val triple = mul(3)
        \\    println("${twice(5)},${triple(5)}")
        \\}
        \\
    ;
    try assertKlio("higher_local", src, "10,15\n");
}

test "lambda_in_for_capturing_loop_var" {
    const src =
        \\
        \\fun main() {
        \\    val makers = mutableListOf<() -> Int>()
        \\    for (i in 1..3) {
        \\        // Each iteration's lambda captures a fresh `i`.
        \\        val v = i
        \\        makers.add { v }
        \\    }
        \\    println(makers.joinToString(",") { it().toString() })
        \\}
        \\
    ;
    try assertKlio("loop_var", src, "1,2,3\n");
}

test "closure_propagates_through_collect" {
    const src =
        \\
        \\fun main() {
        \\    var s = 0
        \\    listOf(1,2,3,4).forEach { s += it * it }
        \\    println(s)
        \\}
        \\
    ;
    try assertKlio("collect_var", src, "30\n");
}

test "lambda_dispatch_through_polymorphic_param" {
    const src =
        \\
        \\interface F<T> { fun apply(x: T): String }
        \\class IntF : F<Int> { override fun apply(x: Int): String = "int:$x" }
        \\class StrF : F<String> { override fun apply(x: String): String = "str:$x" }
        \\fun <T> run(f: F<T>, x: T): String = f.apply(x)
        \\fun main() {
        \\    println("${run(IntF(), 7)}|${run(StrF(), "hi")}")
        \\}
        \\
    ;
    try assertKlio("poly_dispatch", src, "int:7|str:hi\n");
}

test "typed_callable_reference_to_class_method" {
    const src =
        \\
        \\class Foo {
        \\    fun greet(name: String): String = "Hello, $name"
        \\}
        \\fun main() {
        \\    val f = Foo()
        \\    val refs = listOf("Ann", "Bob").map(f::greet)
        \\    println(refs.joinToString(";"))
        \\}
        \\
    ;
    try assertKlio("callable_ref", src, "Hello, Ann;Hello, Bob\n");
}

test "scope_fn_apply_chain_returns_receiver" {
    const src =
        \\
        \\class Bag {
        \\    val items = mutableListOf<String>()
        \\    fun add(s: String): Bag = apply { items.add(s) }
        \\}
        \\fun main() {
        \\    val b = Bag().add("a").add("b").add("c")
        \\    println(b.items.joinToString(","))
        \\}
        \\
    ;
    try assertKlio("apply_chain", src, "a,b,c\n");
}

test "apply_lambda_writes_member_property" {
    const src =
        \\
        \\class Counter {
        \\    var n = 0
        \\    fun bump() { apply { n += 1 } }
        \\}
        \\fun main() {
        \\    val c = Counter()
        \\    c.bump(); c.bump(); c.bump()
        \\    println(c.n)
        \\}
        \\
    ;
    try assertKlio("apply_writes_member", src, "3\n");
}

test "operator_inc_via_apply_returns_modified_self" {
    const src =
        \\
        \\class Counter {
        \\    var n = 0
        \\    operator fun inc(): Counter = apply { n += 1 }
        \\    operator fun dec(): Counter = apply { n -= 1 }
        \\}
        \\fun main() {
        \\    var c = Counter()
        \\    c++; c++; c++; c--
        \\    println(c.n)
        \\}
        \\
    ;
    try assertKlio("operator_inc_apply", src, "2\n");
}

test "iterable_max_of_or_null_with_transform" {
    const src =
        \\
        \\data class Item(val name: String, val price: Int)
        \\fun main() {
        \\    val items = listOf(Item("a", 3), Item("b", 7), Item("c", 2))
        \\    println(items.maxOfOrNull { it.price })
        \\    println(items.minOfOrNull { it.price })
        \\    println(emptyList<Int>().maxOfOrNull { it * 2 })
        \\}
        \\
    ;
    try assertKlio("max_of_or_null", src, "7\n2\nnull\n");
}

test "invoke_operator_instance_used_as_lambda_value" {
    const src =
        \\
        \\class Tagger(val prefix: String) {
        \\    operator fun invoke(s: String): String = "$prefix:$s"
        \\}
        \\fun main() {
        \\    val t = Tagger("note")
        \\    println(t("hello"))
        \\    println(listOf("a","b").map(t).joinToString(","))
        \\    println(listOf("c","d").map(t::invoke).joinToString(","))
        \\}
        \\
    ;
    try assertKlio("operator_invoke_value", src, "note:hello\nnote:a,note:b\nnote:c,note:d\n");
}

test "unbound_class_method_reference_invoked_as_value" {
    const src =
        \\
        \\fun main() {
        \\    val f: (String, String) -> String = String::plus
        \\    println(f("a", "b"))
        \\    println(listOf("hi", "yo").map(String::uppercase).joinToString(","))
        \\}
        \\
    ;
    try assertKlio("unbound_method_ref", src, "ab\nHI,YO\n");
}

test "lambda_value_remove_compares_by_identity" {
    const src =
        \\
        \\class Stream<T> {
        \\    val subs = mutableListOf<(T) -> Unit>()
        \\    fun subscribe(h: (T) -> Unit): () -> Unit {
        \\        subs.add(h)
        \\        return { subs.remove(h) }
        \\    }
        \\    fun emit(v: T) { for (s in subs.toList()) s(v) }
        \\}
        \\fun main() {
        \\    val s = Stream<Int>()
        \\    val log = mutableListOf<String>()
        \\    val unsubA = s.subscribe { log.add("a:$it") }
        \\    s.subscribe { log.add("b:$it") }
        \\    s.emit(1)
        \\    unsubA()
        \\    s.emit(2)
        \\    println(log.joinToString(","))
        \\}
        \\
    ;
    try assertKlio("lambda_identity_remove", src, "a:1,b:1,b:2\n");
}

test "receiver_typed_lambda_invoked_bare_uses_enclosing_this" {
    const src =
        \\
        \\class Html {
        \\    private val sb = StringBuilder()
        \\    fun tag(name: String, body: Html.() -> Unit) {
        \\        sb.append("<$name>")
        \\        body()
        \\        sb.append("</$name>")
        \\    }
        \\    fun text(s: String) { sb.append(s) }
        \\    fun result(): String = sb.toString()
        \\}
        \\fun main() {
        \\    val h = Html()
        \\    h.tag("div") {
        \\        tag("p") { text("first") }
        \\        tag("p") { text("second") }
        \\    }
        \\    println(h.result())
        \\}
        \\
    ;
    try assertKlio("receiver_lambda_bare", src, "<div><p>first</p><p>second</p></div>\n");
}

test "receiver_typed_lambda_bare_invocation_field_read" {
    const src =
        \\
        \\class Pipe {
        \\    val name = "p"
        \\    fun pump(action: Pipe.() -> Unit) { action() }
        \\}
        \\fun main() {
        \\    Pipe().pump { println(name) }
        \\}
        \\
    ;
    try assertKlio("receiver_lambda_field", src, "p\n");
}
