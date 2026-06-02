use criterion::{BenchmarkId, Criterion, criterion_group, criterion_main};
use klio_lexer::Lexer;
use klio_parser::Parser;
use klio_resolver::resolve;
use klio_span::SourceMap;
use std::path::{Path, PathBuf};

fn corpus_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("klio-bench")
        .join("corpus")
}

fn walk(p: &Path, out: &mut Vec<(String, String)>) {
    if p.is_dir() {
        for e in std::fs::read_dir(p).unwrap().flatten() {
            walk(&e.path(), out);
        }
    } else if p.extension().is_some_and(|e| e == "kt") {
        let name = p.file_stem().unwrap().to_string_lossy().into_owned();
        let src = std::fs::read_to_string(p).unwrap();
        out.push((name, src));
    }
}

fn programs() -> Vec<(String, String)> {
    let mut out = Vec::new();
    walk(&corpus_root(), &mut out);
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

fn bench_resolve(c: &mut Criterion) {
    let mut group = c.benchmark_group("resolve");
    group.sample_size(30);
    for (name, src) in programs() {
        let mut map = SourceMap::new();
        let id = map.add(Path::new("<bench>"), src.clone());
        let lexed = Lexer::new(id, &src).tokenize();
        let (ast, _) = Parser::new(id, &src, &lexed.tokens).parse_file();
        group.bench_with_input(BenchmarkId::from_parameter(&name), &ast, |b, ast| {
            b.iter(|| {
                let _ = resolve(ast);
            });
        });
    }
    group.finish();
}

criterion_group!(benches, bench_resolve);
criterion_main!(benches);
