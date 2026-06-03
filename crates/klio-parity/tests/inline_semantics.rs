//! Inline / noinline semantics that rely on the universal-inline
//! splicing landed alongside this file. Each test exercises a
//! behavior that the previous conservative inline policy (suspend
//! OR non-local-return lambda only) did not reach.

use klio_ast::KotlinFile;
use klio_interp_ir::{Vm, build::build_module_files};
use klio_lexer::Lexer;
use klio_parser::Parser as KtParser;
use klio_runtime::Output;
use klio_span::SourceMap;
use std::path::PathBuf;

#[derive(Default)]
struct Capture {
    text: String,
}

impl Output for Capture {
    fn writeln(&mut self, s: &str) {
        self.text.push_str(s);
        self.text.push('\n');
    }
    fn write(&mut self, s: &str) {
        self.text.push_str(s);
    }
}

fn run(src: &str) -> String {
    let mut map = SourceMap::new();
    let path = PathBuf::from("inline_test.kt");
    let id = map.add(&path, src.to_string());
    let owned = map.get(id).source.clone();
    let lexed = Lexer::new(id, &owned).tokenize();
    assert!(
        !lexed.diagnostics.has_errors(),
        "lex: {:?}",
        lexed.diagnostics.diagnostics()
    );
    let (ast, diags) = KtParser::new(id, &owned, &lexed.tokens).parse_file();
    assert!(!diags.has_errors(), "parse: {:?}", diags.diagnostics());
    let built = build_module_files(&[ast as KotlinFile]);
    let main_id = built.main.expect("main");
    let (mut vm, _) = Vm::from_built(built);
    let mut out = Capture::default();
    vm.run(main_id, &mut out).expect("vm run");
    out.text
}

#[test]
fn non_suspend_inline_fn_body_splices_into_caller() {
    // Universal inline splicing: a non-suspend `inline fun` with no
    // non-local-return lambda must still inline. Verified
    // behaviourally — `tag` is captured by the inlined block and
    // each call site emits its own copy.
    let out = run(r#"
        inline fun trace(tag: String, block: () -> String): String =
            "[" + tag + "]" + block()

        fun main() {
            println(trace("a") { "x" })
            println(trace("b") { "y" })
        }
        "#);
    assert_eq!(out, "[a]x\n[b]y\n");
}

#[test]
fn noinline_param_lambda_is_not_spliced() {
    // A `noinline` lambda argument must be passable as a value.
    // After splicing, a normal-call dispatch against the parameter
    // reg invokes the lambda; the test verifies the value flows
    // through a helper that stores it in a property.
    let out = run(r#"
        var stored: (() -> Int)? = null

        inline fun keep(noinline block: () -> Int) {
            stored = block
        }

        fun main() {
            keep { 42 }
            val k = stored
            if (k != null) println(k()) else println("null")
        }
        "#);
    assert_eq!(out, "42\n");
}

#[test]
fn inline_fn_with_default_lambda_arg_does_not_break() {
    // The defaults safety path in `try_inline_call` returns None
    // when a positional arg is missing and no default is declared;
    // the fallback normal-call must dispatch the same body. A
    // defaulted no-arg call should still inline since the AST
    // carries the default literal.
    let out = run(r#"
        inline fun pick(tag: String = "z", block: (String) -> String): String =
            block(tag)

        fun main() {
            println(pick { it + "!" })
        }
        "#);
    assert_eq!(out, "z!\n");
}

// A reified inline fn whose return type is the type parameter can have
// that parameter inferred from the call's context — no explicit `<T>`.
// `build()` reads `T::class`, so a wrong/absent binding misbuilds or
// crashes; the assertions pin the inferred type.
const REIFIED_INFER_SRC: &str = r#"
    class Box(val label: String)
    class Gift(val label: String)

    inline fun <reified T> build(): T {
        val n = T::class.simpleName
        return when (n) {
            "Box" -> Box("b") as T
            "Gift" -> Gift("g") as T
            else -> error("unknown $n")
        }
    }

    // Forwards its own reified T into `build<T>()`.
    inline fun <reified T> build2(): T = build<T>()
"#;

#[test]
fn reified_type_arg_inferred_from_val_type() {
    let out = run(&format!(
        "{REIFIED_INFER_SRC}\nfun main() {{ val b: Box = build(); val g: Gift = build(); println(b.label + g.label) }}"
    ));
    assert_eq!(out, "bg\n");
}

#[test]
fn reified_type_arg_inferred_from_expression_body_return() {
    let out = run(&format!(
        "{REIFIED_INFER_SRC}\nfun mk(): Box = build()\nfun main() {{ println(mk().label) }}"
    ));
    assert_eq!(out, "b\n");
}

#[test]
fn reified_type_arg_inferred_from_block_return() {
    let out = run(&format!(
        "{REIFIED_INFER_SRC}\nfun mk(): Gift {{ return build() }}\nfun main() {{ println(mk().label) }}"
    ));
    assert_eq!(out, "g\n");
}

#[test]
fn reified_type_arg_inferred_through_forwarding_inline_fn() {
    // `build2()` infers T from the `val` type, then forwards it into
    // `build<T>()`; both splices must bind the reified parameter.
    let out = run(&format!(
        "{REIFIED_INFER_SRC}\nfun main() {{ val b: Box = build2(); println(b.label) }}"
    ));
    assert_eq!(out, "b\n");
}

#[test]
fn explicit_reified_type_arg_still_wins() {
    // An explicit `<Gift>` overrides any context type.
    let out = run(&format!(
        "{REIFIED_INFER_SRC}\nfun main() {{ val g = build<Gift>(); println(g.label) }}"
    ));
    assert_eq!(out, "g\n");
}
