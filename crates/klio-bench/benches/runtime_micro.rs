//! Synthetic runtime micros. Each program is a tight inner loop that
//! stresses one runtime concern: integer arithmetic, list churn, lambda
//! dispatch, string templating, method call.

use criterion::{criterion_group, criterion_main, Criterion};
use klio_bench::{run_full, Program};
use std::path::PathBuf;

fn synth(name: &str, body: &str) -> Program {
    Program { path: PathBuf::from(format!("<synth>/{name}.kt")), source: body.to_string() }
}

fn bench_micros(c: &mut Criterion) {
    let mut group = c.benchmark_group("runtime_micro");
    group.sample_size(20);

    let arith = synth("arith", r#"
fun main() {
    var s = 0
    var i = 0
    while (i < 100000) { s += i; i += 1 }
    println(s)
}"#);
    let lists = synth("lists", r#"
fun main() {
    val xs = (1..1000).toList()
    var s = 0
    for (x in xs.map { it * 2 }.filter { it % 3 == 0 }) s += x
    println(s)
}"#);
    let lambdas = synth("lambdas", r#"
fun main() {
    val f: (Int) -> Int = { it * it + 1 }
    var s = 0
    var i = 0
    while (i < 50000) { s += f(i); i += 1 }
    println(s)
}"#);
    let templates = synth("templates", r#"
fun main() {
    var n = 0
    var i = 0
    while (i < 5000) { val s = "$i-${i*2}"; n += s.length; i += 1 }
    println(n)
}"#);
    let dispatch = synth("dispatch", r#"
open class A { open fun hit(x: Int) = x + 1 }
class B : A() { override fun hit(x: Int) = x + 2 }
fun main() {
    val a: A = B()
    var s = 0
    var i = 0
    while (i < 50000) { s = a.hit(s); i += 1 }
    println(s)
}"#);

    for prog in [&arith, &lists, &lambdas, &templates, &dispatch] {
        let name = prog.path.file_stem().unwrap().to_string_lossy().into_owned();
        group.bench_function(name, |b| b.iter(|| { let _ = run_full(prog); }));
    }
    group.finish();
}

criterion_group!(benches, bench_micros);
criterion_main!(benches);
