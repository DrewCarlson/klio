//! Parity sweep. For each file in the corpus and in `examples/`, compile with
//! JVM `kotlinc` and run under `klio`, asserting byte-identical stdout. Skips
//! with a printed note if `kotlinc` isn't available.
//!
//! The heavy lifting lives in `klio_parity::run_sweep`, shared with the
//! `klio-parity --sweep` binary so the test and the fast inner loop never
//! diverge. kotlinc compiles the whole corpus into one cached jar; each file's
//! kotlinc stdout is then text-cached (keyed by staged-source content), so a
//! warm rerun spawns neither kotlinc nor `java` and only re-runs the in-process
//! klio interpreter. Files are compared in parallel across the available cores.
//!
//! `KLIO_PARITY_STAGE_TIMEOUT_SECS` (default 120) bounds each file's klio run.

use std::path::{Path, PathBuf};
use std::time::Duration;

fn stage_timeout() -> Duration {
    let secs = std::env::var("KLIO_PARITY_STAGE_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(120);
    Duration::from_secs(secs)
}

fn check_paths(label: &'static str, paths: &[PathBuf]) {
    if klio_parity::find_kotlinc().is_err() {
        eprintln!(
            "skipping {label}: kotlinc not found (auto-install of JVM kotlinc {} failed; \
             set KLIO_KOTLINC_JVM_HOME).",
            klio_parity::TARGET_VERSION
        );
        return;
    }

    let jobs = std::thread::available_parallelism().map_or(4, |n| n.get());
    let res = klio_parity::run_sweep(label, paths, jobs, stage_timeout())
        .unwrap_or_else(|e| panic!("bulk kotlinc compile failed for {label}: {e}"));

    let failures = res.failures();
    for f in &failures {
        let rel = f
            .path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("?");
        match &f.verdict {
            klio_parity::SweepVerdict::Mismatch(report) => {
                eprintln!("[{label}] MISMATCH {rel}");
                eprint!("{}", klio_parity::render_diff(report));
            }
            klio_parity::SweepVerdict::KlioError(e) => {
                eprintln!("[{label}] klio ERROR {rel}: {e}");
            }
            klio_parity::SweepVerdict::Timeout => {
                eprintln!("[{label}] klio TIMEOUT {rel}");
            }
            _ => {}
        }
    }
    eprintln!(
        "=== sweep:{label} done — {}/{} passed, {} failed ===",
        res.passed(),
        res.results.len(),
        failures.len()
    );

    assert!(
        failures.is_empty(),
        "parity failures in {label}: {:?}",
        failures
            .iter()
            .map(|f| f.path.display().to_string())
            .collect::<Vec<_>>()
    );
}

fn collect(dir: &Path, what: &str) -> Vec<PathBuf> {
    let paths = klio_parity::collect_kt(dir);
    assert!(!paths.is_empty(), "no {what} .kt files in {}", dir.display());
    paths
}

#[test]
fn examples_pass_parity() {
    let dir = klio_parity::examples_dir();
    check_paths("examples", &collect(&dir, "example"));
}

#[test]
fn corpus_passes_parity() {
    let dir = klio_parity::corpus_dir();
    check_paths("corpus", &collect(&dir, "corpus"));
}
