//! Async `ByteChannel` gate: a real `klio` child process drives the
//! upstream ktor-io channel (read side + the async write side with its
//! `Slot` suspension protocol) through the installed packs (`klio pack
//! build` + `pack install` into a scratch HOME, then `klio run`).
//!
//! Three shapes, each through real upstream `ByteChannel` code:
//!  - a buffered write → `flushAndClose` → `readRemaining` round trip
//!    (no suspension; pins the closed-state getters and the
//!    `CloseToken` companion-extension dispatch);
//!  - a reader parked on `awaitContent` (`suspendCancellableCoroutine`
//!    + `Slot.Read`) resumed by a later writer's flush;
//!  - a writer parked on `flush` (payload past `CHANNEL_MAX_SIZE`,
//!    `Slot.Write`) resumed by the reader draining the flush buffer.

const std = @import("std");
const runtime = @import("runtime");

/// The `klio` binary to spawn: `KLIO_ITEST_BIN` when set (the build run
/// step points it at the harness-optimized install), else the Debug install.
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
        std.debug.print("ktor_channel_async: spawn {s} failed: {s}\n", .{ argv[0], @errorName(e) });
        return error.SpawnFailed;
    };
    const ok = switch (r.term) {
        .exited => |c| c == 0,
        else => false,
    };
    return .{ .ok = ok, .stdout = r.stdout, .stderr = r.stderr };
}

/// Build + install the dependency packs and the ktor pack into a scratch
/// HOME, once per test-process.
fn installPacks(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, home: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, home) catch {};
    const pack_dirs = [_][]const u8{
        "kotlin-klio/klio-kotlinx-atomicfu",
        "kotlin-klio/klio-kotlinx-coroutines",
        "kotlin-klio/klio-kotlinx-io",
        "kotlin-klio/klio-ktor",
    };
    const pack_files = [_][]const u8{
        "target/packs/kotlinx.atomicfu.klio-pack",
        "target/packs/kotlinx.coroutines.klio-pack",
        "target/packs/kotlinx.io.klio-pack",
        "target/packs/io.ktor.klio-pack",
    };
    for (pack_dirs) |d| {
        const r = try runKlio(allocator, io, env, &.{ klioBin(env), "pack", "build", d });
        if (!r.ok) {
            std.debug.print("ktor_channel_async: pack build {s} failed:\n{s}\n", .{ d, r.stderr });
            return error.PackBuildFailed;
        }
    }
    for (pack_files) |f| {
        const r = try runKlio(allocator, io, env, &.{ klioBin(env), "pack", "install", f });
        if (!r.ok) {
            std.debug.print("ktor_channel_async: pack install {s} failed:\n{s}\n", .{ f, r.stderr });
            return error.PackInstallFailed;
        }
    }
}

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var packs_installed = false;

const SCRATCH_HOME = "/tmp/klio_itest_channel_home";
const TMP_DIR = "/tmp/klio_itest_channel";

fn runProgram(name: []const u8, src: []const u8, expected: []const u8) !void {
    return runProgramReclaim(name, src, expected, false);
}

/// Like `runProgram` but selects the tracing GC reclaim mode with a low
/// collection threshold (256 KB) so a collection fires repeatedly *during* the
/// channel I/O. This is the regression gate for coroutine GC-root completeness:
/// a closure body (a `launch`ed block) or a not-yet-started launched block that
/// outlives a mid-flight collection must keep its side-table slot and capture
/// store rooted, or the resumed body reads reclaimed/swept state and crashes.
fn runProgramGc(name: []const u8, src: []const u8, expected: []const u8) !void {
    return runProgramReclaim(name, src, expected, true);
}

fn runProgramReclaim(name: []const u8, src: []const u8, expected: []const u8, gc: bool) !void {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = try envWithHome(a, SCRATCH_HOME);
    if (!packs_installed) {
        try installPacks(a, io, &env, SCRATCH_HOME);
        packs_installed = true;
    }
    if (gc) {
        try env.put("KLIO_RECLAIM", "gc");
        try env.put("KLIO_GC_THRESHOLD_KB", "256");
    }

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, TMP_DIR) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name });
    try cwd.writeFile(io, .{ .sub_path = path, .data = src });

    const r = try runKlio(a, io, &env, &.{ klioBin(&env), "run", "--feature", "io.ktor/io", path });
    if (!r.ok) {
        std.debug.print("ktor_channel_async {s}: klio run failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ name, r.stdout, r.stderr });
        return error.KlioRunFailed;
    }
    try std.testing.expectEqualStrings(expected, r.stdout);
}

test "write, flushAndClose, readRemaining round-trips with closed-state getters" {
    try runProgram("channel_roundtrip",
        \\import io.ktor.utils.io.*
        \\import kotlinx.coroutines.*
        \\import kotlinx.io.readByteArray
        \\
        \\fun main() = runBlocking {
        \\    val ch = ByteChannel()
        \\    ch.writeStringUtf8("hello channel")
        \\    ch.flushAndClose()
        \\    println("closedForWrite=" + ch.isClosedForWrite)
        \\    println("closedCause=" + ch.closedCause)
        \\    val text = ch.readRemaining().readByteArray().decodeToString()
        \\    println("text=" + text)
        \\    println("closedForRead=" + ch.isClosedForRead)
        \\}
        \\
    ,
        \\closedForWrite=true
        \\closedCause=null
        \\text=hello channel
        \\closedForRead=true
        \\
    );
}

test "reader parks on awaitContent and a later writer resumes it" {
    try runProgram("channel_reader_parks",
        \\import io.ktor.utils.io.*
        \\import kotlinx.coroutines.*
        \\import kotlinx.io.readByteArray
        \\
        \\fun main() = runBlocking {
        \\    val ch = ByteChannel()
        \\    val reader = launch {
        \\        println("reader: awaiting")
        \\        val text = ch.readRemaining().readByteArray().decodeToString()
        \\        println("reader: got=" + text)
        \\    }
        \\    delay(10)
        \\    println("writer: writing")
        \\    ch.writeStringUtf8("parked then resumed")
        \\    ch.flushAndClose()
        \\    reader.join()
        \\    println("done")
        \\}
        \\
    ,
        \\reader: awaiting
        \\writer: writing
        \\reader: got=parked then resumed
        \\done
        \\
    );
}

test "writer parks on flush past CHANNEL_MAX_SIZE and the reader resumes it" {
    try runProgram("channel_writer_parks",
        \\import io.ktor.utils.io.*
        \\import kotlinx.coroutines.*
        \\import kotlinx.io.readByteArray
        \\
        \\fun main() = runBlocking {
        \\    val ch = ByteChannel()
        \\    val big = ByteArray(1024 * 1024 + 64) { (it % 251).toByte() }
        \\    val writer = launch {
        \\        println("writer: writing " + big.size)
        \\        ch.writeByteArray(big)
        \\        ch.flushAndClose()
        \\        println("writer: closed")
        \\    }
        \\    delay(10)
        \\    val got = ch.readRemaining().readByteArray()
        \\    writer.join()
        \\    println("reader: size=" + got.size + " ok=" + got.contentEquals(big))
        \\}
        \\
    ,
        \\writer: writing 1048640
        \\writer: closed
        \\reader: size=1048640 ok=true
        \\
    );
}

test "writer parks past CHANNEL_MAX_SIZE survives repeated GC mid-write (reclaim=gc)" {
    // Same 1 MB+ channel write as above, but under the tracing GC with a 256 KB
    // collection floor: a collection fires many times *while the writer body
    // runs and parks*. The writer is a `launch`ed closure whose block lives only
    // in the pump's drained-launched slice and whose body frame holds a copy of
    // its captures — neither pins the closure side-table slot, so without the
    // launched-block keepalive + the frame's `closure_id` root the slot is
    // reclaimed (its id recycled) and its capture store swept out from under the
    // resumed body. The pre-fix failure was `BinOp.Less on null` /
    // `compareTo on KlioBlockingCoroutine` inside the kotlinx-io transfer path.
    try runProgramGc("channel_writer_parks_gc",
        \\import io.ktor.utils.io.*
        \\import kotlinx.coroutines.*
        \\import kotlinx.io.readByteArray
        \\
        \\fun main() = runBlocking {
        \\    val ch = ByteChannel()
        \\    val big = ByteArray(1024 * 1024 + 64) { (it % 251).toByte() }
        \\    val writer = launch {
        \\        println("writer: writing " + big.size)
        \\        ch.writeByteArray(big)
        \\        ch.flushAndClose()
        \\        println("writer: closed")
        \\    }
        \\    delay(10)
        \\    val got = ch.readRemaining().readByteArray()
        \\    writer.join()
        \\    println("reader: size=" + got.size + " ok=" + got.contentEquals(big))
        \\}
        \\
    ,
        \\writer: writing 1048640
        \\writer: closed
        \\reader: size=1048640 ok=true
        \\
    );
}
