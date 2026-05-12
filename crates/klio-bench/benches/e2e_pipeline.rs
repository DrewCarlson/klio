//! End-to-end pipeline criterion bench across the bench corpus.

use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion};
use klio_bench::{collect_kt, corpus_root, run_full, Program};

fn bench_e2e(c: &mut Criterion) {
    let mut group = c.benchmark_group("e2e");
    group.sample_size(20);
    for path in collect_kt(&corpus_root()) {
        let Ok(prog) = Program::load(path.clone()) else { continue };
        let label = prog.label();
        group.bench_with_input(BenchmarkId::from_parameter(&label), &prog, |b, p| {
            b.iter(|| {
                let _ = run_full(p);
            });
        });
    }
    group.finish();
}

criterion_group!(benches, bench_e2e);
criterion_main!(benches);
