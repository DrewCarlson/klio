//! `ktc-parity <file.kt>` — compare our interpreter against `kotlinc-native`.
//! Exit code 0 on parity, 1 on mismatch, 2 on harness error.

use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let Some(file) = args.get(1) else {
        eprintln!("usage: ktc-parity <file.kt> [<file.kt> ...]");
        return ExitCode::from(2);
    };
    let mut any_mismatch = false;
    for path in &args[1..] {
        let p = PathBuf::from(path);
        match ktc_parity::check(&p) {
            Ok(report) => {
                if report.matched {
                    println!("[parity] {}: ok", p.display());
                } else {
                    any_mismatch = true;
                    println!("[parity] {}: MISMATCH", p.display());
                    print!("{}", ktc_parity::render_diff(&report));
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
