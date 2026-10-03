//! Pinned parity-corpus fixtures: each test runs one
//! `tests/fixtures/parity_corpus/*.kt` program through the harness binary and
//! asserts kotlinc's output, so the corpus gates without a kotlinc install.

const std = @import("std");
const klio_child = @import("klio_child");

const CORPUS_DIR = "tests/fixtures/parity_corpus";

// One arena for the file's runs, reset per program.
var shared_arena: ?std.heap.ArenaAllocator = null;

fn arenaAllocator() std.mem.Allocator {
    if (shared_arena) |*a| {
        _ = a.reset(.retain_capacity);
    } else {
        shared_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
    return shared_arena.?.allocator();
}

fn check(stem: []const u8, expected: []const u8) !void {
    const a = arenaAllocator();

    const file = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ CORPUS_DIR, stem });
    const res = try klio_child.runFile(a, file);
    switch (res) {
        .ok => |got| try std.testing.expectEqualStrings(expected, got),
        .err => |m| {
            std.debug.print("parity corpus {s}: klio error: {s}\n", .{ stem, m });
            return error.KlioRunFailed;
        },
    }
}

/// Assert `<stem>.kt` is rejected before it runs, with `needle` in the message.
fn checkErr(stem: []const u8, needle: []const u8) !void {
    const a = arenaAllocator();

    const file = try std.fmt.allocPrint(a, "{s}/{s}.kt", .{ CORPUS_DIR, stem });
    const res = try klio_child.runFile(a, file);
    switch (res) {
        .ok => |got| {
            std.debug.print("parity corpus {s}: expected rejection, ran with output:\n{s}\n", .{ stem, got });
            return error.ExpectedRejection;
        },
        .err => |m| {
            if (std.mem.find(u8, m, needle) == null) {
                std.debug.print("parity corpus {s}: rejection `{s}` missing `{s}`\n", .{ stem, m, needle });
                return error.WrongRejection;
            }
        },
    }
}

test "fn_param_member_vs_string_extension" {
    try check("fn_param_member_vs_string_extension",
        \\http://a/
        \\http://b/
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

test "charsequence_content_equals_custom" {
    try check("charsequence_content_equals_custom",
        \\true
        \\true
        \\true
        \\true
        \\false
        \\false
        \\true
        \\false
        \\false
        \\reads after a first-character mismatch: 1
        \\false
        \\false
        \\
    );
}

test "stringbuilder_range_custom_charsequence" {
    try check("stringbuilder_range_custom_charsequence",
        \\[el] reads=2
        \\[]
        \\[axyb]
        \\[ell]
        \\[!tail]
        \\out of range
        \\
    );
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

test "companion_initializes_once" {
    try check("companion_initializes_once",
        \\start Counted.Companion | sum 499500 made 1
        \\ExceptionInInitializerError: companion failed
        \\NoClassDefFoundError: Could not initialize object Broken.Companion
        \\NoClassDefFoundError: Could not initialize object Broken.Companion
        \\SelfMaking.Companion(-1) | [1, 2, 3] -1
        \\before Base.Companion mids Bottom.Companion
        \\[10/1/100, 20/2/200, 30/3/300]
        \\[1/1/2/b1, 2/2/3/b2, 3/3/4/b3]
        \\-5997000
        \\[e1, e2, e3, true]
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
    const res = try klio_child.runFiles(a, &.{
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
    const res = try klio_child.runFiles(a, &.{
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
    const res = try klio_child.runFiles(a, &.{
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

test "fused_throw_catch" {
    try check("fused_throw_catch",
        \\ok=15
        \\caught=Invalid radix: 37
        \\failed=true
        \\
    );
}

test "fused_member_ext_owner" {
    try check("fused_member_ext_owner",
        \\PRESENT,OPTIONAL|2|h:ABSENT=false
        \\PRESENT,OPTIONAL|2|k:ABSENT=false
        \\
    );
}

test "fused_private_companion_ext" {
    try check("fused_private_companion_ext",
        \\-2147483648|-9223372036854775808|true|true
        \\
    );
}

test "fused_erased_cast" {
    try check("fused_erased_cast",
        \\42
        \\15
        \\
    );
}

test "splice_hygiene_shadow" {
    try check("splice_hygiene_shadow",
        \\member=6
        \\member=11
        \\ext=18
        \\signed=101
        \\plain=1
        \\tail=1y2z
        \\
    );
}

test "wide_infix_chain" {
    try check("wide_infix_chain",
        \\wide=20
        \\wide=20
        \\
    );
}

test "member_extension_owner_memo" {
    try check("member_extension_owner_memo",
        \\A7 bB7 A7 bB7 A7 bB7
        \\A7 bB7
        \\
    );
}

test "short_uppercase_user_type" {
    try check("short_uppercase_user_type",
        \\CFc
        \\
    );
}

test "member_extension_receiver_tower" {
    try check("member_extension_receiver_tower",
        \\sized:coord
        \\branch[leaf(w)]
        \\scope
        \\
    );
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

// `arrayOf` needs the element class at run time.
test "generic_factory_return_extension" {
    try checkErr("generic_factory_return_extension", "Cannot use 'T' as reified type parameter. Use a class instead.");
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

test "file_private_collision" {
    try checkFiles(&.{
        "examples/file_private_collision/alpha.kt",
        "examples/file_private_collision/beta.kt",
        "examples/file_private_collision/main.kt",
    },
        \\alpha:A#1
        \\alpha:A#2
        \\alpha:A#3
        \\alpha:A#4
        \\beta:B#1
        \\beta:B#2
        \\beta:B#3
        \\beta:B#4
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

// A superclass named through a star import is the imported package's class,
// even when a later file declares a public namesake with other fields.
test "supertype_star_import_namesake" {
    try checkFiles(&.{
        CORPUS_DIR ++ "/supertype_star_import_namesake/app.kt",
        CORPUS_DIR ++ "/supertype_star_import_namesake/events.kt",
        CORPUS_DIR ++ "/supertype_star_import_namesake/linked.kt",
    },
        \\linked:linked
        \\7
        \\true
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

// kotlinc-native is the oracle: kotlinc-jvm rejects this pair as a platform
// declaration clash under JVM erasure.
test "overload_generic_args" {
    try check("overload_generic_args",
        \\pick(List<String>)
        \\pick(List<Int>)
        \\pick(List<String>)
        \\pick(List<Int>)
        \\
    );
}

// kotlinc-native is the oracle: kotlinc-jvm rejects this pair as a platform
// declaration clash under JVM erasure.
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

// An empty container takes its element type from the binding annotation, so
// `val xs: List<String> = emptyList()` binds the `List<String>` extension over
// the enclosing member. An erased generic return keeps on-demand dispatch.
test "empty_container_binding_elem" {
    try check("empty_container_binding_elem",
        \\ext List<String>
        \\ext Map<String, Int>
        \\
    );
}

// Kotlin needs no `import` for a fully-qualified name; the gate harvests the
// qualified prefix instead.
test "qualified_unimported_ref" {
    try check("qualified_unimported_ref",
        \\7
        \\4.0
        \\5
        \\
    );
}

// A `with(x)` subject exposes only `x`, not its enclosing-instance tower,
// unlike a dispatch receiver.
test "with_subject_outer_member_call_rejected" {
    try checkErr("with_subject_outer_member_call_rejected", "describe");
}

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

// A backticked `this` parameter is ordinary, not a dispatch receiver.
test "capitalized_extension_fn" {
    try check("capitalized_extension_fn", "validator installed expectSuccess=true\n");
}

test "backtick_this_param_not_receiver" {
    try checkErr("backtick_this_param_not_receiver", "show");
}

/// Assert a multi-file program is rejected, with `needle` in the message.
fn checkErrFiles(files: []const []const u8, needle: []const u8) !void {
    const a = arenaAllocator();
    const res = try klio_child.runFiles(a, files);
    switch (res) {
        .ok => |got| {
            std.debug.print("multi-file: expected rejection, ran with output:\n{s}\n", .{got});
            return error.ExpectedRejection;
        },
        .err => |m| {
            if (std.mem.find(u8, m, needle) == null) {
                std.debug.print("multi-file: rejection `{s}` missing `{s}`\n", .{ m, needle });
                return error.WrongRejection;
            }
        },
    }
}

fn checkFiles(files: []const []const u8, expected: []const u8) !void {
    const a = arenaAllocator();
    const res = try klio_child.runFiles(a, files);
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

// An unimported cross-package reference is unresolved in every form: `::name`,
// `::Ctor`, and a bare read of a top-level property.
test "tier5_value_ref_fn_callable_reference_rejected" {
    try checkErrFiles(&.{ T5_VALUE ++ "/lib.kt", T5_VALUE ++ "/app_fnref.kt" }, "unresolved reference `helper`");
}

test "tier5_value_ref_bare_property_read_rejected" {
    try checkErrFiles(&.{ T5_VALUE ++ "/lib.kt", T5_VALUE ++ "/app_bareread.kt" }, "unresolved reference `flag`");
}

test "tier5_value_ref_ctor_reference_rejected" {
    try checkErrFiles(&.{ T5_VALUE ++ "/lib.kt", T5_VALUE ++ "/app_ctorref.kt" }, "unresolved reference `Box`");
}

// Loose shapes are unresolved too: only member redispatch could claim them,
// and no receiver is in scope.
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

// The bound those rejections must not cross: inside a receiver context a
// loose-shape bare call still binds the runtime receiver's member.
test "tier5_loose_member_redispatch_resolves" {
    try checkFiles(&.{
        CORPUS_DIR ++ "/tier5_loose_calls_positive/mr_lib.kt",
        CORPUS_DIR ++ "/tier5_loose_calls_positive/mr_app.kt",
    },
        \\member-member
        \\
    );
}

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
        \\1/2/200
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
        \\[[s], a]
        \\[[s], a]
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
        \\-1
        \\1
        \\0
        \\-1
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

test "overload_tied_on_lambda_return" {
    try check("overload_tied_on_lambda_return",
        \\[f, o, b, a, r]
        \\[f, o, b, a, r]
        \\[f, o, o, b, a, r]
        \\[f, o, o, b, a, r]
        \\
    );
}

test "index_set_fast_path" {
    try check("index_set_fast_path",
        \\2
        \\[1, 9, 3]
        \\7
        \\[7, 42, 3]
        \\threw-uoe
        \\threw-ioobe
        \\t
        \\é
        \\
    );
}

test "bare_call_return_typing" {
    try check("bare_call_return_typing",
        \\3
        \\S4
        \\
    );
}

test "nested_expected_comparator_chain" {
    try check("nested_expected_comparator_chain",
        \\[null, , a]
        \\[a, , null]
        \\[null, a, ]
        \\[abc, sort, ]
        \\
    );
}

test "bare_tp_receiver_lambda_invoke" {
    // `item.getter()` with `getter: T.() -> P` in scope commits the invoke
    // protocol; a runtime class's same-named member must not win.
    try check("bare_tp_receiver_lambda_invoke",
        \\2
        \\value
        \\
    );
}

test "ctor_generic_arg_inference" {
    try check("ctor_generic_arg_inference",
        \\[a, b]
        \\1
        \\4
        \\
    );
}

test "comparator_sibling_expected" {
    try check("comparator_sibling_expected",
        \\bca
        \\abc
        \\bca
        \\
    );
}

// `outer(arrayOf(...))` commits the Long `sumOf` variant, not the Double one.
test "lambda_return_overload_pick" {
    try check("lambda_return_overload_pick",
        \\6
        \\6
        \\3
        \\6.0
        \\6
        \\6
        \\6
        \\3
        \\3
        \\
    );
}

test "nested_class_qualified_ctor" {
    try check("nested_class_qualified_ctor",
        \\built:7
        \\3
        \\companion-lives
        \\
    );
}

test "type_safe_bridge_barrier" {
    try check("type_safe_bridge_barrier",
        \\-1
        \\-1
        \\false
        \\-1
        \\1
        \\0
        \\true
        \\
    );
}

test "class_param_lambda_receiver" {
    try check("class_param_lambda_receiver",
        \\true
        \\
    );
}

test "callable_ref_inline_arg" {
    try check("callable_ref_inline_arg",
        \\[3, 4, 5]
        \\12
        \\6
        \\<x><y>
        \\
    );
}

test "binary_operator_overload_return" {
    try check("binary_operator_overload_return",
        \\-2
        \\8
        \\40
        \\70
        \\
    );
}

test "unsigned_value_class_hash" {
    try check("unsigned_value_class_hash",
        \\-1
        \\-1
        \\30721
        \\30721
        \\30721
        \\30721
        \\
    );
}

test "named_skip_commit_host_boundary" {
    try check("named_skip_commit_host_boundary",
        \\threw
        \\a
        \\1
        \\2
        \\
    );
}

test "splice_window_receiver_typing" {
    try check("splice_window_receiver_typing",
        \\bca
        \\abc
        \\x
        \\
    );
}

test "vararg_forward_named_skip" {
    try check("vararg_forward_named_skip",
        \\strings:2:0:true:0
        \\chars:1:0:false:7
        \\
    );
}

test "type_param_bounded_by_type_param" {
    try check("type_param_bounded_by_type_param",
        \\foobar/foo/2/list-typed
        \\[1, 3, 6]
        \\
    );
}

// The derived-receiver static-binding mechanisms in one program, including a
// `groupBy` result whose key type comes from the trailing lambda's return.
test "derived_receiver_static_binds" {
    try check("derived_receiver_static_binds",
        \\{beta=2}
        \\a, b, c, *
        \\[A, b]
        \\true
        \\true
        \\7
        \\[x, y]
        \\[a, b, c]
        \\[ab]
        \\3
        \\true
        \\
    );
}

test "map_instance_keys" {
    try check("map_instance_keys",
        \\size 200, v5, v199, null
        \\after removes 133, null, v4, false, true
        \\back 134 13270
        \\linked 50 49 50 [49, 48, 47, 46] 21 null
        \\replaced v4 now four
        \\plain 34 null 40
        \\points 34 99 null
        \\points null 99 -1 100
        \\moved null null null 30
        \\7
        \\threw equals of a negative
        \\mixed 60 int7 str7 id7 null
        \\
    );
}

test "map_keyed_ops" {
    try check("map_keyed_ops",
        \\3 putAll 4 100 k1
        \\3 plusAssign 5 8 50
        \\3 getOrPut 2 -2 2 -3 6
        \\3 toMap 6 1 8
        \\3 associateTo 2 [A, B] 2 X
        \\3 remove 8 false false 5
        \\3 minusAssign 5 null null [100]
        \\40 putAll 41 100 k1
        \\40 plusAssign 42 8 50
        \\40 getOrPut 2 -2 2 -3 43
        \\40 toMap 43 1 8
        \\40 associateTo 2 [A, B] 2 X
        \\40 remove 8 false true 42
        \\40 minusAssign 40 null null [100]
        \\
    );
}

test "numeric_conversion_ops" {
    try check("numeric_conversion_ops",
        \\L 0 0 0 0 0 0.0 0.0
        \\L -1 -1 -1 -1 65535 -1.0 -1.0
        \\L 2147483647 2147483647 -1 -1 65535 2.1474836E9 2.147483647E9
        \\L 2147483648 -2147483648 0 0 0 2.1474836E9 2.147483648E9
        \\L 4295032831 65535 -1 -1 65535 4.295033E9 4.295032831E9
        \\L -9223372036854775808 0 0 0 0 -9.223372E18 -9.223372036854776E18
        \\L 9223372036854775807 -1 -1 -1 65535 9.223372E18 9.223372036854776E18
        \\I 0 0 0 0 0 0.0 0.0
        \\I -1 -1 -1 -1 65535 -1.0 -1.0
        \\I 127 127 127 127 127 127.0 127.0
        \\I 128 128 128 -128 128 128.0 128.0
        \\I 255 255 255 -1 255 255.0 255.0
        \\I 256 256 256 0 256 256.0 256.0
        \\I 32767 32767 32767 -1 32767 32767.0 32767.0
        \\I 32768 32768 -32768 0 32768 32768.0 32768.0
        \\I 65535 65535 -1 -1 65535 65535.0 65535.0
        \\I 65536 65536 0 0 0 65536.0 65536.0
        \\I -2147483648 -2147483648 0 0 0 -2.1474836E9 -2.147483648E9
        \\I 2147483647 2147483647 -1 -1 65535 2.1474836E9 2.147483647E9
        \\D 0.0 0 0 0.0
        \\D -0.0 0 0 -0.0
        \\D 1.9 1 1 1.9
        \\D -1.9 -1 -1 -1.9
        \\D 3.0E9 2147483647 3000000000 3.0E9
        \\D -3.0E9 -2147483648 -3000000000 -3.0E9
        \\D 1.0E19 2147483647 9223372036854775807 1.0E19
        \\D -1.0E19 -2147483648 -9223372036854775808 -1.0E19
        \\D NaN 0 0 NaN
        \\D Infinity 2147483647 9223372036854775807 Infinity
        \\D -Infinity -2147483648 -9223372036854775808 -Infinity
        \\D 1.0E40 2147483647 9223372036854775807 Infinity
        \\D 0.1 0 0 0.1
        \\F 0.5 0 0 0.5
        \\F -2.5 -2 -2 -2.5
        \\F 3.0E9 2147483647 3000000000 3.0E9
        \\F -3.0E9 -2147483648 -3000000000 -3.0E9
        \\F 1.0E19 2147483647 9223372036854775807 9.999999980506448E18
        \\F NaN 0 0 NaN
        \\F -Infinity -2147483648 -9223372036854775808 -Infinity
        \\B -3 -3 -3 -3.0 -3.0
        \\S -300 -300 -44 -300.0
        \\C 90 90 [
        \\byte+byte 200 true
        \\short*short 900000000 true
        \\int+long 3000000007 true 2999999993 true
        \\long/int 428571428 4 -428571428 -4
        \\int*float 10.5 true
        \\long+float 3.0E9
        \\int+double 7.25 true
        \\float+double 0.30000000149011613
        \\byte*long 300000000000
        \\acc 45
        \\total 10.0
        \\true true true true
        \\true false -1
        \\true true -1
        \\false false -1 0
        \\false 0 -1 1
        \\<< 0 -20015998343868 >> -20015998343868 >>> -20015998343868
        \\<< 1 -40031996687736 >> -10007999171934 >>> 9223362028855603874
        \\<< 31 -3115450108355805184 >> -9321 >>> 8589925271
        \\<< 32 -6230900216711610368 >> -4661 >>> 4294962635
        \\<< 63 0 >> -1 >>> 1
        \\<< 64 -20015998343868 >> -20015998343868 >>> -20015998343868
        \\<< 65 -40031996687736 >> -10007999171934 >>> 9223362028855603874
        \\<< -1 0 >> -1 >>> 1
        \\int -9320 -2330 2147481318
        \\
    );
}

test "value_class_property_equality" {
    try check("value_class_property_equality",
        \\meters true false true false
        \\ieee false true
        \\ratio true false true
        \\id true true
        \\name true false
        \\packed true false
        \\wrap true true false
        \\fun true true false true
        \\any true false false
        \\unsigned true true true
        \\point true false false
        \\pair true false
        \\list true 0 2
        \\hash true true
        \\
    );
}

test "numeric_bit_functions" {
    try check("numeric_bit_functions",
        \\F 1.0 1065353216 1065353216 1.0
        \\F -0.0 -2147483648 -2147483648 -0.0
        \\F NaN 2143289344 2143289344 NaN
        \\F Infinity 2139095040 2139095040 Infinity
        \\F 1.4E-45 1 1 1.4E-45
        \\D 1.0 4607182418800017408 4607182418800017408 1.0
        \\D -0.0 -9223372036854775808 -9223372036854775808 -0.0
        \\D NaN 9221120237041090560 9221120237041090560 NaN
        \\D -Infinity -4503599627370496 -4503599627370496 -Infinity
        \\D 4.9E-324 1 1 4.9E-324
        \\nan 2143289345 2143289344 9221120237041090560
        \\fromBits -0.0 1.0 2.0
        \\I 0 -1 32 0 0.0 0.0
        \\I 1 -2 0 1 1.0 1.0
        \\I 8 -9 3 8 8.0 8.0
        \\I -1 0 0 -1 4.2949673E9 4.294967295E9
        \\I -2147483648 2147483647 31 -2147483648 2.1474836E9 2.147483648E9
        \\I 65536 -65537 16 65536 65536.0 65536.0
        \\L 0 -1 64 0.0 0.0
        \\L 1 -2 0 1.0 1.0
        \\L -1 0 0 1.8446744E19 1.8446744073709552E19
        \\L -9223372036854775808 9223372036854775807 63 9.223372E18 9.223372036854776E18
        \\L 1099511627776 -1099511627777 40 1.0995116E12 1.099511627776E12
        \\U 32 0 8 2 16
        \\S 16 7 8
        \\M 0.0 0.0 1.0 0.0
        \\M -0.0 -0.0 1.0 -0.0
        \\M 1.0 0.8414709848078965 0.5403023058681398 1.0
        \\M 2.0 0.9092974268256817 -0.4161468365471424 1.4142135623730951
        \\M 4.0 -0.7568024953079282 -0.6536436208636119 2.0
        \\M NaN NaN NaN NaN
        \\M Infinity NaN NaN Infinity
        \\M -1.0 -0.8414709848078965 0.5403023058681398 NaN
        \\MF 0.0 0.0 1.0 0.0
        \\MF -0.0 -0.0 1.0 -0.0
        \\MF 1.0 0.84147096 0.5403023 1.0
        \\MF 9.0 0.4121185 -0.91113025 3.0
        \\MF NaN NaN NaN NaN
        \\MF -4.0 0.7568025 -0.6536436 NaN
        \\
    );
}

test "unsigned_bit_operations" {
    try check("unsigned_bit_operations",
        \\UL 0 0 0 0 1 18446744073709551615 18446744073709551615
        \\   1 18446744073709551615 0 0 0 0 0 0.0
        \\UL 1 16 0 1 1 18446744073709551614 18446744073709551614
        \\   2 0 3 1 1 1 1 1.0
        \\UL 9223372036854775808 0 8 0 9223372036854775809 9223372036854775807 9223372036854775807
        \\   9223372036854775809 9223372036854775807 9223372036854775808 -9223372036854775808 0 0 0 9.223372036854776E18
        \\UL 18446744073709551615 18446744073709551600 15 255 18446744073709551615 0 0
        \\   0 18446744073709551614 18446744073709551613 -1 -1 4294967295 255 1.8446744073709552E19
        \\UL 18374686479671623935 17293822569102708720 15 255 18374686479671623935 72057594037927680 72057594037927680
        \\   18374686479671623936 18374686479671623934 18230571291595768573 -72057594037927681 255 255 255 1.8374686479671624E19
        \\chain 4484958772476917249 640708396068131035 4 true -1
        \\UI 0 0 0 0 4294967295 1 4294967295 0 0 0 0
        \\UI 1 8 0 0 4294967294 2 0 1 1 1 1
        \\UI 2147483648 0 1 0 2147483647 2147483649 2147483647 -2147483648 2147483648 2147483648 0
        \\UI 4294967295 4294967288 1 240 0 0 4294967294 -1 4294967295 4294967295 65535
        \\UI 65535 524280 0 240 4294901760 65536 65534 65535 65535 65535 65535
        \\from int 4294967295 2147483648 18446744073709551615 18446744073709551615
        \\S 0 0 0 255 0 0 0 1 0
        \\S 1 1 1 254 1 1 1 2 16
        \\S 127 127 127 128 15 127 127 128 2032
        \\S 128 128 128 127 0 128 128 129 2048
        \\S 255 255 255 0 15 255 255 256 4080
        \\S 256 0 0 255 0 256 256 257 0
        \\S -1 255 255 0 15 65535 65535 65536 4080
        \\packed 18389154510799896576 255 51 102 153 4281558681
        \\
    );
}

test "constant_operands" {
    try check("constant_operands",
        \\int 0: 0 0 0 0 5 -1 256 0 0 0 0
        \\  true true true true true true false 3
        \\  zero small even
        \\int 1: 1 8 0 0 36 -2 257 0 1 -1 0
        \\  false true true true true true false 2
        \\  nonzero small odd
        \\int 7: 7 56 0 0 222 -8 263 2 2 -7 0
        \\  false false true true true true true -4
        \\  nonzero small odd
        \\int -3: 253 -24 15 -1 -88 2 -3 -1 -3 3 0
        \\  false true true true true true false 6
        \\  nonzero small odd
        \\int 255: 255 2040 0 15 7910 -256 511 85 0 -255 0
        \\  false true false false true true false -252
        \\  nonzero big odd
        \\int 256: 0 2048 0 16 7941 -257 256 85 1 -256 0
        \\  false true false false true true false -253
        \\  nonzero big even
        \\int 1000: 232 8000 0 62 31005 -1001 1000 333 0 -1000 0
        \\  false true false false true true false -997
        \\  nonzero big even
        \\int 2147483647: 255 -8 7 134217727 2147483622 -2147483648 2147483647 715827882 2 -2147483647 0
        \\  false true false false true true false -2147483644
        \\  nonzero big odd
        \\int -2147483648: 0 0 8 -134217728 -2147483643 2147483647 -2147483392 -715827882 -3 -2147483648 0
        \\  false true true true false false false -2147483645
        \\  nonzero small even
        \\long 0: 0 0 0 0 0 -9223372036854775808 0 0
        \\  true false true 0 0
        \\  not max
        \\long 1: 1 8589934592 0 0 1000000007 -9223372036854775807 0 1
        \\  false false true 8 0
        \\  not max
        \\long -1: 65535 -8589934592 15 -1 -1000000007 9223372036854775807 0 -1
        \\  false false false -8 2305843009213693951
        \\  not max
        \\long 2199023255552: 0 0 0 1099511627776 3860726173726146560 -9223369837831520256 314146179364 4
        \\  false true true 17592186044416 274877906944
        \\  not max
        \\long 9223372036854775807: 65535 -8589934592 7 4611686018427387903 9223372035854775801 -1 1317624576693539401 0
        \\  false true true -8 1152921504606846975
        \\  max
        \\long -9223372036854775808: 0 0 8 -4611686018427387904 -9223372036854775808 0 -1317624576693539401 -1
        \\  false false false 0 1152921504606846976
        \\  not max
        \\float 0.0: 0.0 0.5 0.5 0.0 -1.0 0.0 true true true
        \\double 0.0: 0.0 0.25 NaN true false false false
        \\  not positive
        \\float -0.0: -0.0 0.5 0.5 -0.0 -1.0 -0.0 true true true
        \\double -0.0: -0.0 0.25 NaN true false false false
        \\  not positive
        \\float 1.0: 2.0 1.5 1.5 0.25 0.0 1.0 false false false
        \\double 1.0: 2.0 1.25 Infinity false true false false
        \\  positive
        \\float -2.5: -5.0 -2.0 -2.0 -0.625 -3.5 -2.5 false true true
        \\double -2.5: -5.0 -2.25 -Infinity false true false false
        \\  not positive
        \\float NaN: NaN NaN NaN NaN NaN NaN false false false
        \\double NaN: NaN NaN NaN false true false false
        \\  not positive
        \\float Infinity: Infinity Infinity Infinity Infinity Infinity NaN false false false
        \\double Infinity: Infinity Infinity Infinity false true true true
        \\  positive
        \\unsigned 0 1: true true false false
        \\  not max
        \\unsigned 18446744073709551615 4294967295: false false true true
        \\  max
        \\mixed: -127 60000 0 B 1 true false
        \\mixed: 128 -2 15 { 58 false true
        \\int: / by zero
        \\long: / by zero
        \\sum 8745
        \\
    );
}

test "virtual_call_sites" {
    try check("virtual_call_sites",
        \\one class: [1, 4, 9, 16, 25]
        \\two classes: [0, 2, 4, 6, 16, 10, 36, 14] [4, 4, 4, 4, 4, 4, 4, 4]
        \\many classes: [9, 10, 6, 6, 12, 1, 3, 2] [4, 4, 3, 3, 0, 4, 0, 3]
        \\square with 4 sides, area 9
        \\rect with 4 sides, area 10
        \\tri with 3 sides, area 6
        \\tri with 3 sides, area 6
        \\round circle, area 12
        \\square with 4 sides, area 1
        \\round circle, area 3
        \\tri with 3 sides, area 2
        \\total 210
        \\tree sums: [1, 3, 10, 36, 136, 528, 2080]
        \\lengths: [4, 4, 4, 4, 1]
        \\firsts: [k, T, c, S, x]
        \\strings: [klio, TAIL, call, SITE, x]
        \\list sites: 204 [3, 2, 4, 3, 1] [2, 5, 4, 8, 10]
        \\collections: [2, 1, 3, 4]
        \\texts: [1, two, 3, 4.5, c, true, [0, 2], [1]]
        \\hashes: [1, 115276, 3, 1074921472, 99, 1231]
        \\
    );
}

test "value_class_members" {
    try check("value_class_members",
        \\[11px, 10px, 11px, 10px, 10px, 10px, 4px, 0px, 4px]
        \\101px 42px
        \\6px 5px 3px
        \\6px 11px 4px
        \\14px 0px 3px
        \\42px
        \\16px
        \\[0px, 6px, 10px] 10px [10px, 6px, 0px]
        \\total: 16px, angle: 1.5707964
        \\null null 45.0
        \\8 16px 90.0 1.5707964
        \\[px 1, angle 2.0, other]
        \\true 9px [1px, 2px]
        \\[1px, 2px] 2
        \\{a=5px, b=6px}
        \\before
        \\Tagged companion ready
        \\after 3 1
        \\
    );
}

test "value_class_flows" {
    try check("value_class_flows",
        \\3.5m
        \\sum 3.5m times 4.5m half 1.0m Meters(1.5)
        \\false true -1 true
        \\[1.5m, 2.0m, 0.25m] [0.25m, 1.5m, 2.0m] 2.0m [1.5, 2.0, 0.25]
        \\1.5m 1.5m 1.5m
        \\1.5m:true:1073217536 Id(raw=7):false:7 none 2.0m
        \\3.5
        \\1.5m 1.0m null -1.0m 1.5m
        \\0.5m Id(raw=1) other 3.0m 2.0m
        \\3.0m 3.0m
        \\3.5m 3.5m 1 2
        \\-3,4
        \\Box(w=1.5m, id=Id(raw=3), tags=[1.5m, 2.0m, 0.25m])
        \\Box(w=2.0m, id=Id(raw=3), tags=[1.5m, 2.0m, 0.25m])
        \\1.5m Id(raw=3) 3 true
        \\a null 2
        \\[4.0, 9.0] true
        \\smart 1.5 3.5m
        \\nonnull 1.0
        \\0.5m
        \\3.75m
        \\6.75m
        \\negative id -1
        \\Id(raw=0) 5
        \\2.0m
        \\[9.0m, 2.0m]
        \\3.5m 1.5
        \\3.5m
        \\15.0 1.0m Meters
        \\-1
        \\[true, false]
        \\true false true
        \\[1.5m, 4.0m]
        \\3.0m null
        \\
    );
}

test "wide_frames" {
    try check("wide_frames",
        \\wide: [3349156554369338289, -1042370196751942829, 3125300851712839122, -1076956639056340671, 787743997148866197]
        \\guarded 0: 64 caught stage 1 at 1 a=95 finally b=221 stage=1 d=195
        \\guarded 1: 144 128 finally b=50 stage=2 d=79
        \\guarded 2: 185 221 finally b=13 stage=2 d=187
        \\guarded 3: 233 caught stage 1 at 1 a=250 finally b=230 stage=1 d=99
        \\guarded 4: 236 246 finally b=60 stage=2 d=55
        \\Box(1226612418, -3312304032, b2, 0.0)
        \\Box(134786273, 4656866306, b28, 0.0)
        \\Box(-1359819798, 1344562274, first:6;second:7;, 0.0)
        \\copies: 4>0 0>9 4>12 12>7 keep=196 cur=199
        \\sequence: [21694, 45648, 17596, 45649, 53102, 45650, 554]
        \\depth: [0, 1039949, 516962, 579717, 581514, 138820, 791700]
        \\
    );
}

test "null_and_identity_tests" {
    try check("null_and_identity_tests",
        \\length 6 0 5
        \\identity false true true false
        \\null false true false
        \\describe [null, value, value, unit, value, value, value]
        \\nullness [true, false, false, false, false, false, false] [false, true, true, true, true, true, true]
        \\captured true true
        \\captured false true now
        \\captured true
        \\negated true false false
        \\not below true true false
        \\data true false false true
        \\strings true false
        \\
    );
}

test "value_class_boxed_edges" {
    try check("value_class_boxed_edges",
        \\5
        \\14
        \\32
        \\6
        \\ababab
        \\xx
        \\Rank(r=14) true true true
        \\
    );
}
