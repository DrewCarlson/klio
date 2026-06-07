//! Type-system parity: smart casts after combined conditions,
//! Any.toString, nullable Comparable, enum methods, sealed-class
//! with inherited fields, `KClass` equality, type parameter T.foo
//! resolution.
//!
//! Port of crates/klio-parity/tests/type_system_shapes.rs.
const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_type_system_shapes";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


/// Write `src` to a unique temp `.kt` path under this file's temp dir and run
/// it through the klio pipeline, asserting stdout equals `expected`. Mirrors
/// the Rust `assert_klio` helper.
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

test "smart_cast_after_conjunction" {
    const src =
        \\
        \\fun describe(x: Any?, y: Any?): String =
        \\    if (x is String && y is Int) "${x.length}/${y * 2}" else "no"
        \\fun main() { println("${describe("hi", 5)}|${describe(null, 5)}|${describe("a", "b")}") }
        \\
    ;
    try assertKlio("smart_conj", src, "2/10|no|no\n");
}

test "any_to_string_default_and_override" {
    const src =
        \\
        \\class Default
        \\class Custom { override fun toString(): String = "custom!" }
        \\fun main() {
        \\    val d = Default()
        \\    val c = Custom()
        \\    val s = "$d|$c"
        \\    // d.toString() defaults to Class@hash; just check shape with split
        \\    val pipe = s.indexOf('|')
        \\    println("${pipe > 0},${c.toString()}")
        \\}
        \\
    ;
    try assertKlio("any_toString", src, "true,custom!\n");
}

test "nullable_comparable_chain" {
    const src =
        \\
        \\fun main() {
        \\    val a: Int? = 3
        \\    val b: Int? = null
        \\    val r1 = (a ?: 0) + (b ?: 100)
        \\    val r2 = listOfNotNull(a, b, 7).joinToString(",")
        \\    println("$r1|$r2")
        \\}
        \\
    ;
    try assertKlio("nullable_cmp", src, "103|3,7\n");
}

test "enum_class_method_dispatch" {
    const src =
        \\
        \\enum class Color {
        \\    Red, Green, Blue;
        \\    fun greeting(): String = "$name@$ordinal"
        \\}
        \\fun main() {
        \\    val xs = Color.entries
        \\    println(xs.joinToString(";") { it.greeting() })
        \\}
        \\
    ;
    try assertKlio("enum_method", src, "Red@0;Green@1;Blue@2\n");
}

test "sealed_class_inherited_field" {
    const src =
        \\
        \\sealed class Cell(val pos: Int) {
        \\    class Alive(pos: Int) : Cell(pos)
        \\    class Dead(pos: Int) : Cell(pos)
        \\}
        \\fun render(c: Cell): String = when (c) {
        \\    is Cell.Alive -> "A@${c.pos}"
        \\    is Cell.Dead -> "D@${c.pos}"
        \\}
        \\fun main() {
        \\    val xs = listOf(Cell.Alive(1), Cell.Dead(2), Cell.Alive(3))
        \\    println(xs.joinToString(",") { render(it) })
        \\}
        \\
    ;
    try assertKlio("sealed_field", src, "A@1,D@2,A@3\n");
}

test "kclass_simple_name" {
    const src =
        \\
        \\class Box(val v: Int)
        \\fun main() {
        \\    val b = Box(7)
        \\    println("${b::class.simpleName},${Box::class.simpleName}")
        \\}
        \\
    ;
    try assertKlio("kclass_name", src, "Box,Box\n");
}

test "type_parameter_method_resolution" {
    const src =
        \\
        \\fun <T : Comparable<T>> sorted(a: T, b: T): String = if (a <= b) "$a,$b" else "$b,$a"
        \\fun main() {
        \\    println("${sorted(3, 7)}|${sorted("z", "a")}")
        \\}
        \\
    ;
    try assertKlio("type_param", src, "3,7|a,z\n");
}

test "nullable_iterable_filter" {
    const src =
        \\
        \\fun main() {
        \\    val xs: List<Int?> = listOf(1, null, 2, null, 3)
        \\    val sum = xs.filterNotNull().sum()
        \\    println(sum)
        \\}
        \\
    ;
    try assertKlio("nullable_iter", src, "6\n");
}
