//! Snapshot corpus for the resolver. Each `.kt` program is parsed and
//! resolved end-to-end; the resulting symbol table, name-use map, and
//! diagnostics are rendered to a stable text form and compared via `insta`.

use klio_lexer::Lexer;
use klio_parser::Parser;
use klio_resolver::resolve;
use klio_span::SourceMap;

fn render(src: &str) -> String {
    let mut map = SourceMap::new();
    let id = map.add("corpus.kt", src);
    let owned = map.get(id).source.clone();
    let lexed = Lexer::new(id, &owned).tokenize();
    let (ast, parse_diags) = Parser::new(id, &owned, &lexed.tokens).parse_file();
    let r = resolve(&ast);

    let mut out = String::new();
    out.push_str("# symbols\n");
    for s in &r.symbols {
        let span = s
            .decl_span
            .map(|sp| format!("@{}..{}", sp.start, sp.end))
            .unwrap_or_else(|| "@builtin".into());
        out.push_str(&format!(
            "  [{idx}] {kind:?} {name} {span}\n",
            idx = s.id.0,
            kind = s.kind,
            name = s.name,
        ));
    }

    out.push_str("\n# uses\n");
    let mut uses: Vec<_> = r.uses.iter().collect();
    uses.sort_by_key(|(span, _)| (span.start, span.end));
    for (span, sym_id) in uses {
        let sym = r.symbol(*sym_id);
        out.push_str(&format!(
            "  @{}..{} -> [{}] {} ({:?})\n",
            span.start, span.end, sym.id.0, sym.name, sym.kind,
        ));
    }

    let mut all_diags = parse_diags.diagnostics().to_vec();
    all_diags.extend(r.diagnostics.diagnostics().iter().cloned());
    if !all_diags.is_empty() {
        out.push_str("\n# diagnostics\n");
        for d in &all_diags {
            let code = d.code().unwrap_or("");
            out.push_str(&format!(
                "  [{code}] {sev:?} {msg} @{start}..{end}\n",
                sev = d.severity,
                msg = d.message,
                start = d.primary.span.start,
                end = d.primary.span.end,
            ));
        }
    }

    out
}

macro_rules! corpus_test {
    ($name:ident, $file:expr) => {
        #[test]
        fn $name() {
            let src = include_str!(concat!("corpus/", $file));
            insta::assert_snapshot!(stringify!($name), render(src), src);
        }
    };
}

corpus_test!(forward_refs, "forward_refs.kt");
corpus_test!(mutual_recursion, "mutual_recursion.kt");
corpus_test!(shadowing, "shadowing.kt");
corpus_test!(diag_unresolved, "diag_unresolved.kt");
corpus_test!(diag_non_kotlin_import, "diag_non_kotlin_import.kt");
