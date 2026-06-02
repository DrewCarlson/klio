//! End-to-end bench driver. Emits stable JSON on stdout and human
//! summary on stderr.
//!
//! Usage:
//!   klio-bench            # all corpora, fast budget
//!   klio-bench --full     # extended workloads, ref runners (if --features ref)
//!   klio-bench --json     # JSON only, no stderr summary
//!   klio-bench --diff <baseline.json>
//!
//! The driver is intentionally argument-light; richer cadence lives in
//! the `cargo bench` harness.

use std::env;
use std::fs;
use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;

use klio_bench::schema::{BenchRecord, BenchReport, RegressionLevel, diff};
use klio_bench::{Program, collect_kt, corpus_root, time_pipeline_stages};

#[cfg(feature = "dhat")]
#[global_allocator]
static ALLOC: dhat::Alloc = dhat::Alloc;

struct Args {
    full: bool,
    json_only: bool,
    diff_path: Option<PathBuf>,
    out_path: Option<PathBuf>,
    filter: Option<String>,
}

enum ParsedArgs {
    Ok(Args),
    Exit(ExitCode),
}

fn parse_args(args: &[String]) -> ParsedArgs {
    let mut full = false;
    let mut json_only = false;
    let mut diff_path: Option<PathBuf> = None;
    let mut out_path: Option<PathBuf> = None;
    let mut filter: Option<String> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--full" => full = true,
            "--json" => json_only = true,
            "--diff" => {
                i += 1;
                diff_path = args.get(i).map(PathBuf::from);
            }
            "--out" => {
                i += 1;
                out_path = args.get(i).map(PathBuf::from);
            }
            "--filter" => {
                i += 1;
                filter = args.get(i).cloned();
            }
            "-h" | "--help" => {
                eprintln!(
                    "klio-bench [--full] [--json] [--filter substr] [--out file] [--diff baseline.json]"
                );
                return ParsedArgs::Exit(ExitCode::SUCCESS);
            }
            other => {
                eprintln!("unknown arg: {other}");
                return ParsedArgs::Exit(ExitCode::from(2));
            }
        }
        i += 1;
    }
    ParsedArgs::Ok(Args {
        full,
        json_only,
        diff_path,
        out_path,
        filter,
    })
}

fn report_diff(base_path: &std::path::Path, report: &BenchReport) -> Option<ExitCode> {
    match fs::read_to_string(base_path)
        .ok()
        .and_then(|s| serde_json::from_str::<BenchReport>(&s).ok())
    {
        None => {
            eprintln!(
                "[bench] baseline {} unreadable; skipping diff",
                base_path.display()
            );
        }
        Some(b) => {
            let rows = diff(&b, report);
            let mut red = 0;
            let mut yellow = 0;
            for r in &rows {
                let tag = match r.level {
                    RegressionLevel::Green => " ok",
                    RegressionLevel::Yellow => {
                        yellow += 1;
                        "yel"
                    }
                    RegressionLevel::Red => {
                        red += 1;
                        "RED"
                    }
                };
                eprintln!(
                    "[{tag}] {:>8} {:<40} {:>10} ns  ({:+.1}%)",
                    r.stage,
                    r.workload,
                    r.cur_ns,
                    (r.ratio - 1.0) * 100.0,
                );
            }
            eprintln!("[bench] {red} red, {yellow} yellow, {} total", rows.len());
            if red > 0 {
                return Some(ExitCode::from(1));
            }
        }
    }
    None
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().skip(1).collect();
    let Args {
        full,
        json_only,
        diff_path,
        out_path,
        filter,
    } = match parse_args(&args) {
        ParsedArgs::Ok(a) => a,
        ParsedArgs::Exit(code) => return code,
    };

    #[cfg(feature = "dhat")]
    let _dhat = dhat::Profiler::new_heap();

    let files = collect_kt(&corpus_root());
    let budget = if full {
        Duration::from_millis(1500)
    } else {
        Duration::from_millis(250)
    };
    let mut records = Vec::new();
    for path in files {
        let prog = match Program::load(path.clone()) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("skip {}: {e}", path.display());
                continue;
            }
        };
        let label = prog.label();
        if let Some(f) = &filter
            && !label.contains(f)
        {
            continue;
        }
        if !json_only {
            eprintln!("[bench] {label}");
        }
        let stages = time_pipeline_stages(&prog, budget);
        for (stage, t) in [
            ("lex", stages.lex),
            ("parse", stages.parse),
            ("resolve", stages.resolve),
            ("typeck", stages.typeck),
            ("e2e", stages.e2e),
        ] {
            #[allow(unused_mut)]
            let mut rec = BenchRecord {
                stage: stage.into(),
                workload: label.clone(),
                median_ns: t.median_ns,
                p99_ns: t.p99_ns,
                iters: t.iters,
                allocs: None,
                alloc_bytes: None,
                ref_kotlinc_native_ns: None,
                ref_kotlinc_jvm_ns: None,
            };
            #[cfg(feature = "ref")]
            if full && stage == "e2e" {
                use klio_bench::refrunner;
                if let Ok(d) = refrunner::time_kotlinc_native(&prog.path, 3) {
                    rec.ref_kotlinc_native_ns = Some(d.as_nanos() as u64);
                }
                if let Ok(d) = refrunner::time_kotlinc_jvm(&prog.path, 3) {
                    rec.ref_kotlinc_jvm_ns = Some(d.as_nanos() as u64);
                }
            }
            records.push(rec);
        }
    }

    let report = BenchReport {
        git_sha: git_sha().unwrap_or_else(|| "unknown".into()),
        host: host_string(),
        records,
    };

    let json = serde_json::to_string_pretty(&report).expect("serialize");
    if let Some(p) = &out_path {
        if let Err(e) = fs::write(p, &json) {
            eprintln!("write {}: {e}", p.display());
            return ExitCode::FAILURE;
        }
    } else {
        println!("{json}");
    }

    if let Some(base) = diff_path
        && let Some(code) = report_diff(&base, &report)
    {
        return code;
    }

    ExitCode::SUCCESS
}

fn git_sha() -> Option<String> {
    let out = std::process::Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn host_string() -> String {
    format!("{}-{}", env::consts::OS, env::consts::ARCH)
}
