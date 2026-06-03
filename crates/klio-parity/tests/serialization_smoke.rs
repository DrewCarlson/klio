//! kotlinx-serialization pack verification through the **real
//! shipping path**: build + install the kotlinx packs and run the
//! program with the actual `klio` binary (whose import-gated loader is
//! what users get).
//!
//! `ser_smoke` exercises the reflection-synthesized `KSerializer` (the
//! compiler-plugin replacement) over plain `@Serializable` classes
//! (incl. a nullable field), the klioMain primitive serializers, and a
//! datetime `LocalDate` / `Instant` reflective round-trip — the latter
//! proving the kotlinx.datetime -> kotlinx.serialization pack
//! dependency. The encoder/decoder is a tiny in-program flat-list pair
//! built on the upstream `AbstractEncoder` / `AbstractDecoder`
//! consumed verbatim from the serialization-core submodule, so the
//! round-trip goes through real upstream code.

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

/// Build + install the kotlinx packs from the current tree so the
/// binary's `~/.klio/packs` loader reflects HEAD. Idempotent.
fn install_packs() {
    let bin = klio_bin();
    assert!(
        bin.exists(),
        "target/release/klio missing — run `cargo build -p klio-cli --release` first"
    );
    for pack in [
        "klio-kotlinx-coroutines",
        "klio-kotlinx-atomicfu",
        "klio-kotlinx-serialization",
        "klio-kotlinx-datetime",
        "klio-kotlinx-io",
    ] {
        let dir = ws_root().join("crates").join(pack);
        let out = std::env::temp_dir().join(format!("{pack}.klio-pack"));
        let b = Command::new(&bin)
            .args(["pack", "build"])
            .arg(&dir)
            .arg("--out")
            .arg(&out)
            .output()
            .expect("spawn klio pack build");
        assert!(
            b.status.success(),
            "pack build {pack} failed: {}",
            String::from_utf8_lossy(&b.stderr)
        );
        let i = Command::new(&bin)
            .args(["pack", "install"])
            .arg(&out)
            .output()
            .expect("spawn klio pack install");
        assert!(
            i.status.success(),
            "pack install {pack} failed: {}",
            String::from_utf8_lossy(&i.stderr)
        );
    }
}

/// Run `file` through the real `klio` binary, returning stdout.
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

/// Expected stdout = the leading run of `//> ` comment lines.
fn expected_from_litmus(file: &Path) -> String {
    let src = std::fs::read_to_string(file).expect("read litmus");
    let mut out = String::new();
    for line in src.lines() {
        let t = line.trim_start();
        if let Some(rest) = t.strip_prefix("//>") {
            out.push_str(rest.strip_prefix(' ').unwrap_or(rest));
            out.push('\n');
        } else if t.starts_with("//") || out.is_empty() {
            // Skip leading comments and blank lead-in.
        } else {
            break;
        }
    }
    out
}

fn litmus(name: &str) {
    install_packs();
    let file = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("serialization_smoke")
        .join(name);
    let want = expected_from_litmus(&file);
    assert!(!want.is_empty(), "no //> expected lines");
    assert_eq!(run_via_binary(&file), want, "{name} stdout mismatch");
}

#[test]
fn serialization_smoke_litmus() {
    litmus("ser_smoke.kt");
}

/// `Json.encodeToString` / `decodeFromString` over primitives, a nested
/// `@Serializable`, `List<@Serializable>`, `Map<String, @Serializable>`,
/// an enum field, and a nullable field — plus declaration-order keys and
/// the `prettyPrint` / `ignoreUnknownKeys` builder options.
#[test]
fn json_smoke_litmus() {
    litmus("json_smoke.kt");
}
