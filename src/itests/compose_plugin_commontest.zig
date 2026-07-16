//! Run the upstream Compose runtime's own test suite through `klio test`
//! against the installed ENGINE pack with the `@Composable` lowering plugin
//! (`KLIO_COMPOSE_PLUGIN=1`).
//!
//! The conformance signal for the plugin path that replaces the implicit
//! composer hook: the same test classes as `compose_runtime_commontest`, but
//! the `androidx.compose.runtime` id resolves to the real upstream
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
/// the plugin. A ratchet: bump it as fixes land, never down. First measured
/// run: 616 standalone (vs 445 for the implicit hook), 19 classes incomplete;
/// the floor leaves saturation headroom like the implicit suite's does.
const BASELINE: usize = 550;

const UPSTREAM = "kotlin-klio/klio-compose-runtime/upstream/compose/runtime";
const ROOTS = [_][]const u8{
    UPSTREAM ++ "/runtime-test-utils/src/commonMain/kotlin",
    UPSTREAM ++ "/runtime/src/commonTest/kotlin",
    UPSTREAM ++ "/runtime/src/nonEmulatorCommonTest/kotlin",
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
    try map.put("KLIO_COMPOSE_PLUGIN", "1");
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
        std.debug.print("compose_plugin_commontest: spawn {s} failed: {s}\n", .{ argv[0], @errorName(e) });
        return error.SpawnFailed;
    };
    return .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
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
        "compose_plugin_commontest: {d} passed across {d} test classes, {d} did not complete (baseline {d})\n",
        .{ total_passed.load(.monotonic), classes.items.len, hung.load(.monotonic), BASELINE },
    );
    try std.testing.expect(total_passed.load(.monotonic) >= BASELINE);
}
