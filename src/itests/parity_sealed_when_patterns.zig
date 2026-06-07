//! Sealed-hierarchy + when-expression patterns: nested sealed types,
//! exhaustive when over object subtypes, pattern matching on data
//! classes, multi-branch arms with destructured bindings.
//!
//! Port of the Rust suite.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_sealed_when_patterns";

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

test "nested_sealed_hierarchy" {
    const src =
        \\
        \\sealed class Event {
        \\    sealed class Network : Event() {
        \\        class Up(val ms: Int) : Network()
        \\        class Down(val reason: String) : Network()
        \\    }
        \\    class User(val id: Int) : Event()
        \\}
        \\fun render(e: Event): String = when (e) {
        \\    is Event.Network.Up -> "net-up:${e.ms}"
        \\    is Event.Network.Down -> "net-down:${e.reason}"
        \\    is Event.User -> "user:${e.id}"
        \\}
        \\fun main() {
        \\    val xs = listOf(Event.Network.Up(50), Event.Network.Down("timeout"), Event.User(7))
        \\    println(xs.joinToString("|") { render(it) })
        \\}
        \\
    ;
    try assertKlio("nested_sealed", src, "net-up:50|net-down:timeout|user:7\n");
}

test "when_with_destructured_data_class" {
    const src =
        \\
        \\data class P(val x: Int, val y: Int)
        \\fun describe(p: P): String {
        \\    val (x, y) = p
        \\    return when {
        \\        x == 0 && y == 0 -> "origin"
        \\        x == y -> "diag($x)"
        \\        x > 0 && y > 0 -> "q1"
        \\        x < 0 && y > 0 -> "q2"
        \\        else -> "other"
        \\    }
        \\}
        \\fun main() {
        \\    println(listOf(P(0,0), P(3,3), P(2,5), P(-1,4), P(-3,-2))
        \\        .joinToString(",") { describe(it) })
        \\}
        \\
    ;
    try assertKlio("when_dest", src, "origin,diag(3),q1,q2,other\n");
}

test "sealed_with_object_subtypes" {
    const src =
        \\
        \\sealed class State {
        \\    object Idle : State()
        \\    object Loading : State()
        \\    data class Ready(val data: String) : State()
        \\    data class Error(val msg: String) : State()
        \\}
        \\fun describe(s: State): String = when (s) {
        \\    State.Idle -> "idle"
        \\    State.Loading -> "loading"
        \\    is State.Ready -> "ready:${s.data}"
        \\    is State.Error -> "error:${s.msg}"
        \\}
        \\fun main() {
        \\    val xs: List<State> = listOf(
        \\        State.Idle, State.Loading,
        \\        State.Ready("payload"), State.Error("nope"))
        \\    println(xs.joinToString(";") { describe(it) })
        \\}
        \\
    ;
    try assertKlio("sealed_obj", src, "idle;loading;ready:payload;error:nope\n");
}

test "when_with_multi_pattern_arms" {
    const src =
        \\
        \\fun classify(n: Int): String = when (n) {
        \\    0, 1, 2, 3 -> "small"
        \\    4, 5, 6, 7 -> "medium"
        \\    in 8..50 -> "large"
        \\    else -> "huge"
        \\}
        \\fun main() {
        \\    println(listOf(0, 4, 8, 100).joinToString(",") { classify(it) })
        \\}
        \\
    ;
    try assertKlio("when_multi", src, "small,medium,large,huge\n");
}

test "nested_when_with_chained_smart_casts" {
    const src =
        \\
        \\fun render(any: Any?): String = when (any) {
        \\    null -> "null"
        \\    is String -> when {
        \\        any.isEmpty() -> "empty-str"
        \\        any.length < 5 -> "short:$any"
        \\        else -> "long:${any.length}"
        \\    }
        \\    is Int -> when {
        \\        any > 0 -> "pos:$any"
        \\        any < 0 -> "neg:$any"
        \\        else -> "zero"
        \\    }
        \\    else -> "?"
        \\}
        \\fun main() {
        \\    val xs: List<Any?> = listOf(null, "", "hi", "kotlin world", 7, -3, 0, 3.14)
        \\    println(xs.joinToString(",") { render(it) })
        \\}
        \\
    ;
    try assertKlio(
        "nested_when",
        src,
        "null,empty-str,short:hi,long:12,pos:7,neg:-3,zero,?\n",
    );
}

test "when_inside_lambda_body" {
    const src =
        \\
        \\sealed class Op { class Add(val n: Int) : Op(); class Mul(val n: Int) : Op() }
        \\fun main() {
        \\    val ops = listOf<Op>(Op.Add(3), Op.Mul(2), Op.Add(7), Op.Mul(10))
        \\    val result = ops.fold(1) { acc, op ->
        \\        when (op) {
        \\            is Op.Add -> acc + op.n
        \\            is Op.Mul -> acc * op.n
        \\        }
        \\    }
        \\    println(result)
        \\}
        \\
    ;
    // 1+3=4; 4*2=8; 8+7=15; 15*10=150
    try assertKlio("when_lambda", src, "150\n");
}
