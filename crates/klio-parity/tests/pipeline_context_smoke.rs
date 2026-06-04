//! ktor pipeline-execution shape through the real `klio` binary: a chain of
//! `suspend Ctx.(String) -> Unit` interceptors invoked value-style
//! (`ic.invoke(this, subject)`) in a proceed-nested loop — the
//! `DebugPipelineContext` model the cores use under `DISABLE_SFG`. Covers a
//! suspending interceptor that parks at `delay` and resumes mid-chain, and
//! post-`proceed` continuation work. Expected stdout is encoded in the
//! program's `//>` lines.

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
fn pipeline_context_sync_and_async_interceptors() {
    let bin = klio_bin();
    assert!(
        bin.exists(),
        "target/release/klio missing — run `cargo build -p klio-cli --release` first"
    );
    let file = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("pipeline_context_smoke")
        .join("pipeline_ctx.kt");
    let want = expected_from_litmus(&file);
    assert!(!want.is_empty(), "no //> expected lines");
    let o = Command::new(&bin)
        .arg("run")
        .arg(&file)
        .output()
        .expect("spawn klio run");
    assert!(
        o.status.success(),
        "klio run failed: {}",
        String::from_utf8_lossy(&o.stderr)
    );
    assert_eq!(
        String::from_utf8(o.stdout).expect("utf8"),
        want,
        "pipeline_ctx.kt stdout drifted"
    );
}
