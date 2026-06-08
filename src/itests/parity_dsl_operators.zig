//! DSL and operator coverage: infix, operator overloads, builder
//! receiver chains, invoke convention, get/set conventions.
//!
//! Port of the Rust suite.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_dsl_operators";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


/// Write `src` to a unique temp `.kt` path, run it through the in-process
/// klio pipeline, and assert stdout equals `expected`. Uses a per-call arena
/// over the page allocator so the leak-checking test allocator never drives
/// the pipeline (which would abort on its intentional arena lifetimes).
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

test "infix_function_chain" {
    const src =
        \\
        \\infix fun Int.times(s: String): String = (1..this).joinToString("") { s }
        \\fun main() {
        \\    val r = 3 times "ab"
        \\    println(r)
        \\}
        \\
    ;
    try assertKlio("infix", src, "ababab\n");
}

test "operator_get_set_index" {
    const src =
        \\
        \\class Grid(val w: Int, val h: Int) {
        \\    private val data = IntArray(w * h)
        \\    operator fun get(x: Int, y: Int): Int = data[y * w + x]
        \\    operator fun set(x: Int, y: Int, v: Int) { data[y * w + x] = v }
        \\}
        \\fun main() {
        \\    val g = Grid(3, 2)
        \\    g[0,0] = 1; g[2,1] = 99
        \\    println("${g[0,0]},${g[2,1]},${g[1,0]}")
        \\}
        \\
    ;
    try assertKlio("get_set", src, "1,99,0\n");
}

test "operator_arithmetic_overload" {
    const src =
        \\
        \\data class V(val x: Int, val y: Int) {
        \\    operator fun plus(o: V) = V(x+o.x, y+o.y)
        \\    operator fun minus(o: V) = V(x-o.x, y-o.y)
        \\    operator fun times(k: Int) = V(x*k, y*k)
        \\    operator fun unaryMinus() = V(-x, -y)
        \\}
        \\fun main() {
        \\    val a = V(1,2); val b = V(3,4)
        \\    val sum = a + b
        \\    val diff = b - a
        \\    val scaled = a * 3
        \\    val neg = -a
        \\    println("${sum.x},${sum.y};${diff.x},${diff.y};${scaled.x},${scaled.y};${neg.x},${neg.y}")
        \\}
        \\
    ;
    try assertKlio("arith_ops", src, "4,6;2,2;3,6;-1,-2\n");
}

test "operator_compare_overload" {
    const src =
        \\
        \\class Money(val cents: Int) : Comparable<Money> {
        \\    override fun compareTo(other: Money): Int = cents - other.cents
        \\}
        \\fun main() {
        \\    val a = Money(100); val b = Money(250); val c = Money(100)
        \\    println("${a < b},${a == c},${a <= c},${b > a}")
        \\}
        \\
    ;
    // a == c uses structural equality (default object equality) — NOT cents-equal.
    try assertKlio("compare", src, "true,false,true,true\n");
}

test "invoke_convention_function_like" {
    const src =
        \\
        \\class Multi(val k: Int) {
        \\    operator fun invoke(x: Int): Int = x * k
        \\}
        \\fun main() {
        \\    val m = Multi(3)
        \\    println("${m(4)},${m(10)}")
        \\}
        \\
    ;
    try assertKlio("invoke", src, "12,30\n");
}

test "dsl_html_like_builder" {
    const src =
        \\
        \\class Tag(val name: String) {
        \\    private val children = mutableListOf<Tag>()
        \\    private val text = StringBuilder()
        \\    fun add(t: Tag) { children.add(t) }
        \\    fun text(s: String) { text.append(s) }
        \\    fun render(): String {
        \\        val sb = StringBuilder("<").append(name).append(">")
        \\        sb.append(text)
        \\        for (c in children) sb.append(c.render())
        \\        sb.append("</").append(name).append(">")
        \\        return sb.toString()
        \\    }
        \\}
        \\fun tag(name: String, build: Tag.() -> Unit): Tag {
        \\    val t = Tag(name); t.build(); return t
        \\}
        \\fun main() {
        \\    val r = tag("div") {
        \\        text("hello ")
        \\        add(tag("b") { text("world") })
        \\    }
        \\    println(r.render())
        \\}
        \\
    ;
    try assertKlio("dsl_html", src, "<div>hello <b>world</b></div>\n");
}

test "range_to_in_range" {
    // Custom user-Iterable through the new Iterable-extension
    // dispatch fallback. Uses a dedicated iterator class so all
    // state lives in primary-ctor fields and the dispatch is
    // exercised without depending on anonymous-object capture
    // semantics that earlier tracked tasks cover.
    const src =
        \\
        \\class IntIter(var cur: Int, val end: Int) : Iterator<Int> {
        \\    override fun hasNext(): Boolean = cur <= end
        \\    override fun next(): Int { val v = cur; cur += 1; return v }
        \\}
        \\class Counter(val from: Int, val to: Int) : Iterable<Int> {
        \\    override fun iterator(): Iterator<Int> = IntIter(from, to)
        \\}
        \\fun main() {
        \\    val r = Counter(1, 3)
        \\    println(r.joinToString(",") { it.toString() })
        \\}
        \\
    ;
    try assertKlio("counter_join", src, "1,2,3\n");
}

test "plus_assign_operator" {
    const src =
        \\
        \\class Counter {
        \\    var n: Int = 0
        \\    operator fun plusAssign(k: Int) { n += k }
        \\}
        \\fun main() {
        \\    val c = Counter()
        \\    c += 5; c += 3
        \\    println(c.n)
        \\}
        \\
    ;
    try assertKlio("plus_assign", src, "8\n");
}

test "iterator_convention_for_loop" {
    const src =
        \\
        \\class Counter(val max: Int) {
        \\    operator fun iterator(): Iterator<Int> = object : Iterator<Int> {
        \\        var cur = 0
        \\        override fun hasNext(): Boolean = cur < max
        \\        override fun next(): Int { cur += 1; return cur }
        \\    }
        \\}
        \\fun main() {
        \\    val c = Counter(4)
        \\    val sb = StringBuilder()
        \\    for (x in c) sb.append("$x,")
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("iter_convention", src, "1,2,3,4,\n");
}

test "component_n_destructuring" {
    const src =
        \\
        \\class Triple3(val a: Int, val b: Int, val c: Int) {
        \\    operator fun component1(): Int = a
        \\    operator fun component2(): Int = b
        \\    operator fun component3(): Int = c
        \\}
        \\fun main() {
        \\    val (x, y, z) = Triple3(7, 8, 9)
        \\    println("$x,$y,$z")
        \\}
        \\
    ;
    try assertKlio("componentN", src, "7,8,9\n");
}
