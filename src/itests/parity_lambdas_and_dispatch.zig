//! Lambda + dispatch parity: lambda over receiver, lambda inside
//! generic dispatch, suspended lambda captures, member-ref to
//! generic methods, scope function chaining with explicit this@.
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

/// Run an embedded program expected to FAIL with an unresolved-reference
/// error naming `unresolved`. Pins kotlinc-rejected shapes (the interpreter
/// surfaces them as runtime resolution errors).
fn assertKlioUnresolved(name: []const u8, src: []const u8, unresolved: []const u8) !void {
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
        .ok => |got| {
            std.debug.print("lambdas_and_dispatch {s}: expected unresolved `{s}`, program ran: {s}\n", .{ name, unresolved, got });
            return error.KlioRunFailed;
        },
        .err => |m| {
            if (std.mem.indexOf(u8, m, "unresolved") == null or std.mem.indexOf(u8, m, unresolved) == null) {
                std.debug.print("lambdas_and_dispatch {s}: expected unresolved `{s}`, got error: {s}\n", .{ name, unresolved, m });
                return error.KlioRunFailed;
            }
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

test "bare_write_reaches_outer_receiver_member" {
    // kotlinc-pinned (tests/fixtures/parity_corpus/bare_write_outer_receiver_member.kt):
    // a bare-name write inside a nested receiver lambda resolves against
    // the implicit receivers innermost-first, like the read side.
    const src =
        \\
        \\class Outer { var label: String = "init" }
        \\class Gadget { var size: Int = 0 }
        \\fun main() {
        \\    val o = Outer()
        \\    with(o) {
        \\        with(Gadget()) {
        \\            label = "from-inner"
        \\            size = 7
        \\            println(size)
        \\        }
        \\    }
        \\    println(o.label)
        \\}
        \\
    ;
    try assertKlio("bare_write_outer_receiver", src, "7\nfrom-inner\n");
}

test "bare_write_member_beats_same_named_global" {
    // kotlinc-pinned: an enclosing receiver's member outranks a top-level
    // `var` of the same name for a bare-name write.
    const src =
        \\
        \\class Outer { var label: String = "init" }
        \\class Gadget { var size: Int = 0 }
        \\var label: String = "global"
        \\fun main() {
        \\    val o = Outer()
        \\    with(o) {
        \\        with(Gadget()) {
        \\            label = "written"
        \\        }
        \\    }
        \\    println(o.label)
        \\    println(label)
        \\}
        \\
    ;
    try assertKlio("bare_write_member_over_global", src, "written\nglobal\n");
}

test "extension_on_inner_receiver_beats_outer_member" {
    // kotlinc-pinned: implicit-receiver call resolution is per-receiver,
    // innermost-first — an extension applicable to the inner receiver
    // outranks a member of the outer receiver.
    const src =
        \\
        \\class Outer { fun describe(): String = "outer-member" }
        \\class Inner
        \\fun Inner.describe(): String = "inner-extension"
        \\fun main() {
        \\    with(Outer()) {
        \\        with(Inner()) {
        \\            println(describe())
        \\        }
        \\    }
        \\}
        \\
    ;
    try assertKlio("inner_ext_over_outer_member", src, "inner-extension\n");
}

test "bare_write_in_inner_class_lambda_reaches_outer_property" {
    // kotlinc-pinned: a dispatch receiver brings its class-nesting tower
    // into scope for writes — a lambda in an inner-class method writing a
    // bare name mutates `this@Owner`'s property.
    const src =
        \\
        \\class Owner {
        \\    var status: String = "init"
        \\    inner class Pocket {
        \\        fun update() {
        \\            listOf(1).forEach { status = "from-lambda" }
        \\        }
        \\    }
        \\}
        \\fun main() {
        \\    val o = Owner()
        \\    o.Pocket().update()
        \\    println(o.status)
        \\}
        \\
    ;
    try assertKlio("inner_class_lambda_outer_write", src, "from-lambda\n");
}

test "top_level_fn_cannot_see_callers_receiver" {
    // kotlinc rejects resolving a bare name in a top-level function body
    // against a *caller's* `with` receiver (dynamic scope). The lowering
    // classifies the no-receiver-context call as a static global, so the
    // program fails with an unresolved reference instead of leaking the
    // caller's receiver.
    const src =
        \\
        \\class Box { fun payload(): String = "hidden" }
        \\fun leak(): String = payload()
        \\fun main() {
        \\    with(Box()) {
        \\        println(leak())
        \\    }
        \\}
        \\
    ;
    try assertKlioUnresolved("dynamic_scope_call_rejected", src, "payload");
}

test "closure_in_no_receiver_scope_writes_top_level" {
    // kotlinc: a lambda created in `main` (no receivers in scope) resolves
    // a bare write lexically — the top-level `var`, never the member of
    // the method it is dynamically invoked from.
    const src =
        \\
        \\class Host {
        \\    var label: String = "host-init"
        \\    fun act(f: () -> Unit) { f() }
        \\}
        \\var label: String = "global"
        \\fun main() {
        \\    val h = Host()
        \\    val f = { label = "written" }
        \\    h.act(f)
        \\    println(h.label)
        \\    println(label)
        \\}
        \\
    ;
    try assertKlio("closure_lexical_write", src, "host-init\nwritten\n");
}

test "closure_in_no_receiver_scope_reads_top_level" {
    const src =
        \\
        \\class Host {
        \\    val label: String = "host-member"
        \\    fun act(f: () -> String): String = f()
        \\}
        \\val label: String = "global"
        \\fun main() {
        \\    val f = { label }
        \\    println(Host().act(f))
        \\}
        \\
    ;
    try assertKlio("closure_lexical_read", src, "global\n");
}

test "closure_captures_creation_receivers_lexically" {
    // The lambda is created inside `with(W())` and invoked later from a
    // scope with different (or no) receivers: kotlinc resolves `tag`
    // against the creation-time receiver, not the invocation context.
    const src =
        \\
        \\val tag = "global"
        \\class W { val tag = "w-member" }
        \\var f: (() -> String)? = null
        \\fun main() {
        \\    with(W()) { f = { tag } }
        \\    println(f!!())
        \\}
        \\
    ;
    try assertKlio("closure_creation_chain", src, "w-member\n");
}

test "closure_creation_scope_beats_invocation_scope" {
    const src =
        \\
        \\class A { val mark = "a-member" }
        \\class B { val mark = "b-member" }
        \\fun main() {
        \\    var g: (() -> String)? = null
        \\    with(A()) { g = { mark } }
        \\    with(B()) { println(g!!()) }
        \\}
        \\
    ;
    try assertKlio("closure_creation_vs_invocation", src, "a-member\n");
}

test "anon_fun_resolves_enclosing_receivers" {
    // An anonymous-function body resolves bare names against the
    // lexically enclosing receivers exactly like a lambda body.
    const src =
        \\
        \\class Box {
        \\    fun payload(): String = "member-fn"
        \\    val tag = "member-prop"
        \\}
        \\fun main() {
        \\    with(Box()) {
        \\        val f = fun(): String { return payload() }
        \\        println(f())
        \\        val g = fun(): String { return tag }
        \\        println(g())
        \\    }
        \\}
        \\
    ;
    try assertKlio("anon_fun_receiver_scope", src, "member-fn\nmember-prop\n");
}

test "anon_fun_bare_write_reaches_receiver_member" {
    const src =
        \\
        \\class Box { var label = "init" }
        \\var label = "global"
        \\fun main() {
        \\    with(Box()) {
        \\        val w = fun() { label = "set-by-anon" }
        \\        w()
        \\        println(label)
        \\    }
        \\    println(label)
        \\}
        \\
    ;
    try assertKlio("anon_fun_receiver_write", src, "set-by-anon\nglobal\n");
}

test "function_shape_ext_requires_function_receiver" {
    // `(() -> Int).describe()` is not applicable to a plain instance, so
    // the outer receiver's member binds.
    const src =
        \\
        \\class Outer { fun describe(): String = "outer-member" }
        \\class Inner
        \\fun (() -> Int).describe(): String = "fn-ext"
        \\fun main() {
        \\    with(Outer()) { with(Inner()) { println(describe()) } }
        \\}
        \\
    ;
    try assertKlio("fn_shape_ext_proof", src, "outer-member\n");
}

test "bounded_type_param_ext_requires_bound" {
    // `<T : Number> T.halve()` is not applicable to a String receiver
    // (outer member wins) but is to an Int receiver (innermost ext wins).
    const src =
        \\
        \\class Outer { fun halve(): String = "outer-member" }
        \\fun <T : Number> T.halve(): String = "number-ext"
        \\fun main() {
        \\    with(Outer()) { with("str") { println(halve()) } }
        \\    with(Outer()) { with(42) { println(halve()) } }
        \\}
        \\
    ;
    try assertKlio("bounded_generic_ext_proof", src, "outer-member\nnumber-ext\n");
}

test "generic_elem_ext_proof_both_ways" {
    // `List<String>.render()` is disproven on a list of Ints (outer
    // member binds) and proven on a list of Strings (innermost ext binds).
    const src =
        \\
        \\class Outer { fun render(): String = "outer-member" }
        \\fun List<String>.render(): String = "string-list-ext"
        \\fun main() {
        \\    with(Outer()) { with(listOf(1, 2)) { println(render()) } }
        \\    with(Outer()) { with(listOf("a", "b")) { println(render()) } }
        \\}
        \\
    ;
    try assertKlio("generic_elem_ext_proof", src, "outer-member\nstring-list-ext\n");
}

test "typealias_ext_receiver_expands" {
    const src =
        \\
        \\typealias Rows = List<Int>
        \\fun Rows.total(): String = "rows-ext"
        \\class Outer { fun total(): String = "outer-member" }
        \\fun main() {
        \\    with(Outer()) { with(listOf(1, 2)) { println(total()) } }
        \\}
        \\
    ;
    try assertKlio("typealias_ext_receiver", src, "rows-ext\n");
}

test "nullable_ext_receiver_accepts_null_subject" {
    const src =
        \\
        \\class Outer { fun show(): String = "outer-member" }
        \\class Thing
        \\fun Thing?.show(): String = if (this == null) "ext-null" else "ext-thing"
        \\fun main() {
        \\    val t: Thing? = null
        \\    with(Outer()) { with(t) { println(show()) } }
        \\}
        \\
    ;
    try assertKlio("nullable_ext_null_subject", src, "ext-null\n");
}

test "outer_member_read_beats_top_level_when_inner_misses" {
    // The innermost receiver does not own `z`; the outer receiver's
    // member outranks the top-level binding — a candidate probe must not
    // adopt a global.
    const src =
        \\
        \\class A
        \\class B { val z: String = "b-member" }
        \\val z: String = "global"
        \\fun main() {
        \\    with(B()) { with(A()) { println(z) } }
        \\}
        \\
    ;
    try assertKlio("outer_member_over_global_read", src, "b-member\n");
}

test "companion_property_rides_implicit_chain" {
    // A companion `val` is an implicit receiver at its class's own depth:
    // it outranks the top-level binding inside the class's members, but
    // an instance member and a with-subject member outrank it.
    const src =
        \\
        \\val tag: String = "global"
        \\class Other
        \\class Host {
        \\    companion object { val tag: String = "companion" }
        \\    fun test(): String = with(Other()) { tag }
        \\}
        \\class Host2 {
        \\    val tag = "instance"
        \\    companion object { val tag2 = "companion" }
        \\    fun test(): String = tag
        \\}
        \\class WithSubject { val mark = "subject-member" }
        \\class Host3 {
        \\    companion object { val mark = "companion" }
        \\    fun test(): String = with(WithSubject()) { mark }
        \\}
        \\fun main() {
        \\    println(Host().test())
        \\    println(Host2().test())
        \\    println(Host3().test())
        \\}
        \\
    ;
    try assertKlio("companion_implicit_chain", src, "companion\ninstance\nsubject-member\n");
}

test "outer_class_companion_visible_in_inner_class" {
    const src =
        \\
        \\class Outer {
        \\    companion object { val mark = "outer-companion" }
        \\    inner class In { fun f(): String = mark }
        \\}
        \\fun main() { println(Outer().In().f()) }
        \\
    ;
    try assertKlio("inner_sees_outer_companion", src, "outer-companion\n");
}

test "companion_var_takes_bare_write" {
    const src =
        \\
        \\class Host {
        \\    companion object { var count = 0 }
        \\    fun bump() { count = 5 }
        \\}
        \\fun main() {
        \\    val h = Host()
        \\    h.bump()
        \\    println(Host.count)
        \\}
        \\
    ;
    try assertKlio("companion_var_write", src, "5\n");
}

test "bare_write_skips_method_named_like_var" {
    // An assignment LHS resolves only to properties: a member *function*
    // of the written name never captures the write, at any receiver
    // depth, and compound assignment reads and writes the same binding.
    const src =
        \\
        \\class Holder { fun label(): String = "fn" }
        \\class OuterFn { fun tag(): String = "fn" }
        \\class Inner
        \\class Counter { fun count(): Int = 99 }
        \\var label: String = "global"
        \\var tag = "global"
        \\var count = 10
        \\fun main() {
        \\    with(Holder()) { label = "written" }
        \\    println(label)
        \\    with(OuterFn()) { with(Inner()) { tag = "written" } }
        \\    println(tag)
        \\    with(Counter()) { count += 5 }
        \\    println(count)
        \\}
        \\
    ;
    try assertKlio("write_skips_methods", src, "written\nwritten\n15\n");
}

test "member_prop_invoke_shadows_top_level_fn" {
    // kotlinc resolves a bare call scope-by-scope: the receiver's member
    // property + invoke convention outranks the top-level function.
    const src =
        \\
        \\class Host { val handler: () -> String = { "host-property" } }
        \\fun handler(): String = "global-fn"
        \\fun main() {
        \\    with(Host()) { println(handler()) }
        \\}
        \\
    ;
    try assertKlio("member_prop_invoke_shadows", src, "host-property\n");
}

test "member_fn_shadows_top_level_fn" {
    const src =
        \\
        \\class Host { fun handler(): String = "member-fn" }
        \\fun handler(): String = "global-fn"
        \\fun main() { with(Host()) { println(handler()) } }
        \\
    ;
    try assertKlio("member_fn_shadows", src, "member-fn\n");
}

test "inapplicable_member_falls_to_top_level_fn" {
    // The member takes an argument the call does not supply, so it is
    // not a candidate; the top-level function binds.
    const src =
        \\
        \\class Host { fun handler(x: Int): String = "member-$x" }
        \\fun handler(): String = "global-fn"
        \\fun main() { with(Host()) { println(handler()) } }
        \\
    ;
    try assertKlio("inapplicable_member_falls", src, "global-fn\n");
}

test "ext_receiver_brings_no_outer_tower" {
    // A top-level extension on an inner class sees only the extension
    // receiver — not the receiver's enclosing-instance tower (kotlinc:
    // `status` is the top-level var, not `Owner.status`).
    const src =
        \\
        \\class Owner {
        \\    var status: String = "owner-value"
        \\    inner class Pocket { var p: Int = 0 }
        \\}
        \\var status: String = "global"
        \\fun Owner.Pocket.poke(): String = status
        \\fun main() {
        \\    val o = Owner()
        \\    println(o.Pocket().poke())
        \\}
        \\
    ;
    try assertKlio("ext_receiver_no_tower", src, "global\n");
}

test "unit_valued_member_read_is_a_hit" {
    const src =
        \\
        \\class A { var u: Unit = Unit }
        \\fun main() {
        \\    with(A()) { println(u) }
        \\}
        \\
    ;
    try assertKlio("unit_member_read", src, "kotlin.Unit\n");
}
