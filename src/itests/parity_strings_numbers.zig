//! String manipulation, number parsing, regex, char operations; string
//! processing (padStart/padEnd, lines, take/drop, Char conversions,
//! filter/count, StringBuilder chaining, repeat).

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_strings_numbers";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) allocated from the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so a single file-scoped arena over the page allocator backs every run here
// (the leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

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

test "string_split_and_join" {
    const src =
        \\
        \\fun main() {
        \\    val s = "a,b,c,d"
        \\    val parts = s.split(",")
        \\    val rejoined = parts.joinToString("|")
        \\    println("$parts|$rejoined")
        \\}
        \\
    ;
    try assertKlio("split_join", src, "[a, b, c, d]|a|b|c|d\n");
}

test "string_substring_operations" {
    const src =
        \\
        \\fun main() {
        \\    val s = "Kotlin is fun"
        \\    println("${s.length},${s.substring(0,6)},${s.startsWith("Kotlin")},${s.endsWith("fun")},${s.indexOf("is")}")
        \\}
        \\
    ;
    try assertKlio("substr", src, "13,Kotlin,true,true,7\n");
}

test "string_template_complex" {
    const src =
        \\
        \\data class P(val x: Int, val y: Int)
        \\fun main() {
        \\    val p = P(3, 4)
        \\    val s = "p=($p) sum=${p.x + p.y} cond=${if (p.x > p.y) "x" else "y"}"
        \\    println(s)
        \\}
        \\
    ;
    try assertKlio("string_template", src, "p=(P(x=3, y=4)) sum=7 cond=y\n");
}

test "char_arithmetic_and_compare" {
    const src =
        \\
        \\fun main() {
        \\    val c1 = 'a'
        \\    val c2 = 'A'
        \\    println("${c1 - c2},${c1 + 3},${c1.code},${c1.isLetter()},${c1.uppercaseChar()}")
        \\}
        \\
    ;
    try assertKlio("char_arith", src, "32,d,97,true,A\n");
}

test "number_parsing_and_formatting" {
    const src =
        \\
        \\fun main() {
        \\    val a = "42".toInt()
        \\    val b = "3.14".toDouble()
        \\    val c = "ff".toInt(16)
        \\    val d = "1010".toInt(2)
        \\    println("$a,$b,$c,$d")
        \\}
        \\
    ;
    try assertKlio("num_parsing", src, "42,3.14,255,10\n");
}

test "integer_overflow_signed" {
    const src =
        \\
        \\fun main() {
        \\    val max = Int.MAX_VALUE
        \\    val ov = max + 1
        \\    val min = Int.MIN_VALUE
        \\    val ov2 = min - 1
        \\    println("$max,$ov,$min,$ov2")
        \\}
        \\
    ;
    try assertKlio(
        "int_overflow",
        src,
        "2147483647,-2147483648,-2147483648,2147483647\n",
    );
}

test "long_double_arithmetic" {
    const src =
        \\
        \\fun main() {
        \\    val l: Long = 1_000_000L * 1_000_000L
        \\    val d: Double = 1.5 * 2.5
        \\    println("$l,$d")
        \\}
        \\
    ;
    try assertKlio("long_dbl", src, "1000000000000,3.75\n");
}

test "string_replace_and_trim" {
    const src =
        \\
        \\fun main() {
        \\    val s = "  Hello, World!  "
        \\    val t = s.trim()
        \\    val r = t.replace("World", "Kotlin")
        \\    println("[$t]|[$r]")
        \\}
        \\
    ;
    try assertKlio("replace_trim", src, "[Hello, World!]|[Hello, Kotlin!]\n");
}

test "raw_string_with_indent" {
    const src =
        \\
        \\fun main() {
        \\    val r = """
        \\        line1
        \\        line2
        \\        line3""".trimIndent()
        \\    println(r)
        \\}
        \\
    ;
    try assertKlio("raw_indent", src, "line1\nline2\nline3\n");
}

test "string_to_list_chars" {
    const src =
        \\
        \\fun main() {
        \\    val s = "hello"
        \\    val chars = s.toList()
        \\    val rev = chars.reversed().joinToString("")
        \\    println("${chars.size}|$rev")
        \\}
        \\
    ;
    try assertKlio("str_to_chars", src, "5|olleh\n");
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
