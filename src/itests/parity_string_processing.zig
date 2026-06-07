//! String processing parity: regex, padStart/padEnd, lines, take/drop,
//! Char conversions, String<->Bytes, format integers.
//!
//! Port of the Rust suite.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_string_processing";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) allocated from the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so a single file-scoped arena over the page allocator backs every run here
// (the leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

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

test "string_pad_start_end" {
    const src =
        \\
        \\fun main() {
        \\    println("${"3".padStart(5, '0')}|${"3".padEnd(5, '.')}")
        \\}
        \\
    ;
    try assertKlio("pad", src, "00003|3....\n");
}

test "string_lines_and_take" {
    const src =
        \\
        \\fun main() {
        \\    val s = "alpha\nbeta\ngamma\ndelta"
        \\    val xs = s.lines()
        \\    println("${xs.size}|${xs.take(2).joinToString(",")}|${xs.drop(2).joinToString("|")}")
        \\}
        \\
    ;
    try assertKlio("lines", src, "4|alpha,beta|gamma|delta\n");
}

test "string_uppercase_lowercase" {
    const src =
        \\
        \\fun main() {
        \\    val s = "Hello, World!"
        \\    println("${s.uppercase()}|${s.lowercase()}")
        \\}
        \\
    ;
    try assertKlio("case", src, "HELLO, WORLD!|hello, world!\n");
}

test "char_is_digit_letter" {
    const src =
        \\
        \\fun main() {
        \\    val xs = "a1!Z9 ".toCharArray()
        \\    val r = xs.map { "${it.isLetter()}/${it.isDigit()}" }
        \\    println(r.joinToString(","))
        \\}
        \\
    ;
    try assertKlio(
        "char_isX",
        src,
        "true/false,false/true,false/false,true/false,false/true,false/false\n",
    );
}

test "string_filter_count" {
    const src =
        \\
        \\fun main() {
        \\    val s = "Hello, World! 123"
        \\    val digits = s.filter { it.isDigit() }
        \\    val n_letters = s.count { it.isLetter() }
        \\    println("$digits|$n_letters")
        \\}
        \\
    ;
    try assertKlio("filter_count", src, "123|10\n");
}

test "string_reverse_split" {
    const src =
        \\
        \\fun main() {
        \\    val s = "abcdef"
        \\    val r = s.reversed()
        \\    val xs = "a,b,c,d".split(",")
        \\    println("$r|$xs")
        \\}
        \\
    ;
    try assertKlio("reverse_split", src, "fedcba|[a, b, c, d]\n");
}

test "string_concat_mixed_types" {
    const src =
        \\
        \\fun main() {
        \\    val n = 42
        \\    val pi = 3.14
        \\    val ok = true
        \\    println("n=$n pi=$pi ok=$ok ${1+2}")
        \\}
        \\
    ;
    try assertKlio("concat_mixed", src, "n=42 pi=3.14 ok=true 3\n");
}

test "string_code_points_via_chars" {
    const src =
        \\
        \\fun main() {
        \\    val s = "ABC"
        \\    println(s.map { it.code }.joinToString(","))
        \\}
        \\
    ;
    try assertKlio("codepoints", src, "65,66,67\n");
}

test "stringbuilder_chaining" {
    const src =
        \\
        \\fun main() {
        \\    val sb = StringBuilder()
        \\    sb.append("hello").append(", ").append("world").append("!")
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("sb_chain", src, "hello, world!\n");
}

test "string_repeat_zero" {
    const src =
        \\
        \\fun main() {
        \\    println("[${"x".repeat(0)}]|[${"y".repeat(3)}]")
        \\}
        \\
    ;
    try assertKlio("repeat_zero", src, "[]|[yyy]\n");
}
