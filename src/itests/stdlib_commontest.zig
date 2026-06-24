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
const runtime = @import("runtime");

/// Minimum number of stdlib commonTest cases that must pass. A ratchet: bump it
/// up as fixes land, never down. (Total discovered is ~2082; ~1213 pass.)
const BASELINE: usize = 1565;

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
    io: std.Io,
    env: *std.process.Environ.Map,
    argv: []const []const u8,
) !struct { term: std.process.Child.Term, stdout: []u8, stderr: []u8 } {
    _ = io;
    // A fresh threaded io per spawn keeps each run's timeout timer clean.
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const r = std.process.run(allocator, threaded.io(), .{
        .argv = argv,
        .environ_map = env,
        // A test file that makes the interpreter hang (infinite loop, not a
        // crash) must not stall the suite; cap each child.
        .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(200_000), .clock = .awake } },
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
    const b = try runKlio(allocator, io, env, &.{ klioBin(env), "pack", "build", "kotlin-klio/klio-kotlin-test" });
    if (b.term != .exited or b.term.exited != 0) {
        std.debug.print("stdlib_commontest: pack build failed:\n{s}\n", .{b.stderr});
        return error.PackBuildFailed;
    }
    const i = try runKlio(allocator, io, env, &.{ klioBin(env), "pack", "install", "target/packs/kotlin.test.klio-pack" });
    if (i.term != .exited or i.term.exited != 0) {
        std.debug.print("stdlib_commontest: pack install failed:\n{s}\n", .{i.stderr});
        return error.PackInstallFailed;
    }
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

    var total_passed: usize = 0;
    var build_blocked: usize = 0;
    for (targets.items) |target| {
        // Bound each child with `timeout`: a test file that makes the
        // interpreter hang (infinite loop, not a crash) must not stall the
        // whole suite. A killed child yields no summary -> counted as blocked.
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(a, klioBin(&env));
        try argv.append(a, "test");
        try argv.appendSlice(a, support.items);
        try argv.append(a, target);
        const r = try runKlio(a, io, &env, argv.items);
        if (passedCount(r.stdout)) |p| {
            total_passed += p;
        } else {
            build_blocked += 1;
        }
    }
    std.debug.print(
        "stdlib_commontest: {d} passed across {d} files, {d} build-blocked (baseline {d})\n",
        .{ total_passed, targets.items.len, build_blocked, BASELINE },
    );
    try std.testing.expect(total_passed >= BASELINE);
}
