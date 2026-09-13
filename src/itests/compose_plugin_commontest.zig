//! Run the upstream Compose runtime's own test suite through `klio test`
//! against the installed engine pack with the `@Composable` lowering plugin:
//! `androidx.compose.runtime` resolves to the upstream gapbuffer/linkbuffer
//! engine and every composable lowers through `compose_pass`.
//!
//! Every `.kt` under the roots compiles into every child (the fixtures are
//! cross-file), isolation is one child per test class via `--filter`, and the
//! pass count is a ratchet.

const std = @import("std");
const runtime = @import("runtime");

/// Pass-count floor, a ratchet: raise as fixes land, never lower. Set to
/// `1390 - MAX_FAILED`, so it tolerates exactly the failures the ceiling below
/// allows while a class that hangs or crashes still drops the count under it.
const BASELINE: usize = 1385;

/// Ceiling on failing cases, the mirror of `BASELINE`: a pass floor alone
/// cannot see a fix that trades one failure for another. Set one above the
/// measurement, since the standing failures flip between runs under contention.
/// No did-not-complete ceiling: DNC here is throughput-bound and varies by ~40.
const MAX_FAILED: usize = 5;

const UPSTREAM = "kotlin-klio/klio-compose-runtime/upstream/compose/runtime";
const ROOTS = [_][]const u8{
    UPSTREAM ++ "/runtime-test-utils/src/commonMain/kotlin",
    UPSTREAM ++ "/runtime/src/commonTest/kotlin",
    UPSTREAM ++ "/runtime/src/nonEmulatorCommonTest/kotlin",
    // klio-owned actuals for the test sources' platform expects.
    "tests/compose_commontest_actuals",
};
const SCRATCH_HOME = "/tmp/klio_itest_compose_plugin_home";

const Pack = struct { dir: []const u8, artifact: []const u8 };
/// Dependency order. The last entry supplies `androidx.compose.runtime` from
/// the engine pack, whose sources are the upstream Composer and SlotTable.
const PACKS = [_]Pack{
    .{ .dir = "kotlin-klio/klio-kotlinx-atomicfu", .artifact = "target/packs/kotlinx.atomicfu.klio-pack" },
    .{ .dir = "kotlin-klio/klio-kotlin-test", .artifact = "target/packs/kotlin.test.klio-pack" },
    .{ .dir = "kotlin-klio/klio-kotlinx-coroutines", .artifact = "target/packs/kotlinx.coroutines.klio-pack" },
    .{ .dir = "kotlin-klio/klio-androidx-collection", .artifact = "target/packs/androidx.collection.klio-pack" },
    .{ .dir = "kotlin-klio/klio-compose-runtime-engine", .artifact = "target/packs/androidx.compose.runtime.klio-pack" },
};

fn klioBin(env: *const std.process.Environ.Map) []const u8 {
    return env.get("KLIO_ITEST_BIN") orelse "zig-out/bin/klio";
}

fn envWithHome(allocator: std.mem.Allocator, home: []const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    runtime.procEnvPutAllInto(allocator, &map);
    try map.put("HOME", home);
    // runTest's own per-test budget. It must never fire before klio's wall cap
    // below, the suite's hang guard: if it does, a slow but progressing test
    // reports `UncompletedCoroutinesError` instead of passing or hitting the cap.
    try map.put("kotlinx_coroutines_test_default_timeout", "900s");
    // Per-test wall cap in seconds: a deadlocked test fails in place instead of
    // eating its class's whole budget, so its classmates' passes stay counted.
    try map.put("KLIO_TEST_WALL_CAP", "90");
    // Per-test overrides in seconds for three tests that are slow, not stuck,
    // and would otherwise cross the hang window while still passing. A budget
    // is a ratchet: it only shrinks, and exceeding it still fails.
    try map.put(
        "KLIO_TEST_WALL_CAP_FOR",
        "validatePotentialDeadlock=900,resumeOnBackgroundThread=300,pausingTheFrameClockStopShouldBlockWithFrameNanos=300",
    );
    // Each child otherwise takes a half-the-cores compute pool, oversubscribing
    // the box. Cap each so the children together match the core count.
    try map.put("KLIO_MAX_WORKERS", "5");
    return map;
}

fn workerCount() usize {
    // `KLIO_ITEST_JOBS` overrides the width for wall-time measurement.
    if (runtime.envOnce("KLIO_ITEST_JOBS")) |v| {
        if (std.fmt.parseInt(usize, v, 10) catch null) |n| {
            if (n >= 1 and n <= 32) return n;
        }
    }
    const cores = std.Thread.getCpuCount() catch 4;
    // Half the cores, capped at 8.
    return std.math.clamp(cores / 2, 1, 8);
}

fn runKlio(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    argv: []const []const u8,
    timeout_ms: i64,
) !struct { term: std.process.Child.Term, stdout: []u8, stderr: []u8 } {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // `std.process.run` discards its buffer when its timeout fires, losing the
    // passes a class produced before wedging. This variant kills the child and
    // returns what it already wrote, with term 124.
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |e| {
        std.debug.print("compose_plugin_commontest: spawn {s} failed: {s}\n", .{ argv[0], @errorName(e) });
        return error.SpawnFailed;
    };
    defer child.kill(io);
    var mrb: std.Io.File.MultiReader.Buffer(2) = undefined;
    var mr: std.Io.File.MultiReader = undefined;
    mr.init(allocator, io, mrb.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer mr.deinit();
    var timed_out = false;
    while (mr.fill(64, .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake } })) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        error.Timeout => timed_out = true,
        else => |e| return e,
    }
    const term: std.process.Child.Term = if (timed_out) blk: {
        child.kill(io);
        break :blk .{ .exited = 124 };
    } else try child.wait(io);
    const stdout_slice = try mr.toOwnedSlice(0);
    errdefer allocator.free(stdout_slice);
    const stderr_slice = try mr.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout_slice, .stderr = stderr_slice };
}

fn installPacks(allocator: std.mem.Allocator, env: *std.process.Environ.Map) !void {
    for (PACKS) |p| {
        const b = try runKlio(allocator, env, &.{ klioBin(env), "pack", "build", p.dir }, 600_000);
        if (b.term != .exited or b.term.exited != 0) {
            std.debug.print("compose_plugin_commontest: pack build {s} failed:\n{s}\n", .{ p.dir, b.stderr });
            return error.PackBuildFailed;
        }
        const i = try runKlio(allocator, env, &.{ klioBin(env), "pack", "install", p.artifact }, 120_000);
        if (i.term != .exited or i.term.exited != 0) {
            std.debug.print("compose_plugin_commontest: pack install {s} failed:\n{s}\n", .{ p.artifact, i.stderr });
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

/// Number of `@Test` occurrences in a file: the shard-balancing weight, and the
/// quantity the ratchet counts, so a slice's baseline share is its share of this.
fn testCount(a: std.mem.Allocator, io: std.Io, path: []const u8) usize {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch return 0;
    return std.mem.count(u8, bytes, "@Test");
}

/// The test class a file contributes, or null when it declares none.
fn testClassOf(a: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch return null;
    if (std.mem.find(u8, bytes, "@Test") == null) return null;
    const base = std.fs.path.basename(path);
    const stem = base[0 .. base.len - ".kt".len];
    var buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "class {s}", .{stem}) catch return null;
    if (std.mem.find(u8, bytes, needle) == null) return null;
    return a.dupe(u8, stem) catch null;
}

/// Per-test `PASSED` lines, a count that survives a file killed mid-run.
fn passedLineCount(stdout: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.endsWith(u8, line, " PASSED")) n += 1;
    }
    return n;
}

/// Streamed per-test lines (`[test] Class.name PASSED 12ms` on stderr): the
/// count that survives a killed child, whose end-of-run summary never printed.
fn streamedPassedCount(stderr: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "[test] ") and
            std.mem.find(u8, line, " PASSED ") != null) n += 1;
    }
    return n;
}

/// Spin lock guarding the shared name list. Zig 0.16's blocking `std.Io.Mutex`
/// is parameterised on an `Io` handle, which the worker pool does not carry.
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

/// Names of failing tests, collected across workers: a bare count cannot say
/// whether a run drifted from a regression or from a known-unstable test.
const FailedNames = struct {
    mu: SpinLock = .{},
    a: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,

    /// Matches both shapes the child emits: the summary line `Class.name
    /// FAILED`, and the streamed `[test] Class.name FAILED 12ms`.
    fn addFrom(self: *FailedNames, text: []const u8, marker: []const u8) void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            const at = std.mem.find(u8, trimmed, marker) orelse continue;
            var name = std.mem.trim(u8, trimmed[0..at], " \t");
            if (std.mem.startsWith(u8, name, "[test]")) {
                name = std.mem.trim(u8, name["[test]".len..], " \t");
            }
            if (name.len == 0) continue;
            self.mu.lock();
            defer self.mu.unlock();
            const owned = self.a.dupe(u8, name) catch return;
            self.items.append(self.a, owned) catch {};
        }
    }

    fn report(self: *FailedNames, comptime prefix: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        std.mem.sort([]const u8, self.items.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (self.items.items) |n| std.debug.print(prefix ++ " failing: {s}\n", .{n});
    }
};

/// Mirrors the pass counters: a floor alone cannot see a regression in the red.
fn failedLineCount(stdout: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.endsWith(u8, line, " FAILED")) n += 1;
    }
    return n;
}

fn streamedFailedCount(stderr: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |line| {
        if (std.mem.find(u8, line, "[test] ") != null and
            std.mem.find(u8, line, " FAILED") != null) n += 1;
    }
    return n;
}

var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);

test "compose runtime commonTest under the lowering plugin holds the ratchet baseline" {
    const a = arena_inst.allocator();
    defer _ = arena_inst.reset(.free_all);
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.Io.Dir.cwd().access(io, ROOTS[0], .{}) catch {
        std.debug.print(
            "compose_plugin_commontest: test sources missing; run scripts/init-compose-submodule.sh\n",
            .{},
        );
        return error.SkipZigTest;
    };

    std.Io.Dir.cwd().createDirPath(io, SCRATCH_HOME) catch {};
    var env = try envWithHome(a, SCRATCH_HOME);
    try installPacks(a, &env);

    var all: std.ArrayList([]u8) = .empty;
    for (ROOTS) |root| try collectKt(a, io, root, &all);
    std.mem.sort([]u8, all.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    var sources: std.ArrayList([]const u8) = .empty;
    var classes: std.ArrayList([]const u8) = .empty;
    var class_files: std.ArrayList([]const u8) = .empty;
    for (all.items) |p| {
        try sources.append(a, p);
        if (testClassOf(a, io, p)) |cls| {
            try classes.append(a, cls);
            try class_files.append(a, p);
        }
    }

    // KLIO_COMMONTEST_SHARD=K/N runs one slice of the class list so CI can fan
    // this suite, the wall by a wide margin, across parallel jobs.
    var shard_k: usize = 0;
    var shard_n: usize = 1;
    if (runtime.envOnce("KLIO_COMMONTEST_SHARD")) |sv| {
        if (std.mem.findScalar(u8, sv, '/')) |sep| {
            const k = std.fmt.parseInt(usize, sv[0..sep], 10) catch 0;
            const n = std.fmt.parseInt(usize, sv[sep + 1 ..], 10) catch 1;
            if (n != 0 and k < n) {
                shard_k = k;
                shard_n = n;
            }
        }
    }

    // Copying an interpreted Map re-enters Kotlin while a native intrinsic
    // owns its iterator and entry values. Collecting at every safe point holds
    // that boundary to a precise GC-root contract.
    try env.put("KLIO_GC_STRESS", "1");
    var stress_argv: std.ArrayList([]const u8) = .empty;
    try stress_argv.append(a, klioBin(&env));
    try stress_argv.append(a, "test");
    try stress_argv.appendSlice(a, sources.items);
    try stress_argv.append(a, "--filter=SnapshotStateMapTests.validateEntriesRemoveAll");
    // 240s: this step compiles the same whole source set every job does (~50s
    // under load) and the filtered test itself runs in under a second.
    const stress = try runKlio(a, &env, stress_argv.items, 240_000);
    // `Environ.Map` owns its keys and values and exposes no `remove`; the flag
    // is value-gated (`!= "0"`), so clearing it is a `put`.
    try env.put("KLIO_GC_STRESS", "0");
    if (stress.term != .exited or stress.term.exited != 0) {
        std.debug.print(
            "compose_plugin_commontest: GC-stress Map copy failed:\n{s}\n{s}\n",
            .{ stress.stdout, stress.stderr },
        );
        return error.GcStressMapCopyFailed;
    }

    var jobs: std.ArrayList([]const []const u8) = .empty;
    // Longest-first: the wall is the slowest child, so the class that runs for
    // minutes starts with the first worker rather than where nothing overlaps it.
    for (classes.items, 0..) |cls, ci| {
        if (std.mem.find(u8, cls, "RecomposerTests") != null and ci != 0) {
            const first = classes.items[0];
            classes.items[0] = classes.items[ci];
            classes.items[ci] = first;
            break;
        }
    }
    // Weighted slice assignment, greedy to the lightest. `@Test` count keeps a
    // slice's share of the pass count proportional, which is what the ratchet
    // scales by; it does not model time, so the slice holding the wall stays long.
    const slice_of = try a.alloc(usize, classes.items.len);
    var my_weight: usize = 0;
    var total_weight: usize = 0;
    {
        const loads = try a.alloc(usize, shard_n);
        @memset(loads, 0);
        for (classes.items, 0..) |_, ci| {
            const w = @max(testCount(a, io, class_files.items[ci]), 1);
            total_weight += w;
            var best: usize = 0;
            for (loads, 0..) |ld, si| {
                if (ld < loads[best]) best = si;
            }
            slice_of[ci] = best;
            loads[best] += w;
        }
        my_weight = loads[shard_k];
    }

    var job_names: std.ArrayList([]const u8) = .empty;
    for (classes.items, 0..) |cls, cls_i| {
        if (slice_of[cls_i] != shard_k) continue;
        // `validatePotentialDeadlock` is the suite wall, so it gets its own
        // child scheduled first and the class's remainder runs as an overlapping
        // job. Both compile a trimmed source set: the class file plus the
        // same-package files whose helpers it reaches without imports. An
        // unlisted helper fails loudly as an unresolved global, never silently.
        if (std.mem.eql(u8, cls, "RecomposerTests")) {
            var trimmed: std.ArrayList([]const u8) = .empty;
            for (sources.items) |src| {
                const in_test_dirs =
                    std.mem.find(u8, src, "/commonTest/") != null or
                    std.mem.find(u8, src, "/nonEmulatorCommonTest/") != null;
                const keep = !in_test_dirs or
                    std.mem.endsWith(u8, src, "/RecomposerTests.kt") or
                    std.mem.endsWith(u8, src, "/EffectsTests.kt") or
                    std.mem.endsWith(u8, src, "/CompositionTests.kt");
                if (keep) try trimmed.append(a, src);
            }
            var solo: std.ArrayList([]const u8) = .empty;
            // The solo child takes cores 0-5 on a big box (scripts/stack.sh pins
            // everything else off them); siblings run under nice so its threads
            // keep the scheduler wherever the masks overlap.
            if (std.c.getenv("KLIO_VPD_CPUS")) |cpus| {
                try solo.appendSlice(a, &.{ "taskset", "-c", std.mem.span(cpus) });
            } else if ((std.Thread.getCpuCount() catch 1) >= 16) {
                try solo.appendSlice(a, &.{ "taskset", "-c", "0-5" });
            }
            // The body spends ~15-20% of its time in GC. Passed per-child via
            // argv so the others keep the default regime and RSS profile.
            try solo.appendSlice(a, &.{ "env", "KLIO_GC_GROWTH=8", "KLIO_GC_THRESHOLD_KB=524288" });
            try solo.append(a, klioBin(&env));
            try solo.append(a, "test");
            try solo.appendSlice(a, trimmed.items);
            try solo.append(a, "--filter=RecomposerTests.validatePotentialDeadlock");
            try jobs.append(a, try solo.toOwnedSlice(a));
            try job_names.append(a, "RecomposerTests.validatePotentialDeadlock");
            var rest: std.ArrayList([]const u8) = .empty;
            try rest.appendSlice(a, &.{ "nice", "-n", "10" });
            try rest.append(a, klioBin(&env));
            try rest.append(a, "test");
            try rest.appendSlice(a, trimmed.items);
            try rest.append(a, "--filter=RecomposerTests,!validatePotentialDeadlock");
            try jobs.append(a, try rest.toOwnedSlice(a));
            try job_names.append(a, "RecomposerTests-rest");
            continue;
        }
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ "nice", "-n", "10" });
        try argv.append(a, klioBin(&env));
        try argv.append(a, "test");
        try argv.appendSlice(a, sources.items);
        try argv.append(a, try std.fmt.allocPrint(a, "--filter={s}", .{cls}));
        try jobs.append(a, try argv.toOwnedSlice(a));
        try job_names.append(a, cls);
    }

    var next = std.atomic.Value(usize).init(0);
    var total_passed = std.atomic.Value(usize).init(0);
    var total_failed = std.atomic.Value(usize).init(0);
    var failed_names = FailedNames{ .a = a };
    var hung = std.atomic.Value(usize).init(0);
    const Pool = struct {
        fn worker(
            queue: []const []const []const u8,
            names: []const []const u8,
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
                // 480s hang guard per class: a class killed under the cap loses
                // the passes it had buffered. RecomposerTests carries
                // `validatePotentialDeadlock`, slow rather than wedged, so its
                // budget fits it.
                const class_cap_ms: i64 = if (std.mem.find(u8, names[i], "RecomposerTests") != null)
                    1_200_000
                else
                    480_000;
                const child_t0 = runtime.clockMonotonicNanos();
                const r = runKlio(arena.allocator(), penv, queue[i], class_cap_ms) catch {
                    _ = phung.fetchAdd(1, .monotonic);
                    // Name the class: a bare count says nothing actionable.
                    std.debug.print("compose_plugin_commontest: {s} did not complete (spawn/cap)\n", .{names[i]});
                    continue;
                };
                // A completed run counts its summary; a killed run's never
                // printed, so its streamed lines carry the count.
                std.debug.print("compose_plugin_commontest: [child-wall] {s} {d}s\n", .{
                    names[i], @divTrunc(runtime.clockMonotonicNanos() - child_t0, std.time.ns_per_s),
                });
                const summary_count = passedLineCount(r.stdout);
                const n_passed = if (summary_count != 0) summary_count else streamedPassedCount(r.stderr);
                _ = ppassed.fetchAdd(n_passed, .monotonic);
                const summary_failed = failedLineCount(r.stdout);
                if (summary_count != 0) pnames.addFrom(r.stdout, " FAILED") else pnames.addFrom(r.stderr, " FAILED");
                _ = pfailed.fetchAdd(
                    if (summary_count != 0) summary_failed else streamedFailedCount(r.stderr),
                    .monotonic,
                );
                if (std.mem.find(u8, r.stdout, " passed,") == null) {
                    _ = phung.fetchAdd(1, .monotonic);
                    // Name the termination and the tail of the child's output.
                    const tail_from = if (r.stderr.len > 600) r.stderr.len - 600 else 0;
                    std.debug.print("compose_plugin_commontest: {s} did not complete ({d} streamed passes kept) term={s} code={d}\n{s}\n", .{
                        names[i],
                        n_passed,
                        @tagName(std.meta.activeTag(r.term)),
                        switch (r.term) {
                            .exited => |c| @as(i64, c),
                            .signal => |sg| @as(i64, @intCast(@intFromEnum(sg))),
                            else => @as(i64, -1),
                        },
                        r.stderr[tail_from..],
                    });
                    std.debug.print("compose_plugin_commontest: [dnc-argv]", .{});
                    for (queue[i]) |arg| std.debug.print(" {s}", .{arg});
                    std.debug.print("\n", .{});
                }
            }
        }
    };
    var threads: std.ArrayList(std.Thread) = .empty;
    for (0..workerCount()) |_| {
        try threads.append(a, try std.Thread.spawn(.{}, Pool.worker, .{
            @as([]const []const []const u8, jobs.items),
            @as([]const []const u8, job_names.items),
            &env,
            &next,
            &total_passed,
            &total_failed,
            &failed_names,
            &hung,
        }));
    }
    for (threads.items) |t| t.join();

    // A slice is gated on its proportional share, with wide slack: a class whose
    // tests are ignored contributes weight without passes. The exact ratchet is
    // still enforced by every unsharded run.
    const min_pass = if (shard_n == 1)
        BASELINE
    else
        (BASELINE * my_weight / @max(total_weight, 1)) * 65 / 100;
    std.debug.print(
        "compose_plugin_commontest: {d} passed, {d} failed across {d} jobs (shard {d}/{d}), {d} did not complete (min {d}, baseline {d})\n",
        .{
            total_passed.load(.monotonic), total_failed.load(.monotonic), jobs.items.len,
            shard_k,                       shard_n,                       hung.load(.monotonic),
            min_pass,                      BASELINE,
        },
    );
    // Names first: the expect below aborts the body before they would print.
    const failed = total_failed.load(.monotonic);
    failed_names.report("compose_plugin_commontest");
    try std.testing.expect(total_passed.load(.monotonic) >= min_pass);
    if (failed > MAX_FAILED) {
        std.debug.print(
            "compose_plugin_commontest: {d} failed exceeds the ceiling {d}\n",
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
