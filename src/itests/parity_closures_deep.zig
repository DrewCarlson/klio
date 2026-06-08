//! Advanced closure / capture / dispatch scenarios.
//!
//! Port of the Rust suite.
const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_closures_deep";

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

// 1. Closure of closure of var — innermost mutates, middle reads,
//    outer reads after invocation.
test "three_level_closure_capture" {
    const src =
        \\
        \\fun main() {
        \\    var n = 0
        \\    val outer: () -> () -> Int = {
        \\        { n += 1; n }
        \\    }
        \\    val inner = outer()
        \\    val a = inner(); val b = inner(); val c = inner()
        \\    println("$a,$b,$c,n=$n")
        \\}
        \\
    ;
    try assertKlio("three_level", src, "1,2,3,n=3\n");
}

// 2. Lambda referencing a captured var while loop reassigns it
//    invokes lambda each iteration — lambda observes current value.
test "lambda_observes_var_reassignment" {
    const src =
        \\
        \\fun main() {
        \\    var k = 0
        \\    val read = { k }
        \\    val sb = StringBuilder()
        \\    for (i in 1..3) { k = i * 10; sb.append("${read()},") }
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("lambda_observes", src, "10,20,30,\n");
}

// 3. Closure capturing `this` of enclosing class accessed inside
//    deeply nested lambdas.
test "this_capture_in_deep_nesting" {
    const src =
        \\
        \\class Box(val tag: String) {
        \\    fun build(): String {
        \\        val outer = {
        \\            val inner = { tag + "!" }
        \\            inner()
        \\        }
        \\        return outer()
        \\    }
        \\}
        \\fun main() { println(Box("Hi").build()) }
        \\
    ;
    try assertKlio("this_deep", src, "Hi!\n");
}

// 4. Captured destructured variable.
test "capture_destructured" {
    const src =
        \\
        \\fun main() {
        \\    val (a, b) = Pair(3, 4)
        \\    val sum = { a + b }
        \\    val product = { a * b }
        \\    println("${sum()},${product()}")
        \\}
        \\
    ;
    try assertKlio("capture_dest", src, "7,12\n");
}

// 5. Lambda returning lambda chain, currying-style.
test "curried_lambda_chain" {
    const src =
        \\
        \\fun main() {
        \\    val add: (Int) -> (Int) -> (Int) -> Int = { a -> { b -> { c -> a + b + c } } }
        \\    println(add(1)(2)(3))
        \\}
        \\
    ;
    try assertKlio("curried", src, "6\n");
}

// 6. Mutual recursion via lambdas in val bindings using lateinit
//    val and tied-knot through enclosing variable.
test "lambda_tied_knot_recursion" {
    const src =
        \\
        \\fun main() {
        \\    var even: (Int) -> Boolean = { false }
        \\    var odd: (Int) -> Boolean = { false }
        \\    even = { n -> if (n == 0) true else odd(n - 1) }
        \\    odd = { n -> if (n == 0) false else even(n - 1) }
        \\    println("${even(4)},${even(7)}")
        \\}
        \\
    ;
    try assertKlio("tied_knot", src, "true,false\n");
}

// 7. Lambda parameter shadowing enclosing local of same name.
test "lambda_param_shadows_outer" {
    const src =
        \\
        \\fun main() {
        \\    val x = 100
        \\    val f = { x: Int -> x * 2 }
        \\    println("${f(5)},$x")
        \\}
        \\
    ;
    try assertKlio("shadow", src, "10,100\n");
}

// 8. Captured `it` in nested let-blocks doesn't bleed across.
test "nested_let_it_scoping" {
    const src =
        \\
        \\fun main() {
        \\    val a = 3.let { outer ->
        \\        4.let { inner -> outer * inner }
        \\    }
        \\    println(a)
        \\}
        \\
    ;
    try assertKlio("let_it_scoping", src, "12\n");
}

// 9. Closure passed to a coroutine — captures stay alive across
//    suspension points.
test "closure_across_suspension" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\fun main() = runBlocking {
        \\    val tag = "ok"
        \\    val get = { tag }
        \\    delay(5)
        \\    println(get())
        \\}
        \\
    ;
    try assertKlio("closure_suspend", src, "ok\n");
}

// 10. Lambda capturing a primitive Int via box; reassignment is
//     observed across the boundary.
test "primitive_box_observability" {
    const src =
        \\
        \\fun main() {
        \\    var counter = 0
        \\    val tick: () -> Int = { counter += 1; counter }
        \\    repeat(5) { tick() }
        \\    println(counter)
        \\}
        \\
    ;
    try assertKlio("box_obs", src, "5\n");
}

// 11. Precise captured-`var` carrier: the SAME captured var, mutated by a
//     lambda invoked three different ways (called directly, passed to a
//     stdlib HOF, captured across launch/suspend), must round-trip
//     identically on every path. Proves the carrier is uniform, not
//     path-dependent.
test "captured_var_carrier_uniform_across_paths" {
    const src =
        \\import kotlinx.coroutines.*
        \\fun callTwice(f: () -> Unit) { f(); f() }
        \\fun main() = runBlocking {
        \\    var direct = 0
        \\    val bump = { direct = direct + 1 }
        \\    bump()
        \\    callTwice(bump)
        \\    println("direct=$direct")
        \\    var hof = 0
        \\    listOf(1, 2, 3, 4).forEach { hof = hof + it }
        \\    println("hof=$hof")
        \\    var sus = 0
        \\    val job = launch { delay(10L); sus = sus + 100 }
        \\    job.join()
        \\    println("sus=$sus")
        \\}
        \\
    ;
    try assertKlio("carrier_uniform", src, "direct=3\nhof=10\nsus=100\n");
}

// 12. A captured `var` written across the inline-splice boundary: the
//     inline HOF's own body `var` and the spliced user lambda both write
//     captured state. Before the precise carrier, the inlined body's
//     captured-`var` write lowered to the StoreGlobal fallback (only
//     round-tripping on the HOF scoped env); now it lands on a shared cell.
test "captured_var_across_inline_splice" {
    const src =
        \\inline fun runAndCount(times: Int, block: (Int) -> Unit): Int {
        \\    var invoked = 0
        \\    var k = 0
        \\    while (k < times) {
        \\        block(k)
        \\        invoked = invoked + 1
        \\        k = k + 1
        \\    }
        \\    return invoked
        \\}
        \\fun main() {
        \\    var acc = 0
        \\    val n = runAndCount(4) { step -> acc = acc + step }
        \\    println("acc=$acc n=$n")
        \\}
        \\
    ;
    try assertKlio("carrier_inline", src, "acc=6 n=4\n");
}

// 13. Sibling closures over one captured var: one writes, one reads, while
//     a stdlib HOF lambda writes the same var. All three observe one cell.
test "captured_var_sibling_closures_and_hof" {
    const src =
        \\fun main() {
        \\    var shared = 0
        \\    val inc = { shared = shared + 1 }
        \\    val read = { shared }
        \\    inc(); inc()
        \\    listOf(10, 20).forEach { shared = shared + it }
        \\    inc()
        \\    println(read())
        \\}
        \\
    ;
    try assertKlio("carrier_siblings", src, "33\n");
}
