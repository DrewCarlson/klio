//! Threaded-litmus suite. Each program in `tests/threaded_litmus/`
//! pins down one observable guarantee of multi-threaded execution
//! (mutual exclusion, publication, no lost update). Expected stdout
//! is encoded as leading `//> ` comment lines, exactly like the
//! memory-model `conformance` suite.
//!
//! Programs whose guarantee already holds under the serialized
//! interpreter (a `synchronized` block reduces to in-order execution
//! on one thread) assert exact stdout today (`RUNNABLE`). Programs
//! that genuinely need OS-thread spawning to be meaningful are listed
//! in `PENDING`, keyed by the blocker, and run by an `#[ignore]`d
//! test until real thread spawn lands — at which point the entry
//! moves into `RUNNABLE`. This file is the growth point for the real
//! threaded litmus corpus; today it is scaffold plus one smoke
//! program.

use std::path::{Path, PathBuf};

fn litmus_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("threaded_litmus")
}

/// Expected stdout = the leading run of `//> ` comment lines, each
/// contributing one output line (matching `run_with_packs`'s join
/// convention). Mirrors the `conformance` harness.
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
    let file = litmus_dir().join(format!("{stem}.kt"));
    assert!(file.exists(), "missing litmus {}", file.display());
    let want = expected_stdout(&file);
    assert!(!want.is_empty(), "no //> expected lines in {stem}");
    match klio_parity::run_with_packs(&file) {
        Ok(got) => assert_eq!(
            got, want,
            "threaded litmus {stem}: stdout mismatch\n got: {got:?}\nwant: {want:?}"
        ),
        Err(e) => panic!("threaded litmus {stem}: klio error: {e}"),
    }
}

/// Guarantees that hold under the serialized interpreter today —
/// enforced now.
const RUNNABLE: &[&str] = &[
    "tl_smoke",
    "tl_thread_join",
    "tl_sync_counter",
    "tl_parallel_partition",
];

/// Guarantees that only become meaningful with real OS-thread
/// spawning. `(stem, blocker)`. Each moves into `RUNNABLE` when its
/// blocker lands. Empty today: the threaded corpus grows here.
const PENDING: &[(&str, &str)] = &[
    // ("tl_two_thread_monitor", "needs real thread spawn"),
    // ("tl_safe_publication",   "needs real thread spawn"),
];

#[test]
fn threaded_litmus_runnable() {
    for stem in RUNNABLE {
        check(stem);
    }
}

#[test]
#[ignore = "pending litmus: un-ignore as real thread spawn lands"]
fn threaded_litmus_pending() {
    for (stem, _blocker) in PENDING {
        check(stem);
    }
}

/// Every litmus file on disk is classified exactly once. Guards
/// against an orphaned or unlisted program slipping in.
#[test]
fn threaded_litmus_suite_is_complete() {
    let mut on_disk: Vec<String> = std::fs::read_dir(litmus_dir())
        .expect("threaded_litmus dir")
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
        .chain(PENDING.iter().map(|(s, _)| (*s).to_string()))
        .collect();
    classified.sort();

    assert_eq!(
        on_disk, classified,
        "every threaded_litmus/*.kt must be in RUNNABLE or PENDING exactly once"
    );
}
