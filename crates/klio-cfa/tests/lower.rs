//! End-to-end snapshot tests for AST → CFG lowering. Parses small
//! Kotlin functions, lowers their body, and snapshots the printed
//! CFG. These pin the shape of the lowering output across changes.

use klio_ast::{Decl, FunctionBody};
use klio_cfa::lower::lower_function;
use klio_cfa::print_cfg;
use klio_lexer::Lexer;
use klio_span::SourceMap;

fn lower_first_fun(src: &str) -> String {
    let mut map = SourceMap::new();
    let id = map.add("t.kt", src);
    let owned = map.get(id).source.clone();
    let lexed = Lexer::new(id, &owned).tokenize();
    assert!(
        !lexed.diagnostics.has_errors(),
        "lex: {:?}",
        lexed.diagnostics.diagnostics()
    );
    let (file, diags) = klio_parser::Parser::new(id, &owned, &lexed.tokens).parse_file();
    assert!(!diags.has_errors(), "parse: {:?}", diags.diagnostics());
    let func = file
        .decls
        .iter()
        .find_map(|d| match d {
            Decl::Function(f) => Some(f),
            _ => None,
        })
        .expect("no function in source");
    let body = match func.body.as_ref().expect("function has no body") {
        FunctionBody::Block(b) => b.clone(),
        FunctionBody::Expr(e) => klio_ast::Block {
            stmts: vec![klio_ast::Stmt::Expr(e.clone())],
            span: e.span(),
        },
    };
    let lowered = lower_function(&body, func.span);
    print_cfg(&lowered.cfg)
}

#[test]
fn empty_body() {
    insta::assert_snapshot!(lower_first_fun("fun main() { }"));
}

#[test]
fn straight_line_assignment() {
    insta::assert_snapshot!(lower_first_fun(
        "fun main() {
            val x = 1
            val y = x + 2
        }"
    ));
}

#[test]
fn if_else_join() {
    insta::assert_snapshot!(lower_first_fun(
        "fun main() {
            val c = true
            val x = if (c) 1 else 2
        }"
    ));
}

#[test]
fn short_circuit_and() {
    insta::assert_snapshot!(lower_first_fun(
        "fun main() {
            val a = true
            val b = false
            val c = a && b
        }"
    ));
}

#[test]
fn elvis_lowering() {
    insta::assert_snapshot!(lower_first_fun(
        "fun main() {
            val x: Int? = null
            val y = x ?: 0
        }"
    ));
}

#[test]
fn while_loop() {
    insta::assert_snapshot!(lower_first_fun(
        "fun main() {
            var i = 0
            while (i < 10) {
                i = i + 1
            }
        }"
    ));
}

#[test]
fn try_catch_finally() {
    insta::assert_snapshot!(lower_first_fun(
        "fun main() {
            try {
                val x = 1
            } catch (e: RuntimeException) {
                val y = 2
            } finally {
                val z = 3
            }
        }"
    ));
}

#[test]
fn when_with_is() {
    insta::assert_snapshot!(lower_first_fun(
        "fun main() {
            val x: Any = 1
            val r = when (x) {
                is String -> 1
                is Int -> 2
                else -> 3
            }
        }"
    ));
}

#[test]
fn return_short_circuits() {
    insta::assert_snapshot!(lower_first_fun(
        "fun main() {
            val x = 1
            return
            val y = 2
        }"
    ));
}

#[test]
fn not_null_assertion() {
    insta::assert_snapshot!(lower_first_fun(
        "fun main() {
            val x: Int? = 1
            val y = x!! + 1
        }"
    ));
}
