//! Cross-pack name-resolution tests. Each scenario constructs a
//! multi-file module where two pseudo-packs declare the same simple
//! name in different packages, plus a "user" file that explicitly
//! imports one. Klio must dispatch to the imported declaration —
//! not whichever one happened to land first in the module's
//! simple-name index.

use klio_ast::KotlinFile;
use klio_interp_ir::{build::build_module_files, Vm};
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

fn parse(map: &mut SourceMap, name: &str, src: &str) -> KotlinFile {
    let id = map.add(&PathBuf::from(name), src.to_string());
    let owned = map.get(id).source.clone();
    let lexed = Lexer::new(id, &owned).tokenize();
    assert!(
        !lexed.diagnostics.has_errors(),
        "lex {name}: {:?}",
        lexed.diagnostics.diagnostics()
    );
    let (ast, diags) = KtParser::new(id, &owned, &lexed.tokens).parse_file();
    assert!(
        !diags.has_errors(),
        "parse {name}: {:?}",
        diags.diagnostics()
    );
    ast
}

/// Run a synthetic multi-file program. `files` is `(name, source)` pairs;
/// the LAST entry is the user file (matches `build_module_files`'s
/// convention that pack ASTs precede user ASTs).
fn run_multi(files: &[(&str, &str)]) -> String {
    let mut map = SourceMap::new();
    let asts: Vec<KotlinFile> = files
        .iter()
        .map(|(name, src)| parse(&mut map, name, src))
        .collect();
    let built = build_module_files(&asts);
    let main_id = built.main.expect("module has main");
    let (mut vm, _) = Vm::from_built(built);
    let mut out = Capture::default();
    vm.run(main_id, &mut out).expect("vm run");
    out.text
}

#[test]
fn cross_pack_inline_fn_explicit_import_picks_imported_pkg() {
    // pack_a and pack_b both declare `inline fun probe(): Int`. The
    // user explicitly imports pack_a.probe, so the call must dispatch
    // to pack_a's body even though pack_b is registered later in the
    // combined module and `func_id`'s simple-name lookup would find
    // it first.
    // Order pack_b before pack_a so a simple-name `func_index`
    // scan would pick pack_b first; the explicit import must still
    // route the call to pack_a.
    let out = run_multi(&[
        (
            "pack_b.kt",
            r#"
            package pack_b
            public inline fun probe(): Int = 2
            "#,
        ),
        (
            "pack_a.kt",
            r#"
            package pack_a
            public inline fun probe(): Int = 1
            "#,
        ),
        (
            "user.kt",
            r#"
            import pack_a.probe
            fun main() { println(probe()) }
            "#,
        ),
    ]);
    assert_eq!(out, "1\n");
}

#[test]
fn cross_pack_class_explicit_import_picks_imported_pkg() {
    // Two `class Data(val v: Int)` declarations in different packages.
    // The user imports pack_a.Data, so the constructor + member must
    // resolve against pack_a even when pack_b is registered first.
    let out = run_multi(&[
        (
            "pack_b.kt",
            r#"
            package pack_b
            class Data(val v: Int) { fun tag(): String = "B" }
            "#,
        ),
        (
            "pack_a.kt",
            r#"
            package pack_a
            class Data(val v: Int) { fun tag(): String = "A" }
            "#,
        ),
        (
            "user.kt",
            r#"
            import pack_a.Data
            fun main() { println(Data(7).tag() + Data(7).v) }
            "#,
        ),
    ]);
    assert_eq!(out, "A7\n");
}

#[test]
fn cross_pack_toplevel_fn_explicit_import_picks_imported_pkg() {
    // Same shape as the inline-fn test but with non-inline top-level
    // functions, so resolution is entirely on the func_index path.
    // pack_b precedes pack_a so a first-match `func_index` scan
    // would pick the wrong target.
    let out = run_multi(&[
        (
            "pack_b.kt",
            r#"
            package pack_b
            fun greet(): String = "hello-b"
            "#,
        ),
        (
            "pack_a.kt",
            r#"
            package pack_a
            fun greet(): String = "hello-a"
            "#,
        ),
        (
            "user.kt",
            r#"
            import pack_a.greet
            fun main() { println(greet()) }
            "#,
        ),
    ]);
    assert_eq!(out, "hello-a\n");
}

#[test]
fn user_shadow_of_implicit_alias_wins() {
    // Default-imported `kotlin.io.print` is exposed in the Vm's
    // global env via `IMPLICIT_ALIASES`. A user declaration of the
    // same simple name must shadow it at the call site — Kotlin's
    // local scope > any default import. The user's body funnels
    // through fully-qualified `kotlin.io.print` to surface to
    // stdout without recursing back into itself.
    let out = run_multi(&[(
        "user.kt",
        r#"
        fun print(x: Int) { kotlin.io.println("user:" + x) }
        fun main() { print(5) }
        "#,
    )]);
    assert_eq!(out, "user:5\n");
}
