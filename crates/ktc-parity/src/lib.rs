//! Parity harness: compile a `.kt` file with `kotlinc-native`, run the
//! resulting binary, run the same file under `ktc`, and diff stdout.

use std::collections::hash_map::DefaultHasher;
use std::env;
use std::fs;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::process::Command;

use ktc_interp::{CaptureOutput, Interpreter};
use ktc_lexer::Lexer;
use ktc_parser::Parser as KtParser;
use ktc_span::SourceMap;

#[derive(Debug)]
pub struct ParityReport {
    pub matched: bool,
    pub kotlinc_stdout: String,
    pub ktc_stdout: String,
    pub kotlinc_exit: Option<i32>,
    pub ktc_error: Option<String>,
}

#[derive(Debug)]
pub enum ParityError {
    NoKotlinc,
    Compile(String),
    Io(std::io::Error),
}

impl std::fmt::Display for ParityError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NoKotlinc => write!(
                f,
                "kotlinc-native not found. Set KTC_KOTLINC_NATIVE, install Kotlin Native under ~/.konan, or put kotlinc-native on PATH."
            ),
            Self::Compile(msg) => write!(f, "kotlinc compile failed:\n{msg}"),
            Self::Io(e) => write!(f, "io error: {e}"),
        }
    }
}

impl From<std::io::Error> for ParityError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}

/// Default kotlinc-native version we target. Mirrors the `kotlin/` checkout
/// pinned for stdlib mining.
pub const TARGET_VERSION: &str = "2.3.21";

/// Locate `kotlinc-native`. Search order:
/// 1. `KTC_KOTLINC_NATIVE` env var.
/// 2. `~/.konan/kotlin-native-prebuilt-*-{TARGET_VERSION}/bin/kotlinc-native`.
/// 3. `PATH`.
pub fn find_kotlinc() -> Result<PathBuf, ParityError> {
    if let Ok(v) = env::var("KTC_KOTLINC_NATIVE") {
        let p = PathBuf::from(v);
        if p.is_file() {
            return Ok(p);
        }
    }
    if let Some(home) = env::var_os("HOME") {
        let konan = PathBuf::from(home).join(".konan");
        if let Ok(entries) = fs::read_dir(&konan) {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let s = name.to_string_lossy();
                if s.starts_with("kotlin-native-prebuilt-") && s.contains(TARGET_VERSION)
                    && !s.contains("-RC")
                {
                    let p = entry.path().join("bin").join("kotlinc-native");
                    if p.is_file() {
                        return Ok(p);
                    }
                }
            }
        }
    }
    if let Ok(path) = env::var("PATH") {
        for dir in env::split_paths(&path) {
            let p = dir.join("kotlinc-native");
            if p.is_file() {
                return Ok(p);
            }
        }
    }
    Err(ParityError::NoKotlinc)
}

fn parity_cache_dir() -> PathBuf {
    // Live next to the workspace target/, which is where everything else
    // builds. CARGO_TARGET_DIR overrides honored automatically.
    let target = env::var_os("CARGO_TARGET_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| workspace_root().join("target"));
    target.join("parity-cache")
}

fn workspace_root() -> PathBuf {
    let m = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    m.parent()
        .and_then(|p| p.parent())
        .map(PathBuf::from)
        .unwrap_or(m)
}

fn cache_key(file: &Path) -> String {
    let bytes = fs::read(file).unwrap_or_default();
    let mut h = DefaultHasher::new();
    bytes.hash(&mut h);
    format!("{:016x}", h.finish())
}

/// Compile a `.kt` file with `kotlinc-native`, caching by content hash.
pub fn compile_with_kotlinc(file: &Path) -> Result<PathBuf, ParityError> {
    let kotlinc = find_kotlinc()?;
    let dir = parity_cache_dir();
    fs::create_dir_all(&dir)?;
    let key = cache_key(file);
    let out = dir.join(format!("{key}.kexe"));
    if out.is_file() {
        return Ok(out);
    }
    let result = Command::new(&kotlinc)
        .arg(file)
        .arg("-o")
        .arg(&out)
        .output()?;
    if !result.status.success() {
        return Err(ParityError::Compile(format!(
            "{}\n{}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        )));
    }
    Ok(out)
}

fn run_binary(path: &Path) -> Result<(String, Option<i32>), ParityError> {
    let result = Command::new(path).output()?;
    let stdout = String::from_utf8_lossy(&result.stdout).into_owned();
    Ok((stdout, result.status.code()))
}

/// Run a `.kt` file directly through the `ktc` interpreter library, returning
/// captured stdout. Diagnostic output is folded into the returned error.
pub fn run_with_ktc(file: &Path) -> Result<String, String> {
    let src = fs::read_to_string(file).map_err(|e| e.to_string())?;
    let mut map = SourceMap::new();
    let id = map.add(file, src.clone());
    let owned = map.get(id).source.clone();
    let lexed = Lexer::new(id, &owned).tokenize();
    if lexed.diagnostics.has_errors() {
        return Err(format!("lex diagnostics: {:?}", lexed.diagnostics.diagnostics()));
    }
    let (ast, diags) = KtParser::new(id, &owned, &lexed.tokens).parse_file();
    if diags.has_errors() {
        return Err(format!("parse diagnostics: {:?}", diags.diagnostics()));
    }
    let mut out = CaptureOutput::default();
    Interpreter::new()
        .run_with_output(&ast, &mut out)
        .map_err(|e| format!("runtime error: {e}"))?;
    // CaptureOutput stores one entry per writeln. Kotlin's process stdout
    // ends each println with a newline, including a trailing newline after
    // the last print. Match that by appending a newline.
    let mut joined = out.lines.join("\n");
    if !joined.is_empty() {
        joined.push('\n');
    }
    Ok(joined)
}

/// Full parity check: compile + run both compilers, return a report.
pub fn check(file: &Path) -> Result<ParityReport, ParityError> {
    let kexe = compile_with_kotlinc(file)?;
    let (kotlinc_stdout, kotlinc_exit) = run_binary(&kexe)?;
    match run_with_ktc(file) {
        Ok(ktc_stdout) => Ok(ParityReport {
            matched: kotlinc_stdout == ktc_stdout,
            kotlinc_stdout,
            ktc_stdout,
            kotlinc_exit,
            ktc_error: None,
        }),
        Err(e) => Ok(ParityReport {
            matched: false,
            kotlinc_stdout,
            ktc_stdout: String::new(),
            kotlinc_exit,
            ktc_error: Some(e),
        }),
    }
}

/// Render a unified-style diff between the two outputs. Empty string when
/// they match.
#[must_use]
pub fn render_diff(report: &ParityReport) -> String {
    if report.matched {
        return String::new();
    }
    let mut out = String::new();
    out.push_str("--- kotlinc-native\n");
    out.push_str("+++ ktc\n");
    let a: Vec<&str> = report.kotlinc_stdout.lines().collect();
    let b: Vec<&str> = report.ktc_stdout.lines().collect();
    let max = a.len().max(b.len());
    for i in 0..max {
        match (a.get(i), b.get(i)) {
            (Some(x), Some(y)) if x == y => {
                out.push(' ');
                out.push_str(x);
                out.push('\n');
            }
            (Some(x), Some(y)) => {
                out.push('-');
                out.push_str(x);
                out.push('\n');
                out.push('+');
                out.push_str(y);
                out.push('\n');
            }
            (Some(x), None) => {
                out.push('-');
                out.push_str(x);
                out.push('\n');
            }
            (None, Some(y)) => {
                out.push('+');
                out.push_str(y);
                out.push('\n');
            }
            (None, None) => break,
        }
    }
    if let Some(e) = &report.ktc_error {
        out.push_str("ktc error: ");
        out.push_str(e);
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cache_key_is_stable_for_same_contents() {
        let tmp = std::env::temp_dir().join("ktc-parity-cache-key.kt");
        fs::write(&tmp, b"fun main() { println(1) }").unwrap();
        let a = cache_key(&tmp);
        let b = cache_key(&tmp);
        assert_eq!(a, b);
    }
}
