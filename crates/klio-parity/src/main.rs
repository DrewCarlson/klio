//! `klio-parity <file.kt>` — compare our interpreter against JVM `kotlinc`.
//! Exit code 0 on parity, 1 on mismatch, 2 on harness error.

use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let Some(file) = args.get(1) else {
        eprintln!(
            "usage: klio-parity <file.kt> [<file.kt> ...]\n       \
             klio-parity --install [jvm|native|both]"
        );
        return ExitCode::from(2);
    };
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
