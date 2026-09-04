//! Bootstrapping proof: run Kotlin's own stdlib `commonTest` sources through
//! `klio test` against the installed `kotlin.test` pack.
//!
//! The whole common test tree (`kotlin/libraries/stdlib/test`, minus the `js/`
//! platform source set) is discovered automatically — there is no per-test
//! include/exclude list. Files without `@Test` are shared fixtures (testUtils,
//! the comparison DSLs); they are compiled into every test file's module. KLIO
//! actuals for the test infrastructure's `expect` declarations live in
//! `tests/stdlib_commontest_actuals`.
//!
//! Each test file runs in its own child `klio` (a crash isolates to one file),
//! and the run asserts the total number of passing tests stays at or above a
//! ratchet baseline. Raise `BASELINE` as interpreter gaps close; never lower it.

const std = @import("std");
const census_support = @import("commontest_support.zig");
const runtime = @import("runtime");

/// Minimum number of stdlib commonTest cases that must pass. A ratchet: bump it
/// up as fixes land, never down. (Total discovered is ~2082.)
const BASELINE: usize = 2150;

/// Ceiling on *failing* cases, the mirror of `BASELINE`. A pass floor cannot
/// see a regression inside the red mass; this bounds the other direction.
/// Measured solo across both shards: 1024+1277 passed, 0 failed, 0
/// build-blocked — every stdlib case that runs, passes, so a single new
/// failure is a real regression and trips this. A file that cannot produce a
/// summary at all is counted as `build-blocked`, not as a failure.
const MAX_FAILED: usize = 0;

const TEST_ROOT = "kotlin/libraries/stdlib/test";
const ACTUALS = [_][]const u8{
    "tests/stdlib_commontest_actuals/PlatformActuals.kt",
    "tests/stdlib_commontest_actuals/EncodingActuals.kt",
    "tests/stdlib_commontest_actuals/JsCollectionFactories.kt",
};
const SCRATCH_HOME = "/tmp/klio_itest_stdlibtest_home";

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

fn runKlio(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    argv: []const []const u8,
) !struct { term: std.process.Child.Term, stdout: []u8, stderr: []u8 } {
    // A fresh threaded io per spawn keeps each run's timeout timer clean.
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const r = std.process.run(allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = env,
        // A test file that makes the interpreter hang (infinite loop, not a
        // crash) must not stall the suite; cap each child. Sized above the
        // slowest legitimate job (DeepRecursiveTest interprets ~400k
        // coroutine resumes and needs ~300s solo — the unwind-cost residual
        // in the resolution-unification plan) so a slow-but-linear pass is
        // never miscounted as blocked.
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(480_000 * census_support.harnessSlowdown(env)), .clock = .awake } },
    }) catch |e| {
        // A timed-out (hanging) child is reported as a blocked file, not a
        // hard spawn failure.
        if (e == error.Timeout) return .{ .term = .{ .exited = 124 }, .stdout = "", .stderr = "" };
        std.debug.print("stdlib_commontest: spawn {s} failed: {s}\n", .{ argv[0], @errorName(e) });
        return error.SpawnFailed;
    };
    return .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
}

fn installKotlinTestPack(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, home: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, home) catch {};
    const b = try runKlio(allocator, env, &.{ klioBin(env), "pack", "build", "kotlin-klio/klio-kotlin-test" });
    if (b.term != .exited or b.term.exited != 0) {
        std.debug.print("stdlib_commontest: pack build failed:\n{s}\n", .{b.stderr});
        return error.PackBuildFailed;
    }
    const i = try runKlio(allocator, env, &.{ klioBin(env), "pack", "install", "target/packs/kotlin.test.klio-pack" });
    if (i.term != .exited or i.term.exited != 0) {
        std.debug.print("stdlib_commontest: pack install failed:\n{s}\n", .{i.stderr});
        return error.PackInstallFailed;
    }
}

/// Concurrent child count. Each child is one `klio test` process; the pool
/// keeps the cores busy while the slowest files run.
fn workerCount() usize {
    const cores = std.Thread.getCpuCount() catch 4;
    // Half the cores, capped low: suites run beside sweeps and editors,
    // and each child is itself a multi-threaded interpreter.
    return std.math.clamp(cores / 2, 1, 4);
}

/// Recursively collect every `.kt` under `dir`, skipping the `js/` platform
/// source set. Paths are arena-owned.
fn collectKt(a: std.mem.Allocator, io: std.Io, dir: []const u8, out: *std.ArrayList([]u8)) !void {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            if (std.mem.eql(u8, entry.name, "js")) continue;
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

/// Number of `@Test` occurrences in a file — the shard-balancing weight.
fn testCount(a: std.mem.Allocator, io: std.Io, path: []const u8) usize {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch return 0;
    return std.mem.count(u8, bytes, "@Test");
}

/// Parse the "<n> tests, <p> passed, ..." summary line for the passed count.
fn passedCount(stdout: []const u8) ?usize {
    const idx = std.mem.indexOf(u8, stdout, " passed,") orelse return null;
    var end = idx;
    while (end > 0 and stdout[end - 1] == ' ') end -= 1;
    var start = end;
    while (start > 0 and std.ascii.isDigit(stdout[start - 1])) start -= 1;
    if (start == end) return null;
    return std.fmt.parseInt(usize, stdout[start..end], 10) catch null;
}

/// Parse the "<n> tests, <p> passed, <f> failed" summary line for the failed
/// count. The mirror of `passedCount`: a pass floor cannot see a regression
/// inside the red mass, so the failure total is bounded too.
fn failedCount(stdout: []const u8) ?usize {
    const idx = std.mem.indexOf(u8, stdout, " failed,") orelse
        std.mem.lastIndexOf(u8, stdout, " failed") orelse return null;
    var end = idx;
    while (end > 0 and stdout[end - 1] == ' ') end -= 1;
    var start = end;
    while (start > 0 and std.ascii.isDigit(stdout[start - 1])) start -= 1;
    if (start == end) return null;
    return std.fmt.parseInt(usize, stdout[start..end], 10) catch null;
}

/// Extract the symbol name from `import test.<pkg>.<Name>` (null otherwise).
fn importedTestName(line: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, t, "import ")) return null;
    var rest = std.mem.trim(u8, t["import ".len..], " \t\r");
    if (!std.mem.startsWith(u8, rest, "test.")) return null;
    if (std.mem.indexOfAny(u8, rest, " \t")) |sp| rest = rest[0..sp];
    rest = std.mem.trimEnd(u8, rest, ";");
    const dot = std.mem.lastIndexOfScalar(u8, rest, '.') orelse return null;
    const name = rest[dot + 1 ..];
    if (name.len == 0 or std.mem.eql(u8, name, "*")) return null;
    return name;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Whether `hay` contains `word` bounded by non-identifier characters.
fn hasWord(hay: []const u8, word: []const u8) bool {
    if (word.len == 0) return false;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, hay, i, word)) |p| {
        const before_ok = p == 0 or !isIdentChar(hay[p - 1]);
        const after = p + word.len;
        const after_ok = after >= hay.len or !isIdentChar(hay[after]);
        if (before_ok and after_ok) return true;
        i = p + 1;
    }
    return false;
}

/// Whether `content` has a top-level declaration line naming `name`.
fn declaresTopLevel(content: []const u8, name: []const u8) bool {
    const kws = [_][]const u8{ "val", "var", "fun", "class", "object", "interface", "typealias", "enum" };
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (!hasWord(line, name)) continue;
        for (kws) |kw| if (hasWord(line, kw)) return true;
    }
    return false;
}

var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);

test "stdlib commonTest pass count holds at or above the ratchet baseline" {
    const a = arena_inst.allocator();
    defer _ = arena_inst.reset(.free_all);
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.Io.Dir.cwd().access(io, "kotlin/libraries/kotlin.test", .{}) catch {
        std.debug.print("stdlib_commontest: kotlin.test submodule path missing; skipping\n", .{});
        return error.SkipZigTest;
    };

    var env = try envWithHome(a, SCRATCH_HOME);
    // A Debug harness interprets several times slower than the ReleaseSafe
    // build the per-test wall caps are tuned on; scale them to match.
    const slowdown = census_support.harnessSlowdown(&env);
    if (slowdown != 1) try census_support.scaleWallCaps(a, &env, slowdown);
    try installKotlinTestPack(a, io, &env, SCRATCH_HOME);

    var all: std.ArrayList([]u8) = .empty;
    try collectKt(a, io, TEST_ROOT, &all);
    std.mem.sort([]u8, all.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    // Fixtures (no `@Test`) are compiled into every test file's module.
    var support: std.ArrayList([]const u8) = .empty;
    for (ACTUALS) |p| try support.append(a, p);
    var targets: std.ArrayList([]const u8) = .empty;
    for (all.items) |p| {
        if (fileHasTest(a, io, p)) try targets.append(a, p) else try support.append(a, p);
    }

    // A `@Test` file may also export a top-level helper (e.g. a shared
    // Comparator) that tests in another directory import via `import test.X.Y`.
    // The real Kotlin module compiles every file together; mirror that by
    // compiling the UNIQUE provider of each imported `test.*` symbol as extra
    // context. Ambiguous names (declared by more than one target) are skipped
    // so no name clash is introduced.
    var imported_names: std.StringHashMap(void) = .init(a);
    for (targets.items) |t| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, t, a, .unlimited) catch continue;
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |line| {
            if (importedTestName(line)) |n| try imported_names.put(n, {});
        }
    }
    var provider: std.StringHashMap([]const u8) = .init(a);
    var ambiguous: std.StringHashMap(void) = .init(a);
    for (targets.items) |t| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, t, a, .unlimited) catch continue;
        var kit = imported_names.keyIterator();
        while (kit.next()) |k| {
            if (!declaresTopLevel(bytes, k.*)) continue;
            if (provider.contains(k.*)) {
                try ambiguous.put(k.*, {});
            } else {
                try provider.put(k.*, t);
            }
        }
    }
    var ait = ambiguous.keyIterator();
    while (ait.next()) |k| _ = provider.remove(k.*);

    // Build every child's argv up front (file reads stay on the shared
    // arena), then drain the queue with a worker pool. Each child is one
    // isolated `klio test` process, so the only cross-thread state is the
    // two counters.
    //
    // Each child is bounded with `timeout`: a test file that makes the
    // interpreter hang (infinite loop, not a crash) must not stall the
    // whole suite. A killed child yields no summary -> counted as blocked.
    //
    // A test file's top-level helpers (a shared `data class Sortable`, an
    // `assertAlmostEquals`) frequently live in a *sibling* test file that
    // also carries its own `@Test`s — the real Kotlin module compiles
    // every file together. Compile every same-directory sibling target as
    // context so those helpers resolve, and restrict the run to this
    // target's own tests with `--only-file` so siblings' tests do not
    // double-count.
    // KLIO_COMMONTEST_SHARD=K/N slices the sorted target list by stride so
    // CI fans this suite across parallel jobs; sibling-context resolution
    // still sees the full target set. The ratchet applies proportionally
    // (with a small slack for uneven per-file pass counts) when sharded.
    var shard_k: usize = 0;
    var shard_n: usize = 1;
    if (runtime.envOnce("KLIO_COMMONTEST_SHARD")) |s| {
        if (std.mem.indexOfScalar(u8, s, '/')) |sep| {
            const k = std.fmt.parseInt(usize, s[0..sep], 10) catch 0;
            const n = std.fmt.parseInt(usize, s[sep + 1 ..], 10) catch 1;
            if (n != 0 and k < n) {
                shard_k = k;
                shard_n = n;
            }
        }
    }

    // Weighted shard assignment. Stride slicing splits pass-mass badly —
    // passes cluster in a few big files, and a slice's share of the total
    // swung well past the ±25% the coarse ratchet's slack assumes (shard
    // halves measured 720 vs 1394). Weight each target by its `@Test`
    // count and greedy-assign to the lightest shard: every shard process
    // computes the same assignment from the same file contents, and the
    // weight split lands within a few percent of proportional.
    const shard_of = try a.alloc(usize, targets.items.len);
    var my_weight: usize = 0;
    var total_weight: usize = 0;
    {
        const loads = try a.alloc(usize, shard_n);
        @memset(loads, 0);
        for (targets.items, 0..) |t, ti| {
            const w = @max(testCount(a, io, t), 1);
            total_weight += w;
            var best: usize = 0;
            for (loads, 0..) |ld, si| {
                if (ld < loads[best]) best = si;
            }
            shard_of[ti] = best;
            loads[best] += w;
        }
        my_weight = loads[shard_k];
    }

    var jobs: std.ArrayList([]const []const u8) = .empty;
    var my_targets: usize = 0;
    for (targets.items, 0..) |target, ti| {
        if (shard_of[ti] != shard_k) continue;
        my_targets += 1;
        const tdir = std.fs.path.dirname(target) orelse "";
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, klioBin(&env));
        try argv.append(a, "test");
        try argv.append(a, try std.fmt.allocPrint(a, "--only-file={s}", .{target}));
        try argv.appendSlice(a, support.items);
        for (targets.items) |sibling| {
            if (std.mem.eql(u8, sibling, target)) continue;
            const sdir = std.fs.path.dirname(sibling) orelse "";
            if (std.mem.eql(u8, sdir, tdir)) try argv.append(a, sibling);
        }
        // Cross-directory providers of imported `test.*` symbols.
        {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, target, a, .unlimited) catch "";
            var seen: std.StringHashMap(void) = .init(a);
            var it = std.mem.splitScalar(u8, bytes, '\n');
            while (it.next()) |line| {
                const n = importedTestName(line) orelse continue;
                const pf = provider.get(n) orelse continue;
                if (std.mem.eql(u8, pf, target)) continue;
                const pdir = std.fs.path.dirname(pf) orelse "";
                if (std.mem.eql(u8, pdir, tdir)) continue;
                if (seen.contains(pf)) continue;
                try seen.put(pf, {});
                try argv.append(a, pf);
            }
        }
        try argv.append(a, target);
        try jobs.append(a, try argv.toOwnedSlice(a));
    }

    var next = std.atomic.Value(usize).init(0);
    var total_passed = std.atomic.Value(usize).init(0);
    var total_failed = std.atomic.Value(usize).init(0);
    var build_blocked = std.atomic.Value(usize).init(0);
    const Pool = struct {
        fn worker(
            queue: []const []const []const u8,
            penv: *std.process.Environ.Map,
            pnext: *std.atomic.Value(usize),
            ppassed: *std.atomic.Value(usize),
            pfailed: *std.atomic.Value(usize),
            pblocked: *std.atomic.Value(usize),
        ) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            while (true) {
                const i = pnext.fetchAdd(1, .monotonic);
                if (i >= queue.len) return;
                _ = arena.reset(.retain_capacity);
                // The job's target file is the argv tail (jobs append it last).
                const target = queue[i][queue[i].len - 1];
                const r = runKlio(arena.allocator(), penv, queue[i]) catch |e| {
                    std.debug.print("build-blocked (spawn: {t}): {s}\n", .{ e, target });
                    _ = pblocked.fetchAdd(1, .monotonic);
                    continue;
                };
                if (passedCount(r.stdout)) |p| {
                    _ = ppassed.fetchAdd(p, .monotonic);
                    if (failedCount(r.stdout)) |f| {
                        _ = pfailed.fetchAdd(f, .monotonic);
                        // Name every failing case (with its first detail
                        // line) so a red run is actionable from the log.
                        if (f != 0) {
                            var lines = std.mem.splitScalar(u8, r.stdout, '\n');
                            var prev_failed = false;
                            while (lines.next()) |line| {
                                if (prev_failed and line.len != 0 and (line[0] == ' ' or line[0] == '\t')) {
                                    std.debug.print("[stdlib-err] {s}\n", .{std.mem.trim(u8, line, " \t")});
                                }
                                prev_failed = std.mem.endsWith(u8, line, " FAILED");
                                if (prev_failed) std.debug.print("[stdlib-fail] {s} <- {s}\n", .{ line, target });
                            }
                        }
                    }
                } else {
                    std.debug.print("build-blocked (no pass summary): {s}\n", .{target});
                    _ = pblocked.fetchAdd(1, .monotonic);
                }
            }
        }
    };
    var threads: std.ArrayList(std.Thread) = .empty;
    for (0..workerCount()) |_| {
        try threads.append(a, try std.Thread.spawn(.{}, Pool.worker, .{
            @as([]const []const []const u8, jobs.items), &env, &next, &total_passed, &total_failed, &build_blocked,
        }));
    }
    for (threads.items) |t| t.join();

    // Sharded: a coarse ratchet — the weighted assignment lands each
    // shard within a few percent of its proportional share, so the slack
    // only has to absorb pass/fail clustering inside files. The slice
    // gate catches collapse-class regressions; the EXACT ratchet is
    // enforced by every unsharded run (local test-all, nightly).
    const min_pass = if (shard_n == 1)
        BASELINE
    else
        (BASELINE * my_weight / @max(total_weight, 1)) * 80 / 100;
    std.debug.print(
        "stdlib_commontest: {d} passed, {d} failed across {d}/{d} files (shard {d}/{d}), {d} build-blocked (min {d}, baseline {d})\n",
        .{
            total_passed.load(.monotonic),  total_failed.load(.monotonic), my_targets,
            targets.items.len,              shard_k,                       shard_n,
            build_blocked.load(.monotonic), min_pass,                      BASELINE,
        },
    );
    try std.testing.expect(total_passed.load(.monotonic) >= min_pass);
    const failed = total_failed.load(.monotonic);
    if (failed > MAX_FAILED) {
        std.debug.print(
            "stdlib_commontest: {d} failed exceeds the ceiling {d}\n",
            .{ failed, MAX_FAILED },
        );
        return error.FailureCeilingExceeded;
    }
}

test "failedCount parses the child summary (negative control for a zero)" {
    // A zero failure total is only trustworthy if the parser can see a
    // non-zero one. Same shapes the child actually prints.
    try std.testing.expectEqual(@as(?usize, 7), failedCount("40 tests, 33 passed, 7 failed, 0 skipped\n"));
    try std.testing.expectEqual(@as(?usize, 0), failedCount("40 tests, 40 passed, 0 failed, 0 skipped\n"));
    try std.testing.expectEqual(@as(?usize, 12), failedCount("12 failed"));
    try std.testing.expectEqual(@as(?usize, null), failedCount("no summary here\n"));
    // The pass parser must not be fooled by the failure field, and vice versa.
    try std.testing.expectEqual(@as(?usize, 33), passedCount("40 tests, 33 passed, 7 failed\n"));
}
