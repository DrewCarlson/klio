//! Memory-model conformance suite. Each litmus program in
//! `tests/conformance/` is the executable form of one rule in
//! `docs/architecture/memory-model.md`. Expected stdout is encoded
//! as leading `//> ` comment lines.
//!
//! Programs whose rule does not require unimplemented machinery
//! assert exact stdout today (`conformance_runnable`). Programs
//! gated on a later stage (real coroutine happens-before, monitors,
//! threads) are listed in `conformance_gated`, which is `#[ignore]`d
//! until that stage lands — at which point the entry moves into the
//! runnable set. The gated test is the definition of "done" for the
//! stage that owns it.

use std::path::{Path, PathBuf};

fn conformance_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("conformance")
}

/// Expected stdout = the leading run of `//> ` comment lines, each
/// contributing one output line, terminated by a newline (matching
/// `run_with_ktc`'s join convention).
fn expected_stdout(file: &Path) -> String {
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

fn check(stem: &str) {
    let file = conformance_dir().join(format!("{stem}.kt"));
    assert!(file.exists(), "missing litmus {}", file.display());
    let want = expected_stdout(&file);
    assert!(!want.is_empty(), "no //> expected lines in {stem}");
    match klio_parity::run_with_packs(&file) {
        Ok(got) => assert_eq!(
            got, want,
            "conformance {stem}: stdout mismatch\n got: {got:?}\nwant: {want:?}"
        ),
        Err(e) => panic!("conformance {stem}: klio error: {e}"),
    }
}

/// Rules with no unimplemented dependency — enforced now.
const RUNNABLE: &[&str] = &[
    "mm1_no_tearing",
    "mm3_no_oota",
    "mm4_safe_publication",
    "mm5_volatile",
    "mm7_atomics",
];

// mm7 (atomicfu) is runnable today via the pack-aware runner; the
// coroutine/monitor/thread rules are gated on their owning stage.

/// Rules gated on a later stage. `(stem, owning stage)`. Moved into
/// `RUNNABLE` when that stage lands.
const GATED: &[(&str, &str)] = &[
    ("mm2_drf_sc", "cooperative correctness"),
    ("mm9_coroutine_hb", "cooperative correctness"),
    ("mm10_channel_flow", "cooperative correctness"),
    ("mm6_monitor", "single-lock threads / monitors"),
    ("mm8_thread_join", "single-lock threads"),
];

#[test]
fn conformance_runnable() {
    for stem in RUNNABLE {
        check(stem);
    }
}

#[test]
#[ignore = "gated litmus: un-ignore as each owning stage lands"]
fn conformance_gated() {
    for (stem, _stage) in GATED {
        check(stem);
    }
}

/// Every litmus file is accounted for in exactly one bucket, and
/// every spec rule MM1..MM10 has a file. Guards against silently
/// orphaned or missing litmus programs.
#[test]
fn conformance_suite_is_complete() {
    let mut on_disk: Vec<String> = std::fs::read_dir(conformance_dir())
        .expect("conformance dir")
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let p = e.path();
            (p.extension()?.to_str()? == "kt")
                .then(|| p.file_stem().unwrap().to_string_lossy().into_owned())
        })
        .collect();
    on_disk.sort();

    let mut classified: Vec<String> = RUNNABLE
        .iter()
        .map(|s| (*s).to_string())
        .chain(GATED.iter().map(|(s, _)| (*s).to_string()))
        .collect();
    classified.sort();

    assert_eq!(
        on_disk, classified,
        "every conformance/*.kt must be in RUNNABLE or GATED exactly once"
    );

    for n in 1..=10 {
        let prefix = format!("mm{n}_");
        assert!(
            classified.iter().any(|s| s.starts_with(&prefix)),
            "spec rule MM{n} has no litmus program"
        );
    }
}
