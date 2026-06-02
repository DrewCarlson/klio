//! Advanced closure / capture / dispatch scenarios.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_closures_deep");
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

// 1. Closure of closure of var — innermost mutates, middle reads,
//    outer reads after invocation.
#[test]
fn three_level_closure_capture() {
    let src = r#"
fun main() {
    var n = 0
    val outer: () -> () -> Int = {
        { n += 1; n }
    }
    val inner = outer()
    val a = inner(); val b = inner(); val c = inner()
    println("$a,$b,$c,n=$n")
}
"#;
    assert_klio("three_level", src, "1,2,3,n=3\n");
}

// 2. Lambda referencing a captured var while loop reassigns it
//    invokes lambda each iteration — lambda observes current value.
#[test]
fn lambda_observes_var_reassignment() {
    let src = r#"
fun main() {
    var k = 0
    val read = { k }
    val sb = StringBuilder()
    for (i in 1..3) { k = i * 10; sb.append("${read()},") }
    println(sb)
}
"#;
    assert_klio("lambda_observes", src, "10,20,30,\n");
}

// 3. Closure capturing `this` of enclosing class accessed inside
//    deeply nested lambdas.
#[test]
fn this_capture_in_deep_nesting() {
    let src = r#"
class Box(val tag: String) {
    fun build(): String {
        val outer = {
            val inner = { tag + "!" }
            inner()
        }
        return outer()
    }
}
fun main() { println(Box("Hi").build()) }
"#;
    assert_klio("this_deep", src, "Hi!\n");
}

// 4. Captured destructured variable.
#[test]
fn capture_destructured() {
    let src = r#"
fun main() {
    val (a, b) = Pair(3, 4)
    val sum = { a + b }
    val product = { a * b }
    println("${sum()},${product()}")
}
"#;
    assert_klio("capture_dest", src, "7,12\n");
}

// 5. Lambda returning lambda chain, currying-style.
#[test]
fn curried_lambda_chain() {
    let src = r"
fun main() {
    val add: (Int) -> (Int) -> (Int) -> Int = { a -> { b -> { c -> a + b + c } } }
    println(add(1)(2)(3))
}
";
    assert_klio("curried", src, "6\n");
}

// 6. Mutual recursion via lambdas in val bindings using lateinit
//    val and tied-knot through enclosing variable.
#[test]
fn lambda_tied_knot_recursion() {
    let src = r#"
fun main() {
    var even: (Int) -> Boolean = { false }
    var odd: (Int) -> Boolean = { false }
    even = { n -> if (n == 0) true else odd(n - 1) }
    odd = { n -> if (n == 0) false else even(n - 1) }
    println("${even(4)},${even(7)}")
}
"#;
    assert_klio("tied_knot", src, "true,false\n");
}

// 7. Lambda parameter shadowing enclosing local of same name.
#[test]
fn lambda_param_shadows_outer() {
    let src = r#"
fun main() {
    val x = 100
    val f = { x: Int -> x * 2 }
    println("${f(5)},$x")
}
"#;
    assert_klio("shadow", src, "10,100\n");
}

// 8. Captured `it` in nested let-blocks doesn't bleed across.
#[test]
fn nested_let_it_scoping() {
    let src = r"
fun main() {
    val a = 3.let { outer ->
        4.let { inner -> outer * inner }
    }
    println(a)
}
";
    assert_klio("let_it_scoping", src, "12\n");
}

// 9. Closure passed to a coroutine — captures stay alive across
//    suspension points.
#[test]
fn closure_across_suspension() {
    let src = r#"
import kotlinx.coroutines.*
fun main() = runBlocking {
    val tag = "ok"
    val get = { tag }
    delay(5)
    println(get())
}
"#;
    assert_klio("closure_suspend", src, "ok\n");
}

// 10. Lambda capturing a primitive Int via box; reassignment is
//     observed across the boundary.
#[test]
fn primitive_box_observability() {
    let src = r"
fun main() {
    var counter = 0
    val tick: () -> Int = { counter += 1; counter }
    repeat(5) { tick() }
    println(counter)
}
";
    assert_klio("box_obs", src, "5\n");
}
