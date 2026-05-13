//! Build script: produce `stdlib.klio-pack` in `OUT_DIR` so the crate
//! root can embed it via `include_bytes!`. The script is fast (low
//! single-digit seconds) and runs at most once per Cargo build of
//! this crate. We declare narrow `rerun-if-changed` lines so an edit
//! to an unrelated crate does not trigger a re-pack.

use std::path::PathBuf;

fn main() {
    let out_dir = std::env::var_os("OUT_DIR").expect("OUT_DIR set by Cargo");
    let dest = PathBuf::from(&out_dir).join("stdlib.klio-pack");

    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=KLIO_STDLIB_PACK_FORCE_REBUILD");
    // Re-run when any klio-stdlib source changes.
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let stdlib_src = PathBuf::from(&manifest_dir)
        .join("..")
        .join("klio-stdlib")
        .join("src");
    rerun_dir(&stdlib_src);

    let bytes = klio_stdlib::build_stdlib_pack(true).expect("build stdlib pack");
    std::fs::write(&dest, &bytes).expect("write stdlib pack");
    println!(
        "cargo:warning=klio-stdlib-pack: wrote {} ({} bytes)",
        dest.display(),
        bytes.len()
    );
}

fn rerun_dir(dir: &std::path::Path) {
    if !dir.exists() {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let p = e.path();
        if p.is_dir() {
            rerun_dir(&p);
        } else {
            println!("cargo:rerun-if-changed={}", p.display());
        }
    }
}
