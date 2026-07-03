//! Threaded-litmus suite. Each program in the litmus directory pins down one
//! observable guarantee of multi-threaded execution (mutual exclusion,
//! publication, no lost update). Expected stdout is encoded as leading `//> `
//! comment lines, exactly like the memory-model `conformance` suite.
//!
//! Programs assert exact stdout (`RUNNABLE`); the genuinely parallel
//! ones run on real OS threads — via `kotlin.concurrent.thread` or the
//! shared dispatcher worker pool behind `Dispatchers.Default`/`IO`
//! (wall-time overlap, worker thread names, cross-pump park/resume,
//! `limitedParallelism`, and the elastic IO cap are each pinned by a
//! fixture). A program expected to FAIL — an uncaught exception crossing
//! the dispatcher boundary must crash the run, exactly as kotlinc+kotlinx
//! crash the JVM — pins the failure with a leading `//>! substring`
//! comment instead: the run must end in an error whose message contains
//! every such substring. Programs blocked on a missing capability are
//! listed in `PENDING`, keyed by the blocker, and run by an ignored test
//! until it lands.
//! Run with `KLIO_RACE_JITTER=1` to widen borrow interleavings so a
//! lost-update or double-init race reproduces reliably.
const std = @import("std");
const parity = @import("parity");
const runtime = @import("runtime");

/// The litmus corpus directory, relative to the workspace root (cwd).
const LITMUS_DIR = "tests/fixtures/threaded_litmus";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const Expectation = struct {
    /// Exact expected stdout (the `//> ` lines).
    stdout: []u8,
    /// Substrings the run's terminal error must contain (the `//>! `
    /// lines). Non-empty ⇒ the program must FAIL.
    err_contains: [][]u8,
};

/// Expected outcome = the leading run of `//> ` comment lines (one
/// stdout line each, matching `runWithPacks`'s join convention) and/or
/// `//>! ` lines (error-message substrings; their presence makes the
/// expectation "the run fails"). Mirrors the `conformance` harness.
/// Returns owned bytes.
fn expectedOutcome(allocator: std.mem.Allocator, io: std.Io, file: []const u8) !Expectation {
    const src = try std.Io.Dir.cwd().readFileAlloc(io, file, allocator, .unlimited);
    defer allocator.free(src);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var errs: std.ArrayList([]u8) = .empty;
    defer errs.deinit(allocator);
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trimStart(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "//>!")) {
            var rest = t[4..];
            if (rest.len != 0 and rest[0] == ' ') rest = rest[1..];
            rest = std.mem.trimEnd(u8, rest, "\r");
            try errs.append(allocator, try allocator.dupe(u8, rest));
        } else if (std.mem.startsWith(u8, t, "//>")) {
            var rest = t[3..];
            if (rest.len != 0 and rest[0] == ' ') rest = rest[1..];
            // Strip a trailing CR left by the `\n` split on CRLF input.
            rest = std.mem.trimEnd(u8, rest, "\r");
            try out.appendSlice(allocator, rest);
            try out.append(allocator, '\n');
        } else if (std.mem.startsWith(u8, t, "//") or (out.items.len == 0 and errs.items.len == 0)) {
            // Skip leading comments and blank lead-in.
        } else {
            break;
        }
    }
    return .{
        .stdout = try out.toOwnedSlice(allocator),
        .err_contains = try errs.toOwnedSlice(allocator),
    };
}

fn check(stem: []const u8) !void {
    // Reset the per-program arena so each program's ASTs/IR/packs/VM graph
    // is reclaimed instead of accumulating across this file's tests. Safe:
    // the cross-program globals are page_allocator-backed, not this arena.
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const file = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ LITMUS_DIR, stem });
    const st = std.Io.Dir.cwd().statFile(io, file, .{}) catch {
        std.debug.print("missing litmus {s}\n", .{file});
        return error.MissingLitmus;
    };
    if (st.kind != .file) {
        std.debug.print("missing litmus {s}\n", .{file});
        return error.MissingLitmus;
    }
    const want = try expectedOutcome(a, io, file);
    if (want.stdout.len == 0 and want.err_contains.len == 0) {
        std.debug.print("no //> expected lines in {s}\n", .{stem});
        return error.NoExpectedLines;
    }
    const res = try parity.runWithPacks(a, io, file);
    if (want.err_contains.len != 0) {
        // Failure pin: the run must end in an error carrying every
        // expected substring (an uncaught exception crossing the
        // dispatcher boundary crashes the run, as kotlinc+kotlinx do).
        switch (res) {
            .ok => |got| {
                std.debug.print("threaded litmus {s}: expected a failing run, got success with stdout:\n{s}\n", .{ stem, got });
                return error.ExpectedFailureSucceeded;
            },
            .err => |m| {
                for (want.err_contains) |needle| {
                    if (std.mem.indexOf(u8, m, needle) == null) {
                        std.debug.print("threaded litmus {s}: error message missing `{s}`\n got: {s}\n", .{ stem, needle, m });
                        return error.ErrorMessageMismatch;
                    }
                }
            },
        }
        return;
    }
    switch (res) {
        .ok => |got| std.testing.expectEqualStrings(want.stdout, got) catch |e| {
            std.debug.print("threaded litmus {s}: stdout mismatch\n got: {s}\nwant: {s}\n", .{ stem, got, want.stdout });
            return e;
        },
        .err => |m| {
            std.debug.print("threaded litmus {s}: klio error: {s}\n", .{ stem, m });
            return error.KlioRunFailed;
        },
    }
}

/// Guarantees enforced now, on real OS threads.
const RUNNABLE = [_][]const u8{
    "tl_smoke",
    "tl_thread_join",
    "tl_sync_counter",
    "tl_parallel_partition",
    "tl_async_parallel",
    "tl_withcontext_io",
    "tl_dispatch_many",
    "tl_thread_sleep",
    "tl_wakeup_hammer",
    "tl_atomicfu_long_workers",
    "tl_atomicfu_cas_once",
    "tl_atomicfu_ref_cas",
    "tl_atomicfu_lock_mutex",
    "tl_lazy_once",
    "tl_default_parallel_wall",
    "tl_dispatch_thread_names",
    "tl_spin_handoff",
    "tl_io_elastic",
    "tl_limited_one",
    "tl_withcontext_io_from_default",
    "tl_delay_on_worker",
    "tl_runblocking_undispatched",
    "tl_channel_cross_dispatcher",
    "tl_thread_channel_bridge",
    "tl_dispatched_failure_join",
    "tl_dispatched_failure_no_join",
    "tl_dispatched_failure_caught",
    "tl_cancel_dispatched_child",
    "tl_cancel_sibling_plain",
    "tl_cancel_sibling_after_scope",
    "tl_cancel_root_not_independent",
    "tl_runblocking_on_worker",
    "tl_thread_resume_child",
    "tl_daemon_not_awaited",
    "tl_daemon_queued_dropped",
    "tl_daemon_infinite_abandoned",
    "tl_withcontext_noncancellable",
    "tl_cancel_via_coroutine_context",
    "tl_independent_awaited_completes",
    "tl_runblocking_worker_visibility",
    "tl_early_error_with_thread",
};

/// Guarantees that only become meaningful with real OS-thread spawning.
/// `(stem, blocker)`. Each moves into `RUNNABLE` when its blocker lands.
/// Empty today: the threaded corpus grows here.
const PENDING = [_]struct { stem: []const u8, blocker: []const u8 }{
    // .{ .stem = "tl_two_thread_monitor", .blocker = "needs real thread spawn" },
    // .{ .stem = "tl_safe_publication", .blocker = "needs real thread spawn" },
};

// Each litmus stem is its own `test` so they run as separate cases.
test "tl_smoke" {
    try check("tl_smoke");
}
test "tl_thread_join" {
    try check("tl_thread_join");
}
test "tl_sync_counter" {
    try check("tl_sync_counter");
}
test "tl_parallel_partition" {
    try check("tl_parallel_partition");
}
test "tl_async_parallel" {
    try check("tl_async_parallel");
}
test "tl_withcontext_io" {
    try check("tl_withcontext_io");
}
test "tl_dispatch_many" {
    try check("tl_dispatch_many");
}
test "tl_thread_sleep" {
    try check("tl_thread_sleep");
}
test "tl_wakeup_hammer" {
    try check("tl_wakeup_hammer");
}
test "tl_atomicfu_long_workers" {
    try check("tl_atomicfu_long_workers");
}
test "tl_atomicfu_cas_once" {
    try check("tl_atomicfu_cas_once");
}
test "tl_atomicfu_ref_cas" {
    try check("tl_atomicfu_ref_cas");
}
test "tl_atomicfu_lock_mutex" {
    try check("tl_atomicfu_lock_mutex");
}
test "tl_lazy_once" {
    try check("tl_lazy_once");
}
test "tl_default_parallel_wall" {
    try check("tl_default_parallel_wall");
}
test "tl_dispatch_thread_names" {
    try check("tl_dispatch_thread_names");
}
test "tl_spin_handoff" {
    try check("tl_spin_handoff");
}
test "tl_io_elastic" {
    try check("tl_io_elastic");
}
test "tl_limited_one" {
    try check("tl_limited_one");
}
test "tl_withcontext_io_from_default" {
    try check("tl_withcontext_io_from_default");
}
test "tl_delay_on_worker" {
    try check("tl_delay_on_worker");
}
test "tl_runblocking_undispatched" {
    try check("tl_runblocking_undispatched");
}
test "tl_channel_cross_dispatcher" {
    try check("tl_channel_cross_dispatcher");
}
test "tl_thread_channel_bridge" {
    try check("tl_thread_channel_bridge");
}
test "tl_dispatched_failure_join" {
    try check("tl_dispatched_failure_join");
}
test "tl_dispatched_failure_no_join" {
    try check("tl_dispatched_failure_no_join");
}
test "tl_dispatched_failure_caught" {
    try check("tl_dispatched_failure_caught");
}
test "tl_cancel_dispatched_child" {
    try check("tl_cancel_dispatched_child");
}
test "tl_cancel_sibling_plain" {
    try check("tl_cancel_sibling_plain");
}
test "tl_cancel_sibling_after_scope" {
    try check("tl_cancel_sibling_after_scope");
}
test "tl_cancel_root_not_independent" {
    try check("tl_cancel_root_not_independent");
}
test "tl_runblocking_on_worker" {
    try check("tl_runblocking_on_worker");
}
test "tl_thread_resume_child" {
    try check("tl_thread_resume_child");
}
test "tl_daemon_not_awaited" {
    try check("tl_daemon_not_awaited");
}
test "tl_daemon_queued_dropped" {
    try check("tl_daemon_queued_dropped");
}
test "tl_daemon_infinite_abandoned" {
    try check("tl_daemon_infinite_abandoned");
}
test "tl_withcontext_noncancellable" {
    try check("tl_withcontext_noncancellable");
}
test "tl_cancel_via_coroutine_context" {
    try check("tl_cancel_via_coroutine_context");
}
test "tl_independent_awaited_completes" {
    try check("tl_independent_awaited_completes");
}
test "tl_runblocking_worker_visibility" {
    try check("tl_runblocking_worker_visibility");
}
test "tl_early_error_with_thread" {
    try check("tl_early_error_with_thread");
}

// Continuously exercise the cross-thread `DriverWakeup` escape seam: a
// batch of `Dispatchers.Default` jobs route their completion resume
// through the single driver's wakeup mailbox (the global `SlotOwners`
// registry escape) while the driver pump drains it concurrently. Looped so
// a borrow-ordering regression on the wakeup cell as it escapes to a worker
// thread aborts here instead of flaking through. `tl_wakeup_hammer` itself
// launches 60 in-flight awaits over 20 rounds per run.
test "tl_wakeup_hammer repeated stress" {
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        try check("tl_wakeup_hammer");
    }
}

// Every litmus file on disk is classified exactly once. Guards against an
// orphaned or unlisted program slipping in.
test "threaded_litmus_suite_is_complete" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var on_disk: std.ArrayList([]const u8) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, LITMUS_DIR, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".kt")) continue;
        const stem = entry.name[0 .. entry.name.len - ".kt".len];
        try on_disk.append(a, try a.dupe(u8, stem));
    }
    std.mem.sort([]const u8, on_disk.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);

    var classified: std.ArrayList([]const u8) = .empty;
    for (RUNNABLE) |s| try classified.append(a, s);
    for (PENDING) |p| try classified.append(a, p.stem);
    std.mem.sort([]const u8, classified.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);

    try std.testing.expectEqual(classified.items.len, on_disk.items.len);
    for (on_disk.items, classified.items) |d, c| {
        std.testing.expectEqualStrings(c, d) catch |e| {
            std.debug.print("every threaded_litmus/*.kt must be in RUNNABLE or PENDING exactly once\n", .{});
            return e;
        };
    }
}

// The eager pipeline is a fidelity upgrade, never a behavior change: the
// same program produces byte-identical output with and without
// KLIO_EAGER=1 (typeck ahead of lowering + the identity-channel records).
test "eager pipeline output parity" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const al = arena.allocator();
    var threaded: std.Io.Threaded = .init(al, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const src =
        "fun pick(x: Int): String = \"int:\" + x\n" ++
        "fun pick(x: String): String = \"string:\" + x\n" ++
        "fun <T> pick(x: List<T>): String = \"list:\" + x.size\n" ++
        "fun main() {\n" ++
        "    println(pick(42))\n" ++
        "    println(pick(\"y\"))\n" ++
        "    println(pick(listOf(1, 2)))\n" ++
        "}\n";
    std.Io.Dir.cwd().createDirPath(io, "/tmp/klio_eager_itest") catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "/tmp/klio_eager_itest/e1.kt", .data = src }) catch return error.WriteFailed;

    var env = std.process.Environ.Map.init(al);
    runtime.procEnvPutAllInto(al, &env);
    const bin = env.get("KLIO_ITEST_BIN") orelse "zig-out/bin/klio";
    const lazy = std.process.run(al, io, .{
        .argv = &.{ bin, "run", "/tmp/klio_eager_itest/e1.kt" },
        .environ_map = &env,
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(120_000), .clock = .awake } },
    }) catch return error.SpawnFailed;
    try env.put("KLIO_EAGER", "1");
    const eager = std.process.run(al, io, .{
        .argv = &.{ bin, "run", "/tmp/klio_eager_itest/e1.kt" },
        .environ_map = &env,
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(120_000), .clock = .awake } },
    }) catch return error.SpawnFailed;
    try std.testing.expectEqualStrings("int:42\nstring:y\nlist:2\n", lazy.stdout);
    try std.testing.expectEqualStrings(lazy.stdout, eager.stdout);
}
