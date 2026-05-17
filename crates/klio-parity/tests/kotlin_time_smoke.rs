//! kotlin.time verification through the **real shipping path**: run a
//! deterministic program with the actual `klio` binary. `kotlin.time`
//! (`Duration` / `DurationUnit`) is consumed verbatim from the upstream
//! Kotlin commonMain checkout via the embedded stdlib pack's curated
//! `SOURCES` section, with klio's platform `actual`s + Rust host
//! bindings supplying the `internal expect` clock surface.
//!
//! The pinned stdout is byte-identical to kotlinc 2.3.21, proving the
//! consumed code is real upstream Kotlin on the live path — not a klio
//! reimplementation. No pack install is needed: the curated stdlib
//! SOURCES are statically embedded in the binary.

use std::path::{Path, PathBuf};
use std::process::Command;

fn ws_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .map(PathBuf::from)
        .expect("workspace root")
}

fn klio_bin() -> PathBuf {
    ws_root().join("target/release/klio")
}

/// Run `file` through the real `klio` binary, returning stdout.
fn run_via_binary(file: &Path) -> String {
    let o = Command::new(klio_bin())
        .arg("run")
        .arg(file)
        .output()
        .expect("spawn klio run");
    assert!(
        o.status.success(),
        "klio run {} failed: {}",
        file.display(),
        String::from_utf8_lossy(&o.stderr)
    );
    String::from_utf8(o.stdout).expect("utf8 stdout")
}

/// Expected stdout = the run of `//> ` comment lines.
fn expected_from_litmus(file: &Path) -> String {
    let src = std::fs::read_to_string(file).expect("read litmus");
    let mut out = String::new();
    for line in src.lines() {
        let t = line.trim_start();
        if let Some(rest) = t.strip_prefix("//>") {
            out.push_str(rest.strip_prefix(' ').unwrap_or(rest));
            out.push('\n');
        }
    }
    out
}

#[test]
fn kotlin_time_smoke_litmus() {
    let bin = klio_bin();
    assert!(
        bin.exists(),
        "target/release/klio missing — run `cargo build -p klio-cli --release` first"
    );
    let file = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("kotlin_time_smoke")
        .join("kt_time_smoke.kt");
    let want = expected_from_litmus(&file);
    assert!(!want.is_empty(), "no //> expected lines");
    assert_eq!(
        run_via_binary(&file),
        want,
        "kt_time_smoke.kt stdout drifted (kotlin.time SOURCES path)"
    );
}
