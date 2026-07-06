//! Named arguments, default values, varargs, mixed forms.
const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_named_args_defaults";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


/// Run `src` through the in-process klio pipeline and assert stdout equals
/// `expected`: write the embedded source to a unique temp `.kt`, then
/// `runWithPacks`.
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

test "named_args_out_of_order" {
    const src =
        \\
        \\fun greet(name: String, prefix: String, suffix: String): String = "$prefix$name$suffix"
        \\fun main() {
        \\    val r = greet(suffix = "!", name = "Ann", prefix = ">>")
        \\    println(r)
        \\}
        \\
    ;
    try assertKlio("named_oo", src, ">>Ann!\n");
}

test "default_with_named_partial" {
    const src =
        \\
        \\fun fmt(n: Int, base: Int = 10, prefix: String = "", suffix: String = ""): String =
        \\    "$prefix${n.toString(base)}$suffix"
        \\fun main() {
        \\    println("${fmt(15)}|${fmt(15, base = 16)}|${fmt(15, suffix = "!")}|${fmt(15, prefix = "0x", base = 16)}")
        \\}
        \\
    ;
    try assertKlio("default_named", src, "15|f|15!|0xf\n");
}

test "vararg_with_named_after" {
    const src =
        \\
        \\fun build(first: String, vararg items: Int, last: String = "end"): String =
        \\    "$first[${items.joinToString(",")}]$last"
        \\fun main() {
        \\    println(build("S", 1, 2, 3, last = "E"))
        \\    println(build("S", last = "Z"))
        \\}
        \\
    ;
    try assertKlio("vararg_named", src, "S[1,2,3]E\nS[]Z\n");
}

test "default_expression_references_prior_param" {
    const src =
        \\
        \\fun rect(w: Int, h: Int = w * 2, p: Int = 2 * (w + h)): String =
        \\    "w=$w h=$h p=$p"
        \\fun main() {
        \\    println("${rect(3)}|${rect(3, 5)}|${rect(3, 5, 20)}")
        \\}
        \\
    ;
    // rect(3): w=3, h=6, p=2*(3+6)=18
    // rect(3,5): w=3, h=5, p=2*8=16
    // rect(3,5,20): w=3, h=5, p=20
    try assertKlio("default_prior", src, "w=3 h=6 p=18|w=3 h=5 p=16|w=3 h=5 p=20\n");
}

test "lambda_default_arg" {
    const src =
        \\
        \\fun pick(n: Int, fallback: () -> Int = { 0 }): Int = if (n > 0) n else fallback()
        \\fun main() {
        \\    println("${pick(7)},${pick(-3)},${pick(-3) { 99 }}")
        \\}
        \\
    ;
    try assertKlio("lambda_default", src, "7,0,99\n");
}

test "extension_with_named_args" {
    const src =
        \\
        \\fun String.padBoth(left: Int = 1, right: Int = 1, fill: Char = '.'): String =
        \\    "${fill.toString().repeat(left)}$this${fill.toString().repeat(right)}"
        \\fun main() {
        \\    println("a".padBoth())
        \\    println("a".padBoth(right = 3))
        \\    println("a".padBoth(fill = '*', left = 2))
        \\}
        \\
    ;
    try assertKlio("ext_named", src, ".a.\n.a...\n**a*\n");
}

test "data_class_copy_named_args" {
    const src =
        \\
        \\data class P(val x: Int = 0, val y: Int = 0, val tag: String = "")
        \\fun main() {
        \\    val a = P()
        \\    val b = a.copy(x = 5)
        \\    val c = a.copy(tag = "T")
        \\    val d = a.copy(x = 1, y = 2, tag = "all")
        \\    println("$a|$b|$c|$d")
        \\}
        \\
    ;
    try assertKlio(
        "data_copy_named",
        src,
        "P(x=0, y=0, tag=)|P(x=5, y=0, tag=)|P(x=0, y=0, tag=T)|P(x=1, y=2, tag=all)\n",
    );
}

test "constructor_default_chained" {
    const src =
        \\
        \\class Cfg(val host: String = "localhost", val port: Int = 8080, val tls: Boolean = false) {
        \\    fun render(): String = "${if (tls) "https" else "http"}://$host:$port"
        \\}
        \\fun main() {
        \\    println(Cfg().render())
        \\    println(Cfg("example.com").render())
        \\    println(Cfg(port = 443, tls = true, host = "api.example.com").render())
        \\}
        \\
    ;
    try assertKlio(
        "ctor_default",
        src,
        "http://localhost:8080\nhttp://example.com:8080\nhttps://api.example.com:443\n",
    );
}
