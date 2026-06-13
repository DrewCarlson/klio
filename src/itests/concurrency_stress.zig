//! Threaded stress gate for the pack-level concurrency primitives whose
//! upstream contracts require thread safety: ktor's `ConcurrentMap` and
//! `Attributes` (`computeIfAbsent` runs its block at most once per
//! absent key under contention) and the `io.ktor.utils.io.locks`
//! actuals (real mutual exclusion, used by `ByteChannel`'s flush
//! buffer), hammered from real OS threads (`kotlin.concurrent.thread`
//! — the genuinely parallel surface). The `ByteChannel` programs run
//! the write/read sides through the cooperative pump: a continuation
//! parked on one pump cannot yet be resumed from a foreign OS thread
//! (see plans/KTOR-UPSTREAM.md), so cross-thread channel contention is
//! exercised at the lock level, not the suspension level.
//!
//! Each program runs in a real `klio` child process against installed
//! packs (`klio pack build` + `pack install` into a scratch HOME), with
//! `KLIO_RACE_JITTER=1` set so the runtime widens borrow-acquisition
//! windows and a lost update / double-computed block reproduces
//! reliably instead of only on a rare interleaving.

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
    // Widen the borrow-acquisition windows in the child so a genuine
    // race reproduces reliably under this gate.
    try map.put("KLIO_RACE_JITTER", "1");
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
        std.debug.print("concurrency_stress: spawn {s} failed: {s}\n", .{ argv[0], @errorName(e) });
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
        "kotlin-klio/klio-ktor-client",
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
            std.debug.print("concurrency_stress: pack build {s} failed:\n{s}\n", .{ d, r.stderr });
            return error.PackBuildFailed;
        }
    }
    for (pack_files) |f| {
        const r = try runKlio(allocator, io, env, &.{ klioBin(env), "pack", "install", f });
        if (!r.ok) {
            std.debug.print("concurrency_stress: pack install {s} failed:\n{s}\n", .{ f, r.stderr });
            return error.PackInstallFailed;
        }
    }
}

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var packs_installed = false;

const SCRATCH_HOME = "/tmp/klio_itest_concstress_home";
const TMP_DIR = "/tmp/klio_itest_concstress";

fn runProgram(name: []const u8, src: []const u8, expected: []const u8) !void {
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

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, TMP_DIR) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name });
    try cwd.writeFile(io, .{ .sub_path = path, .data = src });

    const r = try runKlio(a, io, &env, &.{ klioBin(&env), "run", path });
    if (!r.ok) {
        std.debug.print("concurrency_stress {s}: klio run failed:\nstdout:\n{s}\nstderr:\n{s}\n", .{ name, r.stdout, r.stderr });
        return error.KlioRunFailed;
    }
    try std.testing.expectEqualStrings(expected, r.stdout);
}

test "ConcurrentMap survives a thread hammer and computes absent keys once" {
    try runProgram("concurrent_map_hammer",
        \\import io.ktor.util.collections.*
        \\import kotlin.concurrent.thread
        \\import kotlinx.atomicfu.atomic
        \\
        \\fun main() {
        \\    val map = ConcurrentMap<String, Int>()
        \\    val writers = ArrayList<Thread>()
        \\    for (w in 0 until 8) {
        \\        writers.add(thread {
        \\            for (i in 0 until 100) {
        \\                map.put("k$w-$i", w * 1000 + i)
        \\            }
        \\        })
        \\    }
        \\    for (t in writers) t.join()
        \\    println("size=" + map.size)
        \\    var intact = true
        \\    for (w in 0 until 8) {
        \\        for (i in 0 until 100) {
        \\            if (map["k$w-$i"] != w * 1000 + i) intact = false
        \\        }
        \\    }
        \\    println("intact=" + intact)
        \\
        \\    val once = ConcurrentMap<String, Int>()
        \\    val runs = atomic(0)
        \\    val agreed = atomic(0)
        \\    val racers = ArrayList<Thread>()
        \\    for (w in 0 until 8) {
        \\        racers.add(thread {
        \\            val v = once.computeIfAbsent("shared") {
        \\                runs.incrementAndGet()
        \\                Thread.sleep(10)
        \\                99
        \\            }
        \\            if (v == 99) agreed.incrementAndGet()
        \\        })
        \\    }
        \\    for (t in racers) t.join()
        \\    println("computeRuns=" + runs.value + " agreed=" + agreed.value)
        \\}
        \\
    ,
        \\size=800
        \\intact=true
        \\computeRuns=1 agreed=8
        \\
    );
}

test "Attributes computeIfAbsent runs its block once under contention" {
    try runProgram("attributes_compute_once",
        \\import io.ktor.util.*
        \\import kotlin.concurrent.thread
        \\import kotlinx.atomicfu.atomic
        \\
        \\fun main() {
        \\    val attrs = Attributes(true)
        \\    val key = AttributeKey<Int>("counter")
        \\    val runs = atomic(0)
        \\    val agreed = atomic(0)
        \\    val racers = ArrayList<Thread>()
        \\    for (w in 0 until 8) {
        \\        racers.add(thread {
        \\            val v = attrs.computeIfAbsent(key) {
        \\                runs.incrementAndGet()
        \\                Thread.sleep(10)
        \\                7
        \\            }
        \\            if (v == 7) agreed.incrementAndGet()
        \\        })
        \\    }
        \\    for (t in racers) t.join()
        \\    println("runs=" + runs.value + " agreed=" + agreed.value + " present=" + attrs.contains(key))
        \\}
        \\
    ,
        \\runs=1 agreed=8 present=true
        \\
    );
}

test "ktor locks hold real mutual exclusion across threads" {
    try runProgram("ktor_locks_mutex",
        \\import io.ktor.utils.io.locks.*
        \\import kotlin.concurrent.thread
        \\
        \\fun main() {
        \\    val lock = ReentrantLock()
        \\    var counter = 0
        \\    val lockers = ArrayList<Thread>()
        \\    for (n in 0 until 8) {
        \\        lockers.add(thread {
        \\            repeat(300) {
        \\                lock.withLock { counter += 1 }
        \\            }
        \\        })
        \\    }
        \\    for (t in lockers) t.join()
        \\
        \\    val mon = SynchronizedObject()
        \\    var sync = 0
        \\    val syncers = ArrayList<Thread>()
        \\    for (n in 0 until 8) {
        \\        syncers.add(thread {
        \\            repeat(300) {
        \\                synchronized(mon) { sync += 1 }
        \\            }
        \\        })
        \\    }
        \\    for (t in syncers) t.join()
        \\    println("lock=" + counter + " sync=" + sync)
        \\}
        \\
    ,
        \\lock=2400 sync=2400
        \\
    );
}

test "ByteChannel writer and reader interleave with real locks held" {
    try runProgram("channel_worker_writer",
        \\import io.ktor.utils.io.*
        \\import kotlinx.coroutines.*
        \\import kotlinx.io.readByteArray
        \\
        \\fun main() = runBlocking {
        \\    val ch = ByteChannel()
        \\    val big = ByteArray(1024 * 1024 + 64) { (it % 251).toByte() }
        \\    val writer = launch(Dispatchers.Default) {
        \\        ch.writeByteArray(big)
        \\        ch.flushAndClose()
        \\    }
        \\    val got = ch.readRemaining().readByteArray()
        \\    writer.join()
        \\    println("size=" + got.size + " ok=" + got.contentEquals(big))
        \\}
        \\
    ,
        \\size=1048640 ok=true
        \\
    );
}

test "ByteChannel flush-per-byte keeps every byte in order" {
    try runProgram("channel_worker_flush_loop",
        \\import io.ktor.utils.io.*
        \\import kotlinx.coroutines.*
        \\import kotlinx.io.readByteArray
        \\
        \\fun main() = runBlocking {
        \\    val ch = ByteChannel()
        \\    val writer = launch(Dispatchers.Default) {
        \\        repeat(500) { i ->
        \\            ch.writeByte((i % 64).toByte())
        \\            ch.flush()
        \\        }
        \\        ch.flushAndClose()
        \\    }
        \\    val got = ch.readRemaining().readByteArray()
        \\    writer.join()
        \\    var ordered = true
        \\    for (i in 0 until 500) {
        \\        if (got[i].toInt() != i % 64) ordered = false
        \\    }
        \\    println("n=" + got.size + " ordered=" + ordered)
        \\}
        \\
    ,
        \\n=500 ordered=true
        \\
    );
}
