//! Negative-case corpus. Each `.kt` file under `tests/negative/` MUST
//! produce at least one type-checker error with the expected code.

use std::path::PathBuf;

use klio_lexer::Lexer;
use klio_parser::Parser;
use klio_span::SourceMap;

fn negative_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests").join("negative")
}

fn type_codes_for(name: &str) -> Vec<String> {
    let path = negative_dir().join(name);
    let src = std::fs::read_to_string(&path).expect("read");
    let mut map = SourceMap::new();
    let id = map.add(&path, src);
    let owned = map.get(id).source.clone();
    let toks = Lexer::new(id, &owned).tokenize();
    let (ast, _) = Parser::new(id, &owned, &toks.tokens).parse_file();
    let r = klio_resolver::resolve(&ast);
    let tc = klio_typeck::typecheck(&ast, &r);
    tc.diagnostics
        .diagnostics()
        .iter()
        .filter_map(|d| d.legacy_code.map(String::from))
        .collect()
}

#[test]
fn neg_type_mismatch() {
    assert!(type_codes_for("neg_type_mismatch.kt").iter().any(|c| c == "T0001"));
}

#[test]
fn neg_null_deref() {
    assert!(type_codes_for("neg_null_deref.kt").iter().any(|c| c == "T0003"));
}

#[test]
fn neg_val_reassign() {
    assert!(type_codes_for("neg_val_reassign.kt").iter().any(|c| c == "T0006"));
}

#[test]
fn neg_arity() {
    assert!(type_codes_for("neg_arity.kt").iter().any(|c| c == "T0004"));
}

#[test]
fn neg_wrong_arg_type() {
    assert!(type_codes_for("neg_wrong_arg_type.kt").iter().any(|c| c == "T0001"));
}

#[test]
fn neg_abstract_instantiate() {
    assert!(type_codes_for("neg_abstract_instantiate.kt")
        .iter()
        .any(|c| c == "T0007"));
}

#[test]
fn neg_override_needed() {
    assert!(type_codes_for("neg_override_needed.kt").iter().any(|c| c == "T0009"));
}

#[test]
fn neg_override_no_base() {
    assert!(type_codes_for("neg_override_no_base.kt").iter().any(|c| c == "T0011"));
}

#[test]
fn neg_override_parent_not_open() {
    assert!(type_codes_for("neg_override_parent_not_open.kt")
        .iter()
        .any(|c| c == "T0010"));
}

#[test]
fn neg_prop_override_needed() {
    assert!(type_codes_for("neg_prop_override_needed.kt")
        .iter()
        .any(|c| c == "T0009"));
}

#[test]
fn neg_delegate_missing_operator() {
    assert!(type_codes_for("neg_delegate_missing_operator.kt")
        .iter()
        .any(|c| c == "T0012"));
}

#[test]
fn neg_operator_keyword_missing_plus() {
    assert!(type_codes_for("neg_operator_keyword_missing_plus.kt")
        .iter()
        .any(|c| c == "T0087"));
}

#[test]
fn neg_operator_keyword_missing_get() {
    assert!(type_codes_for("neg_operator_keyword_missing_get.kt")
        .iter()
        .any(|c| c == "T0087"));
}

#[test]
fn neg_operator_signature_inc_takes_arg() {
    assert!(type_codes_for("neg_operator_signature_inc_takes_arg.kt")
        .iter()
        .any(|c| c == "T0088"));
}

#[test]
fn neg_operator_signature_compareto_return() {
    assert!(type_codes_for("neg_operator_signature_compareto_return.kt")
        .iter()
        .any(|c| c == "T0088"));
}

#[test]
fn neg_diamond_conflict() {
    assert!(type_codes_for("neg_diamond_conflict.kt")
        .iter()
        .any(|c| c == "T0013"));
}

#[test]
fn neg_lateinit_val() {
    assert!(type_codes_for("neg_lateinit_val.kt")
        .iter()
        .any(|c| c == "T0014"));
}

#[test]
fn neg_lateinit_primitive() {
    assert!(type_codes_for("neg_lateinit_primitive.kt")
        .iter()
        .any(|c| c == "T0015"));
}

#[test]
fn neg_lateinit_initializer() {
    assert!(type_codes_for("neg_lateinit_initializer.kt")
        .iter()
        .any(|c| c == "T0016"));
}

#[test]
fn neg_lateinit_nullable() {
    assert!(type_codes_for("neg_lateinit_nullable.kt")
        .iter()
        .any(|c| c == "T0017"));
}

#[test]
fn neg_accessor_return_type_mismatch() {
    assert!(type_codes_for("neg_accessor_return_type_mismatch.kt")
        .iter()
        .any(|c| c == "T0018"));
}

#[test]
fn neg_when_not_exhaustive() {
    assert!(type_codes_for("neg_when_not_exhaustive.kt")
        .iter()
        .any(|c| c == "T0019"));
}

#[test]
fn neg_var_not_definitely_assigned() {
    assert!(type_codes_for("neg_var_not_definitely_assigned.kt")
        .iter()
        .any(|c| c == "T0020"));
}

#[test]
fn neg_reified_requires_inline() {
    assert!(type_codes_for("neg_reified_requires_inline.kt")
        .iter()
        .any(|c| c == "T0023"));
}

#[test]
fn neg_inline_modifier_outside_inline() {
    assert!(type_codes_for("neg_inline_modifier_outside_inline.kt")
        .iter()
        .any(|c| c == "T0026"));
}

#[test]
fn neg_vararg_misuse() {
    assert!(type_codes_for("neg_vararg_misuse.kt")
        .iter()
        .any(|c| c == "T0025"));
}

#[test]
fn neg_declaration_variance_violation() {
    assert!(type_codes_for("neg_declaration_variance_violation.kt")
        .iter()
        .any(|c| c == "T0024"));
}

#[test]
fn neg_definitely_non_null() {
    assert!(type_codes_for("neg_definitely_non_null.kt")
        .iter()
        .any(|c| c == "T0027"));
}

#[test]
fn neg_unchecked_cast() {
    assert!(type_codes_for("neg_unchecked_cast.kt")
        .iter()
        .any(|c| c == "T0028"));
}

#[test]
fn neg_infix_modifier_required() {
    assert!(type_codes_for("neg_infix_modifier_required.kt")
        .iter()
        .any(|c| c == "T0029"));
}

#[test]
fn neg_unresolved_label() {
    assert!(type_codes_for("neg_unresolved_label.kt")
        .iter()
        .any(|c| c == "T0030"));
}

#[test]
fn neg_private_class_member_from_outside() {
    assert!(type_codes_for("neg_private_class_member_from_outside.kt")
        .iter()
        .any(|c| c == "T0031"));
}

#[test]
fn neg_protected_member_from_unrelated() {
    assert!(type_codes_for("neg_protected_member_from_unrelated.kt")
        .iter()
        .any(|c| c == "T0031"));
}

#[test]
fn pos_protected_member_from_subclass() {
    use klio_span::SourceMap;
    let src = r#"
        open class Base {
            protected fun greet(): String = "hi"
        }
        class Sub : Base() {
            fun call(): String = greet()
            fun callOnThis(): String = this.greet()
        }
        fun main() { println(Sub().call()) }
    "#;
    let mut map = SourceMap::new();
    let id = map.add("pos.kt", src.to_string());
    let owned = map.get(id).source.clone();
    let toks = Lexer::new(id, &owned).tokenize();
    let (ast, _) = Parser::new(id, &owned, &toks.tokens).parse_file();
    let r = klio_resolver::resolve(&ast);
    let tc = klio_typeck::typecheck(&ast, &r);
    let codes: Vec<_> = tc
        .diagnostics
        .diagnostics()
        .iter()
        .filter_map(|d| d.legacy_code.map(String::from))
        .collect();
    assert!(!codes.iter().any(|c| c == "T0031"),
        "unexpected T0031 on subclass `protected` access: {codes:?}");
}

#[test]
fn pos_private_member_same_class() {
    use klio_span::SourceMap;
    let src = r#"
        class Box(val n: Int) {
            private fun secret(): Int = n * 2
            fun expose(): Int = secret()
        }
        fun main() { println(Box(3).expose()) }
    "#;
    let mut map = SourceMap::new();
    let id = map.add("pos.kt", src.to_string());
    let owned = map.get(id).source.clone();
    let toks = Lexer::new(id, &owned).tokenize();
    let (ast, _) = Parser::new(id, &owned, &toks.tokens).parse_file();
    let r = klio_resolver::resolve(&ast);
    let tc = klio_typeck::typecheck(&ast, &r);
    let codes: Vec<_> = tc
        .diagnostics
        .diagnostics()
        .iter()
        .filter_map(|d| d.legacy_code.map(String::from))
        .collect();
    assert!(!codes.iter().any(|c| c == "T0031"),
        "unexpected T0031 on same-class `private` access: {codes:?}");
}

#[test]
fn pos_internal_treated_as_public() {
    use klio_span::SourceMap;
    let src = r#"
        internal fun helper(): Int = 7
        internal class Bag(val n: Int)
        fun main() { println(helper() + Bag(3).n) }
    "#;
    let mut map = SourceMap::new();
    let id = map.add("pos.kt", src.to_string());
    let owned = map.get(id).source.clone();
    let toks = Lexer::new(id, &owned).tokenize();
    let (ast, _) = Parser::new(id, &owned, &toks.tokens).parse_file();
    let r = klio_resolver::resolve(&ast);
    let tc = klio_typeck::typecheck(&ast, &r);
    let codes: Vec<_> = tc
        .diagnostics
        .diagnostics()
        .iter()
        .filter_map(|d| d.legacy_code.map(String::from))
        .collect();
    assert!(!codes.iter().any(|c| c == "T0031" || c == "T0032"),
        "unexpected visibility diagnostic on `internal`: {codes:?}");
}

#[test]
fn neg_private_top_level_cross_file() {
    use klio_span::SourceMap;
    let src_a = r#"
        private fun hidden(): Int = 42
        fun helperA(): Int = hidden()
    "#;
    let src_b = r#"
        fun main() { println(hidden()) }
    "#;
    let mut map = SourceMap::new();
    let id_a = map.add("a.kt", src_a.to_string());
    let id_b = map.add("b.kt", src_b.to_string());
    let src_a_owned = map.get(id_a).source.clone();
    let src_b_owned = map.get(id_b).source.clone();
    let toks_a = Lexer::new(id_a, &src_a_owned).tokenize();
    let toks_b = Lexer::new(id_b, &src_b_owned).tokenize();
    let (ast_a, _) = Parser::new(id_a, &src_a_owned, &toks_a.tokens).parse_file();
    let (ast_b, _) = Parser::new(id_b, &src_b_owned, &toks_b.tokens).parse_file();
    // Merge into a single synthetic file so the type checker sees both
    // declarations in one analysis unit while keeping their original
    // spans (and thus their FileId). The visibility check keys off
    // `Span::file`, not declaration order, so this exposes the
    // cross-file rule.
    let mut merged = ast_a.clone();
    merged.decls.extend(ast_b.decls.iter().cloned());
    let r = klio_resolver::resolve(&merged);
    let tc = klio_typeck::typecheck(&merged, &r);
    let codes: Vec<_> = tc
        .diagnostics
        .diagnostics()
        .iter()
        .filter_map(|d| d.legacy_code.map(String::from))
        .collect();
    assert!(codes.iter().any(|c| c == "T0032"),
        "expected T0032 on private top-level fn used across files: {codes:?}");
}

#[test]
fn neg_const_val_not_toplevel() {
    assert!(type_codes_for("neg_const_val_not_toplevel.kt")
        .iter()
        .any(|c| c == "T0033"));
}

#[test]
fn neg_const_val_non_const_init() {
    assert!(type_codes_for("neg_const_val_non_const_init.kt")
        .iter()
        .any(|c| c == "T0034"));
}

#[test]
fn neg_const_val_bad_type() {
    assert!(type_codes_for("neg_const_val_bad_type.kt")
        .iter()
        .any(|c| c == "T0034"));
}

#[test]
fn neg_value_class_open() {
    assert!(type_codes_for("neg_value_class_open.kt")
        .iter()
        .any(|c| c == "T0035"));
}

#[test]
fn neg_value_class_data() {
    assert!(type_codes_for("neg_value_class_data.kt")
        .iter()
        .any(|c| c == "T0035"));
}

#[test]
fn neg_value_class_two_vals() {
    assert!(type_codes_for("neg_value_class_two_vals.kt")
        .iter()
        .any(|c| c == "T0035"));
}

#[test]
fn neg_value_class_var() {
    assert!(type_codes_for("neg_value_class_var.kt")
        .iter()
        .any(|c| c == "T0035"));
}

#[test]
fn neg_value_class_init_block() {
    assert!(type_codes_for("neg_value_class_init_block.kt")
        .iter()
        .any(|c| c == "T0035"));
}

#[test]
fn neg_annotation_class_body() {
    assert!(type_codes_for("neg_annotation_class_body.kt")
        .iter()
        .any(|c| c == "T0036"));
}

#[test]
fn neg_annotation_class_open() {
    assert!(type_codes_for("neg_annotation_class_open.kt")
        .iter()
        .any(|c| c == "T0036"));
}

#[test]
fn neg_annotation_class_param_type() {
    assert!(type_codes_for("neg_annotation_class_param_type.kt")
        .iter()
        .any(|c| c == "T0037"));
}

#[test]
fn neg_recursive_typealias() {
    assert!(type_codes_for("neg_recursive_typealias.kt")
        .iter()
        .any(|c| c == "T0038"));
}

#[test]
fn neg_typealias_nested_in_class() {
    assert!(type_codes_for("neg_typealias_nested_in_class.kt")
        .iter()
        .any(|c| c == "T0039"));
}

#[test]
fn neg_extension_property_initializer() {
    assert!(type_codes_for("neg_extension_property_initializer.kt")
        .iter()
        .any(|c| c == "T0040"));
}

#[test]
fn neg_extension_property_delegate() {
    assert!(type_codes_for("neg_extension_property_delegate.kt")
        .iter()
        .any(|c| c == "T0041"));
}

#[test]
fn neg_extension_property_needs_accessor() {
    assert!(type_codes_for("neg_extension_property_needs_accessor.kt")
        .iter()
        .any(|c| c == "T0042"));
}

#[test]
fn neg_delegation_to_class() {
    assert!(type_codes_for("neg_delegation_to_class.kt")
        .iter()
        .any(|c| c == "T0043"));
}

#[test]
fn neg_delegation_type_mismatch() {
    assert!(type_codes_for("neg_delegation_type_mismatch.kt")
        .iter()
        .any(|c| c == "T0044"));
}

#[test]
fn neg_data_object_equals() {
    assert!(type_codes_for("neg_data_object_equals.kt")
        .iter()
        .any(|c| c == "T0045"));
}

#[test]
fn neg_field_outside_accessor() {
    assert!(type_codes_for("neg_field_outside_accessor.kt")
        .iter()
        .any(|c| c == "T0046"));
}

#[test]
fn neg_field_in_extension_property() {
    assert!(type_codes_for("neg_field_in_extension_property.kt")
        .iter()
        .any(|c| c == "T0046"));
}

#[test]
fn neg_spread_requires_vararg() {
    assert!(type_codes_for("neg_spread_requires_vararg.kt")
        .iter()
        .any(|c| c == "T0047"));
}

#[test]
fn neg_tailrec_non_tail() {
    assert!(type_codes_for("neg_tailrec_non_tail.kt")
        .iter()
        .any(|c| c == "T0048"));
}

#[test]
fn neg_tailrec_no_calls() {
    assert!(type_codes_for("neg_tailrec_no_calls.kt")
        .iter()
        .any(|c| c == "T0049"));
}

#[test]
fn neg_enum_final_override() {
    assert!(type_codes_for("neg_enum_final_override.kt")
        .iter()
        .any(|c| c == "T0050"));
}

#[test]
fn neg_throwable_type_params() {
    assert!(type_codes_for("neg_throwable_type_params.kt")
        .iter()
        .any(|c| c == "T0051"));
}

#[test]
fn neg_tailrec_on_open() {
    assert!(type_codes_for("neg_tailrec_on_open.kt")
        .iter()
        .any(|c| c == "T0057"));
}

#[test]
fn neg_data_class_copy_override() {
    assert!(type_codes_for("neg_data_class_copy_override.kt")
        .iter()
        .any(|c| c == "T0059"));
}

#[test]
fn neg_data_class_component_override() {
    assert!(type_codes_for("neg_data_class_component_override.kt")
        .iter()
        .any(|c| c == "T0058"));
}

#[test]
fn neg_secondary_ctor_cycle() {
    assert!(type_codes_for("neg_secondary_ctor_cycle.kt")
        .iter()
        .any(|c| c == "T0060"));
}

#[test]
fn neg_data_class_no_property() {
    assert!(type_codes_for("neg_data_class_no_property.kt")
        .iter()
        .any(|c| c == "T0061"));
}

#[test]
fn neg_data_class_vararg_property() {
    assert!(type_codes_for("neg_data_class_vararg_property.kt")
        .iter()
        .any(|c| c == "T0062"));
}

#[test]
fn neg_annotation_array_bad_element() {
    assert!(type_codes_for("neg_annotation_array_bad_element.kt")
        .iter()
        .any(|c| c == "T0037"));
}

#[test]
fn neg_inline_property_initializer() {
    assert!(type_codes_for("neg_inline_property_initializer.kt")
        .iter()
        .any(|c| c == "T0053"));
}

#[test]
fn neg_no_backing_field_initializer() {
    assert!(type_codes_for("neg_no_backing_field_initializer.kt")
        .iter()
        .any(|c| c == "T0054"));
}

#[test]
fn neg_inline_param_leak() {
    assert!(type_codes_for("neg_inline_param_leak.kt")
        .iter()
        .any(|c| c == "T0055"));
}

#[test]
fn neg_crossinline_param_leak() {
    assert!(type_codes_for("neg_crossinline_param_leak.kt")
        .iter()
        .any(|c| c == "T0056"));
}

#[test]
fn neg_private_primary_ctor_cross_file() {
    use klio_span::SourceMap;
    let src_a = "class Foo private constructor(val x: Int)\n";
    let src_b = "fun main() { Foo(1) }\n";
    let mut map = SourceMap::new();
    let id_a = map.add("a.kt", src_a.to_string());
    let id_b = map.add("b.kt", src_b.to_string());
    let src_a_owned = map.get(id_a).source.clone();
    let src_b_owned = map.get(id_b).source.clone();
    let toks_a = Lexer::new(id_a, &src_a_owned).tokenize();
    let toks_b = Lexer::new(id_b, &src_b_owned).tokenize();
    let (ast_a, _) = Parser::new(id_a, &src_a_owned, &toks_a.tokens).parse_file();
    let (ast_b, _) = Parser::new(id_b, &src_b_owned, &toks_b.tokens).parse_file();
    let mut merged = ast_a.clone();
    merged.decls.extend(ast_b.decls.iter().cloned());
    let r = klio_resolver::resolve(&merged);
    let tc = klio_typeck::typecheck(&merged, &r);
    let codes: Vec<_> = tc
        .diagnostics
        .diagnostics()
        .iter()
        .filter_map(|d| d.legacy_code.map(String::from))
        .collect();
    assert!(codes.iter().any(|c| c == "T0031"),
        "expected T0031 on private primary-ctor cross-file ctor call: {codes:?}");
}

#[test]
fn neg_private_setter_cross_file() {
    use klio_span::SourceMap;
    let src_a = "var counter: Int = 0\n    private set\n";
    let src_b = "fun main() { counter = 5 }\n";
    let mut map = SourceMap::new();
    let id_a = map.add("a.kt", src_a.to_string());
    let id_b = map.add("b.kt", src_b.to_string());
    let src_a_owned = map.get(id_a).source.clone();
    let src_b_owned = map.get(id_b).source.clone();
    let toks_a = Lexer::new(id_a, &src_a_owned).tokenize();
    let toks_b = Lexer::new(id_b, &src_b_owned).tokenize();
    let (ast_a, _) = Parser::new(id_a, &src_a_owned, &toks_a.tokens).parse_file();
    let (ast_b, _) = Parser::new(id_b, &src_b_owned, &toks_b.tokens).parse_file();
    let mut merged = ast_a.clone();
    merged.decls.extend(ast_b.decls.iter().cloned());
    let r = klio_resolver::resolve(&merged);
    let tc = klio_typeck::typecheck(&merged, &r);
    let codes: Vec<_> = tc
        .diagnostics
        .diagnostics()
        .iter()
        .filter_map(|d| d.legacy_code.map(String::from))
        .collect();
    assert!(codes.iter().any(|c| c == "T0032"),
        "expected T0032 on private-setter cross-file write: {codes:?}");
}

#[test]
fn neg_published_api_missing() {
    assert!(type_codes_for("neg_published_api_missing.kt")
        .iter()
        .any(|c| c == "T0031"));
}

#[test]
fn neg_diamond_class_interface() {
    assert!(type_codes_for("neg_diamond_class_interface.kt").iter().any(|c| c == "T0013"));
}

#[test]
fn neg_diamond_abstract_concrete() {
    assert!(type_codes_for("neg_diamond_abstract_concrete.kt").iter().any(|c| c == "T0013"));
}

#[test]
fn neg_override_return_type() {
    assert!(type_codes_for("neg_override_return_type.kt").iter().any(|c| c == "T0065"));
}

#[test]
fn neg_override_property_mutability() {
    assert!(type_codes_for("neg_override_property_mutability.kt").iter().any(|c| c == "T0066"));
}

#[test]
fn neg_override_property_type() {
    assert!(type_codes_for("neg_override_property_type.kt").iter().any(|c| c == "T0067"));
}

#[test]
fn neg_override_visibility_stronger() {
    assert!(type_codes_for("neg_override_visibility_stronger.kt").iter().any(|c| c == "T0068"));
}

#[test]
fn neg_sealed_local_inheritor() {
    assert!(type_codes_for("neg_sealed_local_inheritor.kt").iter().any(|c| c == "T0071"));
}

#[test]
fn neg_sealed_anonymous_inheritor() {
    assert!(type_codes_for("neg_sealed_anonymous_inheritor.kt").iter().any(|c| c == "T0071"));
}

#[test]
fn neg_private_open() {
    assert!(type_codes_for("neg_private_open.kt").iter().any(|c| c == "T0070"));
}

#[test]
fn neg_private_override() {
    assert!(type_codes_for("neg_private_override.kt").iter().any(|c| c == "T0070"));
}

#[test]
fn neg_inherit_from_final() {
    assert!(type_codes_for("neg_inherit_from_final.kt").iter().any(|c| c == "T0063"));
}

#[test]
fn neg_inherit_from_object() {
    assert!(type_codes_for("neg_inherit_from_object.kt").iter().any(|c| c == "T0064"));
}

#[test]
fn neg_data_class_open() {
    assert!(type_codes_for("neg_data_class_open.kt").iter().any(|c| c == "T0072"));
}

#[test]
fn neg_enum_class_abstract() {
    assert!(type_codes_for("neg_enum_class_abstract.kt").iter().any(|c| c == "T0072"));
}

#[test]
fn pos_definitely_non_null_on_type_param() {
    use klio_span::SourceMap;
    let src = "fun <T> id(x: T & Any): T & Any = x\nfun main() { println(id(7)) }\n";
    let mut map = SourceMap::new();
    let id = map.add("pos.kt", src.to_string());
    let owned = map.get(id).source.clone();
    let toks = Lexer::new(id, &owned).tokenize();
    let (ast, _) = Parser::new(id, &owned, &toks.tokens).parse_file();
    let r = klio_resolver::resolve(&ast);
    let tc = klio_typeck::typecheck(&ast, &r);
    let codes: Vec<_> = tc
        .diagnostics
        .diagnostics()
        .iter()
        .filter_map(|d| d.legacy_code.map(String::from))
        .collect();
    assert!(!codes.iter().any(|c| c == "T0027"), "unexpected T0027 on type parameter use: {codes:?}");
}

#[test]
fn neg_label_on_arbitrary_expr() {
    assert!(
        type_codes_for("neg_label_on_arbitrary_expr.kt")
            .iter()
            .any(|c| c == "T0078")
    );
}

#[test]
fn neg_property_init_cycle() {
    assert!(
        type_codes_for("neg_property_init_cycle.kt")
            .iter()
            .any(|c| c == "T0076")
    );
}

#[test]
fn neg_reference_equality_distinct() {
    assert!(
        type_codes_for("neg_reference_equality_distinct.kt")
            .iter()
            .any(|c| c == "T0081")
    );
}

#[test]
fn neg_anonymous_object_escapes_multi() {
    assert!(
        type_codes_for("neg_anonymous_object_escapes_multi.kt")
            .iter()
            .any(|c| c == "T0085")
    );
}

#[test]
fn neg_spread_type_mismatch() {
    assert!(
        type_codes_for("neg_spread_type_mismatch.kt")
            .iter()
            .any(|c| c == "T0086")
    );
}

#[test]
fn neg_as_safe_type_param() {
    assert!(
        type_codes_for("neg_as_safe_type_param.kt")
            .iter()
            .any(|c| c == "T0083")
    );
}

#[test]
fn neg_value_equality_distinct() {
    assert!(
        type_codes_for("neg_value_equality_distinct.kt")
            .iter()
            .any(|c| c == "T0082")
    );
}

#[test]
fn neg_method_reads_nonproperty_ctor_param() {
    assert!(
        type_codes_for("neg_method_reads_nonproperty_ctor_param.kt")
            .iter()
            .any(|c| c == "T0075")
    );
}
