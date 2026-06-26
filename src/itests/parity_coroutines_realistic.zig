//! Realistic coroutine shapes drawn from kotlinx-coroutines patterns:
//! cancellation race, supervisorScope, async with explicit start, channels,
//! flow collection, parallel decomposition. Port of
//! the Rust suite.

const std = @import("std");
const parity = @import("parity");

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

/// Write `src` to a unique temp `.kt` path under a per-file dir and return it.
fn writeSrc(a: std.mem.Allocator, io: std.Io, name: []const u8, src: []const u8) ![]const u8 {
    const dir = "/tmp/klio_coroutines_realistic";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const file = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ dir, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = src });
    return file;
}

fn assertKlio(name: []const u8, src: []const u8, want: []const u8) !void {
    // Reset the per-program arena so each program's ASTs/IR/packs/VM graph
    // is reclaimed instead of accumulating across this file's tests. Safe:
    // the cross-program globals are page_allocator-backed, not this arena.
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const file = try writeSrc(a, io, name, src);
    const res = try parity.runWithPacks(a, io, file);
    switch (res) {
        .ok => |got| try std.testing.expectEqualStrings(want, got),
        .err => |m| {
            std.debug.print("klio run failed for `{s}`: {s}\n", .{ name, m });
            return error.KlioRunFailed;
        },
    }
}

test "launch_join_sequencing" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\fun main() = runBlocking {
        \\    val sb = StringBuilder()
        \\    val j = launch { delay(5); sb.append("inner;") }
        \\    sb.append("outer;")
        \\    j.join()
        \\    sb.append("done;")
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("launch_join", src, "outer;inner;done;\n");
}

test "async_await_value" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\fun main() = runBlocking {
        \\    val a = async { delay(5); 6 }
        \\    val b = async { delay(3); 7 }
        \\    println(a.await() * b.await())
        \\}
        \\
    ;
    try assertKlio("async_await", src, "42\n");
}

test "async_coroutine_carries_active_job_in_context" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\fun main() = runBlocking {
        \\    val d = async {
        \\        val job = coroutineContext[Job]
        \\        "present=${job != null} active=${job?.isActive}"
        \\    }
        \\    println(d.await())
        \\}
        \\
    ;
    try assertKlio("async_job_in_context", src, "present=true active=true\n");
}

test "cancellation_propagates_to_children" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\fun main() = runBlocking {
        \\    val sb = StringBuilder()
        \\    val parent = launch {
        \\        launch { try { delay(1000) } catch (e: CancellationException) { sb.append("c1;") } }
        \\        launch { try { delay(1000) } catch (e: CancellationException) { sb.append("c2;") } }
        \\        try { delay(1000) } catch (e: CancellationException) { sb.append("p;") }
        \\    }
        \\    delay(10)
        \\    parent.cancel()
        \\    parent.join()
        \\    println(sb)
        \\}
        \\
    ;
    // Order of c1;c2;p; is unspecified — accept any permutation by sorting.
    // Reset the per-program arena so each program's ASTs/IR/packs/VM graph
    // is reclaimed instead of accumulating across this file's tests. Safe:
    // the cross-program globals are page_allocator-backed, not this arena.
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const file = try writeSrc(a, io, "cancel_children", src);
    const res = try parity.runWithPacks(a, io, file);
    const raw = switch (res) {
        .ok => |got| got,
        .err => |m| {
            std.debug.print("run failed: {s}\n", .{m});
            return error.KlioRunFailed;
        },
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, trimmed, ';');
    while (it.next()) |s| {
        if (s.len != 0) try parts.append(a, s);
    }
    std.mem.sort([]const u8, parts.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    const joined = try std.mem.join(a, ";", parts.items);
    try std.testing.expectEqualStrings("c1;c2;p", joined);
}

test "coroutine_with_finally_cleanup" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\fun main() = runBlocking {
        \\    val sb = StringBuilder()
        \\    val j = launch {
        \\        try { delay(1000) } finally { sb.append("clean;") }
        \\    }
        \\    delay(10); j.cancel(); j.join()
        \\    sb.append("after;")
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("co_finally", src, "clean;after;\n");
}

test "yield_interleaving" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\fun main() = runBlocking {
        \\    val sb = StringBuilder()
        \\    val a = launch { for (i in 1..3) { sb.append("a$i;"); yield() } }
        \\    val b = launch { for (i in 1..3) { sb.append("b$i;"); yield() } }
        \\    a.join(); b.join()
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("yield_interleave", src, "a1;b1;a2;b2;a3;b3;\n");
}

test "nested_run_blocking_returns_value" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\fun compute(): Int = runBlocking {
        \\    delay(2)
        \\    val n = async { delay(1); 21 }
        \\    n.await() * 2
        \\}
        \\fun main() { println(compute()) }
        \\
    ;
    try assertKlio("nested_run_blocking", src, "42\n");
}

test "coroutine_scope_block" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\fun main() = runBlocking {
        \\    val r = coroutineScope {
        \\        val a = async { delay(2); 1 }
        \\        val b = async { delay(3); 2 }
        \\        a.await() + b.await()
        \\    }
        \\    println(r)
        \\}
        \\
    ;
    try assertKlio("co_scope", src, "3\n");
}

test "channel_send_receive" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\import kotlinx.coroutines.channels.*
        \\fun main() = runBlocking {
        \\    val ch = Channel<Int>(1)
        \\    launch { ch.send(7); ch.send(8); ch.close() }
        \\    val a = ch.receive()
        \\    val b = ch.receive()
        \\    println("$a,$b")
        \\}
        \\
    ;
    try assertKlio("channel", src, "7,8\n");
}

test "launch_in_repeat_resolves_enclosing_it" {
    // `launch { ch.send(it) }` is a receiver lambda (`suspend
    // CoroutineScope.() -> Unit`) with no `it` of its own, so `it` resolves
    // to the enclosing `repeat` lambda's index — kotlinc prints [0, 1, 2].
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\import kotlinx.coroutines.channels.*
        \\fun main() = runBlocking {
        \\    val ch = Channel<Int>(3)
        \\    repeat(3) { launch { ch.send(it) } }
        \\    val got = mutableListOf<Int>()
        \\    repeat(3) { got.add(ch.receive()) }
        \\    got.sort()
        \\    println(got)
        \\}
        \\
    ;
    try assertKlio("launch_in_repeat_it", src, "[0, 1, 2]\n");
}

test "with_timeout_or_null_returns_value_within_budget_and_null_on_expiry" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\fun main() = runBlocking {
        \\    val r = withTimeoutOrNull(100) { delay(5); "done" }
        \\    val r2 = withTimeoutOrNull(5) { delay(50); "done2" }
        \\    println("$r,$r2")
        \\}
        \\
    ;
    try assertKlio("with_timeout_or_null", src, "done,null\n");
}

test "cancel_during_delay_throws_cancellation_exception_into_body" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\fun main() = runBlocking {
        \\    val sb = StringBuilder()
        \\    val j = launch {
        \\        try { delay(1000); sb.append("normal;") }
        \\        catch (e: CancellationException) { sb.append("c;") }
        \\        finally { sb.append("f;") }
        \\    }
        \\    delay(10); j.cancel(); j.join()
        \\    sb.append("done")
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("cancel_in_delay_catch_finally", src, "c;f;done\n");
}

test "channel_for_loop_iterates_via_iterator" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\import kotlinx.coroutines.channels.*
        \\fun main() = runBlocking {
        \\    val ch = Channel<Int>()
        \\    launch {
        \\        for (i in 1..3) ch.send(i)
        \\        ch.close()
        \\    }
        \\    val sb = StringBuilder()
        \\    for (v in ch) sb.append("$v;")
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("channel_for_loop", src, "1;2;3;\n");
}

test "channel_buffered_send_receive_pairs" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\import kotlinx.coroutines.channels.*
        \\fun main() = runBlocking {
        \\    val ch = Channel<String>(2)
        \\    launch {
        \\        ch.send("a")
        \\        ch.send("b")
        \\        ch.send("c")
        \\        ch.close()
        \\    }
        \\    val sb = StringBuilder()
        \\    for (v in ch) sb.append(v)
        \\    println(sb)
        \\}
        \\
    ;
    try assertKlio("channel_buffered", src, "abc\n");
}

// A bare `coroutineContext` inside an extension of a `CoroutineScope` reads the
// receiver's own stored context (the member shadows the ambient intrinsic), not
// the running coroutine's context.
test "coroutine_scope_extension_reads_receiver_context" {
    const src =
        \\
        \\import kotlinx.coroutines.CoroutineName
        \\import kotlinx.coroutines.CoroutineScope
        \\import kotlinx.coroutines.runBlocking
        \\import kotlin.coroutines.CoroutineContext
        \\
        \\class Holder(override val coroutineContext: CoroutineContext) : CoroutineScope
        \\
        \\fun Holder.tagName(): String = coroutineContext[CoroutineName]?.name ?: "none"
        \\
        \\fun main() = runBlocking {
        \\    val h = Holder(CoroutineName("held"))
        \\    println(h.tagName())
        \\    println(coroutineContext[CoroutineName]?.name ?: "ambient-none")
        \\}
        \\
    ;
    try assertKlio("scope_extension_context", src, "held\nambient-none\n");
}

// `select { }` over channel clauses: a buffered `onReceive` is ready and wins
// over an empty channel's clause in biased registration order. The selected
// clause's block runs with the received value.
test "select_onreceive_ready_clause_wins" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\import kotlinx.coroutines.channels.*
        \\import kotlinx.coroutines.selects.*
        \\fun main() = runBlocking {
        \\    val a = Channel<Int>(1)
        \\    val b = Channel<Int>(1)
        \\    a.send(7)
        \\    val r = select<String> {
        \\        a.onReceive { "a=$it" }
        \\        b.onReceive { "b=$it" }
        \\    }
        \\    println(r)
        \\}
        \\
    ;
    try assertKlio("select_onreceive_ready", src, "a=7\n");
}

// `onTimeout(0)` is selected immediately when no other clause is ready.
test "select_ontimeout_zero_is_immediate" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\import kotlinx.coroutines.channels.*
        \\import kotlinx.coroutines.selects.*
        \\fun main() = runBlocking {
        \\    val empty = Channel<Int>(1)
        \\    val r = select<String> {
        \\        empty.onReceive { "received $it" }
        \\        onTimeout(0) { "timeout" }
        \\    }
        \\    println(r)
        \\}
        \\
    ;
    try assertKlio("select_ontimeout_zero", src, "timeout\n");
}

// A binary `Semaphore` serializes two `launch` coroutines through
// `withPermit` under contention: the second acquirer suspends until the first
// releases, so both critical sections run exactly once and the permit is
// returned at the end.
test "semaphore_withpermit_serializes_under_contention" {
    const src =
        \\
        \\import kotlinx.coroutines.*
        \\import kotlinx.coroutines.sync.*
        \\fun main() = runBlocking {
        \\    val sem = Semaphore(1)
        \\    val order = mutableListOf<Int>()
        \\    val jobs = (1..2).map { i ->
        \\        launch { sem.withPermit { order.add(i) } }
        \\    }
        \\    jobs.forEach { it.join() }
        \\    println("permits=${sem.availablePermits} ran=${order.size}")
        \\}
        \\
    ;
    try assertKlio("semaphore_contention", src, "permits=1 ran=2\n");
}
