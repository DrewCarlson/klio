//! Cross-program isolation gate for the base the data home caches: its image
//! is baked once and every later program builds over it. Each test runs a
//! probe, a polluter that redefines the same top-level names and pulls in a
//! pack, then the probe again: every probe run must be byte-identical to the
//! first. The base is built from the image or afresh (`klio_child.Mode`).

const std = @import("std");
const klio_child = @import("klio_child");

const TMP_DIR = "/tmp/klio_itest_stdlib_isolation";

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

fn writeProgram(a: std.mem.Allocator, io: std.Io, name: []const u8, src: []const u8) ![]const u8 {
    std.Io.Dir.cwd().createDirPath(io, TMP_DIR) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });
    return path;
}

fn runProgram(a: std.mem.Allocator, io: std.Io, path: []const u8, mode: klio_child.Mode) ![]const u8 {
    _ = io;
    switch (try klio_child.run(a, &.{path}, .{ .mode = mode })) {
        .ok => |out| return out,
        .err => |e| {
            std.debug.print("klio run failed for {s}: {s}\n", .{ path, e });
            return error.TestUnexpectedResult;
        },
    }
}

/// The enum is patched at startup: the mutable part of the cloned class table.
const PROBE_SRC =
    \\var sharedCounter = 7
    \\object Registry {
    \\    init { println("registry-init") }
    \\    var total = 5
    \\    val items = mutableListOf<String>()
    \\}
    \\enum class Paint(val code: Int) { RED(10), GREEN(20) }
    \\fun main() {
    \\    println("probe " + sharedCounter + " " + Registry.total + " " + Registry.items.size)
    \\    sharedCounter += 1
    \\    Registry.total += 1
    \\    Registry.items.add("x")
    \\    println("paint " + Paint.RED.code + " " + Paint.GREEN.code + " " + Paint.GREEN.ordinal)
    \\    println("after " + sharedCounter + " " + Registry.total + " " + Registry.items.size)
    \\}
    \\
;

const PROBE_EXPECTED =
    "registry-init\n" ++
    "probe 7 5 0\n" ++
    "paint 10 20 1\n" ++
    "after 8 6 1\n";

/// Pulls in the coroutines pack, so pack sources and host bindings install
/// mid-sequence.
const POLLUTER_SRC =
    \\import kotlinx.coroutines.runBlocking
    \\var sharedCounter = 0
    \\object Registry {
    \\    init { println("polluter-registry-init") }
    \\    var total = 0
    \\    val items = mutableListOf<String>()
    \\}
    \\enum class Paint(val code: Int) { RED(1), GREEN(2), BLUE(3) }
    \\fun main() {
    \\    sharedCounter = 41
    \\    Registry.total = 99
    \\    Registry.items.add("polluted")
    \\    Registry.items.add("twice")
    \\    runBlocking { }
    \\    println("polluter " + sharedCounter + " " + Registry.total + " " + Registry.items.size + " " + Paint.BLUE.code)
    \\}
    \\
;

const POLLUTER_EXPECTED =
    "polluter-registry-init\n" ++
    "polluter 41 99 2 3\n";

/// Redeclares the stdlib name `log`.
const FALLBACK_SRC =
    \\fun log(s: String): String { println("local-log:" + s); return s }
    \\fun main() { println("fallback " + log("ok")) }
    \\
;

const FALLBACK_EXPECTED =
    "local-log:ok\n" ++
    "fallback ok\n";

fn assertSequence(mode: klio_child.Mode, polluter_mode: klio_child.Mode) !void {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const probe = try writeProgram(a, io, "probe", PROBE_SRC);
    const polluter = try writeProgram(a, io, "polluter", POLLUTER_SRC);
    const fallback = try writeProgram(a, io, "fallback", FALLBACK_SRC);

    const first = try runProgram(a, io, probe, mode);
    try std.testing.expectEqualStrings(PROBE_EXPECTED, first);

    const polluted = try runProgram(a, io, polluter, polluter_mode);
    try std.testing.expectEqualStrings(POLLUTER_EXPECTED, polluted);

    const second = try runProgram(a, io, probe, mode);
    try std.testing.expectEqualStrings(first, second);

    const fb = try runProgram(a, io, fallback, mode);
    try std.testing.expectEqualStrings(FALLBACK_EXPECTED, fb);
    const third = try runProgram(a, io, probe, mode);
    try std.testing.expectEqualStrings(first, third);
}

test "stdlib base stays pristine across programs (probe on a fresh base)" {
    try assertSequence(.cold, .image);
}

test "stdlib base stays pristine across programs (base image)" {
    try assertSequence(.image, .image);
}

test "stdlib base stays pristine across programs (polluter on a fresh base)" {
    try assertSequence(.image, .cold);
}

test "repeated alternating modes stay deterministic" {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const probe = try writeProgram(a, io, "probe_alt", PROBE_SRC);
    const polluter = try writeProgram(a, io, "polluter_alt", POLLUTER_SRC);

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        for ([_]klio_child.Mode{ .image, .cold }) |mode| {
            const out = try runProgram(a, io, probe, mode);
            try std.testing.expectEqualStrings(PROBE_EXPECTED, out);
        }
        const pout = try runProgram(a, io, polluter, .image);
        try std.testing.expectEqualStrings(POLLUTER_EXPECTED, pout);
    }
}
