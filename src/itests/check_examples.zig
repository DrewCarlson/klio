//! `klio check` pipeline gate.
//!
//! Representative example programs must come out of the static checking
//! pipeline (lexer -> parser -> resolveModule -> typecheckModule, with the
//! stdlib assembled exactly as `klio check` assembles it) with ZERO
//! diagnostics anchored in the user file. Each picked example exercises a
//! shape that has regressed before: string templates with `$ident`
//! fragments and `when (val v = …)` bindings, `vararg` arity + spread at
//! call sites, and builder lambdas (`buildList { add(…) }`).

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
    // `loadProgram` appends the user file last; diagnostics are filtered to
    // it the same way `klio check` trusts pack/stdlib shims.
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
