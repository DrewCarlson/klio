//! Negative-case corpus.
//!
//! Each `.kt` fixture under tests/fixtures/typeck_negative/ MUST produce
//! at least one type-checker diagnostic carrying the expected legacy code.
//! The fixtures are read from disk, run through the real pipeline
//! lexer -> parser -> resolver -> typeck, and the emitted legacy codes are
//! asserted against the expected ones — faithful to the Rust assertions.
//!
//! A handful of cases embed their source inline (the `pos_*` no-diagnostic
//! cases) or merge two parsed files into one analysis unit (the cross-file
//! visibility cases); those mirror the Rust tests exactly.

const std = @import("std");

const lexer = @import("lexer");
const parser = @import("parser");
const resolver = @import("resolver");
const typeck = @import("typeck");
const ast = @import("ast");
const span = @import("span");

const Lexer = lexer.Lexer;
const Parser = parser.Parser;
const FileId = span.FileId;

const NEG_DIR = "tests/fixtures/typeck_negative";

/// Run lexer -> parser -> resolver -> typeck over `src` (a single file with
/// `file_id`) and return the list of legacy diagnostic codes the type checker
/// emitted. Everything is allocated from `a` (an arena owned by the caller).
fn codesForSource(a: std.mem.Allocator, file_id: FileId, src: []const u8) ![]const []const u8 {
    var lx = try Lexer.init(a, file_id, src);
    const lexed = try lx.tokenize();
    const p = Parser.new(a, file_id, src, lexed.tokens);
    const file = p.parseFile();

    var r = try resolver.resolve(a, &file);
    var tc = try typeck.typecheck(a, &file, &r);

    var codes: std.ArrayList([]const u8) = .empty;
    for (tc.diagnostics.diags()) |d| {
        if (d.legacy_code) |c| try codes.append(a, c);
    }
    return codes.items;
}

/// Read a fixture under tests/negative/ and return the emitted legacy codes.
fn codesForFixture(a: std.mem.Allocator, name: []const u8) ![]const []const u8 {
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ NEG_DIR, name });
    const src = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited);
    return codesForSource(a, FileId.from(0), src);
}

/// Merge two source files into one analysis unit (matching the Rust
/// cross-file tests) and return the emitted legacy codes. Each source keeps
/// its own `FileId` so the visibility check, which keys off `Span::file`,
/// sees them as distinct files.
fn codesForMerged(a: std.mem.Allocator, src_a: []const u8, src_b: []const u8) ![]const []const u8 {
    var lx_a = try Lexer.init(a, FileId.from(0), src_a);
    const lexed_a = try lx_a.tokenize();
    const p_a = Parser.new(a, FileId.from(0), src_a, lexed_a.tokens);
    const file_a = p_a.parseFile();

    var lx_b = try Lexer.init(a, FileId.from(1), src_b);
    const lexed_b = try lx_b.tokenize();
    const p_b = Parser.new(a, FileId.from(1), src_b, lexed_b.tokens);
    const file_b = p_b.parseFile();

    const merged_decls = try a.alloc(ast.Decl, file_a.decls.len + file_b.decls.len);
    @memcpy(merged_decls[0..file_a.decls.len], file_a.decls);
    @memcpy(merged_decls[file_a.decls.len..], file_b.decls);

    const merged = ast.KotlinFile{
        .package = file_a.package,
        .imports = file_a.imports,
        .decls = merged_decls,
        .span = file_a.span,
    };

    var r = try resolver.resolve(a, &merged);
    var tc = try typeck.typecheck(a, &merged, &r);

    var codes: std.ArrayList([]const u8) = .empty;
    for (tc.diagnostics.diags()) |d| {
        if (d.legacy_code) |c| try codes.append(a, c);
    }
    return codes.items;
}

fn hasCode(codes: []const []const u8, want: []const u8) bool {
    for (codes) |c| {
        if (std.mem.eql(u8, c, want)) return true;
    }
    return false;
}

/// Assert that the fixture `name` emits at least one diagnostic with code `want`.
fn expectFixtureCode(name: []const u8, want: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const codes = try codesForFixture(a, name);
    if (!hasCode(codes, want)) {
        std.debug.print("expected {s} from {s}, got: {s}\n", .{ want, name, codesJoin(a, codes) });
        return error.MissingExpectedCode;
    }
}

fn codesJoin(a: std.mem.Allocator, codes: []const []const u8) []const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (codes, 0..) |c, i| {
        if (i != 0) buf.appendSlice(a, ", ") catch {};
        buf.appendSlice(a, c) catch {};
    }
    return buf.items;
}

test "neg_type_mismatch" {
    try expectFixtureCode("neg_type_mismatch.kt", "T0001");
}

test "neg_null_deref" {
    try expectFixtureCode("neg_null_deref.kt", "T0003");
}

test "neg_val_reassign" {
    try expectFixtureCode("neg_val_reassign.kt", "T0006");
}

test "neg_arity" {
    try expectFixtureCode("neg_arity.kt", "T0004");
}

test "neg_wrong_arg_type" {
    try expectFixtureCode("neg_wrong_arg_type.kt", "T0001");
}

test "neg_abstract_instantiate" {
    try expectFixtureCode("neg_abstract_instantiate.kt", "T0007");
}

test "neg_override_needed" {
    try expectFixtureCode("neg_override_needed.kt", "T0009");
}

test "neg_override_no_base" {
    try expectFixtureCode("neg_override_no_base.kt", "T0011");
}

test "neg_override_parent_not_open" {
    try expectFixtureCode("neg_override_parent_not_open.kt", "T0010");
}

test "neg_prop_override_needed" {
    try expectFixtureCode("neg_prop_override_needed.kt", "T0009");
}

test "neg_delegate_missing_operator" {
    try expectFixtureCode("neg_delegate_missing_operator.kt", "T0012");
}

test "neg_operator_keyword_missing_plus" {
    try expectFixtureCode("neg_operator_keyword_missing_plus.kt", "T0087");
}

test "neg_operator_keyword_missing_get" {
    try expectFixtureCode("neg_operator_keyword_missing_get.kt", "T0087");
}

test "neg_operator_signature_inc_takes_arg" {
    try expectFixtureCode("neg_operator_signature_inc_takes_arg.kt", "T0088");
}

test "neg_operator_signature_compareto_return" {
    try expectFixtureCode("neg_operator_signature_compareto_return.kt", "T0088");
}

test "neg_diamond_conflict" {
    try expectFixtureCode("neg_diamond_conflict.kt", "T0013");
}

test "neg_lateinit_val" {
    try expectFixtureCode("neg_lateinit_val.kt", "T0014");
}

test "neg_lateinit_primitive" {
    try expectFixtureCode("neg_lateinit_primitive.kt", "T0015");
}

test "neg_lateinit_initializer" {
    try expectFixtureCode("neg_lateinit_initializer.kt", "T0016");
}

test "neg_lateinit_nullable" {
    try expectFixtureCode("neg_lateinit_nullable.kt", "T0017");
}

test "neg_accessor_return_type_mismatch" {
    try expectFixtureCode("neg_accessor_return_type_mismatch.kt", "T0018");
}

test "neg_when_not_exhaustive" {
    try expectFixtureCode("neg_when_not_exhaustive.kt", "T0019");
}

test "neg_var_not_definitely_assigned" {
    try expectFixtureCode("neg_var_not_definitely_assigned.kt", "T0020");
}

test "neg_reified_requires_inline" {
    try expectFixtureCode("neg_reified_requires_inline.kt", "T0023");
}

test "neg_inline_modifier_outside_inline" {
    try expectFixtureCode("neg_inline_modifier_outside_inline.kt", "T0026");
}

test "neg_vararg_misuse" {
    try expectFixtureCode("neg_vararg_misuse.kt", "T0025");
}

test "neg_declaration_variance_violation" {
    try expectFixtureCode("neg_declaration_variance_violation.kt", "T0024");
}

test "neg_definitely_non_null" {
    try expectFixtureCode("neg_definitely_non_null.kt", "T0027");
}

test "neg_unchecked_cast" {
    try expectFixtureCode("neg_unchecked_cast.kt", "T0028");
}

test "neg_infix_modifier_required" {
    try expectFixtureCode("neg_infix_modifier_required.kt", "T0029");
}

test "neg_unresolved_label" {
    try expectFixtureCode("neg_unresolved_label.kt", "T0030");
}

test "neg_private_class_member_from_outside" {
    try expectFixtureCode("neg_private_class_member_from_outside.kt", "T0031");
}

test "neg_protected_member_from_unrelated" {
    try expectFixtureCode("neg_protected_member_from_unrelated.kt", "T0031");
}

test "pos_protected_member_from_subclass" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\
        \\        open class Base {
        \\            protected fun greet(): String = "hi"
        \\        }
        \\        class Sub : Base() {
        \\            fun call(): String = greet()
        \\            fun callOnThis(): String = this.greet()
        \\        }
        \\        fun main() { println(Sub().call()) }
        \\
    ;
    const codes = try codesForSource(a, FileId.from(0), src);
    if (hasCode(codes, "T0031")) {
        std.debug.print("unexpected T0031 on subclass `protected` access: {s}\n", .{codesJoin(a, codes)});
        return error.UnexpectedCode;
    }
}

test "pos_private_member_same_class" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\
        \\        class Box(val n: Int) {
        \\            private fun secret(): Int = n * 2
        \\            fun expose(): Int = secret()
        \\        }
        \\        fun main() { println(Box(3).expose()) }
        \\
    ;
    const codes = try codesForSource(a, FileId.from(0), src);
    if (hasCode(codes, "T0031")) {
        std.debug.print("unexpected T0031 on same-class `private` access: {s}\n", .{codesJoin(a, codes)});
        return error.UnexpectedCode;
    }
}

test "pos_internal_treated_as_public" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\
        \\        internal fun helper(): Int = 7
        \\        internal class Bag(val n: Int)
        \\        fun main() { println(helper() + Bag(3).n) }
        \\
    ;
    const codes = try codesForSource(a, FileId.from(0), src);
    if (hasCode(codes, "T0031") or hasCode(codes, "T0032")) {
        std.debug.print("unexpected visibility diagnostic on `internal`: {s}\n", .{codesJoin(a, codes)});
        return error.UnexpectedCode;
    }
}

test "neg_private_top_level_cross_file" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src_a =
        \\
        \\        private fun hidden(): Int = 42
        \\        fun helperA(): Int = hidden()
        \\
    ;
    const src_b =
        \\
        \\        fun main() { println(hidden()) }
        \\
    ;
    const codes = try codesForMerged(a, src_a, src_b);
    if (!hasCode(codes, "T0032")) {
        std.debug.print("expected T0032 on private top-level fn used across files: {s}\n", .{codesJoin(a, codes)});
        return error.MissingExpectedCode;
    }
}

test "neg_const_val_not_toplevel" {
    try expectFixtureCode("neg_const_val_not_toplevel.kt", "T0033");
}

test "neg_const_val_non_const_init" {
    try expectFixtureCode("neg_const_val_non_const_init.kt", "T0034");
}

test "neg_const_val_bad_type" {
    try expectFixtureCode("neg_const_val_bad_type.kt", "T0034");
}

test "neg_value_class_open" {
    try expectFixtureCode("neg_value_class_open.kt", "T0035");
}

test "neg_value_class_data" {
    try expectFixtureCode("neg_value_class_data.kt", "T0035");
}

test "neg_value_class_two_vals" {
    try expectFixtureCode("neg_value_class_two_vals.kt", "T0035");
}

test "neg_value_class_var" {
    try expectFixtureCode("neg_value_class_var.kt", "T0035");
}

test "neg_value_class_init_block" {
    try expectFixtureCode("neg_value_class_init_block.kt", "T0035");
}

test "neg_annotation_class_body" {
    try expectFixtureCode("neg_annotation_class_body.kt", "T0036");
}

test "neg_annotation_class_open" {
    try expectFixtureCode("neg_annotation_class_open.kt", "T0036");
}

test "neg_annotation_class_param_type" {
    try expectFixtureCode("neg_annotation_class_param_type.kt", "T0037");
}

test "neg_annotation_class_cycle_direct" {
    try expectFixtureCode("neg_annotation_class_cycle_direct.kt", "T0107");
}

test "neg_annotation_class_cycle_array" {
    try expectFixtureCode("neg_annotation_class_cycle_array.kt", "T0107");
}

test "neg_opt_in_missing" {
    try expectFixtureCode("neg_opt_in_missing.kt", "T0112");
}

test "neg_deprecated_error_used" {
    try expectFixtureCode("neg_deprecated_error_used.kt", "T0111");
}

test "neg_annotation_duplicate_non_repeatable" {
    try expectFixtureCode("neg_annotation_duplicate_non_repeatable.kt", "T0109");
}

test "neg_annotation_target_class_only_on_function" {
    try expectFixtureCode("neg_annotation_target_class_only_on_function.kt", "T0110");
}

test "neg_annotation_class_param_default_non_const" {
    try expectFixtureCode("neg_annotation_class_param_default_non_const.kt", "T0108");
}

test "neg_annotation_class_unsupported_user_param" {
    try expectFixtureCode("neg_annotation_class_unsupported_user_param.kt", "T0037");
}

test "neg_recursive_typealias" {
    try expectFixtureCode("neg_recursive_typealias.kt", "T0038");
}

test "neg_typealias_nested_in_class" {
    try expectFixtureCode("neg_typealias_nested_in_class.kt", "T0039");
}

test "neg_extension_property_initializer" {
    try expectFixtureCode("neg_extension_property_initializer.kt", "T0040");
}

test "neg_extension_property_delegate" {
    try expectFixtureCode("neg_extension_property_delegate.kt", "T0041");
}

test "neg_extension_property_needs_accessor" {
    try expectFixtureCode("neg_extension_property_needs_accessor.kt", "T0042");
}

test "neg_delegation_to_class" {
    try expectFixtureCode("neg_delegation_to_class.kt", "T0043");
}

test "neg_delegation_type_mismatch" {
    try expectFixtureCode("neg_delegation_type_mismatch.kt", "T0044");
}

test "neg_data_object_equals" {
    try expectFixtureCode("neg_data_object_equals.kt", "T0045");
}

test "neg_field_outside_accessor" {
    try expectFixtureCode("neg_field_outside_accessor.kt", "T0046");
}

test "neg_field_in_extension_property" {
    try expectFixtureCode("neg_field_in_extension_property.kt", "T0046");
}

test "neg_spread_requires_vararg" {
    try expectFixtureCode("neg_spread_requires_vararg.kt", "T0047");
}

test "neg_tailrec_non_tail" {
    try expectFixtureCode("neg_tailrec_non_tail.kt", "T0048");
}

test "neg_tailrec_no_calls" {
    try expectFixtureCode("neg_tailrec_no_calls.kt", "T0049");
}

test "neg_enum_final_override" {
    try expectFixtureCode("neg_enum_final_override.kt", "T0050");
}

test "neg_throwable_type_params" {
    try expectFixtureCode("neg_throwable_type_params.kt", "T0051");
}

test "neg_throw_non_throwable" {
    try expectFixtureCode("neg_throw_non_throwable.kt", "T0106");
}

test "neg_tailrec_on_open" {
    try expectFixtureCode("neg_tailrec_on_open.kt", "T0057");
}

test "neg_data_class_copy_override" {
    try expectFixtureCode("neg_data_class_copy_override.kt", "T0059");
}

test "neg_data_class_component_override" {
    try expectFixtureCode("neg_data_class_component_override.kt", "T0058");
}

test "neg_secondary_ctor_cycle" {
    try expectFixtureCode("neg_secondary_ctor_cycle.kt", "T0060");
}

test "neg_data_class_no_property" {
    try expectFixtureCode("neg_data_class_no_property.kt", "T0061");
}

test "neg_data_class_vararg_property" {
    try expectFixtureCode("neg_data_class_vararg_property.kt", "T0062");
}

test "neg_annotation_array_bad_element" {
    try expectFixtureCode("neg_annotation_array_bad_element.kt", "T0037");
}

test "neg_inline_property_initializer" {
    try expectFixtureCode("neg_inline_property_initializer.kt", "T0053");
}

test "neg_no_backing_field_initializer" {
    try expectFixtureCode("neg_no_backing_field_initializer.kt", "T0054");
}

test "neg_inline_param_leak" {
    try expectFixtureCode("neg_inline_param_leak.kt", "T0055");
}

test "neg_crossinline_param_leak" {
    try expectFixtureCode("neg_crossinline_param_leak.kt", "T0056");
}

test "neg_private_primary_ctor_cross_file" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src_a = "class Foo private constructor(val x: Int)\n";
    const src_b = "fun main() { Foo(1) }\n";
    const codes = try codesForMerged(a, src_a, src_b);
    if (!hasCode(codes, "T0031")) {
        std.debug.print("expected T0031 on private primary-ctor cross-file ctor call: {s}\n", .{codesJoin(a, codes)});
        return error.MissingExpectedCode;
    }
}

test "neg_private_setter_cross_file" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src_a = "var counter: Int = 0\n    private set\n";
    const src_b = "fun main() { counter = 5 }\n";
    const codes = try codesForMerged(a, src_a, src_b);
    if (!hasCode(codes, "T0032")) {
        std.debug.print("expected T0032 on private-setter cross-file write: {s}\n", .{codesJoin(a, codes)});
        return error.MissingExpectedCode;
    }
}

test "neg_published_api_missing" {
    try expectFixtureCode("neg_published_api_missing.kt", "T0031");
}

test "neg_diamond_class_interface" {
    try expectFixtureCode("neg_diamond_class_interface.kt", "T0013");
}

test "neg_diamond_abstract_concrete" {
    try expectFixtureCode("neg_diamond_abstract_concrete.kt", "T0013");
}

test "neg_override_return_type" {
    try expectFixtureCode("neg_override_return_type.kt", "T0065");
}

test "neg_override_property_mutability" {
    try expectFixtureCode("neg_override_property_mutability.kt", "T0066");
}

test "neg_override_property_type" {
    try expectFixtureCode("neg_override_property_type.kt", "T0067");
}

test "neg_suspend_call_from_non_suspend" {
    try expectFixtureCode("neg_suspend_call_from_non_suspend.kt", "T0115");
}

test "neg_override_suspend_added" {
    try expectFixtureCode("neg_override_suspend_added.kt", "T0069");
}

test "neg_override_suspend_dropped" {
    try expectFixtureCode("neg_override_suspend_dropped.kt", "T0069");
}

test "neg_override_visibility_stronger" {
    try expectFixtureCode("neg_override_visibility_stronger.kt", "T0068");
}

test "neg_sealed_local_inheritor" {
    try expectFixtureCode("neg_sealed_local_inheritor.kt", "T0071");
}

test "neg_sealed_anonymous_inheritor" {
    try expectFixtureCode("neg_sealed_anonymous_inheritor.kt", "T0071");
}

test "neg_private_open" {
    try expectFixtureCode("neg_private_open.kt", "T0070");
}

test "neg_private_override" {
    try expectFixtureCode("neg_private_override.kt", "T0070");
}

test "neg_inherit_from_final" {
    try expectFixtureCode("neg_inherit_from_final.kt", "T0063");
}

test "neg_inherit_from_object" {
    try expectFixtureCode("neg_inherit_from_object.kt", "T0064");
}

test "neg_data_class_open" {
    try expectFixtureCode("neg_data_class_open.kt", "T0072");
}

test "neg_enum_class_abstract" {
    try expectFixtureCode("neg_enum_class_abstract.kt", "T0072");
}

test "pos_definitely_non_null_on_type_param" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "fun <T> id(x: T & Any): T & Any = x\nfun main() { println(id(7)) }\n";
    const codes = try codesForSource(a, FileId.from(0), src);
    if (hasCode(codes, "T0027")) {
        std.debug.print("unexpected T0027 on type parameter use: {s}\n", .{codesJoin(a, codes)});
        return error.UnexpectedCode;
    }
}

test "neg_label_on_arbitrary_expr" {
    try expectFixtureCode("neg_label_on_arbitrary_expr.kt", "T0078");
}

test "neg_property_init_cycle" {
    try expectFixtureCode("neg_property_init_cycle.kt", "T0076");
}

test "neg_reference_equality_distinct" {
    try expectFixtureCode("neg_reference_equality_distinct.kt", "T0081");
}

test "neg_anonymous_object_escapes_multi" {
    try expectFixtureCode("neg_anonymous_object_escapes_multi.kt", "T0085");
}

test "neg_spread_type_mismatch" {
    try expectFixtureCode("neg_spread_type_mismatch.kt", "T0086");
}

test "neg_as_safe_type_param" {
    try expectFixtureCode("neg_as_safe_type_param.kt", "T0083");
}

test "neg_is_type_param" {
    try expectFixtureCode("neg_is_type_param.kt", "T0100");
}

test "neg_as_unchecked_type_param" {
    try expectFixtureCode("neg_as_unchecked_type_param.kt", "T0028");
}

test "neg_class_literal_nullable" {
    try expectFixtureCode("neg_class_literal_nullable.kt", "T0101");
}

test "neg_class_literal_type_param" {
    try expectFixtureCode("neg_class_literal_type_param.kt", "T0102");
}

test "neg_catch_type_param" {
    try expectFixtureCode("neg_catch_type_param.kt", "T0105");
}

test "neg_catch_type_args" {
    try expectFixtureCode("neg_catch_type_args.kt", "T0105");
}

test "neg_throw_type_param" {
    try expectFixtureCode("neg_throw_type_param.kt", "T0105");
}

test "neg_value_equality_distinct" {
    try expectFixtureCode("neg_value_equality_distinct.kt", "T0082");
}

test "neg_method_reads_nonproperty_ctor_param" {
    try expectFixtureCode("neg_method_reads_nonproperty_ctor_param.kt", "T0075");
}

test "neg_circular_type_bound" {
    try expectFixtureCode("neg_circular_type_bound.kt", "T0096");
}

test "neg_type_bound_not_satisfied" {
    try expectFixtureCode("neg_type_bound_not_satisfied.kt", "T0022");
}

test "neg_circular_type_bound_self" {
    try expectFixtureCode("neg_circular_type_bound_self.kt", "T0096");
}

test "neg_compound_assign_ambiguity" {
    try expectFixtureCode("neg_compound_assign_ambiguity.kt", "T0079");
}

test "neg_super_qualifier_not_supertype" {
    try expectFixtureCode("neg_super_qualifier_not_supertype.kt", "T0073");
}

test "neg_missing_return" {
    try expectFixtureCode("neg_missing_return.kt", "T0005");
}

test "neg_dsl_marker_nested_shadow" {
    try expectFixtureCode("neg_dsl_marker_nested_shadow.kt", "T0113");
}

test "neg_suspend_delegate_get_value" {
    try expectFixtureCode("neg_suspend_delegate_get_value.kt", "T0114");
}
