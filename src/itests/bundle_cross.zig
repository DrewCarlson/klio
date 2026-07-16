//! Cross-target bundling gate: `klio bundle --target` resolves the
//! target's stub through `KLIO_STUB_DIR` (never the network in tests),
//! assembles the bundle by pure byte surgery, and the result boots —
//! host-runnable here because the "linux-arm64" stub under the stub dir
//! is really a copy of the host stub. Also covers the offline error when
//! no stub resolves, `--stub` explicit paths, and the UI shim riding the
//! same resolve order (a placeholder shim blob embeds and lands in the
//! `skia-shim` section). Fetch-side sha256 refusal is unit-tested in
//! `src/cli/stub_fetch.zig` (dev builds bake no manifest, so the network
//! path never runs here).

const std = @import("std");
const runtime = @import("runtime");

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const TMP_ROOT = "/tmp/klio_itest_bundle_cross";
const FAKE_TARGET = "linux-arm64";

fn klioBin(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]const u8 {
    const rel = env.get("KLIO_ITEST_BIN") orelse "zig-out/bin/klio";
    return std.Io.Dir.cwd().realPathFileAlloc(io, rel, a) catch rel;
}

fn baseEnv(a: std.mem.Allocator, home: []const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(a);
    errdefer map.deinit();
    runtime.procEnvPutAllInto(a, &map);
    try map.put("HOME", home);
    _ = map.array_hash_map.swapRemove(@as([]const u8, "KLIO_STUB_DIR"));
    _ = map.array_hash_map.swapRemove(@as([]const u8, "KLIO_BUNDLE_INSPECT"));
    return map;
}

const RunResult = struct { code: u32, stdout: []u8, stderr: []u8 };

fn runChild(
    a: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    argv: []const []const u8,
) !RunResult {
    const r = std.process.run(a, io, .{ .argv = argv, .environ_map = env }) catch |e| {
        std.debug.print("bundle_cross: spawn {s} failed: {s}\n", .{ argv[0], @errorName(e) });
        return error.SpawnFailed;
    };
    const code: u32 = switch (r.term) {
        .exited => |c| c,
        else => 0xffff,
    };
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
}

test "cross bundle resolves the stub from KLIO_STUB_DIR and boots" {
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    cwd.deleteTree(io, TMP_ROOT) catch {};
    try cwd.createDirPath(io, TMP_ROOT);
    const home = TMP_ROOT ++ "/home";
    try cwd.createDirPath(io, home);
    var env = try baseEnv(a, home);
    defer env.deinit();
    const bin = try klioBin(a, io, &env);

    // A stub dir carrying the "linux-arm64" stub (a copy of the host
    // stub, so the produced bundle is host-runnable) and a placeholder
    // shim blob for the UI resolve order.
    const stub_dir = TMP_ROOT ++ "/stubs";
    try cwd.createDirPath(io, stub_dir ++ "/" ++ FAKE_TARGET);
    {
        const stub_bytes = try cwd.readFileAlloc(io, bin, a, .unlimited);
        try cwd.writeFile(io, .{
            .sub_path = stub_dir ++ "/" ++ FAKE_TARGET ++ "/klio",
            .data = stub_bytes,
        });
        try cwd.writeFile(io, .{
            .sub_path = stub_dir ++ "/" ++ FAKE_TARGET ++ "/libklio_skia.so",
            .data = "placeholder shim blob for the cross resolve order",
        });
    }

    // Without a stub source, cross bundling reports the offline hint.
    {
        const r = try runChild(a, io, &env, &.{
            bin, "bundle", "examples/hello.kt", "-o", TMP_ROOT ++ "/nostub", "--target", FAKE_TARGET,
        });
        try std.testing.expectEqual(@as(u32, 1), r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "no cached stub for linux-arm64") != null);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "--stub <path>") != null);
    }

    // With KLIO_STUB_DIR, the cross bundle assembles and (being a host
    // stub in disguise) boots byte-identically to `klio run`.
    try env.put("KLIO_STUB_DIR", stub_dir);
    const out = TMP_ROOT ++ "/hello_cross";
    {
        const r = try runChild(a, io, &env, &.{
            bin, "bundle", "examples/hello.kt", "-o", out, "--target", FAKE_TARGET,
        });
        if (r.code != 0) {
            std.debug.print("bundle_cross: bundling failed:\n{s}\n", .{r.stderr});
            return error.TestUnexpectedResult;
        }
    }
    const expect = try runChild(a, io, &env, &.{ bin, "run", "examples/hello.kt" });
    const abs = try cwd.realPathFileAlloc(io, out, a);
    const got = try runChild(a, io, &env, &.{abs});
    try std.testing.expectEqual(expect.code, got.code);
    try std.testing.expectEqualStrings(expect.stdout, got.stdout);

    // An unknown target is rejected up front.
    {
        const r = try runChild(a, io, &env, &.{
            bin, "bundle", "examples/hello.kt", "-o", TMP_ROOT ++ "/badtarget", "--target", "beos-ppc",
        });
        try std.testing.expectEqual(@as(u32, 2), r.code);
        try std.testing.expect(std.mem.indexOf(u8, r.stderr, "unknown --target") != null);
    }

    // --stub bypasses the resolve order entirely.
    {
        const r = try runChild(a, io, &env, &.{
            bin,      "bundle", "examples/hello.kt",
            "-o",     TMP_ROOT ++ "/hello_stubflag",
            "--target", FAKE_TARGET,
            "--stub", stub_dir ++ "/" ++ FAKE_TARGET ++ "/klio",
        });
        try std.testing.expectEqual(@as(u32, 0), r.code);
    }

    // A forced-UI cross bundle picks the shim blob up from the stub dir
    // and embeds it (inspection shows the section; the blob is a
    // placeholder, so it is not run).
    {
        const ui_out = TMP_ROOT ++ "/ui_cross";
        const r = try runChild(a, io, &env, &.{
            bin, "bundle", "examples/hello.kt", "-o", ui_out, "--target", FAKE_TARGET, "--ui",
        });
        if (r.code != 0) {
            std.debug.print("bundle_cross: ui bundling failed:\n{s}\n", .{r.stderr});
            return error.TestUnexpectedResult;
        }
        const ui_abs = try cwd.realPathFileAlloc(io, ui_out, a);
        try env.put("KLIO_BUNDLE_INSPECT", "1");
        const inspect = try runChild(a, io, &env, &.{ui_abs});
        _ = env.array_hash_map.swapRemove(@as([]const u8, "KLIO_BUNDLE_INSPECT"));
        try std.testing.expectEqual(@as(u32, 0), inspect.code);
        try std.testing.expect(std.mem.indexOf(u8, inspect.stdout, "flavor: ui\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, inspect.stdout, "  skia-shim ") != null);
    }
}
