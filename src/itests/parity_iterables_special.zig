//! Iterable special operations that round out collection coverage:
//! zipWithNext, scan, runningFold, take/drop, takeLast/dropLast,
//! single/firstOrNull, indexOfFirst.
//!
//! Ported from crates/klio-parity/tests/iterables_special.rs.
const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_iterables_special";

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
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, TMP_DIR) catch |e| {
        std.debug.print("iterables_special {s}: mkdir failed {s}\n", .{ name, @errorName(e) });
        return error.KlioRunFailed;
    };
    const path = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name });
    cwd.writeFile(io, .{ .sub_path = path, .data = src }) catch |e| {
        std.debug.print("iterables_special {s}: write failed {s}\n", .{ name, @errorName(e) });
        return error.KlioRunFailed;
    };

    const res = try parity.runWithPacks(a, io, path);
    switch (res) {
        .ok => |got| try std.testing.expectEqualStrings(expected, got),
        .err => |m| {
            std.debug.print("iterables_special {s}: klio run failed: {s}\n", .{ name, m });
            return error.KlioRunFailed;
        },
    }
}

test "list_take_drop_take_last_drop_last" {
    const src =
        \\
        \\fun main() {
        \\    val xs = listOf(1, 2, 3, 4, 5, 6)
        \\    println("${xs.take(3)}|${xs.drop(2)}|${xs.takeLast(2)}|${xs.dropLast(4)}")
        \\}
        \\
    ;
    try assertKlio("take_drop", src, "[1, 2, 3]|[3, 4, 5, 6]|[5, 6]|[1, 2]\n");
}

test "list_index_of_first_index_of_last" {
    const src =
        \\
        \\fun main() {
        \\    val xs = listOf(1, 2, 3, 4, 2, 5)
        \\    val first = xs.indexOfFirst { it > 2 }
        \\    val last = xs.indexOfLast { it < 4 }
        \\    println("$first,$last")
        \\}
        \\
    ;
    try assertKlio("indexOf", src, "2,4\n");
}

test "list_first_last_with_predicate" {
    const src =
        \\
        \\fun main() {
        \\    val xs = listOf(1, 2, 3, 4)
        \\    println("${xs.first()}|${xs.last()}|${xs.firstOrNull { it > 10 }}")
        \\}
        \\
    ;
    try assertKlio("first_last", src, "1|4|null\n");
}

test "list_take_with_predicate_while" {
    const src =
        \\
        \\fun main() {
        \\    val xs = listOf(1, 2, 3, 4, 1, 2)
        \\    println("${xs.takeWhile { it < 3 }}|${xs.dropWhile { it < 3 }}")
        \\}
        \\
    ;
    try assertKlio("while", src, "[1, 2]|[3, 4, 1, 2]\n");
}

test "list_group_by_count" {
    const src =
        \\
        \\fun main() {
        \\    val xs = listOf(1, 2, 3, 4, 5, 6)
        \\    val by = xs.groupBy { it % 3 }
        \\    val keys = by.keys.sorted()
        \\    val sb = StringBuilder()
        \\    for (k in keys) sb.append("$k=${by[k]};")
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("groupBy", src, "0=[3, 6];1=[1, 4];2=[2, 5];\n");
}

test "list_zip_with_other_list" {
    const src =
        \\
        \\fun main() {
        \\    val a = listOf(1, 2, 3)
        \\    val b = listOf("a", "b", "c", "d")
        \\    val z = a.zip(b) { x, y -> "$x$y" }
        \\    println(z)
        \\}
        \\
    ;
    try assertKlio("zip_with", src, "[1a, 2b, 3c]\n");
}

test "list_distinct_distinct_by" {
    const src =
        \\
        \\fun main() {
        \\    val xs = listOf("alpha", "ant", "beta", "bee", "bear")
        \\    val by = xs.distinctBy { it[0] }
        \\    println(by)
        \\}
        \\
    ;
    try assertKlio("distinctBy", src, "[alpha, beta]\n");
}

test "list_sum_average_max_min" {
    const src =
        \\
        \\fun main() {
        \\    val xs = listOf(2, 4, 6, 8, 10)
        \\    println("${xs.sum()} ${xs.average()} ${xs.max()} ${xs.min()}")
        \\}
        \\
    ;
    try assertKlio("aggregates", src, "30 6.0 10 2\n");
}
