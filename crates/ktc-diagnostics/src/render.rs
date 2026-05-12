//! Diagnostic renderers. Each format consumes the same `[Diagnostic]` slice
//! against a `SourceMap`; choose the renderer that matches your downstream
//! consumer (terminal, JSON-consuming tooling, SARIF aggregator).

pub mod plain;
pub mod json;
pub mod sarif;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Plain,
    Json,
    Sarif,
}

impl Format {
    pub fn from_str(s: &str) -> Option<Self> {
        Some(match s {
            "plain" => Self::Plain,
            "json" => Self::Json,
            "sarif" => Self::Sarif,
            _ => return None,
        })
    }
}
