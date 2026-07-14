//! Run the upstream Compose runtime's own test suite through `klio test`
//! against the installed `androidx.compose.runtime` pack.
//!
//! This is the conformance signal for klio's implicit-composer hook: the same
//! `CompositionTests` / `RestartTests` / `MovableContentTests` / `EffectsTests`
//! / snapshot suites androidx runs against the Compose compiler plugin, composed
//! here against the interpreter instead. They compose through the upstream mock
//! `View`/`Applier` harness (`runtime-test-utils`, the `compositionTest { … }`
//! scope), which the sparse checkout pulls in beside the sources.
//!
//! Layout: EVERY `.kt` under the roots is compiled into every child -- the test
//! files reference each other's fixtures across files (`RestartTests` composes
//! `ModelViewTests`' `Person` and its `PRESIDENT_NAME_*` constants), which a
//! per-file split would break. Isolation is by `--filter=<Class>` instead: one
//! child per test class, so one hanging class cannot take the rest down. Every
//! upstream test file declares a class named after the file. The pass count is a
//! ratchet -- raise `BASELINE` as fixes land, never lower it.
//!
//! Passes are counted from per-test `PASSED` lines rather than the summary, so a
//! file killed at the per-child cap still contributes what it proved.

const std = @import("std");
const runtime = @import("runtime");

/// Minimum number of upstream Compose runtime test cases that must pass. A
/// ratchet: bump it as core-composer fixes land, never down. 143 pass today;
/// the margin absorbs the timing variance of the parallel children.
const BASELINE: usize = 140;

const UPSTREAM = "kotlin-klio/klio-compose-runtime/upstream/compose/runtime";
/// The mock View/Applier harness the tests compose against, plus the two test
/// source sets. `runtime-test-utils` carries no `@Test`, so all of it lands in
/// the shared-fixture set.
const ROOTS = [_][]const u8{
    UPSTREAM ++ "/runtime-test-utils/src/commonMain/kotlin",
    UPSTREAM ++ "/runtime/src/commonTest/kotlin",
    UPSTREAM ++ "/runtime/src/nonEmulatorCommonTest/kotlin",
};
const SCRATCH_HOME = "/tmp/klio_itest_compose_runtime_home";

const Pack = struct { dir: []const u8, artifact: []const u8 };
/// Dependency order: the compose runtime pack sits on collection, atomicfu,
/// coroutines (the tests drive `runTest` / `TestCoroutineScheduler`) and
/// kotlin.test.
const PACKS = [_]Pack{
    .{ .dir = "kotlin-klio/klio-kotlinx-atomicfu", .artifact = "target/packs/kotlinx.atomicfu.klio-pack" },
    .{ .dir = "kotlin-klio/klio-kotlin-test", .artifact = "target/packs/kotlin.test.klio-pack" },
    .{ .dir = "kotlin-klio/klio-kotlinx-coroutines", .artifact = "target/packs/kotlinx.coroutines.klio-pack" },
    .{ .dir = "kotlin-klio/klio-androidx-collection", .artifact = "target/packs/androidx.collection.klio-pack" },
    .{ .dir = "kotlin-klio/klio-compose-runtime", .artifact = "target/packs/androidx.compose.runtime.klio-pack" },
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
    const r = std.process.run(allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = env,
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake } },
    }) catch |e| {
        if (e == error.Timeout) return .{ .term = .{ .exited = 124 }, .stdout = "", .stderr = "" };
        std.debug.print("compose_runtime_commontest: spawn {s} failed: {s}\n", .{ argv[0], @errorName(e) });
        return error.SpawnFailed;
    };
    return .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
}

fn installPacks(allocator: std.mem.Allocator, env: *std.process.Environ.Map) !void {
    for (PACKS) |p| {
        const b = try runKlio(allocator, env, &.{ klioBin(env), "pack", "build", p.dir }, 600_000);
        if (b.term != .exited or b.term.exited != 0) {
            std.debug.print("compose_runtime_commontest: pack build {s} failed:\n{s}\n", .{ p.dir, b.stderr });
            return error.PackBuildFailed;
        }
        const i = try runKlio(allocator, env, &.{ klioBin(env), "pack", "install", p.artifact }, 120_000);
        if (i.term != .exited or i.term.exited != 0) {
            std.debug.print("compose_runtime_commontest: pack install {s} failed:\n{s}\n", .{ p.artifact, i.stderr });
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

/// The test CLASS a file contributes, or null when it declares none: `@Test`
/// alone is not enough (two helper files merely mention it). Upstream names the
/// class after the file, which `--filter` then selects.
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

var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);

test "compose runtime commonTest pass count holds at or above the ratchet baseline" {
    const a = arena_inst.allocator();
    defer _ = arena_inst.reset(.free_all);
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.Io.Dir.cwd().access(io, ROOTS[0], .{}) catch {
        std.debug.print(
            "compose_runtime_commontest: test sources missing; run scripts/init-compose-submodule.sh\n",
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

    // Every source goes into every child; `--filter` picks the one class.
    var sources: std.ArrayList([]const u8) = .empty;
    var classes: std.ArrayList([]const u8) = .empty;
    for (all.items) |p| {
        try sources.append(a, p);
        if (testClassOf(a, io, p)) |cls| try classes.append(a, cls);
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
                const r = runKlio(arena.allocator(), penv, queue[i], 240_000) catch {
                    _ = phung.fetchAdd(1, .monotonic);
                    continue;
                };
                _ = ppassed.fetchAdd(passedLineCount(r.stdout), .monotonic);
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
        "compose_runtime_commontest: {d} passed across {d} test classes, {d} did not complete (baseline {d})\n",
        .{ total_passed.load(.monotonic), classes.items.len, hung.load(.monotonic), BASELINE },
    );
    try std.testing.expect(total_passed.load(.monotonic) >= BASELINE);
}
