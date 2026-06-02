//! `klio-parity <file.kt>` — compare our interpreter against JVM `kotlinc`.
//! Exit code 0 on parity, 1 on mismatch, 2 on harness error.

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let Some(file) = args.get(1) else {
        eprintln!(
            "usage: klio-parity <file.kt> [<file.kt> ...]\n       \
             klio-parity --sweep [corpus|examples|all]\n       \
             klio-parity --install [jvm|native|both]"
        );
        return ExitCode::from(2);
    };
    if file == "--sweep" {
        return run_sweep_cmd(args.get(2).map_or("all", String::as_str));
    }
    if file == "--install" {
        let kinds: &[klio_parity::KotlincKind] = match args.get(2).map(String::as_str) {
            Some("native") => &[klio_parity::KotlincKind::Native],
            Some("both") => &[
                klio_parity::KotlincKind::Jvm,
                klio_parity::KotlincKind::Native,
            ],
            // default and explicit "jvm"
            _ => &[klio_parity::KotlincKind::Jvm],
        };
        for k in kinds {
            match klio_parity::install_kotlinc_kind(*k, klio_parity::TARGET_VERSION) {
                Ok(p) => println!("{k:?} kotlinc ready at {}", p.display()),
                Err(e) => {
                    eprintln!("install {k:?} failed: {e}");
                    return ExitCode::from(2);
                }
            }
        }
        return ExitCode::SUCCESS;
    }
    let mut any_mismatch = false;
    for path in &args[1..] {
        let p = PathBuf::from(path);
        match klio_parity::check(&p) {
            Ok(report) => {
                if report.matched {
                    println!("[parity] {}: ok", p.display());
                } else {
                    any_mismatch = true;
                    println!("[parity] {}: MISMATCH", p.display());
                    print!("{}", klio_parity::render_diff(&report));
                }
            }
            Err(e) => {
                eprintln!("[parity] {}: error: {e}", p.display());
                return ExitCode::from(2);
            }
        }
    }
    let _ = file; // suppress unused-var warning in case args was empty
    if any_mismatch { ExitCode::from(1) } else { ExitCode::SUCCESS }
}

/// `klio-parity --sweep [corpus|examples|all]` — the fast inner loop. Compares
/// every corpus/examples file against its cached kotlinc output in parallel,
/// touching kotlinc/java only for files that changed since the last run.
fn run_sweep_cmd(which: &str) -> ExitCode {
    if klio_parity::find_kotlinc().is_err() {
        eprintln!(
            "[sweep] kotlinc not found (set KLIO_KOTLINC_JVM_HOME or run \
             `klio-parity --install`). The expected-output cache is keyed by \
             kotlinc version; a first run needs kotlinc to populate it."
        );
        return ExitCode::from(2);
    }
    let jobs = klio_parity::default_jobs();
    let timeout = Duration::from_mins(1);
    let mut groups: Vec<(&str, Vec<PathBuf>)> = Vec::new();
    if which == "corpus" || which == "all" {
        groups.push(("corpus", klio_parity::collect_kt(&klio_parity::corpus_dir())));
    }
    if which == "examples" || which == "all" {
        groups.push(("examples", klio_parity::collect_kt(&klio_parity::examples_dir())));
    }
    if groups.is_empty() {
        eprintln!("[sweep] unknown target {which:?}; use corpus | examples | all");
        return ExitCode::from(2);
    }

    let start = std::time::Instant::now();
    let mut total = 0usize;
    let mut total_pass = 0usize;
    let mut any_fail = false;
    for (label, paths) in &groups {
        match klio_parity::run_sweep(label, paths, jobs, timeout) {
            Ok(res) => {
                total += res.results.len();
                total_pass += res.passed();
                for f in res.failures() {
                    any_fail = true;
                    let rel = f.path.file_name().and_then(|s| s.to_str()).unwrap_or("?");
                    match &f.verdict {
                        klio_parity::SweepVerdict::Mismatch(report) => {
                            println!("[sweep {label}] MISMATCH {rel}");
                            print!("{}", klio_parity::render_diff(report));
                        }
                        klio_parity::SweepVerdict::KlioError(e) => {
                            println!("[sweep {label}] KLIO ERROR {rel}: {e}");
                        }
                        klio_parity::SweepVerdict::Timeout => {
                            println!("[sweep {label}] TIMEOUT {rel}");
                        }
                        klio_parity::SweepVerdict::KotlincError(_)
                        | klio_parity::SweepVerdict::Pass => {}
                    }
                }
                println!(
                    "[sweep {label}] {}/{} passed",
                    res.passed(),
                    res.results.len()
                );
            }
            Err(e) => {
                eprintln!("[sweep {label}] harness error: {e}");
                return ExitCode::from(2);
            }
        }
    }
    println!(
        "=== sweep: {total_pass}/{total} passed in {:.1}s ===",
        start.elapsed().as_secs_f64()
    );
    if any_fail { ExitCode::from(1) } else { ExitCode::SUCCESS }
}
