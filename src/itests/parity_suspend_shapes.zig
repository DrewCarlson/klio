//! Suspend function shapes that drive realistic coroutine code.
const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_suspend_shapes";

// One file-scoped arena: the pipeline installs process-global state backed by
// the run's allocator, which a per-test arena would tear down under it.
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


fn assertKlio(name: []const u8, src: []const u8, expected: []const u8) !void {
    // Reclaim the previous program; the globals live on the page allocator.
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

test "suspend_chain_of_calls" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\suspend fun step1(): Int { delay(2); return 10 }
        \\suspend fun step2(x: Int): Int { delay(2); return x + 5 }
        \\suspend fun step3(x: Int): String { delay(2); return "result=$x" }
        \\fun main() = runBlocking {
        \\    val a = step1()
        \\    val b = step2(a)
        \\    val c = step3(b)
        \\    println(c)
        \\}
        \\
    ;
    try assertKlio("suspend_chain", src, "result=15\n");
}

test "suspend_main_drives_real_delay" {
    // kotlinc wraps `suspend fun main` in `runSuspend`, so `delay` has a
    // driver to park under.
    const src =
        \\
        \\import kotlinx.coroutines.delay
        \\suspend fun compute(): Int { delay(5); return 42 }
        \\suspend fun main() {
        \\    println("start")
        \\    val v = compute()
        \\    println("got $v")
        \\}
        \\
    ;
    try assertKlio("suspend_main_delay", src, "start\ngot 42\n");
}

test "suspend_in_lambda" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\fun main() = runBlocking {
        \\    val results = mutableListOf<Int>()
        \\    for (i in 1..3) {
        \\        launch {
        \\            delay(2)
        \\            results.add(i * 10)
        \\        }
        \\    }
        \\    delay(20)
        \\    results.sort()
        \\    println(results)
        \\}
        \\
    ;
    try assertKlio("suspend_lambda", src, "[10, 20, 30]\n");
}

test "suspend SAM member propagates suspension" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\fun interface SuspendSink {
        \\    suspend fun emit(value: Int)
        \\}
        \\class Source {
        \\    suspend fun collect(sink: SuspendSink) {
        \\        sink.emit(1)
        \\        println("after")
        \\    }
        \\}
        \\fun main() = runBlocking {
        \\    Source().collect { value ->
        \\        delay(1)
        \\        println("value=$value")
        \\    }
        \\}
        \\
    ;
    try assertKlio("suspend_sam_member", src, "value=1\nafter\n");
}

test "suspend_with_try_catch" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\suspend fun risky(n: Int): Int {
        \\    delay(2)
        \\    if (n < 0) throw IllegalArgumentException("neg")
        \\    return n * 2
        \\}
        \\fun main() = runBlocking {
        \\    val a = try { risky(5) } catch (e: IllegalArgumentException) { -1 }
        \\    val b = try { risky(-1) } catch (e: IllegalArgumentException) { -1 }
        \\    println("$a,$b")
        \\}
        \\
    ;
    try assertKlio("suspend_try", src, "10,-1\n");
}

test "async_concurrent_completion" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\fun main() = runBlocking {
        \\    val a = async { delay(5); 1 }
        \\    val b = async { delay(3); 2 }
        \\    val c = async { delay(7); 3 }
        \\    println("${a.await() + b.await() + c.await()}")
        \\}
        \\
    ;
    try assertKlio("async_concurrent", src, "6\n");
}

test "nested_suspend_lambda_capture" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\fun main() = runBlocking {
        \\    val tag = "hello"
        \\    val r = withContext(Dispatchers.Default) {
        \\        delay(2)
        \\        "$tag, world"
        \\    }
        \\    println(r)
        \\}
        \\
    ;
    try assertKlio("withContext", src, "hello, world\n");
}

test "coroutine_returns_through_run_blocking" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\fun compute(): Int = runBlocking {
        \\    val a = async { delay(1); 100 }
        \\    val b = async { delay(1); 200 }
        \\    a.await() + b.await()
        \\}
        \\fun main() { println(compute()) }
        \\
    ;
    try assertKlio("rb_returns", src, "300\n");
}

// A local class's `suspend` method is lowered into its own sub-module, so the
// frame snapshot carries that module: the same `FuncId` index names a
// different function in the main module.
test "local_class_suspend_method_resumes_in_its_module" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\suspend fun runWith(x: Int): String {
        \\    class Worker {
        \\        suspend fun work(n: Int): Int {
        \\            delay(1)
        \\            return n * 2
        \\        }
        \\    }
        \\    return "got=" + Worker().work(x)
        \\}
        \\fun main() = runBlocking { println("result=" + runWith(21)) }
        \\
    ;
    try assertKlio("local_class_suspend_resume", src, "result=got=42\n");
}

test "local class retains transitive interfaces" {
    const src =
        \\
        \\interface Marker
        \\open class Base : Marker
        \\fun main() {
        \\    class Local : Base()
        \\    val value: Any = Local()
        \\    println(value is Base)
        \\    println(value is Marker)
        \\}
        \\
    ;
    try assertKlio("local_class_transitive_interfaces", src, "true\ntrue\n");
}

// An overload delegating through an explicit cast dispatches on the cast
// type: `async(Job)` calls `async(CoroutineContext)`, and re-selecting on the
// still-`Job` runtime value recurses forever.
test "async_job_overload_delegates_without_recursing" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\import kotlin.coroutines.*
        \\interface Snd { suspend fun execute(r: String): String }
        \\class Base : Snd {
        \\    override suspend fun execute(r: String): String {
        \\        val ctx = coroutineContext + Job()
        \\        return coroutineScope { async(ctx) { "E($r)" }.await() }
        \\    }
        \\}
        \\class Inter(val ic: suspend Snd.(String) -> String, val next: Snd) : Snd {
        \\    override suspend fun execute(r: String): String = ic.invoke(next, r)
        \\}
        \\fun main() = runBlocking {
        \\    val s: Snd = Inter({ r -> "R1[" + execute(r) + "]" }, Base())
        \\    println(s.execute("x"))
        \\}
        \\
    ;
    try assertKlio("async_job_overload_delegates", src, "R1[E(x)]\n");
}

// Named imports are file-scoped, so a library file importing
// `ChannelResult.Companion.closed` cannot capture a user's `val closed`.
test "user_property_not_shadowed_by_other_files_named_import" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\import kotlin.coroutines.*
        \\abstract class Base(name: String) : CoroutineScope {
        \\    override val coroutineContext: CoroutineContext by lazy {
        \\        SupervisorJob() + Dispatchers.Unconfined + CoroutineName(name)
        \\    }
        \\    val closed: Boolean get() = false
        \\    suspend fun run1(): String {
        \\        val cc = coroutineContext + Job(coroutineContext[Job])
        \\        return async(cc) { "closed=" + closed }.await()
        \\    }
        \\}
        \\class Impl : Base("impl")
        \\fun main() = runBlocking { println(Impl().run1()) }
        \\
    ;
    try assertKlio("user_prop_not_shadowed", src, "closed=false\n");
}

// A member of the implicit receiver shadows the same-named top-level
// intrinsic, so bare `coroutineContext` here is the receiver's own property,
// not the ambient context. With no such receiver the intrinsic still wins.
test "bare_coroutine_context_in_scope_member_is_own_property" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\import kotlin.coroutines.*
        \\abstract class EngBase(name: String) : CoroutineScope {
        \\    override val coroutineContext: CoroutineContext by lazy {
        \\        SupervisorJob() + Dispatchers.Unconfined + CoroutineName(name)
        \\    }
        \\    private val closed: Boolean get() = !(coroutineContext[Job]?.isActive ?: false)
        \\    abstract suspend fun execute(data: String): String
        \\    suspend fun within(data: String): String {
        \\        val ctx = coroutineContext + Job(coroutineContext[Job])
        \\        return async(ctx) {
        \\            if (closed) throw IllegalStateException("CLOSED")
        \\            execute(data)
        \\        }.await()
        \\    }
        \\}
        \\class Eng : EngBase("eng") {
        \\    override suspend fun execute(data: String): String = "EXEC($data)"
        \\}
        \\fun main() = runBlocking { println(Eng().within("req")) }
        \\
    ;
    try assertKlio("bare_cc_scope_member", src, "EXEC(req)\n");
}

// The implicit-receiver chain travels with a parked continuation: `owned()`
// reaches `this@Owner` only through that chain, being neither the body's
// `this` param nor a capture, and it runs after the park.
test "enclosing_this_chain_survives_suspend" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\class Helper { val hid = "H"; fun localTag() = "helper=$hid" }
        \\class Owner(val oid: String) {
        \\    fun owned() = "owner=$oid"
        \\    suspend fun Helper.process(): String {
        \\        val before = "$hid:${owned()}"
        \\        delay(5)
        \\        return "$before|${localTag()}:${owned()}"
        \\    }
        \\    suspend fun drive(h: Helper) = h.process()
        \\}
        \\fun main() = runBlocking {
        \\    val h = Helper()
        \\    val a = async { Owner("A").drive(h) }
        \\    val b = async { Owner("B").drive(h) }
        \\    println(a.await())
        \\    println(b.await())
        \\    println(Owner("seq").drive(h))
        \\}
        \\
    ;
    try assertKlio(
        "enclosing_this_chain_suspend",
        src,
        "H:owner=A|helper=H:owner=A\nH:owner=B|helper=H:owner=B\nH:owner=seq|helper=H:owner=seq\n",
    );
}

// Outer selection for an `Inner()` built after a park reads the frame's
// `this` param, which the continuation snapshots per coroutine.
test "inner_class_constructed_after_park" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\class Outer(val tag: String) {
        \\    inner class Inner {
        \\        fun show(): String = "outer=" + tag
        \\    }
        \\    suspend fun build(): String {
        \\        delay(5)
        \\        return Inner().show()
        \\    }
        \\}
        \\fun main() = runBlocking {
        \\    val a = async { Outer("A").build() }
        \\    val b = async { Outer("B").build() }
        \\    println(a.await())
        \\    println(b.await())
        \\    println(Outer("seq").build())
        \\}
        \\
    ;
    try assertKlio("inner_after_park", src, "outer=A\nouter=B\nouter=seq\n");
}

// With an unrelated innermost receiver, outer selection keys on Inner's
// enclosing class while `hid` still resolves on the with-subject.
test "inner_class_in_receiver_lambda_after_park" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\class Helper(val hid: String)
        \\class Outer(val tag: String) {
        \\    inner class Inner {
        \\        fun show(): String = "outer=" + tag
        \\    }
        \\    suspend fun buildVia(h: Helper): String {
        \\        delay(5)
        \\        return with(h) { Inner().show() + "+" + hid }
        \\    }
        \\}
        \\fun main() = runBlocking {
        \\    val a = async { Outer("A").buildVia(Helper("x")) }
        \\    val b = async { Outer("B").buildVia(Helper("y")) }
        \\    println(a.await())
        \\    println(b.await())
        \\}
        \\
    ;
    try assertKlio("inner_with_after_park", src, "outer=A+x\nouter=B+y\n");
}

// A sibling `Inner()` takes its outer from the dispatch receiver's own outer
// link; the caller's `with(w)` subject is not in scope inside `sibling()`.
test "sibling_inner_constructed_after_park" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\class Outer(val tag: String) {
        \\    inner class Inner {
        \\        suspend fun sibling(): Inner {
        \\            delay(5)
        \\            return Inner()
        \\        }
        \\        fun show(): String = "outer=" + tag
        \\    }
        \\    fun mk(): Inner = Inner()
        \\}
        \\class Driver(val w: Outer, val inner: Outer.Inner) {
        \\    suspend fun drive(): Outer.Inner = with(w) { inner.sibling() }
        \\}
        \\fun main() = runBlocking {
        \\    val d = Driver(Outer("W"), Outer("A").mk())
        \\    val a = async { d.drive() }
        \\    val b = async { Outer("B").mk().sibling() }
        \\    println(a.await().show())
        \\    println(b.await().show())
        \\}
        \\
    ;
    try assertKlio("inner_sibling_after_park", src, "outer=A\nouter=B\n");
}

// A `suspend Receiver.() -> Unit` parameter called as `b.block()` runs on the
// main evaluator path, so a `delay` in its body snapshots the whole call
// chain rather than reporting a suspension with no driver.
test "receiver_bound_suspend_value_call_parks" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\class Bar(val n: Int)
        \\suspend fun runOn(b: Bar, block: suspend Bar.() -> Unit) { b.block() }
        \\fun main() = runBlocking {
        \\    val acc = StringBuilder()
        \\    runOn(Bar(7)) {
        \\        acc.append("a$n")
        \\        delay(5)
        \\        acc.append("|b$n")
        \\    }
        \\    println(acc.toString())
        \\}
        \\
    ;
    try assertKlio("receiver_bound_suspend_value_call", src, "a7|b7\n");
}

test "suspension survives nested inline lambda forwarding" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\inline fun <reified T> outer(block: () -> Unit) {
        \\    T::class
        \\    middle(block)
        \\}
        \\inline fun middle(block: () -> Unit) = leaf(block)
        \\inline fun leaf(block: () -> Unit) = block()
        \\fun main() = runBlocking {
        \\    outer<String> {
        \\        print("before;")
        \\        delay(1)
        \\        println("after;")
        \\    }
        \\    println("done;")
        \\}
        \\
    ;
    try assertKlio("nested_inline_suspend_forward", src, "before;after;\ndone;\n");
}

test "suspension survives host-backed inline lambda forwarding" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\inline fun <reified T> capture(block: () -> Unit): Result<Unit> {
        \\    T::class
        \\    return runCatching(block)
        \\}
        \\fun main() = runBlocking {
        \\    val result = capture<String> {
        \\        print("before;")
        \\        delay(1)
        \\        println("after;")
        \\    }
        \\    println("success=" + result.isSuccess)
        \\}
        \\
    ;
    try assertKlio(
        "host_backed_inline_suspend_forward",
        src,
        "before;after;\nsuccess=true\n",
    );
}

test "receiver_bound_suspend_value_call_multi_park" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\class Bar(val n: Int)
        \\suspend fun runOn(b: Bar, block: suspend Bar.() -> Unit) { b.block() }
        \\fun main() = runBlocking {
        \\    val acc = StringBuilder()
        \\    runOn(Bar(7)) {
        \\        acc.append("a$n")
        \\        delay(5)
        \\        acc.append("|b$n")
        \\        delay(3)
        \\        acc.append("|c$n")
        \\    }
        \\    println(acc.toString())
        \\}
        \\
    ;
    try assertKlio("receiver_bound_suspend_value_call_multi", src, "a7|b7|c7\n");
}

test "receiver_bound_suspend_value_call_interleaved_async" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\class Bar(val n: Int)
        \\suspend fun runOn(b: Bar, block: suspend Bar.() -> String): String = b.block()
        \\fun main() = runBlocking {
        \\    val a = async {
        \\        runOn(Bar(1)) {
        \\            val before = "a$n"
        \\            delay(10)
        \\            "$before|b$n"
        \\        }
        \\    }
        \\    val b = async {
        \\        runOn(Bar(2)) {
        \\            val before = "a$n"
        \\            delay(5)
        \\            "$before|b$n"
        \\        }
        \\    }
        \\    println(a.await())
        \\    println(b.await())
        \\}
        \\
    ;
    try assertKlio(
        "receiver_bound_suspend_value_call_interleaved",
        src,
        "a1|b1\na2|b2\n",
    );
}

test "manual_continuation_slot_park_and_resume" {
    // The ByteChannel slot wakeup protocol in miniature, including the
    // in-block immediate-resume race and the no-park path.
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\import kotlin.coroutines.Continuation
        \\
        \\class MiniChannel {
        \\    private var slot: Continuation<Unit>? = null
        \\    private var data = ""
        \\    private var closed = false
        \\
        \\    suspend fun awaitContent() {
        \\        while (data.isEmpty() && !closed) {
        \\            suspendCancellableCoroutine { cont ->
        \\                slot = cont
        \\                if (!(data.isEmpty() && !closed)) {
        \\                    slot = null
        \\                    cont.resumeWith(Result.success(Unit))
        \\                }
        \\            }
        \\        }
        \\    }
        \\
        \\    fun send(text: String) {
        \\        data += text
        \\        val c = slot
        \\        slot = null
        \\        c?.resumeWith(Result.success(Unit))
        \\    }
        \\
        \\    fun close() {
        \\        closed = true
        \\        val c = slot
        \\        slot = null
        \\        c?.resumeWith(Result.success(Unit))
        \\    }
        \\
        \\    fun take(): String {
        \\        val d = data
        \\        data = ""
        \\        return d
        \\    }
        \\}
        \\
        \\fun main() = runBlocking {
        \\    val ch = MiniChannel()
        \\    val reader = launch {
        \\        println("reader: waiting")
        \\        ch.awaitContent()
        \\        println("reader: got=" + ch.take())
        \\        ch.awaitContent()
        \\        println("reader: closed=" + ch.take() + ".")
        \\    }
        \\    delay(5)
        \\    println("writer: send")
        \\    ch.send("ping")
        \\    delay(5)
        \\    ch.close()
        \\    reader.join()
        \\    val ch2 = MiniChannel()
        \\    ch2.send("pre")
        \\    ch2.awaitContent()
        \\    println("main: got=" + ch2.take())
        \\    println("done")
        \\}
        \\
    ;
    try assertKlio(
        "manual_continuation_slot_park_and_resume",
        src,
        "reader: waiting\nwriter: send\nreader: got=ping\nreader: closed=.\nmain: got=pre\ndone\n",
    );
}
