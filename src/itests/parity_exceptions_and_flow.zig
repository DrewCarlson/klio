//! Exception handling, finally semantics, multi-catch, rethrow,
//! try-as-expression, and exception inside lambda capture.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_exceptions_and_flow";

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

test "try_finally_runs_on_normal_path" {
    const src =
        \\
        \\fun main() {
        \\    val sb = StringBuilder()
        \\    try { sb.append("body;") } finally { sb.append("fin;") }
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("try_fin_normal", src, "body;fin;\n");
}

test "try_finally_runs_on_exception" {
    const src =
        \\
        \\fun main() {
        \\    val sb = StringBuilder()
        \\    try {
        \\        try { throw RuntimeException("e"); sb.append("nope;") }
        \\        finally { sb.append("fin;") }
        \\    } catch (e: RuntimeException) { sb.append("caught:${e.message};") }
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("try_fin_throw", src, "fin;caught:e;\n");
}

test "rethrow_in_catch_propagates" {
    const src =
        \\
        \\class A : RuntimeException("a")
        \\class B : RuntimeException("b")
        \\fun probe() {
        \\    try { throw A() } catch (e: A) { throw B() }
        \\}
        \\fun main() {
        \\    try { probe() } catch (e: B) { println("got B:${e.message}") }
        \\}
        \\
    ;
    try assertKlio("rethrow", src, "got B:b\n");
}

test "try_as_expression_yields_value" {
    const src =
        \\
        \\fun parse(s: String): Int = try { s.toInt() } catch (e: NumberFormatException) { -1 }
        \\fun main() {
        \\    println("${parse("42")},${parse("nope")}")
        \\}
        \\
    ;
    try assertKlio("try_expr", src, "42,-1\n");
}

test "exception_through_lambda_boundary" {
    const src =
        \\
        \\fun runWith(f: () -> Int): Int {
        \\    return try { f() } catch (e: IllegalStateException) { -1 }
        \\}
        \\fun main() {
        \\    val r = runWith { throw IllegalStateException("bad") }
        \\    println(r)
        \\}
        \\
    ;
    try assertKlio("ex_lambda", src, "-1\n");
}

test "nested_try_inner_catches_outer_doesnt" {
    const src =
        \\
        \\fun main() {
        \\    val sb = StringBuilder()
        \\    try {
        \\        try { throw RuntimeException("e1") }
        \\        catch (e: RuntimeException) { sb.append("inner:${e.message};") }
        \\    } catch (e: RuntimeException) { sb.append("outer:${e.message};") }
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("nested_try", src, "inner:e1;\n");
}

test "finally_overrides_value_if_returns" {
    const src =
        \\
        \\fun f(): Int {
        \\    try { return 1 } finally { return 2 }
        \\}
        \\fun main() { println(f()) }
        \\
    ;
    try assertKlio("fin_override", src, "2\n");
}

test "catch_hierarchy_first_match_wins" {
    const src =
        \\
        \\fun probe(): String = try {
        \\    throw IllegalStateException("x")
        \\} catch (e: IllegalArgumentException) { "arg" }
        \\  catch (e: IllegalStateException) { "state" }
        \\  catch (e: RuntimeException) { "runtime" }
        \\fun main() { println(probe()) }
        \\
    ;
    try assertKlio("catch_hierarchy", src, "state\n");
}

test "exception_inside_init_block_propagates" {
    const src =
        \\
        \\class Bad(v: Int) {
        \\    init { if (v < 0) throw IllegalArgumentException("neg") }
        \\}
        \\fun main() {
        \\    try { Bad(-1) } catch (e: IllegalArgumentException) { println("caught:${e.message}") }
        \\}
        \\
    ;
    try assertKlio("ex_in_init", src, "caught:neg\n");
}

test "check_require_helpers" {
    const src =
        \\
        \\fun safeDiv(a: Int, b: Int): Int {
        \\    require(b != 0) { "divide by zero" }
        \\    return a / b
        \\}
        \\fun main() {
        \\    try { safeDiv(6, 0) } catch (e: IllegalArgumentException) { println(e.message) }
        \\    println(safeDiv(10, 2))
        \\}
        \\
    ;
    try assertKlio("require", src, "divide by zero\n5\n");
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
