//! `klio check --unimplemented`: the ahead-of-time scan for `expect`
//! declarations with no `actual` body and no host intrinsic (the silent
//! `Unit` failure mode). Driven through the real `klio` binary.

use std::path::PathBuf;
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

#[test]
fn reports_user_expect_without_actual() {
    let bin = klio_bin();
    assert!(bin.exists(), "build the release binary first");
    let dir = std::env::temp_dir().join("klio_unimpl_check");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("prog.kt");
    // A top-level `expect` the program calls, with no actual anywhere and
    // no host intrinsic: exactly the silent-`Unit` shape the check exists
    // to surface. The name is deliberately obscure so no real binding or
    // future implementation collides with it.
    std::fs::write(
        &file,
        "expect fun zzUnimplementedPlatformHook(x: Int): Int\n\
         fun main() { println(zzUnimplementedPlatformHook(1)) }\n",
    )
    .unwrap();

    let out = Command::new(&bin)
        .args(["check", "--unimplemented"])
        .arg(&file)
        .output()
        .expect("klio check --unimplemented");

    let stdout = String::from_utf8_lossy(&out.stdout);
    // Non-zero exit when at least one unimplemented expect is reachable.
    assert!(
        !out.status.success(),
        "expected non-zero exit; stdout:\n{stdout}"
    );
    assert!(
        stdout.contains("zzUnimplementedPlatformHook"),
        "report should name the unimplemented expect; stdout:\n{stdout}"
    );
}
