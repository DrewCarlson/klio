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

/// Run `tests/fixtures/parity_corpus/<stem>.kt` and assert the program is
/// rejected before it runs, the rejection message containing `needle`.
/// Mirrors a kotlinc compile error (e.g. `unresolved reference 'it'`).
fn checkErr(stem: []const u8, needle: []const u8) !void {
    const a = arenaAllocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const file = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ CORPUS_DIR, stem });
    const res = try parity.runWithPacks(a, io, file);
    switch (res) {
        .ok => |got| {
            std.debug.print("parity corpus {s}: expected rejection, ran with output:\n{s}\n", .{ stem, got });
            return error.ExpectedRejection;
        },
        .err => |m| {
            if (std.mem.indexOf(u8, m, needle) == null) {
                std.debug.print("parity corpus {s}: rejection `{s}` missing `{s}`\n", .{ stem, m, needle });
                return error.WrongRejection;
            }
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

test "inline_param_shadows_caller" {
    try check("inline_param_shadows_caller",
        \\result=40
        \\calls=1
        \\
    );
}

test "lambda_it_receiver_enclosing" {
    try check("lambda_it_receiver_enclosing",
        \\0
        \\1
        \\
    );
}

test "lambda_it_zero_param_enclosing" {
    try check("lambda_it_zero_param_enclosing",
        \\0
        \\1
        \\
    );
}

test "lambda_it_nested_shadow" {
    try check("lambda_it_nested_shadow",
        \\1
        \\2
        \\1
        \\2
        \\
    );
}

test "lambda_it_receiver_in_foreach" {
    try check("lambda_it_receiver_in_foreach",
        \\7
        \\8
        \\
    );
}

test "lambda_it_single_arg" {
    try check("lambda_it_single_arg",
        \\2
        \\4
        \\6
        \\
    );
}

test "lambda_it_unresolved" {
    try checkErr("lambda_it_unresolved", "unresolved reference `it`");
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

test "copy_into_named_args" {
    try check("copy_into_named_args",
        \\0,0,8,7,0,0
        \\0,0,8,7,0,0
        \\0,0,9,8,7,6
        \\0,0,8,7,0,0
        \\0,4,5,6,0
        \\null,b,c,null
        \\
    );
}

test "tailrec_member_receiver" {
    try check("tailrec_member_receiver",
        \\a
        \\3
        \\
    );
}

test "named_arg_member_over_extension" {
    try check("named_arg_member_over_extension",
        \\ints[3]
        \\ints[2]
        \\text[ell]
        \\
    );
}

// kotlinc-native 2.3.10 is the oracle: kotlinc-jvm rejects this overload
// pair under JVM erasure (platform declaration clash), the native compiler
// resolves it by the full declared type.
test "overload_generic_args" {
    try check("overload_generic_args",
        \\pick(List<String>)
        \\pick(List<Int>)
        \\pick(List<String>)
        \\pick(List<Int>)
        \\
    );
}

// kotlinc-native 2.3.10 is the oracle: kotlinc-jvm rejects this overload
// pair under JVM erasure (platform declaration clash), the native compiler
// resolves it by the full declared type.
test "overload_function_shapes" {
    try check("overload_function_shapes",
        \\call((String)->String)
        \\call((Int)->Int)
        \\
    );
}

test "overload_suspend_vs_plain" {
    try check("overload_suspend_vs_plain",
        \\take(plain)
        \\take(suspend)
        \\
    );
}

test "empty_container_declared_elem" {
    try check("empty_container_declared_elem",
        \\ext List<String>
        \\ext List<String>
        \\
    );
}

// A package member used by fully-qualified name with no `import` needs no
// import in Kotlin; the load gate harvests the qualified prefix so the
// gated sources load just as an import of it would.
test "qualified_unimported_ref" {
    try check("qualified_unimported_ref",
        \\7
        \\4.0
        \\5
        \\
    );
}

// A `with(x) { … }` subject exposes only `x`; its enclosing-instance tower
// is NOT in scope, so a bare call to a member of the subject's outer class
// is unresolved (kotlinc: `unresolved reference 'describe'`). The
// dispatch-receiver tower stays in scope (see
// `inner_member_calls_outer_member`); the difference is subject vs dispatch
// receiver.
test "with_subject_outer_member_call_rejected" {
    try checkErr("with_subject_outer_member_call_rejected", "describe");
}

// The positive companion: an inner-class method calling a bare member of
// its enclosing class resolves through the real dispatch-receiver `this`
// tower (`this@Inner` → `this@Outer`). Must keep working.
test "inner_member_calls_outer_member" {
    try check("inner_member_calls_outer_member",
        \\outer-describe
        \\
    );
}

// A user parameter named `this` (backticked, since `this` is a hard
// keyword) is an ordinary parameter, not a dispatch receiver, so a bare
// call in the function body is unresolved (kotlinc: `unresolved reference
// 'show'`).
test "backtick_this_param_not_receiver" {
    try checkErr("backtick_this_param_not_receiver", "show");
}

/// Run a multi-file program and assert it is rejected before it runs, the
/// rejection containing `needle`. Mirrors kotlinc's `unresolved reference`
/// for an unimported cross-package reference.
fn checkErrFiles(files: []const []const u8, needle: []const u8) !void {
    const a = arenaAllocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const res = try parity.runFilesWithPacks(a, io, files);
    switch (res) {
        .ok => |got| {
            std.debug.print("multi-file: expected rejection, ran with output:\n{s}\n", .{got});
            return error.ExpectedRejection;
        },
        .err => |m| {
            if (std.mem.indexOf(u8, m, needle) == null) {
                std.debug.print("multi-file: rejection `{s}` missing `{s}`\n", .{ m, needle });
                return error.WrongRejection;
            }
        },
    }
}

/// Run a multi-file program and assert its stdout.
fn checkFiles(files: []const []const u8, expected: []const u8) !void {
    const a = arenaAllocator();
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const res = try parity.runFilesWithPacks(a, io, files);
    switch (res) {
        .ok => |got| try std.testing.expectEqualStrings(expected, got),
        .err => |m| {
            std.debug.print("multi-file: klio error: {s}\n", .{m});
            return error.KlioRunFailed;
        },
    }
}

const T5_VALUE = CORPUS_DIR ++ "/tier5_value_ref";
const T5_LOOSE = CORPUS_DIR ++ "/tier5_loose_calls";

// An unimported cross-package value reference is unresolved exactly as
// kotlinc rejects it (kotlinc-jvm 2.3.21). A callable reference `::name`,
// a `::Ctor`, and a bare read of an unimported cross-package top-level
// property each report `unresolved reference`; before this they ran
// leniently (the function ran, the property's value printed, the
// constructor built).
test "tier5_value_ref_fn_callable_reference_rejected" {
    try checkErrFiles(&.{ T5_VALUE ++ "/lib.kt", T5_VALUE ++ "/app_fnref.kt" }, "unresolved reference `helper`");
}

test "tier5_value_ref_bare_property_read_rejected" {
    try checkErrFiles(&.{ T5_VALUE ++ "/lib.kt", T5_VALUE ++ "/app_bareread.kt" }, "unresolved reference `flag`");
}

test "tier5_value_ref_ctor_reference_rejected" {
    try checkErrFiles(&.{ T5_VALUE ++ "/lib.kt", T5_VALUE ++ "/app_ctorref.kt" }, "unresolved reference `Box`");
}

// Loose-shape calls (default-arg / vararg / default+trailing-lambda /
// vararg+trailing-lambda) to an unimported cross-package target are
// unresolved too — the heuristic could bind them only because the runtime
// member-redispatch path can also claim them, but no receiver is in scope
// here. kotlinc rejects all four; the vararg+trailing-lambda one even
// misrouted and crashed (`get_field 'entries' on kotlin.Int`) before.
test "tier5_loose_default_arg_call_rejected" {
    try checkErrFiles(&.{ T5_LOOSE ++ "/lib.kt", T5_LOOSE ++ "/app_default.kt" }, "unresolved reference `greet`");
}

test "tier5_loose_vararg_call_rejected" {
    try checkErrFiles(&.{ T5_LOOSE ++ "/lib.kt", T5_LOOSE ++ "/app_vararg.kt" }, "unresolved reference `sum`");
}

test "tier5_loose_default_plus_lambda_call_rejected" {
    try checkErrFiles(&.{ T5_LOOSE ++ "/lib.kt", T5_LOOSE ++ "/app_combo.kt" }, "unresolved reference `combo`");
}

test "tier5_loose_vararg_plus_lambda_call_rejected" {
    try checkErrFiles(&.{ T5_LOOSE ++ "/lib.kt", T5_LOOSE ++ "/app_vlam.kt" }, "unresolved reference `vlam`");
}

// Positive counterparts that MUST still resolve. An imported cross-package
// program references every shape with explicit imports; kotlinc compiles
// and runs it. The same shapes in a single same-package file resolve too.
test "tier5_value_ref_imported_resolves" {
    try checkFiles(&.{
        CORPUS_DIR ++ "/tier5_value_ref_positive/lib.kt",
        CORPUS_DIR ++ "/tier5_value_ref_positive/app_imported.kt",
    },
        \\helper-ran
        \\42
        \\3
        \\hi world
        \\6
        \\x
        \\3
        \\
    );
}

test "tier5_loose_same_package_resolves" {
    try checkFiles(&.{CORPUS_DIR ++ "/tier5_loose_calls_positive/samepkg.kt"},
        \\helper-ran
        \\42
        \\3
        \\hi world
        \\6
        \\x
        \\3
        \\
    );
}

// A loose-shape bare call inside a receiver context (`g.apply { greet() }`)
// must bind the runtime receiver's member even when a same-named top-level
// function is out of scope — the member-redispatch shape the tightening
// must NOT over-reject (kotlinc resolves it to the member).
test "tier5_loose_member_redispatch_resolves" {
    try checkFiles(&.{
        CORPUS_DIR ++ "/tier5_loose_calls_positive/mr_lib.kt",
        CORPUS_DIR ++ "/tier5_loose_calls_positive/mr_app.kt",
    },
        \\member-member
        \\
    );
}

// `++`/`--` write-back must reach the real binding for every lvalue shape,
// not a dead local. Regression: prefix/postfix on a top-level `var` mutated
// from a non-reader function dropped the write. All outputs match kotlinc.
test "incdec_toplevel_postinc" {
    try check("incdec_toplevel_postinc",
        \\2
        \\
    );
}

test "incdec_toplevel_preinc" {
    try check("incdec_toplevel_preinc",
        \\2
        \\
    );
}

test "incdec_toplevel_postdec" {
    try check("incdec_toplevel_postdec",
        \\3
        \\
    );
}

test "incdec_toplevel_predec" {
    try check("incdec_toplevel_predec",
        \\3
        \\
    );
}

test "incdec_member_bare" {
    try check("incdec_member_bare",
        \\2
        \\
    );
}

test "incdec_member_this" {
    try check("incdec_member_this",
        \\2
        \\
    );
}

test "incdec_captured_lambda" {
    try check("incdec_captured_lambda",
        \\2
        \\
    );
}

test "incdec_member_lambda_outer" {
    try check("incdec_member_lambda_outer",
        \\2
        \\
    );
}

test "incdec_postfix_expr_old" {
    try check("incdec_postfix_expr_old",
        \\5
        \\6
        \\
    );
}

test "incdec_prefix_expr_new" {
    try check("incdec_prefix_expr_new",
        \\6
        \\6
        \\
    );
}

test "incdec_index_array" {
    try check("incdec_index_array",
        \\3
        \\4
        \\
    );
}
