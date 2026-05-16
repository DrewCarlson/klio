//! Parity harness: compile a `.kt` file with `kotlinc` (JVM by default; native
//! is also supported), run it, run the same file under `klio`, and diff stdout.
//!
//! We default to the JVM compiler because native compilation per-file is
//! dominated by LLVM codegen and linking, which makes a corpus sweep take
//! hours. JVM `kotlinc` compiles each file in ~1s and the produced jar runs
//! under `java` in ~200ms, keeping the full sweep tractable. The native path
//! is kept for callers that need a native runtime baseline (e.g. `klio-bench`).

use std::collections::hash_map::DefaultHasher;
use std::env;
use std::fs;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::process::Command;

use klio_interp_ir::build::build_module;
use klio_interp_ir::Vm;
use klio_lexer::Lexer;
use klio_parser::Parser as KtParser;
use klio_span::SourceMap;

/// Stdout sink that captures every `println` line for parity diffing.
#[derive(Default)]
struct CaptureOutput {
    lines: Vec<String>,
    cur: String,
}
impl klio_runtime::Output for CaptureOutput {
    fn write(&mut self, s: &str) {
        self.cur.push_str(s);
        while let Some(idx) = self.cur.find('\n') {
            let line: String = self.cur.drain(..=idx).collect();
            self.lines.push(line.trim_end_matches('\n').to_string());
        }
    }
    fn writeln(&mut self, s: &str) {
        self.write(s);
        self.write("\n");
    }
}

#[derive(Debug)]
pub struct ParityReport {
    pub matched: bool,
    pub kotlinc_stdout: String,
    pub klio_stdout: String,
    pub kotlinc_exit: Option<i32>,
    pub klio_error: Option<String>,
}

#[derive(Debug)]
pub enum ParityError {
    NoKotlinc,
    NoJava,
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
                "kotlinc not found. Set KLIO_KOTLINC_JVM_HOME to a kotlinc dist, or let the harness auto-install."
            ),
            Self::NoJava => write!(
                f,
                "java not found on PATH (required to run JVM kotlinc output); set JAVA_HOME or install a JDK."
            ),
            Self::Compile(msg) => write!(f, "kotlinc compile failed:\n{msg}"),
            Self::Install(msg) => write!(f, "kotlinc install failed: {msg}"),
            Self::UnsupportedPlatform(s) => {
                write!(f, "no kotlinc prebuilt for platform: {s}")
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

/// Default kotlinc version we target (applies to both JVM and Native).
pub const TARGET_VERSION: &str = "2.3.21";

/// Which Kotlin compiler distribution to download/locate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KotlincKind {
    /// JVM `kotlinc` (`kotlin-compiler-<v>.zip` from JetBrains GitHub).
    Jvm,
    /// `kotlinc-native` (`kotlin-native-prebuilt-<slug>-<v>.tar.gz` from the
    /// JetBrains CDN, extracted under `~/.konan/`).
    Native,
}

impl KotlincKind {
    fn binary_name(self) -> &'static str {
        match self {
            Self::Jvm => {
                if cfg!(windows) { "kotlinc.bat" } else { "kotlinc" }
            }
            Self::Native => {
                if cfg!(windows) { "kotlinc-native.bat" } else { "kotlinc-native" }
            }
        }
    }

    fn env_override(self) -> &'static str {
        match self {
            Self::Jvm => "KLIO_KOTLINC_JVM_HOME",
            Self::Native => "KLIO_KOTLINC_NATIVE",
        }
    }
}

fn java_filename() -> &'static str {
    if cfg!(windows) { "java.exe" } else { "java" }
}

fn workspace_root() -> PathBuf {
    let m = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    m.parent().and_then(|p| p.parent()).map(PathBuf::from).unwrap_or(m)
}

fn parity_cache_dir() -> PathBuf {
    let target = env::var_os("CARGO_TARGET_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| workspace_root().join("target"));
    target.join("parity-cache")
}

fn konan_root() -> Result<PathBuf, ParityError> {
    if let Ok(v) = env::var("KONAN_DATA_DIR") {
        return Ok(PathBuf::from(v));
    }
    let home = env::var_os("HOME")
        .ok_or_else(|| ParityError::Install("HOME not set; cannot resolve ~/.konan".into()))?;
    Ok(PathBuf::from(home).join(".konan"))
}

/// Kotlin/Native distribution descriptor: (archive os-arch slug, CDN subdir, archive extension).
fn native_platform_slug() -> Result<(&'static str, &'static str, &'static str), ParityError> {
    let os = env::consts::OS;
    let arch = env::consts::ARCH;
    let triple = match (os, arch) {
        ("macos", "aarch64") => ("macos-aarch64", "macos", "tar.gz"),
        ("macos", "x86_64") => ("macos-x86_64", "macos", "tar.gz"),
        ("linux", "x86_64") => ("linux-x86_64", "linux", "tar.gz"),
        ("windows", "x86_64") => ("windows-x86_64", "windows", "zip"),
        _ => return Err(ParityError::UnsupportedPlatform(format!("{os}-{arch}"))),
    };
    Ok(triple)
}

/// JVM install directory for `version` (default-cached layout).
fn jvm_install_dir(version: &str) -> PathBuf {
    parity_cache_dir().join(format!("kotlinc-{version}"))
}

/// Backwards-compatible alias for [`find_kotlinc_kind`] with [`KotlincKind::Jvm`].
pub fn find_kotlinc() -> Result<PathBuf, ParityError> {
    find_kotlinc_kind(KotlincKind::Jvm)
}

/// Locate the requested `kotlinc` binary. Search order (per kind):
///   1. Kind-specific env var (`KLIO_KOTLINC_JVM_HOME` / `KLIO_KOTLINC_NATIVE`).
///   2. Default cached install location.
///   3. `PATH`.
///
/// When not found, attempts to auto-install unless `KLIO_NO_AUTO_INSTALL_KOTLINC=1`.
pub fn find_kotlinc_kind(kind: KotlincKind) -> Result<PathBuf, ParityError> {
    if let Some(p) = locate_kotlinc(kind) {
        return Ok(p);
    }
    if env::var("KLIO_NO_AUTO_INSTALL_KOTLINC").is_ok_and(|v| !v.is_empty() && v != "0") {
        return Err(ParityError::NoKotlinc);
    }
    install_kotlinc_kind(kind, TARGET_VERSION)?;
    locate_kotlinc(kind).ok_or(ParityError::NoKotlinc)
}

fn locate_kotlinc(kind: KotlincKind) -> Option<PathBuf> {
    let binary = kind.binary_name();
    if let Ok(v) = env::var(kind.env_override()) {
        // The JVM override is a kotlinc dist root (with bin/kotlinc inside); the
        // native override historically points at the kotlinc-native binary
        // directly. Accept either form for both.
        let candidate = PathBuf::from(&v);
        if candidate.is_file() {
            return Some(candidate);
        }
        let inside = candidate.join("bin").join(binary);
        if inside.is_file() {
            return Some(inside);
        }
    }
    match kind {
        KotlincKind::Jvm => {
            let p = jvm_install_dir(TARGET_VERSION).join("bin").join(binary);
            if p.is_file() {
                return Some(p);
            }
        }
        KotlincKind::Native => {
            // Match any kotlin-native-prebuilt-*-{TARGET_VERSION} dir under ~/.konan
            // (not just our default slug), to honor pre-existing installs.
            if let Ok(root) = konan_root()
                && let Ok(entries) = fs::read_dir(&root)
            {
                for entry in entries.flatten() {
                    let name = entry.file_name();
                    let s = name.to_string_lossy();
                    if s.starts_with("kotlin-native-prebuilt-")
                        && s.contains(TARGET_VERSION)
                        && !s.contains("-RC")
                    {
                        let p = entry.path().join("bin").join(binary);
                        if p.is_file() {
                            return Some(p);
                        }
                    }
                }
            }
        }
    }
    if let Ok(path) = env::var("PATH") {
        for dir in env::split_paths(&path) {
            let p = dir.join(binary);
            if p.is_file() {
                return Some(p);
            }
        }
    }
    None
}

fn locate_java() -> Result<PathBuf, ParityError> {
    if let Ok(home) = env::var("JAVA_HOME") {
        let p = PathBuf::from(home).join("bin").join(java_filename());
        if p.is_file() {
            return Ok(p);
        }
    }
    if let Ok(path) = env::var("PATH") {
        for dir in env::split_paths(&path) {
            let p = dir.join(java_filename());
            if p.is_file() {
                return Ok(p);
            }
        }
    }
    Err(ParityError::NoJava)
}

/// Backwards-compatible alias for [`install_kotlinc_kind`] with [`KotlincKind::Jvm`].
pub fn install_kotlinc(version: &str) -> Result<PathBuf, ParityError> {
    install_kotlinc_kind(KotlincKind::Jvm, version)
}

/// Download + extract the requested kotlinc distribution. Idempotent: if the
/// destination already has a working binary, this is a no-op.
pub fn install_kotlinc_kind(kind: KotlincKind, version: &str) -> Result<PathBuf, ParityError> {
    match kind {
        KotlincKind::Jvm => install_jvm(version),
        KotlincKind::Native => install_native(version),
    }
}

fn install_jvm(version: &str) -> Result<PathBuf, ParityError> {
    match (env::consts::OS, env::consts::ARCH) {
        ("macos" | "linux" | "windows", _) => {}
        (os, arch) => return Err(ParityError::UnsupportedPlatform(format!("{os}-{arch}"))),
    }

    let cache = parity_cache_dir();
    fs::create_dir_all(&cache)?;
    let dest = cache.join(format!("kotlinc-{version}"));
    let kotlinc = dest.join("bin").join(KotlincKind::Jvm.binary_name());
    if kotlinc.is_file() {
        return Ok(dest);
    }

    let lock_path = cache.join(format!(".kotlinc-{version}.installing"));
    let _lock = InstallLock::acquire(&lock_path)?;
    if kotlinc.is_file() {
        return Ok(dest);
    }

    let archive_name = format!("kotlin-compiler-{version}.zip");
    let url = format!(
        "https://github.com/JetBrains/kotlin/releases/download/v{version}/{archive_name}"
    );
    let archive_path = cache.join(&archive_name);
    eprintln!("[parity] installing JVM kotlinc {version} into {}", cache.display());
    eprintln!("[parity] downloading {url}");
    download(&url, &archive_path)?;

    let staging = cache.join(format!(".kotlinc-{version}.partial"));
    let _ = fs::remove_dir_all(&staging);
    fs::create_dir_all(&staging)?;
    extract_archive(&archive_path, &staging, "zip")?;

    let inner = staging.join("kotlinc");
    if !inner.is_dir() {
        return Err(ParityError::Install("kotlinc/ missing in archive".into()));
    }
    if dest.exists() {
        let _ = fs::remove_dir_all(&dest);
    }
    fs::rename(&inner, &dest).map_err(|e| {
        ParityError::Install(format!("rename {} -> {}: {e}", inner.display(), dest.display()))
    })?;
    let _ = fs::remove_dir_all(&staging);
    let _ = fs::remove_file(&archive_path);

    #[cfg(unix)]
    {
        for name in ["kotlinc", "kotlin", "kotlinc-jvm"] {
            let p = dest.join("bin").join(name);
            if p.is_file() {
                let _ = Command::new("chmod").arg("+x").arg(&p).status();
            }
        }
    }

    if !kotlinc.is_file() {
        return Err(ParityError::Install(format!(
            "{} missing after extract",
            kotlinc.display()
        )));
    }
    eprintln!("[parity] kotlinc {version} ready at {}", dest.display());
    Ok(dest)
}

fn install_native(version: &str) -> Result<PathBuf, ParityError> {
    let (slug, subdir, ext) = native_platform_slug()?;
    let root = konan_root()?;
    fs::create_dir_all(&root)?;
    let dir_name = format!("kotlin-native-prebuilt-{slug}-{version}");
    let dest = root.join(&dir_name);
    let kotlinc = dest.join("bin").join(KotlincKind::Native.binary_name());
    if kotlinc.is_file() {
        return Ok(dest);
    }

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
    eprintln!(
        "[parity] installing kotlin-native {version} ({slug}) into {}",
        root.display()
    );
    eprintln!("[parity] downloading {url}");
    download(&url, &archive_path)?;

    let staging = root.join(format!(".{dir_name}.partial"));
    let _ = fs::remove_dir_all(&staging);
    fs::create_dir_all(&staging)?;
    extract_archive(&archive_path, &staging, ext)?;

    let extracted = staging.join(&dir_name);
    let extracted = if extracted.is_dir() {
        extracted
    } else {
        // Fallback: pick the single top-level dir the archive produced.
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

fn download(url: &str, dest: &Path) -> Result<(), ParityError> {
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

fn extract_archive(archive: &Path, into: &Path, ext: &str) -> Result<(), ParityError> {
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

fn cache_key(file: &Path) -> String {
    let bytes = fs::read(file).unwrap_or_default();
    let mut h = DefaultHasher::new();
    bytes.hash(&mut h);
    format!("{:016x}", h.finish())
}

/// Compile a `.kt` file with JVM `kotlinc` into a self-contained jar, cached by
/// content hash.
pub fn compile_with_kotlinc(file: &Path) -> Result<PathBuf, ParityError> {
    let kotlinc = find_kotlinc()?;
    let dir = parity_cache_dir().join("jars");
    fs::create_dir_all(&dir)?;
    let key = cache_key(file);
    let out = dir.join(format!("{key}.jar"));
    if out.is_file() {
        return Ok(out);
    }
    let result = Command::new(&kotlinc)
        .arg(file)
        .arg("-include-runtime")
        .arg("-d")
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

/// Run a previously-compiled jar under `java -jar`, returning captured stdout
/// and exit code. Exposed so the parity test can time the stages individually.
pub fn run_kotlinc_jar(jar: &Path) -> Result<(String, Option<i32>), ParityError> {
    let java = locate_java()?;
    let result = Command::new(java).arg("-jar").arg(jar).output()?;
    let stdout = String::from_utf8_lossy(&result.stdout).into_owned();
    Ok((stdout, result.status.code()))
}

/// Run a specific fully-qualified main class out of `jar`. Used by the bulk
/// corpus build, where one jar contains all corpus mains in distinct packages.
pub fn run_class(jar: &Path, fqcn: &str) -> Result<(String, Option<i32>), ParityError> {
    let java = locate_java()?;
    let result = Command::new(java).arg("-cp").arg(jar).arg(fqcn).output()?;
    let stdout = String::from_utf8_lossy(&result.stdout).into_owned();
    Ok((stdout, result.status.code()))
}

/// Output of a one-shot `kotlinc` compile over an entire corpus: a single jar
/// holding every file's `main`, each in its own `klio_parity.<label>.<stem>`
/// package, plus the mapping from original `.kt` path to the staged source
/// (with the synthesized `package` line) and JVM FQCN of its `main` class.
///
/// The staged source is what we should feed the klio interpreter too — running
/// it against the original would silently drop the staged package, so klio's
/// FQ class names (used by default `toString` and the `Enum.valueOf` error
/// message) would diverge from kotlinc's purely as a harness artifact.
#[derive(Debug, Clone)]
pub struct CorpusBuild {
    pub jar: PathBuf,
    pub stage_dir: PathBuf,
    pub classes: Vec<CorpusEntry>,
}

#[derive(Debug, Clone)]
pub struct CorpusEntry {
    pub original: PathBuf,
    pub staged: PathBuf,
    pub fqcn: String,
}

/// Compile a whole list of `.kt` files in one `kotlinc` invocation. Each file
/// is staged under a unique package so `fun main()` declarations don't collide.
/// The resulting jar is cached by `(label, sorted file contents)` and reused.
///
/// Assumes the inputs are simple top-level scripts with no existing `package`
/// declaration or `@file:` annotations — the current corpus and `examples/`
/// satisfy that. If that assumption breaks, audit `stage_one`.
pub fn compile_corpus(label: &str, files: &[PathBuf]) -> Result<CorpusBuild, ParityError> {
    let kotlinc = find_kotlinc()?;
    let cache = parity_cache_dir();
    fs::create_dir_all(&cache)?;

    let key = corpus_cache_key(label, files);
    let jar = cache.join(format!("corpus-{label}-{key}.jar"));
    let stage = cache.join(format!("stage-{label}-{key}"));

    // Always (re)stage. The writes are cheap (~50 KB total for the whole
    // corpus) and the staged sources double as the klio interpreter's input,
    // so they must be present even on a cache hit for the jar.
    let _ = fs::remove_dir_all(&stage);
    fs::create_dir_all(&stage)?;
    let mut classes = Vec::with_capacity(files.len());
    for file in files {
        let stem = file
            .file_stem()
            .and_then(|s| s.to_str())
            .ok_or_else(|| ParityError::Compile(format!("bad filename: {}", file.display())))?;
        let pkg_seg = sanitize_pkg_segment(stem);
        let pkg = format!("klio_parity.{label}.{pkg_seg}");
        let fqcn = format!("{pkg}.{}Kt", capitalize_first(stem));
        let src = fs::read_to_string(file)?;
        let rewritten = inject_jvm_inline(&src);
        let shimmed = format!("package {pkg}\n\n{rewritten}");
        let staged = stage.join(format!("{stem}.kt"));
        fs::write(&staged, shimmed)?;
        classes.push(CorpusEntry {
            original: file.clone(),
            staged,
            fqcn,
        });
    }

    if jar.is_file() {
        return Ok(CorpusBuild { jar, stage_dir: stage, classes });
    }

    // kotlinc picks output kind from the `-d` extension: `.jar` → jar file,
    // anything else → a directory of `.class` files. We need a jar, so the
    // partial path must keep `.jar` last; previously we used `.jar.part`
    // (extension `.part`) and ended up with a stale directory that the rename
    // below could not move over the real jar.
    let tmp = cache.join(format!("corpus-{label}-{key}.partial.jar"));
    let _ = fs::remove_file(&tmp);
    let _ = fs::remove_dir_all(&tmp);
    let result = Command::new(&kotlinc)
        .arg(&stage)
        .arg("-include-runtime")
        .arg("-d")
        .arg(&tmp)
        .output()?;
    if !result.status.success() {
        let _ = fs::remove_file(&tmp);
        return Err(ParityError::Compile(format!(
            "{}\n{}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        )));
    }
    fs::rename(&tmp, &jar)?;
    Ok(CorpusBuild { jar, stage_dir: stage, classes })
}

fn corpus_cache_key(label: &str, files: &[PathBuf]) -> String {
    let mut h = DefaultHasher::new();
    label.hash(&mut h);
    let mut sorted: Vec<&PathBuf> = files.iter().collect();
    sorted.sort();
    for f in sorted {
        f.file_name().and_then(|s| s.to_str()).unwrap_or("").hash(&mut h);
        let bytes = fs::read(f).unwrap_or_default();
        bytes.hash(&mut h);
    }
    format!("{:016x}", h.finish())
}

/// Kotlin (hard) and Java reserved words. A `.kt` file whose stem is one of
/// these can't be used directly as a package segment — `package …​.typealias`
/// is rejected by kotlinc-native because `typealias` is a keyword. We suffix
/// an underscore for collisions; the staged filename (and therefore the
/// generated `…​Kt` class name) is unchanged, so the original capitalization
/// continues to drive `FQCN`.
fn sanitize_pkg_segment(stem: &str) -> String {
    const RESERVED: &[&str] = &[
        // Kotlin hard keywords
        "as", "break", "class", "continue", "do", "else", "false", "for", "fun", "if", "in",
        "interface", "is", "null", "object", "package", "return", "super", "this", "throw",
        "true", "try", "typealias", "typeof", "val", "var", "when", "while",
        // Java reserved words (JVM backend rejects these as package segments too)
        "abstract", "assert", "boolean", "byte", "case", "catch", "char", "const", "default",
        "double", "enum", "extends", "final", "finally", "float", "goto", "implements",
        "import", "instanceof", "int", "long", "native", "new", "private", "protected",
        "public", "short", "static", "strictfp", "switch", "synchronized", "throws",
        "transient", "void", "volatile",
    ];
    if RESERVED.iter().any(|w| *w == stem) {
        format!("{stem}_")
    } else {
        stem.to_string()
    }
}

fn capitalize_first(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => c.to_ascii_uppercase().to_string() + chars.as_str(),
        None => String::new(),
    }
}

/// JVM `kotlinc` rejects `value class` declarations without an explicit
/// `@JvmInline` annotation; native `kotlinc` doesn't require it. The corpus is
/// JVM-agnostic so we inject the annotation during staging to keep both backends
/// happy from a single source.
///
/// The scan is line-based and intentionally conservative: a line is considered
/// a `value class` declaration when, after stripping leading whitespace,
/// annotations, and recognized declaration modifiers, it begins with
/// `value class`. If the preceding non-blank emitted line is already
/// `@JvmInline` we leave it alone.
fn inject_jvm_inline(src: &str) -> String {
    let mut out = String::with_capacity(src.len() + 32);
    let mut prev_had_jvminline = false;
    for line in src.split_inclusive('\n') {
        if declares_value_class(line) && !prev_had_jvminline {
            let trimmed = line.trim_start();
            let indent = &line[..line.len() - trimmed.len()];
            out.push_str(indent);
            out.push_str("@JvmInline\n");
        }
        out.push_str(line);
        let t = line.trim();
        if !t.is_empty() {
            prev_had_jvminline = t.starts_with("@JvmInline");
        }
    }
    out
}

fn declares_value_class(line: &str) -> bool {
    const MODIFIERS: &[&str] = &[
        "public ",
        "private ",
        "internal ",
        "protected ",
        "expect ",
        "actual ",
        "external ",
        "open ",
        "final ",
        "abstract ",
        "sealed ",
        "data ",
        "enum ",
        "annotation ",
        "companion ",
        "inner ",
        "inline ",
    ];
    let mut rest = line.trim_start();
    loop {
        // Strip a leading annotation `@Foo` or `@Foo(...)`.
        if let Some(after_at) = rest.strip_prefix('@') {
            let end = after_at
                .find(|c: char| c.is_whitespace() || c == '(')
                .unwrap_or(after_at.len());
            let mut tail = &after_at[end..];
            // Skip a parenthesized arg list if present.
            if tail.starts_with('(') {
                let mut depth = 0i32;
                let bytes = tail.as_bytes();
                let mut i = 0;
                while i < bytes.len() {
                    match bytes[i] {
                        b'(' => depth += 1,
                        b')' => {
                            depth -= 1;
                            if depth == 0 {
                                i += 1;
                                break;
                            }
                        }
                        _ => {}
                    }
                    i += 1;
                }
                tail = &tail[i..];
            }
            rest = tail.trim_start();
            continue;
        }
        let mut advanced = None;
        for m in MODIFIERS {
            if let Some(s) = rest.strip_prefix(m) {
                advanced = Some(s.trim_start());
                break;
            }
        }
        match advanced {
            Some(next) => rest = next,
            None => break,
        }
    }
    rest.starts_with("value class ") || rest.starts_with("value class\t")
}

#[cfg(test)]
mod inject_tests {
    use super::*;

    #[test]
    fn plain_value_class_gets_annotation() {
        let out = inject_jvm_inline("value class UserId(val raw: Int)\n");
        assert!(out.starts_with("@JvmInline\nvalue class UserId"));
    }

    #[test]
    fn modifier_chain_handled() {
        let out = inject_jvm_inline("public value class X(val a: Int)\n");
        assert!(out.contains("@JvmInline\npublic value class X"));
    }

    #[test]
    fn existing_annotation_left_alone() {
        let src = "@JvmInline\nvalue class X(val a: Int)\n";
        assert_eq!(inject_jvm_inline(src), src);
    }

    #[test]
    fn indented_value_class_preserves_indent() {
        let src = "    value class Inner(val a: Int)\n";
        assert_eq!(
            inject_jvm_inline(src),
            "    @JvmInline\n    value class Inner(val a: Int)\n"
        );
    }

    #[test]
    fn unrelated_lines_unchanged() {
        let src = "fun main() { println(\"value class\") }\n";
        assert_eq!(inject_jvm_inline(src), src);
    }
}

/// Run a `.kt` file directly through the `klio` interpreter library, returning
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
    klio_interp_ir::set_coroutine_time_mode(klio_interp_ir::TimeMode::Virtual);
    let mut out = CaptureOutput::default();
    let r = klio_resolver::resolve(&ast);
    let _ = klio_typeck::typecheck(&ast, &r);
    let built = build_module(&ast);
    let Some(main_id) = built.main else {
        return Err("no main function in module".into());
    };
    let (mut vm, _main) = Vm::from_built(built);
    vm.run(main_id, &mut out).map_err(|e| format!("runtime error: {e}"))?;
    if !out.cur.is_empty() {
        let trailing = std::mem::take(&mut out.cur);
        out.lines.push(trailing);
    }
    let mut joined = out.lines.join("\n");
    if !joined.is_empty() {
        joined.push('\n');
    }
    Ok(joined)
}

/// One source root parsed out of a pack's `klio.toml`: either a
/// plain `source_roots` string (no filters) or a `[[source]]` table
/// with `include`/`exclude`. Mirrors the pack builder's shape so
/// `run_with_packs` collects exactly the files the installed pack
/// would carry.
struct ManifestRoot {
    root: String,
    include: Vec<String>,
    exclude: Vec<String>,
}

/// Match `rel` (a slash-normalized path relative to a source root)
/// against one pattern. Same forms the pack builder accepts: exact,
/// trailing-`/` directory prefix, leading-`*` suffix glob, trailing-`*`
/// prefix glob.
fn manifest_pat_match(rel: &str, pat: &str) -> bool {
    if let Some(prefix) = pat.strip_suffix('/') {
        return rel == prefix || rel.starts_with(pat);
    }
    if let Some(suffix) = pat.strip_prefix('*') {
        return rel.ends_with(suffix);
    }
    if let Some(prefix) = pat.strip_suffix('*') {
        return rel.starts_with(prefix);
    }
    rel == pat
}

/// Minimal reader for the two `klio.toml` shapes the in-repo kotlinx
/// packs use: top-level `source_roots = ["a", "b"]` and any number of
/// `[[source]]` tables carrying `root` / `include` / `exclude`. This
/// is intentionally not a general TOML parser — it understands just
/// enough to mirror the pack builder so the conformance harness loads
/// each pack the same way an installed `.klio-pack` would.
fn parse_manifest_roots(toml: &str) -> Vec<ManifestRoot> {
    fn string_array(rest: &str) -> Vec<String> {
        rest.trim()
            .trim_start_matches('[')
            .trim_end_matches(']')
            .split(',')
            .filter_map(|s| {
                let t = s.trim().trim_matches('"');
                (!t.is_empty()).then(|| t.to_string())
            })
            .collect()
    }

    // Coalesce multi-line arrays into one logical line so
    // `include = [\n "a",\n "b",\n]` parses as a single `key = [...]`
    // statement. Comments are stripped per physical line first.
    let mut logical: Vec<String> = Vec::new();
    let mut pending: Option<String> = None;
    for raw in toml.lines() {
        let line = raw.split('#').next().unwrap_or("").trim();
        if let Some(buf) = pending.as_mut() {
            buf.push(' ');
            buf.push_str(line);
            if line.contains(']') {
                logical.push(pending.take().unwrap());
            }
            continue;
        }
        if line.is_empty() {
            continue;
        }
        // An array value whose `]` hasn't appeared yet starts a
        // continuation buffer.
        if line.contains('[') && !line.contains(']') && line.contains('=') {
            pending = Some(line.to_string());
            continue;
        }
        logical.push(line.to_string());
    }
    if let Some(buf) = pending.take() {
        logical.push(buf);
    }

    let mut plain: Vec<String> = Vec::new();
    let mut tables: Vec<ManifestRoot> = Vec::new();
    let mut cur: Option<ManifestRoot> = None;
    let mut in_source_table = false;
    for line in &logical {
        let line = line.as_str();
        if line.is_empty() {
            continue;
        }
        if line == "[[source]]" {
            if let Some(c) = cur.take() {
                tables.push(c);
            }
            cur = Some(ManifestRoot { root: String::new(), include: Vec::new(), exclude: Vec::new() });
            in_source_table = true;
            continue;
        }
        if line.starts_with('[') {
            if let Some(c) = cur.take() {
                tables.push(c);
            }
            in_source_table = false;
            continue;
        }
        let Some((key, val)) = line.split_once('=') else { continue };
        let key = key.trim();
        let val = val.trim();
        if in_source_table {
            let Some(c) = cur.as_mut() else { continue };
            match key {
                "root" => c.root = val.trim_matches('"').to_string(),
                "include" => c.include = string_array(val),
                "exclude" => c.exclude = string_array(val),
                _ => {}
            }
        } else if key == "source_roots" {
            plain = string_array(val);
        }
    }
    if let Some(c) = cur.take() {
        tables.push(c);
    }

    let mut out: Vec<ManifestRoot> = plain
        .into_iter()
        .map(|root| ManifestRoot { root, include: Vec::new(), exclude: Vec::new() })
        .collect();
    out.extend(tables);
    out
}

/// Recursively collect every `.kt` file under `dir`, returning paths
/// relative to `dir` (slash-normalized).
fn walk_kt(dir: &Path, base: &Path, out: &mut Vec<(String, PathBuf)>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut entries: Vec<_> = entries.flatten().collect();
    entries.sort_by_key(std::fs::DirEntry::path);
    for e in entries {
        let p = e.path();
        if p.is_dir() {
            walk_kt(&p, base, out);
        } else if p.extension().map(|x| x == "kt").unwrap_or(false) {
            let rel = p
                .strip_prefix(base)
                .unwrap_or(&p)
                .to_string_lossy()
                .replace('\\', "/");
            out.push((rel, p));
        }
    }
}

/// Collect a pack's Kotlin sources by reading its `klio.toml`
/// `source_roots` / `[[source]]` tables and applying the same
/// include/exclude selection the pack builder uses. Returns absolute
/// paths sorted by their root-relative path, deduplicated.
fn collect_manifest_sources(pack_dir: &Path) -> Result<Vec<PathBuf>, String> {
    let toml_path = pack_dir.join("klio.toml");
    let toml = std::fs::read_to_string(&toml_path)
        .map_err(|e| format!("read {}: {e}", toml_path.display()))?;
    let mut roots = parse_manifest_roots(&toml);
    if roots.is_empty() {
        roots.push(ManifestRoot {
            root: "src".to_string(),
            include: Vec::new(),
            exclude: Vec::new(),
        });
    }
    let mut seen: std::collections::HashSet<PathBuf> = std::collections::HashSet::new();
    let mut picked: Vec<(String, PathBuf)> = Vec::new();
    for r in &roots {
        let root_path = pack_dir.join(&r.root);
        if !root_path.is_dir() {
            continue;
        }
        let mut found: Vec<(String, PathBuf)> = Vec::new();
        walk_kt(&root_path, &root_path, &mut found);
        for (rel, abs) in found {
            let included = r.include.is_empty()
                || r.include.iter().any(|pat| manifest_pat_match(&rel, pat));
            if !included {
                continue;
            }
            if r.exclude.iter().any(|pat| manifest_pat_match(&rel, pat)) {
                continue;
            }
            if seen.insert(abs.clone()) {
                picked.push((rel, abs));
            }
        }
    }
    picked.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(picked.into_iter().map(|(_, p)| p).collect())
}

/// Run a `.kt` file through the `klio` interpreter library with the
/// in-repo kotlinx packs (coroutines, atomicfu) loaded and their
/// host bindings installed — the same shape the `klio` binary uses,
/// but sourced from each pack's `klio.toml` manifest so it is
/// independent of `~/.klio/packs`. Used by the memory-model
/// conformance suite.
pub fn run_with_packs(file: &Path) -> Result<String, String> {
    fn parse(
        map: &mut SourceMap,
        path: &Path,
        text: String,
    ) -> Result<klio_ast::KotlinFile, String> {
        let id = map.add(path, text);
        let src = map.get(id).source.clone();
        let lexed = Lexer::new(id, &src).tokenize();
        if lexed.diagnostics.has_errors() {
            return Err(format!("lex: {:?}", lexed.diagnostics.diagnostics()));
        }
        let (ast, diags) = KtParser::new(id, &src, &lexed.tokens).parse_file();
        if diags.has_errors() {
            return Err(format!("parse: {:?}", diags.diagnostics()));
        }
        Ok(ast)
    }

    let ws = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .map(PathBuf::from)
        .ok_or("workspace root")?;
    // Drive every in-repo kotlinx pack off its own `klio.toml`
    // `source_roots` / `[[source]]` tables instead of a hard-coded
    // file list, so the atomicfu pack picks up its curated upstream
    // commonMain + klioMain actuals. Coroutines still declares
    // `source_roots = ["shim"]`, so its collected set is byte-for-byte
    // the two files the old hard-coded list named.
    let pack_dirs = [
        ws.join("crates/klio-kotlinx-coroutines"),
        ws.join("crates/klio-kotlinx-atomicfu"),
    ];

    let mut map = SourceMap::new();
    let mut asts: Vec<klio_ast::KotlinFile> = Vec::new();
    for pack_dir in &pack_dirs {
        for src_path in collect_manifest_sources(pack_dir)? {
            let text = std::fs::read_to_string(&src_path).map_err(|e| e.to_string())?;
            let ast = parse(&mut map, &src_path, text)?;
            if let Some(pkg) = &ast.package {
                let path = pkg
                    .path
                    .iter()
                    .map(|i| i.name.as_str())
                    .collect::<Vec<_>>()
                    .join(".");
                if !path.is_empty() {
                    klio_stdlib::register_known_package(path);
                }
            }
            asts.push(ast);
        }
    }
    let user_src = std::fs::read_to_string(file).map_err(|e| e.to_string())?;
    asts.push(parse(&mut map, file, user_src)?);

    let mut bindings = klio_stdlib::HostBindings::with_stdlib_defaults();
    for (sym, f) in klio_kotlinx_coroutines::host_bindings().entries() {
        bindings.register(sym, f);
    }
    for (sym, f) in klio_kotlinx_atomicfu::host_bindings().entries() {
        bindings.register(sym, f);
    }

    // Conformance / smoke determinism: timed coroutine programs are
    // only byte-deterministic under virtual time.
    klio_interp_ir::set_coroutine_time_mode(klio_interp_ir::TimeMode::Virtual);
    for ast in &asts {
        let r = klio_resolver::resolve(ast);
        let _ = klio_typeck::typecheck(ast, &r);
    }
    let built = klio_interp_ir::build::build_module_files(&asts);
    let Some(main_id) = built.main else {
        return Err("no main function in module".into());
    };
    let (mut vm, _main) = Vm::from_built(built);
    vm.set_installed_bindings(bindings);
    let mut out = CaptureOutput::default();
    vm.run(main_id, &mut out)
        .map_err(|e| format!("runtime error: {e}"))?;
    if !out.cur.is_empty() {
        out.lines.push(std::mem::take(&mut out.cur));
    }
    let mut joined = out.lines.join("\n");
    if !joined.is_empty() {
        joined.push('\n');
    }
    Ok(joined)
}

/// Full parity check: compile + run both compilers, return a report.
pub fn check(file: &Path) -> Result<ParityReport, ParityError> {
    let jar = compile_with_kotlinc(file)?;
    let (kotlinc_stdout, kotlinc_exit) = run_kotlinc_jar(&jar)?;
    match run_with_ktc(file) {
        Ok(klio_stdout) => Ok(ParityReport {
            matched: kotlinc_stdout == klio_stdout,
            kotlinc_stdout,
            klio_stdout,
            kotlinc_exit,
            klio_error: None,
        }),
        Err(e) => Ok(ParityReport {
            matched: false,
            kotlinc_stdout,
            klio_stdout: String::new(),
            kotlinc_exit,
            klio_error: Some(e),
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
    out.push_str("--- kotlinc\n");
    out.push_str("+++ klio\n");
    let a: Vec<&str> = report.kotlinc_stdout.lines().collect();
    let b: Vec<&str> = report.klio_stdout.lines().collect();
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
    if let Some(e) = &report.klio_error {
        out.push_str("klio error: ");
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
        let tmp = std::env::temp_dir().join("klio-parity-cache-key.kt");
        fs::write(&tmp, b"fun main() { println(1) }").unwrap();
        let a = cache_key(&tmp);
        let b = cache_key(&tmp);
        assert_eq!(a, b);
    }
}
