//! Data class feature parity: copy with named args, equals/hashCode
//! by field, toString format, destructuring via componentN, copy with
//! all defaults.
//!
//! Port of crates/klio-parity/tests/data_class_features.rs.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_data_class_features";

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

test "data_class_copy_with_partial_override" {
    const src =
        \\
        \\data class P(val name: String, val age: Int, val role: String = "user")
        \\fun main() {
        \\    val a = P("Ann", 30)
        \\    val b = a.copy(age = 31)
        \\    val c = a.copy(role = "admin", age = 40)
        \\    println("$a|$b|$c")
        \\}
        \\
    ;
    try assertKlio(
        "copy_partial",
        src,
        "P(name=Ann, age=30, role=user)|P(name=Ann, age=31, role=user)|P(name=Ann, age=40, role=admin)\n",
    );
}

test "data_class_equality_structural" {
    const src =
        \\
        \\data class Pair2(val a: Int, val b: String)
        \\fun main() {
        \\    val p = Pair2(1, "x")
        \\    val q = Pair2(1, "x")
        \\    val r = Pair2(2, "x")
        \\    println("${p == q},${p == r},${p === q}")
        \\}
        \\
    ;
    try assertKlio("eq_structural", src, "true,false,false\n");
}

test "data_class_in_set_and_map" {
    const src =
        \\
        \\data class K(val v: Int)
        \\fun main() {
        \\    val s = setOf(K(1), K(2), K(1))
        \\    val m = mutableMapOf<K, String>()
        \\    m[K(1)] = "one"
        \\    m[K(2)] = "two"
        \\    println("${s.size}|${m[K(1)]}|${m[K(2)]}")
        \\}
        \\
    ;
    try assertKlio("data_set_map", src, "2|one|two\n");
}

test "data_class_component_n_destructure" {
    const src =
        \\
        \\data class Triple3(val a: Int, val b: String, val c: Double)
        \\fun main() {
        \\    val t = Triple3(1, "x", 3.14)
        \\    val (a, b, c) = t
        \\    println("$a,$b,$c")
        \\}
        \\
    ;
    try assertKlio("componentN", src, "1,x,3.14\n");
}

test "data_class_with_collection_property" {
    const src =
        \\
        \\data class Bag(val items: List<Int>)
        \\fun main() {
        \\    val a = Bag(listOf(1, 2, 3))
        \\    val b = a.copy(items = a.items + 4)
        \\    println("${a.items}|${b.items}")
        \\}
        \\
    ;
    try assertKlio("bag_copy", src, "[1, 2, 3]|[1, 2, 3, 4]\n");
}

test "data_class_pattern_via_when" {
    const src =
        \\
        \\data class Event(val kind: String, val value: Int)
        \\fun classify(e: Event): String = when {
        \\    e.kind == "click" && e.value > 0 -> "click+"
        \\    e.kind == "click" -> "click0"
        \\    e.kind == "scroll" -> "scroll:${e.value}"
        \\    else -> "other"
        \\}
        \\fun main() {
        \\    val xs = listOf(Event("click", 3), Event("click", 0), Event("scroll", 7), Event("?", 0))
        \\    println(xs.joinToString(",") { classify(it) })
        \\}
        \\
    ;
    try assertKlio("when_data", src, "click+,click0,scroll:7,other\n");
}
