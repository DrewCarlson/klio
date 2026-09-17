//! End-to-end gate for UI bundles. A Compose program bundles with the Skia
//! backend embedded, runs against an empty home with no `KLIO_SKIA_LIB` and no
//! repo `LD_LIBRARY_PATH`, extracts the shim into the per-user cache on first
//! launch only, and rasterizes a PNG byte-identical to a direct `klio run`
//! against the dev shim. Skips without the built backend at `zig-out/lib/`.

const std = @import("std");
const runtime = @import("runtime");

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const TMP_ROOT = "/tmp/klio_itest_bundle_ui";

const SCENE =
    \\import klio.compose.ui.Box
    \\import klio.compose.ui.Color
    \\import klio.compose.ui.Column
    \\import klio.compose.ui.Modifier
    \\import klio.compose.ui.Text
    \\import klio.compose.ui.uiRenderer
    \\
    \\fun main() {
    \\    val ui = uiRenderer(16, 10) {
    \\        Column(Modifier.None.background(Color.Blue).border(Color.White).padding(1)) {
    \\            Text("PNG", Color.White, Modifier.None)
    \\            Box(Modifier.None.size(6, 3).background(Color.Red).border(Color.Yellow).cornerRadius(1))
    \\        }
    \\    }
    \\    println("checksum=" + ui.savePng("/tmp/klio_itest_bundle_ui/scene.png", 8))
    \\    ui.dispose()
    \\}
    \\
;

fn klioBin(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]const u8 {
    const rel = env.get("KLIO_ITEST_BIN") orelse "zig-out/bin/klio";
    return std.Io.Dir.cwd().realPathFileAlloc(io, rel, a) catch rel;
}

fn baseEnv(a: std.mem.Allocator, home: []const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(a);
    errdefer map.deinit();
    runtime.procEnvPutAllInto(a, &map);
    try map.put("HOME", home);
    _ = map.array_hash_map.swapRemove(@as([]const u8, "KLIO_TRACE_STDLIB_IMAGE"));
    _ = map.array_hash_map.swapRemove(@as([]const u8, "KLIO_STDLIB_IMAGE"));
    _ = map.array_hash_map.swapRemove(@as([]const u8, "KLIO_PACK_DIAG"));
    _ = map.array_hash_map.swapRemove(@as([]const u8, "KLIO_SKIA_LIB"));
    _ = map.array_hash_map.swapRemove(@as([]const u8, "KLIO_BUNDLE_INSPECT"));
    _ = map.array_hash_map.swapRemove(@as([]const u8, "LD_LIBRARY_PATH"));
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
        std.debug.print("bundle_ui: spawn {s} failed: {s}\n", .{ argv[0], @errorName(e) });
        return error.SpawnFailed;
    };
    const code: u32 = switch (r.term) {
        .exited => |c| c,
        else => 0xffff,
    };
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
}

fn freshDir(a: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    const dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ TMP_ROOT, name });
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

fn findShim(a: std.mem.Allocator, io: std.Io, root: []const u8) ?[]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var walker = dir.walk(a) catch return null;
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .file and std.mem.eql(u8, entry.basename, "libklio_skia.so")) {
            return std.fmt.allocPrint(a, "{s}/{s}", .{ root, entry.path }) catch null;
        }
    }
    return null;
}

test "ui bundle renders the pixel gate offline with shim extraction" {
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    _ = cwd.statFile(io, "zig-out/lib/libklio_skia.so", .{}) catch {
        std.debug.print("bundle_ui: zig-out/lib/libklio_skia.so absent; skipping (run scripts/fetch-skia.sh + zig build)\n", .{});
        return error.SkipZigTest;
    };

    cwd.deleteTree(io, TMP_ROOT) catch {};
    try cwd.createDirPath(io, TMP_ROOT);
    const build_home = try freshDir(a, io, "home_build");
    const run_home = try freshDir(a, io, "home_run");
    var build_env = try baseEnv(a, build_home);
    defer build_env.deinit();
    var run_env = try baseEnv(a, run_home);
    defer run_env.deinit();
    const cache_dir = try std.fmt.allocPrint(a, "{s}/xdg-cache", .{TMP_ROOT});
    try run_env.put("XDG_CACHE_HOME", cache_dir);
    const bin = try klioBin(a, io, &build_env);

    const pack_dirs = [_][]const u8{
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlinx-io",
        "kotlin-klio/klio-kotlinx-coroutines",
        "kotlin-klio/klio-androidx-collection",
        "kotlin-klio/klio-compose-runtime-engine",
        "kotlin-klio/klio-compose-ui",
    };
    const pack_files = [_][]const u8{
        "target/packs/kotlinx.atomicfu.klio-pack",
        "target/packs/kotlinx.io.klio-pack",
        "target/packs/kotlinx.coroutines.klio-pack",
        "target/packs/androidx.collection.klio-pack",
        "target/packs/androidx.compose.runtime.klio-pack",
        "target/packs/klio.compose.ui.klio-pack",
    };
    for (pack_dirs) |d| {
        const r = try runChild(a, io, &build_env, &.{ bin, "pack", "build", d });
        if (r.code != 0) {
            std.debug.print("bundle_ui: pack build {s} failed:\n{s}\n", .{ d, r.stderr });
            return error.TestUnexpectedResult;
        }
    }
    for (pack_files) |f| {
        const r = try runChild(a, io, &build_env, &.{ bin, "pack", "install", f });
        if (r.code != 0) {
            std.debug.print("bundle_ui: pack install {s} failed:\n{s}\n", .{ f, r.stderr });
            return error.TestUnexpectedResult;
        }
    }

    const program = try std.fmt.allocPrint(a, "{s}/scene.kt", .{TMP_ROOT});
    try cwd.writeFile(io, .{ .sub_path = program, .data = SCENE });

    const shim_abs = try cwd.realPathFileAlloc(io, "zig-out/lib/libklio_skia.so", a);
    try build_env.put("KLIO_SKIA_LIB", shim_abs);
    const expect = try runChild(a, io, &build_env, &.{ bin, "run", program });
    _ = build_env.array_hash_map.swapRemove(@as([]const u8, "KLIO_SKIA_LIB"));
    try std.testing.expectEqual(@as(u32, 0), expect.code);
    try std.testing.expect(std.mem.startsWith(u8, expect.stdout, "checksum="));
    // Checksum 0 is the headless fallback, which would make the gate vacuous.
    try std.testing.expect(!std.mem.eql(u8, std.mem.trim(u8, expect.stdout, "\n"), "checksum=0"));
    const expect_png = try cwd.readFileAlloc(io, TMP_ROOT ++ "/scene.png", a, .unlimited);
    try cwd.deleteFile(io, TMP_ROOT ++ "/scene.png");

    // The ui flavor must be auto-detected from the klio.compose.ui pack.
    const out = try std.fmt.allocPrint(a, "{s}/uibin", .{TMP_ROOT});
    const bundled = try runChild(a, io, &build_env, &.{ bin, "bundle", program, "-o", out });
    if (bundled.code != 0) {
        std.debug.print("bundle_ui: bundling failed:\n{s}\n", .{bundled.stderr});
        return error.TestUnexpectedResult;
    }
    try std.testing.expect(std.mem.find(u8, bundled.stdout, ", ui)") != null);
    try std.testing.expect(std.mem.find(u8, bundled.stdout, "skia backend") != null);

    const abs = try cwd.realPathFileAlloc(io, out, a);
    try run_env.put("KLIO_BUNDLE_INSPECT", "1");
    const inspect = try runChild(a, io, &run_env, &.{abs});
    _ = run_env.array_hash_map.swapRemove(@as([]const u8, "KLIO_BUNDLE_INSPECT"));
    try std.testing.expectEqual(@as(u32, 0), inspect.code);
    try std.testing.expect(std.mem.find(u8, inspect.stdout, "flavor: ui\n") != null);
    try std.testing.expect(std.mem.find(u8, inspect.stdout, "  skia-shim ") != null);

    // First launch renders through the extracted shim, not the dev one.
    const first = try runChild(a, io, &run_env, &.{abs});
    try std.testing.expectEqual(@as(u32, 0), first.code);
    try std.testing.expectEqualStrings(expect.stdout, first.stdout);
    const got_png = try cwd.readFileAlloc(io, TMP_ROOT ++ "/scene.png", a, .unlimited);
    try std.testing.expect(std.mem.eql(u8, expect_png, got_png));

    const shim_root = try std.fmt.allocPrint(a, "{s}/klio/shim", .{cache_dir});
    const extracted = findShim(a, io, shim_root) orelse {
        std.debug.print("bundle_ui: no extracted shim under {s}\n", .{shim_root});
        return error.TestUnexpectedResult;
    };
    const st_before = try cwd.statFile(io, extracted, .{});

    // Second launch reuses the cache, so the mtime must not move.
    const second = try runChild(a, io, &run_env, &.{abs});
    try std.testing.expectEqual(@as(u32, 0), second.code);
    try std.testing.expectEqualStrings(expect.stdout, second.stdout);
    const st_after = try cwd.statFile(io, extracted, .{});
    try std.testing.expectEqual(st_before.mtime.nanoseconds, st_after.mtime.nanoseconds);
}
