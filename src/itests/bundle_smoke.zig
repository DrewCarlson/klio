//! End-to-end gate for `klio bundle`: a bundled program must behave
//! byte-identically to `klio run` — stdout, stderr, exit code — while
//! running against an EMPTY home (no `~/.klio`, no packs, no cache) and
//! a non-repo cwd. Covers the plain-hello case, a pack-using program
//! (kotlinx.serialization with a baked feature), argv passthrough into
//! `main(args)`, embedded resources (binary + text + the
//! missing-resource exception), `exitProcess` exit-code fidelity, stdin
//! passthrough, payload corruption, `KLIO_BUNDLE_INSPECT` output shape,
//! and double-bundle byte determinism.
//!
//! Each scenario spawns the real `klio` binary (KLIO_ITEST_BIN). Bundling
//! runs under a scratch HOME seeded with the packs the programs need;
//! bundles run under a second, empty HOME.

const std = @import("std");
const runtime = @import("runtime");

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const TMP_ROOT = "/tmp/klio_itest_bundle_smoke";

// -------------------------------------------------------------------------
// Child-process plumbing (mirrors src/itests/stdlib_image.zig).
// -------------------------------------------------------------------------

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
    _ = map.array_hash_map.swapRemove(@as([]const u8, "KLIO_BUNDLE_INSPECT"));
    return map;
}

const RunResult = struct { code: u32, stdout: []u8, stderr: []u8 };

fn runChild(
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
        std.debug.print("bundle_smoke: spawn {s} failed: {s}\n", .{ argv[0], @errorName(e) });
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

fn freshDir(a: std.mem.Allocator, io: std.Io, name: []const u8) ![]const u8 {
    const dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ TMP_ROOT, name });
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

/// Shared per-suite state: one bundling HOME (packs installed once) and
/// one empty run HOME.
const Ctx = struct {
    a: std.mem.Allocator,
    io: std.Io,
    bin: []const u8,
    build_env: *std.process.Environ.Map,
    run_env: *std.process.Environ.Map,
    run_home: []const u8,
};

var ctx_state: ?Ctx = null;

fn ctx() !*Ctx {
    if (ctx_state) |*c| return c;
    const a = file_arena.allocator();
    const threaded = try a.create(std.Io.Threaded);
    threaded.* = .init(a, .{});
    const io = threaded.io();

    const build_home = try freshDir(a, io, "home_build");
    const run_home = try freshDir(a, io, "home_run");
    const build_env = try a.create(std.process.Environ.Map);
    build_env.* = try baseEnv(a, build_home);
    const run_env = try a.create(std.process.Environ.Map);
    run_env.* = try baseEnv(a, run_home);
    const bin = try klioBin(a, io, build_env);

    // Install the packs the pack-using scenarios bake in.
    const pack_dirs = [_][]const u8{
        "kotlin-klio/klio-kotlinx-serialization",
        "kotlin-klio/klio-bundle",
    };
    const pack_files = [_][]const u8{
        "target/packs/kotlinx.serialization.klio-pack",
        "target/packs/klio.bundle.klio-pack",
    };
    for (pack_dirs) |d| {
        const r = try runChild(a, io, build_env, null, &.{ bin, "pack", "build", d });
        if (r.code != 0) {
            std.debug.print("bundle_smoke: pack build {s} failed:\n{s}\n", .{ d, r.stderr });
            return error.TestUnexpectedResult;
        }
    }
    for (pack_files) |f| {
        const r = try runChild(a, io, build_env, null, &.{ bin, "pack", "install", f });
        if (r.code != 0) {
            std.debug.print("bundle_smoke: pack install {s} failed:\n{s}\n", .{ f, r.stderr });
            return error.TestUnexpectedResult;
        }
    }

    ctx_state = .{
        .a = a,
        .io = io,
        .bin = bin,
        .build_env = build_env,
        .run_env = run_env,
        .run_home = run_home,
    };
    return &ctx_state.?;
}

/// Bundle `program` (plus extra bundle args) to `out_name` under
/// TMP_ROOT and return the output path.
fn bundleProgram(c: *Ctx, program: []const u8, out_name: []const u8, extra: []const []const u8) ![]const u8 {
    const out = try std.fmt.allocPrint(c.a, "{s}/{s}", .{ TMP_ROOT, out_name });
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(c.a);
    try argv.appendSlice(c.a, &.{ c.bin, "bundle", program, "-o", out });
    try argv.appendSlice(c.a, extra);
    const r = try runChild(c.a, c.io, c.build_env, null, argv.items);
    if (r.code != 0) {
        std.debug.print("bundle_smoke: bundling {s} failed (code {d}):\n{s}\n", .{ program, r.code, r.stderr });
        return error.TestUnexpectedResult;
    }
    return out;
}

/// Assert a bundle's stdout/stderr/exit match `klio run` of the same
/// program. The bundle runs from an empty, non-repo cwd with the empty
/// HOME; `klio run` runs under the bundling HOME (packs available).
fn assertMatchesRun(c: *Ctx, program: []const u8, bundle_path: []const u8, run_args: []const []const u8) !void {
    var run_argv: std.ArrayList([]const u8) = .empty;
    defer run_argv.deinit(c.a);
    try run_argv.appendSlice(c.a, &.{ c.bin, "run", program });
    try run_argv.appendSlice(c.a, run_args);
    const expect = try runChild(c.a, c.io, c.build_env, null, run_argv.items);

    const abs = std.Io.Dir.cwd().realPathFileAlloc(c.io, bundle_path, c.a) catch bundle_path;
    const empty_cwd = try freshDir(c.a, c.io, "empty_cwd");
    const got = try runChild(c.a, c.io, c.run_env, empty_cwd, &.{abs});

    if (got.code != expect.code or
        !std.mem.eql(u8, got.stdout, expect.stdout) or
        !std.mem.eql(u8, got.stderr, expect.stderr))
    {
        std.debug.print(
            "bundle_smoke mismatch for {s}\nrun code={d} stdout:\n{s}\nstderr:\n{s}\nbundle code={d} stdout:\n{s}\nstderr:\n{s}\n",
            .{ program, expect.code, expect.stdout, expect.stderr, got.code, got.stdout, got.stderr },
        );
        return error.TestUnexpectedResult;
    }
}

// -------------------------------------------------------------------------
// Scenarios.
// -------------------------------------------------------------------------

test "hello bundle matches klio run from an empty home" {
    const c = try ctx();
    const bundle_path = try bundleProgram(c, "examples/hello.kt", "hello", &.{});
    try assertMatchesRun(c, "examples/hello.kt", bundle_path, &.{});
}

test "pack-using bundle (kotlinx.serialization + feature) matches klio run" {
    const c = try ctx();
    const program = try writeProgram(c.a, c.io,
        "ser.kt",
        \\import kotlinx.serialization.Serializable
        \\import kotlinx.serialization.json.Json
        \\import kotlinx.serialization.encodeToString
        \\
        \\@Serializable
        \\data class Point(val x: Int, val y: Int)
        \\
        \\fun main() {
        \\    val json = Json.encodeToString(Point(3, 4))
        \\    println(json)
        \\    println(Json.decodeFromString<Point>(json))
        \\}
        \\
    );
    const bundle_path = try bundleProgram(c, program, "serbin", &.{ "--feature", "kotlinx.serialization/json" });
    try assertMatchesRun(c, program, bundle_path, &.{ "--feature", "kotlinx.serialization/json" });
}

test "argv passes through to main(args)" {
    const c = try ctx();
    const program = try writeProgram(c.a, c.io,
        "args.kt",
        \\fun main(args: Array<String>) {
        \\    println("n=" + args.size)
        \\    for (a in args) println("arg: " + a)
        \\}
        \\
    );
    const bundle_path = try bundleProgram(c, program, "argsbin", &.{});
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(c.io, bundle_path, c.a);
    const got = try runChild(c.a, c.io, c.run_env, null, &.{ abs, "--input", "data.json", "-v" });
    try std.testing.expectEqual(@as(u32, 0), got.code);
    try std.testing.expectEqualStrings("n=3\narg: --input\narg: data.json\narg: -v\n", got.stdout);
}

test "resources round-trip: text, bytes, exists, list, missing throws" {
    const c = try ctx();
    const assets = try freshDir(c.a, c.io, "assets");
    try std.Io.Dir.cwd().writeFile(c.io, .{
        .sub_path = try std.fmt.allocPrint(c.a, "{s}/config.txt", .{assets}),
        .data = "config-line-1\nconfig-line-2\n",
    });
    // Incompressible binary payload (stays raw) with every byte value.
    var blob: [4096]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(7);
    rng.random().bytes(&blob);
    try std.Io.Dir.cwd().writeFile(c.io, .{
        .sub_path = try std.fmt.allocPrint(c.a, "{s}/blob.bin", .{assets}),
        .data = &blob,
    });

    const program = try writeProgram(c.a, c.io,
        "res.kt",
        \\import klio.bundle.Resources
        \\fun main() {
        \\    println(Resources.list())
        \\    println(Resources.exists("assets/config.txt"))
        \\    println(Resources.exists("nope"))
        \\    println(Resources.readText("assets/config.txt").trim())
        \\    val bytes = Resources.readBytes("assets/blob.bin")
        \\    var sum = 0
        \\    for (b in bytes) sum = (sum + b.toInt() + 256) % 9973
        \\    println("" + bytes.size + " " + sum)
        \\    try {
        \\        Resources.readBytes("missing.txt")
        \\    } catch (e: IllegalArgumentException) {
        \\        println("missing: " + e.message)
        \\    }
        \\}
        \\
    );
    const include = try std.fmt.allocPrint(c.a, "{s}:assets", .{assets});
    const bundle_path = try bundleProgram(c, program, "resbin", &.{ "--include", include });
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(c.io, bundle_path, c.a);
    const got = try runChild(c.a, c.io, c.run_env, null, &.{abs});
    try std.testing.expectEqual(@as(u32, 0), got.code);

    // The expected byte checksum, computed the same way (Kotlin's
    // `Byte.toInt()` is signed).
    var sum: i32 = 0;
    for (blob) |b| sum = @mod(sum + @as(i32, @as(i8, @bitCast(b))) + 256, 9973);
    const expected = try std.fmt.allocPrint(c.a,
        \\[assets/blob.bin, assets/config.txt]
        \\true
        \\false
        \\config-line-1
        \\config-line-2
        \\4096 {d}
        \\missing: no bundled resource at `missing.txt`
        \\
    , .{sum});
    try std.testing.expectEqualStrings(expected, got.stdout);
}

test "exitProcess value is the process exit code" {
    const c = try ctx();
    const program = try writeProgram(c.a, c.io,
        "exit7.kt",
        \\import kotlin.system.exitProcess
        \\fun main() {
        \\    println("before")
        \\    exitProcess(7)
        \\    println("after")
        \\}
        \\
    );
    const bundle_path = try bundleProgram(c, program, "exitbin", &.{});
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(c.io, bundle_path, c.a);
    const got = try runChild(c.a, c.io, c.run_env, null, &.{abs});
    try std.testing.expectEqual(@as(u32, 7), got.code);
    try std.testing.expectEqualStrings("before\n", got.stdout);
}

test "stdin passes through to readLine" {
    const c = try ctx();
    const program = try writeProgram(c.a, c.io,
        "stdin.kt",
        \\fun main() {
        \\    println("got: " + readLine())
        \\}
        \\
    );
    const bundle_path = try bundleProgram(c, program, "stdinbin", &.{});
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(c.io, bundle_path, c.a);
    // `std.process.run` pins stdin to /dev/null; pipe through the shell.
    const cmd = try std.fmt.allocPrint(c.a, "printf 'hello-stdin\\n' | {s}", .{abs});
    const got = try runChild(c.a, c.io, c.run_env, null, &.{ "/bin/sh", "-c", cmd });
    try std.testing.expectEqual(@as(u32, 0), got.code);
    try std.testing.expectEqualStrings("got: hello-stdin\n", got.stdout);
}

test "corrupted payload refuses with the hash-mismatch message" {
    const c = try ctx();
    const bundle_path = try bundleProgram(c, "examples/hello.kt", "hello_corrupt", &.{});
    // Flip one byte inside the payload area (just before the trailer).
    const bytes = try std.Io.Dir.cwd().readFileAlloc(c.io, bundle_path, c.a, .unlimited);
    bytes[bytes.len - 72 - 100] ^= 0x40;
    try std.Io.Dir.cwd().writeFile(c.io, .{ .sub_path = bundle_path, .data = bytes });

    const abs = try std.Io.Dir.cwd().realPathFileAlloc(c.io, bundle_path, c.a);
    const got = try runChild(c.a, c.io, c.run_env, null, &.{abs});
    try std.testing.expectEqual(@as(u32, 1), got.code);
    try std.testing.expectEqualStrings(
        "error: bundle payload hash mismatch (file truncated or modified); rebundle\n",
        got.stderr,
    );
}

test "KLIO_BUNDLE_INSPECT prints the manifest and exits 0" {
    const c = try ctx();
    const bundle_path = try bundleProgram(c, "examples/hello.kt", "hello_inspect", &.{});
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(c.io, bundle_path, c.a);
    try c.run_env.put("KLIO_BUNDLE_INSPECT", "1");
    defer _ = c.run_env.array_hash_map.swapRemove(@as([]const u8, "KLIO_BUNDLE_INSPECT"));
    const got = try runChild(c.a, c.io, c.run_env, null, &.{abs});
    try std.testing.expectEqual(@as(u32, 0), got.code);
    try std.testing.expect(std.mem.startsWith(u8, got.stdout, "bundle: hello_inspect\n"));
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "klio: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "flavor: headless\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "entry: program-src\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "  base-image ") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.stdout, "  program-src ") != null);
}

test "double-bundle output is byte-identical" {
    const c = try ctx();
    const one = try bundleProgram(c, "examples/hello.kt", "det", &.{});
    const first = try std.Io.Dir.cwd().readFileAlloc(c.io, one, c.a, .unlimited);
    const two = try bundleProgram(c, "examples/hello.kt", "det", &.{});
    const second = try std.Io.Dir.cwd().readFileAlloc(c.io, two, c.a, .unlimited);
    try std.testing.expect(std.mem.eql(u8, first, second));
}
