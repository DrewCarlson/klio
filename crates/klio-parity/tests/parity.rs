//! Parity sweep. For each file in the corpus and in `examples/`, compile
//! with JVM `kotlinc` and run under `klio`, asserting byte-identical stdout.
//! Skips with a printed note if `kotlinc` isn't available.
//!
//! The kotlinc step runs once per sweep: all `.kt` files are staged into
//! disjoint packages (`klio_parity.<label>.<stem>`) and compiled into a single
//! jar. Per-file work is then just `java -cp jar <fqcn>` plus the klio interp.
//! This trades one ~30–60s up-front compile for ~200ms per file, instead of
//! paying ~1–2s of `kotlinc` startup per file.
//!
//! Progress is streamed to `target/parity-progress.log` so a hang's location
//! is visible even when `cargo test` captures stdout. Tail it live:
//!
//!     tail -f target/parity-progress.log
//!
//! `KLIO_PARITY_STAGE_TIMEOUT_SECS` (default 120) bounds each stage; on
//! overrun the file is marked as a stage timeout and the sweep continues.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

fn workspace_root() -> PathBuf {
    let m = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    m.parent()
        .and_then(|p| p.parent())
        .map(PathBuf::from)
        .unwrap_or(m)
}

fn progress_log_path() -> PathBuf {
    let target = std::env::var_os("CARGO_TARGET_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| workspace_root().join("target"));
    let _ = std::fs::create_dir_all(&target);
    target.join("parity-progress.log")
}

fn open_progress_log() -> File {
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(progress_log_path())
        .expect("open parity-progress.log")
}

fn log_progress(log: &mut File, msg: &str) {
    let ts = ts_hms();
    let line = format!("{ts} {msg}");
    let _ = writeln!(log, "{line}");
    let _ = log.flush();
    eprintln!("{line}");
}

fn ts_hms() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    let secs = now.as_secs();
    let ms = now.subsec_millis();
    let h = (secs / 3600) % 24;
    let m = (secs / 60) % 60;
    let s = secs % 60;
    format!("{h:02}:{m:02}:{s:02}.{ms:03}")
}

fn stage_timeout() -> Duration {
    let secs = std::env::var("KLIO_PARITY_STAGE_TIMEOUT_SECS")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(120);
    Duration::from_secs(secs)
}

/// Run `f` on a worker thread; on timeout the worker is detached (Rust has no
/// portable safe thread-kill) and the sweep moves on. Good enough for
/// diagnosing where things hang.
fn run_with_timeout<T, F>(timeout: Duration, f: F) -> Result<T, Duration>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    let (tx, rx) = mpsc::channel();
    let start = Instant::now();
    thread::spawn(move || {
        let r = f();
        let _ = tx.send(r);
    });
    match rx.recv_timeout(timeout) {
        Ok(v) => Ok(v),
        Err(_) => Err(start.elapsed()),
    }
}

enum StageOutcome<T> {
    Ok(T, Duration),
    Timeout(Duration),
    Err(String, Duration),
}

fn time_stage<T, F>(timeout: Duration, f: F) -> StageOutcome<T>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, String> + Send + 'static,
{
    let start = Instant::now();
    match run_with_timeout(timeout, f) {
        Ok(Ok(v)) => StageOutcome::Ok(v, start.elapsed()),
        Ok(Err(e)) => StageOutcome::Err(e, start.elapsed()),
        Err(elapsed) => StageOutcome::Timeout(elapsed),
    }
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

#[derive(Default)]
struct SweepStats {
    failed: Vec<PathBuf>,
    timed_out: Vec<(PathBuf, &'static str)>,
}

fn check_paths(label: &'static str, paths: &[PathBuf]) {
    let mut log = open_progress_log();
    log_progress(
        &mut log,
        &format!("=== sweep:{label} start ({} files) ===", paths.len()),
    );

    if klio_parity::find_kotlinc().is_err() {
        log_progress(
            &mut log,
            &format!(
                "skipping {label}: kotlinc not found (auto-install of JVM kotlinc {} failed; set KLIO_KOTLINC_JVM_HOME).",
                klio_parity::TARGET_VERSION
            ),
        );
        return;
    }

    let timeout = stage_timeout();

    // Stage 1 (one-shot): bulk compile all files into a single jar.
    log_progress(
        &mut log,
        &format!("{label}: bulk kotlinc compile ({} files)…", paths.len()),
    );
    let paths_for_thread = paths.to_vec();
    let build_timeout = timeout.max(Duration::from_secs(600));
    let build = match time_stage(build_timeout, move || {
        klio_parity::compile_corpus(label, &paths_for_thread).map_err(|e| e.to_string())
    }) {
        StageOutcome::Ok(b, elapsed) => {
            log_progress(
                &mut log,
                &format!(
                    "{label}: bulk kotlinc ok ({:.2}s) -> {}",
                    elapsed.as_secs_f64(),
                    b.jar.display()
                ),
            );
            b
        }
        StageOutcome::Timeout(elapsed) => {
            panic!(
                "bulk kotlinc compile timed out after {:.2}s (see {})",
                elapsed.as_secs_f64(),
                progress_log_path().display()
            );
        }
        StageOutcome::Err(e, elapsed) => {
            panic!(
                "bulk kotlinc compile failed after {:.2}s: {e}\n(see {})",
                elapsed.as_secs_f64(),
                progress_log_path().display()
            );
        }
    };

    let mut stats = SweepStats::default();

    for (idx, entry) in build.classes.iter().enumerate() {
        let path = &entry.original;
        let rel = path
            .strip_prefix(workspace_root())
            .map(|r| r.display().to_string())
            .unwrap_or_else(|_| path.display().to_string());
        let tag = format!("[{label} {}/{}]", idx + 1, build.classes.len());

        // Stage 2: java -cp jar <fqcn>
        let jar = build.jar.clone();
        let fqcn_for_thread = entry.fqcn.clone();
        let kotlinc_stdout = match time_stage(timeout, move || {
            klio_parity::run_class(&jar, &fqcn_for_thread).map_err(|e| e.to_string())
        }) {
            StageOutcome::Ok((out, _exit), elapsed) => {
                log_progress(
                    &mut log,
                    &format!("{tag} {rel}: java ok ({:.2}s)", elapsed.as_secs_f64()),
                );
                out
            }
            StageOutcome::Timeout(elapsed) => {
                log_progress(
                    &mut log,
                    &format!(
                        "{tag} {rel}: java TIMEOUT after {:.2}s",
                        elapsed.as_secs_f64()
                    ),
                );
                stats.timed_out.push((path.clone(), "java"));
                continue;
            }
            StageOutcome::Err(e, elapsed) => {
                log_progress(
                    &mut log,
                    &format!(
                        "{tag} {rel}: java ERROR ({:.2}s): {e}",
                        elapsed.as_secs_f64()
                    ),
                );
                stats.failed.push(path.clone());
                continue;
            }
        };

        // Stage 3: klio interp — feed the *staged* source so klio sees the
        // same synthesized `package` decl kotlinc did; otherwise FQ class
        // names diverge purely from the harness, not from real interp behavior.
        let staged_for_thread = entry.staged.clone();
        match time_stage(timeout, move || klio_parity::run_with_ktc(&staged_for_thread)) {
            StageOutcome::Ok(klio_stdout, elapsed) => {
                let matched = kotlinc_stdout == klio_stdout;
                if matched {
                    log_progress(
                        &mut log,
                        &format!(
                            "{tag} {rel}: klio ok ({:.2}s) -> MATCH",
                            elapsed.as_secs_f64()
                        ),
                    );
                } else {
                    log_progress(
                        &mut log,
                        &format!(
                            "{tag} {rel}: klio ok ({:.2}s) -> MISMATCH",
                            elapsed.as_secs_f64()
                        ),
                    );
                    let report = klio_parity::ParityReport {
                        matched: false,
                        kotlinc_stdout,
                        klio_stdout,
                        kotlinc_exit: None,
                        klio_error: None,
                    };
                    eprint!("{}", klio_parity::render_diff(&report));
                    stats.failed.push(path.clone());
                }
            }
            StageOutcome::Timeout(elapsed) => {
                log_progress(
                    &mut log,
                    &format!(
                        "{tag} {rel}: klio TIMEOUT after {:.2}s (interp hang)",
                        elapsed.as_secs_f64()
                    ),
                );
                stats.timed_out.push((path.clone(), "klio"));
            }
            StageOutcome::Err(e, elapsed) => {
                log_progress(
                    &mut log,
                    &format!(
                        "{tag} {rel}: klio ERROR ({:.2}s): {e}",
                        elapsed.as_secs_f64()
                    ),
                );
                stats.failed.push(path.clone());
            }
        }
    }

    log_progress(
        &mut log,
        &format!(
            "=== sweep:{label} done — failed={} timed_out={} ===",
            stats.failed.len(),
            stats.timed_out.len()
        ),
    );

    if !stats.timed_out.is_empty() {
        let detail: Vec<String> = stats
            .timed_out
            .iter()
            .map(|(p, stage)| format!("{} ({stage})", p.display()))
            .collect();
        panic!(
            "parity stage timeouts in {label}: {:?}\n(see {})",
            detail,
            progress_log_path().display()
        );
    }
    assert!(
        stats.failed.is_empty(),
        "parity mismatches in {label}: {:?}\n(see {})",
        stats.failed.iter().map(|p| p.display().to_string()).collect::<Vec<_>>(),
        progress_log_path().display()
    );
}

#[test]
fn examples_pass_parity() {
    let dir = workspace_root().join("examples");
    let paths = collect_kt(&dir);
    assert!(!paths.is_empty(), "no example .kt files in {}", dir.display());
    check_paths("examples", &paths);
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
    check_paths("corpus", &paths);
}
