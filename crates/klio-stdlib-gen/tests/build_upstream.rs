//! End-to-end: run the generator against the real upstream stdlib tree and
//! assert the output is non-empty and well-formed. The generated files are
//! committed to the repo; this test re-runs the mining and writes to a temp
//! dir so it doesn't churn the workspace.

use std::env;
use std::path::PathBuf;

use klio_stdlib_gen::{collect_decls, emit_generated};

fn workspace_root() -> PathBuf {
    let m = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    m.parent().unwrap().parent().unwrap().to_path_buf()
}

#[test]
fn mines_upstream_stdlib() {
    let root = workspace_root();
    let stdlib = root.join("kotlin/libraries/stdlib");
    if !stdlib.is_dir() {
        eprintln!("skipping: upstream kotlin checkout missing at {}", stdlib.display());
        return;
    }
    let (files, stats) = collect_decls(&stdlib);
    assert!(stats.files_parsed > 100, "expected to parse many files, got {}", stats.files_parsed);
    assert!(stats.total_decls > 500, "expected > 500 decls, got {}", stats.total_decls);

    let tmp = env::temp_dir().join("klio-stdlib-gen-test");
    let _ = std::fs::remove_dir_all(&tmp);
    let written = emit_generated(&tmp, &files).expect("emit failed");
    assert!(written > 500, "expected > 500 symbols written, got {}", written);

    // The generated files should be syntactically valid Rust. We don't run
    // rustc here (slow), but a coarse sanity check on the symbols.rs shape
    // catches the most common emit bugs.
    let symbols = std::fs::read_to_string(tmp.join("symbols.rs")).unwrap();
    assert!(symbols.contains("pub static STDLIB_SYMBOLS"));
    assert!(symbols.matches("SymbolEntry {").count() == written);
}
