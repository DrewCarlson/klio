//! Threaded-litmus suite. Each program in the litmus directory pins down one
//! observable guarantee of multi-threaded execution (mutual exclusion,
//! publication, no lost update). Expected stdout is encoded as leading `//> `
//! comment lines, exactly like the memory-model `conformance` suite.
//!
//! Programs whose guarantee already holds under the serialized interpreter (a
//! `synchronized` block reduces to in-order execution on one thread) assert
//! exact stdout today (`RUNNABLE`). Programs that genuinely need OS-thread
//! spawning to be meaningful are listed in `PENDING`, keyed by the blocker,
//! and run by an ignored test until real thread spawn lands.
const std = @import("std");
const parity = @import("parity");

/// The litmus corpus directory, relative to the workspace root (cwd).
const LITMUS_DIR = "tests/fixtures/threaded_litmus";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

/// Expected stdout = the leading run of `//> ` comment lines, each
/// contributing one output line (matching `runWithPacks`'s join convention).
/// Mirrors the `conformance` harness. Returns owned bytes.
fn expectedStdout(allocator: std.mem.Allocator, io: std.Io, file: []const u8) ![]u8 {
    const src = try std.Io.Dir.cwd().readFileAlloc(io, file, allocator, .unlimited);
    defer allocator.free(src);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trimStart(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "//>")) {
            var rest = t[3..];
            if (rest.len != 0 and rest[0] == ' ') rest = rest[1..];
            // Strip a trailing CR left by the `\n` split on CRLF input.
            rest = std.mem.trimEnd(u8, rest, "\r");
            try out.appendSlice(allocator, rest);
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
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const file = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ LITMUS_DIR, stem });
    const st = std.Io.Dir.cwd().statFile(io, file, .{}) catch {
        std.debug.print("missing litmus {s}\n", .{file});
        return error.MissingLitmus;
    };
    if (st.kind != .file) {
        std.debug.print("missing litmus {s}\n", .{file});
        return error.MissingLitmus;
    }
    const want = try expectedStdout(a, io, file);
    if (want.len == 0) {
        std.debug.print("no //> expected lines in {s}\n", .{stem});
        return error.NoExpectedLines;
    }
    const res = try parity.runWithPacks(a, io, file);
    switch (res) {
        .ok => |got| std.testing.expectEqualStrings(want, got) catch |e| {
            std.debug.print("threaded litmus {s}: stdout mismatch\n got: {s}\nwant: {s}\n", .{ stem, got, want });
            return e;
        },
        .err => |m| {
            std.debug.print("threaded litmus {s}: klio error: {s}\n", .{ stem, m });
            return error.KlioRunFailed;
        },
    }
}

/// Guarantees that hold under the serialized interpreter today — enforced now.
const RUNNABLE = [_][]const u8{
    "tl_smoke",
    "tl_thread_join",
    "tl_sync_counter",
    "tl_parallel_partition",
    "tl_async_parallel",
    "tl_withcontext_io",
    "tl_dispatch_many",
    "tl_thread_sleep",
};

/// Guarantees that only become meaningful with real OS-thread spawning.
/// `(stem, blocker)`. Each moves into `RUNNABLE` when its blocker lands.
/// Empty today: the threaded corpus grows here.
const PENDING = [_]struct { stem: []const u8, blocker: []const u8 }{
    // .{ .stem = "tl_two_thread_monitor", .blocker = "needs real thread spawn" },
    // .{ .stem = "tl_safe_publication", .blocker = "needs real thread spawn" },
};

// Each litmus stem is its own `test` so they run as separate cases.
test "tl_smoke" {
    try check("tl_smoke");
}
test "tl_thread_join" {
    try check("tl_thread_join");
}
test "tl_sync_counter" {
    try check("tl_sync_counter");
}
test "tl_parallel_partition" {
    try check("tl_parallel_partition");
}
test "tl_async_parallel" {
    try check("tl_async_parallel");
}
test "tl_withcontext_io" {
    try check("tl_withcontext_io");
}
test "tl_dispatch_many" {
    try check("tl_dispatch_many");
}
test "tl_thread_sleep" {
    try check("tl_thread_sleep");
}

// Pending litmus: un-ignore as real thread spawn lands. Mirrors the Rust
// `#[ignore]`d test — skipped today (PENDING is empty).
test "threaded_litmus_pending" {
    if (PENDING.len == 0) return error.SkipZigTest;
    for (PENDING) |p| {
        try check(p.stem);
    }
}

// Every litmus file on disk is classified exactly once. Guards against an
// orphaned or unlisted program slipping in.
test "threaded_litmus_suite_is_complete" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var on_disk: std.ArrayList([]const u8) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, LITMUS_DIR, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".kt")) continue;
        const stem = entry.name[0 .. entry.name.len - ".kt".len];
        try on_disk.append(a, try a.dupe(u8, stem));
    }
    std.mem.sort([]const u8, on_disk.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);

    var classified: std.ArrayList([]const u8) = .empty;
    for (RUNNABLE) |s| try classified.append(a, s);
    for (PENDING) |p| try classified.append(a, p.stem);
    std.mem.sort([]const u8, classified.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);

    try std.testing.expectEqual(classified.items.len, on_disk.items.len);
    for (on_disk.items, classified.items) |d, c| {
        std.testing.expectEqualStrings(c, d) catch |e| {
            std.debug.print("every threaded_litmus/*.kt must be in RUNNABLE or PENDING exactly once\n", .{});
            return e;
        };
    }
}
