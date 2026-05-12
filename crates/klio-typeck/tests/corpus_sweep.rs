//! Type-check every parity-corpus and example program. The type checker
//! must not emit hard errors on programs we accept as runnable today.

use std::path::{Path, PathBuf};

use klio_lexer::Lexer;
use klio_parser::Parser;
use klio_span::SourceMap;

fn workspace_root() -> PathBuf {
    let m = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    m.parent()
        .and_then(|p| p.parent())
        .map(PathBuf::from)
        .unwrap_or(m)
}

fn collect_kt(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return out;
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) == Some("kt") {
            out.push(p);
        }
    }
    out.sort();
    out
}

fn typecheck_path(path: &Path) -> Vec<String> {
    let src = std::fs::read_to_string(path).expect("read file");
    let mut map = SourceMap::new();
    let id = map.add(path, src);
    let owned = map.get(id).source.clone();
    let toks = Lexer::new(id, &owned).tokenize();
    let (ast, _) = Parser::new(id, &owned, &toks.tokens).parse_file();
    let r = klio_resolver::resolve(&ast);
    let tc = klio_typeck::typecheck(&ast, &r);
    tc.diagnostics
        .diagnostics()
        .iter()
        .filter(|d| matches!(d.severity, klio_diagnostics::Severity::Error))
        .map(|d| format!("{}: {}", d.code().unwrap_or("?"), d.message))
        .collect()
}

#[test]
fn corpus_typechecks_clean() {
    let dir = workspace_root()
        .join("crates")
        .join("klio-parity")
        .join("tests")
        .join("corpus");
    let paths = collect_kt(&dir);
    assert!(!paths.is_empty(), "no corpus files");
    let mut failed = Vec::new();
    for p in &paths {
        let errs = typecheck_path(p);
        if !errs.is_empty() {
            eprintln!("[typeck] {}: errors:", p.display());
            for e in &errs {
                eprintln!("  - {e}");
            }
            failed.push(p.clone());
        }
    }
    assert!(
        failed.is_empty(),
        "type-checker emitted errors on {} corpus files",
        failed.len()
    );
}

#[test]
fn examples_typecheck_clean() {
    let dir = workspace_root().join("examples");
    let paths = collect_kt(&dir);
    assert!(!paths.is_empty(), "no examples");
    let mut failed = Vec::new();
    for p in &paths {
        let errs = typecheck_path(p);
        if !errs.is_empty() {
            eprintln!("[typeck] {}: errors:", p.display());
            for e in &errs {
                eprintln!("  - {e}");
            }
            failed.push(p.clone());
        }
    }
    assert!(
        failed.is_empty(),
        "type-checker emitted errors on {} examples",
        failed.len()
    );
}
