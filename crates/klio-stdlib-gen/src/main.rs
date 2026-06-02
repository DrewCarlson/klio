//! Stdlib codegen binary.
//!
//! Subcommands:
//! * `build` mines the upstream stdlib sources and emits Rust into
//!   `crates/klio-stdlib/src/generated/`.
//! * `coverage` prints implemented / total counts from the current
//!   generated registry.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};

use klio_stdlib_gen::{collect_decls, emit_generated};

#[derive(Parser)]
#[command(
    name = "klio-stdlib-gen",
    about = "Kotlin stdlib codegen for klio-stdlib"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    Build {
        /// Path to the upstream Kotlin checkout's stdlib root
        /// (`<repo>/kotlin/libraries/stdlib`).
        #[arg(long)]
        stdlib: Option<PathBuf>,
        /// Output directory for generated Rust
        /// (`<repo>/crates/klio-stdlib/src/generated`).
        #[arg(long)]
        out: Option<PathBuf>,
    },
    Coverage,
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Build { stdlib, out } => build(stdlib, out),
        Cmd::Coverage => coverage(),
    }
}

fn workspace_root() -> PathBuf {
    // CARGO_MANIFEST_DIR is `crates/klio-stdlib-gen` at build time; back off two
    // dirs to the workspace root.
    let m = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    m.parent()
        .and_then(|p| p.parent())
        .map(PathBuf::from)
        .unwrap_or(m)
}

fn build(stdlib: Option<PathBuf>, out: Option<PathBuf>) -> ExitCode {
    let root = workspace_root();
    let stdlib_path = stdlib.unwrap_or_else(|| root.join("kotlin/libraries/stdlib"));
    let out_dir = out.unwrap_or_else(|| root.join("crates/klio-stdlib/src/generated"));

    if !stdlib_path.is_dir() {
        eprintln!("stdlib root not found: {}", stdlib_path.display());
        return ExitCode::from(2);
    }

    eprintln!("mining {}", stdlib_path.display());
    let (files, stats) = collect_decls(&stdlib_path);

    eprintln!(
        "scanned {} files, parsed {}, failed {}",
        stats.files_seen,
        stats.files_parsed,
        stats.files_failed.len()
    );
    for (p, e) in &stats.files_failed {
        eprintln!("  failed: {} — {}", p.display(), e);
    }
    eprintln!("extracted {} declarations", stats.total_decls);

    match emit_generated(&out_dir, &files) {
        Ok(n) => {
            eprintln!("wrote {} symbols to {}", n, out_dir.display());
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("emit failed: {e}");
            ExitCode::from(1)
        }
    }
}

fn coverage() -> ExitCode {
    let c = klio_stdlib::coverage();
    println!(
        "implemented {} / total {} ({:.2}%)",
        c.implemented,
        c.total,
        c.percent()
    );
    if c.total == 0 {
        println!("registry is empty — run `klio-stdlib-gen build` first");
    }
    ExitCode::SUCCESS
}
