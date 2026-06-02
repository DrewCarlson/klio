//! File walking + per-file parse driving.

use std::fs;
use std::path::{Path, PathBuf};

use crate::parse::{parse_file, Decl};

#[derive(Debug, Default, Clone)]
pub struct CollectStats {
    pub files_seen: usize,
    pub files_parsed: usize,
    pub files_failed: Vec<(PathBuf, String)>,
    pub total_decls: usize,
}

#[derive(Debug, Clone)]
pub struct FileDecls {
    pub rel_path: String,
    pub package: String,
    pub decls: Vec<Decl>,
}

/// Walk the curated stdlib roots under `stdlib_root` and return all parsed
/// declarations. `stdlib_root` is expected to be `kotlin/libraries/stdlib`.
#[must_use] 
pub fn collect_decls(stdlib_root: &Path) -> (Vec<FileDecls>, CollectStats) {
    let mut out = Vec::new();
    let mut stats = CollectStats::default();

    let roots = [
        stdlib_root.join("common/src/generated"),
        stdlib_root.join("common/src/kotlin"),
        stdlib_root.join("src/kotlin"),
    ];

    let mut files: Vec<PathBuf> = Vec::new();
    for r in &roots {
        gather_kt_files(r, &mut files);
    }
    files.sort();

    for path in &files {
        stats.files_seen += 1;
        let rel = match path.strip_prefix(stdlib_root) {
            Ok(p) => p.to_string_lossy().to_string(),
            Err(_) => path.to_string_lossy().to_string(),
        };
        match fs::read_to_string(path) {
            Ok(src) => {
                let pf = parse_file(&src);
                stats.files_parsed += 1;
                stats.total_decls += pf.decls.len();
                out.push(FileDecls {
                    rel_path: rel,
                    package: pf.package,
                    decls: pf.decls,
                });
            }
            Err(e) => {
                stats.files_failed.push((path.clone(), e.to_string()));
            }
        }
    }
    (out, stats)
}

fn gather_kt_files(root: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = fs::read_dir(root) else { return };
    for entry in rd.flatten() {
        let p = entry.path();
        if p.is_dir() {
            gather_kt_files(&p, out);
        } else if p.extension().and_then(|e| e.to_str()) == Some("kt") {
            out.push(p);
        }
    }
}
