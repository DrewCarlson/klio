//! `klio-diagnostics-gen build` — mines kotlinc factory declarations and
//! emits `crates/klio-diagnostics/src/generated/factories.rs`.

use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let cmd = args.get(1).map_or("build", String::as_str);
    let rest: &[String] = if args.len() > 2 { &args[2..] } else { &[] };
    match cmd {
        "build" => build(rest),
        other => {
            eprintln!("unknown subcommand: {other}");
            eprintln!("usage: klio-diagnostics-gen build [--kotlin <path>] [--out <path>]");
            ExitCode::from(2)
        }
    }
}

fn build(args: &[String]) -> ExitCode {
    let mut kotlin = klio_diagnostics_gen::default_kotlin_root();
    let mut out = klio_diagnostics_gen::default_out_file();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--kotlin" => {
                if let Some(v) = args.get(i + 1) {
                    kotlin = PathBuf::from(v);
                    i += 2;
                    continue;
                }
            }
            "--out" => {
                if let Some(v) = args.get(i + 1) {
                    out = PathBuf::from(v);
                    i += 2;
                    continue;
                }
            }
            _ => {}
        }
        i += 1;
    }
    if !kotlin.is_dir() {
        eprintln!("kotlin checkout not found: {}", kotlin.display());
        return ExitCode::from(2);
    }
    eprintln!("mining {}", kotlin.display());
    let factories = klio_diagnostics_gen::mine(&kotlin);
    eprintln!("found {} factories", factories.len());
    match klio_diagnostics_gen::emit(&factories, &out) {
        Ok(()) => {
            eprintln!("wrote {}", out.display());
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("emit failed: {e}");
            ExitCode::from(1)
        }
    }
}
