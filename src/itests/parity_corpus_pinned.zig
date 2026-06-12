//! Pinned parity-corpus fixtures. Each test runs one real
//! `tests/fixtures/parity_corpus/*.kt` program through the in-process
//! pipeline and asserts kotlinc's output (kotlinc-jvm 2.3.21), so the
//! fixtures gate under `zig build test` — the kotlinc-backed corpus
//! sweep (`klio-parity --sweep corpus`) needs a kotlinc install and runs
//! out-of-band.

const std = @import("std");
const parity = @import("parity");

const CORPUS_DIR = "tests/fixtures/parity_corpus";

// One arena shared by every pipeline run in this file. The pipeline
// installs process-global tables backed by the build allocator; a fresh
// per-test arena would free that memory out from under the still-live
// globals. Mirrors the e2e harness.
var shared_arena: ?std.heap.ArenaAllocator = null;

fn arenaAllocator() std.mem.Allocator {
    if (shared_arena) |*a| {
        _ = a.reset(.retain_capacity);
    } else {
        shared_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
    return shared_arena.?.allocator();
}

/// Run `tests/fixtures/parity_corpus/<stem>.kt` and assert its stdout.
fn check(stem: []const u8, expected: []const u8) !void {
    const a = arenaAllocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const file = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ CORPUS_DIR, stem });
    const res = try parity.runWithPacks(a, io, file);
    switch (res) {
        .ok => |got| try std.testing.expectEqualStrings(expected, got),
        .err => |m| {
            std.debug.print("parity corpus {s}: klio error: {s}\n", .{ stem, m });
            return error.KlioRunFailed;
        },
    }
}

test "annotated_expression_body" {
    try check("annotated_expression_body",
        \\neg
        \\zero
        \\pos
        \\1
        \\null
        \\
    );
}

test "elvis_line_continuation" {
    try check("elvis_line_continuation",
        \\7
        \\-1
        \\anonymous
        \\
    );
}

test "companion_init_reads_top_const" {
    try check("companion_init_reads_top_const",
        \\200
        \\101
        \\100
        \\
    );
}

test "method_fn_ref_default_param" {
    try check("method_fn_ref_default_param",
        \\ANN!
        \\<ann>
        \\<ann>
        \\[ann]
        \\
    );
}

test "nested_enum_in_class" {
    try check("nested_enum_in_class",
        \\RED
        \\GREEN
        \\YELLOW
        \\RED
        \\GREEN
        \\
    );
}

test "unsigned_compare" {
    try check("unsigned_compare",
        \\true
        \\true
        \\false
        \\false
        \\5
        \\1
        \\3
        \\true
        \\10
        \\3
        \\[1, 1, 3, 4, 5]
        \\4
        \\
    );
}

test "exception_hierarchy_multilevel" {
    try check("exception_hierarchy_multilevel",
        \\notfound app=true rt=true th=true
        \\timeout app=true rt=true th=true
        \\other app=false rt=true th=true
        \\caught-as-AppError msg=boom
        \\not here
        \\timeout
        \\wrapped-msg
        \\
    );
}

test "compound_assign_val_plus_assign" {
    try check("compound_assign_val_plus_assign",
        \\[base, user, tail]
        \\false
        \\
    );
}

test "apply_fills_positional_param" {
    try check("apply_fills_positional_param",
        \\direct
        \\direct
        \\install data on s1
        \\
    );
}

test "member_shadowed_buildstring" {
    try check("member_shadowed_buildstring",
        \\member:auth(example.com)
        \\auth(example.com)
        \\
    );
}

test "fn_param_member_vs_string_extension" {
    try check("fn_param_member_vs_string_extension",
        \\http://a/
        \\http://b/
        \\
    );
}

test "init_block_companion_call" {
    try check("init_block_companion_call",
        \\10
        \\1
        \\
    );
}

test "iface_default_named_overload_typealias" {
    try check("iface_default_named_overload_typealias",
        \\handler go
        \\r=1
        \\
    );
}

test "bare_call_prop_vs_toplevel_fn" {
    try check("bare_call_prop_vs_toplevel_fn",
        \\[1, 2, 3]
        \\3
        \\
    );
}

test "local_ext_fn_capture_receiver" {
    try check("local_ext_fn_capture_receiver",
        \\snd:7|false|tail
        \\
    );
}

test "named_arg_explicit_null" {
    try check("named_arg_explicit_null",
        \\h null-branch
        \\h null-branch
        \\h ise
        \\h other
        \\
    );
}

test "when_comma_conditions_lazy" {
    try check("when_comma_conditions_lazy",
        \\two-or-three
        \\ab
        \\two-or-three
        \\abc
        \\none
        \\abcd
        \\
    );
}

test "member_lambda_param_vs_inline_ext" {
    try check("member_lambda_param_vs_inline_ext",
        \\[on] lambda message 2
        \\[on] plain message
        \\
    );
}

test "file_private_top_level_props" {
    const a = arenaAllocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const res = try parity.runFilesWithPacks(a, io, &.{
        CORPUS_DIR ++ "/file_private_props/file_a.kt",
        CORPUS_DIR ++ "/file_private_props/file_b.kt",
    });
    switch (res) {
        .ok => |got| try std.testing.expectEqualStrings(
            \\logger-a
            \\logger-b
            \\
        , got),
        .err => |m| {
            std.debug.print("parity corpus file_private_props: klio error: {s}\n", .{m});
            return error.KlioRunFailed;
        },
    }
}

test "file_private_types" {
    const a = arenaAllocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const res = try parity.runFilesWithPacks(a, io, &.{
        CORPUS_DIR ++ "/file_private_types/file_a.kt",
        CORPUS_DIR ++ "/file_private_types/file_b.kt",
    });
    switch (res) {
        .ok => |got| try std.testing.expectEqualStrings(
            \\yx
            \\ab
            \\
        , got),
        .err => |m| {
            std.debug.print("parity corpus file_private_types: klio error: {s}\n", .{m});
            return error.KlioRunFailed;
        },
    }
}

test "internal_props_cross_package" {
    const a = arenaAllocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const res = try parity.runFilesWithPacks(a, io, &.{
        CORPUS_DIR ++ "/internal_props/alpha.kt",
        CORPUS_DIR ++ "/internal_props/beta.kt",
        CORPUS_DIR ++ "/internal_props/main.kt",
    });
    switch (res) {
        .ok => |got| try std.testing.expectEqualStrings(
            \\alpha-state
            \\beta-state
            \\1
            \\101
            \\2
            \\102
            \\501
            \\3
            \\
        , got),
        .err => |m| {
            std.debug.print("parity corpus internal_props: klio error: {s}\n", .{m});
            return error.KlioRunFailed;
        },
    }
}

test "companion_member_extension_import" {
    try check("companion_member_extension_import",
        \\a=label:none
        \\aw=null
        \\b=label:boom
        \\bw=wrapped:boom
        \\bx=X:boom
        \\
    );
}

test "reified_ctor_ref_inference" {
    try check("reified_ctor_ref_inference",
        \\empty+hit;same:Read(c1)+hit;
        \\read:Read(c2)+hit;same:Write(c3)+hit;
        \\
    );
}
