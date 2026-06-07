//! Map manipulation: iteration, mutation, key/value views, mapValues,
//! filterKeys/filterValues, getOrPut, entries destructuring.
//!
//! Port of the Rust suite.
const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_maps_intensive";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


/// Run `src` through the in-process klio pipeline and assert stdout equals
/// `expected`. Mirrors the Rust `assert_klio`: write the embedded source to a
/// unique temp `.kt`, then `run_with_packs`.
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
