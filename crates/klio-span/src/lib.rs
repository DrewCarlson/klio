//! Source positions and file tracking.

use std::ops::Range;
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct FileId(pub u32);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Span {
    pub file: FileId,
    pub start: u32,
    pub end: u32,
}

impl Span {
    #[must_use]
    pub fn new(file: FileId, start: u32, end: u32) -> Self {
        debug_assert!(start <= end);
        Self { file, start, end }
    }

    #[must_use]
    pub fn range(self) -> Range<usize> {
        self.start as usize..self.end as usize
    }

    #[must_use]
    pub fn join(self, other: Self) -> Self {
        debug_assert_eq!(self.file, other.file);
        Self {
            file: self.file,
            start: self.start.min(other.start),
            end: self.end.max(other.end),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SourceFile {
    pub id: FileId,
    pub path: PathBuf,
    pub source: Arc<str>,
    line_starts: Vec<u32>,
}

impl SourceFile {
    #[must_use]
    pub fn new(id: FileId, path: PathBuf, source: impl Into<Arc<str>>) -> Self {
        let source = source.into();
        let mut line_starts = vec![0u32];
        for (i, b) in source.bytes().enumerate() {
            if b == b'\n' {
                line_starts.push((i + 1) as u32);
            }
        }
        Self { id, path, source, line_starts }
    }

    #[must_use]
    pub fn line_col(&self, offset: u32) -> (u32, u32) {
        let line = match self.line_starts.binary_search(&offset) {
            Ok(i) => i,
            Err(i) => i - 1,
        };
        let col = offset - self.line_starts[line];
        (line as u32 + 1, col + 1)
    }
}

#[derive(Debug, Default)]
pub struct SourceMap {
    files: Vec<SourceFile>,
}

impl SourceMap {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add(&mut self, path: impl AsRef<Path>, source: impl Into<Arc<str>>) -> FileId {
        let id = FileId(self.files.len() as u32);
        self.files.push(SourceFile::new(id, path.as_ref().to_path_buf(), source));
        id
    }

    #[must_use]
    pub fn get(&self, id: FileId) -> &SourceFile {
        &self.files[id.0 as usize]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn span_join_extends_range() {
        let f = FileId(0);
        let a = Span::new(f, 0, 3);
        let b = Span::new(f, 5, 9);
        assert_eq!(a.join(b), Span::new(f, 0, 9));
    }

    #[test]
    fn line_col_resolves_offsets() {
        let sf = SourceFile::new(FileId(0), "x.kt".into(), "fun a()\nval b = 1\n");
        assert_eq!(sf.line_col(0), (1, 1));
        assert_eq!(sf.line_col(8), (2, 1));
    }
}
