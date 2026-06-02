//! Reference runners: `kotlinc-native` and JVM `kotlinc`. Both are downloaded
//! on demand via `klio-parity`'s install machinery and are never assumed on
//! PATH.
//!
//! Compiled artifacts are cached under `target/bench-cache/` keyed by
//! source-content hash so repeated bench passes don't recompile.

use std::collections::hash_map::DefaultHasher;
use std::env;
use std::fs;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

pub const KOTLIN_JVM_VERSION: &str = "2.3.21";

#[derive(Debug)]
pub enum RefError {
    Io(std::io::Error),
    Install(String),
    Compile(String),
    NoJava,
    Disabled(String),
}

impl std::fmt::Display for RefError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "io: {e}"),
            Self::Install(s) => write!(f, "install: {s}"),
            Self::Compile(s) => write!(f, "compile: {s}"),
            Self::NoJava => write!(
                f,
                "java not found on PATH (required to run JVM kotlinc); set JAVA_HOME or install a JDK"
            ),
            Self::Disabled(s) => write!(f, "ref runner disabled: {s}"),
        }
    }
}

impl From<std::io::Error> for RefError {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .map(PathBuf::from)
        .expect("workspace root")
}

fn bench_cache_dir() -> PathBuf {
    let target = env::var_os("CARGO_TARGET_DIR")
        .map_or_else(|| workspace_root().join("target"), PathBuf::from);
    target.join("bench-cache")
}

fn hash_file(p: &Path) -> String {
    let bytes = fs::read(p).unwrap_or_default();
    let mut h = DefaultHasher::new();
    bytes.hash(&mut h);
    format!("{:016x}", h.finish())
}

// ---------------------- kotlinc-native ----------------------

/// Time a single end-to-end run of `kotlinc-native` (compile + execute).
/// Compilation is cached by `klio-parity`; only the execution time is measured.
pub fn time_kotlinc_native(file: &Path, iters: u32) -> Result<Duration, RefError> {
    let kotlinc = klio_parity::find_kotlinc_kind(klio_parity::KotlincKind::Native)
        .map_err(|e| RefError::Install(format!("kotlinc-native: {e}")))?;

    let cache = bench_cache_dir().join("native");
    fs::create_dir_all(&cache)?;
    let key = hash_file(file);
    let exe = cache.join(format!("{key}.kexe"));
    if !exe.is_file() {
        let result = Command::new(&kotlinc)
            .arg(file)
            .arg("-o")
            .arg(&exe)
            .output()?;
        if !result.status.success() {
            return Err(RefError::Compile(format!(
                "kotlinc-native:\n{}\n{}",
                String::from_utf8_lossy(&result.stdout),
                String::from_utf8_lossy(&result.stderr)
            )));
        }
    }
    let mut samples = Vec::with_capacity(iters as usize);
    for _ in 0..iters {
        let t = Instant::now();
        let out = Command::new(&exe).output()?;
        if !out.status.success() {
            return Err(RefError::Compile(format!(
                "kotlinc-native binary exit {:?}",
                out.status.code()
            )));
        }
        samples.push(t.elapsed());
    }
    samples.sort();
    Ok(samples[samples.len() / 2])
}

// ---------------------- kotlinc JVM ----------------------

fn kotlinc_jvm_root() -> Result<PathBuf, RefError> {
    if let Ok(v) = env::var("KLIO_KOTLINC_JVM_HOME") {
        let p = PathBuf::from(v);
        if p.join("bin").join(kotlinc_jvm_filename()).is_file() {
            return Ok(p);
        }
    }
    let cache = bench_cache_dir();
    fs::create_dir_all(&cache)?;
    let dest = cache.join(format!("kotlinc-{KOTLIN_JVM_VERSION}"));
    if dest.join("bin").join(kotlinc_jvm_filename()).is_file() {
        return Ok(dest);
    }
    install_kotlinc_jvm(KOTLIN_JVM_VERSION, &cache, &dest)?;
    Ok(dest)
}

fn kotlinc_jvm_filename() -> &'static str {
    if cfg!(windows) {
        "kotlinc.bat"
    } else {
        "kotlinc"
    }
}

fn install_kotlinc_jvm(version: &str, cache: &Path, dest: &Path) -> Result<(), RefError> {
    let archive_name = format!("kotlin-compiler-{version}.zip");
    let url =
        format!("https://github.com/JetBrains/kotlin/releases/download/v{version}/{archive_name}");
    let archive_path = cache.join(&archive_name);
    eprintln!("[bench] downloading {url}");
    let tmp = archive_path.with_extension("part");
    let _ = fs::remove_file(&tmp);
    let curl = Command::new("curl")
        .args(["-fL", "--retry", "3", "--retry-delay", "2", "-o"])
        .arg(&tmp)
        .arg(&url)
        .status();
    let ok = curl.is_ok_and(|s| s.success());
    if !ok {
        let _ = fs::remove_file(&tmp);
        return Err(RefError::Install(format!("download failed: {url}")));
    }
    fs::rename(&tmp, &archive_path)?;

    let staging = cache.join(format!(".kotlinc-{version}.partial"));
    let _ = fs::remove_dir_all(&staging);
    fs::create_dir_all(&staging)?;
    let status = Command::new("unzip")
        .args(["-q"])
        .arg(&archive_path)
        .arg("-d")
        .arg(&staging)
        .status()
        .map_err(|e| RefError::Install(format!("unzip spawn: {e}")))?;
    if !status.success() {
        return Err(RefError::Install("unzip failed".into()));
    }
    // The zip extracts a top-level `kotlinc/` dir.
    let inner = staging.join("kotlinc");
    if !inner.is_dir() {
        return Err(RefError::Install("kotlinc/ missing in archive".into()));
    }
    if dest.exists() {
        let _ = fs::remove_dir_all(dest);
    }
    fs::rename(&inner, dest)?;
    let _ = fs::remove_dir_all(&staging);
    let _ = fs::remove_file(&archive_path);

    // Make scripts executable.
    #[cfg(unix)]
    {
        for name in ["kotlinc", "kotlin", "kotlinc-jvm"] {
            let p = dest.join("bin").join(name);
            if p.is_file() {
                // chmod +x via /bin/chmod since std doesn't expose mode setters
                // without unsafe-adjacent libc bindings.
                let _ = Command::new("chmod").arg("+x").arg(&p).status();
            }
        }
    }
    Ok(())
}

fn locate_java() -> Result<PathBuf, RefError> {
    if let Ok(home) = env::var("JAVA_HOME") {
        let p =
            PathBuf::from(home)
                .join("bin")
                .join(if cfg!(windows) { "java.exe" } else { "java" });
        if p.is_file() {
            return Ok(p);
        }
    }
    if let Ok(path) = env::var("PATH") {
        let name = if cfg!(windows) { "java.exe" } else { "java" };
        for dir in env::split_paths(&path) {
            let p = dir.join(name);
            if p.is_file() {
                return Ok(p);
            }
        }
    }
    Err(RefError::NoJava)
}

/// Compile to JVM bytecode (cached) and time `java -cp ...` runs.
pub fn time_kotlinc_jvm(file: &Path, iters: u32) -> Result<Duration, RefError> {
    let _java = locate_java()?;
    let kotlinc_home = kotlinc_jvm_root()?;
    let kotlinc = kotlinc_home.join("bin").join(kotlinc_jvm_filename());
    let cache = bench_cache_dir().join("jvm");
    fs::create_dir_all(&cache)?;
    let key = hash_file(file);
    let jar = cache.join(format!("{key}.jar"));
    if !jar.is_file() {
        let result = Command::new(&kotlinc)
            .arg(file)
            .arg("-include-runtime")
            .arg("-d")
            .arg(&jar)
            .output()?;
        if !result.status.success() {
            return Err(RefError::Compile(format!(
                "{}\n{}",
                String::from_utf8_lossy(&result.stdout),
                String::from_utf8_lossy(&result.stderr)
            )));
        }
    }
    let java = locate_java()?;
    let mut samples = Vec::with_capacity(iters as usize);
    for _ in 0..iters {
        let t = Instant::now();
        let out = Command::new(&java).arg("-jar").arg(&jar).output()?;
        if !out.status.success() {
            return Err(RefError::Compile(format!(
                "java exit {:?}: {}",
                out.status.code(),
                String::from_utf8_lossy(&out.stderr)
            )));
        }
        samples.push(t.elapsed());
    }
    samples.sort();
    Ok(samples[samples.len() / 2])
}
