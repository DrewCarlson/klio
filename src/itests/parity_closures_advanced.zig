//! Advanced closure patterns: mutual captures, scope-fn chaining
//! with `this` reassignment, lambdas stored and invoked later,
//! enclosed-by-loop iteration variables.
const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_closures_advanced";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


/// Write `src` to a unique temp `.kt` file, run it through klio with the
/// kotlinx packs loaded, and assert the captured stdout equals `expected`.
/// An arena over the page allocator is used per test so the leak-checking
/// test allocator never drives the pipeline.
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

test "lambdas_stored_and_invoked_later" {
    const src =
        \\
        \\fun main() {
        \\    val tasks = mutableListOf<() -> String>()
        \\    for (i in 1..3) {
        \\        val captured = i
        \\        tasks.add { "t$captured" }
        \\    }
        \\    println(tasks.joinToString(",") { it() })
        \\}
        \\
    ;
    try assertKlio("stored_lambdas", src, "t1,t2,t3\n");
}

test "closure_chains_apply_let_run_with" {
    const src =
        \\
        \\fun main() {
        \\    val result = StringBuilder()
        \\        .apply { append("a") }
        \\        .let { it.append("b") }
        \\        .run { append("c"); toString() }
        \\    println(result)
        \\}
        \\
    ;
    try assertKlio("scope_chain", src, "abc\n");
}

test "closure_capturing_class_property" {
    const src =
        \\
        \\class P(val name: String) {
        \\    fun greeter(): () -> String = { "hello $name" }
        \\}
        \\fun main() {
        \\    val g = P("kotlin").greeter()
        \\    println(g())
        \\}
        \\
    ;
    try assertKlio("capture_prop", src, "hello kotlin\n");
}

test "nested_closures_share_outer_mutable" {
    const src =
        \\
        \\fun main() {
        \\    var counter = 0
        \\    val incr = { counter += 1 }
        \\    val read = { counter }
        \\    incr(); incr(); incr()
        \\    println(read())
        \\}
        \\
    ;
    try assertKlio("share_outer", src, "3\n");
}

test "lambda_in_init_block_captures_init_local" {
    const src =
        \\
        \\class Box {
        \\    val getter: () -> Int
        \\    init {
        \\        val v = 42
        \\        getter = { v }
        \\    }
        \\}
        \\fun main() {
        \\    println(Box().getter())
        \\}
        \\
    ;
    try assertKlio("init_lambda", src, "42\n");
}

test "fold_with_mutating_accumulator" {
    const src =
        \\
        \\fun main() {
        \\    val r = listOf(1, 2, 3, 4, 5).fold(StringBuilder()) { acc, x ->
        \\        acc.append(x); acc
        \\    }
        \\    println(r)
        \\}
        \\
    ;
    try assertKlio("fold_acc", src, "12345\n");
}

test "nested_let_destructure_pair" {
    const src =
        \\
        \\fun main() {
        \\    val r = Pair(3, 4).let { (a, b) -> a * b }
        \\    println(r)
        \\}
        \\
    ;
    try assertKlio("let_dest", src, "12\n");
}
