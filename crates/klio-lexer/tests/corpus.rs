//! Lexer corpus tests. Each `.kt` snippet is tokenized end-to-end and the
//! token stream + any diagnostics are snapshot-compared with `insta`.
//!
//! Add new programs to `tests/corpus/` and a new test below. Snapshots live in
//! `tests/snapshots/` and are reviewed via `cargo insta review`.

use klio_lexer::{Lexer, Token, TokenKind};
use klio_span::SourceMap;

fn render(src: &str) -> String {
    let mut map = SourceMap::new();
    let id = map.add("corpus.kt", src);
    let owned = map.get(id).source.clone();
    let result = Lexer::new(id, &owned).tokenize();
    let mut out = String::new();
    out.push_str("# tokens\n");
    for t in &result.tokens {
        out.push_str(&render_token(t, src));
        out.push('\n');
    }
    if !result.diagnostics.diagnostics().is_empty() {
        out.push_str("\n# diagnostics\n");
        for d in result.diagnostics.diagnostics() {
            let code = d.code().unwrap_or("");
            out.push_str(&format!("[{code}] {sev:?} {msg} @{start}..{end}\n",
                sev = d.severity,
                msg = d.message,
                start = d.primary.span.start,
                end = d.primary.span.end,
            ));
        }
    }
    out
}

fn render_token(t: &Token, src: &str) -> String {
    let text = if matches!(t.kind, TokenKind::Eof) {
        String::new()
    } else {
        src[t.span.range()].escape_debug().collect::<String>()
    };
    let label = match &t.kind {
        TokenKind::Whitespace => "WS".to_string(),
        TokenKind::Newline => "NL".to_string(),
        TokenKind::LineComment => "LCOMMENT".to_string(),
        TokenKind::BlockComment => "BCOMMENT".to_string(),
        TokenKind::IntLiteral { base, suffix } => format!("INT[{base:?},{suffix:?}]"),
        TokenKind::FloatLiteral { suffix } => format!("FLOAT[{suffix:?}]"),
        TokenKind::BoolLiteral(v) => format!("BOOL[{v}]"),
        TokenKind::NullLiteral => "NULL".to_string(),
        TokenKind::CharLiteral(c) => char::from_u32(u32::from(*c))
            .map_or_else(|| format!("CHAR[{c}]"), |ch| format!("CHAR[{ch:?}]")),
        TokenKind::StringQuote { triple } => format!("QUOTE[{}]", if *triple { "\"\"\"" } else { "\"" }),
        TokenKind::StringText(s) => format!("STR_TEXT[{s:?}]"),
        TokenKind::InterpStart => "INTERP_START".to_string(),
        TokenKind::InterpEnd => "INTERP_END".to_string(),
        TokenKind::ShortInterp(s) => format!("SHORT_INTERP[{s}]"),
        TokenKind::Ident => "IDENT".to_string(),
        TokenKind::Keyword(k) => format!("KW[{k:?}]"),
        TokenKind::Unknown => "UNKNOWN".to_string(),
        TokenKind::Eof => "EOF".to_string(),
        other => format!("{other:?}"),
    };
    format!("{label:<20} {start:>4}..{end:<4} {text}",
        start = t.span.start,
        end = t.span.end,
    )
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

corpus_test!(hello_world, "hello.kt");
corpus_test!(arithmetic, "arithmetic.kt");
corpus_test!(strings_templates, "strings.kt");
corpus_test!(comments_nested, "comments.kt");
corpus_test!(declarations, "declarations.kt");
corpus_test!(operators_zoo, "operators.kt");
corpus_test!(unicode_idents, "unicode.kt");
corpus_test!(numbers_zoo, "numbers.kt");
corpus_test!(diag_unterminated_string, "diag_unterminated_string.kt");
corpus_test!(diag_invalid_escape, "diag_invalid_escape.kt");
