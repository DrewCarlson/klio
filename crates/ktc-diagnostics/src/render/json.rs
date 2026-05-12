//! NDJSON renderer — one diagnostic per line, suitable for streaming into
//! external tooling that wants to consume our diagnostics directly.

use crate::{Diagnostic, Severity};
use ktc_span::SourceMap;

pub fn render(
    diagnostics: &[Diagnostic],
    sources: &SourceMap,
    mut out: impl std::io::Write,
) -> std::io::Result<()> {
    for d in diagnostics {
        let file = sources.get(d.primary.span.file);
        let (sl, sc) = file.line_col(d.primary.span.start);
        let (el, ec) = file.line_col(d.primary.span.end);
        let mut s = String::new();
        s.push('{');
        push_field(&mut s, "factory", json_string(d.factory.map(|f| f.name).unwrap_or("")));
        push_field(&mut s, "legacy_code", json_string(d.legacy_code.unwrap_or("")));
        push_field(&mut s, "severity", json_string(severity_str(d.severity)));
        push_field(&mut s, "file", json_string(&file.path.to_string_lossy()));
        push_field(&mut s, "message", json_string(&d.message));
        s.push_str(",\"range\":{\"start\":{");
        s.push_str(&format!("\"line\":{sl},\"col\":{sc}"));
        s.push_str("},\"end\":{");
        s.push_str(&format!("\"line\":{el},\"col\":{ec}"));
        s.push_str("}}");
        if !d.notes.is_empty() {
            s.push_str(",\"notes\":[");
            for (i, n) in d.notes.iter().enumerate() {
                if i > 0 { s.push(','); }
                s.push_str(&json_string(n));
            }
            s.push(']');
        }
        if !d.fixits.is_empty() {
            s.push_str(",\"fixits\":[");
            for (i, fx) in d.fixits.iter().enumerate() {
                if i > 0 { s.push(','); }
                s.push_str(&format!("{{\"title\":{}}}", json_string(&fx.title)));
            }
            s.push(']');
        }
        s.push('}');
        out.write_all(s.as_bytes())?;
        out.write_all(b"\n")?;
    }
    Ok(())
}

#[must_use]
pub fn to_string(diagnostics: &[Diagnostic], sources: &SourceMap) -> String {
    let mut buf = Vec::new();
    let _ = render(diagnostics, sources, &mut buf);
    String::from_utf8(buf).unwrap_or_default()
}

fn push_field(buf: &mut String, key: &str, value: String) {
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

fn severity_str(sev: Severity) -> &'static str {
    match sev {
        Severity::Error => "error",
        Severity::StrongWarning => "strong_warning",
        Severity::Warning => "warning",
        Severity::Info => "info",
        Severity::Hint => "hint",
    }
}
