//! Datetime pack verification through the **real shipping path**:
//! build + install the kotlinx packs and run the program with the
//! actual `klio` binary (whose import-gated loader is what users
//! get). An earlier in-process all-pack co-loader was unrepresentative
//! of that path and tripped an unrelated interpreter bug; this drives
//! exactly what ships.
//!
//! `kotlinx_demo` is the sole shipped consumer of the datetime pack;
//! its stdout is pinned byte-for-byte so the upstream-value-type
//! migration must keep it identical. `dt_smoke` is a focused datetime
//! litmus (leap day, UTC Instant<->LocalDateTime round-trip, calendar
//! DateTimePeriod add, verbatim upstream Month/DayOfWeek enums).

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

/// Build + install the four kotlinx packs from the current tree so
/// the binary's `~/.klio/packs` loader reflects HEAD. Idempotent.
fn install_packs() {
    let bin = klio_bin();
    assert!(
        bin.exists(),
        "target/release/klio missing — run `cargo build -p klio-cli --release` first"
    );
    for pack in [
        "klio-kotlinx-coroutines",
        "klio-kotlinx-atomicfu",
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
        } else if t.starts_with("//") {
            continue;
        } else if out.is_empty() {
            continue;
        } else {
            break;
        }
    }
    out
}

#[test]
fn datetime_smoke_litmus() {
    install_packs();
    let file = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("datetime_smoke")
        .join("dt_smoke.kt");
    let want = expected_from_litmus(&file);
    assert!(!want.is_empty(), "no //> expected lines");
    assert_eq!(run_via_binary(&file), want, "dt_smoke.kt stdout mismatch");
}

/// The shipped kotlinx demo (the only consumer of the datetime pack),
/// pinned byte-for-byte through the real binary path.
const KOTLINX_DEMO_EXPECTED: &str = "\
== atomicfu ==
int=5
long=42
bool=true swapped=true
ref=hello
== kotlinx.io ==
size_before=14
int=42 long=1000000000000 str=kt
empty=true
== kotlinx.datetime ==
pinned=1700000000000
delta_min=120
ldt=2023-11-14T22:13:20
roundtrip=true
== kotlinx.coroutines ==
start
after-delay
done
";

#[test]
fn kotlinx_demo_byte_identical() {
    install_packs();
    let file = ws_root().join("crates/klio-cli/tests/kotlinx_pack/kotlinx_demo.kt");
    assert_eq!(
        run_via_binary(&file),
        KOTLINX_DEMO_EXPECTED,
        "kotlinx_demo.kt stdout drifted from the pinned baseline"
    );
}
