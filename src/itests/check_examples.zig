//! Example programs run the static pipeline with the stdlib assembled as `klio
//! check` assembles it, and must emit zero diagnostics anchored in the user file.

const std = @import("std");
const parity = @import("parity");
const resolver = @import("resolver");
const typeck = @import("typeck");
const diagnostics = @import("diagnostics");

fn expectCheckClean(file: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(arena, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const loaded = switch (try parity.loadProgram(arena, io, file, .EmbeddedOnly)) {
        .ok => |l| l,
        .err => |e| {
            std.debug.print("load {s} failed: {s}\n", .{ file, e });
            return error.TestUnexpectedResult;
        },
    };
    // `loadProgram` appends the user file last; pack and stdlib diagnostics are ignored.
    const user_file = loaded.asts[loaded.asts.len - 1].span.file;

    var failed = false;
    const r = try resolver.resolveModule(arena, loaded.asts);
    for (r.diagnostics.diags()) |d| {
        if (d.primary.span.file.int() != user_file.int()) continue;
        const msg = try diagnostics.render.plain.toString(arena, &.{d}, loaded.map);
        std.debug.print("unexpected resolver diagnostic in {s}: {s}\n", .{ file, msg });
        failed = true;
    }
    const tc = try typeck.typecheckModule(arena, loaded.asts, &r);
    for (tc.diagnostics.diags()) |d| {
        if (d.primary.span.file.int() != user_file.int()) continue;
        const msg = try diagnostics.render.plain.toString(arena, &.{d}, loaded.map);
        std.debug.print("unexpected typeck diagnostic in {s}: {s}\n", .{ file, msg });
        failed = true;
    }
    if (failed) return error.TestUnexpectedResult;
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
