//! Complex name-resolution parity. Each test is a self-contained
//! Kotlin program that exercises realistic resolution patterns —
//! lambdas inside lambdas, enclosing-`this`, inherited members,
//! inline extension non-local returns, sibling-branch capture
//! reads, smart-casts, companions, inner classes, overload picks.
//! Programs print a deterministic short string; klio's stdout is
//! asserted against a literal so the test runs in kotlinc-less
//! environments too. When `kotlinc` is available the suite also
//! asserts byte-identity through `klio_parity::check`.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_complex_resolution");
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
    // If kotlinc is available, also check byte-identity.
    if let Ok(report) = klio_parity::check(&file) {
        assert!(
            report.matched,
            "kotlinc parity mismatch for `{name}`\n{}",
            klio_parity::render_diff(&report)
        );
    }
}

// 1. The capture-CSE regression: a closure captures an enclosing-fn
//    param and reads it across SIBLING branches. Before the fix the
//    sibling read got the uninitialized `Unit`.
#[test]
fn capture_read_across_sibling_branches() {
    let src = r#"
fun runner(act: (Int) -> Unit) { var i = 0; while (i < 3) { act(i); i++ } }

fun probe(label: String, choose: Int): String {
    var out = ""
    runner { n ->
        when (n) {
            0 -> { if (choose == 0) out += "a:$label;" else out += "x:$label;" }
            1 -> { if (choose == 1) out += "b:$label;" else out += "y:$label;" }
            else -> { out += "z:$label;" }
        }
    }
    return out
}

fun main() {
    println(probe("L", 1))
}
"#;
    // n=0 choose!=0 -> "x:L;" ; n=1 choose==1 -> "b:L;" ; n=2 -> "z:L;"
    assert_klio("capture_sibling_branches", src, "x:L;b:L;z:L;\n");
}

// 2. Nested lambdas, `this@Outer`, member ext property, inherited
//    member call — all in one body.
#[test]
fn nested_lambdas_this_label_and_inherited_member() {
    let src = r#"
open class Base {
    fun greet(n: Int): String = "hi=$n"
}
class Holder(val tag: String) : Base() {
    private fun own(x: Int): String = "own$x"
    private val Int.boxed: String get() = "[${own(this)}+${greet(this)}]"
    fun build(): String {
        // outer lambda receiver = Holder ; inner = the Int receiver
        val sb = StringBuilder()
        listOf(1, 2).forEach { i ->
            // forEach lambda body captures `this@Holder.tag`, calls
            // member ext property `i.boxed` on enclosing receiver.
            with(i) { sb.append("$tag:" + this.boxed + ";") }
        }
        return sb.toString()
    }
}
fun main() { println(Holder("H").build()) }
"#;
    // i=1: [own1+hi=1] ; i=2: [own2+hi=2]
    assert_klio(
        "nested_lambdas_this_label",
        src,
        "H:[own1+hi=1];H:[own2+hi=2];\n",
    );
}

// 3. Inline ext fn with non-local return, lambda captures an
//    enclosing-fn param. (kotlinx-coroutines `_state.loop { ... }`
//    shape; the capture-CSE fix is what makes the captured `tag`
//    survive across the `when` branches.)
#[test]
fn inline_ext_nonlocal_return_with_capture() {
    let src = r#"
class Box(var value: Any?)

inline fun Box.spin(action: (Any?) -> Unit): Nothing {
    while (true) { action(value) }
}

fun install(tag: String): String {
    val state = Box("active")
    state.spin { s ->
        when (s) {
            "active" -> { state.value = "claimed:$tag"; return tag + ":ok" }
            else -> { return tag + ":late" }
        }
    }
}
fun main() { println(install("T")) }
"#;
    assert_klio("inline_ext_nonlocal_return_capture", src, "T:ok\n");
}

// 4. Subclass member resolution: bare call from a method, from an
//    init block, from a lambda inside a method, all reaching a
//    private inherited helper via implicit `this`.
#[test]
fn subclass_resolution_init_method_lambda() {
    let src = r#"
open class Base {
    protected fun bump(n: Int): Int = n + 10
}
class Sub(start: Int) : Base() {
    private var acc: Int = 0
    init { acc = bump(start) }                            // bare in init
    fun viaMethod(x: Int): Int = bump(x) + acc            // bare in method
    fun viaLambda(xs: List<Int>): Int {
        var total = 0
        xs.forEach { total += bump(it) }                  // bare in lambda
        return total
    }
}
fun main() {
    val s = Sub(3)
    println("${s.viaMethod(2)} ${s.viaLambda(listOf(1, 2, 3))}")
}
"#;
    // init: acc = 13 ; viaMethod(2) = 12 + 13 = 25 ; viaLambda = (11+12+13) = 36
    assert_klio("subclass_init_method_lambda", src, "25 36\n");
}

// 5. Overload resolution: a same-named member vs extension vs
//    top-level, picked by receiver type.
#[test]
fn overload_member_vs_extension_vs_toplevel() {
    let src = r#"
open class A { open fun tag(): String = "A.member" }
class B : A() { override fun tag(): String = "B.member" }

fun A.tag(): String = "A.ext" // shadowed by member when receiver is A or subtype

fun describe(a: A): String = a.tag()

fun main() {
    println("${describe(A())} ${describe(B())}")
}
"#;
    // Kotlin: a member of the receiver outranks a same-named ext on the
    // same type — both calls go to the member.
    assert_klio(
        "overload_member_vs_extension",
        src,
        "A.member B.member\n",
    );
}

// 6. Companion object member referenced bare from a class method
//    (no `Outer.` qualifier).
#[test]
fn companion_member_bare_from_method() {
    let src = r#"
class Counter private constructor(val n: Int) {
    companion object {
        fun mk(n: Int): Counter = Counter(n)
        const val OFFSET = 100
    }
    fun render(): String = "n=${n + OFFSET}"
}
fun main() {
    println(Counter.mk(7).render())
}
"#;
    assert_klio("companion_member_bare", src, "n=107\n");
}

// 7. Inner (non-static) class accessing outer's private member.
#[test]
fn inner_class_outer_private_access() {
    let src = r#"
class Outer(private val seed: Int) {
    private fun salt(): Int = seed * 2
    inner class Inner {
        fun describe(): String = "seed=$seed salt=${salt()}"
    }
}
fun main() {
    println(Outer(5).Inner().describe())
}
"#;
    assert_klio("inner_outer_private", src, "seed=5 salt=10\n");
}

// 8. Smart cast across `when` arms with shared captured state.
#[test]
fn smart_cast_across_when_arms_with_capture() {
    let src = r#"
sealed class S { class A(val a: Int) : S(); class B(val b: String) : S(); object Z : S() }

fun render(s: S, tag: String): String =
    when (s) {
        is S.A -> "A($tag,${s.a})"
        is S.B -> "B($tag,${s.b})"
        S.Z -> "Z($tag)"
    }

fun main() {
    println("${render(S.A(7), "x")}|${render(S.B("k"), "y")}|${render(S.Z, "z")}")
}
"#;
    assert_klio(
        "smart_cast_when_arms_capture",
        src,
        "A(x,7)|B(y,k)|Z(z)\n",
    );
}

#[test]
fn comparable_user_type_sorted_and_min_max() {
    let src = r#"
class Coord(val x: Int, val y: Int) : Comparable<Coord> {
    override fun compareTo(other: Coord): Int =
        if (x != other.x) x - other.x else y - other.y
    override fun toString(): String = "($x,$y)"
}
fun main() {
    val cs = listOf(Coord(3,1), Coord(1,2), Coord(3,0), Coord(2,5)).sorted()
    println(cs.joinToString(","))
    println(cs.min())
    println(cs.max())
}
"#;
    assert_klio("comparable_sort", src,
        "(1,2),(2,5),(3,0),(3,1)\n(1,2)\n(3,1)\n");
}

#[test]
fn join_to_string_invokes_user_to_string_on_elements() {
    let src = r#"
class Tag(val v: Int) {
    override fun toString(): String = "<$v>"
}
fun main() {
    val xs = listOf(Tag(1), Tag(2), Tag(3))
    println(xs.joinToString(","))
    println(xs.joinToString("|"))
}
"#;
    assert_klio("join_user_tostring", src, "<1>,<2>,<3>\n<1>|<2>|<3>\n");
}

#[test]
fn set_first_last_join_to_string() {
    let src = r#"
fun main() {
    val s = setOf("a", "b", "c")
    println(s.first())
    println(s.last())
    println(s.joinToString("|"))
}
"#;
    assert_klio("set_first_last_join", src, "a\nc\na|b|c\n");
}

#[test]
fn primary_ctor_default_uses_empty_collection_factory() {
    let src = r#"
class Pipeline<T>(private val steps: MutableList<(T) -> T> = mutableListOf()) {
    fun then(f: (T) -> T): Pipeline<T> { steps.add(f); return this }
    fun apply(x: T): T = steps.fold(x) { acc, f -> f(acc) }
}
fun main() {
    val p = Pipeline<Int>()
        .then { it * 2 }
        .then { it + 1 }
        .then { it * 10 }
    println(p.apply(5))
}
"#;
    assert_klio("primary_default_factory", src, "110\n");
}
