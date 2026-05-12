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
    Install(String),
    UnsupportedPlatform(String),
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
            Self::Install(msg) => write!(f, "kotlin-native install failed: {msg}"),
            Self::UnsupportedPlatform(s) => {
                write!(f, "no kotlin-native prebuilt for platform: {s}")
            }
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
///
/// When not found, attempts to install `TARGET_VERSION` into `~/.konan`
/// (matching the gradle/konan layout) unless `KTC_NO_AUTO_INSTALL_KOTLINC=1`.
pub fn find_kotlinc() -> Result<PathBuf, ParityError> {
    if let Some(p) = locate_kotlinc() {
        return Ok(p);
    }
    if env::var("KTC_NO_AUTO_INSTALL_KOTLINC").is_ok_and(|v| !v.is_empty() && v != "0") {
        return Err(ParityError::NoKotlinc);
    }
    install_kotlinc(TARGET_VERSION)?;
    locate_kotlinc().ok_or(ParityError::NoKotlinc)
}

fn locate_kotlinc() -> Option<PathBuf> {
    if let Ok(v) = env::var("KTC_KOTLINC_NATIVE") {
        let p = PathBuf::from(v);
        if p.is_file() {
            return Some(p);
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
                        return Some(p);
                    }
                }
            }
        }
    }
    if let Ok(path) = env::var("PATH") {
        for dir in env::split_paths(&path) {
            let p = dir.join("kotlinc-native");
            if p.is_file() {
                return Some(p);
            }
        }
    }
    None
}

fn konan_root() -> Result<PathBuf, ParityError> {
    if let Ok(v) = env::var("KONAN_DATA_DIR") {
        return Ok(PathBuf::from(v));
    }
    let home = env::var_os("HOME").ok_or_else(|| {
        ParityError::Install("HOME not set; cannot resolve ~/.konan".into())
    })?;
    Ok(PathBuf::from(home).join(".konan"))
}

/// Kotlin/Native distribution descriptor: the os/arch slug embedded in the
/// archive name and the CDN subdirectory.
fn platform_slug() -> Result<(&'static str, &'static str, &'static str), ParityError> {
    let os = env::consts::OS;
    let arch = env::consts::ARCH;
    let (slug, subdir, ext) = match (os, arch) {
        ("macos", "aarch64") => ("macos-aarch64", "macos", "tar.gz"),
        ("macos", "x86_64") => ("macos-x86_64", "macos", "tar.gz"),
        ("linux", "x86_64") => ("linux-x86_64", "linux", "tar.gz"),
        ("windows", "x86_64") => ("windows-x86_64", "windows", "zip"),
        _ => return Err(ParityError::UnsupportedPlatform(format!("{os}-{arch}"))),
    };
    Ok((slug, subdir, ext))
}

/// Download + extract `kotlin-native-prebuilt-{platform}-{version}` into
/// `~/.konan/` (or `$KONAN_DATA_DIR`). Idempotent: if the destination already
/// exists with a working `bin/kotlinc-native`, this is a no-op.
pub fn install_kotlinc(version: &str) -> Result<PathBuf, ParityError> {
    let (slug, subdir, ext) = platform_slug()?;
    let root = konan_root()?;
    fs::create_dir_all(&root)?;
    let dir_name = format!("kotlin-native-prebuilt-{slug}-{version}");
    let dest = root.join(&dir_name);
    let kotlinc = dest.join("bin").join(kotlinc_native_filename());
    if kotlinc.is_file() {
        return Ok(dest);
    }

    // Cross-process lock so concurrent cargo test invocations don't race.
    let lock_path = root.join(format!(".{dir_name}.installing"));
    let _lock = InstallLock::acquire(&lock_path)?;
    if kotlinc.is_file() {
        return Ok(dest);
    }

    let archive_name = format!("{dir_name}.{ext}");
    let url = format!(
        "https://download.jetbrains.com/kotlin/native/builds/releases/{version}/{subdir}/{archive_name}"
    );
    let archive_path = root.join(&archive_name);
    eprintln!("[parity] installing kotlin-native {version} ({slug}) into {}", root.display());
    eprintln!("[parity] downloading {url}");
    download(&url, &archive_path)?;

    // Extract into root; the archive's top-level dir matches `dir_name`.
    let staging = root.join(format!(".{dir_name}.partial"));
    let _ = fs::remove_dir_all(&staging);
    fs::create_dir_all(&staging)?;
    extract(&archive_path, &staging, ext)?;

    // The archive contains `dir_name/...`. Move that out to the final spot.
    let extracted = staging.join(&dir_name);
    let extracted = if extracted.is_dir() {
        extracted
    } else {
        // Fallback: some archives may extract a slightly different top-level
        // dir. Pick the single child directory.
        let mut children = fs::read_dir(&staging)?
            .filter_map(Result::ok)
            .map(|e| e.path())
            .filter(|p| p.is_dir())
            .collect::<Vec<_>>();
        if children.len() != 1 {
            return Err(ParityError::Install(format!(
                "unexpected archive layout under {}",
                staging.display()
            )));
        }
        children.remove(0)
    };
    if dest.exists() {
        let _ = fs::remove_dir_all(&dest);
    }
    fs::rename(&extracted, &dest).map_err(|e| {
        ParityError::Install(format!(
            "rename {} -> {}: {e}",
            extracted.display(),
            dest.display()
        ))
    })?;
    let _ = fs::remove_dir_all(&staging);
    let _ = fs::remove_file(&archive_path);

    if !kotlinc.is_file() {
        return Err(ParityError::Install(format!(
            "{} missing after extract",
            kotlinc.display()
        )));
    }
    eprintln!("[parity] kotlin-native {version} ready at {}", dest.display());
    Ok(dest)
}

fn kotlinc_native_filename() -> &'static str {
    if cfg!(windows) { "kotlinc-native.bat" } else { "kotlinc-native" }
}

fn download(url: &str, dest: &Path) -> Result<(), ParityError> {
    // Prefer curl, fall back to wget. Both are present on macOS/Linux CI.
    let tmp = dest.with_extension("part");
    let _ = fs::remove_file(&tmp);
    let status = Command::new("curl")
        .args(["-fL", "--retry", "3", "--retry-delay", "2", "-o"])
        .arg(&tmp)
        .arg(url)
        .status();
    let ok = match status {
        Ok(s) if s.success() => true,
        _ => {
            let _ = fs::remove_file(&tmp);
            Command::new("wget")
                .args(["-O"])
                .arg(&tmp)
                .arg(url)
                .status()
                .map(|s| s.success())
                .unwrap_or(false)
        }
    };
    if !ok {
        let _ = fs::remove_file(&tmp);
        return Err(ParityError::Install(format!("download failed: {url}")));
    }
    fs::rename(&tmp, dest)?;
    Ok(())
}

fn extract(archive: &Path, into: &Path, ext: &str) -> Result<(), ParityError> {
    let status = if ext == "zip" {
        Command::new("unzip")
            .arg("-q")
            .arg(archive)
            .arg("-d")
            .arg(into)
            .status()
    } else {
        Command::new("tar")
            .arg("-xf")
            .arg(archive)
            .arg("-C")
            .arg(into)
            .status()
    }
    .map_err(|e| ParityError::Install(format!("extract spawn: {e}")))?;
    if !status.success() {
        return Err(ParityError::Install(format!(
            "extract {} failed (exit {:?})",
            archive.display(),
            status.code()
        )));
    }
    Ok(())
}

/// Best-effort cross-process advisory lock implemented via O_CREAT|O_EXCL on a
/// sentinel file. Stale locks older than 1h are reclaimed.
struct InstallLock {
    path: PathBuf,
}

impl InstallLock {
    fn acquire(path: &Path) -> Result<Self, ParityError> {
        use std::time::{Duration, SystemTime};
        loop {
            match fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(path)
            {
                Ok(_) => return Ok(Self { path: path.to_path_buf() }),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                    if let Ok(meta) = fs::metadata(path)
                        && let Ok(modified) = meta.modified()
                        && SystemTime::now()
                            .duration_since(modified)
                            .unwrap_or_default()
                            > Duration::from_secs(60 * 60)
                    {
                        let _ = fs::remove_file(path);
                        continue;
                    }
                    std::thread::sleep(Duration::from_secs(2));
                }
                Err(e) => return Err(ParityError::Io(e)),
            }
        }
    }
}

impl Drop for InstallLock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
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
