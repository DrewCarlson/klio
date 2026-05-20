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

// Each smoke source is its own `#[test]` fn so cargo's test harness
// can run them in parallel — the wall-clock for this binary was
// previously dominated by 7 serial `run_with_packs` calls.
fn run_smoke(stem: &str) {
    let file = dir().join(format!("{stem}.kt"));
    let want = expected(stem);
    assert!(!want.is_empty(), "no //> lines in {stem}");
    match klio_parity::run_with_packs(&file) {
        Ok(got) => assert_eq!(got, want, "coroutine smoke {stem} regressed"),
        Err(e) => panic!("coroutine smoke {stem}: {e}"),
    }
}

#[test] fn cs1_launch_delay()    { run_smoke("cs1_launch_delay"); }
#[test] fn cs2_async_await()     { run_smoke("cs2_async_await"); }
#[test] fn cs3_many_launch()     { run_smoke("cs3_many_launch"); }
#[test] fn cs4_suspend_seq()     { run_smoke("cs4_suspend_seq"); }
#[test] fn cs5_flow_builder()    { run_smoke("cs5_flow_builder"); }
#[test] fn cs6_flow_operators()  { run_smoke("cs6_flow_operators"); }
#[test] fn cs7_scope_builders()  { run_smoke("cs7_scope_builders"); }
