//! More realistic parity coverage: generics with `where` clauses,
//! `vararg` + spread, lambda parameter destructuring, sealed
//! interfaces, value classes, `typealias`, anonymous-function
//! expression bodies, ranges + downTo + step, `for` with
//! destructuring, recursive locals, higher-order chains.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_generics_and_more");
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
    if let Ok(report) = klio_parity::check(&file) {
        assert!(
            report.matched,
            "kotlinc parity mismatch for `{name}`\n{}",
            klio_parity::render_diff(&report)
        );
    }
}

// 1. Generic fn with `where` clauses + Comparable.
#[test]
fn generic_with_where_clause() {
    let src = r#"
fun <T> maxBoth(a: T, b: T): T where T : Comparable<T>, T : Any =
    if (a >= b) a else b

fun main() {
    println("${maxBoth(3, 7)} ${maxBoth("alpha", "beta")}")
}
"#;
    assert_klio("generic_where_clause", src, "7 beta\n");
}

// 2. `vararg` + spread of an existing array.
#[test]
fn vararg_and_spread() {
    let src = r#"
fun sumOf(vararg xs: Int): Int { var s = 0; for (x in xs) s += x; return s }
fun main() {
    val arr = intArrayOf(10, 20, 30)
    println("${sumOf(1, 2, 3)} ${sumOf(*arr)} ${sumOf(*arr, 100)}")
}
"#;
    assert_klio("vararg_and_spread", src, "6 60 160\n");
}

// 3. Lambda parameter destructuring `{ (a, b) -> ... }`.
#[test]
fn lambda_param_destructuring() {
    let src = r#"
fun main() {
    val pairs = listOf(Pair(1, "x"), Pair(2, "y"), Pair(3, "z"))
    val s = pairs.joinToString("|") { (k, v) -> "$k=$v" }
    println(s)
}
"#;
    assert_klio("lambda_param_destructuring", src, "1=x|2=y|3=z\n");
}

// 4. Sealed interface with diverse impls; `when` expression
//    branches return values.
#[test]
fn sealed_interface_when_expression() {
    let src = r#"
sealed interface Shape {
    class Circle(val r: Int) : Shape
    class Square(val s: Int) : Shape
    object Dot : Shape
}

fun area(x: Shape): Int = when (x) {
    is Shape.Circle -> x.r * x.r * 3
    is Shape.Square -> x.s * x.s
    Shape.Dot -> 0
}

fun main() {
    println("${area(Shape.Circle(2))} ${area(Shape.Square(3))} ${area(Shape.Dot)}")
}
"#;
    assert_klio("sealed_interface_when", src, "12 9 0\n");
}

// 5. Value class (inline class) — boxed/unboxed across a fn boundary.
#[test]
fn value_class_roundtrip() {
    let src = r#"
@JvmInline
value class Cents(val v: Int) {
    fun dollars(): String = "$${v / 100}.${(v % 100).toString().padStart(2, '0')}"
}

fun format(c: Cents): String = c.dollars()

fun main() {
    val price = Cents(1234)
    println(format(price))
}
"#;
    assert_klio("value_class_roundtrip", src, "$12.34\n");
}

// 6. `typealias` resolved at call site.
#[test]
fn typealias_resolution() {
    let src = r#"
typealias IntPair = Pair<Int, Int>
typealias IntFn = (Int) -> Int

fun apply2(p: IntPair, f: IntFn): String = "${f(p.first)},${f(p.second)}"

fun main() {
    println(apply2(IntPair(3, 4)) { it * 10 })
}
"#;
    assert_klio("typealias_resolution", src, "30,40\n");
}

// 7. Anonymous function as the trailing argument (NOT a lambda):
//    can use `return` without a label for local return. Tracked as
//    task #31 (parser feature).
#[test]

fn anonymous_function_local_return() {
    let src = r#"
fun pickFirstEven(xs: List<Int>): Int? {
    return xs.firstOrNull(fun(n): Boolean {
        if (n < 0) return false
        return n % 2 == 0
    })
}
fun main() {
    println(pickFirstEven(listOf(1, 3, 4, 5, 6)))
}
"#;
    assert_klio("anonymous_fn_local_return", src, "4\n");
}

// 8. Ranges: `..`, `downTo`, `step`.
#[test]
fn ranges_downto_step() {
    let src = r#"
fun main() {
    val sb = StringBuilder()
    for (i in 1..5) sb.append(i)
    sb.append("|")
    for (i in 10 downTo 0 step 3) sb.append("$i,")
    println(sb)
}
"#;
    assert_klio("ranges_downto_step", src, "12345|10,7,4,1,\n");
}

// 9. `for` with destructuring over a `mapOf` entries view.
#[test]
fn for_destructuring_map_entries() {
    let src = r#"
fun main() {
    val m = mapOf("a" to 1, "b" to 2, "c" to 3)
    val sb = StringBuilder()
    for ((k, v) in m) { sb.append("$k=$v;") }
    println(sb)
}
"#;
    // mapOf preserves insertion order
    assert_klio("for_destructuring_map", src, "a=1;b=2;c=3;\n");
}

// 10. Recursive local function (mutual recursion via a forward
//     declaration / lateinit lambda).
#[test]
fn mutually_recursive_locals() {
    let src = r#"
fun parity(n: Int): String {
    fun isEven(k: Int): Boolean = if (k == 0) true else isOdd(k - 1)
    fun isOdd(k: Int): Boolean  = if (k == 0) false else isEven(k - 1)
    return if (isEven(n)) "even" else "odd"
}
fun main() { println("${parity(4)} ${parity(7)}") }
"#;
    assert_klio("mutually_recursive_locals", src, "even odd\n");
}

// 11. Higher-order chain: filter -> map -> reduce.
#[test]
fn filter_map_reduce_chain() {
    let src = r#"
fun main() {
    val n = (1..10).filter { it % 2 == 1 }.map { it * it }.reduce { a, b -> a + b }
    println(n)
}
"#;
    // 1+9+25+49+81 = 165
    assert_klio("filter_map_reduce", src, "165\n");
}

// 12. `const val` at top level + in a companion + class-level.
#[test]
fn const_val_resolution() {
    let src = r#"
const val TOP = 100
class Cfg {
    companion object { const val BUMP = 7 }
    fun render(x: Int): String = "$TOP+$BUMP+$x=${TOP + BUMP + x}"
}
fun main() { println(Cfg().render(3)) }
"#;
    assert_klio("const_val_resolution", src, "100+7+3=110\n");
}
