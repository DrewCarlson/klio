//! Interpreter-only timings: we measure `Interpreter::run` against
//! pre-parsed ASTs, so the numbers attribute purely to evaluation.

use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion};
use klio_interp::{CaptureOutput, Interpreter};
use klio_lexer::Lexer;
use klio_parser::Parser;
use klio_span::SourceMap;
use std::path::{Path, PathBuf};

fn corpus_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).parent().unwrap().join("klio-bench").join("corpus")
}

fn programs() -> Vec<(String, String)> {
    let mut out = Vec::new();
    fn walk(p: &Path, out: &mut Vec<(String, String)>) {
        if p.is_dir() {
            for e in std::fs::read_dir(p).unwrap().flatten() { walk(&e.path(), out); }
        } else if p.extension().is_some_and(|e| e == "kt") {
            let name = p.file_stem().unwrap().to_string_lossy().into_owned();
            let src = std::fs::read_to_string(p).unwrap();
            out.push((name, src));
        }
    }
    walk(&corpus_root(), &mut out);
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

fn bench_eval(c: &mut Criterion) {
    let mut group = c.benchmark_group("eval");
    group.sample_size(15);
    for (name, src) in programs() {
        let mut map = SourceMap::new();
        let id = map.add(Path::new("<bench>"), src.clone());
        let lexed = Lexer::new(id, &src).tokenize();
        let (ast, _) = Parser::new(id, &src, &lexed.tokens).parse_file();
        group.bench_with_input(BenchmarkId::from_parameter(&name), &ast, |b, ast| {
            b.iter(|| {
                let mut out = CaptureOutput::default();
                let _ = Interpreter::new().run_with_output(ast, &mut out);
            });
        });
    }
    group.finish();
}

criterion_group!(benches, bench_eval);
criterion_main!(benches);
