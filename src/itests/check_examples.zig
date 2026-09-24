//! Example programs run through `klio check` and must emit zero diagnostics
//! anchored in the checked file.

const std = @import("std");
const klio_child = @import("klio_child");

fn expectCheckClean(file: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var env = try klio_child.baseEnv(a);
    const r = try klio_child.runKlio(a, &env, &.{ klio_child.bin(), "check", file }, .{});
    const anchored = std.mem.find(u8, r.stdout, file) != null or std.mem.find(u8, r.stderr, file) != null;
    if (r.exitedZero() and !anchored) return;
    std.debug.print("klio check {s} (exit {d}):\n{s}{s}\n", .{ file, r.code(), r.stdout, r.stderr });
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
