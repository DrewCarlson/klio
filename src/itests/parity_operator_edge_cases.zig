//! Operator edge cases and conversions.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_operator_edge_cases";

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

test "int_div_truncation_and_mod" {
    const src =
        \\
        \\fun main() {
        \\    println("${7 / 2},${-7 / 2},${7 % 3},${-7 % 3},${7.0 / 2.0}")
        \\}
        \\
    ;
    try assertKlio("int_div", src, "3,-3,1,-1,3.5\n");
}

test "integer_widening_int_to_long" {
    const src =
        \\
        \\fun main() {
        \\    val a: Long = 5
        \\    val b: Long = 1L + 2 * 3
        \\    println("$a,$b")
        \\}
        \\
    ;
    try assertKlio("widening", src, "5,7\n");
}

test "char_to_int_and_back" {
    const src =
        \\
        \\fun main() {
        \\    val c = 'A'
        \\    val n = c.code
        \\    val back = (n + 1).toChar()
        \\    println("$n,$back")
        \\}
        \\
    ;
    try assertKlio("char_int", src, "65,B\n");
}

test "equality_vs_reference" {
    const src =
        \\
        \\fun main() {
        \\    val a = "hello"
        \\    val b = "hel" + "lo"
        \\    val c = a
        \\    println("${a == b},${a === c},${a === b}")
        \\}
        \\
    ;
    // a === b can be true if Kotlin interns; but a == b structurally is true; === c is true (same ref)
    try assertKlio("eq_ref", src, "true,true,true\n");
}

test "bitwise_int_ops" {
    const src =
        \\
        \\fun main() {
        \\    val a = 0b1100
        \\    val b = 0b1010
        \\    println("${a and b},${a or b},${a xor b},${a shl 2},${a shr 1}")
        \\}
        \\
    ;
    try assertKlio("bitwise", src, "8,14,6,48,6\n");
}

test "boolean_short_circuit" {
    const src =
        \\
        \\fun main() {
        \\    var counter = 0
        \\    fun count(b: Boolean): Boolean { counter += 1; return b }
        \\    val r1 = count(true) || count(true)
        \\    val r2 = count(false) && count(true)
        \\    println("$counter,$r1,$r2")
        \\}
        \\
    ;
    // counter: true||... short circuits after 1 call; false&&... short circuits after 1 call. Total: 2
    try assertKlio("short_circuit", src, "2,true,false\n");
}

test "compare_to_returns_consistent" {
    const src =
        \\
        \\fun main() {
        \\    val a = "apple"; val b = "banana"; val c = "apple"
        \\    println("${a.compareTo(b)},${b.compareTo(a)},${a.compareTo(c)}")
        \\}
        \\
    ;
    try assertKlio("compareTo", src, "-1,1,0\n");
}

test "string_repeat_and_concat" {
    const src =
        \\
        \\fun main() {
        \\    val s = "ab".repeat(3)
        \\    val t = "x" + "y" + "z"
        \\    println("$s|$t")
        \\}
        \\
    ;
    try assertKlio("str_repeat", src, "ababab|xyz\n");
}

test "result equality dispatches payload equals" {
    const src =
        \\
        \\class Token(val value: Int) {
        \\    override fun equals(other: Any?): Boolean =
        \\        other is Token && value == other.value
        \\}
        \\@JvmInline value class WrappedToken(val token: Token)
        \\fun main() {
        \\    val first = Result.success(Token(7))
        \\    val same = Result.success(Token(7))
        \\    val different = Result.success(Token(8))
        \\    val wrapped = WrappedToken(Token(7))
        \\    println("${first == same},${first == different}," +
        \\        "${wrapped == WrappedToken(Token(7))},${wrapped == WrappedToken(Token(8))}")
        \\}
        \\
    ;
    try assertKlio("result_payload_equality", src, "true,false,true,false\n");
}
