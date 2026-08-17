//! Null safety, smart casts after null checks, type-erased nullable
//! receivers, elvis returns, !! assertion.
const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_nullability_deep";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


/// Run `src` through the in-process klio pipeline and assert stdout equals
/// `expected`: write the embedded source to a unique temp `.kt`, then
/// `runWithPacks`.
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

test "double_bang_throws_npe" {
    const src =
        \\
        \\fun main() {
        \\    val s: String? = null
        \\    try { val r = s!!; println(r) }
        \\    catch (e: NullPointerException) { println("npe") }
        \\}
        \\
    ;
    try assertKlio("double_bang", src, "npe\n");
}

test "elvis_with_early_return" {
    const src =
        \\
        \\fun lookup(m: Map<String, Int>, k: String): String {
        \\    val v = m[k] ?: return "missing"
        \\    return "found=$v"
        \\}
        \\fun main() {
        \\    val m = mapOf("a" to 1)
        \\    println("${lookup(m, "a")}|${lookup(m, "b")}")
        \\}
        \\
    ;
    try assertKlio("elvis_return", src, "found=1|missing\n");
}

test "nullable_chain_let_and_take_if" {
    const src =
        \\
        \\fun classify(n: Int?): String =
        \\    n?.takeIf { it > 0 }?.let { "+$it" } ?: "n/a"
        \\fun main() {
        \\    println("${classify(5)}|${classify(0)}|${classify(null)}")
        \\}
        \\
    ;
    try assertKlio("nullable_let_takeIf", src, "+5|n/a|n/a\n");
}

test "null_safe_through_collection" {
    const src =
        \\
        \\fun main() {
        \\    val xs: List<String?> = listOf("a", null, "b", null, "c")
        \\    val nn = xs.filterNotNull()
        \\    val rendered = xs.joinToString(",") { it ?: "<n>" }
        \\    println("$nn|$rendered")
        \\}
        \\
    ;
    try assertKlio("filterNotNull", src, "[a, b, c]|a,<n>,b,<n>,c\n");
}

test "nullable_receiver_extension" {
    const src =
        \\
        \\fun String?.orPlaceholder(): String = this ?: "<null>"
        \\fun main() {
        \\    val a: String? = "kotlin"; val b: String? = null
        \\    println("${a.orPlaceholder()}|${b.orPlaceholder()}")
        \\}
        \\
    ;
    try assertKlio("nullable_ext", src, "kotlin|<null>\n");
}

test "safe_cast_through_when" {
    const src =
        \\
        \\fun describe(x: Any?): String = when (x) {
        \\    is String -> "S:$x"
        \\    is Int -> "I:$x"
        \\    null -> "null"
        \\    else -> "?"
        \\}
        \\fun main() {
        \\    println(listOf<Any?>("hi", 5, null, 3.14).joinToString(",") { describe(it) })
        \\}
        \\
    ;
    try assertKlio("smart_when", src, "S:hi,I:5,null,?\n");
}

test "null_safe_index_access" {
    const src =
        \\
        \\fun main() {
        \\    val m: Map<String, List<Int>?> = mapOf("a" to listOf(1,2,3), "b" to null)
        \\    val a = m["a"]?.get(1)
        \\    val b = m["b"]?.get(0)
        \\    val c = m["c"]?.get(0)
        \\    println("$a,$b,$c")
        \\}
        \\
    ;
    try assertKlio("null_index", src, "2,null,null\n");
}

test "lateinit_var_uninitialized_check" {
    const src =
        \\
        \\class Box {
        \\    lateinit var s: String
        \\    fun maybeSet(set: Boolean) { if (set) s = "ok" }
        \\    fun get(): String = if (::s.isInitialized) s else "uninit"
        \\}
        \\fun main() {
        \\    val a = Box(); val b = Box()
        \\    a.maybeSet(true); b.maybeSet(false)
        \\    println("${a.get()}|${b.get()}")
        \\}
        \\
    ;
    try assertKlio("lateinit_check", src, "ok|uninit\n");
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
