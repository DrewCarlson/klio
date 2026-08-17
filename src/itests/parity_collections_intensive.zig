//! Collections-intensive parity: chain operations, fold variants,
//! windowed iteration, partitioning, sortedBy variants; iterable special
//! operations (zipWithNext, scan, take/drop families, indexOfFirst,
//! groupBy, distinctBy, aggregates); map manipulation (iteration,
//! mutation, key/value views, mapValues, filterKeys/filterValues,
//! getOrPut, entries destructuring).
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

test "map_iteration_ordered" {
    const src =
        \\
        \\fun main() {
        \\    val m = mapOf("a" to 1, "b" to 2, "c" to 3)
        \\    val sb = StringBuilder()
        \\    for ((k, v) in m) sb.append("$k=$v;")
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("map_iter", src, "a=1;b=2;c=3;\n");
}

test "map_filter_keys_values" {
    const src =
        \\
        \\fun main() {
        \\    val m = mapOf("a" to 1, "b" to 2, "c" to 3, "d" to 4)
        \\    val keyFilt = m.filterKeys { it > "b" }
        \\    val valFilt = m.filterValues { it % 2 == 0 }
        \\    println("$keyFilt|$valFilt")
        \\}
        \\
    ;
    try assertKlio("map_filter", src, "{c=3, d=4}|{b=2, d=4}\n");
}

test "map_map_values_chain" {
    const src =
        \\
        \\fun main() {
        \\    val m = mapOf("x" to 1, "y" to 2, "z" to 3)
        \\    val squared = m.mapValues { it.value * it.value }
        \\    println(squared)
        \\}
        \\
    ;
    try assertKlio("map_values", src, "{x=1, y=4, z=9}\n");
}

test "mutable_map_get_or_put" {
    const src =
        \\
        \\fun main() {
        \\    val cache = mutableMapOf<String, Int>()
        \\    val a = cache.getOrPut("k") { 10 }
        \\    val b = cache.getOrPut("k") { 99 }  // already there, lambda not invoked
        \\    println("$a,$b,${cache.size}")
        \\}
        \\
    ;
    try assertKlio("getOrPut", src, "10,10,1\n");
}

test "map_to_list_and_pairs" {
    const src =
        \\
        \\fun main() {
        \\    val m = mapOf("a" to 1, "b" to 2)
        \\    val pairs = m.toList()
        \\    val joined = pairs.joinToString(",") { "${it.first}=${it.second}" }
        \\    println(joined)
        \\}
        \\
    ;
    try assertKlio("map_to_list", src, "a=1,b=2\n");
}

test "map_entries_destructuring" {
    const src =
        \\
        \\fun main() {
        \\    val m = mapOf("a" to 1, "b" to 2, "c" to 3)
        \\    val sb = StringBuilder()
        \\    for ((k, v) in m.entries) sb.append("$k:$v ")
        \\    println(sb.toString().trim())
        \\}
        \\
    ;
    try assertKlio("entries_dest", src, "a:1 b:2 c:3\n");
}

test "map_plus_minus_operators" {
    const src =
        \\
        \\fun main() {
        \\    val a = mapOf("x" to 1, "y" to 2)
        \\    val b = a + ("z" to 3)
        \\    val c = b - "x"
        \\    println("$a|$b|$c")
        \\}
        \\
    ;
    try assertKlio("map_plus_minus", src, "{x=1, y=2}|{x=1, y=2, z=3}|{y=2, z=3}\n");
}

test "map_count_and_any" {
    const src =
        \\
        \\fun main() {
        \\    val m = mapOf("a" to 1, "b" to 2, "c" to 3, "d" to 4)
        \\    val evens = m.count { (_, v) -> v % 2 == 0 }
        \\    val anyHigh = m.any { (_, v) -> v > 3 }
        \\    val allPositive = m.all { (_, v) -> v > 0 }
        \\    println("$evens,$anyHigh,$allPositive")
        \\}
        \\
    ;
    try assertKlio("map_count_any", src, "2,true,true\n");
}
