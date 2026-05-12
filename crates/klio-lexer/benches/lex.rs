use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use klio_lexer::Lexer;
use klio_span::SourceMap;
use std::path::PathBuf;

fn corpus_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("klio-bench")
        .join("corpus")
}

fn programs() -> Vec<(String, String)> {
    let mut out = Vec::new();
    fn walk(p: &std::path::Path, out: &mut Vec<(String, String)>) {
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
    walk(&corpus_root(), &mut out);
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

fn bench_lex(c: &mut Criterion) {
    let mut group = c.benchmark_group("lex");
    group.sample_size(30);
    for (name, src) in programs() {
        group.throughput(Throughput::Bytes(src.len() as u64));
        group.bench_with_input(BenchmarkId::from_parameter(&name), &src, |b, s| {
            b.iter(|| {
                let mut map = SourceMap::new();
                let id = map.add(std::path::Path::new("<bench>"), s.clone());
                let _ = Lexer::new(id, s).tokenize();
            });
        });
    }
    group.finish();
}

criterion_group!(benches, bench_lex);
criterion_main!(benches);
