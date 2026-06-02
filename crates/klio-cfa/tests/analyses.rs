//! Tests for the CFG analyses: VIA, reachability, finally pruning.

use klio_cfa::analyses::{finally, reachable, via};
use klio_cfa::dataflow::Flat;
use klio_cfa::lower::lower_function;
use klio_cfa::{BlockId, Place, Symbol};
use klio_lexer::Lexer;
use klio_span::SourceMap;

fn parse_lower(src: &str) -> klio_cfa::Cfg {
    let mut map = SourceMap::new();
    let id = map.add("t.kt", src);
    let owned = map.get(id).source.clone();
    let lexed = Lexer::new(id, &owned).tokenize();
    let (file, _) = klio_parser::Parser::new(id, &owned, &lexed.tokens).parse_file();
    let func = file
        .decls
        .iter()
        .find_map(|d| match d {
            klio_ast::Decl::Function(f) => Some(f),
            _ => None,
        })
        .unwrap();
    let body = match func.body.as_ref().unwrap() {
        klio_ast::FunctionBody::Block(b) => b.clone(),
        klio_ast::FunctionBody::Expr(e) => klio_ast::Block {
            stmts: vec![klio_ast::Stmt::Expr(e.clone())],
            span: e.span(),
        },
    };
    lower_function(&body, func.span).cfg
}

#[test]
// block count fits in u32
#[allow(clippy::cast_possible_truncation)]
fn via_marks_declared_var_unassigned_then_assigned() {
    let cfg = parse_lower(
        "fun main() {
            var x: Int = 0
            x = 7
        }",
    );
    let states = via::solve_via(&cfg);
    // Pick the last reachable block (function exit). `x` should be
    // recorded as Assigned by the time we reach it.
    let last = BlockId(cfg.blocks.len() as u32 - 1);
    let s = via::place_state_at_block_entry(&states, last, &Place::Local(Symbol("x".into())));
    assert!(
        matches!(s, Flat::Value(via::AssignState::Assigned)),
        "expected x to be Assigned at exit, got {s:?}"
    );
}

#[test]
fn via_reports_unassigned_via_branch_join() {
    // x is declared but not initialised, then assigned only in one
    // arm of an if — at the join the lattice flips it to Unassigned
    // (the bottom representative of "may not be assigned").
    let cfg = parse_lower(
        "fun foo() {
            val x: Int
            val flag = true
            if (flag) {
                println(\"hi\")
            }
        }",
    );
    let states = via::solve_via(&cfg);
    let maybe = via::maybe_unassigned_places(&states);
    let names: Vec<String> = maybe.keys().map(|p| format!("{p:?}")).collect();
    assert!(
        names.iter().any(|n| n.contains("\"x\"")),
        "expected x to appear in maybe-unassigned places, got {names:?}"
    );
}

#[test]
fn reachability_after_return_is_dead() {
    let cfg = parse_lower(
        "fun main() {
            val x = 1
            return
            val y = 2
        }",
    );
    let r = reachable::analyse(&cfg);
    // The block holding `val y = 2` must end up unreachable.
    let mut found_dead = false;
    for blk in &cfg.blocks {
        let has_y = blk
            .nodes
            .iter()
            .any(|n| matches!(n, klio_cfa::Node::DeclLocal { place, .. } if place.0 == "y"));
        if has_y {
            found_dead = !r.is_reachable(blk.id);
        }
    }
    assert!(found_dead, "y's block should be unreachable after return");
}

#[test]
fn reachability_marks_main_path_reachable() {
    let cfg = parse_lower("fun main() { val x = 1 }");
    let r = reachable::analyse(&cfg);
    assert!(r.is_reachable(cfg.entry));
}

#[test]
fn finally_pruning_is_a_noop_on_normal_finally() {
    let mut cfg = parse_lower(
        "fun main() {
            try {
                val x = 1
            } finally {
                val y = 2
            }
        }",
    );
    let pruned = finally::prune_divergent_finally(&mut cfg);
    assert_eq!(
        pruned, 0,
        "finally with no divergent terminator should not prune"
    );
}
