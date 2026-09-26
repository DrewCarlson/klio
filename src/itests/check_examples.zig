//! Example programs run through `klio check` and must emit zero diagnostics
//! anchored in the checked file.

const std = @import("std");
const klio_child = @import("klio_child");

fn expectCheckClean(file: []const u8) !void {
    try expectCheckCleanWith(file, "old");
    try expectCheckCleanWith(file, "sema");
}

fn expectCheckCleanWith(file: []const u8, engine: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var env = try klio_child.baseEnv(a);
    const r = try klio_child.runKlio(a, &env, &.{ klio_child.bin(), "check", "--engine", engine, file }, .{});
    const anchored = std.mem.find(u8, r.stdout, file) != null or std.mem.find(u8, r.stderr, file) != null;
    if (r.exitedZero() and !anchored) return;
    std.debug.print("klio check --engine {s} {s} (exit {d}):\n{s}{s}\n", .{ engine, file, r.code(), r.stdout, r.stderr });
    return error.TestUnexpectedResult;
}

test "check is clean on string templates and when-subject bindings" {
    try expectCheckClean("examples/when_binding.kt");
}

test "check is clean on vararg arity and spread call sites" {
    try expectCheckClean("examples/vararg_spread.kt");
}

test "check is clean on builder lambdas" {
    try expectCheckClean("examples/build_helpers.kt");
}

// Checking must stay linear in chain depth; re-typing the receiver per level
// costs O(2^depth) and never finishes.
test "check is clean on a deep method-call chain" {
    try expectCheckClean("examples/deep_call_chain.kt");
}

test "check with sema names kotlinc's diagnostics and honors @Suppress" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const file = "tests/fixtures/check_sema/diagnostics.kt";
    var env = try klio_child.baseEnv(a);
    const r = try klio_child.runKlio(a, &env, &.{ klio_child.bin(), "check", "--engine=sema", "--format=json", file }, .{});
    errdefer std.debug.print("klio check (exit {d}):\n{s}{s}\n", .{ r.code(), r.stdout, r.stderr });
    try std.testing.expectEqual(@as(i64, 1), r.code());
    var got: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        const o = parsed.object;
        const start = o.get("range").?.object.get("start").?.object;
        try got.append(a, try std.fmt.allocPrint(a, "{s} {s} {d}:{d}", .{
            o.get("factory").?.string,
            o.get("severity").?.string,
            start.get("line").?.integer,
            start.get("col").?.integer,
        }));
    }
    const want = [_][]const u8{
        "CONFLICTING_OVERLOADS error 3:5",
        "CONFLICTING_OVERLOADS error 4:5",
        "REDECLARATION error 10:9",
        "REDECLARATION error 11:9",
        "UNRESOLVED_REFERENCE error 15:13",
        "UNRESOLVED_REFERENCE error 16:16",
    };
    try std.testing.expectEqual(want.len, got.items.len);
    for (want, got.items) |w, g| try std.testing.expectEqualStrings(w, g);
}
