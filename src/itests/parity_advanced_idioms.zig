//! Advanced Kotlin idioms: data class equality and hashing,
//! sequence laziness, reified generics, lateinit, contracts,
//! reflection lite, scoping edges.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_advanced_idioms";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


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

test "data_class_equality_and_copy" {
    const src =
        \\
        \\data class P(val a: Int, val b: String)
        \\fun main() {
        \\    val p1 = P(1, "x"); val p2 = P(1, "x"); val p3 = p1.copy(b = "y")
        \\    println("${p1 == p2},${p1 == p3},${p3.a},${p3.b}")
        \\}
        \\
    ;
    try assertKlio("data_eq_copy", src, "true,false,1,y\n");
}

test "result equality dispatches payload equals" {
    const src =
        \\
        \\class Token(val value: Int) {
        \\    override fun equals(other: Any?): Boolean =
        \\        other is Token && value == other.value
        \\}
        \\@JvmInline value class WrappedToken(val token: Token)
        \\fun main() {
        \\    val first = Result.success(Token(7))
        \\    val same = Result.success(Token(7))
        \\    val different = Result.success(Token(8))
        \\    val wrapped = WrappedToken(Token(7))
        \\    println("${first == same},${first == different}," +
        \\        "${wrapped == WrappedToken(Token(7))},${wrapped == WrappedToken(Token(8))}")
        \\}
        \\
    ;
    try assertKlio("result_payload_equality", src, "true,false,true,false\n");
}

test "lateinit_var_with_is_initialized" {
    const alt =
        \\
        \\class Box {
        \\    lateinit var name: String
        \\    fun ready(): Boolean = ::name.isInitialized
        \\}
        \\fun main() {
        \\    val b = Box()
        \\    val before = b.ready()
        \\    b.name = "hello"
        \\    val after = b.ready()
        \\    println("$before,$after,${b.name}")
        \\}
        \\
    ;
    try assertKlio("lateinit_init", alt, "false,true,hello\n");
}

test "sequence_lazy_evaluation" {
    const src =
        \\
        \\fun main() {
        \\    var n = 0
        \\    val s = sequenceOf(1, 2, 3, 4, 5)
        \\        .map { n += 1; it * 2 }
        \\        .filter { it > 4 }
        \\        .take(2)
        \\    val r = s.toList()
        \\    println("$r,n=$n")
        \\}
        \\
    ;
    try assertKlio("seq_lazy", src, "[6, 8],n=4\n");
}

test "elvis_chain" {
    const src =
        \\
        \\fun look(m: Map<String, String?>, k: String): String =
        \\    m[k] ?: "missing"
        \\fun main() {
        \\    val m = mapOf("a" to "A", "b" to null)
        \\    println("${look(m,"a")}|${look(m,"b")}|${look(m,"c")}")
        \\}
        \\
    ;
    try assertKlio("elvis", src, "A|missing|missing\n");
}

test "safe_call_chain" {
    const src =
        \\
        \\class A(val b: B?)
        \\class B(val c: C?)
        \\class C(val v: Int)
        \\fun main() {
        \\    val a1 = A(B(C(7)))
        \\    val a2 = A(B(null))
        \\    val a3 = A(null)
        \\    println("${a1.b?.c?.v},${a2.b?.c?.v},${a3.b?.c?.v}")
        \\}
        \\
    ;
    try assertKlio("safe_call", src, "7,null,null\n");
}

test "smart_cast_after_null_check" {
    const src =
        \\
        \\fun shout(s: String?): Int {
        \\    if (s == null) return -1
        \\    return s.length  // smart-cast to non-null String
        \\}
        \\fun main() { println("${shout("hi")},${shout(null)}") }
        \\
    ;
    try assertKlio("smart_null", src, "2,-1\n");
}

test "when_pattern_guard_via_subject" {
    const src =
        \\
        \\fun classify(n: Int): String = when {
        \\    n < 0 -> "neg"
        \\    n == 0 -> "zero"
        \\    n in 1..10 -> "small"
        \\    n in 11..100 -> "medium"
        \\    else -> "large"
        \\}
        \\fun main() {
        \\    println(listOf(-3,0,5,50,500).joinToString(",") { classify(it) })
        \\}
        \\
    ;
    try assertKlio("when_guard", src, "neg,zero,small,medium,large\n");
}

test "collection_group_by_associate" {
    const src =
        \\
        \\fun main() {
        \\    val words = listOf("alpha", "ant", "bear", "bat", "cat")
        \\    val byInitial = words.groupBy { it[0] }
        \\    val sortedKeys = byInitial.keys.sorted()
        \\    val sb = StringBuilder()
        \\    for (k in sortedKeys) {
        \\        sb.append("$k=${byInitial[k]!!.joinToString(",")};")
        \\    }
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("group_by", src, "a=alpha,ant;b=bear,bat;c=cat;\n");
}

test "flatmap_and_distinct" {
    const src =
        \\
        \\fun main() {
        \\    val xs = listOf(listOf(1,2,2), listOf(2,3,3), listOf(3,4))
        \\    val flat = xs.flatten()
        \\    val unique = flat.distinct()
        \\    println("$flat|$unique")
        \\}
        \\
    ;
    try assertKlio("flat_distinct", src, "[1, 2, 2, 2, 3, 3, 3, 4]|[1, 2, 3, 4]\n");
}

test "zip_and_unzip" {
    const src =
        \\
        \\fun main() {
        \\    val a = listOf(1,2,3,4)
        \\    val b = listOf("a","b","c")
        \\    val z = a.zip(b)
        \\    println(z.joinToString(",") { "${it.first}=${it.second}" })
        \\}
        \\
    ;
    try assertKlio("zip", src, "1=a,2=b,3=c\n");
}
