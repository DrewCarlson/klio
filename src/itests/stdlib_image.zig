//! Gate for the base image `klio run` caches (`sema-base-<key>.klio-sema`):
//! a run over the image (baked on a miss, read on a hit) must match a run
//! over a base analyzed afresh (`KLIO_SEMA_IMAGE=0`) byte for byte. The
//! scenarios run the real `klio` binary (KLIO_ITEST_BIN) against a scratch
//! HOME, so the cache under test never touches `~/.klio`. The image's own
//! encoding round trips are the `lower_driver` module's tests.

const std = @import("std");
const stdlib = @import("stdlib");
const runtime = @import("runtime");

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const TMP_ROOT = "/tmp/klio_itest_stdlib_image";

fn klioBin(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]const u8 {
    const rel = env.get("KLIO_ITEST_BIN") orelse "zig-out/bin/klio";
    // Scenarios spawn with a non-repo cwd, so the path must be absolute.
    return std.Io.Dir.cwd().realPathFileAlloc(io, rel, a) catch rel;
}

fn baseEnv(a: std.mem.Allocator, home: []const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(a);
    errdefer map.deinit();
    runtime.procEnvPutAllInto(a, &map);
    try map.put("HOME", home);
    try map.put("KLIO_HOME", home);
    // The comparisons assert byte-identical stderr and watch this cache.
    _ = map.array_hash_map.swapRemove(@as([]const u8, "KLIO_SEMA_IMAGE"));
    _ = map.array_hash_map.swapRemove(@as([]const u8, "KLIO_SEMA_TIMING"));
    _ = map.array_hash_map.swapRemove(@as([]const u8, "KLIO_PACK_DIAG"));
    return map;
}

const RunResult = struct { code: u32, stdout: []u8, stderr: []u8 };

fn runKlio(
    a: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    cwd: ?[]const u8,
    argv: []const []const u8,
) !RunResult {
    const r = std.process.run(a, io, .{
        .argv = argv,
        .environ_map = env,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
    }) catch |e| {
        std.debug.print("stdlib_image: spawn {s} failed: {s}\n", .{ argv[0], @errorName(e) });
        return error.SpawnFailed;
    };
    const code: u32 = switch (r.term) {
        .exited => |c| c,
        else => 0xffff,
    };
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
}

fn writeProgram(a: std.mem.Allocator, io: std.Io, name: []const u8, src: []const u8) ![]const u8 {
    std.Io.Dir.cwd().createDirPath(io, TMP_ROOT) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ TMP_ROOT, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });
    return path;
}

/// Run `argv` over a fresh base, then over the image twice (the first bakes
/// it on a miss, the second reads it); all three must agree.
fn assertImageMatchesCold(
    a: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    cwd: ?[]const u8,
    argv: []const []const u8,
) !void {
    try env.put("KLIO_SEMA_IMAGE", "0");
    const fresh = try runKlio(a, io, env, cwd, argv);
    _ = env.array_hash_map.swapRemove(@as([]const u8, "KLIO_SEMA_IMAGE"));
    const cold = try runKlio(a, io, env, cwd, argv);
    const warm = try runKlio(a, io, env, cwd, argv);

    for ([_]RunResult{ cold, warm }) |got| {
        if (got.code != fresh.code or
            !std.mem.eql(u8, got.stdout, fresh.stdout) or
            !std.mem.eql(u8, got.stderr, fresh.stderr))
        {
            std.debug.print(
                "stdlib_image mismatch for {s}\nfresh base code={d} stdout:\n{s}\nstderr:\n{s}\nimage code={d} stdout:\n{s}\nstderr:\n{s}\n",
                .{ argv[argv.len - 1], fresh.code, fresh.stdout, fresh.stderr, got.code, got.stdout, got.stderr },
            );
            return error.TestUnexpectedResult;
        }
    }
}

fn freshHome(a: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    const home = try std.fmt.allocPrint(a, "{s}/home_{s}", .{ TMP_ROOT, name });
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    return home;
}

fn isImage(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "sema-base-") and std.mem.endsWith(u8, name, ".klio-sema");
}

fn countImages(a: std.mem.Allocator, io: std.Io, home: []const u8) usize {
    const cache = std.fmt.allocPrint(a, "{s}/.klio/cache", .{home}) catch return 0;
    var dir = std.Io.Dir.cwd().openDir(io, cache, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (isImage(entry.name)) n += 1;
    }
    return n;
}

fn firstImagePath(a: std.mem.Allocator, io: std.Io, home: []const u8) ?[]const u8 {
    const cache = std.fmt.allocPrint(a, "{s}/.klio/cache", .{home}) catch return null;
    var dir = std.Io.Dir.cwd().openDir(io, cache, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (isImage(entry.name)) {
            return std.fmt.allocPrint(a, "{s}/{s}", .{ cache, entry.name }) catch null;
        }
    }
    return null;
}

const P_BASIC =
    \\enum class Paint(val code: Int) {
    \\    RED(10),
    \\    GREEN(20) { override fun label(): String = "green!" };
    \\    open fun label(): String = "plain " + code
    \\}
    \\object Registry { var total = 0 }
    \\fun main() {
    \\    val items = listOf(3, 1, 2).sorted().map { it * 10 }
    \\    println(items.joinToString("|"))
    \\    println(Paint.RED.label() + " " + Paint.GREEN.label() + " " + Paint.GREEN.ordinal)
    \\    Registry.total += 41
    \\    println("total=${Registry.total + 1}")
    \\    println(buildString { append("a"); append(1..3) })
    \\}
    \\
;

/// Redeclares a stdlib top-level name.
const P_FALLBACK =
    \\fun listOf(x: Int): Int = x + 1
    \\fun main() {
    \\    println(listOf(41))
    \\    println(kotlin.collections.listOf(1, 2).size)
    \\}
    \\
;

const P_NO_MAIN =
    \\fun helper(): Int = 7
    \\
;

const P_KX =
    \\import kotlinx.coroutines.*
    \\fun main() = runBlocking {
    \\    val jobs = (1..3).map { n -> async { n * n } }
    \\    println(jobs.map { it.await() }.joinToString(","))
    \\}
    \\
;

/// A package member reached by fully-qualified name with no `import`.
const P_QUALIFIED_IMPLICIT =
    \\fun main() {
    \\    println(kotlin.math.max(3, 7))
    \\    println(kotlin.math.sqrt(16.0))
    \\}
    \\
;

/// The same shape against a non-implicit gated package.
const P_QUALIFIED_GATED =
    \\fun main() {
    \\    val ctx = kotlin.coroutines.EmptyCoroutineContext
    \\    println(ctx != null)
    \\}
    \\
;

test "image path is byte-identical to a fresh base: basic, redeclared stdlib name, no-main" {
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = try freshHome(a, io, "basic");
    var env = try baseEnv(a, home);
    defer env.deinit();
    const bin = try klioBin(a, io, &env);

    const basic = try writeProgram(a, io, "basic.kt", P_BASIC);
    try assertImageMatchesCold(a, io, &env, null, &.{ bin, "run", basic });
    try std.testing.expect(countImages(a, io, home) >= 1);

    const fallback = try writeProgram(a, io, "fallback.kt", P_FALLBACK);
    try assertImageMatchesCold(a, io, &env, null, &.{ bin, "run", fallback });

    const no_main = try writeProgram(a, io, "no_main.kt", P_NO_MAIN);
    try assertImageMatchesCold(a, io, &env, null, &.{ bin, "run", no_main });
}

test "fully-qualified unimported reference: image path matches a fresh base" {
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = try freshHome(a, io, "qualified");
    var env = try baseEnv(a, home);
    defer env.deinit();
    const bin = try klioBin(a, io, &env);

    const implicit = try writeProgram(a, io, "qualified_implicit.kt", P_QUALIFIED_IMPLICIT);
    try assertImageMatchesCold(a, io, &env, null, &.{ bin, "run", implicit });

    const gated = try writeProgram(a, io, "qualified_gated.kt", P_QUALIFIED_GATED);
    try assertImageMatchesCold(a, io, &env, null, &.{ bin, "run", gated });
}

test "corrupted image is rejected and rebaked transparently" {
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = try freshHome(a, io, "corrupt");
    var env = try baseEnv(a, home);
    defer env.deinit();
    const bin = try klioBin(a, io, &env);

    const basic = try writeProgram(a, io, "corrupt_probe.kt", P_BASIC);
    const first = try runKlio(a, io, &env, null, &.{ bin, "run", basic });
    try std.testing.expectEqual(@as(u32, 0), first.code);

    const img = firstImagePath(a, io, home) orelse return error.TestUnexpectedResult;
    // Truncate the image; the next run must reject it and rebake.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, img, a, .unlimited);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = img, .data = bytes[0 .. bytes.len / 2] });

    const again = try runKlio(a, io, &env, null, &.{ bin, "run", basic });
    try std.testing.expectEqual(@as(u32, 0), again.code);
    try std.testing.expectEqualStrings(first.stdout, again.stdout);
    const rebaked = try std.Io.Dir.cwd().readFileAlloc(io, img, a, .unlimited);
    try std.testing.expectEqual(bytes.len, rebaked.len);
}

test "editing a stdlib source rebakes under a new key" {
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    // A private copy, so the edit below never touches the repo.
    const sandbox = try std.fmt.allocPrint(a, "{s}/stale_sandbox", .{TMP_ROOT});
    cwd.deleteTree(io, sandbox) catch {};
    const pb = stdlib.pack_builder;
    for (pb.CURATED_UPSTREAM_SOURCES) |rel| {
        const src_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ pb.UPSTREAM_STDLIB_ROOT, rel });
        const dst_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ sandbox, pb.UPSTREAM_STDLIB_ROOT, rel });
        try cwd.createDirPath(io, std.fs.path.dirname(dst_path).?);
        const data = try cwd.readFileAlloc(io, src_path, a, .unlimited);
        try cwd.writeFile(io, .{ .sub_path = dst_path, .data = data });
    }
    for (pb.KLIO_STDLIB_ACTUAL_FILES) |rel| {
        const src_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ pb.KLIO_STDLIB_DIR, rel });
        const dst_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ sandbox, pb.KLIO_STDLIB_DIR, rel });
        try cwd.createDirPath(io, std.fs.path.dirname(dst_path).?);
        const data = try cwd.readFileAlloc(io, src_path, a, .unlimited);
        try cwd.writeFile(io, .{ .sub_path = dst_path, .data = data });
    }

    const home = try freshHome(a, io, "stale");
    var env = try baseEnv(a, home);
    defer env.deinit();
    const bin = try klioBin(a, io, &env);
    const prog = try writeProgram(a, io, "stale_probe.kt", P_BASIC);

    const first = try runKlio(a, io, &env, sandbox, &.{ bin, "run", prog });
    try std.testing.expectEqual(@as(u32, 0), first.code);
    try std.testing.expectEqual(@as(usize, 1), countImages(a, io, home));

    const edited = try std.fmt.allocPrint(a, "{s}/{s}/src/kotlin/util/Standard.kt", .{ sandbox, pb.UPSTREAM_STDLIB_ROOT });
    const old = try cwd.readFileAlloc(io, edited, a, .unlimited);
    const patched = try std.fmt.allocPrint(a, "{s}\n// stale-test edit\n", .{old});
    try cwd.writeFile(io, .{ .sub_path = edited, .data = patched });

    const second = try runKlio(a, io, &env, sandbox, &.{ bin, "run", prog });
    try std.testing.expectEqual(@as(u32, 0), second.code);
    try std.testing.expectEqualStrings(first.stdout, second.stdout);
    try std.testing.expectEqual(@as(usize, 2), countImages(a, io, home));

    const third = try runKlio(a, io, &env, sandbox, &.{ bin, "run", prog });
    try std.testing.expectEqual(@as(u32, 0), third.code);
    try std.testing.expectEqualStrings(first.stdout, third.stdout);
    try std.testing.expectEqual(@as(usize, 2), countImages(a, io, home));
}

test "outside a checkout the embedded pack serves the stdlib" {
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();

    // No checkout in cwd, so the embedded pack must serve the curated sources
    // and the cache must key off the embedded bytes.
    const sandbox = try std.fmt.allocPrint(a, "{s}/outside_sandbox", .{TMP_ROOT});
    cwd.deleteTree(io, sandbox) catch {};
    try cwd.createDirPath(io, sandbox);

    const home = try freshHome(a, io, "outside");
    var env = try baseEnv(a, home);
    defer env.deinit();
    _ = env.array_hash_map.swapRemove(@as([]const u8, "KLIO_STDLIB_PACK"));
    const bin = try klioBin(a, io, &env);
    const prog = try writeProgram(a, io, "outside_probe.kt",
        \\fun main() {
        \\    val doubled = listOf(1, 2, 3).map { it * 2 }
        \\    val msg = doubled.joinToString(",").let { "doubled: $it" }
        \\    run { println(msg) }
        \\}
        \\
    );

    const first = try runKlio(a, io, &env, sandbox, &.{ bin, "run", prog });
    try std.testing.expectEqualStrings("", first.stderr);
    try std.testing.expectEqual(@as(u32, 0), first.code);
    try std.testing.expectEqualStrings("doubled: 2,4,6\n", first.stdout);
    try std.testing.expectEqual(@as(usize, 1), countImages(a, io, home));

    const second = try runKlio(a, io, &env, sandbox, &.{ bin, "run", prog });
    try std.testing.expectEqual(@as(u32, 0), second.code);
    try std.testing.expectEqualStrings(first.stdout, second.stdout);
    try std.testing.expectEqual(@as(usize, 1), countImages(a, io, home));
}

test "pack-using program: image path matches a fresh base with installed packs" {
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const home = try freshHome(a, io, "packs");
    var env = try baseEnv(a, home);
    defer env.deinit();
    const bin = try klioBin(a, io, &env);

    const pack_dirs = [_][]const u8{
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlinx-coroutines",
        "kotlin-klio/klio-kotlinx-io",
    };
    var pack_files: [pack_dirs.len][]const u8 = undefined;
    for (pack_dirs, &pack_files) |d, *f| {
        f.* = try std.fmt.allocPrint(a, "{s}/{s}.klio-pack", .{ home, std.fs.path.basename(d) });
        const r = try runKlio(a, io, &env, null, &.{ bin, "pack", "build", d, "--out", f.* });
        if (r.code != 0) {
            std.debug.print("stdlib_image: pack build {s} failed:\n{s}\n", .{ d, r.stderr });
            return error.TestUnexpectedResult;
        }
    }
    for (pack_files) |f| {
        const r = try runKlio(a, io, &env, null, &.{ bin, "pack", "install", f });
        if (r.code != 0) {
            std.debug.print("stdlib_image: pack install {s} failed:\n{s}\n", .{ f, r.stderr });
            return error.TestUnexpectedResult;
        }
    }

    const kx = try writeProgram(a, io, "kx.kt", P_KX);
    try assertImageMatchesCold(a, io, &env, null, &.{ bin, "run", kx });
}
