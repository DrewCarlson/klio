//! Parity sweep. For each file in the corpus and in `examples/`, compile
//! with `kotlinc-native` and run under `klio`, asserting byte-identical
//! stdout. Skips with a printed note if `kotlinc-native` isn't available.

use std::path::{Path, PathBuf};

fn workspace_root() -> PathBuf {
    let m = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    m.parent()
        .and_then(|p| p.parent())
        .map(PathBuf::from)
        .unwrap_or(m)
}

fn collect_kt(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else { return out };
    for entry in entries.flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) == Some("kt") {
            out.push(p);
        }
    }
    out.sort();
    out
}

fn check_paths(paths: &[PathBuf]) {
    if klio_parity::find_kotlinc().is_err() {
        eprintln!(
            "kotlinc-native not found; skipping parity tests (install Kotlin Native at version {} \
             or set KLIO_KOTLINC_NATIVE).",
            klio_parity::TARGET_VERSION
        );
        return;
    }
    let mut failed = Vec::new();
    for p in paths {
        match klio_parity::check(p) {
            Ok(report) if report.matched => {
                eprintln!("[parity] {}: ok", p.display());
            }
            Ok(report) => {
                eprintln!("[parity] {}: MISMATCH", p.display());
                eprint!("{}", klio_parity::render_diff(&report));
                failed.push(p.clone());
            }
            Err(e) => {
                panic!("[parity] {}: harness error: {e}", p.display());
            }
        }
    }
    assert!(
        failed.is_empty(),
        "parity mismatches: {:?}",
        failed.iter().map(|p| p.display().to_string()).collect::<Vec<_>>()
    );
}

#[test]
fn examples_pass_parity() {
    let dir = workspace_root().join("examples");
    let paths = collect_kt(&dir);
    assert!(!paths.is_empty(), "no example .kt files in {}", dir.display());
    check_paths(&paths);
}

#[test]
fn corpus_passes_parity() {
    let dir = workspace_root()
        .join("crates")
        .join("klio-parity")
        .join("tests")
        .join("corpus");
    let paths = collect_kt(&dir);
    assert!(!paths.is_empty(), "no corpus .kt files");
    check_paths(&paths);
}
