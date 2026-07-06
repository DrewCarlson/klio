//! Ranges, arrays, progressions, and primitive array specializations.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_ranges_arrays";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


/// Write `src` to a unique temp `.kt` path, run it through the klio pipeline,
/// and assert stdout equals `expected`. Uses an arena per test so the
/// leak-checking test allocator never drives the pipeline.
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

test "int_array_init_pattern" {
    const src =
        \\
        \\fun main() {
        \\    val xs = IntArray(5) { it * it }
        \\    println(xs.joinToString(","))
        \\}
        \\
    ;
    try assertKlio("intArray_init", src, "0,1,4,9,16\n");
}

test "array_of_primitives_sum" {
    const src =
        \\
        \\fun main() {
        \\    val xs = intArrayOf(3,1,4,1,5,9,2,6)
        \\    println("sum=${xs.sum()} max=${xs.max()} avg=${xs.average()}")
        \\}
        \\
    ;
    try assertKlio("prim_arr", src, "sum=31 max=9 avg=3.875\n");
}

test "range_step_explicit" {
    const src =
        \\
        \\fun main() {
        \\    val sb = StringBuilder()
        \\    for (i in 1..15 step 2) sb.append("$i,")
        \\    sb.append("|")
        \\    for (i in 10 downTo 1 step 3) sb.append("$i,")
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("range_step", src, "1,3,5,7,9,11,13,15,|10,7,4,1,\n");
}

test "until_range_exclusive" {
    const src =
        \\
        \\fun main() {
        \\    val sb = StringBuilder()
        \\    for (i in 0 until 5) sb.append("$i,")
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("until", src, "0,1,2,3,4,\n");
}

test "char_range_iteration" {
    const src =
        \\
        \\fun main() {
        \\    val sb = StringBuilder()
        \\    for (c in 'a'..'e') sb.append(c)
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("char_range", src, "abcde\n");
}

test "array_copy_and_slice" {
    const src =
        \\
        \\fun main() {
        \\    val xs = intArrayOf(10,20,30,40,50)
        \\    val slice = xs.sliceArray(1..3)
        \\    println(slice.joinToString(","))
        \\}
        \\
    ;
    try assertKlio("slice", src, "20,30,40\n");
}

test "array_of_nulls_works" {
    const src =
        \\
        \\fun main() {
        \\    val arr = arrayOfNulls<String>(3)
        \\    arr[0] = "a"; arr[2] = "c"
        \\    println(arr.joinToString(",") { it ?: "_" })
        \\}
        \\
    ;
    try assertKlio("arr_nulls", src, "a,_,c\n");
}

test "range_contains_check" {
    const src =
        \\
        \\fun main() {
        \\    val r = 1..10
        \\    println("${5 in r},${15 in r},${(1..3).contains(2)}")
        \\}
        \\
    ;
    try assertKlio("range_in", src, "true,false,true\n");
}

test "int_array_indexed_iter" {
    const src =
        \\
        \\fun main() {
        \\    val xs = intArrayOf(10,20,30)
        \\    val sb = StringBuilder()
        \\    for ((i, v) in xs.withIndex()) sb.append("$i=$v;")
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("withIndex", src, "0=10;1=20;2=30;\n");
}

test "double_array_operations" {
    const src =
        \\
        \\fun main() {
        \\    val xs = doubleArrayOf(1.5, 2.5, 3.5, 4.5)
        \\    println("sum=${xs.sum()} avg=${xs.average()}")
        \\}
        \\
    ;
    try assertKlio("double_arr", src, "sum=12.0 avg=3.0\n");
}
