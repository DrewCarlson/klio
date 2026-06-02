//! Advanced closure patterns: mutual captures, scope-fn chaining
//! with `this` reassignment, lambdas stored and invoked later,
//! enclosed-by-loop iteration variables.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_closures_advanced");
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
fn lambdas_stored_and_invoked_later() {
    let src = r#"
fun main() {
    val tasks = mutableListOf<() -> String>()
    for (i in 1..3) {
        val captured = i
        tasks.add { "t$captured" }
    }
    println(tasks.joinToString(",") { it() })
}
"#;
    assert_klio("stored_lambdas", src, "t1,t2,t3\n");
}

#[test]
fn closure_chains_apply_let_run_with() {
    let src = r#"
fun main() {
    val result = StringBuilder()
        .apply { append("a") }
        .let { it.append("b") }
        .run { append("c"); toString() }
    println(result)
}
"#;
    assert_klio("scope_chain", src, "abc\n");
}

#[test]
fn closure_capturing_class_property() {
    let src = r#"
class P(val name: String) {
    fun greeter(): () -> String = { "hello $name" }
}
fun main() {
    val g = P("kotlin").greeter()
    println(g())
}
"#;
    assert_klio("capture_prop", src, "hello kotlin\n");
}

#[test]
fn nested_closures_share_outer_mutable() {
    let src = r"
fun main() {
    var counter = 0
    val incr = { counter += 1 }
    val read = { counter }
    incr(); incr(); incr()
    println(read())
}
";
    assert_klio("share_outer", src, "3\n");
}

#[test]
fn lambda_in_init_block_captures_init_local() {
    let src = r"
class Box {
    val getter: () -> Int
    init {
        val v = 42
        getter = { v }
    }
}
fun main() {
    println(Box().getter())
}
";
    assert_klio("init_lambda", src, "42\n");
}

#[test]
fn fold_with_mutating_accumulator() {
    let src = r"
fun main() {
    val r = listOf(1, 2, 3, 4, 5).fold(StringBuilder()) { acc, x ->
        acc.append(x); acc
    }
    println(r)
}
";
    assert_klio("fold_acc", src, "12345\n");
}

#[test]
fn nested_let_destructure_pair() {
    let src = r"
fun main() {
    val r = Pair(3, 4).let { (a, b) -> a * b }
    println(r)
}
";
    assert_klio("let_dest", src, "12\n");
}
