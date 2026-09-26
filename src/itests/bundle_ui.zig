//! End-to-end gate for UI bundles. A Compose program bundles with the Skia
//! backend embedded, runs against an empty home with no `KLIO_SKIA_LIB` and no
//! repo library path, extracts the shim into the per-user cache on first
//! launch only, and rasterizes a PNG byte-identical to a direct `klio run`
//! against the dev shim. Skips without the built backend at `zig-out/lib/`.

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const klio_child = @import("klio_child");

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const TMP_ROOT = "/tmp/klio_itest_bundle_ui";

const SHIM_NAME = switch (builtin.os.tag) {
    .macos => "libklio_skia.dylib",
    .windows => "klio_skia.dll",
    else => "libklio_skia.so",
};

const SCENE =
    \\import androidx.compose.foundation.background
    \\import androidx.compose.foundation.border
    \\import androidx.compose.foundation.layout.Box
    \\import androidx.compose.foundation.layout.Column
    \\import androidx.compose.foundation.layout.fillMaxSize
    \\import androidx.compose.foundation.layout.padding
    \\import androidx.compose.foundation.layout.size
    \\import androidx.compose.foundation.shape.RoundedCornerShape
    \\import androidx.compose.foundation.text.BasicText
    \\import androidx.compose.ui.Modifier
    \\import androidx.compose.ui.graphics.Color
    \\import androidx.compose.ui.klio.renderComposeToPng
    \\import androidx.compose.ui.text.TextStyle
    \\import androidx.compose.ui.unit.dp
    \\import androidx.compose.ui.unit.sp
    \\
    \\fun main() {
    \\    val ok = renderComposeToPng(128, 80, 8f, "/tmp/klio_itest_bundle_ui/scene.png") {
    \\        Column(Modifier.fillMaxSize().background(Color.Blue).border(1.dp, Color.White).padding(1.dp)) {
    \\            BasicText("PNG", style = TextStyle(color = Color.White, fontSize = 4.sp))
    \\            val shape = RoundedCornerShape(1.dp)
    \\            Box(Modifier.size(6.dp, 3.dp).background(Color.Red, shape).border(1.dp, Color.Yellow, shape))
    \\        }
    \\    }
    \\    println("rendered=" + ok)
    \\}
    \\
;

/// Drops what would let a child find the dev shim, a baked image or the
/// repository's libraries, so a bundle proves it carries its own.
fn scrub(env: *std.process.Environ.Map) void {
    inline for (.{ "KLIO_TRACE_STDLIB_IMAGE", "KLIO_STDLIB_IMAGE", "KLIO_PACK_DIAG", "KLIO_SKIA_LIB", "KLIO_BUNDLE_INSPECT", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH" }) |k| {
        _ = env.swapRemove(k);
    }
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
        if (entry.kind == .file and std.mem.eql(u8, entry.basename, SHIM_NAME)) {
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

    const shim_rel = "zig-out/lib/" ++ SHIM_NAME;
    _ = cwd.statFile(io, shim_rel, .{}) catch {
        if (klio_child.verbose()) std.debug.print("bundle_ui: " ++ shim_rel ++ " absent; skipping (zig build skia-lib)\n", .{});
        return error.SkipZigTest;
    };

    cwd.deleteTree(io, TMP_ROOT) catch {};
    try cwd.createDirPath(io, TMP_ROOT);
    // The program builds against the shared test home, where every shipped
    // pack is installed; the bundle runs in an empty one.
    var build_env = try klio_child.baseEnv(a);
    defer build_env.deinit();
    scrub(&build_env);
    const run_home = try freshDir(a, io, "home_run");
    var run_env = try klio_child.envFor(a, run_home);
    defer run_env.deinit();
    scrub(&run_env);
    const cache_dir = try std.fmt.allocPrint(a, "{s}/xdg-cache", .{TMP_ROOT});
    try run_env.put("XDG_CACHE_HOME", cache_dir);
    const bin = cwd.realPathFileAlloc(io, klio_child.bin(), a) catch klio_child.bin();

    const program = try std.fmt.allocPrint(a, "{s}/scene.kt", .{TMP_ROOT});
    try cwd.writeFile(io, .{ .sub_path = program, .data = SCENE });

    const shim_abs = try cwd.realPathFileAlloc(io, shim_rel, a);
    try build_env.put("KLIO_SKIA_LIB", shim_abs);
    const expect = try runChild(a, io, &build_env, &.{ bin, "run", program });
    _ = build_env.swapRemove("KLIO_SKIA_LIB");
    if (expect.code != 0) std.debug.print("bundle_ui: klio run failed:\n{s}\n", .{expect.stderr});
    try std.testing.expectEqual(@as(u32, 0), expect.code);
    // `false` is the headless fallback, which would make the gate vacuous.
    try std.testing.expectEqualStrings("rendered=true\n", expect.stdout);
    const expect_png = try cwd.readFileAlloc(io, TMP_ROOT ++ "/scene.png", a, .unlimited);
    try std.testing.expect(std.mem.startsWith(u8, expect_png, "\x89PNG\r\n\x1a\n"));
    try cwd.deleteFile(io, TMP_ROOT ++ "/scene.png");

    // The ui flavor must be auto-detected from the androidx.compose.ui packs.
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
    _ = run_env.swapRemove("KLIO_BUNDLE_INSPECT");
    try std.testing.expectEqual(@as(u32, 0), inspect.code);
    try std.testing.expect(std.mem.find(u8, inspect.stdout, "flavor: ui\n") != null);
    try std.testing.expect(std.mem.find(u8, inspect.stdout, "  skia-shim ") != null);

    // First launch renders through the extracted shim, not the dev one.
    const first = try runChild(a, io, &run_env, &.{abs});
    try std.testing.expectEqual(@as(u32, 0), first.code);
    try std.testing.expectEqualStrings(expect.stdout, first.stdout);
    const got_png = try cwd.readFileAlloc(io, TMP_ROOT ++ "/scene.png", a, .unlimited);
    try std.testing.expect(std.mem.eql(u8, expect_png, got_png));

    const cache_base = if (builtin.os.tag == .macos)
        try std.fmt.allocPrint(a, "{s}/Library/Caches", .{run_home})
    else
        cache_dir;
    const shim_root = try std.fmt.allocPrint(a, "{s}/klio/shim", .{cache_base});
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
