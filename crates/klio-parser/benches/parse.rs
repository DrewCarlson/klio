use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};
use klio_lexer::Lexer;
use klio_parser::Parser;
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

fn bench_parse(c: &mut Criterion) {
    let mut group = c.benchmark_group("parse");
    group.sample_size(30);
    for (name, src) in programs() {
        // Pre-lex once per workload to isolate parse cost; clone tokens per iter.
        let mut map = SourceMap::new();
        let id = map.add(Path::new("<bench>"), src.clone());
        let lexed = Lexer::new(id, &src).tokenize();
        group.throughput(Throughput::Bytes(src.len() as u64));
        group.bench_with_input(
            BenchmarkId::from_parameter(&name),
            &(src.clone(), lexed.tokens, id),
            |b, (s, toks, id)| {
                b.iter(|| {
                    let _ = Parser::new(*id, s, toks).parse_file();
                });
            },
        );
    }
    group.finish();
}

criterion_group!(benches, bench_parse);
criterion_main!(benches);
