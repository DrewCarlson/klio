//! Allocation-shape profile. By default this just times the workloads.
//! With `--features dhat` the binary becomes a heap-profiler run that
//! dumps a `dhat-heap.json` viewable in the DHAT web viewer.

use criterion::{criterion_group, criterion_main, Criterion};
use klio_bench::{run_full, Program};
use std::path::PathBuf;

#[cfg(feature = "dhat")]
#[global_allocator]
static ALLOC: dhat::Alloc = dhat::Alloc;

fn synth(name: &str, body: &str) -> Program {
    Program { path: PathBuf::from(format!("<synth>/{name}.kt")), source: body.to_string() }
}

fn bench_mem(c: &mut Criterion) {
    #[cfg(feature = "dhat")]
    let _p = dhat::Profiler::new_heap();

    let churn_strings = synth("churn_strings", r#"
fun main() {
    var s = ""
    var i = 0
    while (i < 2000) { s = s + "x"; i += 1 }
    println(s.length)
}"#);
    let churn_lists = synth("churn_lists", r"
fun main() {
    var xs: List<Int> = emptyList()
    var i = 0
    while (i < 500) { xs = xs + i; i += 1 }
    println(xs.size)
}");
    let boxed_arith = synth("boxed_arith", r"
fun main() {
    val xs = (1..10000).toList()
    println(xs.sum())
}");

    let mut group = c.benchmark_group("memory_profile");
    group.sample_size(15);
    for prog in [&churn_strings, &churn_lists, &boxed_arith] {
        let name = prog.path.file_stem().unwrap().to_string_lossy().into_owned();
        group.bench_function(name, |b| b.iter(|| { let _ = run_full(prog); }));
    }
    group.finish();
}

criterion_group!(benches, bench_mem);
criterion_main!(benches);
