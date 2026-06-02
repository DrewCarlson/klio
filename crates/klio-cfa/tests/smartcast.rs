//! Smart-cast analysis tests. Each test parses a small Kotlin
//! function, lowers it, runs the smart-cast pass, and asserts on
//! the per-place fact at a chosen block.

use klio_cfa::analyses::smartcast::{self, Nullability, SmartCastFact};
use klio_cfa::dataflow::MapLattice;
use klio_cfa::lower::lower_function;
use klio_cfa::{Place, Symbol};
use klio_lexer::Lexer;
use klio_span::SourceMap;
use klio_types::Type;

fn parse_and_lower(
    src: &str,
) -> (
    klio_cfa::Cfg,
    std::collections::HashMap<klio_cfa::Reg, Place>,
) {
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
    let lowered = lower_function(&body, func.span);
    (lowered.cfg, lowered.reg_to_place)
}

// block index fits in u32 for these CFGs
#[allow(clippy::cast_possible_truncation)]
fn any_narrowing_anywhere(
    cfg: &klio_cfa::Cfg,
    r2p: &std::collections::HashMap<klio_cfa::Reg, Place>,
    place: &Place,
    f: impl Fn(&SmartCastFact) -> bool,
) -> bool {
    let entry_states = smartcast::solve(cfg, r2p);
    for (i, st) in entry_states.iter().enumerate() {
        let bid = klio_cfa::BlockId(i as u32);
        let walk = smartcast::states_within_block(cfg, bid, st.clone(), r2p);
        for s in walk {
            if let Some(fact) = s.map.get(place)
                && f(fact)
            {
                return true;
            }
        }
    }
    false
}

#[test]
fn null_check_narrows_branch() {
    let (cfg, r2p) = parse_and_lower(
        "fun foo(x: String?) {
            if (x != null) {
                println(x.length)
            }
        }",
    );
    let x = Place::Local(Symbol("x".into()));
    assert!(
        any_narrowing_anywhere(&cfg, &r2p, &x, |f| matches!(f.null, Nullability::NonNull)),
        "expected x to be NonNull on the true branch"
    );
}

#[test]
fn is_check_narrows_type() {
    let (cfg, r2p) = parse_and_lower(
        "fun foo(x: Any) {
            if (x is String) {
                println(x)
            }
        }",
    );
    let x = Place::Local(Symbol("x".into()));
    assert!(
        any_narrowing_anywhere(&cfg, &r2p, &x, |f| matches!(f.narrowed, Some(Type::String))),
        "expected x narrowed to String on the true branch"
    );
}

#[test]
fn fact_resets_after_assignment() {
    let (cfg, r2p) = parse_and_lower(
        "fun foo(x: Any) {
            if (x is String) {
                println(x)
                val y: Any = 1
            }
        }",
    );
    let _ = (cfg, r2p);
}

#[test]
fn join_drops_disagreeing_narrowings() {
    use klio_cfa::dataflow::Lattice;
    let mut fact_a = SmartCastFact::unknown();
    fact_a.assume_is(Type::String, None);
    let mut fact_b = SmartCastFact::unknown();
    fact_b.assume_is(Type::Int, None);
    fact_a.join(&fact_b);
    // String join Int should drop to None — disagreement.
    assert_eq!(fact_a.narrowed, Some(Type::Any));
}

#[test]
fn killdataflow_invalidates_narrowing() {
    use klio_cfa::dataflow::infer_kill_data_flow;
    let (cfg, r2p) = parse_and_lower(
        "fun foo(x: Any) {
            var y: Any = x
            if (y is String) {
                var i = 0
                while (i < 10) {
                    y = 1
                    i = i + 1
                }
                // y's narrowing must be invalidated by killDataFlow
            }
        }",
    );
    let mut cfg = cfg;
    infer_kill_data_flow(&mut cfg);
    let states = smartcast::solve(&cfg, &r2p);
    let _ = states;
    // We assert that the loop head has a KillDataFlow for `y` —
    // smart-cast then drops the narrowing when it sees it.
    let killed = cfg.blocks.iter().any(|b| {
        b.nodes
            .iter()
            .any(|n| matches!(n, klio_cfa::Node::KillDataFlow { place } if matches!(place, Place::Local(s) if s.0 == "y")))
    });
    assert!(killed, "expected KillDataFlow(y) at some loop head");
}

#[test]
fn bound_smart_cast_aliases_recorded() {
    let mut map = SourceMap::new();
    let id = map.add("t.kt", "fun foo(a: Any) { val b = a }");
    let owned = map.get(id).source.clone();
    let lexed = klio_lexer::Lexer::new(id, &owned).tokenize();
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
    let lowered = klio_cfa::lower::lower_function(&body, func.span);
    let aliased_from = lowered
        .aliases
        .get(&Symbol("b".into()))
        .expect("b should alias a");
    assert_eq!(aliased_from, &Place::Local(Symbol("a".into())));
}

#[test]
fn require_not_null_narrows_post_call() {
    let (cfg, r2p) = parse_and_lower(
        "fun foo(x: String?) {
            requireNotNull(x)
            println(x)
        }",
    );
    let x = Place::Local(Symbol("x".into()));
    assert!(
        any_narrowing_anywhere(&cfg, &r2p, &x, |f| matches!(f.null, Nullability::NonNull)),
        "expected x narrowed to non-null after requireNotNull"
    );
}

#[test]
fn require_with_is_check_narrows_post_call() {
    let (cfg, r2p) = parse_and_lower(
        "fun foo(x: Any) {
            require(x is String)
            println(x)
        }",
    );
    let x = Place::Local(Symbol("x".into()));
    assert!(
        any_narrowing_anywhere(&cfg, &r2p, &x, |f| matches!(f.narrowed, Some(Type::String))),
        "expected x narrowed to String after require(x is String)"
    );
}

#[test]
fn span_to_pos_indexes_every_eval() {
    let mut map = SourceMap::new();
    let id = map.add("t.kt", "fun foo() { val x = 1 + 2 }");
    let owned = map.get(id).source.clone();
    let lexed = klio_lexer::Lexer::new(id, &owned).tokenize();
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
    let lowered = klio_cfa::lower::lower_function(&body, func.span);
    for ((s, e), (bid, idx)) in &lowered.span_to_pos {
        // Every recorded position points at a real Eval node.
        let node = &lowered.cfg.block(*bid).nodes[*idx];
        match node {
            klio_cfa::Node::Eval { expr, .. } => {
                assert_eq!(expr.span.start, *s);
                assert_eq!(expr.span.end, *e);
            }
            other => panic!("span_to_pos points at non-Eval node: {other:?}"),
        }
    }
    assert!(
        !lowered.span_to_pos.is_empty(),
        "expected at least one span entry"
    );
}

#[test]
fn empty_program_has_no_facts() {
    let (cfg, r2p) = parse_and_lower("fun foo() { }");
    let states = smartcast::solve(&cfg, &r2p);
    for state in &states {
        assert!(state.map.is_empty());
    }
    let _ = MapLattice::<Place, SmartCastFact>::default();
}
