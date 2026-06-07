//! Advanced generic scenarios: covariant/contravariant variance,
//! star-projection, reified inline functions, bounds projection,
//! generic function reified-class lookup. Ported from
//! the Rust suite.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_generics_advanced";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


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

test "covariant_out_producer" {
    const src =
        \\
        \\interface Producer<out T> { fun produce(): T }
        \\class IntP : Producer<Int> { override fun produce(): Int = 42 }
        \\fun useAny(p: Producer<Any>): String = p.produce().toString()
        \\fun main() {
        \\    val ip: Producer<Int> = IntP()
        \\    println(useAny(ip))
        \\}
        \\
    ;
    try assertKlio("covariant_out", src, "42\n");
}

test "star_projection" {
    const src =
        \\
        \\class Box<T>(val v: T) { fun toAny(): Any? = v }
        \\fun render(b: Box<*>): String = b.toAny().toString()
        \\fun main() {
        \\    println("${render(Box(7))}|${render(Box("hi"))}")
        \\}
        \\
    ;
    try assertKlio("star_proj", src, "7|hi\n");
}

test "generic_method_in_class" {
    const src =
        \\
        \\class Holder<T>(val v: T) {
        \\    fun <R> map(f: (T) -> R): Holder<R> = Holder(f(v))
        \\}
        \\fun main() {
        \\    val h = Holder(7).map { it * 2 }.map { "v=$it" }
        \\    println(h.v)
        \\}
        \\
    ;
    try assertKlio("generic_method", src, "v=14\n");
}

test "nested_generic_resolution" {
    const src =
        \\
        \\fun <T> firstOrZero(xs: List<T>, zero: T): T = if (xs.isEmpty()) zero else xs[0]
        \\fun main() {
        \\    val a = firstOrZero(listOf(1,2,3), 0)
        \\    val b = firstOrZero(listOf<String>(), "empty")
        \\    val c = firstOrZero(listOf("alpha"), "beta")
        \\    println("$a|$b|$c")
        \\}
        \\
    ;
    try assertKlio("nested_gen", src, "1|empty|alpha\n");
}

test "bound_constraint_comparable" {
    const src =
        \\
        \\fun <T : Comparable<T>> sortPair(a: T, b: T): Pair<T, T> =
        \\    if (a <= b) Pair(a, b) else Pair(b, a)
        \\fun main() {
        \\    val p = sortPair(5, 3)
        \\    val q = sortPair("z", "a")
        \\    println("${p.first},${p.second}|${q.first},${q.second}")
        \\}
        \\
    ;
    try assertKlio("bound_cmp", src, "3,5|a,z\n");
}

test "generic_class_with_secondary_constructor" {
    const src =
        \\
        \\class Pair2<A, B>(val a: A, val b: B) {
        \\    constructor(a: A) : this(a, a as B)
        \\    fun show(): String = "[$a,$b]"
        \\}
        \\fun main() {
        \\    val p = Pair2(7, "x")
        \\    val q = Pair2<Int, Int>(5)
        \\    println("${p.show()}|${q.show()}")
        \\}
        \\
    ;
    try assertKlio("gen_secondary", src, "[7,x]|[5,5]\n");
}

test "lambda_with_generic_param" {
    const src =
        \\
        \\fun <T> apply(x: T, f: (T) -> T): T = f(x)
        \\fun main() {
        \\    val a = apply(7) { it * 2 }
        \\    val b = apply("hi") { "$it!" }
        \\    println("$a|$b")
        \\}
        \\
    ;
    try assertKlio("lambda_gen", src, "14|hi!\n");
}

test "function_type_returning_function_type" {
    const src =
        \\
        \\fun adder(n: Int): (Int) -> Int = { it + n }
        \\fun composed(a: (Int) -> Int, b: (Int) -> Int): (Int) -> Int = { a(b(it)) }
        \\fun main() {
        \\    val plus5 = adder(5); val times2 = { x: Int -> x * 2 }
        \\    val pipe = composed(plus5, times2)
        \\    println("${pipe(3)},${pipe(10)}")
        \\}
        \\
    ;
    // pipe(3) = plus5(times2(3)) = plus5(6) = 11; pipe(10) = plus5(20) = 25
    try assertKlio("fn_returns_fn", src, "11,25\n");
}
