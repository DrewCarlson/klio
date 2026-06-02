//! Kotlin parser.
//!
//! Hand-written recursive descent over a [`Token`] stream produced by
//! `klio-lexer`. Expression grammar is implemented as a Pratt parser with
//! precedence levels lifted directly from spec §7 (Expressions):
//!
//! ```text
//!   disjunction      ||
//!   conjunction      &&
//!   equality         == != === !==
//!   comparison       < > <= >=
//!   named_checks     in !in is !is        (in/is wired; type-RHS deferred)
//!   elvis            ?:
//!   infix_function   (deferred)
//!   range            .. ..<
//!   additive         + -
//!   multiplicative   * / %
//!   type_rhs         as as?                (deferred)
//!   prefix           + - ! ++ --
//!   postfix          ++ -- . ?. !! () []
//!   primary
//! ```
//!
//! Assignment is parsed at the statement level (Kotlin assignments are not
//! expressions). Newlines act as soft separators: inside parens/braces/brackets
//! they are skipped freely; at statement positions they terminate a statement.

use klio_ast::{
    Accessor, Annotation, AnnotationUseSite, AssignOp, BinOp, Block, Catch, Class, ClassParam,
    CtorDelegation, Decl, EnumEntry, Expr, FunctionBody, Function, FunctionTypeRef, Ident,
    ImportDecl, KotlinFile, ObjectDecl, PackageHeader, Param, PostfixOp, Property, SecondaryCtor,
    Stmt, StringPart, TypeAlias, TypeArg, TypeParam, TypeRef, UnOp, Variance, Visibility,
    WhenBinding, WhenBranch, WhenPattern, WhenPatternKind, WhereBound,
};
use klio_diagnostics::{Diagnostic, DiagnosticSink};
use klio_lexer::{Keyword, Token, TokenKind};
use klio_span::{FileId, Span};

pub struct Parser<'src, 'tok> {
    src: &'src str,
    tokens: &'tok [Token],
    pos: usize,
    pub diagnostics: DiagnosticSink,
    /// When `true`, postfix expression parsing will not attach a trailing
    /// `{ … }` lambda. Set while reading the delegate expression in a
    /// supertype-list entry of the form `: I by expr`, so the class body's
    /// opening brace isn't swallowed as `expr { … }`.
    suppress_trailing_lambda: bool,
    /// When `true`, `parse_simple_type` does NOT fold trailing
    /// `.Ident` segments into a qualified type path. Set while
    /// parsing an extension / anonymous-function *receiver* type,
    /// where the trailing `.name` is the function name (the
    /// receiver-fold loop separates the qualifier itself). Keeps
    /// qualified type refs working everywhere else.
    suppress_qualified_path: bool,
    /// Per-token flag: `true` when the token sits inside an unclosed
    /// `(` or `[` (not `{`). Kotlin treats newlines as soft inside
    /// round/square brackets — an expression may break before or
    /// after a binary/infix operator there — but significant inside
    /// `{ … }` blocks. Precomputed so it is O(1) regardless of how
    /// the cursor advances.
    nl_soft: Vec<bool>,
}

mod parse;

#[derive(Default, Clone, Copy)]
struct ClassModifiers {
    is_data: bool,
    is_companion: bool,
    is_enum: bool,
    is_sealed: bool,
    is_open: bool,
    is_abstract: bool,
    is_inner: bool,
    is_fun_interface: bool,
    is_value: bool,
    is_annotation: bool,
    is_expect: bool,
    is_actual: bool,
}

#[derive(Default, Clone)]
struct ModifierFlags {
    is_data: bool,
    is_companion: bool,
    is_enum: bool,
    is_sealed: bool,
    is_open: bool,
    is_override: bool,
    is_abstract: bool,
    is_inner: bool,
    is_lateinit: bool,
    is_operator: bool,
    is_inline: bool,
    is_infix: bool,
    is_const: bool,
    is_tailrec: bool,
    is_value: bool,
    is_annotation: bool,
    is_suspend: bool,
    is_expect: bool,
    is_actual: bool,
    /// Span of the `suspend` modifier when one was consumed. Used to point
    /// the user at the modifier when emitting the rejection diagnostic on
    /// constructors / accessors / anonymous functions / delegation
    /// operators.
    suspend_span: Option<Span>,
    /// Span of the `inline` modifier when one was consumed. Used to emit a
    /// deprecation warning when the source wrote `inline class`, since
    /// `inline class` is an alias for `value class`.
    inline_span: Option<Span>,
    visibility: Visibility,
    annotations: Vec<Annotation>,
}

/// Identifiers that are reserved soft modifiers / contextual keywords and
/// must never be tentatively consumed as infix function names. Without this
/// guard, declarations like `val x = foo\nprivate fun ...` could be misread
/// because the previous statement has no newline separator.
fn is_valid_infix_name(name: &str) -> bool {
    !matches!(
        name,
        "private" | "public" | "protected" | "internal"
            | "open" | "abstract" | "final" | "override" | "sealed"
            | "inner" | "lateinit" | "operator" | "infix" | "inline"
            | "tailrec" | "external" | "suspend" | "annotation" | "const"
            | "companion" | "data" | "enum" | "by" | "where" | "get" | "set"
            | "field" | "value" | "actual" | "expect" | "vararg" | "crossinline"
            | "noinline" | "reified" | "out"
    )
}

fn is_trailing_lambda_callable(expr: &Expr) -> bool {
    matches!(
        expr,
        Expr::Path { .. } | Expr::Call { .. } | Expr::Member { .. }
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use klio_lexer::Lexer;
    use klio_span::SourceMap;

    fn parse(src: &str) -> (klio_ast::KotlinFile, DiagnosticSink) {
        let mut map = SourceMap::new();
        let id = map.add("t.kt", src);
        let owned = map.get(id).source.clone();
        let lexed = Lexer::new(id, &owned).tokenize();
        assert!(!lexed.diagnostics.has_errors(),
            "lex diagnostics: {:?}", lexed.diagnostics.diagnostics());
        Parser::new(id, &owned, &lexed.tokens).parse_file()
    }

    #[test]
    fn parses_hello_world() {
        let (file, diags) = parse("fun main() { println(1 + 1) }");
        assert!(!diags.has_errors());
        assert_eq!(file.decls.len(), 1);
        assert!(matches!(file.decls[0], klio_ast::Decl::Function(ref f) if f.name.name == "main"));
    }

    #[test]
    fn package_and_imports() {
        let (file, diags) = parse(
            "package a.b.c\nimport kotlin.math.PI\nimport kotlin.collections.*\n"
        );
        assert!(!diags.has_errors());
        let pkg = file.package.expect("package");
        assert_eq!(pkg.path.iter().map(|s| s.name.as_str()).collect::<Vec<_>>(), vec!["a", "b", "c"]);
        assert_eq!(file.imports.len(), 2);
        assert!(file.imports[1].wildcard);
        assert!(file.imports[1].alias.is_none());
    }

    #[test]
    fn import_with_backticked_segment() {
        let src = "import kotlin.collections.`Map`\n";
        let (file, diags) = parse(src);
        assert!(!diags.has_errors(), "diags: {:?}", diags.diagnostics());
        let imp = &file.imports[0];
        let segs: Vec<_> = imp.path.iter().map(|i| i.name.as_str()).collect();
        assert_eq!(segs, vec!["kotlin", "collections", "Map"]);
    }

    #[test]
    fn import_with_backticked_alias() {
        let src = "import kotlin.math.PI as `tau-ish`\n";
        let (file, diags) = parse(src);
        assert!(!diags.has_errors(), "diags: {:?}", diags.diagnostics());
        let alias = file.imports[0].alias.as_ref().expect("alias");
        assert_eq!(alias.name, "tau-ish");
    }

    #[test]
    fn import_wildcard_with_alias_is_rejected() {
        let (_file, diags) = parse("import kotlin.collections.* as col\n");
        let codes: Vec<_> = diags.diagnostics().iter().filter_map(klio_diagnostics::Diagnostic::code).collect();
        assert!(codes.contains(&"P0044"), "expected P0044, got {codes:?}");
    }

    #[test]
    fn class_literal_with_type_arguments_is_rejected() {
        let (_file, diags) = parse("fun main() { val k = Box<Int>::class }\n");
        let codes: Vec<_> = diags.diagnostics().iter().filter_map(klio_diagnostics::Diagnostic::code).collect();
        assert!(codes.contains(&"T0104"), "expected T0104, got {codes:?}");
    }

    #[test]
    fn expression_body_function() {
        let (file, diags) = parse("fun sq(x: Int): Int = x * x\n");
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        assert!(matches!(f.body, Some(klio_ast::FunctionBody::Expr(_))));
    }

    #[test]
    fn pratt_precedence() {
        // `2 + 3 * 4` must parse as `2 + (3 * 4)`.
        let (file, _) = parse("fun f() { val x = 2 + 3 * 4 }");
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &b.stmts[0] else { panic!() };
        let init = p.init.as_ref().unwrap();
        let klio_ast::Expr::Binary { op: outer, rhs, .. } = init else { panic!() };
        assert_eq!(*outer, klio_ast::BinOp::Add);
        assert!(matches!(**rhs, klio_ast::Expr::Binary { op: klio_ast::BinOp::Mul, .. }));
    }

    #[test]
    fn assignment_is_a_statement() {
        let (file, diags) = parse("fun f() { var x = 0; x = 5 }");
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        assert!(matches!(b.stmts.last().unwrap(), klio_ast::Stmt::Assign { .. }));
    }

    #[test]
    fn compound_assignment_recognized() {
        let (file, _) = parse("fun f() { var x = 0; x += 5 }");
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        let klio_ast::Stmt::Assign { op, .. } = b.stmts.last().unwrap() else { panic!() };
        assert_eq!(*op, klio_ast::AssignOp::Add);
    }

    #[test]
    fn string_template_parts() {
        let (file, diags) = parse(r#"fun f() { val s = "x=$x and ${x + 1}" }"#);
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &b.stmts[0] else { panic!() };
        let klio_ast::Expr::StringTemplate { parts, .. } = p.init.as_ref().unwrap() else { panic!() };
        assert_eq!(parts.len(), 4);
        assert!(matches!(parts[0], klio_ast::StringPart::Text(_)));
        assert!(matches!(parts[1], klio_ast::StringPart::ShortInterp(_)));
        assert!(matches!(parts[2], klio_ast::StringPart::Text(_)));
        assert!(matches!(parts[3], klio_ast::StringPart::Interp(_)));
    }

    #[test]
    fn if_else_chain() {
        let (_file, diags) = parse(r"
            fun f(x: Int): Int {
                return if (x < 0) -1 else if (x == 0) 0 else 1
            }
        ");
        assert!(!diags.has_errors());
    }

    #[test]
    fn while_with_break_and_continue() {
        let (file, diags) = parse(r"
            fun f() {
                var i = 0
                while (i < 10) {
                    if (i == 3) { i = i + 1; continue }
                    if (i == 7) break
                    i = i + 1
                }
            }
        ");
        assert!(!diags.has_errors());
        let _ = file;
    }

    #[test]
    fn for_loop_parses() {
        let (file, diags) = parse("fun f() { for (k in 1..3) { println(k) } }");
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        assert!(matches!(b.stmts[0], klio_ast::Stmt::Expr(klio_ast::Expr::For { .. })));
    }

    #[test]
    fn member_chain_and_safe_call() {
        let (file, _) = parse("fun f() { val x = a.b?.c }");
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &b.stmts[0] else { panic!() };
        let klio_ast::Expr::Member { safe, .. } = p.init.as_ref().unwrap() else { panic!() };
        assert!(*safe);
    }

    #[test]
    fn diagnostic_on_missing_close_paren() {
        let (_file, diags) = parse("fun main() { println(1 + 2 \n}\n");
        assert!(diags.has_errors());
    }

    fn property_type(file: &klio_ast::KotlinFile) -> &klio_ast::TypeRef {
        let klio_ast::Decl::Property(p) = &file.decls[0] else { panic!("expected property") };
        p.ty.as_ref().expect("property type annotation")
    }

    #[test]
    fn function_type_simple() {
        let (file, diags) = parse("val f: (Int) -> Int = { it * 2 }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let ty = property_type(&file);
        let f = ty.function.as_ref().expect("function-type metadata");
        assert!(f.receiver.is_none());
        assert!(!f.is_suspend);
        assert!(!ty.nullable);
        assert_eq!(f.params.len(), 1);
        assert_eq!(f.params[0].name.name, "Int");
        assert_eq!(f.ret.name.name, "Int");
    }

    #[test]
    fn function_type_empty_params() {
        let (file, diags) = parse("val f: () -> Unit = { }\n");
        assert!(!diags.has_errors());
        let ty = property_type(&file);
        let f = ty.function.as_ref().unwrap();
        assert!(f.params.is_empty());
        assert_eq!(f.ret.name.name, "Unit");
    }

    #[test]
    fn function_type_multi_param() {
        let (file, diags) =
            parse("fun apply(f: (Int, String) -> Boolean): Boolean = f(1, \"x\")\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(fn_) = &file.decls[0] else { panic!() };
        let p_ty = &fn_.params[0].ty;
        let f = p_ty.function.as_ref().unwrap();
        assert_eq!(f.params.len(), 2);
        assert_eq!(f.params[0].name.name, "Int");
        assert_eq!(f.params[1].name.name, "String");
        assert_eq!(f.ret.name.name, "Boolean");
    }

    #[test]
    fn function_type_nullable_whole() {
        let (file, diags) = parse("val g: ((Int) -> Int)? = null\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let ty = property_type(&file);
        assert!(ty.nullable);
        let f = ty.function.as_ref().unwrap();
        assert_eq!(f.params.len(), 1);
        assert_eq!(f.ret.name.name, "Int");
    }

    #[test]
    fn function_type_right_associative() {
        let (file, diags) = parse("val h: (Int) -> (Int) -> Int = { x -> { y -> x + y } }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let ty = property_type(&file);
        let outer = ty.function.as_ref().unwrap();
        assert_eq!(outer.params.len(), 1);
        let inner = outer.ret.function.as_ref().expect("nested function type");
        assert_eq!(inner.params.len(), 1);
        assert_eq!(inner.ret.name.name, "Int");
    }

    #[test]
    fn function_type_with_receiver() {
        let (file, diags) = parse("val r: String.(Int) -> Int = { 0 }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let ty = property_type(&file);
        let f = ty.function.as_ref().unwrap();
        let recv = f.receiver.as_ref().expect("receiver type");
        assert_eq!(recv.name.name, "String");
        assert_eq!(f.params.len(), 1);
        assert_eq!(f.params[0].name.name, "Int");
    }

    #[test]
    fn suspend_modifier_on_fun_sets_flag() {
        let (file, diags) = parse("suspend fun f() {}\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        assert!(f.is_suspend);
    }

    #[test]
    fn suspend_modifier_on_non_suspend_fun_absent() {
        let (file, diags) = parse("fun f() {}\n");
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        assert!(!f.is_suspend);
    }

    #[test]
    fn suspend_modifier_on_secondary_ctor_rejected() {
        let (_file, diags) = parse(
            "class C { suspend constructor() {} }\n",
        );
        assert!(
            diags.diagnostics().iter().any(|d| d.code() == Some("T0114")),
            "expected T0114: {:?}", diags.diagnostics()
        );
    }

    #[test]
    fn suspend_modifier_on_property_accepted_inert() {
        // The stdlib `coroutineContext` intrinsic is a `suspend val`;
        // klio accepts the (inert) modifier rather than erroring.
        let (file, diags) = parse("suspend val x = 1\n");
        assert!(
            !diags.diagnostics().iter().any(|d| d.code() == Some("T0114")),
            "unexpected T0114: {:?}", diags.diagnostics()
        );
        assert!(matches!(&file.decls[0], klio_ast::Decl::Property(_)));
    }

    #[test]
    fn function_type_suspend_accepted() {
        let (file, diags) = parse("val s: suspend (Int) -> Int = { it }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let ty = property_type(&file);
        let f = ty.function.as_ref().unwrap();
        assert!(f.is_suspend);
        assert_eq!(f.params.len(), 1);
    }

    #[test]
    fn function_type_named_params_allowed() {
        let (file, diags) = parse("val f: (x: Int, y: Int) -> Int = { a, b -> a + b }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let ty = property_type(&file);
        let f = ty.function.as_ref().unwrap();
        assert_eq!(f.params.len(), 2);
        assert_eq!(f.params[0].name.name, "Int");
    }

    #[test]
    fn function_type_malformed_empty_arrow() {
        // A parenthesized empty type list without `->` is ill-formed.
        let (_file, diags) = parse("val f: () = 1\n");
        assert!(diags.has_errors());
    }

    #[test]
    fn function_type_parenthesized_single_type_still_parses() {
        // `(Int)` without `->` is a parenthesized type — should round-trip
        // to a plain `Int` ref.
        let (file, diags) = parse("val x: (Int) = 1\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let ty = property_type(&file);
        assert!(ty.function.is_none());
        assert_eq!(ty.name.name, "Int");
    }

    #[test]
    fn recovers_from_top_level_garbage() {
        let (file, diags) = parse("@@@@\nfun main() { println(1) }\n");
        assert!(diags.has_errors());
        // We still recovered to parse `main`.
        assert!(file.decls.iter().any(|d| matches!(d, klio_ast::Decl::Function(f) if f.name.name == "main")));
    }

    // ---------- Phase B: visibility / annotations / when-binding / T & Any.

    #[test]
    fn visibility_modifiers_round_trip() {
        let (file, diags) = parse(
            "private fun a() {}\n\
             internal class B\n\
             protected val c: Int = 1\n\
             public fun d() {}\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let mut vis = Vec::new();
        for d in &file.decls {
            match d {
                klio_ast::Decl::Function(f) => vis.push((f.name.name.as_str(), f.visibility)),
                klio_ast::Decl::Class(c) => vis.push((c.name.name.as_str(), c.visibility)),
                klio_ast::Decl::Property(p) => vis.push((p.name.name.as_str(), p.visibility)),
                _ => {}
            }
        }
        assert_eq!(
            vis,
            vec![
                ("a", klio_ast::Visibility::Private),
                ("B", klio_ast::Visibility::Internal),
                ("c", klio_ast::Visibility::Protected),
                ("d", klio_ast::Visibility::Public),
            ]
        );
    }

    #[test]
    fn visibility_defaults_to_public() {
        let (file, diags) = parse("fun a() {}\n");
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        assert_eq!(f.visibility, klio_ast::Visibility::Public);
    }

    #[test]
    fn declaration_site_annotations_captured() {
        let (file, diags) = parse(
            "@Suppress(\"x\") @JvmStatic fun main() {}\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        assert_eq!(f.annotations.len(), 2);
        assert_eq!(f.annotations[0].path[0].name, "Suppress");
        assert_eq!(f.annotations[0].args.len(), 1);
        assert_eq!(f.annotations[1].path[0].name, "JvmStatic");
    }

    #[test]
    fn annotation_use_site_target() {
        let (file, diags) = parse(
            "class C(@field:Foo val x: Int)\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Class(c) = &file.decls[0] else { panic!() };
        let cp = &c.primary_params[0];
        assert_eq!(cp.annotations.len(), 1);
        assert_eq!(cp.annotations[0].use_site, Some(klio_ast::AnnotationUseSite::Field));
        assert_eq!(cp.annotations[0].path[0].name, "Foo");
    }

    #[test]
    fn annotation_array_form() {
        let (file, diags) = parse(
            "@field:[A B] val x: Int = 1\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Property(p) = &file.decls[0] else { panic!() };
        assert_eq!(p.annotations.len(), 2);
        assert!(p.annotations.iter().all(|a| a.use_site == Some(klio_ast::AnnotationUseSite::Field)));
        assert_eq!(p.annotations[0].path[0].name, "A");
        assert_eq!(p.annotations[1].path[0].name, "B");
    }

    #[test]
    fn when_subject_binding_parsed() {
        let (file, diags) = parse(
            "fun f(x: Any): Int = when (val v = x) { is Int -> v; else -> 0 }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Expr(e)) = &f.body else { panic!() };
        let klio_ast::Expr::When { subject, subject_binding, .. } = e else { panic!() };
        assert!(subject.is_some());
        let b = subject_binding.as_ref().expect("binding");
        assert_eq!(b.name.name, "v");
        assert!(b.ty.is_none());
    }

    #[test]
    fn when_without_binding_still_parses() {
        let (file, diags) = parse(
            "fun f(x: Int): Int = when (x) { 1 -> 1; else -> 0 }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Expr(e)) = &f.body else { panic!() };
        let klio_ast::Expr::When { subject, subject_binding, .. } = e else { panic!() };
        assert!(subject.is_some());
        assert!(subject_binding.is_none());
    }

    #[test]
    fn as_basic() {
        let (file, diags) = parse("fun f(x: Any): String = x as String\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Expr(e)) = &f.body else { panic!() };
        let klio_ast::Expr::As { ty, safe, .. } = e else { panic!("got {e:?}") };
        assert!(!*safe);
        assert_eq!(ty.name.name, "String");
    }

    #[test]
    fn as_safe() {
        let (file, diags) = parse("fun f(x: Any): String? = x as? String\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Expr(e)) = &f.body else { panic!() };
        let klio_ast::Expr::As { safe, ty, .. } = e else { panic!() };
        assert!(*safe);
        assert_eq!(ty.name.name, "String");
    }

    #[test]
    fn as_chains_left_associative() {
        let (file, diags) = parse("fun f(x: Any): Any = x as A as B\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Expr(e)) = &f.body else { panic!() };
        let klio_ast::Expr::As { expr: outer_expr, ty: outer_ty, .. } = e else { panic!() };
        assert_eq!(outer_ty.name.name, "B");
        let klio_ast::Expr::As { ty: inner_ty, .. } = outer_expr.as_ref() else { panic!() };
        assert_eq!(inner_ty.name.name, "A");
    }

    #[test]
    fn anon_fun_expr_body() {
        let (file, diags) = parse("fun main() { val f = fun(x: Int): Int = x + 1 }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &b.stmts[0] else { panic!() };
        let init = p.init.as_ref().unwrap();
        let klio_ast::Expr::AnonFun { params, return_ty, body, .. } = init else { panic!() };
        assert_eq!(params.len(), 1);
        assert_eq!(return_ty.as_ref().unwrap().name.name, "Int");
        assert!(matches!(body.as_deref(), Some(klio_ast::FunctionBody::Expr(_))));
    }

    #[test]
    fn anon_fun_block_body() {
        let (file, diags) = parse(
            "fun main() { val f = fun(x: Int): Int { return x * 2 } }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &b.stmts[0] else { panic!() };
        let klio_ast::Expr::AnonFun { body, .. } = p.init.as_ref().unwrap() else { panic!() };
        assert!(matches!(body.as_deref(), Some(klio_ast::FunctionBody::Block(_))));
    }

    #[test]
    fn anon_fun_optional_param_types() {
        let (file, diags) = parse(
            "fun main() { val f = fun(x: Int, y: Int) = x + y }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &b.stmts[0] else { panic!() };
        let klio_ast::Expr::AnonFun { params, .. } = p.init.as_ref().unwrap() else { panic!() };
        assert_eq!(params.len(), 2);
    }

    #[test]
    fn anon_fun_with_receiver() {
        let (file, diags) = parse(
            "fun main() { val f = fun Int.(): Int = this + 1 }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &f.body else { panic!() };
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &b.stmts[0] else { panic!() };
        let klio_ast::Expr::AnonFun { receiver_ty, .. } = p.init.as_ref().unwrap() else { panic!() };
        assert!(receiver_ty.is_some());
        assert_eq!(receiver_ty.as_ref().unwrap().name.name, "Int");
    }

    #[test]
    fn definitely_non_nullable_type_parsed() {
        let (file, diags) = parse(
            "fun <T> id(x: T & Any): T & Any = x\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        assert!(f.params[0].ty.definitely_non_null);
        assert!(f.return_type.as_ref().unwrap().definitely_non_null);
    }

    fn body_stmts(f: &klio_ast::Function) -> &[klio_ast::Stmt] {
        match f.body.as_ref().unwrap() {
            klio_ast::FunctionBody::Block(b) => &b.stmts,
            klio_ast::FunctionBody::Expr(_) => panic!("not block-bodied"),
        }
    }

    #[test]
    fn infix_call_user_defined() {
        let (file, diags) = parse(
            "infix fun Int.plus2(o: Int): Int = this + o\nfun main() { val r = 1 plus2 2 }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f0) = &file.decls[0] else { panic!() };
        assert!(f0.is_infix);
        let klio_ast::Decl::Function(main) = &file.decls[1] else { panic!() };
        let stmts = body_stmts(main);
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &stmts[0] else { panic!() };
        let init = p.init.as_ref().unwrap();
        let Expr::Call { callee, args, is_infix, .. } = init else { panic!("{init:?}") };
        assert!(*is_infix);
        assert_eq!(args.len(), 2);
        let Expr::Path { segments, .. } = callee.as_ref() else { panic!() };
        assert_eq!(segments[0].name, "plus2");
    }

    #[test]
    fn infix_call_no_newline_break() {
        // `a\nfoo b` MUST NOT parse as infix: the newline ends the
        // statement before the candidate ident.
        let (file, _) = parse("fun main() { val a = 1\nfoo(2) }\n");
        let klio_ast::Decl::Function(main) = &file.decls[0] else { panic!() };
        let stmts = body_stmts(main);
        assert_eq!(stmts.len(), 2);
        let klio_ast::Stmt::Decl(_) = &stmts[0] else { panic!() };
        let klio_ast::Stmt::Expr(Expr::Call { is_infix, .. }) = &stmts[1] else { panic!() };
        assert!(!*is_infix);
    }

    #[test]
    fn infix_call_chain_left_assoc() {
        let (file, diags) = parse(
            "infix fun Int.f(o: Int): Int = this\nfun main() { val r = 1 f 2 f 3 }\n",
        );
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(main) = &file.decls[1] else { panic!() };
        let stmts = body_stmts(main);
        let klio_ast::Stmt::Decl(klio_ast::Decl::Property(p)) = &stmts[0] else { panic!() };
        let init = p.init.as_ref().unwrap();
        // Expect ((1 f 2) f 3).
        let Expr::Call { args, .. } = init else { panic!() };
        assert!(matches!(&args[0], Expr::Call { .. }));
    }

    #[test]
    fn return_with_label() {
        let (file, diags) = parse("fun main() { foo@ run { return@foo 1 } }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(main) = &file.decls[0] else { panic!() };
        let stmts = body_stmts(main);
        let klio_ast::Stmt::Expr(Expr::Labeled { label, .. }) = &stmts[0] else { panic!() };
        assert_eq!(label.name, "foo");
    }

    #[test]
    fn break_with_label() {
        let (file, diags) = parse("fun main() { outer@ for (i in 1..3) { break@outer } }\n");
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(main) = &file.decls[0] else { panic!() };
        let stmts = body_stmts(main);
        let klio_ast::Stmt::Expr(Expr::Labeled { label, .. }) = &stmts[0] else { panic!() };
        assert_eq!(label.name, "outer");
    }

    #[test]
    fn continue_with_label() {
        let (_file, diags) = parse("fun main() { outer@ for (i in 1..3) { continue@outer } }\n");
        assert!(!diags.has_errors());
    }

    #[test]
    fn labeled_loop() {
        let (file, diags) = parse(
            "fun main() { L@ while (true) { break@L } }\n",
        );
        assert!(!diags.has_errors());
        let klio_ast::Decl::Function(main) = &file.decls[0] else { panic!() };
        let stmts = body_stmts(main);
        let klio_ast::Stmt::Expr(Expr::Labeled { label, expr, .. }) = &stmts[0] else { panic!() };
        assert_eq!(label.name, "L");
        assert!(matches!(expr.as_ref(), Expr::While { .. }));
    }

    #[test]
    fn labeled_lambda_via_run() {
        let (file, diags) = parse(
            "fun main() { foo@ run { return@foo } }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(main) = &file.decls[0] else { panic!() };
        let stmts = body_stmts(main);
        let klio_ast::Stmt::Expr(Expr::Labeled { label, expr, .. }) = &stmts[0] else { panic!() };
        assert_eq!(label.name, "foo");
        // The inner expression is `run { ... }` — a Call.
        assert!(matches!(expr.as_ref(), Expr::Call { .. }));
    }

    #[test]
    fn const_val_flag_captured() {
        let (file, diags) = parse("const val PI: Double = 3.14\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Property(p) = &file.decls[0] else { panic!() };
        assert!(p.is_const);
        assert!(!p.mutable);
    }

    #[test]
    fn value_class_flag_captured() {
        let (file, diags) = parse("value class Boxed(val n: Int)\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Class(c) = &file.decls[0] else { panic!() };
        assert!(c.is_value);
        assert!(!c.is_annotation);
    }

    #[test]
    fn inline_class_promotes_to_value_with_warning() {
        let (file, diags) = parse("inline class Boxed(val n: Int)\n");
        let klio_ast::Decl::Class(c) = &file.decls[0] else { panic!() };
        assert!(c.is_value);
        let codes: Vec<_> = diags.diagnostics().iter().filter_map(klio_diagnostics::Diagnostic::code).collect();
        assert!(codes.contains(&"W0001"), "expected deprecation warning: {codes:?}");
    }

    #[test]
    fn annotation_class_flag_captured() {
        let (file, diags) = parse("annotation class Marker(val name: String)\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Class(c) = &file.decls[0] else { panic!() };
        assert!(c.is_annotation);
        assert_eq!(c.primary_params.len(), 1);
        assert_eq!(c.primary_params[0].name.name, "name");
    }

    #[test]
    fn tailrec_flag_captured() {
        let (file, diags) = parse(
            "tailrec fun loop(n: Int): Int = if (n == 0) 0 else loop(n - 1)\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(f) = &file.decls[0] else { panic!() };
        assert!(f.is_tailrec);
    }

    #[test]
    fn typealias_top_level() {
        let (file, diags) = parse("typealias IntList = List<Int>\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::TypeAlias(a) = &file.decls[0] else { panic!() };
        assert_eq!(a.name.name, "IntList");
        assert_eq!(a.target.name.name, "List");
        assert_eq!(a.target.type_args.len(), 1);
        assert_eq!(a.target.type_args[0].ty.name.name, "Int");
        assert!(a.type_params.is_empty());
    }

    #[test]
    fn typealias_with_type_params() {
        let (file, diags) = parse("typealias Pair2<A> = Pair<A, A>\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::TypeAlias(a) = &file.decls[0] else { panic!() };
        assert_eq!(a.name.name, "Pair2");
        assert_eq!(a.type_params.len(), 1);
        assert_eq!(a.type_params[0].name.name, "A");
        assert_eq!(a.target.name.name, "Pair");
        assert_eq!(a.target.type_args.len(), 2);
    }

    #[test]
    fn typealias_function_type() {
        let (file, diags) = parse("typealias Pred<T> = (T) -> Boolean\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::TypeAlias(a) = &file.decls[0] else { panic!() };
        assert_eq!(a.name.name, "Pred");
        assert!(a.target.function.is_some());
        let func = a.target.function.as_ref().unwrap();
        assert_eq!(func.params.len(), 1);
        assert_eq!(func.params[0].name.name, "T");
        assert_eq!(func.ret.name.name, "Boolean");
    }

    #[test]
    fn extension_property_val_parses() {
        let (file, diags) = parse("val Int.cubed: Int get() = this * this * this\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Property(p) = &file.decls[0] else { panic!() };
        assert_eq!(p.name.name, "cubed");
        assert!(!p.mutable);
        let recv = p.receiver_type.as_ref().expect("receiver");
        assert_eq!(recv.name.name, "Int");
        assert!(p.getter.is_some());
        assert!(p.setter.is_none());
        assert!(p.init.is_none());
    }

    #[test]
    fn extension_property_var_parses() {
        let (file, diags) = parse(
            "var Holder.doubled: Int\n    get() = 0\n    set(value) { }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Property(p) = &file.decls[0] else { panic!() };
        assert!(p.mutable);
        assert_eq!(p.receiver_type.as_ref().unwrap().name.name, "Holder");
        assert!(p.getter.is_some());
        assert!(p.setter.is_some());
    }

    #[test]
    fn extension_property_on_user_class() {
        let (file, diags) = parse(
            "class Box(val n: Int)\nval Box.doubled: Int get() = n * 2\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Property(p) = &file.decls[1] else { panic!() };
        assert_eq!(p.receiver_type.as_ref().unwrap().name.name, "Box");
        assert!(p.getter.is_some());
    }

    #[test]
    fn typealias_in_class_body_parses() {
        // Parser accepts the form; typeck emits T0039 elsewhere.
        let (file, diags) = parse(
            "class Outer { typealias Inner = Int }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Class(c) = &file.decls[0] else { panic!() };
        assert_eq!(c.members.len(), 1);
        assert!(matches!(&c.members[0], klio_ast::Decl::TypeAlias(_)));
    }

    #[test]
    fn delegation_supertype_parsed() {
        let (file, diags) = parse(
            "interface I { fun f(): Int }\nclass C(d: I) : I by d\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Class(c) = &file.decls[1] else { panic!() };
        assert_eq!(c.supertypes.len(), 1);
        assert_eq!(c.supertype_delegates.len(), 1);
        assert!(c.supertype_args[0].is_none());
        assert!(matches!(&c.supertype_delegates[0], Some(klio_ast::Expr::Path { .. })));
    }

    #[test]
    fn delegation_with_class_body_not_consumed_as_lambda() {
        // The class body's `{ … }` must not be swallowed as a trailing
        // lambda of the delegate expression.
        let (file, diags) = parse(
            "interface I { fun f(): Int }\nclass C(d: I) : I by d { fun extra() = 1 }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Class(c) = &file.decls[1] else { panic!() };
        assert_eq!(c.members.len(), 1);
        assert!(matches!(&c.members[0], klio_ast::Decl::Function(f) if f.name.name == "extra"));
    }

    #[test]
    fn data_object_parsed() {
        let (file, diags) = parse("data object Foo { val n: Int = 0 }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Object(o) = &file.decls[0] else { panic!() };
        assert!(o.is_data);
        assert_eq!(o.name.name, "Foo");
    }

    #[test]
    fn plain_object_not_data() {
        let (_file, diags) = parse("object Bar { val n: Int = 0 }\n");
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
    }

    #[test]
    fn spread_arg_parsed() {
        let (file, diags) = parse(
            "fun show(vararg ns: Int) {}\nfun main() { val a = intArrayOf(1); show(*a) }\n",
        );
        assert!(!diags.has_errors(), "{:?}", diags.diagnostics());
        let klio_ast::Decl::Function(main) = &file.decls[1] else { panic!() };
        let Some(klio_ast::FunctionBody::Block(b)) = &main.body else { panic!() };
        // The second statement is the call show(*a).
        let klio_ast::Stmt::Expr(klio_ast::Expr::Call { args, .. }) = &b.stmts[1] else {
            panic!("expected call");
        };
        assert!(matches!(&args[0], klio_ast::Expr::Spread { .. }));
    }
}
