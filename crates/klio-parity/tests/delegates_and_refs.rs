//! Parity coverage for property delegation, function references,
//! data-class destructuring, default-parameter expressions, and
//! receiver-typed function types — realistic shapes that surface
//! resolution / capture / dispatch gaps.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_delegates_and_refs");
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

// 1. `by lazy { ... }` capturing an enclosing-fn local. Tracked as
//    a separate gap (task #30: local property delegation) — class
//    property delegation works (see `custom_property_delegate`); only
//    LOCAL `val x by D` mis-lowers (binds `x` to Unit instead of
//    routing reads through `getValue`).
#[test]

fn by_lazy_captures_enclosing_local() {
    let src = r#"
fun build(seed: Int): String {
    val expensive: String by lazy { "computed:${seed * 2}" }
    return expensive + "|" + expensive  // initialiser runs once
}
fun main() { println(build(7)) }
"#;
    assert_klio("by_lazy_capture", src, "computed:14|computed:14\n");
}

// 2. Custom property delegate (getValue/setValue).
#[test]
fn custom_property_delegate() {
    let src = r#"
import kotlin.reflect.KProperty

class Counter {
    private var n = 0
    operator fun getValue(thisRef: Any?, p: KProperty<*>): Int { n++; return n }
    operator fun setValue(thisRef: Any?, p: KProperty<*>, v: Int) { n = v }
}

class Holder {
    var x: Int by Counter()
}

fun main() {
    val h = Holder()
    val a = h.x
    val b = h.x
    h.x = 100
    val c = h.x
    println("$a $b $c")
}
"#;
    // a=1, b=2, after set x=100 -> getValue returns 101 (n becomes 101 from 100++... actually our getter increments BEFORE return: n++ then return n).
    // Sequence: a: n=0->1 return 1. b: n=1->2 return 2. set: n=100. c: n=100->101 return 101.
    assert_klio("custom_property_delegate", src, "1 2 101\n");
}

// 3. Data class destructuring in for-loop with a lambda over it.
#[test]
fn data_destructuring_in_for_lambda() {
    let src = r#"
data class P(val a: Int, val b: String)

fun main() {
    val xs = listOf(P(1, "x"), P(2, "y"), P(3, "z"))
    val out = StringBuilder()
    for ((i, s) in xs) {
        // Lambda captures `out` and the destructured `i`/`s`.
        run { out.append("$i=$s,") }
    }
    println(out)
}
"#;
    assert_klio("data_destructuring_for", src, "1=x,2=y,3=z,\n");
}

// 4. Default param expression referring to a prior param and an
//    enclosing-class member.
#[test]
fn default_param_refers_prior_and_member() {
    let src = r#"
class Mixer(val base: Int) {
    fun mix(a: Int, b: Int = a * 2, c: Int = base + b): Int = a + b + c
}
fun main() {
    val m = Mixer(10)
    println("${m.mix(3)} ${m.mix(3, 5)} ${m.mix(1, 2, 3)}")
}
"#;
    // m.mix(3): a=3, b=6, c=10+6=16, sum=25
    // m.mix(3,5): a=3, b=5, c=10+5=15, sum=23
    // m.mix(1,2,3): a+b+c=6
    assert_klio("default_param_chained", src, "25 23 6\n");
}

// 5. Top-level function reference and instance method reference,
//    both invoked and stored.
#[test]
fn function_references_top_and_instance() {
    let src = r#"
fun adder(x: Int): Int = x + 10
class Mul(val k: Int) { fun apply(x: Int): Int = x * k }

fun apply2(x: Int, f: (Int) -> Int): Int = f(f(x))

fun main() {
    val r1 = apply2(3, ::adder)         // (3+10+10) = 23
    val mul = Mul(4)
    val r2 = apply2(2, mul::apply)      // (2*4)*4 = 32
    println("$r1 $r2")
}
"#;
    assert_klio("function_references", src, "23 32\n");
}

// 6. Function type with receiver (T.() -> R) — invoked via dot
//    on a value, NOT explicit `.invoke`.
#[test]
fn receiver_function_type_dot_invoke() {
    let src = r#"
fun build(label: String, builder: StringBuilder.() -> Unit): String {
    val sb = StringBuilder()
    sb.append(label); sb.append(":")
    sb.builder()
    return sb.toString()
}
fun main() {
    val s = build("L") { append("A"); append("B") }
    println(s)
}
"#;
    assert_klio("receiver_function_type", src, "L:AB\n");
}

// 7. Anonymous object expression overriding a method, capturing the
//    enclosing-fn local.
#[test]
fn anon_object_overrides_and_captures() {
    let src = r#"
interface Greeter { fun greet(who: String): String }

fun mk(prefix: String): Greeter = object : Greeter {
    override fun greet(who: String): String = "$prefix:$who"
}
fun main() {
    val g = mk("hi")
    println(g.greet("Ann"))
}
"#;
    assert_klio("anon_object_capture", src, "hi:Ann\n");
}

// 8. Operator overloading + a lambda invoked via implicit invoke.
#[test]
fn operator_overload_and_invoke() {
    let src = r#"
class Vec(val x: Int, val y: Int) {
    operator fun plus(o: Vec) = Vec(x + o.x, y + o.y)
    operator fun invoke(): String = "($x,$y)"
}
fun main() {
    val a = Vec(1, 2)
    val b = Vec(3, 4)
    val c = a + b
    println(c())
}
"#;
    assert_klio("operator_overload_invoke", src, "(4,6)\n");
}

// 9. Sealed when with bound subject + smart cast in each arm.
#[test]
fn sealed_when_bound_subject() {
    let src = r#"
sealed class N { class L(val n: Int) : N(); class S(val s: String) : N() }

fun render(items: List<N>): String {
    val sb = StringBuilder()
    for (it in items) {
        val tag = when (val v = it) {
            is N.L -> "L${v.n}"
            is N.S -> "S${v.s.length}"
        }
        sb.append(tag); sb.append(",")
    }
    return sb.toString()
}
fun main() {
    println(render(listOf(N.L(7), N.S("kotlin"), N.L(0))))
}
"#;
    assert_klio("sealed_when_bound", src, "L7,S6,L0,\n");
}

// 10. Chained scope functions with mixed receivers and the original
//     `this@Class` reaching through.
#[test]
fn chained_scope_functions_this_label() {
    let src = r#"
class Bag(val tag: String) {
    private val items = mutableListOf<String>()
    fun add(s: String): Bag = apply { items.add("[" + this@Bag.tag + "]" + s) }
    override fun toString(): String = items.joinToString(";")
}

fun main() {
    val b = Bag("B").add("a").add("b").add("c")
    println(b)
}
"#;
    assert_klio("chained_scope_this_label", src, "[B]a;[B]b;[B]c\n");
}
