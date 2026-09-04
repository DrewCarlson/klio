//! Run the upstream Compose runtime's own test suite through `klio test`
//! against the installed ENGINE pack with the `@Composable` lowering plugin.
//!
//! THE compose conformance gate: the `androidx.compose.runtime` id resolves to
//! the real upstream
//! gapbuffer/linkbuffer engine (`klio-compose-runtime-engine`) and every
//! composable lowers through `compose_pass` — $composer/$changed threading,
//! restart groups, marker defaults. At cutover this suite becomes THE compose
//! conformance gate and the implicit-hook suite retires with the old
//! implementation.
//!
//! Structure: every `.kt` under the roots compiles into every child
//! (cross-file fixtures), isolation is one child per test class via
//! `--filter`, passes are counted from per-test `PASSED` lines, and the
//! pass count is a ratchet — raise `BASELINE` as fixes land, never lower
//! it.

const std = @import("std");
const runtime = @import("runtime");

/// Minimum number of upstream Compose runtime test cases that must pass under
/// the plugin. A ratchet: bump it as fixes land, never down. Measured 841
/// standalone (vs 445 for the implicit hook) with skip calculus + local
/// composables and the 480s per-child cap. The persisted-resume throw fix
/// converted the 18-class hang family (926 measured); the typealias-receiver
/// dispatch, event-loop actuals, pump mailbox-drain, and captured-counter
/// fixes took it to 953; the movable-content chain and the validator-side
/// sink-scope gate took it to 987; the receiver-lambda dispatch, local-fun
/// Unit-return, local-class init-block, and vararg-overload-resolution
/// fixes held five consecutive runs at 1031-1050. The floor leaves
/// saturation headroom like the implicit suite's does.
// Ratchet RAISED again 1100 -> 1150 after the serial-agent round's
// verified 1166 (deadlock-scope, Unconfined, channel-dispatch, pump-exit
// handoff, non-local-return endToMarker). This is the pass-count FLOOR
// future runs must meet or beat; raising it tightens the gate. Margin
// below 1166 covers the ±flake band and did-not-complete variance.
// RAISED 1150 -> 1175 after verified 1208 (the compose-defaulted-parameter
// named-argument binder fix wired the onReuse/onDeactivate/onRelease/onSet
// callbacks a source call passes by name, which had silently fallen back to
// their defaults). Deliberately NOT 1190: single-run counts swing ~±40
// because 3-5 compute-heavy/concurrent classes variably cross the 480s
// per-class cap under 8-way contention and lose their tail passes (samples
// 1179/1200/1208/1221). The floor must sit below the worst realistic
// DNC run so a high-DNC run does not fail the ratchet spuriously; 1175
// keeps meaningful regression detection with that margin.
// RAISED 1175 -> 1210 after verified 1252 (the image-loaded-base decl
// fix: the plugin's base collectors now see an image-loaded base's
// composables, a deterministic gain on the pack path the suite always
// uses). Kept below the 1252 peak by the ~±40 DNC-variance margin.
// RAISED 1210 -> 1275 after four consecutive runs at 1315-1318: the
// GC-stress step no longer times out inside the compiler, and the static
// receiver-typing channels bound work that previously resolved by name.
// Same ~±40 margin below the observed floor.
// RAISED 1275 -> 1305 once the flat-call seam stopped reading a callee's
// body against the caller's module: `CompositionTests`, `PausableComposition-
// Tests` and `SnapshotStateMapTests` no longer abort part-way, so all 46
// classes complete and the observed count moved to 1345. Same ~±40 margin.
// RAISED 1305 -> 1340 after the remember-family scoping fixes (captured
// locals as the nearest binding) and the dirty-bits skip calculus landed:
// four consecutive runs at 1370-1372 with the GroupSize slot anchor green.
// Same ~±30 margin below the observed floor.
// RAISED 1375 -> 1377 after the call-throughput rounds (trivial-init
// serve, scalar bitwise BinOps, persistent-collection host scans, the
// host-served snapshot validity walk): three consecutive solo runs at
// 1378/1380/1380 under the width-6 capped-children config. Margin below
// the 1380 observations covers the ±3 band this config has shown.
// RAISED 1377 -> 1381 after the literal-lambda splice landed by default
// (with the builder bulk-op serves and the dead-closure skip): gate runs
// at 1383 and 1385 passed; margin below both covers the ±3 band.
// RAISED 1381 -> 1386 after the inline-parity rounds (qualified splice,
// ext-lambda tier, seated subjects), the whole-cycle SnapshotStateMap.put
// serve, and the perm-mint birth-barrier GC fix: the gate runs at 1389
// with the ONLY real failure validatePotentialDeadlock, and
// SnapshotStateMapTests is 59/59 solo. Margin below 1389 covers the
// load-flake band (Movable, the Pausable pair, frame-clock).
// RAISED 1386 -> 1390 (2026-09-01): five consecutive full stacks at
// 1390/0/0 under the L3-split structure.
/// 1389: every class passes except `RecomposerTests.validatePotentialDeadlock`,
/// a pure throughput ceiling (it completes, in ~744s on a 6-core slice with
/// the pre-session harness and packs, against a 580s cap that a 4-vCPU CI
/// runner cannot meet). The failure ceiling below still catches real
/// regressions; the baseline does not depend on the machine's speed.
const BASELINE: usize = 1389;

/// Ceiling on failing cases, the mirror of `BASELINE`. Measured solo at
/// 1380 passed / 10 failed once companion extension properties resolved
/// (that root took five with it, including four FloatingPointEqualityTest
/// cases). A pass floor alone cannot see a fix that trades one failure for
/// another; this bounds that direction.
///
/// Set one above the measurement, not at it. Two runs of the previous state
/// differed by exactly one failure (15 then 16) with the total constant, and
/// every remaining failure is in the concurrency group
/// (`SnapshotState*.concurrent*`, `RecomposerTests.validatePotentialDeadlock`,
/// `PausableCompositionTests.resumeOnBackgroundThread`), so the flip lives
/// there. The instability is real and tracked as open work; until it is
/// fixed, a ceiling exactly at the measurement would red the gate about half
/// the time. The names are printed on every run, so a genuine new failure is
/// still identifiable rather than absorbed by the slack.
/// Deliberately NO did-not-complete ceiling: DNC on this suite is
/// throughput-bound and varies by ~40 between runs (see the note above the
/// baseline), so a DNC gate would be a flake, not a signal. Failures do not
/// have that variance — a killed class contributes neither.
/// LOWERED 11 -> 5 with the concurrency family closed (the map class is
/// 59/59 solo; the only standing real failure is
/// `RecomposerTests.validatePotentialDeadlock`, a pure throughput
/// ceiling). The slack above 1 covers the known load flakes that appear
/// only at gate contention: MovableContent, the PausableComposition
/// pair, and the frame-clock test.
const MAX_FAILED: usize = 5;

const UPSTREAM = "kotlin-klio/klio-compose-runtime/upstream/compose/runtime";
const ROOTS = [_][]const u8{
    UPSTREAM ++ "/runtime-test-utils/src/commonMain/kotlin",
    UPSTREAM ++ "/runtime/src/commonTest/kotlin",
    UPSTREAM ++ "/runtime/src/nonEmulatorCommonTest/kotlin",
    // klio-owned actuals for the test sources' platform expects
    // (`wrapRunTest`), following the stdlib_commontest_actuals pattern.
    "tests/compose_commontest_actuals",
};
const SCRATCH_HOME = "/tmp/klio_itest_compose_plugin_home";

const Pack = struct { dir: []const u8, artifact: []const u8 };
/// Dependency order as in the implicit suite; the final entry swaps the
/// implicit-composer pack for the engine pack (same `androidx.compose.runtime`
/// id, real upstream Composer/SlotTable/Recomposer sources).
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
    // Cap runTest's default 60s real-time timeout: a test that will time out
    // should fail fast, not hold its class's child (and the pump's job tree)
    // for a minute per occurrence.
    //
    // `resumeOnBackgroundThread` resumes 1000 pausable chunks one
    // cross-thread round-trip at a time (~40-55s interpreted) and PASSES
    // under upstream's own 60s default; a 10s override was the right
    // trade when dozens of hanging tests each ate their timeout (measured
    // then: 90s gave 1336 with two Snapshot classes not completing vs
    // 1345 at 10s). That hang population is gone — the suite stands at
    // 1385/5 with the failures enumerated — so the cap returns to the
    // upstream default and only genuinely-stuck tests pay it.
    // Upstream's own per-test budget. It must never fire BEFORE klio's wall
    // cap, which is the suite's hang guard and is per-test tunable: when it
    // did, a slow-but-progressing test reported `UncompletedCoroutinesError`
    // at an arbitrary point instead of either passing or hitting the cap.
    try map.put("kotlinx_coroutines_test_default_timeout", "900s");
    // Per-test wall cap: a test that genuinely deadlocks (the Recomposer
    // deadlock-regression shape, the concurrent-mixing teardown stall) fails
    // in place instead of eating the class's whole 480s budget — its
    // classmates' passes stay counted. Generous enough for the compute-heavy
    // benchmark tests under 8-way contention.
    try map.put("KLIO_TEST_WALL_CAP", "90");
    // `validatePotentialDeadlock` is throughput-bound, not wedged: it races
    // two infinite writer loops against ~3120 frames of 200 composables.
    // It gets a declared budget so the suite reports what it is (slow)
    // rather than what it is not (stuck). The budget is a ratchet — it
    // must only shrink as the recomposition path gets faster, and
    // exceeding it still fails. 645 -> 580 (2026-09-01): GC-relaxed and
    // L3-isolated it runs 510s solo, 525-535s in-stack across four
    // consecutive stacks.
    // Two more measured-slow, not-stuck tests: `resumeOnBackgroundThread`
    // resumes 1000 pausable chunks one cross-thread round-trip at a time
    // (~40-55s solo, 25/25) and the frame-clock test is a timing test; under
    // 8-way contention both cross the 90s hang window while still passing.
    try map.put(
        "KLIO_TEST_WALL_CAP_FOR",
        "validatePotentialDeadlock=900,resumeOnBackgroundThread=300,pausingTheFrameClockStopShouldBlockWithFrameNanos=300",
    );
    // Four children each defaulting to a half-the-cores compute pool
    // oversubscribe the box 2x and inflate the concurrent classes'
    // walls 3-8x. Cap each child so the children together match the
    // core count.
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
    // Half the cores, capped at 8. The old cap of 6 existed because wider
    // job sets inflated the concurrent-snapshot family past its budgets;
    // with that family fixed, width 8 measured 334s vs 418s at width 6
    // with an identical 1389/1/0 result.
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
    // `std.process.run` discards everything it buffered when the timeout
    // fires, so a class that passed 100 tests and then wedged counted ZERO.
    // This variant keeps the partial capture: on timeout the child is
    // killed and whatever it already wrote is returned with term 124.
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

/// The test CLASS a file contributes, or null when it declares none.
fn testClassOf(a: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch return null;
    if (std.mem.indexOf(u8, bytes, "@Test") == null) return null;
    const base = std.fs.path.basename(path);
    const stem = base[0 .. base.len - ".kt".len];
    var buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "class {s}", .{stem}) catch return null;
    if (std.mem.indexOf(u8, bytes, needle) == null) return null;
    return a.dupe(u8, stem) catch null;
}

/// Count per-test `PASSED` lines — robust to a file killed mid-run.
fn passedLineCount(stdout: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.endsWith(u8, line, " PASSED")) n += 1;
    }
    return n;
}

/// Streamed per-test lines (`[test] Class.name PASSED 12ms`, stderr,
/// flushed as each test finishes) — the count that survives a killed
/// child, whose end-of-run summary never printed.
fn streamedPassedCount(stderr: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, stderr, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "[test] ") and
            std.mem.indexOf(u8, line, " PASSED ") != null) n += 1;
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

/// Names of failing tests, collected across workers. "16 failed" is not
/// actionable — the name is what tells you whether a run drifted because of a
/// real regression or because one known-unstable test flipped.
const FailedNames = struct {
    mu: SpinLock = .{},
    a: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,

    /// Matches both shapes the child emits: the end-of-run summary line
    /// `Class.name FAILED`, and the streamed line `[test] Class.name FAILED
    /// 12ms` that carries a duration after the marker.
    fn addFrom(self: *FailedNames, text: []const u8, marker: []const u8) void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            const at = std.mem.indexOf(u8, trimmed, marker) orelse continue;
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

/// Mirrors of the pass counters for failing tests. A pass-count floor alone
/// cannot see a regression inside the red mass; bounding failures gates the
/// other direction.
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
        if (std.mem.indexOf(u8, line, "[test] ") != null and
            std.mem.indexOf(u8, line, " FAILED") != null) n += 1;
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
    for (all.items) |p| {
        try sources.append(a, p);
        if (testClassOf(a, io, p)) |cls| try classes.append(a, cls);
    }

    // Copying an interpreted Map re-enters Kotlin while a native intrinsic
    // owns its iterator and entry values. Collect at every safe point so this
    // boundary remains a precise GC-root contract.
    try env.put("KLIO_GC_STRESS", "1");
    var stress_argv: std.ArrayList([]const u8) = .empty;
    try stress_argv.append(a, klioBin(&env));
    try stress_argv.append(a, "test");
    try stress_argv.appendSlice(a, sources.items);
    try stress_argv.append(a, "--filter=SnapshotStateMapTests.validateEntriesRemoveAll");
    // 240s, matching the order of the per-class budget below: this step
    // hands `klio test` the SAME 68-file source set every job compiles, and
    // that compile alone is ~50s under load. The filtered test itself runs
    // in under a second — the old 30s cap timed out in the compiler, before
    // the GC contract it exists to check was ever exercised.
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
    // Longest-first: the wall is the slowest child, so a class known to run
    // for minutes (RecomposerTests carries the ~724s
    // `validatePotentialDeadlock`) must start with the first worker, not be
    // picked up near the end where nothing overlaps it.
    for (classes.items, 0..) |cls, ci| {
        if (std.mem.indexOf(u8, cls, "RecomposerTests") != null and ci != 0) {
            const first = classes.items[0];
            classes.items[0] = classes.items[ci];
            classes.items[ci] = first;
            break;
        }
    }
    var job_names: std.ArrayList([]const u8) = .empty;
    for (classes.items) |cls| {
        // `validatePotentialDeadlock` IS the suite wall (~500s solo), and the
        // rest of RecomposerTests queued behind it in the same child pushed
        // the wall past 750s. The test gets its own child, scheduled first;
        // the class's remainder runs as a separate job that overlaps it.
        // Both children compile a TRIMMED source set — the full set costs
        // ~180s of lowering per child, which sat inside the wall. The trim
        // is the class file plus the same-package files whose helpers it
        // reaches without imports (`Trigger` in EffectsTests,
        // `TestSubcomposition` in CompositionTests); an unlisted helper
        // fails loudly as an unresolved global, never silently.
        if (std.mem.eql(u8, cls, "RecomposerTests")) {
            var trimmed: std.ArrayList([]const u8) = .empty;
            for (sources.items) |src| {
                const in_test_dirs =
                    std.mem.indexOf(u8, src, "/commonTest/") != null or
                    std.mem.indexOf(u8, src, "/nonEmulatorCommonTest/") != null;
                const keep = !in_test_dirs or
                    std.mem.endsWith(u8, src, "/RecomposerTests.kt") or
                    std.mem.endsWith(u8, src, "/EffectsTests.kt") or
                    std.mem.endsWith(u8, src, "/CompositionTests.kt");
                if (keep) try trimmed.append(a, src);
            }
            var solo: std.ArrayList([]const u8) = .empty;
            // vpd IS the suite wall (537s solo test body, JIT-negative,
            // throughput-exhausted): it gets cores 0-5 to itself on a big
            // box — scripts/stack.sh pins everything else off them — and
            // every sibling child is spawned under nice so vpd's threads
            // keep the scheduler wherever masks overlap (siblings had
            // inflated the wall 554s solo -> 633s in-suite).
            if (std.c.getenv("KLIO_VPD_CPUS")) |cpus| {
                try solo.appendSlice(a, &.{ "taskset", "-c", std.mem.span(cpus) });
            } else if ((std.Thread.getCpuCount() catch 1) >= 16) {
                try solo.appendSlice(a, &.{ "taskset", "-c", "0-5" });
            }
            // vpd's 537s body spends ~15-20% in GC (shade 6.7% + alloc
            // paths, measured): a relaxed Appel factor + floor takes the
            // solo body to 494s. The knobs are per-child via argv so the
            // other children keep the default regime and RSS profile.
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
                // 480s: the skip calculus probes every composable call's
                // params through `$composer.changed`, so the big snapshot
                // classes run 2-3x longer than the implicit hook did; under
                // 8-way saturation they crossed a 240s cap while still making
                // progress and their (buffered, lost-on-kill) passes vanished
                // from the count — a deterministic 616 -> 403 that was pace,
                // not correctness.
                // RecomposerTests carries `validatePotentialDeadlock`, whose
                // cost is modelled (~724s to a full pass; see the campaign
                // plan) rather than wedged, so its class gets a budget that
                // fits it. Every other class keeps the 480s hang guard.
                const class_cap_ms: i64 = if (std.mem.indexOf(u8, names[i], "RecomposerTests") != null)
                    1_200_000
                else
                    480_000;
                const child_t0 = runtime.clockMonotonicNanos();
                const r = runKlio(arena.allocator(), penv, queue[i], class_cap_ms) catch {
                    _ = phung.fetchAdd(1, .monotonic);
                    // Name it. "2 did not complete" is not actionable; the
                    // class is what tells you whether it is the known
                    // throughput-bound pair or something new.
                    std.debug.print("compose_plugin_commontest: {s} did not complete (spawn/cap)\n", .{names[i]});
                    continue;
                };
                // A completed run counts its end-of-run summary; a killed
                // run's summary never printed, so its streamed per-test
                // lines carry the count — only the wedged test is lost.
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
                if (std.mem.indexOf(u8, r.stdout, " passed,") == null) {
                    _ = phung.fetchAdd(1, .monotonic);
                    // Name the cause: the child's termination and the tail of
                    // what it said, so a load-only incomplete is actionable.
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

    std.debug.print(
        "compose_plugin_commontest: {d} passed, {d} failed across {d} test classes, {d} did not complete (baseline {d})\n",
        .{ total_passed.load(.monotonic), total_failed.load(.monotonic), classes.items.len, hung.load(.monotonic), BASELINE },
    );
    // Names first: a red gate without the failing names is not actionable
    // (the expect aborts the test body).
    const failed = total_failed.load(.monotonic);
    failed_names.report("compose_plugin_commontest");
    try std.testing.expect(total_passed.load(.monotonic) >= BASELINE);
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
