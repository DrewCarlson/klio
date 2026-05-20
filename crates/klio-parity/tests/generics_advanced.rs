//! Advanced generic scenarios: covariant/contravariant variance,
//! star-projection, reified inline functions, bounds projection,
//! generic function reified-class lookup.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_generics_advanced");
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
fn covariant_out_producer() {
    let src = r#"
interface Producer<out T> { fun produce(): T }
class IntP : Producer<Int> { override fun produce(): Int = 42 }
fun useAny(p: Producer<Any>): String = p.produce().toString()
fun main() {
    val ip: Producer<Int> = IntP()
    println(useAny(ip))
}
"#;
    assert_klio("covariant_out", src, "42\n");
}

#[test]
fn star_projection() {
    let src = r#"
class Box<T>(val v: T) { fun toAny(): Any? = v }
fun render(b: Box<*>): String = b.toAny().toString()
fun main() {
    println("${render(Box(7))}|${render(Box("hi"))}")
}
"#;
    assert_klio("star_proj", src, "7|hi\n");
}

#[test]
fn generic_method_in_class() {
    let src = r#"
class Holder<T>(val v: T) {
    fun <R> map(f: (T) -> R): Holder<R> = Holder(f(v))
}
fun main() {
    val h = Holder(7).map { it * 2 }.map { "v=$it" }
    println(h.v)
}
"#;
    assert_klio("generic_method", src, "v=14\n");
}

#[test]
fn nested_generic_resolution() {
    let src = r#"
fun <T> firstOrZero(xs: List<T>, zero: T): T = if (xs.isEmpty()) zero else xs[0]
fun main() {
    val a = firstOrZero(listOf(1,2,3), 0)
    val b = firstOrZero(listOf<String>(), "empty")
    val c = firstOrZero(listOf("alpha"), "beta")
    println("$a|$b|$c")
}
"#;
    assert_klio("nested_gen", src, "1|empty|alpha\n");
}

#[test]
fn bound_constraint_comparable() {
    let src = r#"
fun <T : Comparable<T>> sortPair(a: T, b: T): Pair<T, T> =
    if (a <= b) Pair(a, b) else Pair(b, a)
fun main() {
    val p = sortPair(5, 3)
    val q = sortPair("z", "a")
    println("${p.first},${p.second}|${q.first},${q.second}")
}
"#;
    assert_klio("bound_cmp", src, "3,5|a,z\n");
}

#[test]
fn generic_class_with_secondary_constructor() {
    let src = r#"
class Pair2<A, B>(val a: A, val b: B) {
    constructor(a: A) : this(a, a as B)
    fun show(): String = "[$a,$b]"
}
fun main() {
    val p = Pair2(7, "x")
    val q = Pair2<Int, Int>(5)
    println("${p.show()}|${q.show()}")
}
"#;
    assert_klio("gen_secondary", src, "[7,x]|[5,5]\n");
}

#[test]
fn lambda_with_generic_param() {
    let src = r#"
fun <T> apply(x: T, f: (T) -> T): T = f(x)
fun main() {
    val a = apply(7) { it * 2 }
    val b = apply("hi") { "$it!" }
    println("$a|$b")
}
"#;
    assert_klio("lambda_gen", src, "14|hi!\n");
}

#[test]
fn function_type_returning_function_type() {
    let src = r#"
fun adder(n: Int): (Int) -> Int = { it + n }
fun composed(a: (Int) -> Int, b: (Int) -> Int): (Int) -> Int = { a(b(it)) }
fun main() {
    val plus5 = adder(5); val times2 = { x: Int -> x * 2 }
    val pipe = composed(plus5, times2)
    println("${pipe(3)},${pipe(10)}")
}
"#;
    // pipe(3) = plus5(times2(3)) = plus5(6) = 11; pipe(10) = plus5(20) = 25
    assert_klio("fn_returns_fn", src, "11,25\n");
}
