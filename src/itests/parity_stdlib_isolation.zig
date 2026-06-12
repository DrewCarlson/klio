//! Cross-program isolation gate for the once-per-process stdlib base.
//!
//! The in-process harness lowers the stdlib once and extends a clone per
//! program, so the contamination risk is a later program observing state an
//! earlier one defined or mutated — globals, object singletons, enum-entry
//! patches, installed packs. Each test runs a probe program, then a
//! polluting program that defines/mutates the SAME top-level names (and
//! pulls in the kotlinx packs), then the probe again: every probe run must
//! be byte-identical to the first, in both the embedded and pack modes. A
//! base-name-colliding program is interleaved too, so the whole-program
//! fallback path and the fast path alternate within one process.

const std = @import("std");
const parity = @import("parity");

const TMP_DIR = "/tmp/klio_itest_stdlib_isolation";

var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

fn writeProgram(a: std.mem.Allocator, io: std.Io, name: []const u8, src: []const u8) ![]const u8 {
    std.Io.Dir.cwd().createDirPath(io, TMP_DIR) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ TMP_DIR, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });
    return path;
}

fn runProgram(a: std.mem.Allocator, io: std.Io, path: []const u8, mode: parity.LoadMode) ![]const u8 {
    switch (try parity.runInMode(a, io, path, mode)) {
        .ok => |out| return out,
        .err => |e| {
            std.debug.print("klio run failed for {s}: {s}\n", .{ path, e });
            return error.TestUnexpectedResult;
        },
    }
}

/// The probe defines the same top-level names the polluter mutates, plus an
/// enum whose ctor args are patched at startup (the runtime-mutable part of
/// the cloned class table) and a lazily-initialized object.
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

/// Same names, different values and extra mutation; pulls in the
/// coroutines pack so pack sources + host bindings install mid-sequence.
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

/// Redeclares a stdlib top-level name (`log`), which forces the
/// whole-program fallback build in the same process.
const FALLBACK_SRC =
    \\fun log(s: String): String { println("local-log:" + s); return s }
    \\fun main() { println("fallback " + log("ok")) }
    \\
;

const FALLBACK_EXPECTED =
    "local-log:ok\n" ++
    "fallback ok\n";

fn assertSequence(mode: parity.LoadMode, polluter_mode: parity.LoadMode) !void {
    _ = file_arena.reset(.retain_capacity);
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const probe = try writeProgram(a, io, "probe", PROBE_SRC);
    const polluter = try writeProgram(a, io, "polluter", POLLUTER_SRC);
    const fallback = try writeProgram(a, io, "fallback", FALLBACK_SRC);

    // Probe first: records the pristine-base output.
    const first = try runProgram(a, io, probe, mode);
    try std.testing.expectEqualStrings(PROBE_EXPECTED, first);

    // Pollute: same top-level names, pack install, global/object/enum writes.
    const polluted = try runProgram(a, io, polluter, polluter_mode);
    try std.testing.expectEqualStrings(POLLUTER_EXPECTED, polluted);

    // Probe again: must be byte-identical to the pristine run.
    const second = try runProgram(a, io, probe, mode);
    try std.testing.expectEqualStrings(first, second);

    // Interleave the whole-program fallback path, then probe once more.
    const fb = try runProgram(a, io, fallback, mode);
    try std.testing.expectEqualStrings(FALLBACK_EXPECTED, fb);
    const third = try runProgram(a, io, probe, mode);
    try std.testing.expectEqualStrings(first, third);
}

test "stdlib base stays pristine across programs (embedded mode)" {
    try assertSequence(.EmbeddedOnly, .SourcePacks);
}

test "stdlib base stays pristine across programs (source packs)" {
    try assertSequence(.SourcePacks, .SourcePacks);
}

test "stdlib base stays pristine across programs (compiled packs)" {
    try assertSequence(.CompiledPacks, .CompiledPacks);
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
        for ([_]parity.LoadMode{ .EmbeddedOnly, .SourcePacks, .CompiledPacks }) |mode| {
            const out = try runProgram(a, io, probe, mode);
            try std.testing.expectEqualStrings(PROBE_EXPECTED, out);
        }
        const pout = try runProgram(a, io, polluter, .SourcePacks);
        try std.testing.expectEqualStrings(POLLUTER_EXPECTED, pout);
    }
}
