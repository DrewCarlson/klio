//! kotlin.coroutines **language layer** verification through the real
//! shipping path: run a deterministic program with the actual `klio`
//! binary. The pure kotlin.coroutines commonMain types
//! (CoroutineContext / EmptyCoroutineContext / ContinuationInterceptor
//! / Continuation) are consumed verbatim from the upstream Kotlin
//! checkout via the embedded stdlib pack's curated SOURCES; klio's
//! platform layer supplies the intrinsic surface
//! (suspendCoroutineUninterceptedOrReturn, startCoroutine, the
//! slot-backed continuation) bridged onto the inline suspension
//! engine. Distinct from `coroutine_smoke` (the kotlinx.coroutines
//! pack shim) — this exercises only the language/stdlib layer.

use std::path::{Path, PathBuf};
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

fn run_via_binary(file: &Path) -> String {
    let o = Command::new(klio_bin())
        .arg("run")
        .arg(file)
        .output()
        .expect("spawn klio run");
    assert!(
        o.status.success(),
        "klio run {} failed: {}",
        file.display(),
        String::from_utf8_lossy(&o.stderr)
    );
    String::from_utf8(o.stdout).expect("utf8 stdout")
}

fn expected_from_litmus(file: &Path) -> String {
    let src = std::fs::read_to_string(file).expect("read litmus");
    let mut out = String::new();
    for line in src.lines() {
        let t = line.trim_start();
        if let Some(rest) = t.strip_prefix("//>") {
            out.push_str(rest.strip_prefix(' ').unwrap_or(rest));
            out.push('\n');
        }
    }
    out
}

#[test]
fn coroutine_lang_smoke_litmus() {
    let bin = klio_bin();
    assert!(
        bin.exists(),
        "target/release/klio missing — run `cargo build -p klio-cli --release` first"
    );
    let file = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("coroutine_lang_smoke")
        .join("co_lang_smoke.kt");
    let want = expected_from_litmus(&file);
    assert!(!want.is_empty(), "no //> expected lines");
    assert_eq!(
        run_via_binary(&file),
        want,
        "co_lang_smoke.kt stdout drifted (kotlin.coroutines SOURCES path)"
    );
}
