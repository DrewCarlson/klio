//! Plain-text renderer matching `kotlinc`'s `MessageRenderer.PLAIN`:
//!
//! ```text
//! file.kt:10:5: error: Unresolved reference: foo
//!         foo()
//!         ^^^
//! ```
//!
//! Includes the source line and an underline-caret if the span fits on a
//! single line. Multi-line spans only mark the start.

use crate::{Diagnostic, Severity};
use klio_span::{SourceFile, SourceMap, Span};

pub fn render(
    diagnostics: &[Diagnostic],
    sources: &SourceMap,
    mut out: impl std::io::Write,
) -> std::io::Result<()> {
    for d in diagnostics {
        render_one(d, sources, &mut out)?;
    }
    Ok(())
}

#[must_use]
pub fn to_string(diagnostics: &[Diagnostic], sources: &SourceMap) -> String {
    let mut buf = Vec::new();
    let _ = render(diagnostics, sources, &mut buf);
    String::from_utf8(buf).unwrap_or_default()
}

fn render_one<W: std::io::Write>(
    d: &Diagnostic,
    sources: &SourceMap,
    out: &mut W,
) -> std::io::Result<()> {
    let file = sources.get(d.primary.span.file);
    let (line, col) = file.line_col(d.primary.span.start);
    let sev_label = severity_word(d.severity);
    let code_suffix = d.code().map(|c| format!(" [{c}]")).unwrap_or_default();
    writeln!(
        out,
        "{path}:{line}:{col}: {sev}: {msg}{code}",
        path = file.path.display(),
        sev = sev_label,
        msg = d.message,
        code = code_suffix,
    )?;
    if let Some(snippet) = source_line(file, d.primary.span) {
        writeln!(out, "{snippet}")?;
        writeln!(out, "{}", caret_underline(file, d.primary.span))?;
    }
    for sec in &d.secondary {
        let (l, c) = file.line_col(sec.span.start);
        writeln!(
            out,
            "    {path}:{l}:{c}: {msg}",
            path = file.path.display(),
            msg = sec.message,
        )?;
    }
    for note in &d.notes {
        writeln!(out, "    note: {note}")?;
    }
    for fixit in &d.fixits {
        writeln!(out, "    help: {}", fixit.title)?;
    }
    Ok(())
}

fn severity_word(sev: Severity) -> &'static str {
    sev.as_kotlinc_label()
}

fn source_line(file: &SourceFile, span: Span) -> Option<String> {
    let (line, _) = file.line_col(span.start);
    let mut iter = file.source.split('\n');
    iter.nth((line - 1) as usize)
        .map(std::string::ToString::to_string)
}

fn caret_underline(file: &SourceFile, span: Span) -> String {
    let (start_line, start_col) = file.line_col(span.start);
    let (end_line, end_col) = file.line_col(span.end);
    let width = if start_line == end_line {
        (end_col.saturating_sub(start_col)).max(1)
    } else {
        1
    };
    let mut s = String::new();
    for _ in 1..start_col {
        s.push(' ');
    }
    for _ in 0..width {
        s.push('^');
    }
    s
}
