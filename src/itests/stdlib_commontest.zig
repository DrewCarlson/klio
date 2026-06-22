//! Bootstrapping proof: run Kotlin's own stdlib `commonTest` sources through
//! `klio test` against the installed `kotlin.test` pack. The curated list is
//! the subset that currently passes end to end; it grows monotonically as the
//! interpreter closes the remaining gaps. Each file is referenced in place
//! from the `kotlin` submodule (`kotlin/libraries/stdlib/test`), unmodified.
//!
//! A child `klio` is spawned (its exit code is the pass/fail signal) so a
//! crash in one program isolates instead of taking down this test process.

const std = @import("std");
const runtime = @import("runtime");

/// Curated upstream stdlib commonTest files that pass through `klio test`.
/// Add entries here as interpreter gaps close; never remove one to hide a
/// regression.
const PASSING = [_][]const u8{
    "kotlin/libraries/stdlib/test/utils/HashCodeTest.kt",
    "kotlin/libraries/stdlib/test/collections/IteratorsTest.kt",
    "kotlin/libraries/stdlib/test/utils/LazyTest.kt",
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
) !struct { ok: bool, stdout: []u8, stderr: []u8 } {
    const r = std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = env,
    }) catch |e| {
        std.debug.print("stdlib_commontest: spawn {s} failed: {s}\n", .{ argv[0], @errorName(e) });
        return error.SpawnFailed;
    };
    const ok = switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
    return .{ .ok = ok, .stdout = r.stdout, .stderr = r.stderr };
}

/// Build + install the `kotlin.test` pack into the scratch HOME.
fn installKotlinTestPack(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, home: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, home) catch {};
    const build_r = try runKlio(allocator, io, env, &.{ klioBin(env), "pack", "build", "kotlin-klio/klio-kotlin-test" });
    if (!build_r.ok) {
        std.debug.print("stdlib_commontest: pack build failed:\n{s}\n", .{build_r.stderr});
        return error.PackBuildFailed;
    }
    const install_r = try runKlio(allocator, io, env, &.{ klioBin(env), "pack", "install", "target/packs/kotlin.test.klio-pack" });
    if (!install_r.ok) {
        std.debug.print("stdlib_commontest: pack install failed:\n{s}\n", .{install_r.stderr});
        return error.PackInstallFailed;
    }
}

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

test "stdlib commonTest subset passes through klio test" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The kotlin.test sources live in the sparse `kotlin` submodule. If it has
    // not been populated (scripts/init-kotlin-submodule.sh), skip rather than
    // fail spuriously.
    std.Io.Dir.cwd().access(io, "kotlin/libraries/kotlin.test", .{}) catch {
        std.debug.print("stdlib_commontest: kotlin.test submodule path missing; skipping\n", .{});
        return error.SkipZigTest;
    };

    var env = try envWithHome(a, SCRATCH_HOME);
    try installKotlinTestPack(a, io, &env, SCRATCH_HOME);

    for (PASSING) |file| {
        const r = try runKlio(a, io, &env, &.{ klioBin(&env), "test", file });
        if (!r.ok) {
            std.debug.print("stdlib_commontest: {s} did not pass:\n{s}\n{s}\n", .{ file, r.stdout, r.stderr });
            return error.StdlibTestFailed;
        }
        // `klio test` exits 0 only with zero failures; confirm the summary too.
        try std.testing.expect(std.mem.indexOf(u8, r.stdout, "0 failed") != null);
    }
}
