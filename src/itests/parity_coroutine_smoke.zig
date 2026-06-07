//! Regression net for the currently-working coroutine subset. Locks down
//! behavior across the layer-split and coroutine stages: a pure refactor must
//! not change any of these outputs. Expected stdout is encoded as leading
//! `//> ` comment lines.

const std = @import("std");
const parity = @import("parity");

const SMOKE_DIR = "tests/fixtures/coroutine_smoke";

// The klio pipeline installs process-global lowering/VM state (inline-fn
// tables, the enclosing-`this` stack) backed by the run's allocator. A
// per-test arena would be torn down while those globals still point into it,
// so one file-scoped arena over the page allocator backs every run here (the
// leak-checking test allocator is never used, matching the e2e harness).
var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);


/// Expected stdout = the leading run of `//> ` comment lines. Caller owns the
/// returned bytes.
fn expected(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
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

fn runSmoke(stem: []const u8) !void {
    const a = file_arena.allocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const file = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ SMOKE_DIR, stem });
    const src = std.Io.Dir.cwd().readFileAlloc(io, file, a, .unlimited) catch |e| {
        std.debug.print("coroutine smoke {s}: read {s} ({s})\n", .{ stem, file, @errorName(e) });
        return error.MissingSource;
    };
    const want = try expected(a, src);
    try std.testing.expect(want.len != 0);

    const res = try parity.runWithPacks(a, io, file);
    switch (res) {
        .ok => |got| try std.testing.expectEqualStrings(want, got),
        .err => |m| {
            std.debug.print("coroutine smoke {s}: {s}\n", .{ stem, m });
            return error.KlioRunFailed;
        },
    }
}

test "cs1_launch_delay" {
    try runSmoke("cs1_launch_delay");
}
test "cs2_async_await" {
    try runSmoke("cs2_async_await");
}
test "cs3_many_launch" {
    try runSmoke("cs3_many_launch");
}
test "cs4_suspend_seq" {
    try runSmoke("cs4_suspend_seq");
}
test "cs5_flow_builder" {
    try runSmoke("cs5_flow_builder");
}
test "cs6_flow_operators" {
    try runSmoke("cs6_flow_operators");
}
test "cs7_scope_builders" {
    try runSmoke("cs7_scope_builders");
}
