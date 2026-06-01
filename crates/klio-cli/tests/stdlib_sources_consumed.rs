//! Enforces that every curated stdlib source embedded in the pack's
//! `SOURCES` section lexes and parses without errors — i.e. the
//! interpreter actually *consumes* its standard-library sources rather
//! than silently dropping a file that fails to parse (which
//! `load_embedded_stdlib_sources` does at runtime, gated on
//! `KLIO_PACK_DIAG`).
//!
//! A file that newly fails to parse becomes a loud, named test failure
//! here instead of a silent behavioural gap. The only permitted
//! failures are listed in `ALLOWED_UNPARSEABLE` with a documented
//! reason; that list must shrink, never grow silently.

use klio_pack::schema::{decode, SourceBundle};
use klio_pack::{section_names, PackReader};
use klio_span::FileId;

/// Curated sources klio cannot yet parse, each with the language
/// feature that blocks it. These are deliberately excluded from the
/// "consumed without errors" guarantee until the feature lands; the
/// list is an explicit ledger of remaining work, not a silent skip.
const ALLOWED_UNPARSEABLE: &[(&str, &str)] = &[
    // Kotlin 2.2 context parameters — `context(T) () -> R` receiver
    // function types and `context(ctx: A)` parameter clauses. Brand-new
    // experimental syntax, not part of the consumed stdlib API surface.
    ("contextParameters/Context.kt", "Kotlin 2.2 context-receiver function types"),
    ("contextParameters/ContextOf.kt", "Kotlin 2.2 context parameters"),
];

fn allowed(rel_path: &str) -> Option<&'static str> {
    ALLOWED_UNPARSEABLE
        .iter()
        .find(|(suffix, _)| rel_path.ends_with(suffix))
        .map(|(_, reason)| *reason)
}

#[test]
fn embedded_stdlib_sources_parse() {
    let bytes = klio_stdlib_pack::stdlib_pack_bytes().into_owned();
    let pack = PackReader::from_bytes(bytes).expect("read embedded stdlib pack");
    let payload = pack
        .read_section(section_names::SOURCES)
        .expect("read SOURCES section")
        .expect("pack has a SOURCES section");
    let bundle: SourceBundle = decode(&payload).expect("decode SourceBundle");
    assert!(!bundle.files.is_empty(), "pack SOURCES section is empty");

    let mut unexpected_failures: Vec<String> = Vec::new();
    let mut stale_allows: Vec<String> = Vec::new();

    for sf in &bundle.files {
        let src = String::from_utf8_lossy(&sf.bytes);
        let lexed = klio_lexer::Lexer::new(FileId(0), &src).tokenize();
        let parse_ok = if lexed.diagnostics.has_errors() {
            false
        } else {
            let (_ast, diags) =
                klio_parser::Parser::new(FileId(0), &src, &lexed.tokens).parse_file();
            !diags.has_errors()
        };

        match (parse_ok, allowed(&sf.rel_path)) {
            (true, Some(_)) => stale_allows.push(sf.rel_path.clone()),
            (false, None) => unexpected_failures.push(sf.rel_path.clone()),
            _ => {}
        }
    }

    assert!(
        unexpected_failures.is_empty(),
        "curated stdlib sources failed to parse (not in the allow-list): {unexpected_failures:#?}\n\
         A consumed stdlib source must lex+parse without errors. Fix the parser/lexer, \
         or — only if the feature is genuinely out of scope — add it to \
         ALLOWED_UNPARSEABLE with a reason."
    );
    assert!(
        stale_allows.is_empty(),
        "these files now parse and should be removed from ALLOWED_UNPARSEABLE: {stale_allows:#?}"
    );
}
