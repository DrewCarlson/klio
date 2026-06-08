//! Suspend function shapes that drive realistic coroutine code.
//!
//! Port of the Rust suite.
const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_suspend_shapes";

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

// A `suspend` method of a *local class* (lowered into its own per-method
// sub-module) parks at a `delay` and resumes correctly. The frame
// snapshot records which module the method was lowered into, so resume
// resolves its `FuncId` against that sub-module rather than the main
// module (where the same index is a different function — which fed the
// resumed value back garbage). Nested-`private`-class methods (ktor's
// `HttpSend.DefaultSender`) take the same per-method sub-module path.
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

// A deprecated overload that delegates to the general one via an
// explicit cast — kotlinx.coroutines' `async(context: Job, …) =
// async(context as CoroutineContext, …)` — must reach the general
// `async(CoroutineContext)` overload, not re-select the `Job` overload
// (the runtime value is still a `Job`) and recurse forever. Here the
// receiver-lambda `ic.invoke(next, r)` calls a suspend method whose body
// is `async(coroutineContext + Job()) { … }.await()`, exercising the
// delegation through the real coroutines library.
test "async_job_overload_delegates_without_recursing" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\import kotlin.coroutines.*
        \\interface Snd { suspend fun execute(r: String): String }
        \\class Base : Snd {
        \\    override suspend fun execute(r: String): String {
        \\        val ctx = coroutineContext + Job()
        \\        return async(ctx) { "E($r)" }.await()
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

// A bare name inside a `CoroutineScope`-receiver block must resolve to
// the enclosing class's own property, not to a same-named member that a
// *different* library file imported. kotlinx.coroutines' BufferedChannel
// does `import …ChannelResult.Companion.closed`; a global import table
// leaked that `closed` into every file, so a user `val closed` read in
// an `async { … }` block was rewritten to the `ChannelResult` companion
// access and mis-dispatched. Named imports are file-scoped.
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

// A bare `coroutineContext` inside a member/extension of a
// `CoroutineScope` is that receiver's own property — a member of the
// implicit receiver shadows the top-level suspend `coroutineContext`
// intrinsic. ktor's `HttpClientEngine.closed` reads
// `coroutineContext[Job]?.isActive` on the engine's own supervisor; if
// it instead saw the ambient runBlocking context the engine would look
// permanently closed. A bare intrinsic in a plain suspend fn (no such
// receiver, e.g. `yield()`) still resolves to the running context.
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
