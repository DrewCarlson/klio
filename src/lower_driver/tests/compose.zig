//! Compose as lowering, over a miniature compose runtime whose composer
//! records the groups and probes composable code makes. Each expected
//! output is the call sequence the Compose compiler's lowering gives the
//! same program: the composer pair threaded through every composable call,
//! restart groups whose scopes re-invoke their function, the skip gate over
//! the arguments' change bits, replace groups around branches that compose,
//! movable groups for `key`, and the groups a return leaves closed.

const std = @import("std");

const driver = @import("../lower_driver.zig");

fn skipUnbuilt(err: anyerror) anyerror {
    return if (err == error.Unsupported) error.SkipZigTest else err;
}

/// The compiler-facing surface of `androidx.compose.runtime` the lowering
/// calls, and a composer that records what it is asked: groups as `<key` /
/// `>`, skipped groups as `skip`, each `changed` against a slot list in
/// call order.
const runtime =
    \\package androidx.compose.runtime
    \\
    \\annotation class Composable
    \\annotation class NonRestartableComposable
    \\annotation class ReadOnlyComposable
    \\annotation class ExplicitGroupsComposable
    \\annotation class NonSkippableComposable
    \\annotation class Stable
    \\annotation class Immutable
    \\annotation class StableMarker
    \\
    \\interface ScopeUpdateScope {
    \\    fun updateScope(block: (Composer, Int) -> Unit)
    \\}
    \\
    \\interface Composer {
    \\    val skipping: Boolean
    \\    fun startRestartGroup(key: Int): Composer
    \\    fun endRestartGroup(): ScopeUpdateScope?
    \\    fun startReplaceGroup(key: Int)
    \\    fun endReplaceGroup()
    \\    fun startMovableGroup(key: Int, dataKey: Any?)
    \\    fun endMovableGroup()
    \\    fun skipToGroupEnd()
    \\    fun changed(value: Any?): Boolean
    \\    fun changed(value: Int): Boolean
    \\    fun changedInstance(value: Any?): Boolean
    \\    fun shouldExecute(parametersChanged: Boolean, flags: Int): Boolean
    \\    fun joinKey(left: Any?, right: Any?): Any
    \\    val currentMarker: Int
    \\    fun endToMarker(marker: Int)
    \\    fun startDefaults()
    \\    fun endDefaults()
    \\    val defaultsInvalid: Boolean
    \\    fun rememberedValue(): Any?
    \\    fun updateRememberedValue(value: Any?)
    \\    companion object {
    \\        val Empty: Any = "empty"
    \\    }
    \\}
    \\
    \\annotation class DisallowComposableCalls
    \\annotation class DontMemoize
    \\
    \\@Composable inline fun <T> remember(crossinline calculation: @DisallowComposableCalls () -> T): T =
    \\    throw IllegalStateException("the compiler's")
    \\@Composable inline fun <T> remember(key1: Any?, crossinline calculation: @DisallowComposableCalls () -> T): T =
    \\    throw IllegalStateException("the compiler's")
    \\
    \\@Composable inline fun <T> key(vararg keys: Any?, block: @Composable () -> T): T = block()
    \\
    \\fun updateChangedFlags(flags: Int): Int = flags
    \\
    \\val currentComposer: Composer
    \\    @Composable get() = throw IllegalStateException("an intrinsic")
    \\
    \\class Scope(val block: (Composer, Int) -> Unit) : ScopeUpdateScope {
    \\    var restart: ((Composer, Int) -> Unit)? = null
    \\    override fun updateScope(block: (Composer, Int) -> Unit) { restart = block }
    \\}
    \\
    \\class Recorder : Composer {
    \\    var trace = ""
    \\    val slots = ArrayList<Any?>()
    \\    var pos = 0
    \\    var scopes = ArrayList<Scope>()
    \\    override var skipping = false
    \\    fun note(s: String) { trace = if (trace.length == 0) s else trace + " " + s }
    \\    override fun startRestartGroup(key: Int): Composer { note("<r"); depth = depth + 1; return this }
    \\    override fun endRestartGroup(): ScopeUpdateScope? {
    \\        note(">r")
    \\        depth = depth - 1
    \\        val s = Scope({ c, f -> })
    \\        scopes.add(s)
    \\        return s
    \\    }
    \\    override fun startReplaceGroup(key: Int) { note("<g"); depth = depth + 1 }
    \\    override fun endReplaceGroup() { note(">g"); depth = depth - 1 }
    \\    override fun startMovableGroup(key: Int, dataKey: Any?) { note("<m:" + dataKey); depth = depth + 1 }
    \\    override fun endMovableGroup() { note(">m"); depth = depth - 1 }
    \\    override fun skipToGroupEnd() { note("skip") }
    \\    override fun startDefaults() { note("<d") }
    \\    override fun endDefaults() { note(">d") }
    \\    override val defaultsInvalid: Boolean get() = false
    \\    override fun rememberedValue(): Any? {
    \\        val v = if (pos < slots.size) slots[pos] else Composer.Empty
    \\        pos = pos + 1
    \\        return v
    \\    }
    \\    override fun updateRememberedValue(value: Any?) {
    \\        if (pos - 1 < slots.size) slots.set(pos - 1, value) else slots.add(value)
    \\    }
    \\    override fun changed(value: Any?): Boolean {
    \\        val differs = pos >= slots.size || slots[pos] != value
    \\        if (pos >= slots.size) slots.add(value) else slots.set(pos, value)
    \\        pos = pos + 1
    \\        return differs
    \\    }
    \\    override fun changed(value: Int): Boolean = changed(value as Any?)
    \\    override fun changedInstance(value: Any?): Boolean = changed(value)
    \\    override fun shouldExecute(parametersChanged: Boolean, flags: Int): Boolean =
    \\        parametersChanged || !skipping
    \\    override fun joinKey(left: Any?, right: Any?): Any = "" + left + "+" + right
    \\    var depth = 0
    \\    override val currentMarker: Int get() = depth
    \\    override fun endToMarker(marker: Int) {
    \\        note("~" + (depth - marker))
    \\        depth = marker
    \\    }
    \\    /// Recomposes: reruns the restart scope recorded `index`-th, skipping
    \\    /// what did not change.
    \\    fun recompose(index: Int) {
    \\        pos = 0
    \\        trace = ""
    \\        skipping = true
    \\        val s = scopes.get(index)
    \\        scopes = ArrayList<Scope>()
    \\        s.restart!!(this, 0)
    \\    }
    \\}
    \\
    \\fun compose(composer: Composer, content: @Composable () -> Unit) {
    \\    (content as (Composer, Int) -> Unit)(composer, 0)
    \\}
    \\
;

/// The runtime's composable lambdas: a closure remembered as a value that
/// brackets its content with `<L` / `>L`.
const lambdas =
    \\package androidx.compose.runtime.internal
    \\
    \\import androidx.compose.runtime.*
    \\
    \\class Memo(val key: Int, val block: Any) : (Composer, Int) -> Any? {
    \\    override fun invoke(c: Composer, changed: Int): Any? {
    \\        (c as Recorder).note("<L")
    \\        val r = (block as (Composer, Int) -> Any?)(c, changed)
    \\        c.note(">L")
    \\        return r
    \\    }
    \\}
    \\
    \\@Composable fun rememberComposableLambda(key: Int, tracked: Boolean, block: Any): Any = Memo(key, block)
    \\fun composableLambdaInstance(key: Int, tracked: Boolean, block: Any): Any = Memo(key, block)
    \\
;

test "a composable literal becomes the runtime's composable lambda, remembered in a composable scope" {
    driver.expectOutputOver(&.{ runtime, lambdas,
        \\import androidx.compose.runtime.*
        \\
        \\@Composable fun Leaf(x: Int) { println("leaf " + x) }
        \\@Composable fun Box(content: @Composable () -> Unit) { content() }
        \\@Composable inline fun Column(content: @Composable () -> Unit) { content() }
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) {
        \\        Box { Leaf(1) }
        \\        Column { Leaf(2) }
        \\    }
        \\    println(r.trace)
        \\}
    }, "leaf 1\nleaf 2\n<L <r <L <r >r >L >r <r >r >L\n") catch |e| return skipUnbuilt(e);
}

test "composable calls pass the composer; a restartable composable runs in a restart group" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\@Composable fun Leaf(x: Int) { println("leaf " + x) }
        \\@Composable fun Tree(n: Int) {
        \\    Leaf(n)
        \\    Leaf(n + 1)
        \\}
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) { Tree(1) }
        \\    println(r.trace)
        \\}
    }, "leaf 1\nleaf 2\n<r <r >r <r >r >r\n") catch |e| return skipUnbuilt(e);
}

test "a recompose scope reruns its function and skips the calls whose arguments are unchanged" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\var label = "a"
        \\@Composable fun Leaf(x: Int) { println("leaf " + x) }
        \\@Composable fun Text(s: String) { println("text " + s) }
        \\@Composable fun Tree(n: Int) {
        \\    Leaf(n)
        \\    Text(label)
        \\}
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) { Tree(1) }
        \\    println(r.trace)
        \\    label = "b"
        \\    r.recompose(2)
        \\    println(r.trace)
        \\}
    }, "leaf 1\ntext a\n<r <r >r <r >r >r\ntext b\n<r <r skip >r <r >r >r\n") catch |e| return skipUnbuilt(e);
}

test "a composable lambda takes the composer pair, called through its value or in place" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\@Composable fun Leaf(x: Int) { println("leaf " + x) }
        \\@Composable fun Box(content: @Composable () -> Unit) {
        \\    println("box")
        \\    content()
        \\}
        \\@Composable inline fun Column(content: @Composable () -> Unit) { content() }
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) {
        \\        Box { Leaf(7) }
        \\        Column { Leaf(8) }
        \\    }
        \\    println(r.trace)
        \\}
    }, "box\nleaf 7\nleaf 8\n<r <r >r >r <r >r\n") catch |e| return skipUnbuilt(e);
}

test "a value-returning composable composes in its caller's group, and currentComposer is the scope's composer" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\@Composable fun who(): String = if (currentComposer is Recorder) "recorder" else "other"
        \\val title: String
        \\    @Composable get() = "title from " + who()
        \\@Composable fun Show() { println(title) }
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) { Show() }
        \\    println(r.trace)
        \\}
    }, "title from recorder\n<r >r\n") catch |e| return skipUnbuilt(e);
}

test "branches that compose run in replace groups, a missing else in an empty one" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\@Composable fun Leaf(x: Int) { println("leaf " + x) }
        \\@Composable fun Pick(n: Int) {
        \\    if (n > 0) Leaf(n)
        \\    val tag = if (n > 5) "big" else "small"
        \\    when (n) {
        \\        1 -> Leaf(10)
        \\        2 -> println("two")
        \\    }
        \\    println(tag)
        \\}
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) { Pick(1) }
        \\    println(r.trace)
        \\    val q = Recorder()
        \\    compose(q) { Pick(0) }
        \\    println(q.trace)
        \\}
    }, "leaf 1\nleaf 10\nsmall\n<r <g <r >r >g <g <r >r >g >r\nsmall\n<r <g >g <g >g >r\n") catch |e| return skipUnbuilt(e);
}

test "key composes its block in a movable group keyed by its keys" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\@Composable fun Leaf(x: Int) { println("leaf " + x) }
        \\@Composable fun Items(ids: List<Int>) {
        \\    for (id in ids) {
        \\        key(id) { Leaf(id) }
        \\    }
        \\    key(1, "b") { Leaf(0) }
        \\}
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) { Items(listOf(3, 4)) }
        \\    println(r.trace)
        \\}
    }, "leaf 3\nleaf 4\nleaf 0\n<r <g <m:3 <r >r >m <m:4 <r >r >m >g <m:1+b <r >r >m >r\n") catch |e| return skipUnbuilt(e);
}

test "a loop that composes is grouped when a composable call follows it, and per iteration when it continues" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\@Composable fun Leaf(x: Int) { println("leaf " + x) }
        \\@Composable fun Last(n: Int) {
        \\    for (i in 0 until n) Leaf(i)
        \\}
        \\@Composable fun Before(n: Int) {
        \\    for (i in 0 until n) Leaf(i)
        \\    Leaf(9)
        \\}
        \\@Composable fun Skips(n: Int) {
        \\    var i = 0
        \\    while (i < n) {
        \\        i = i + 1
        \\        if (i == 1) continue
        \\        Leaf(i)
        \\    }
        \\}
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) { Last(1) }
        \\    println(r.trace)
        \\    val q = Recorder()
        \\    compose(q) { Before(1) }
        \\    println(q.trace)
        \\    val w = Recorder()
        \\    compose(w) { Skips(2) }
        \\    println(w.trace)
        \\}
    }, "leaf 0\n<r <r >r >r\nleaf 0\nleaf 9\n<r <g <r >r >g <r >r >r\nleaf 2\n<r <g >g <g >g <g >g <g <r >r >g <g >g >r\n") catch |e| return skipUnbuilt(e);
}

test "a return or a break out of a replace group closes it" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\@Composable fun Leaf(x: Int) { println("leaf " + x) }
        \\@Composable fun Early(n: Int) {
        \\    if (n > 0) {
        \\        Leaf(n)
        \\        return
        \\    }
        \\    Leaf(0)
        \\}
        \\@Composable fun Loop(ids: List<Int>) {
        \\    for (id in ids) {
        \\        if (id == 2) {
        \\            Leaf(id)
        \\            break
        \\        }
        \\    }
        \\}
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) {
        \\        Early(5)
        \\        Loop(listOf(1, 2, 3))
        \\    }
        \\    println(r.trace)
        \\}
    }, "leaf 5\nleaf 2\n<r <g <r >r >g >r <r <g >g <g <r >r >g >r\n") catch |e| return skipUnbuilt(e);
}

test "a call passes what it knows of its arguments: literals static, parameters passed on with their bits" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\@Composable fun Leaf(x: Int) { println("leaf " + x) }
        \\@Composable fun Tree(n: Int) {
        \\    Leaf(1)
        \\    Leaf(n)
        \\}
        \\fun main() {
        \\    val r = Recorder()
        \\    val k = 5
        \\    compose(r) { Tree(k) }
        \\    println(r.slots.size)
        \\}
    }, "leaf 1\nleaf 5\n1\n") catch |e| return skipUnbuilt(e);
}

test "past ten parameters the change bits take a second int, and a parameter passed on from it keeps its bits" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\var tail = 11
        \\@Composable fun Leaf(x: Int) { println("leaf " + x) }
        \\@Composable fun Wide(a0: Int, a1: Int, a2: Int, a3: Int, a4: Int, a5: Int, a6: Int, a7: Int, a8: Int, a9: Int, a10: Int, a11: Int) {
        \\    Leaf(a11)
        \\}
        \\@Composable fun Outer() { Wide(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, tail) }
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) { Outer() }
        \\    println(r.trace)
        \\    r.recompose(2)
        \\    println(r.trace)
        \\    tail = 12
        \\    r.recompose(1)
        \\    println(r.trace)
        \\    r.recompose(1)
        \\    println(r.trace)
        \\}
    }, "leaf 11\n<r <r <r >r >r >r\n<r <r skip >r >r\nleaf 12\n<r <r <r >r >r >r\n<r <r skip >r >r\n") catch |e| return skipUnbuilt(e);
}

test "a parameter the body never reads does not make it run" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\var gen = 0
        \\@Composable fun Item(label: String, generation: Int) { println("item " + label) }
        \\@Composable fun Screen(g: Int) { Item("x", g) }
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) { Screen(gen) }
        \\    println(r.trace)
        \\    gen = 1
        \\    r.recompose(1)
        \\    println(r.trace)
        \\}
    }, "item x\n<r <r >r >r\n<r <r skip >r >r\n") catch |e| return skipUnbuilt(e);
}

test "a composable fills its omitted arguments in its body, and keeps a default that is not static when it recomposes" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\var calls = 0
        \\fun next(): Int { calls = calls + 1; return calls }
        \\@Composable fun Show(label: String = "static", n: Int = next()) { println(label + " " + n) }
        \\@Composable fun Span(a: Int, b: Int = a + 1) { println("" + a + ".." + b) }
        \\@Composable fun Host() {
        \\    Show()
        \\    Span(3)
        \\}
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) { Host() }
        \\    println(r.trace)
        \\    r.recompose(0)
        \\    println(r.trace)
        \\    println(calls)
        \\}
    }, "static 1\n3..4\n<r <r <d >d >r <r <d >d >r >r\nstatic 1\n<r <d skip >d >r\n1\n") catch |e| return skipUnbuilt(e);
}

test "lambdas and fun interface wrappers in a composable scope are remembered over their captures" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\fun interface Act { fun run() }
        \\val seen = ArrayList<Any>()
        \\@Composable fun UseAct(a: Act) { seen.add(a) }
        \\@Composable fun Host(n: Int) {
        \\    val k = remember { n * 10 }
        \\    val lam = { println("lam " + n) }
        \\    seen.add(lam)
        \\    UseAct { println("act") }
        \\    println("k " + k)
        \\}
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) { Host(1) }
        \\    r.recompose(1)
        \\    println(seen.size)
        \\    println(seen[0] === seen[2])
        \\    println(r.trace)
        \\    println(r.slots.size)
        \\}
    }, "k 10\nk 10\n3\ntrue\n<r <r skip >r >r\n4\n") catch |e| return skipUnbuilt(e);
}

test "remember compares its keys, and a lambda in a try is not remembered" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\var key = 1
        \\val seen = ArrayList<Any>()
        \\@Composable fun Keyed() {
        \\    val v = remember(key) { "v" + key }
        \\    println(v)
        \\    val k = key
        \\    try {
        \\        seen.add({ k })
        \\    } catch (e: Exception) {
        \\    }
        \\}
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) { Keyed() }
        \\    key = 2
        \\    r.recompose(0)
        \\    println(seen[0] === seen[1])
        \\}
    }, "v1\nv2\nfalse\n") catch |e| return skipUnbuilt(e);
}

test "an inline call whose literal composes is grouped when a composable call follows it" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\@Composable fun Leaf(x: Int) { println("leaf " + x) }
        \\@Composable fun Rows(n: Int) {
        \\    repeat(n) { Leaf(it) }
        \\    Leaf(9)
        \\}
        \\@Composable fun Tail(n: Int) {
        \\    repeat(n) { Leaf(it) }
        \\}
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) { Rows(1) }
        \\    println(r.trace)
        \\    val q = Recorder()
        \\    compose(q) { Tail(1) }
        \\    println(q.trace)
        \\}
    }, "leaf 0\nleaf 9\n<r <g <r >r >g <r >r >r\nleaf 0\n<r <r >r >r\n") catch |e| return skipUnbuilt(e);
}

test "a non-restartable composable that returns early is a group, and groups every loop directly in it" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\@Composable fun Leaf(x: Int) { println("leaf " + x) }
        \\@Composable @NonRestartableComposable fun Maybe(n: Int) {
        \\    if (n == 0) return
        \\    Leaf(n)
        \\}
        \\@Composable @NonRestartableComposable fun Loop(n: Int) {
        \\    for (i in 0 until n) Leaf(i)
        \\}
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) {
        \\        Maybe(1)
        \\        Maybe(0)
        \\    }
        \\    println(r.trace)
        \\    val q = Recorder()
        \\    compose(q) { Loop(1) }
        \\    println(q.trace)
        \\}
    }, "leaf 1\n<g <r >r >g <g >g\nleaf 0\n<g <r >r >g\n") catch |e| return skipUnbuilt(e);
}

test "a composable literal capturing nothing is one instance, one capturing is remembered per composition" {
    driver.expectOutputOver(&.{ runtime, lambdas,
        \\import androidx.compose.runtime.*
        \\
        \\val seen = ArrayList<Any>()
        \\@Composable fun Box(content: @Composable () -> Unit) { seen.add(content) }
        \\@Composable fun Host(n: Int) {
        \\    Box { }
        \\    Box { println(n) }
        \\}
        \\fun main() {
        \\    compose(Recorder()) { Host(1) }
        \\    compose(Recorder()) { Host(1) }
        \\    println(seen[0] === seen[2])
        \\    println(seen[1] === seen[3])
        \\}
    }, "true\nfalse\n") catch |e| return skipUnbuilt(e);
}

test "a composable lambda skips when it is the same lambda" {
    driver.expectOutputOver(&.{ runtime, lambdas,
        \\import androidx.compose.runtime.*
        \\
        \\@Composable fun Leaf(x: Int) { println("leaf " + x) }
        \\@Composable fun Box(content: @Composable () -> Unit) { content() }
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) { Box { Leaf(1) } }
        \\    println(r.trace)
        \\    r.recompose(1)
        \\    println(r.trace)
        \\}
    }, "leaf 1\n<L <r <L <r >r >L >r >L\n<r <L skip >L >r\n") catch |e| return skipUnbuilt(e);
}

test "a return out of inline composable code ends the groups it opened back to the marker" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\@Composable inline fun Row(content: @Composable () -> Unit) {
        \\    currentComposer.startReplaceGroup(5)
        \\    content()
        \\    currentComposer.endReplaceGroup()
        \\}
        \\@Composable fun Leaf(x: Int) { println("leaf " + x) }
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) {
        \\        Row outer@{
        \\            Row {
        \\                Leaf(1)
        \\                if (r.trace.length > 0) return@outer
        \\                Leaf(2)
        \\            }
        \\            Leaf(3)
        \\        }
        \\        Leaf(4)
        \\    }
        \\    println(r.trace)
        \\    println(r.depth)
        \\}
    }, "leaf 1\nleaf 4\n<g <g <r >r ~1 >g <r >r\n0\n") catch |e| return skipUnbuilt(e);
}

test "an early return leaves the restart group closed" {
    driver.expectOutputOver(&.{ runtime,
        \\import androidx.compose.runtime.*
        \\
        \\@Composable fun Leaf(x: Int) { println("leaf " + x) }
        \\@Composable fun Maybe(show: Boolean) {
        \\    if (!show) return
        \\    Leaf(1)
        \\}
        \\fun main() {
        \\    val r = Recorder()
        \\    compose(r) {
        \\        Maybe(false)
        \\        Maybe(true)
        \\    }
        \\    println(r.trace)
        \\}
    }, "leaf 1\n<r >r <r <r >r >r\n") catch |e| return skipUnbuilt(e);
}
