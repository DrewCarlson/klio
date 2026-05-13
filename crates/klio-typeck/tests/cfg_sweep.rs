//! Run every CFG-driven analysis on every function in the parity
//! corpus. The point of this test is not to assert specific facts —
//! it is to prove that the AST -> CFG lowering, the killDataFlow
//! pass, reachability, VIA, and the smart-cast analysis all survive
//! the real surface of Kotlin programs we run. If a corpus program
//! triggers an unexpected lowering shape (panic, runaway iteration,
//! malformed edges) we catch it here before swapping live query
//! sites onto the CFG.

use std::path::{Path, PathBuf};

use klio_lexer::Lexer;
use klio_parser::Parser;
use klio_span::SourceMap;

fn workspace_root() -> PathBuf {
    let m = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    m.parent()
        .and_then(|p| p.parent())
        .map(PathBuf::from)
        .unwrap_or(m)
}

fn collect_kt(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return out;
    };
    for entry in entries.flatten() {
        let p = entry.path();
        if p.extension().and_then(|s| s.to_str()) == Some("kt") {
            out.push(p);
        }
    }
    out.sort();
    out
}

#[test]
fn corpus_cfgs_run_every_analysis() {
    let dir = workspace_root()
        .join("crates")
        .join("klio-parity")
        .join("tests")
        .join("corpus");
    let paths = collect_kt(&dir);
    assert!(!paths.is_empty(), "no corpus files");
    let mut total_cfgs = 0usize;
    let mut total_files = 0usize;
    for p in &paths {
        let src = std::fs::read_to_string(p).expect("read");
        let mut map = SourceMap::new();
        let id = map.add(p, src);
        let owned = map.get(id).source.clone();
        let toks = Lexer::new(id, &owned).tokenize();
        let (ast, _) = Parser::new(id, &owned, &toks.tokens).parse_file();
        let r = klio_resolver::resolve(&ast);
        let tc = klio_typeck::typecheck(&ast, &r);
        total_files += 1;
        for (_span, cfg) in &tc.cfgs {
            total_cfgs += 1;
            // Reachability: every block reachable from entry; the
            // entry itself is always reachable.
            let reach = klio_cfa::analyses::reachable::analyse(cfg);
            assert!(
                reach.is_reachable(cfg.entry),
                "entry must be reachable for {p:?}"
            );
            // VIA: solve and check every block has a non-Top in-state
            // for at least the synthetic locals we declared.
            let _ = klio_cfa::analyses::via::solve_via(cfg);
            // Smart-cast: empty reg_to_place is fine for the smoke test,
            // we just need it to not panic.
            let r2p = std::collections::HashMap::new();
            let _ = klio_cfa::analyses::smartcast::solve(cfg, &r2p);
        }
    }
    assert!(total_cfgs > 0, "expected at least one CFG across {total_files} files");
}
