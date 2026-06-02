//! Diagnostic renderers. Each format consumes the same `[Diagnostic]` slice
//! against a `SourceMap`; choose the renderer that matches your downstream
//! consumer (terminal, JSON-consuming tooling, SARIF aggregator).

pub mod json;
pub mod plain;
pub mod sarif;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Plain,
    Json,
    Sarif,
}

impl std::str::FromStr for Format {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(match s {
            "plain" => Self::Plain,
            "json" => Self::Json,
            "sarif" => Self::Sarif,
            _ => return Err(()),
        })
    }
}
