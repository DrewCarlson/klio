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

test "captured_write_shared_resolution" {
    try check("captured_write_shared_resolution",
        \\3
        \\5
        \\6
        \\17
        \\7
        \\5
        \\5
        \\extension:1
        \\
    );
}

test "static_operator_resolution" {
    try check("static_operator_resolution",
        \\nullable:1
        \\int:2
        \\string:qualified
        \\[1, 2, 3]
        \\string:inherited
        \\int:4
        \\number:4
        \\extension:shadow
        \\inner:receiver
        \\[3]
        \\extension:constructor
        \\21500
        \\
    );
}

test "qualified_type_parameter_collision" {
    try check("qualified_type_parameter_collision",
        \\extension:class
        \\extension:function
        \\derived
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

test "exception_inherited_tostring" {
    try check("exception_inherited_tostring",
        \\SpecificFailure: bad
        \\decorated DecoratedFailure: worse
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

test "iterator_builder_vs_extension" {
    try check("iterator_builder_vs_extension",
        \\1
        \\2
        \\9
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

test "when_string_subject" {
    try check("when_string_subject",
        \\star
        \\foobar
        \\foobar
        \\empty
        \\other:baz
        \\
    );
}

test "error_in_receiver_context" {
    try check("error_in_receiver_context",
        \\real-error
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

test "member_extension_shadows_stdlib" {
    try check("member_extension_shadows_stdlib",
        \\false
        \\true
        \\false
        \\member:x
        \\member:x
        \\top
        \\member:x
        \\
    );
}

test "source_body_extension_defaults" {
    try check("source_body_extension_defaults",
        \\abc
        \\missing
        \\abc
        \\
    );
}

test "local_extension_receiver_applicability" {
    try check("local_extension_receiver_applicability",
        \\true
        \\false
        \\
    );
}

test "explicit_type_arg_receiver_lambda" {
    try check("explicit_type_arg_receiver_lambda",
        \\Any
        \\nullable
        \\
    );
}

test "generic_local_extension" {
    try check("generic_local_extension",
        \\local
        \\
    );
}

test "local_extension_generic_argument_applicability" {
    try check("local_extension_generic_argument_applicability",
        \\outer
        \\
    );
}

test "local_extension_generic_applicability_matrix" {
    try check("local_extension_generic_applicability_matrix",
        \\local
        \\outer
        \\outer
        \\outer
        \\outer
        \\outer
        \\
    );
}

test "bare_local_extension_receiver_applicability" {
    try check("bare_local_extension_receiver_applicability",
        \\outer
        \\
    );
}

test "local_extension_bound_applicability" {
    try check("local_extension_bound_applicability",
        \\outer
        \\local
        \\
    );
}

test "generic_factory_return_extension" {
    try check("generic_factory_return_extension",
        \\0.0
        \\
    );
}

test "unsigned_array_sort_descending_range" {
    try check("unsigned_array_sort_descending_range",
        \\OK
        \\
    );
}

test "sequence_argument_extension_overload" {
    try check("sequence_argument_extension_overload",
        \\[1, 0, 1, 1, 2]
        \\
    );
}

test "static_operator_receiver_type" {
    try check("static_operator_receiver_type",
        \\[foo, bar, zoo, g]
        \\true
        \\[foo, bar, zoo, g]
        \\true
        \\
    );
}

test "subjectless_when_this_smart_cast" {
    try check("subjectless_when_this_smart_cast",
        \\member:2
        \\zero
        \\
    );
}

test "redundant_projection_static_applicability" {
    try check("redundant_projection_static_applicability",
        \\local
        \\
    );
}

test "qualified_alias_static_applicability" {
    try checkFiles(&.{
        CORPUS_DIR ++ "/qualified_alias_static_applicability/alpha.kt",
        CORPUS_DIR ++ "/qualified_alias_static_applicability/beta.kt",
        CORPUS_DIR ++ "/qualified_alias_static_applicability/app.kt",
    },
        \\outer
        \\
    );
}

test "member_factory_constructor_shadow" {
    try check("member_factory_constructor_shadow",
        \\Bar
        \\
    );
}

test "constructor_scope_import" {
    try checkFiles(&.{
        CORPUS_DIR ++ "/constructor_scope_import/lib.kt",
        CORPUS_DIR ++ "/constructor_scope_import/app.kt",
    },
        \\ctor
        \\
    );
}

test "constructor_scope_import_alias" {
    try checkFiles(&.{
        CORPUS_DIR ++ "/constructor_scope_import/lib.kt",
        CORPUS_DIR ++ "/constructor_scope_import/app_alias.kt",
    },
        \\ctor
        \\
    );
}

test "renamed_function_import" {
    try checkFiles(&.{
        CORPUS_DIR ++ "/renamed_function_import/lib.kt",
        CORPUS_DIR ++ "/renamed_function_import/app.kt",
    },
        \\extension:a:b
        \\plain:a:b:c
        \\inline:a:b:c:d
        \\x+y
        \\plain:r:s:t
        \\extension:u:v
        \\extension:w:x
        \\30
        \\
    );
}

test "constructor_identity_collision" {
    try checkFiles(&.{
        CORPUS_DIR ++ "/constructor_identity_collision/wrong.kt",
        CORPUS_DIR ++ "/constructor_identity_collision/app.kt",
    },
        \\ctor
        \\
    );
}

test "static_overload_evidence" {
    try check("static_overload_evidence",
        \\generic
        \\generic
        \\fixed
        \\
    );
}

test "unimported_object_member_extension" {
    try check("unimported_object_member_extension",
        \\true
        \\false
        \\true
        \\false
        \\true
        \\false
        \\false
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

// An empty container typed by its binding annotation (`val xs: List<String>
// = emptyList()`) binds the `List<String>.describe()` extension over the
// enclosing class's `describe()` member, matching kotlinc — the lowering
// reads the annotation's element head and stamps it where an explicit
// creation-site type argument would. The erased-generic-return shape
// (`fun <T> make(): List<T> = emptyList()`) is the documented residue:
// `T` carries no runtime element identity, so that one keeps on-demand
// dispatch.
test "empty_container_binding_elem" {
    try check("empty_container_binding_elem",
        \\ext List<String>
        \\ext Map<String, Int>
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

test "member_extension_foreign_field_shadow" {
    try check("member_extension_foreign_field_shadow",
        \\7
        \\
    );
}

test "imported_function_over_noncallable_member" {
    try check("imported_function_over_noncallable_member",
        \\1.0
        \\2.0
        \\
    );
}

// A user parameter named `this` (backticked, since `this` is a hard
// keyword) is an ordinary parameter, not a dispatch receiver, so a bare
// call in the function body is unresolved (kotlinc: `unresolved reference
// 'show'`).
test "capitalized_extension_fn" {
    try check("capitalized_extension_fn", "validator installed expectSuccess=true\n");
}

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

test "expect_actual_superclass_delegate" {
    try checkFiles(&.{
        CORPUS_DIR ++ "/expect_actual_superclass_delegate/common.kt",
        CORPUS_DIR ++ "/expect_actual_superclass_delegate/actual.kt",
    },
        \\reported 7
        \\reported 42
        \\boom
        \\
    );
}

test "infix_extension_over_inapplicable_intrinsic" {
    try check("infix_extension_over_inapplicable_intrinsic",
        \\3
        \\5
        \\
    );
}

test "imported_overload_in_captured_receiver" {
    try checkFiles(&.{
        CORPUS_DIR ++ "/imported_overload_in_captured_receiver/lib.kt",
        CORPUS_DIR ++ "/imported_overload_in_captured_receiver/app.kt",
    },
        \\short:1
        \\content
        \\
    );
}

test "imported_specific_overload_after_generic" {
    try checkFiles(&.{
        CORPUS_DIR ++ "/imported_specific_overload_after_generic/lib.kt",
        CORPUS_DIR ++ "/imported_specific_overload_after_generic/app.kt",
    },
        \\generic
        \\int
        \\
    );
}

test "receiver_lambda_invoke" {
    try check("receiver_lambda_invoke",
        \\n=5 tag=hi
        \\n=9 tag=yo
        \\n=3 tag=x
        \\n=1 tag=k b=42
        \\5
        \\7
        \\17
        \\7
        \\
    );
}

test "overloaded_nullable_smartcast" {
    try check("overloaded_nullable_smartcast",
        \\true
        \\true
        \\true
        \\
    );
}

test "reified_inline_overload_delegation" {
    try check("reified_inline_overload_delegation",
        \\true
        \\false
        \\
    );
}

test "member_receiver_lambda_over_extension" {
    try check("member_receiver_lambda_over_extension",
        \\payload
        \\
    );
}

test "bare_write_inline_receiver_lambda" {
    try check("bare_write_inline_receiver_lambda",
        \\applied
        \\ran
        \\lbl!
        \\withed
        \\explicit
        \\also
        \\global
        \\
    );
}

test "bare_write_receiver_lacks_property" {
    try check("bare_write_receiver_lacks_property",
        \\outer
        \\2
        \\
    );
}

test "bare_write_var_declared_later" {
    try check("bare_write_var_declared_later",
        \\applied
        \\run!
        \\through-run
        \\through-with
        \\captured
        \\top-level
        \\
    );
}

test "catch_param_static_type" {
    try check("catch_param_static_type",
        \\cause=Root cause
        \\renders-cause=true
        \\renders-suppressed=true
        \\renders-outer-suppressed=true
        \\suppressed-count=1
        \\boom:x
        \\
    );
}

test "smart_cast_through_and_chain" {
    try check("smart_cast_through_and_chain",
        \\circle
        \\circle
        \\circle
        \\circle/circle
        \\none
        \\none
        \\true
        \\false
        \\true
        \\c
        \\b
        \\
    );
}

test "bare_member_call_on_captured_receiver" {
    try check("bare_member_call_on_captured_receiver",
        \\n=5
        \\n=6
        \\n=6
        \\n=26
        \\n=126
        \\252/n=126
        \\
    );
}

test "redeclared_interface_slot_reaches_the_inherited_body" {
    try check("redeclared_interface_slot_reaches_the_inherited_body",
        \\[a, b]
        \\[b, a]
        \\[b]
        \\
    );
}

test "bare_extension_call_in_a_receiver_body" {
    try check("bare_extension_call_in_a_receiver_body",
        \\base
        \\base
        \\
    );
}

test "receiver_typed_through_its_parameter_bound" {
    try check("receiver_typed_through_its_parameter_bound",
        \\base
        \\1
        \\2
        \\
    );
}

test "generic_argument_from_every_constraint" {
    try check("generic_argument_from_every_constraint",
        \\base
        \\base
        \\base
        \\base
        \\true
        \\false
        \\
    );
}

test "generic_receiver_through_its_initializer" {
    try check("generic_receiver_through_its_initializer",
        \\base
        \\base
        \\derived
        \\base
        \\base
        \\
    );
}

test "property_typed_from_a_ctor_parameter" {
    try check("property_typed_from_a_ctor_parameter",
        \\base
        \\derived
        \\
    );
}

test "property_typed_from_a_factory_call" {
    try check("property_typed_from_a_factory_call",
        \\base
        \\derived
        \\derived
        \\
    );
}

test "null_check_through_and_chain" {
    try check("null_check_through_and_chain",
        \\member
        \\member
        \\member
        \\member
        \\none
        \\nullable-ext
        \\nullable-ext
        \\
    );
}

test "alias_local_keeps_its_source_type" {
    try check("alias_local_keeps_its_source_type",
        \\base
        \\base
        \\base
        \\derived
        \\
    );
}

test "receiver_typed_from_an_operator" {
    try check("receiver_typed_from_an_operator",
        \\base
        \\base
        \\base
        \\base
        \\derived
        \\
    );
}

test "bare_name_inside_an_extension_body" {
    try check("bare_name_inside_an_extension_body",
        \\base
        \\derived
        \\base
        \\
    );
}

test "receiver_typed_from_a_property_read" {
    try check("receiver_typed_from_a_property_read",
        \\base
        \\derived
        \\base
        \\derived
        \\
    );
}

test "local_named_after_its_own_initializer" {
    try check("local_named_after_its_own_initializer",
        \\base
        \\derived
        \\abc
        \\lambda
        \\
    );
}

test "data_class_components_are_declared_members" {
    try check("data_class_components_are_declared_members",
        \\a/1
        \\a/1
        \\6/t
        \\200
        \\1/200
        \\x=1
        \\x:1
        \\Entry(key=a, num=1)
        \\true
        \\Entry(key=a, num=3)
        \\
    );
}

test "loop_variable_typed_from_element" {
    try check("loop_variable_typed_from_element",
        \\item:a;item:b;
        \\item:c
        \\6
        \\item:a;item:b;pqr
        \\1=one
        \\2=two
        \\
    );
}

test "bare_call_lends_its_return_type" {
    try check("bare_call_lends_its_return_type",
        \\a/b
        \\3
        \\3
        \\xy
        \\
    );
}

test "local_typed_from_its_initializer" {
    try check("local_typed_from_its_initializer",
        \\box:a
        \\box:a!
        \\box:made
        \\2
        \\20
        \\30
        \\box:a?
        \\
    );
}

test "sequence_sum_of_infers_its_kind" {
    try check("sequence_sum_of_infers_its_kind",
        \\7
        \\7
        \\7
        \\7
        \\7
        \\7
        \\3.5
        \\7000000000
        \\
    );
}

test "grouping_through_its_own_protocol" {
    try check("grouping_through_its_own_protocol",
        \\{b=2, f=2, z=1}
        \\{b=10, f=7, z=3}
        \\{b=biscuit, f=flea, z=zoo}
        \\{b=2, f=2, z=1}
        \\{b=10, f=7, z=3}
        \\
    );
}

test "member_header_binds_its_own_owner" {
    try check("member_header_binds_its_own_owner",
        \\true
        \\false
        \\false
        \\true
        \\false
        \\true
        \\true
        \\true
        \\false
        \\true
        \\true
        \\true
        \\
    );
}

test "host_backed_receiver_virtual_slot" {
    try check("host_backed_receiver_virtual_slot",
        \\10,20,30,
        \\2,1,0,
        \\a1true
        \\w|x|y
        \\3
        \\43
        \\7
        \\true
        \\
    );
}

test "safe_call_binds_on_non_null_branch" {
    try check("safe_call_binds_on_non_null_branch",
        \\node:a!
        \\null
        \\evaluations=2
        \\inner:a
        \\null
        \\evaluations=4
        \\node:z?
        \\
    );
}

test "override_param_type_from_enclosing_scope" {
    try check("override_param_type_from_enclosing_scope",
        \\tagged-empty
        \\tagged-kept
        \\tagged-empty
        \\tagged-empty
        \\
    );
}

test "init_lambda_encloses_instance" {
    try check("init_lambda_encloses_instance",
        \\T/prop T/init
        \\
    );
}

test "receiver_scope_zero_arg_println" {
    try check("receiver_scope_zero_arg_println",
        \\a
        \\b
        \\
    );
}

test "getter_lambda_param_shape" {
    try check("getter_lambda_param_shape",
        \\got:x
        \\
    );
}

test "bare_call_through_closure_subject" {
    try check("bare_call_through_closure_subject",
        \\v1
        \\v2
        \\v3
        \\
    );
}

test "local_extension_fbounded_param" {
    try check("local_extension_fbounded_param",
        \\5
        \\fig
        \\
    );
}

test "iterator_member_global_arity" {
    try check("iterator_member_global_arity",
        \\4
        \\9
        \\
    );
}

test "vararg_before_defaulted_positional" {
    try check("vararg_before_defaulted_positional",
        \\A [1,2,3] end
        \\B [1] end
        \\C [] end
        \\D [4,5] z
        \\E [7,8,9] end
        \\
    );
}

test "range_in_range_user_operator" {
    try check("range_in_range_user_operator",
        \\true
        \\false
        \\true
        \\true
        \\false
        \\
    );
}

test "finally_runs_on_return_leaf_shape" {
    try check("finally_runs_on_return_leaf_shape",
        \\fin-a
        \\1
        \\fin-b
        \\2
        \\
    );
}

test "throwable_suppressed_user_instance" {
    try check("throwable_suppressed_user_instance",
        \\0
        \\2
        \\[side, side2]
        \\2
        \\
    );
}

test "tower_outer_receiver_extension" {
    try check("tower_outer_receiver_extension",
        \\outer-extension:a
        \\outer-extension:b
        \\
    );
}

test "bound_receiver_bare_iterator" {
    try check("bound_receiver_bare_iterator",
        \\3
        \\
    );
}

test "local_fn_default_beats_stdlib_sibling" {
    try check("local_fn_default_beats_stdlib_sibling",
        \\local 1.5 0.5 null
        \\local 1.5 0.5 null
        \\local 2.5 0.5 3.0
        \\
    );
}

test "anon_object_outer_prop_iterator" {
    try check("anon_object_outer_prop_iterator",
        \\6
        \\a-b
        \\
    );
}

test "bounded_prop_minus_list" {
    try check("bounded_prop_minus_list",
        \\[bar]
        \\true
        \\[bar]
        \\true
        \\1
        \\
    );
}

test "fn_bound_receiver_ext_commit" {
    try check("fn_bound_receiver_ext_commit",
        \\2
        \\
    );
}

test "bound_args_lambda_param" {
    try check("bound_args_lambda_param",
        \\2
        \\[FOO, BAR, FIZZ]
        \\
    );
}

test "bound_args_lambda_replay" {
    try check("bound_args_lambda_replay",
        \\cs,cs
        \\2
        \\
    );
}

test "trailing_callable_gap_defaults" {
    try check("trailing_callable_gap_defaults",
        \\ext:fn
        \\ext:null
        \\member3
        \\
    );
}

test "type_overload_runtime_pick" {
    try check("type_overload_runtime_pick",
        \\meta:7 d:2
        \\bool:true w:1.5
        \\
    );
}

test "generic_arg_vs_any_param" {
    try check("generic_arg_vs_any_param",
        \\keyed:x
        \\plain:y
        \\
    );
}

test "member_overload_receiver_instantiation" {
    try check("member_overload_receiver_instantiation",
        \\one
        \\list
        \\
    );
}

test "plus_element_inference" {
    try check("plus_element_inference",
        \\[[s], [a]]
        \\[[s], [a]]
        \\[[s], [a]]
        \\
    );
}

test "windowed_trailing_transform" {
    try check("windowed_trailing_transform",
        \\[01, 34]
        \\[0, 1]
        \\true
        \\true
        \\ok
        \\
    );
}

test "jit_char_tag_rebox" {
    try check("jit_char_tag_rebox",
        \\a
        \\b
        \\a
        \\b
        \\
    );
}

test "and_chain_smartcast" {
    try check("and_chain_smartcast",
        \\true
        \\false
        \\true
        \\false
        \\
    );
}

test "nested_it_shadow_local_ext" {
    try check("nested_it_shadow_local_ext",
        \\[, abc, sort]
        \\[sort, abc, ]
        \\[abc, sort, ]
        \\true
        \\false
        \\
    );
}

test "fn_type_ext_private_inline" {
    try check("fn_type_ext_private_inline",
        \\ran alpha -> 42
        \\ran beta -> beta-value
        \\member runIt(direct)
        \\
    );
}

test "factory_lambda_local_star" {
    try check("factory_lambda_local_star",
        \\4
        \\A
        \\7
        \\
    );
}

test "ext_body_bare_iterator_star" {
    try check("ext_body_bare_iterator_star",
        \\3
        \\b
        \\null
        \\
    );
}

test "toplevel_prop_bare_receiver" {
    try check("toplevel_prop_bare_receiver",
        \\hello, klio
        \\42
        \\hello, again
        \\
    );
}

test "sequence_scope_outer_iterator" {
    try check("sequence_scope_outer_iterator",
        \\[1, 3, 5]
        \\
    );
}

test "interface_prop_receiver_iterator" {
    try check("interface_prop_receiver_iterator",
        \\3
        \\
    );
}

test "ext_prop_receiver_typed_read" {
    try check("ext_prop_receiver_typed_read",
        \\5
        \\
    );
}

test "lock_member_binding_spliced" {
    try check("lock_member_binding_spliced",
        \\other=false
        \\reacquired=true
        \\
    );
}

test "setter_value_param_typed" {
    try check("setter_value_param_typed",
        \\6
        \\HI
        \\bad 0
        \\
    );
}

test "ext_prop_type_bare_read" {
    try check("ext_prop_type_bare_read",
        \\n=3 last=2 total=12
        \\r=0..1
        \\
    );
}

test "unbound_ref_companion_receiver" {
    try check("unbound_ref_companion_receiver",
        \\[0, 1, 2, 3, 4]
        \\10
        \\[1, 2]
        \\
    );
}

test "splice_hygiene_caller_members" {
    try check("splice_hygiene_caller_members",
        \\[6, 7]
        \\400
        \\17
        \\[[s], [a]]
        \\
    );
}

test "splice_bounded_type_param_receiver" {
    try check("splice_bounded_type_param_receiver",
        \\[a, b, c]
        \\[(1, a)]
        \\[1, 2]
        \\[3]
        \\
    );
}

test "exit_guard_negated_is_narrows_overload" {
    try check("exit_guard_negated_is_narrows_overload",
        \\18
        \\5
        \\
    );
}

test "result_host_render_custom_tostring" {
    try check("result_host_render_custom_tostring",
        \\Failure(CustomException: F)
        \\tpl: Failure(CustomException: F)
        \\Failure(CustomException: F)
        \\true
        \\CustomException: F
        \\Success(OK)
        \\Failure(CustomException: G)
        \\
    );
}

test "inherited_overload_beats_own_predicate" {
    try check("inherited_overload_beats_own_predicate",
        \\[0, 1, 3, 5]
        \\[0, 1, 3]
        \\
    );
}

test "invoke_convention_peer_vararg_member" {
    try check("invoke_convention_peer_vararg_member",
        \\[a, b]
        \\
    );
}

test "jit_char_append_tag" {
    try check("jit_char_append_tag",
        \\ABCDEFGHIJKLMNOPQRST
        \\ABCDEFGH
        \\ABCDEFGH
        \\ABCD
        \\ABC
        \\ABCDEFGHIJKLMNOPQRSTUVWX
        \\
    );
}

test "tower_local_extension_label" {
    try check("tower_local_extension_label",
        \\top-ext:z
        \\w
        \\
    );
}

test "reified_from_lambda_annotation" {
    try check("reified_from_lambda_annotation",
        \\is
        \\no
        \\plain:5
        \\is:HI
        \\no
        \\is
        \\
    );
}

test "delegated_member_named_args_pin" {
    try check("delegated_member_named_args_pin",
        \\a:7@1.0
        \\b:0@2.5
        \\
    );
}

test "flow_builder_object_identity" {
    try check("flow_builder_object_identity",
        \\d3
        \\d4
        \\w7
        \\w1
        \\a5
        \\a6
        \\
    );
}

test "select_receive_beats_timeout" {
    try check("select_receive_beats_timeout",
        \\got 99
        \\
    );
}

test "primitive_bit_members" {
    try check("primitive_bit_members",
        \\89 -1234567 -1234656 1234566
        \\-9876536 -154321 536716591
        \\-9876536 -154321 536716591
        \\-2147483648 -1 1
        \\33029 -1234567824387 -1234567857416 1234567890122
        \\-39506172483936 -38580246567 576460713723176921
        \\-79012344967872 -19290123284 288230356861588460
        \\-1912276171 -1234567 14
        \\1073741824 -1073741824 4611686018427387904
        \\
    );
}

test "site_memo_null_field" {
    try check("site_memo_null_field",
        \\null
        \\null
        \\threw: lateinit property late has not been initialized
        \\set
        \\true
        \\
    );
}

test "platform_collection_factories" {
    try check("platform_collection_factories",
        \\[1, 2, 3]
        \\{1=a, 2=b}
        \\{x=1}
        \\
    );
}

test "numeric_promotion_receiver" {
    try check("numeric_promotion_receiver",
        \\256
        \\344
        \\8
        \\450
        \\5
        \\0
        \\
    );
}

test "nullable_receiver_member" {
    try check("nullable_receiver_member",
        \\node:a
        \\none
        \\4
        \\-1
        \\XY
        \\-
        \\
    );
}

test "binary_arg_promotion" {
    try check("binary_arg_promotion",
        \\2,3,4
        \\2,4,6
        \\false,true,true
        \\5
        \\1
        \\4
        \\
    );
}

test "range_arg_element_type" {
    try check("range_arg_element_type",
        \\5
        \\101
        \\1
        \\6
        \\xyz
        \\
    );
}

test "unary_arg_lambda_param" {
    try check("unary_arg_lambda_param",
        \\false,true,false
        \\-3,4,-5
        \\-7
        \\5
        \\
    );
}

test "postfix_arg_lambda_param" {
    try check("postfix_arg_lambda_param",
        \\7
        \\48
        \\5/6
        \\9/1
        \\
    );
}

test "local_type_survives_init_record" {
    try check("local_type_survives_init_record",
        \\66
        \\6
        \\BC
        \\3
        \\
    );
}

test "operator_member_return" {
    try check("operator_member_return",
        \\500
        \\1000
        \\1500
        \\5
        \\
    );
}

test "indexed_read_builtin_prop" {
    try check("indexed_read_builtin_prop",
        \\294
        \\2
        \\120
        \\105
        \\
    );
}

test "class_prop_literal_type" {
    try check("class_prop_literal_type",
        \\ROW114
        \\ROW214
        \\3
        \\
    );
}

test "thread_declared_handle" {
    try check("thread_declared_handle",
        \\worker
        \\false
        \\true
        \\5
        \\
    );
}

test "bare_member_call_return" {
    try check("bare_member_call_return",
        \\AB,CD|2
        \\[3, 4]
        \\
    );
}

test "receiver_lambda_member_read" {
    try check("receiver_lambda_member_read",
        \\cell7
        \\1,2,3|6
        \\
    );
}

test "top_level_prop_literal_type" {
    try check("top_level_prop_literal_type",
        \\10000000000
        \\2
        \\KLIO:
        \\4
        \\
    );
}

test "chained_member_return" {
    try check("chained_member_return",
        \\abcd
        \\5
        \\18
        \\134
        \\box6
        \\3
        \\a-b-c
        \\
    );
}

test "indexed_splice_lambda_param" {
    try check("indexed_splice_lambda_param",
        \\1
        \\1
        \\1
        \\1
        \\1
        \\1
        \\0
        \\
    );
}

test "string_companion_format" {
    try check("string_companion_format",
        \\a/3/1.50
        \\x=7
        \\
    );
}

test "nested_inline_lambda_same_param_name" {
    try check("nested_inline_lambda_same_param_name",
        \\190
        \\600
        \\
    );
}

test "for_over_progression_element_type" {
    try check("for_over_progression_element_type",
        \\15
        \\abcde
        \\4
        \\6420
        \\
    );
}

test "splice_param_shadows_its_own_source" {
    try check("splice_param_shadows_its_own_source",
        \\0a1b2c
        \\x0y1
        \\
    );
}

test "safe_call_scope_function_typing" {
    try check("safe_call_scope_function_typing",
        \\[cq]2
        \\none
        \\[d]
        \\none
        \\[e]
        \\none
        \\BC
        \\
    );
}

test "ctor_thunk_param_types" {
    try check("ctor_thunk_param_types",
        \\-6
        \\-111
        \\ab/AB
        \\
    );
}

test "safe_chain_and_nullable_extension" {
    try check("safe_chain_and_nullable_extension",
        \\8
        \\-1
        \\-1
        \\16
        \\true
        \\false
        \\true
        \\true
        \\x
        \\null
        \\
    );
}

test "identity_extension_return" {
    try check("identity_extension_return",
        \\ab1
        \\n=7
        \\n=2
        \\n=3
        \\
    );
}

test "local_fun_return_type" {
    try check("local_fun_return_type",
        \\4
        \\[q]
        \\
    );
}

test "ctor_overload_specificity" {
    try check("ctor_overload_specificity",
        \\i1,sx,circle,shape,shape
        \\circle,shape,shape
        \\
    );
}

test "member_type_param_beats_extension" {
    try check("member_type_param_beats_extension",
        \\1/-1/2
        \\2,true,2
        \\
    );
}

test "member_collection_beats_iterable_extension" {
    try check("member_collection_beats_iterable_extension",
        \\1,2,3,4
        \\true
        \\
        \\a,b,c,d,e
        \\
    );
}

test "universal_any_extension_binding" {
    try check("universal_any_extension_binding",
        \\N(a),N(b)
        \\x,null
        \\N(q)
        \\null
        \\true
        \\
    );
}

test "type_parameter_erases_to_bound" {
    try check("type_parameter_erases_to_bound",
        \\1/2
        \\true
        \\3,4
        \\x,null
        \\true
        \\3
        \\k=9
        \\
    );
}

test "star_projection_element_type" {
    try check("star_projection_element_type",
        \\true
        \\1;a;null;
        \\2
        \\
    );
}

test "generic_property_type_arguments" {
    try check("generic_property_type_arguments",
        \\<a>
        \\<a><b>
        \\<a>,<b>
        \\<c>
        \\<t>
        \\
    );
}

test "generic_property_read_substitution" {
    try check("generic_property_read_substitution",
        \\<c><d>
        \\<c>,<d>
        \\1,2
        \\<x><y>
        \\
    );
}

test "generic_member_return_substitution" {
    try check("generic_member_return_substitution",
        \\<a>
        \\<c>
        \\<a>
        \\<c>
        \\<b>
        \\-
        \\
    );
}

test "splice_receiver_survives_delegation" {
    try check("splice_receiver_survives_delegation",
        \\<c>,<d>
        \\<a>,<b>
        \\1,2
        \\<c>,<d>
        \\
    );
}

test "unsigned_arithmetic_promotion" {
    try check("unsigned_arithmetic_promotion",
        \\9,99,103,8,10,30,5
        \\0..3
        \\4294967295..0
        \\
    );
}

test "nested_class_property_type" {
    try check("nested_class_property_type",
        \\-/2/4/mun/t
        \\:/1/2/mun/f
        \\
    );
}

test "constructor_scope_param_types" {
    try check("constructor_scope_param_types",
        \\3<a>|
        \\1<b>|<c>7
        \\
    );
}

test "nested_qualified_constructor" {
    try check("nested_qualified_constructor",
        \\i1/d2
        \\
    );
}

test "char_intrinsic_direct_dispatch" {
    try check("char_intrinsic_direct_dispatch",
        \\1194
        \\120/121/122
        \\Ab
        \\535
        \\-1,1,0
        \\
    );
}

test "unsigned_scalar_intrinsic_dispatch" {
    try check("unsigned_scalar_intrinsic_dispatch",
        \\1
        \\{1=1, 2=2}
        \\255
        \\7
        \\97
        \\3
        \\true
        \\9223372036854775807
        \\
    );
}

test "overload_set_lambda_discriminated" {
    try check("overload_set_lambda_discriminated",
        \\10 12
        \\base/derived/base/derived
        \\int/string/int/string
        \\
    );
}

test "char_compare_to_code_difference" {
    try check("char_compare_to_code_difference",
        \\-2
        \\2
        \\0
        \\-32
        \\-1
        \\1
        \\-1
        \\[a, b, c]
        \\true
        \\true
        \\
    );
}

test "string_compare_to_difference" {
    try check("string_compare_to_difference",
        \\-2
        \\2
        \\0
        \\-2
        \\2
        \\-3
        \\-32
        \\0
        \\0
        \\[apple, fig, pear]
        \\true
        \\
    );
}

test "collection_slot_direct_intrinsic" {
    try check("collection_slot_direct_intrinsic",
        \\[7, 1, 2, 4]
        \\4
        \\false
        \\true
        \\2
        \\[7, 1]
        \\[7, 1, 2, 4, 5, 6]
        \\[7, 1, 2, 4, 6]
        \\[a, c]
        \\false
        \\2
        \\{y=2}
        \\1
        \\false
        \\true
        \\6
        \\1
        \\1
        \\false
        \\
    );
}

test "null_literal_widens_type_argument" {
    try check("null_literal_widens_type_argument",
        \\[f, o, o, b, a, r]
        \\[foo, bar]
        \\3
        \\[a]
        \\2
        \\[b]
        \\[1]
        \\2
        \\2
        \\
    );
}
