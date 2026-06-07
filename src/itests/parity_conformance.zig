//! Memory-model conformance suite. Each litmus program in
//! `tests/fixtures/conformance/` is the executable form of one rule
//! in the memory model. Expected stdout is encoded as leading `//> ` comment
//! lines.

const std = @import("std");
const parity = @import("parity");

const CONFORMANCE_DIR = "tests/fixtures/conformance";

// One arena shared by every pipeline run in this file. The pipeline installs
// process-global tables (inline-fn ASTs, the enclosing-`this` stack, ...)
// backed by the build allocator; a fresh per-test arena would free that
// memory out from under the still-live globals and the next run would touch
// freed pages. A single file-scoped arena keeps them valid across all tests,
// and stays off the leak-checking test allocator. Mirrors the e2e harness.
var shared_arena: ?std.heap.ArenaAllocator = null;

fn arenaAllocator() std.mem.Allocator {
    if (shared_arena == null) {
        shared_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
    return shared_arena.?.allocator();
}

/// Expected stdout = the leading run of `//> ` comment lines, each contributing
/// one output line, terminated by a newline (matching the join convention of
/// the runner). Caller owns the returned bytes.
fn expectedStdout(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const t = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, t, "//>")) {
            const rest = t["//>".len..];
            const body = if (std.mem.startsWith(u8, rest, " ")) rest[1..] else rest;
            try out.appendSlice(allocator, body);
            try out.append(allocator, '\n');
        } else if (std.mem.startsWith(u8, t, "//") or out.items.len == 0) {
            // Skip leading comments and blank lead-in.
        } else {
            break;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn check(stem: []const u8) !void {
    const a = arenaAllocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const file = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ CONFORMANCE_DIR, stem });
    const src = std.Io.Dir.cwd().readFileAlloc(io, file, a, .unlimited) catch |e| {
        std.debug.print("conformance {s}: missing litmus {s} ({s})\n", .{ stem, file, @errorName(e) });
        return error.MissingLitmus;
    };
    const want = try expectedStdout(a, src);
    try std.testing.expect(want.len != 0);

    const res = try parity.runWithPacks(a, io, file);
    switch (res) {
        .ok => |got| try std.testing.expectEqualStrings(want, got),
        .err => |m| {
            std.debug.print("conformance {s}: klio error: {s}\n", .{ stem, m });
            return error.KlioRunFailed;
        },
    }
}

test "mm1_no_tearing" {
    try check("mm1_no_tearing");
}
test "mm2_drf_sc" {
    try check("mm2_drf_sc");
}
test "mm3_no_oota" {
    try check("mm3_no_oota");
}
test "mm4_safe_publication" {
    try check("mm4_safe_publication");
}
test "mm5_volatile" {
    try check("mm5_volatile");
}
test "mm6_monitor" {
    try check("mm6_monitor");
}
test "mm7_atomics" {
    try check("mm7_atomics");
}
test "mm8_thread_join" {
    try check("mm8_thread_join");
}
test "mm9_coroutine_hb" {
    try check("mm9_coroutine_hb");
}
test "mm10_channel_flow" {
    try check("mm10_channel_flow");
}
test "mm11_no_lost_tearing" {
    try check("mm11_no_lost_tearing");
}

// Every litmus file is accounted for in exactly one bucket, and every rule
// MM1..MM11 has a file. Guards against silently orphaned or missing litmus
// programs.
test "conformance_suite_is_complete" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const RUNNABLE = [_][]const u8{
        "mm1_no_tearing",
        "mm2_drf_sc",
        "mm3_no_oota",
        "mm4_safe_publication",
        "mm5_volatile",
        "mm6_monitor",
        "mm7_atomics",
        "mm8_thread_join",
        "mm9_coroutine_hb",
        "mm10_channel_flow",
        "mm11_no_lost_tearing",
    };

    var on_disk: std.ArrayList([]u8) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, CONFORMANCE_DIR, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".kt")) continue;
        const stem = entry.name[0 .. entry.name.len - ".kt".len];
        try on_disk.append(a, try a.dupe(u8, stem));
    }
    std.mem.sort([]u8, on_disk.items, {}, struct {
        fn lessThan(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);

    var classified: std.ArrayList([]const u8) = .empty;
    for (RUNNABLE) |s| try classified.append(a, s);
    std.mem.sort([]const u8, classified.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);

    try std.testing.expectEqual(classified.items.len, on_disk.items.len);
    for (on_disk.items, classified.items) |d, c| {
        try std.testing.expectEqualStrings(c, d);
    }

    var n: usize = 1;
    while (n <= 11) : (n += 1) {
        const prefix = try std.fmt.allocPrint(a, "mm{d}_", .{n});
        var found = false;
        for (classified.items) |s| {
            if (std.mem.startsWith(u8, s, prefix)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}
