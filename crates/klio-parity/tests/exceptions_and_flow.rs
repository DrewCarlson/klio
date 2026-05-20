//! Exception handling, finally semantics, multi-catch, rethrow,
//! try-as-expression, and exception inside lambda capture.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_exceptions_and_flow");
    std::fs::create_dir_all(&dir).expect("mkdir");
    let file = dir.join(format!("{name}.kt"));
    let mut f = std::fs::File::create(&file).expect("create kt");
    f.write_all(src.as_bytes()).expect("write");
    file
}

fn assert_klio(name: &str, src: &str, expected: &str) {
    let file = write_src(name, src);
    let got = klio_parity::run_with_packs(&file)
        .unwrap_or_else(|e| panic!("klio run failed for `{name}`: {e}"));
    assert_eq!(got, expected, "klio output for `{name}` did not match");
}

#[test]
fn try_finally_runs_on_normal_path() {
    let src = r#"
fun main() {
    val sb = StringBuilder()
    try { sb.append("body;") } finally { sb.append("fin;") }
    println(sb)
}
"#;
    assert_klio("try_fin_normal", src, "body;fin;\n");
}

#[test]
fn try_finally_runs_on_exception() {
    let src = r#"
fun main() {
    val sb = StringBuilder()
    try {
        try { throw RuntimeException("e"); sb.append("nope;") }
        finally { sb.append("fin;") }
    } catch (e: RuntimeException) { sb.append("caught:${e.message};") }
    println(sb)
}
"#;
    assert_klio("try_fin_throw", src, "fin;caught:e;\n");
}

#[test]
fn rethrow_in_catch_propagates() {
    let src = r#"
class A : RuntimeException("a")
class B : RuntimeException("b")
fun probe() {
    try { throw A() } catch (e: A) { throw B() }
}
fun main() {
    try { probe() } catch (e: B) { println("got B:${e.message}") }
}
"#;
    assert_klio("rethrow", src, "got B:b\n");
}

#[test]
fn try_as_expression_yields_value() {
    let src = r#"
fun parse(s: String): Int = try { s.toInt() } catch (e: NumberFormatException) { -1 }
fun main() {
    println("${parse("42")},${parse("nope")}")
}
"#;
    assert_klio("try_expr", src, "42,-1\n");
}

#[test]
fn exception_through_lambda_boundary() {
    let src = r#"
fun runWith(f: () -> Int): Int {
    return try { f() } catch (e: IllegalStateException) { -1 }
}
fun main() {
    val r = runWith { throw IllegalStateException("bad") }
    println(r)
}
"#;
    assert_klio("ex_lambda", src, "-1\n");
}

#[test]
fn nested_try_inner_catches_outer_doesnt() {
    let src = r#"
fun main() {
    val sb = StringBuilder()
    try {
        try { throw RuntimeException("e1") }
        catch (e: RuntimeException) { sb.append("inner:${e.message};") }
    } catch (e: RuntimeException) { sb.append("outer:${e.message};") }
    println(sb)
}
"#;
    assert_klio("nested_try", src, "inner:e1;\n");
}

#[test]
#[ignore = "tracked as task #42"]
fn finally_overrides_value_if_returns() {
    let src = r#"
fun f(): Int {
    try { return 1 } finally { return 2 }
}
fun main() { println(f()) }
"#;
    assert_klio("fin_override", src, "2\n");
}

#[test]
fn catch_hierarchy_first_match_wins() {
    let src = r#"
fun probe(): String = try {
    throw IllegalStateException("x")
} catch (e: IllegalArgumentException) { "arg" }
  catch (e: IllegalStateException) { "state" }
  catch (e: RuntimeException) { "runtime" }
fun main() { println(probe()) }
"#;
    assert_klio("catch_hierarchy", src, "state\n");
}

#[test]
fn exception_inside_init_block_propagates() {
    let src = r#"
class Bad(v: Int) {
    init { if (v < 0) throw IllegalArgumentException("neg") }
}
fun main() {
    try { Bad(-1) } catch (e: IllegalArgumentException) { println("caught:${e.message}") }
}
"#;
    assert_klio("ex_in_init", src, "caught:neg\n");
}

#[test]
fn check_require_helpers() {
    let src = r#"
fun safeDiv(a: Int, b: Int): Int {
    require(b != 0) { "divide by zero" }
    return a / b
}
fun main() {
    try { safeDiv(6, 0) } catch (e: IllegalArgumentException) { println(e.message) }
    println(safeDiv(10, 2))
}
"#;
    assert_klio("require", src, "divide by zero\n5\n");
}
