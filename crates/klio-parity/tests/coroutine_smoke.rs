//! Regression net for the currently-working coroutine subset. These
//! lock down behavior across the layer-split and later coroutine
//! stages: a pure refactor must not change any of these outputs.
//! Expected stdout is encoded as leading `//> ` comment lines.

use std::path::PathBuf;

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("coroutine_smoke")
}

fn expected(stem: &str) -> String {
    let src = std::fs::read_to_string(dir().join(format!("{stem}.kt"))).expect("read");
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

const SMOKE: &[&str] = &[
    "cs1_launch_delay",
    "cs2_async_await",
    "cs3_many_launch",
    "cs4_suspend_seq",
    "cs5_flow_builder",
    "cs6_flow_operators",
    "cs7_scope_builders",
];

#[test]
fn coroutine_smoke() {
    for stem in SMOKE {
        let file = dir().join(format!("{stem}.kt"));
        let want = expected(stem);
        assert!(!want.is_empty(), "no //> lines in {stem}");
        match klio_parity::run_with_packs(&file) {
            Ok(got) => assert_eq!(got, want, "coroutine smoke {stem} regressed"),
            Err(e) => panic!("coroutine smoke {stem}: {e}"),
        }
    }
}
