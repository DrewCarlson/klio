//! Tests for the dataflow framework, lattices, and killDataFlow
//! inference.

use klio_cfa::dataflow::{Flat, Lattice, MapLattice, infer_kill_data_flow};
use klio_cfa::lower::lower_function;
use klio_cfa::{Node, print_cfg};
use klio_lexer::Lexer;
use klio_span::SourceMap;

#[test]
fn flat_lattice_basic_joins() {
    let mut a: Flat<u32> = Flat::Bottom;
    assert!(a.join(&Flat::Value(3)));
    assert!(matches!(a, Flat::Value(3)));
    assert!(!a.join(&Flat::Value(3)));
    assert!(a.join(&Flat::Value(4)));
    assert!(matches!(a, Flat::Top));
    assert!(!a.join(&Flat::Value(99)));
    assert!(!a.join(&Flat::Top));
}

#[test]
fn map_lattice_pointwise_join() {
    let mut a: MapLattice<&'static str, Flat<u32>> = MapLattice::new();
    a.put("x", Flat::Value(1));
    let mut b: MapLattice<&'static str, Flat<u32>> = MapLattice::new();
    b.put("y", Flat::Value(2));
    assert!(a.join(&b));
    assert_eq!(a.get(&"x"), Flat::Value(1));
    assert_eq!(a.get(&"y"), Flat::Value(2));
    let mut c: MapLattice<&'static str, Flat<u32>> = MapLattice::new();
    c.put("x", Flat::Value(7));
    assert!(a.join(&c));
    assert_eq!(a.get(&"x"), Flat::Top);
    assert_eq!(a.get(&"y"), Flat::Value(2));
}

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
        klio_ast::FunctionBody::Expr(e) => {
            klio_ast::Block { stmts: vec![klio_ast::Stmt::Expr(e.clone())], span: e.span() }
        }
    };
    lower_function(&body, func.span).cfg
}

#[test]
fn kill_data_flow_injected_at_loop_head_for_reassigned_var() {
    let mut cfg = parse_lower(
        "fun main() {
            var i = 0
            while (i < 10) {
                i = i + 1
            }
        }",
    );
    infer_kill_data_flow(&mut cfg);
    let printed = print_cfg(&cfg);
    assert!(
        printed.contains("kill i"),
        "expected KillDataFlow(i) at loop head:\n{printed}"
    );
}

#[test]
fn kill_data_flow_not_injected_when_var_is_not_reassigned() {
    let mut cfg = parse_lower(
        "fun main() {
            val xs = listOf(1, 2, 3)
            val n = xs.size
            var sum = 0
            while (sum < n) {
                sum = sum + 1
            }
        }",
    );
    infer_kill_data_flow(&mut cfg);
    let printed = print_cfg(&cfg);
    // `n` is val-bound outside the loop and never reassigned, so it
    // must not be killed at the head.
    let head_section = printed
        .split("\n\nb")
        .find(|s| s.contains("kill"))
        .unwrap_or("");
    assert!(
        !head_section.contains("kill n"),
        "killDataFlow falsely reported n:\n{printed}"
    );
}

#[test]
fn straight_line_program_has_no_killdataflow() {
    let mut cfg = parse_lower(
        "fun main() {
            var i = 0
            i = i + 1
            i = i + 2
        }",
    );
    infer_kill_data_flow(&mut cfg);
    for blk in &cfg.blocks {
        for node in &blk.nodes {
            assert!(
                !matches!(node, Node::KillDataFlow { .. }),
                "no KillDataFlow expected on straight-line code"
            );
        }
    }
}
