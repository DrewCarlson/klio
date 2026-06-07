//! Collections-intensive parity: chain operations, fold variants,
//! windowed iteration, partitioning, sortedBy variants.
//!
//! Port of the Rust suite.
const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_collections_intensive";

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

test "fold_and_reduce" {
    const src =
        \\
        \\fun main() {
        \\    val xs = listOf(1,2,3,4,5)
        \\    val f = xs.fold(100) { acc, x -> acc + x }
        \\    val r = xs.reduce { acc, x -> acc * x }
        \\    println("$f|$r")
        \\}
        \\
    ;
    try assertKlio("fold_red", src, "115|120\n");
}

test "associate_associate_by_associate_with" {
    const src =
        \\
        \\fun main() {
        \\    val xs = listOf("ant", "bee", "cat")
        \\    val ab = xs.associateBy { it[0] }
        \\    val aw = xs.associateWith { it.length }
        \\    val keys = ab.keys.sorted()
        \\    val sb = StringBuilder()
        \\    for (k in keys) sb.append("$k=${ab[k]};")
        \\    sb.append("|")
        \\    val keys2 = aw.keys.sorted()
        \\    for (k in keys2) sb.append("$k=${aw[k]};")
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("assoc", src, "a=ant;b=bee;c=cat;|ant=3;bee=3;cat=3;\n");
}

test "partition_into_two_lists" {
    const src =
        \\
        \\fun main() {
        \\    val (evens, odds) = (1..10).partition { it % 2 == 0 }
        \\    println("$evens|$odds")
        \\}
        \\
    ;
    try assertKlio("partition", src, "[2, 4, 6, 8, 10]|[1, 3, 5, 7, 9]\n");
}

test "windowed_and_chunked" {
    const src =
        \\
        \\fun main() {
        \\    val xs = (1..6).toList()
        \\    val w = xs.windowed(3)
        \\    val c = xs.chunked(2)
        \\    println("$w|$c")
        \\}
        \\
    ;
    try assertKlio(
        "win_chunked",
        src,
        "[[1, 2, 3], [2, 3, 4], [3, 4, 5], [4, 5, 6]]|[[1, 2], [3, 4], [5, 6]]\n",
    );
}

test "sorted_by_descending" {
    const src =
        \\
        \\fun main() {
        \\    data class P(val name: String, val age: Int)
        \\    val xs = listOf(P("Bob", 35), P("Ann", 22), P("Cal", 40))
        \\    val byAge = xs.sortedBy { it.age }
        \\    val byAgeDesc = xs.sortedByDescending { it.age }
        \\    println(byAge.joinToString(",") { it.name })
        \\    println(byAgeDesc.joinToString(",") { it.name })
        \\}
        \\
    ;
    try assertKlio("sortedBy", src, "Ann,Bob,Cal\nCal,Bob,Ann\n");
}

test "map_get_or_default" {
    const src =
        \\
        \\fun main() {
        \\    val m = mapOf("a" to 1, "b" to 2)
        \\    val a = m.getOrDefault("a", -1)
        \\    val z = m.getOrDefault("z", -1)
        \\    val ek = m.getOrElse("c") { 999 }
        \\    println("$a|$z|$ek")
        \\}
        \\
    ;
    try assertKlio("map_get_or", src, "1|-1|999\n");
}

test "mutable_collection_operations" {
    const src =
        \\
        \\fun main() {
        \\    val xs = mutableListOf(3,1,4,1,5,9,2,6)
        \\    xs.sort()
        \\    val unique = xs.toSet().toList()
        \\    println("$xs|$unique")
        \\}
        \\
    ;
    try assertKlio(
        "mut_ops",
        src,
        "[1, 1, 2, 3, 4, 5, 6, 9]|[1, 2, 3, 4, 5, 6, 9]\n",
    );
}

test "max_by_min_by_by_key" {
    const src =
        \\
        \\fun main() {
        \\    val xs = listOf("ant", "elephant", "bear", "wolf")
        \\    val longest = xs.maxByOrNull { it.length }
        \\    val shortest = xs.minByOrNull { it.length }
        \\    println("$longest|$shortest")
        \\}
        \\
    ;
    try assertKlio("max_min_by", src, "elephant|ant\n");
}

test "map_filter_chain" {
    const src =
        \\
        \\fun main() {
        \\    val xs = (1..20)
        \\        .map { it * it }
        \\        .filter { it % 2 == 0 }
        \\        .take(4)
        \\    println(xs)
        \\}
        \\
    ;
    try assertKlio("chain", src, "[4, 16, 36, 64]\n");
}
