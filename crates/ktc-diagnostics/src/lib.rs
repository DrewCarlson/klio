//! Compiler diagnostics.
//!
//! Models a Kotlin-compatible diagnostic: each emission can carry a
//! [`DiagnosticFactory`] (a stable ID + default severity + message
//! template mined from kotlinc's `FirErrors.kt`), zero or more secondary
//! labels, notes, and zero or more [`FixIt`]s. Severities align with
//! kotlinc's `CompilerMessageSeverity`.
//!
//! Diagnostics render via the [`render`] module — plain text matching
//! `kotlinc`'s `MessageRenderer.PLAIN`, NDJSON for tooling, and SARIF
//! 2.1.0 for static-analysis aggregators.

pub mod generated;
pub mod render;

use ktc_span::Span;

/// Mirrors `org.jetbrains.kotlin.cli.common.messages.CompilerMessageSeverity`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Severity {
    Error,
    StrongWarning,
    Warning,
    Info,
    Hint,
}

impl Severity {
    #[must_use]
    pub fn as_kotlinc_label(self) -> &'static str {
        match self {
            Self::Error => "error",
            Self::StrongWarning => "warning",
            Self::Warning => "warning",
            Self::Info => "info",
            Self::Hint => "info",
        }
    }
}

/// A stable diagnostic identifier paired with its default severity and
/// message template. Names mirror the upstream Kotlin compiler so existing
/// IDE infrastructure (IntelliJ inspections, quick-fix dispatchers, etc.)
/// recognizes them without translation.
#[derive(Debug, Clone, Copy)]
pub struct DiagnosticFactory {
    pub name: &'static str,
    pub default_severity: Severity,
    pub message_template: &'static str,
}

#[derive(Debug, Clone)]
pub struct Label {
    pub span: Span,
    pub message: String,
}

/// A suggested code change. `kind` lets IDEs filter quick-fixes from
/// refactors. `edits` are applied atomically.
#[derive(Debug, Clone)]
pub struct FixIt {
    pub title: String,
    pub kind: FixItKind,
    pub edits: Vec<TextEdit>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FixItKind {
    QuickFix,
    Refactor,
    Suggestion,
}

#[derive(Debug, Clone)]
pub struct TextEdit {
    pub span: Span,
    pub replacement: String,
}

#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub severity: Severity,
    /// Factory (canonical Kotlin-style ID) when one applies. Falls back to
    /// [`legacy_code`](Self::legacy_code) for diagnostics we haven't mapped
    /// to a kotlinc factory yet.
    pub factory: Option<&'static DiagnosticFactory>,
    /// Older, kt-exp-internal code (e.g. `E0001`, `R0005`). Kept so the
    /// renderer can emit *something* even before every emit site is
    /// migrated to factories.
    pub legacy_code: Option<&'static str>,
    pub message: String,
    pub primary: Label,
    pub secondary: Vec<Label>,
    pub notes: Vec<String>,
    pub fixits: Vec<FixIt>,
}

impl Diagnostic {
    #[must_use]
    pub fn error(message: impl Into<String>, span: Span) -> Self {
        Self {
            severity: Severity::Error,
            factory: None,
            legacy_code: None,
            message: message.into(),
            primary: Label { span, message: String::new() },
            secondary: Vec::new(),
            notes: Vec::new(),
            fixits: Vec::new(),
        }
    }

    #[must_use]
    pub fn warning(message: impl Into<String>, span: Span) -> Self {
        Self {
            severity: Severity::Warning,
            ..Self::error(message, span)
        }
    }

    /// Build a diagnostic from a factory. Severity defaults to the factory's
    /// declared default; the message is the factory's template, which call
    /// sites may override with [`with_message`](Self::with_message).
    #[must_use]
    pub fn from_factory(factory: &'static DiagnosticFactory, span: Span) -> Self {
        Self {
            severity: factory.default_severity,
            factory: Some(factory),
            legacy_code: None,
            message: factory.message_template.to_string(),
            primary: Label { span, message: String::new() },
            secondary: Vec::new(),
            notes: Vec::new(),
            fixits: Vec::new(),
        }
    }

    #[must_use]
    pub fn with_factory(mut self, factory: &'static DiagnosticFactory) -> Self {
        self.factory = Some(factory);
        self
    }

    #[must_use]
    pub fn with_code(mut self, code: &'static str) -> Self {
        self.legacy_code = Some(code);
        self
    }

    #[must_use]
    pub fn with_severity(mut self, severity: Severity) -> Self {
        self.severity = severity;
        self
    }

    #[must_use]
    pub fn with_message(mut self, message: impl Into<String>) -> Self {
        self.message = message.into();
        self
    }

    #[must_use]
    pub fn with_label(mut self, span: Span, message: impl Into<String>) -> Self {
        self.secondary.push(Label { span, message: message.into() });
        self
    }

    #[must_use]
    pub fn with_note(mut self, note: impl Into<String>) -> Self {
        self.notes.push(note.into());
        self
    }

    #[must_use]
    pub fn with_fixit(mut self, fixit: FixIt) -> Self {
        self.fixits.push(fixit);
        self
    }

    /// The identifier we render in tool output. Factory name takes priority;
    /// falls back to the legacy code.
    #[must_use]
    pub fn code(&self) -> Option<&'static str> {
        self.factory.map(|f| f.name).or(self.legacy_code)
    }
}

#[derive(Debug, Default)]
pub struct DiagnosticSink {
    diagnostics: Vec<Diagnostic>,
}

impl DiagnosticSink {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn emit(&mut self, d: Diagnostic) {
        self.diagnostics.push(d);
    }

    #[must_use]
    pub fn has_errors(&self) -> bool {
        self.diagnostics
            .iter()
            .any(|d| d.severity == Severity::Error)
    }

    #[must_use]
    pub fn diagnostics(&self) -> &[Diagnostic] {
        &self.diagnostics
    }

    /// Convenience: render with the default plain-text renderer.
    pub fn render(
        &self,
        sources: &ktc_span::SourceMap,
        out: impl std::io::Write,
    ) -> std::io::Result<()> {
        render::plain::render(&self.diagnostics, sources, out)
    }
}
