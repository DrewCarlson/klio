//! Functional-style patterns: pipelines, immutable builders, Option-
//! like Result handling, recursive structures. Ported from
//! the Rust suite.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_functional_patterns";

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

test "result_run_catching_chain" {
    const src =
        \\
        \\fun parse(s: String): Result<Int> = runCatching { s.toInt() }
        \\fun main() {
        \\    val a = parse("42").getOrDefault(-1)
        \\    val b = parse("nope").getOrDefault(-1)
        \\    val c = parse("7").map { it * 10 }.getOrDefault(0)
        \\    println("$a,$b,$c")
        \\}
        \\
    ;
    try assertKlio("result_chain", src, "42,-1,70\n");
}

test "collection_pipeline_long" {
    const src =
        \\
        \\fun main() {
        \\    val r = (1..20)
        \\        .filter { it % 2 == 0 }
        \\        .map { it * it }
        \\        .filter { it > 20 }
        \\        .take(3)
        \\        .sum()
        \\    println(r)
        \\}
        \\
    ;
    // 36 + 64 + 100 = 200
    try assertKlio("pipeline", src, "200\n");
}

test "nullable_chain_safe_let" {
    const src =
        \\
        \\class Node(val v: Int, val next: Node? = null)
        \\fun main() {
        \\    val n = Node(1, Node(2, Node(3)))
        \\    val third = n.next?.next?.v
        \\    val fifth = n.next?.next?.next?.next?.v
        \\    println("${third ?: -1},${fifth ?: -1}")
        \\}
        \\
    ;
    try assertKlio("nullable_safe", src, "3,-1\n");
}

test "recursive_list_sum" {
    const src =
        \\
        \\fun sumRec(xs: List<Int>): Int =
        \\    if (xs.isEmpty()) 0 else xs.first() + sumRec(xs.drop(1))
        \\fun main() {
        \\    println(sumRec(listOf(1, 2, 3, 4, 5)))
        \\}
        \\
    ;
    try assertKlio("recursive_sum", src, "15\n");
}

test "immutable_record_update" {
    const src =
        \\
        \\data class State(val counter: Int, val log: List<String>)
        \\fun tick(s: State, msg: String): State =
        \\    s.copy(counter = s.counter + 1, log = s.log + msg)
        \\fun main() {
        \\    var s = State(0, emptyList())
        \\    s = tick(s, "a")
        \\    s = tick(s, "b")
        \\    s = tick(s, "c")
        \\    println("${s.counter}|${s.log.joinToString(",")}")
        \\}
        \\
    ;
    try assertKlio("record_update", src, "3|a,b,c\n");
}

test "currying_via_lambda_chain" {
    const src =
        \\
        \\fun main() {
        \\    val add: (Int) -> (Int) -> Int = { a -> { b -> a + b } }
        \\    val plus5 = add(5)
        \\    println("${plus5(3)},${plus5(10)},${add(2)(8)}")
        \\}
        \\
    ;
    try assertKlio("curry", src, "8,15,10\n");
}

test "either_via_sealed_class" {
    const src =
        \\
        \\sealed class Either<out A, out B> {
        \\    data class Left<A>(val v: A) : Either<A, Nothing>()
        \\    data class Right<B>(val v: B) : Either<Nothing, B>()
        \\}
        \\fun divide(a: Int, b: Int): Either<String, Int> =
        \\    if (b == 0) Either.Left("zero") else Either.Right(a / b)
        \\fun main() {
        \\    val xs = listOf(Pair(10, 2), Pair(5, 0), Pair(8, 4))
        \\    val out = xs.joinToString(",") { (a, b) ->
        \\        when (val r = divide(a, b)) {
        \\            is Either.Left -> "err:${r.v}"
        \\            is Either.Right -> "ok:${r.v}"
        \\        }
        \\    }
        \\    println(out)
        \\}
        \\
    ;
    try assertKlio("either", src, "ok:5,err:zero,ok:2\n");
}

test "auto_closeable_use_block_invokes_close" {
    const src =
        \\
        \\class Resource(val name: String) : AutoCloseable {
        \\    var closed = false
        \\    override fun close() { closed = true }
        \\}
        \\fun main() {
        \\    val r = Resource("A")
        \\    val n = r.use { it.name.length }
        \\    println("n=$n,closed=${r.closed}")
        \\}
        \\
    ;
    try assertKlio("autoclose_use", src, "n=1,closed=true\n");
}
