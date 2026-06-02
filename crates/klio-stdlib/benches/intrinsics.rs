//! Stdlib intrinsic micros. Each program is shaped as a hot loop around
//! one intrinsic family so the dominant cost in the measurement is that
//! family.

use criterion::{criterion_group, criterion_main, Criterion};
use klio_interp_ir::{build::build_module, Vm};
use klio_lexer::Lexer;
use klio_parser::Parser;
use klio_span::SourceMap;
use std::path::Path;

#[derive(Default)]
struct CaptureOutput;
impl klio_runtime::Output for CaptureOutput {
    fn write(&mut self, _: &str) {}
    fn writeln(&mut self, _: &str) {}
}

fn run(src: &str) {
    let mut map = SourceMap::new();
    let id = map.add(Path::new("<bench>"), src.to_string());
    let lexed = Lexer::new(id, src).tokenize();
    let (ast, _) = Parser::new(id, src, &lexed.tokens).parse_file();
    let built = build_module(&ast);
    let Some(main_id) = built.main else {
        return;
    };
    let (mut vm, _main) = Vm::from_built(built);
    let mut out = CaptureOutput;
    let _ = vm.run(main_id, &mut out);
}

fn bench(c: &mut Criterion, name: &str, body: &str) {
    c.bench_function(name, |b| b.iter(|| run(body)));
}

fn bench_intrinsics(c: &mut Criterion) {
    bench(c, "stdlib_map_filter_fold", r"
fun main() {
    val xs = (1..1000).toList()
    val r = xs.map { it * 2 }.filter { it % 3 == 0 }.fold(0) { acc, x -> acc + x }
    println(r)
}");
    bench(c, "stdlib_string_format", r#"
fun main() {
    var n = 0
    var i = 0
    while (i < 1000) { n += "%05d".format(i).length; i += 1 }
    println(n)
}"#);
    bench(c, "stdlib_stringbuilder", r"
fun main() {
    val sb = StringBuilder()
    var i = 0
    while (i < 2000) { sb.append(i); sb.append(','); i += 1 }
    println(sb.length)
}");
    bench(c, "stdlib_regex_match", r#"
fun main() {
    val r = Regex("\\d+")
    val s = "a1b22c333d4444"
    var n = 0
    var i = 0
    while (i < 500) { n += r.findAll(s).count(); i += 1 }
    println(n)
}"#);
    bench(c, "stdlib_list_grow", r"
fun main() {
    val xs = mutableListOf<Int>()
    var i = 0
    while (i < 5000) { xs.add(i); i += 1 }
    println(xs.size)
}");
}

criterion_group!(benches, bench_intrinsics);
criterion_main!(benches);
