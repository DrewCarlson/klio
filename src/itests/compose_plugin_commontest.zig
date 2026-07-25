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
//! Structure mirrors compose_runtime_commontest.zig: every `.kt` under the
//! roots compiles into every child (cross-file fixtures), isolation is one
//! child per test class via `--filter`, passes are counted from per-test
//! `PASSED` lines, and the pass count is a ratchet — raise `BASELINE` as
//! fixes land, never lower it.

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
const BASELINE: usize = 1210;

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
    // should fail in 10s, not hold its class's child (and the pump's job
    // tree) for a minute per occurrence.
    try map.put("kotlinx_coroutines_test_default_timeout", "10s");
    try map.put("KLIO_COMPOSE_PLUGIN", "1");
    // Per-test wall cap: a test that genuinely deadlocks (the Recomposer
    // deadlock-regression shape, the concurrent-mixing teardown stall) fails
    // in place instead of eating the class's whole 480s budget — its
    // classmates' passes stay counted. Generous enough for the compute-heavy
    // benchmark tests under 8-way contention.
    try map.put("KLIO_TEST_WALL_CAP", "90");
    return map;
}

fn workerCount() usize {
    const cores = std.Thread.getCpuCount() catch 4;
    return std.math.clamp(cores, 1, 8);
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

/// The test CLASS a file contributes, or null when it declares none (see
/// compose_runtime_commontest.zig).
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
    const stress = try runKlio(a, &env, stress_argv.items, 30_000);
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
    for (classes.items) |cls| {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, klioBin(&env));
        try argv.append(a, "test");
        try argv.appendSlice(a, sources.items);
        try argv.append(a, try std.fmt.allocPrint(a, "--filter={s}", .{cls}));
        try jobs.append(a, try argv.toOwnedSlice(a));
    }

    var next = std.atomic.Value(usize).init(0);
    var total_passed = std.atomic.Value(usize).init(0);
    var hung = std.atomic.Value(usize).init(0);
    const Pool = struct {
        fn worker(
            queue: []const []const []const u8,
            penv: *std.process.Environ.Map,
            pnext: *std.atomic.Value(usize),
            ppassed: *std.atomic.Value(usize),
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
                const r = runKlio(arena.allocator(), penv, queue[i], 480_000) catch {
                    _ = phung.fetchAdd(1, .monotonic);
                    continue;
                };
                // A completed run counts its end-of-run summary; a killed
                // run's summary never printed, so its streamed per-test
                // lines carry the count — only the wedged test is lost.
                const summary_count = passedLineCount(r.stdout);
                const n_passed = if (summary_count != 0) summary_count else streamedPassedCount(r.stderr);
                _ = ppassed.fetchAdd(n_passed, .monotonic);
                if (std.mem.indexOf(u8, r.stdout, " passed,") == null) _ = phung.fetchAdd(1, .monotonic);
            }
        }
    };
    var threads: std.ArrayList(std.Thread) = .empty;
    for (0..workerCount()) |_| {
        try threads.append(a, try std.Thread.spawn(.{}, Pool.worker, .{
            @as([]const []const []const u8, jobs.items), &env, &next, &total_passed, &hung,
        }));
    }
    for (threads.items) |t| t.join();

    std.debug.print(
        "compose_plugin_commontest: {d} passed across {d} test classes, {d} did not complete (baseline {d})\n",
        .{ total_passed.load(.monotonic), classes.items.len, hung.load(.monotonic), BASELINE },
    );
    try std.testing.expect(total_passed.load(.monotonic) >= BASELINE);
}
