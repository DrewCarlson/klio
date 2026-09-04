//! Run androidx.collection's own `commonTest` sources through `klio test`
//! against the installed `androidx.collection` pack.
//!
//! The whole common test tree is discovered automatically. Files without
//! `@Test` are shared fixtures (the value-class templates, ignore-target
//! helpers) compiled into every test file's module. The androidx pack and its
//! deps (`kotlinx.atomicfu`, `kotlin.test`) are built + installed first.
//!
//! Several files contain a 1M-iteration `insertManyRemoveMany` stress test that
//! the interpreter cannot yet finish inside the per-file timeout; such a file is
//! killed before printing its summary, so the suite counts per-test `PASSED`
//! lines (a strict lower bound that survives a mid-file hang) rather than the
//! summary. The total must stay at or above a ratchet baseline; raise it as the
//! static-dispatch work speeds the stress loops up, never lower it.

const std = @import("std");
const census_support = @import("commontest_support.zig");
const runtime = @import("runtime");

/// Minimum number of androidx commonTest cases that must pass. A ratchet: bump
/// it up as fixes land (and as the stress loops get fast enough to complete),
/// never down.
///
/// Raised 560 -> 1250 once the suite could actually run. The old figure was
/// never enforced: the sparse checkout omitted `commonTest`, so `TEST_ROOT`
/// was missing and the whole suite took the skip path. First real measurement:
/// 1309 passed, 15 failed, 9 did not complete across 39 files. The floor sits
/// below the measurement because a file killed mid-run keeps only the passes
/// it had already printed, so the total moves with how many stress loops
/// finish: 1275 passes at 10 did-not-complete, 1547 at 5. The floor stays at
/// the low-water mark rather than the best run.
// 1250 -> 1560. ValueClassListTest no longer hangs: a bare `forEachIndexed`
// inside `buildString { … }` bound `CharSequence.forEachIndexed` and iterated
// the builder its own body was appending to. The suite now reports 1841
// passed, 0 failed, 0 did not complete — previously 1500/0 with 6 classes
// timing out, which is how a real failure hid behind a green ceiling.
const BASELINE: usize = 1841; // tightened 2026-09-01: 1841/0 across five consecutive full stacks

/// Ceiling on failing cases, the mirror of `BASELINE`. 15 -> 4 -> 0 as two
/// resolution roots closed: overloaded inline extensions no longer bind by
/// call shape alone (that took fourteen failures, the whole of
/// `IndexBasedArrayIteratorTest` and `ArraySetTest`), and a call carrying
/// explicit type arguments no longer binds a same-named member that declares
/// none (the last two, `ObjectIntTest`/`ObjectLongTest`'s `emptyObject*Map`,
/// which recursed into their own @Test method until the eval depth blew).
///
/// Zero, deliberately: every case that runs, passes, so any new failure is a
/// real regression. The count is biased DOWNWARD by the did-not-complete
/// files — a file killed at the per-file timeout contributes no failures, and
/// which of the 1M-iteration stress loops finish varies by run. If one of
/// those starts completing and brings a genuine failure with it, that is
/// worth knowing rather than absorbing into slack; the failing names are
/// printed on every run, so a trip is diagnosable.
///
/// No did-not-complete ceiling, for the same throughput-bound reason.
const MAX_FAILED: usize = 0;

const TEST_ROOT = "kotlin-klio/klio-androidx-collection/upstream/collection/collection/src/commonTest/kotlin";
const INLINE_RECEIVER_FIXTURE = "tests/fixtures/androidx_collection_inline_receiver.kt";
const SCRATCH_HOME = "/tmp/klio_itest_androidx_home";

const Pack = struct { dir: []const u8, artifact: []const u8 };
/// Dependency order: atomicfu and kotlin.test before the androidx pack that
/// depends on them.
const PACKS = [_]Pack{
    .{ .dir = "kotlin-klio/klio-kotlinx-atomicfu", .artifact = "target/packs/kotlinx.atomicfu.klio-pack" },
    .{ .dir = "kotlin-klio/klio-kotlin-test", .artifact = "target/packs/kotlin.test.klio-pack" },
    .{ .dir = "kotlin-klio/klio-androidx-collection", .artifact = "target/packs/androidx.collection.klio-pack" },
};

fn klioBin(env: *const std.process.Environ.Map) []const u8 {
    return env.get("KLIO_ITEST_BIN") orelse "zig-out/bin/klio";
}

fn envWithHome(allocator: std.mem.Allocator, home: []const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    runtime.procEnvPutAllInto(allocator, &map);
    try map.put("HOME", home);
    return map;
}

/// Concurrent child count. Each child is one `klio test` process; the pool
/// keeps the cores busy while the slowest files run.
fn workerCount() usize {
    // KLIO_ITEST_JOBS overrides, like the shared registry runner — the
    // full-stack script bounds every suite to its share of the box.
    if (std.c.getenv("KLIO_ITEST_JOBS")) |v| {
        if (std.fmt.parseInt(usize, std.mem.span(v), 10) catch null) |n| {
            if (n >= 1) return @min(n, 64);
        }
    }
    const cores = std.Thread.getCpuCount() catch 4;
    // Half the cores, capped low: suites run beside sweeps and editors,
    // and each child is itself a multi-threaded interpreter.
    return std.math.clamp(cores / 2, 1, 4);
}

fn runKlio(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    argv: []const []const u8,
    timeout_ms: i64,
) !struct { term: std.process.Child.Term, stdout: []u8, stderr: []u8 } {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const r = std.process.run(allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = env,
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake } },
    }) catch |e| {
        // A hanging child (the 1M stress loop) is reported with whatever it
        // printed before the kill, so the PASSED lines it already emitted count.
        if (e == error.Timeout) return .{ .term = .{ .exited = 124 }, .stdout = "", .stderr = "" };
        std.debug.print("androidx_commontest: spawn {s} failed: {s}\n", .{ argv[0], @errorName(e) });
        return error.SpawnFailed;
    };
    return .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
}

fn installPacks(allocator: std.mem.Allocator, env: *std.process.Environ.Map) !void {
    for (PACKS) |p| {
        const b = try runKlio(allocator, env, &.{ klioBin(env), "pack", "build", p.dir }, 120_000 * census_support.harnessSlowdown(env));
        if (b.term != .exited or b.term.exited != 0) {
            std.debug.print("androidx_commontest: pack build {s} failed:\n{s}\n", .{ p.dir, b.stderr });
            return error.PackBuildFailed;
        }
        const i = try runKlio(allocator, env, &.{ klioBin(env), "pack", "install", p.artifact }, 120_000 * census_support.harnessSlowdown(env));
        if (i.term != .exited or i.term.exited != 0) {
            std.debug.print("androidx_commontest: pack install {s} failed:\n{s}\n", .{ p.artifact, i.stderr });
            return error.PackInstallFailed;
        }
    }
}

fn collectKt(a: std.mem.Allocator, io: std.Io, dir: []const u8, out: *std.ArrayList([]u8)) !void {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            const sub = try std.fs.path.join(a, &.{ dir, entry.name });
            try collectKt(a, io, sub, out);
        } else if (std.mem.endsWith(u8, entry.name, ".kt")) {
            try out.append(a, try std.fs.path.join(a, &.{ dir, entry.name }));
        }
    }
}

fn fileHasTest(a: std.mem.Allocator, io: std.Io, path: []const u8) bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch return false;
    return std.mem.indexOf(u8, bytes, "@Test") != null;
}

/// Count per-test `PASSED` lines. Robust to a file killed mid-run: the passes
/// printed before the kill still count. A line is `<Class>.<method> PASSED`.
fn passedLineCount(stdout: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.endsWith(u8, line, " PASSED")) n += 1;
    }
    return n;
}

/// Small atomic spin lock. Zig 0.16's blocking `std.Io.Mutex` is parameterised
/// on an `Io` handle, which the worker pool does not carry, so this guards the
/// shared name list the same way the runtime guards its cell locks.
const SpinLock = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.state.store(0, .release);
    }
};

/// Names of failing tests, collected across workers. A bare count is not
/// actionable; the name distinguishes a real regression from one known
/// unstable test flipping between runs.
const FailedNames = struct {
    mu: SpinLock = .{},
    a: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,

    fn addFrom(self: *FailedNames, text: []const u8) void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            const at = std.mem.indexOf(u8, trimmed, " FAILED") orelse continue;
            const name = std.mem.trim(u8, trimmed[0..at], " \t");
            if (name.len == 0) continue;
            self.mu.lock();
            defer self.mu.unlock();
            const owned = self.a.dupe(u8, name) catch return;
            self.items.append(self.a, owned) catch {};
        }
    }

    fn report(self: *FailedNames) void {
        self.mu.lock();
        defer self.mu.unlock();
        std.mem.sort([]const u8, self.items.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (self.items.items) |n| std.debug.print("androidx_commontest failing: {s}\n", .{n});
    }
};

/// Count per-test `FAILED` lines, the mirror of `passedLineCount`. A floor on
/// passes cannot see a regression *inside* the red mass: a change that turns
/// one failure into a pass while breaking a different test leaves the pass
/// count flat. Counting failures too gates both directions.
fn failedLineCount(stdout: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.endsWith(u8, line, " FAILED")) n += 1;
    }
    return n;
}

var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);

test "androidx.collection commonTest pass count holds at or above the ratchet baseline" {
    const a = arena_inst.allocator();
    defer _ = arena_inst.reset(.free_all);
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.Io.Dir.cwd().access(io, TEST_ROOT, .{}) catch {
        std.debug.print("androidx_commontest: commonTest path missing; skipping\n", .{});
        return error.SkipZigTest;
    };

    std.Io.Dir.cwd().createDirPath(io, SCRATCH_HOME) catch {};
    var env = try envWithHome(a, SCRATCH_HOME);
    // A Debug harness interprets several times slower than the ReleaseSafe
    // build these deadlines are tuned on; scale every child cap to match.
    const slowdown = census_support.harnessSlowdown(&env);
    if (slowdown != 1) try census_support.scaleWallCaps(a, &env, slowdown);
    try installPacks(a, &env);
    const smoke = try runKlio(
        a,
        &env,
        &.{ klioBin(&env), "run", INLINE_RECEIVER_FIXTURE, "--opt", "safe" },
        120_000 * slowdown,
    );
    if (smoke.term != .exited or smoke.term.exited != 0 or
        !std.mem.eql(u8, smoke.stdout, "0\n"))
    {
        std.debug.print(
            "androidx_commontest: inline receiver smoke failed:\nstdout:\n{s}\nstderr:\n{s}\n",
            .{ smoke.stdout, smoke.stderr },
        );
        return error.InlineReceiverSmokeFailed;
    }

    var all: std.ArrayList([]u8) = .empty;
    try collectKt(a, io, TEST_ROOT, &all);
    std.mem.sort([]u8, all.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    // Fixtures (no `@Test`) are compiled into every test file's module.
    var support: std.ArrayList([]const u8) = .empty;
    var targets: std.ArrayList([]const u8) = .empty;
    for (all.items) |p| {
        if (fileHasTest(a, io, p)) try targets.append(a, p) else try support.append(a, p);
    }

    // Build every child's argv up front, then drain the queue with a worker
    // pool — each child is one isolated `klio test` process, so the only
    // cross-thread state is the two counters. A file with the 1M stress loop
    // is killed at the per-child cap; its earlier PASSED lines still count.
    // Non-stress files finish in a few seconds.
    var jobs: std.ArrayList([]const []const u8) = .empty;
    for (targets.items) |target| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, klioBin(&env));
        try argv.append(a, "test");
        try argv.appendSlice(a, support.items);
        try argv.append(a, target);
        try jobs.append(a, try argv.toOwnedSlice(a));
    }
    var next = std.atomic.Value(usize).init(0);
    var total_passed = std.atomic.Value(usize).init(0);
    var total_failed = std.atomic.Value(usize).init(0);
    var failed_names = FailedNames{ .a = a };
    var hung = std.atomic.Value(usize).init(0);
    const Pool = struct {
        fn worker(
            queue: []const []const []const u8,
            penv: *std.process.Environ.Map,
            pnext: *std.atomic.Value(usize),
            ppassed: *std.atomic.Value(usize),
            pfailed: *std.atomic.Value(usize),
            pnames: *FailedNames,
            phung: *std.atomic.Value(usize),
        ) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            while (true) {
                const i = pnext.fetchAdd(1, .monotonic);
                if (i >= queue.len) return;
                _ = arena.reset(.retain_capacity);
                // 180s per file: ScatterMapTest / OrderedScatterSetTest /
                // SieveCacheTest are the compute-heavy tail (a healthy file
                // returns long before), scaled for a Debug harness.
                const r = runKlio(arena.allocator(), penv, queue[i], 180_000 * census_support.harnessSlowdown(penv)) catch {
                    _ = phung.fetchAdd(1, .monotonic);
                    continue;
                };
                _ = ppassed.fetchAdd(passedLineCount(r.stdout), .monotonic);
                _ = pfailed.fetchAdd(failedLineCount(r.stdout), .monotonic);
                pnames.addFrom(r.stdout);
                if (std.mem.indexOf(u8, r.stdout, " passed,") == null) {
                    _ = phung.fetchAdd(1, .monotonic);
                    // Name the file that produced no summary (crashed or
                    // cut off) so a red run is actionable from the log.
                    std.debug.print("[androidx-nosummary] <- {s}\n", .{queue[i][queue[i].len - 1]});
                }
            }
        }
    };
    var threads: std.ArrayList(std.Thread) = .empty;
    for (0..workerCount()) |_| {
        try threads.append(a, try std.Thread.spawn(.{}, Pool.worker, .{
            @as([]const []const []const u8, jobs.items), &env, &next, &total_passed, &total_failed, &failed_names, &hung,
        }));
    }
    for (threads.items) |t| t.join();

    const failed = total_failed.load(.monotonic);
    failed_names.report();
    std.debug.print(
        "androidx_commontest: {d} passed, {d} failed across {d} files, {d} did not complete (baseline {d}, max_failed {d})\n",
        .{ total_passed.load(.monotonic), failed, targets.items.len, hung.load(.monotonic), BASELINE, MAX_FAILED },
    );
    try std.testing.expect(total_passed.load(.monotonic) >= BASELINE);
    if (failed > MAX_FAILED) {
        std.debug.print(
            "androidx_commontest: {d} failed exceeds the ceiling {d}\n",
            .{ failed, MAX_FAILED },
        );
        return error.FailureCeilingExceeded;
    }
}

test "failedLineCount counts FAILED lines and ignores PASSED ones" {
    const out =
        \\SomeTest.a PASSED
        \\SomeTest.b FAILED
        \\SomeTest.c PASSED
        \\SomeTest.d FAILED
        \\3 tests, 1 passed, 2 failed
        \\
    ;
    try std.testing.expectEqual(@as(usize, 2), failedLineCount(out));
    try std.testing.expectEqual(@as(usize, 2), passedLineCount(out));
    try std.testing.expectEqual(@as(usize, 0), failedLineCount("nothing here\n"));
}
