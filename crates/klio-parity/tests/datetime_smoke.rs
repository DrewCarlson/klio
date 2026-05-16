//! Datetime pack verification. Drives the kotlinx packs off their
//! `klio.toml` manifests (so the curated upstream commonMain +
//! klioMain layer is exercised through the real pack-selection path,
//! independent of `~/.klio/packs`).
//!
//! `kotlinx_demo` is the sole shipped consumer of the datetime pack;
//! its expected stdout is pinned byte-for-byte here so a regression
//! in the upstream-value-type migration fails loudly. `dt_smoke`
//! is a focused datetime litmus (leap day, UTC Instant<->LocalDateTime
//! round-trip, calendar DateTimePeriod add, and the verbatim upstream
//! Month / DayOfWeek enums + factories).

use std::path::{Path, PathBuf};

fn ws_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .map(PathBuf::from)
        .expect("workspace root")
}

/// Expected stdout = the leading run of `//> ` comment lines, matching
/// the conformance harness convention.
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
    let file = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("datetime_smoke")
        .join("dt_smoke.kt");
    let want = expected_from_litmus(&file);
    assert!(!want.is_empty(), "no //> expected lines");
    match klio_parity::run_with_all_packs(&file) {
        Ok(got) => assert_eq!(got, want, "dt_smoke.kt stdout mismatch"),
        Err(e) => panic!("dt_smoke.kt run failed: {e}"),
    }
}

/// The shipped kotlinx demo (the only consumer of the datetime pack).
/// Output is pinned byte-for-byte: the upstream-value-type migration
/// must keep this identical to the pre-change behavior.
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
pinned=2023-11-14T22:13:20Z
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
    let file = ws_root()
        .join("crates/klio-cli/tests/kotlinx_pack/kotlinx_demo.kt");
    match klio_parity::run_with_all_packs(&file) {
        Ok(got) => assert_eq!(
            got, KOTLINX_DEMO_EXPECTED,
            "kotlinx_demo.kt stdout drifted from the pinned baseline"
        ),
        Err(e) => panic!("kotlinx_demo.kt run failed: {e}"),
    }
}
