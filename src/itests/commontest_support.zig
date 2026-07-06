//! Shared driver for library `commonTest` suites: discover a library's own
//! upstream common test tree, build and install its pack (plus deps), and run
//! every `@Test`-bearing file through a child `klio test` against the pack.
//!
//! A file without `@Test` is a shared fixture, compiled into every test file's
//! module; `extra_support` files (klio-authored platform actuals) are added the
//! same way. Pass counting is per-`PASSED`-line so a file killed mid-run still
//! contributes the cases it printed before the kill. The suite ratchets on the
//! total pass count; raise the baseline as fixes land, never lower it.

const std = @import("std");
const runtime = @import("runtime");

pub const Pack = struct { dir: []const u8, artifact: []const u8 };

pub const Config = struct {
    /// Short label for log lines (e.g. "atomicfu").
    name: []const u8,
    /// One or more common test directories to discover recursively.
    test_roots: []const []const u8,
    /// Per-suite scratch HOME the child packs install into.
    scratch_home: []const u8,
    /// Packs to build+install, in dependency order (deps before dependents).
    packs: []const Pack,
    /// Minimum total passing cases. A ratchet floor; raise as fixes land.
    baseline: usize,
    /// klio-authored actual/fixture files added to every test file's module.
    extra_support: []const []const u8 = &.{},
    /// Per-file child timeout.
    timeout_ms: i64 = 60_000,
    /// Once a suite reaches full coverage, set true to also fail on any
    /// non-passing case (a hard 100% gate on top of the ratchet).
    require_no_failures: bool = false,
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

const RunResult = struct { term: std.process.Child.Term, stdout: []u8, stderr: []u8 };

fn runKlio(
    allocator: std.mem.Allocator,
    env: *std.process.Environ.Map,
    argv: []const []const u8,
    timeout_ms: i64,
) !RunResult {
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const r = std.process.run(allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = env,
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake } },
    }) catch |e| {
        if (e == error.Timeout) return .{ .term = .{ .exited = 124 }, .stdout = "", .stderr = "" };
        std.debug.print("{s}_commontest: spawn {s} failed: {s}\n", .{ argv[0], argv[0], @errorName(e) });
        return error.SpawnFailed;
    };
    return .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr };
}

fn installPacks(allocator: std.mem.Allocator, env: *std.process.Environ.Map, cfg: Config) !void {
    for (cfg.packs) |p| {
        const b = try runKlio(allocator, env, &.{ klioBin(env), "pack", "build", p.dir }, 120_000);
        if (b.term != .exited or b.term.exited != 0) {
            std.debug.print("{s}_commontest: pack build {s} failed:\n{s}\n", .{ cfg.name, p.dir, b.stderr });
            return error.PackBuildFailed;
        }
        const i = try runKlio(allocator, env, &.{ klioBin(env), "pack", "install", p.artifact }, 120_000);
        if (i.term != .exited or i.term.exited != 0) {
            std.debug.print("{s}_commontest: pack install {s} failed:\n{s}\n", .{ cfg.name, p.artifact, i.stderr });
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

/// Count per-test `PASSED` lines (`<Class>.<method> PASSED`). Robust to a file
/// killed mid-run: passes printed before the kill still count.
fn passedLineCount(stdout: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        if (std.mem.endsWith(u8, line, " PASSED")) n += 1;
    }
    return n;
}

/// Sum the `N failed` counts from every `M tests, ... N failed, ...` summary
/// line the run printed.
fn failedCount(stdout: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const marker = " failed,";
        const idx = std.mem.indexOf(u8, line, marker) orelse continue;
        var start = idx;
        while (start > 0 and line[start - 1] >= '0' and line[start - 1] <= '9') start -= 1;
        n += std.fmt.parseInt(usize, line[start..idx], 10) catch 0;
    }
    return n;
}

var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);

/// Run one library's commonTest suite and assert the pass-count ratchet.
pub fn runSuite(cfg: Config) !void {
    const a = arena_inst.allocator();
    defer _ = arena_inst.reset(.free_all);
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var any_root = false;
    for (cfg.test_roots) |root| {
        if (std.Io.Dir.cwd().access(io, root, .{})) |_| any_root = true else |_| {}
    }
    if (!any_root) {
        std.debug.print("{s}_commontest: no commonTest path present; skipping\n", .{cfg.name});
        return error.SkipZigTest;
    }

    std.Io.Dir.cwd().createDirPath(io, cfg.scratch_home) catch {};
    var env = try envWithHome(a, cfg.scratch_home);
    try installPacks(a, &env, cfg);

    var all: std.ArrayList([]u8) = .empty;
    for (cfg.test_roots) |root| try collectKt(a, io, root, &all);
    std.mem.sort([]u8, all.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);

    var support: std.ArrayList([]const u8) = .empty;
    for (cfg.extra_support) |s| try support.append(a, s);
    var targets: std.ArrayList([]const u8) = .empty;
    for (all.items) |p| {
        if (fileHasTest(a, io, p)) try targets.append(a, p) else try support.append(a, p);
    }

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
    var hung = std.atomic.Value(usize).init(0);
    const Pool = struct {
        fn worker(
            queue: []const []const []const u8,
            penv: *std.process.Environ.Map,
            pnext: *std.atomic.Value(usize),
            ppassed: *std.atomic.Value(usize),
            pfailed: *std.atomic.Value(usize),
            phung: *std.atomic.Value(usize),
            timeout_ms: i64,
        ) void {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            while (true) {
                const i = pnext.fetchAdd(1, .monotonic);
                if (i >= queue.len) return;
                _ = arena.reset(.retain_capacity);
                const r = runKlio(arena.allocator(), penv, queue[i], timeout_ms) catch {
                    _ = phung.fetchAdd(1, .monotonic);
                    continue;
                };
                _ = ppassed.fetchAdd(passedLineCount(r.stdout), .monotonic);
                _ = pfailed.fetchAdd(failedCount(r.stdout), .monotonic);
                if (std.mem.indexOf(u8, r.stdout, " passed,") == null) _ = phung.fetchAdd(1, .monotonic);
            }
        }
    };
    var threads: std.ArrayList(std.Thread) = .empty;
    for (0..workerCount()) |_| {
        try threads.append(a, try std.Thread.spawn(.{}, Pool.worker, .{
            @as([]const []const []const u8, jobs.items), &env, &next, &total_passed, &total_failed, &hung, cfg.timeout_ms,
        }));
    }
    for (threads.items) |t| t.join();

    const passed = total_passed.load(.monotonic);
    const failed = total_failed.load(.monotonic);
    std.debug.print(
        "{s}_commontest: {d} passed, {d} failed across {d} files, {d} did not complete (baseline {d})\n",
        .{ cfg.name, passed, failed, targets.items.len, hung.load(.monotonic), cfg.baseline },
    );
    try std.testing.expect(passed >= cfg.baseline);
    if (cfg.require_no_failures) try std.testing.expectEqual(@as(usize, 0), failed);
}
