//! Minimal SARIF 2.1.0 renderer. Produces a single SARIF run with one
//! result per diagnostic, suitable for GitHub Code Scanning and CodeQL-
//! style aggregators. Schema reference:
//! <https://docs.oasis-open.org/sarif/sarif/v2.1.0/sarif-v2.1.0.html>.

use crate::{Diagnostic, Severity};
use klio_span::SourceMap;

pub fn render(
    diagnostics: &[Diagnostic],
    sources: &SourceMap,
    mut out: impl std::io::Write,
) -> std::io::Result<()> {
    let mut s = String::new();
    s.push_str("{\"version\":\"2.1.0\",\"$schema\":\"https://json.schemastore.org/sarif-2.1.0.json\",\"runs\":[{\"tool\":{\"driver\":{");
    push(&mut s, "name", json_string("klio"));
    push(&mut s, "informationUri", json_string("https://github.com/DrewCarlson/kt-exp"));
    push(&mut s, "rules", rules_array(diagnostics));
    s.push_str("}},\"results\":[");
    for (i, d) in diagnostics.iter().enumerate() {
        if i > 0 { s.push(','); }
        s.push_str(&result_object(d, sources));
    }
    s.push_str("]}]}");
    out.write_all(s.as_bytes())?;
    out.write_all(b"\n")?;
    Ok(())
}

#[must_use]
pub fn to_string(diagnostics: &[Diagnostic], sources: &SourceMap) -> String {
    let mut buf = Vec::new();
    let _ = render(diagnostics, sources, &mut buf);
    String::from_utf8(buf).unwrap_or_default()
}

fn rules_array(diagnostics: &[Diagnostic]) -> String {
    let mut seen: Vec<&'static str> = Vec::new();
    for d in diagnostics {
        if let Some(code) = d.code() {
            if !seen.contains(&code) {
                seen.push(code);
            }
        }
    }
    let mut s = String::new();
    s.push('[');
    for (i, code) in seen.iter().enumerate() {
        if i > 0 { s.push(','); }
        s.push_str(&format!(
            "{{\"id\":{},\"name\":{}}}",
            json_string(code),
            json_string(code),
        ));
    }
    s.push(']');
    s
}

fn result_object(d: &Diagnostic, sources: &SourceMap) -> String {
    let file = sources.get(d.primary.span.file);
    let (sl, sc) = file.line_col(d.primary.span.start);
    let (el, ec) = file.line_col(d.primary.span.end);
    let level = match d.severity {
        Severity::Error => "error",
        Severity::StrongWarning | Severity::Warning => "warning",
        Severity::Info | Severity::Hint => "note",
    };
    let rule_id = d.code().unwrap_or("klio.diagnostic");
    let mut s = String::new();
    s.push('{');
    push(&mut s, "ruleId", json_string(rule_id));
    push(&mut s, "level", json_string(level));
    push(&mut s, "message", format!("{{\"text\":{}}}", json_string(&d.message)));
    let loc = format!(
        "[{{\"physicalLocation\":{{\"artifactLocation\":{{\"uri\":{uri}}},\"region\":{{\"startLine\":{sl},\"startColumn\":{sc},\"endLine\":{el},\"endColumn\":{ec}}}}}}}]",
        uri = json_string(&file.path.to_string_lossy()),
    );
    push(&mut s, "locations", loc);
    s.push('}');
    s
}

fn push(buf: &mut String, key: &str, value: String) {
    if !buf.ends_with('{') {
        buf.push(',');
    }
    buf.push_str(&format!("\"{key}\":{value}"));
}

fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
