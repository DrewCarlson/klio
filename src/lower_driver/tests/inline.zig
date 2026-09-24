//! Package D's tests: inline instantiation, non-local and labeled
//! returns, jumps out of inline lambdas, and reified type parameters.
//!
//! Each program runs through parse, sema, the bridge, the lowering and the
//! VM over the executable base; the expected output is what kotlinc 2.4.20
//! prints for it.

const std = @import("std");
const ir = @import("ir");

const driver = @import("../lower_driver.zig");

test {
    std.testing.refAllDecls(ir.lower_sema.inline_);
}

fn expectRun(src: []const u8, want: []const u8) !void {
    try driver.expectOutput(&.{src}, want);
}

/// How many instructions of each kind `main`'s lowered body holds.
fn mainCounts(a: std.mem.Allocator, src: []const u8) !std.EnumArray(std.meta.Tag(ir.Inst), u32) {
    const an = try driver.analyze(a, &.{src});
    const prog = try ir.lower_sema.lowerProgram(a, an.s, an.br);
    try std.testing.expectEqual(@as(usize, 0), prog.errors.items.len);
    const main = an.br.funcOfOpt((try an.mainSym()).?).?;
    var counts: std.EnumArray(std.meta.Tag(ir.Inst), u32) = .initFill(0);
    for (an.br.m.funcs.items[main.int()].blocks) |blk| {
        for (blk.insts) |inst| counts.set(std.meta.activeTag(inst), counts.get(std.meta.activeTag(inst)) + 1);
    }
    return counts;
}

test "a literal passed to an inline function is lowered in place and a reified test is static" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const counts = try mainCounts(arena.allocator(),
        \\inline fun <reified T> isA(x: Any?): Boolean = x is T
        \\fun main() {
        \\    var sum = 0
        \\    listOf(1, 2).forEach { sum = sum + it }
        \\    println(isA<String>(sum))
        \\}
    );
    try std.testing.expectEqual(@as(u32, 0), counts.get(.MakeClosure));
    try std.testing.expectEqual(@as(u32, 0), counts.get(.RCallValue));
    try std.testing.expectEqual(@as(u32, 0), counts.get(.InstanceOfDyn));
    try std.testing.expectEqual(@as(u32, 1), counts.get(.RInstanceOf));
}

test "a return from a lambda passed to forEach leaves the caller" {
    try expectRun(
        \\fun firstEven(xs: List<Int>): Int {
        \\    xs.forEach { if (it % 2 == 0) return it }
        \\    return -1
        \\}
        \\fun main() {
        \\    println(firstEven(listOf(1, 3, 4, 5)))
        \\    println(firstEven(listOf(1, 3)))
        \\}
    , "4\n-1\n");
}

test "return@forEach leaves only the lambda" {
    try expectRun(
        \\fun main() {
        \\    listOf(1, 2, 3, 4).forEach {
        \\        if (it % 2 == 0) return@forEach
        \\        println(it)
        \\    }
        \\    listOf(5, 6).forEach lit@{
        \\        if (it == 5) return@lit
        \\        println(it)
        \\    }
        \\    println("done")
        \\}
    , "1\n3\n6\ndone\n");
}

test "break and continue in an inline lambda reach the caller's loop" {
    try expectRun(
        \\fun main() {
        \\    for (i in 1..5) {
        \\        run {
        \\            if (i == 2) continue
        \\            if (i == 4) break
        \\            println(i)
        \\        }
        \\    }
        \\    var n = 0
        \\    while (true) {
        \\        n = n + 1
        \\        listOf(1, 2).forEach { if (n == 3) break }
        \\    }
        \\    println(n)
        \\}
    , "1\n3\n3\n");
}

test "inline calls nest, and a return crosses both" {
    try expectRun(
        \\inline fun twice(block: () -> Unit) {
        \\    block()
        \\    block()
        \\}
        \\inline fun <T> around(tag: String, block: () -> T): T {
        \\    println("<" + tag + ">")
        \\    val r = block()
        \\    println("</" + tag + ">")
        \\    return r
        \\}
        \\fun find(xs: List<Int>): String {
        \\    twice { xs.forEach { if (it > 2) return "found " + it } }
        \\    return "none"
        \\}
        \\fun main() {
        \\    var n = 0
        \\    val r = around("a") {
        \\        twice { around("b") { n = n + 1 } }
        \\        n * 10
        \\    }
        \\    println(r)
        \\    println(find(listOf(1, 5)))
        \\    println(find(listOf(1)))
        \\}
    , "<a>\n<b>\n</b>\n<b>\n</b>\n</a>\n20\nfound 5\nnone\n");
}

test "a try/finally around the lambda call runs its finally on every way out" {
    try expectRun(
        \\inline fun <T> guarded(block: () -> T): T {
        \\    try {
        \\        return block()
        \\    } finally {
        \\        println("cleanup")
        \\    }
        \\}
        \\fun pick(x: Int): String {
        \\    guarded {
        \\        if (x > 0) return "positive"
        \\        "zero"
        \\    }
        \\    return "after"
        \\}
        \\fun main() {
        \\    println(pick(1))
        \\    println(pick(0))
        \\    println(guarded { "value" })
        \\    for (i in 1..3) {
        \\        guarded {
        \\            if (i == 2) break
        \\            println(i)
        \\        }
        \\    }
        \\    println("end")
        \\}
    , "cleanup\npositive\ncleanup\nafter\ncleanup\nvalue\n1\ncleanup\ncleanup\nend\n");
}

test "a jump out of a lambda leaves the inline function's catch frame behind" {
    try expectRun(
        \\inline fun safely(block: () -> Unit) {
        \\    try {
        \\        block()
        \\    } catch (e: IllegalStateException) {
        \\        println("caught")
        \\    }
        \\}
        \\fun main() {
        \\    for (i in 1..3) {
        \\        safely {
        \\            if (i == 2) break
        \\            println(i)
        \\        }
        \\    }
        \\    safely { throw IllegalStateException("inner") }
        \\    try {
        \\        throw IllegalStateException("outer")
        \\    } catch (e: IllegalStateException) {
        \\        println("outer")
        \\    }
        \\}
    , "1\ncaught\nouter\n");
    // Had the break left the frame armed, it would catch this throw.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const o = try driver.run(arena.allocator(), &.{
        \\inline fun safely(block: () -> Unit) {
        \\    try {
        \\        block()
        \\    } catch (e: IllegalStateException) {
        \\        println("caught")
        \\    }
        \\}
        \\fun main() {
        \\    for (i in 1..3) {
        \\        safely { if (i == 2) break }
        \\    }
        \\    throw IllegalStateException("escapes")
        \\}
    });
    try std.testing.expectEqual(.threw, o.result);
    try std.testing.expectEqualStrings("", o.output);
    try std.testing.expectEqualStrings("kotlin.IllegalStateException", o.diag);
}

test "a reified type parameter tests, casts, names its class and passes on" {
    try expectRun(
        \\inline fun <reified T> isA(x: Any?): Boolean = x is T
        \\inline fun <reified T> castOrNull(x: Any?): T? = x as? T
        \\inline fun <reified T> cast(x: Any?): T = x as T
        \\inline fun <reified T> name(): String? = T::class.simpleName
        \\inline fun <reified T> both(x: Any?): String = "" + isA<T>(x) + " " + name<T>()
        \\fun main() {
        \\    println(isA<String>("s"))
        \\    println(isA<String>(1))
        \\    println(castOrNull<Int>(3))
        \\    println(castOrNull<Int>("x"))
        \\    println(cast<String>("ok"))
        \\    println(name<String>())
        \\    println(both<Int>(5))
        \\    println(both<String>(5))
        \\    try {
        \\        println(cast<Int>("no"))
        \\    } catch (e: ClassCastException) {
        \\        println("cce")
        \\    }
        \\}
    , "true\nfalse\n3\nnull\nok\nString\ntrue Int\nfalse String\ncce\n");
}

test "a lambda that outlives the call captures the reified type value" {
    try expectRun(
        \\inline fun <reified T> tester(): (Any?) -> Boolean = { x -> x is T }
        \\inline fun <reified T> keeper(): (Any?) -> T? = { x -> x as? T }
        \\fun main() {
        \\    val isText = tester<String>()
        \\    println(isText("a"))
        \\    println(isText(1))
        \\    println(keeper<Int>()(7))
        \\    println(keeper<Int>()("no"))
        \\}
    , "true\nfalse\n7\nnull\n");
}

test "an inline call with an omitted argument instantiates the defaults bridge, literal in place" {
    try expectRun(
        \\inline fun repeatText(text: String = "x", times: Int = 2, block: (String) -> Unit) {
        \\    var i = 0
        \\    while (i < times) {
        \\        block(text)
        \\        i = i + 1
        \\    }
        \\}
        \\fun early(): String {
        \\    repeatText { if (it == "x") return "early" }
        \\    return "late"
        \\}
        \\fun main() {
        \\    repeatText { println(it) }
        \\    repeatText("y", 1) { println(it) }
        \\    println(early())
        \\}
    , "x\nx\ny\nearly\n");
}

test "a crossinline lambda called from a nested closure is a closure" {
    try expectRun(
        \\inline fun later(crossinline block: () -> Unit): () -> Unit = { block(); block() }
        \\fun main() {
        \\    var n = 0
        \\    val f = later { n = n + 1 }
        \\    f()
        \\    println(n)
        \\}
    , "2\n");
}

test "a noinline parameter is a value the function can store" {
    try expectRun(
        \\inline fun keep(list: MutableList<() -> String>, noinline f: () -> String, g: () -> String): String {
        \\    list.add(f)
        \\    return g()
        \\}
        \\fun main() {
        \\    val list = mutableListOf<() -> String>()
        \\    println(keep(list, { "stored" }, { "called" }))
        \\    println(list[0]())
        \\}
    , "called\nstored\n");
}

test "a reference to an inline function runs its ordinary body" {
    try expectRun(
        \\inline fun twiceOf(x: Int): Int = x * 2
        \\fun applyTo(f: (Int) -> Int, v: Int): Int = f(v)
        \\fun main() {
        \\    println(applyTo(::twiceOf, 21))
        \\    println(twiceOf(4))
        \\}
    , "42\n8\n");
}

test "a reference to a reified function passes the type its expected type fixes" {
    try expectRun(
        \\inline fun <reified T> kind(x: T): String = (T::class.simpleName ?: "?") + " " + x
        \\fun useInt(f: (Int) -> String) = f(1)
        \\fun useString(f: (String) -> String) = f("a")
        \\fun main() {
        \\    println(useInt(::kind))
        \\    println(useString(::kind))
        \\}
    , "Int 1\nString a\n");
}

test "an inline extension property is instantiated from its getter" {
    try expectRun(
        \\val Int.dp: Int inline get() = this * 3
        \\inline val String.shout: String get() = this + "!"
        \\fun main() {
        \\    println(5.dp)
        \\    println("hi".shout)
        \\}
    , "15\nhi!\n");
}

test "a suspend inline function called from suspend main" {
    try expectRun(
        \\suspend inline fun <T> measure(block: () -> T): T {
        \\    println("start")
        \\    val r = block()
        \\    println("end")
        \\    return r
        \\}
        \\suspend fun main() {
        \\    println(measure { 7 })
        \\}
    , "start\nend\n7\n");
}
