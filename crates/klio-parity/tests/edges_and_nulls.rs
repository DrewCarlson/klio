//! Null-safety, Elvis chains, safe-call sequences, Iterator/Iterable
//! interop, map merge operators, custom `iterator()` for `for`,
//! and a few realistic exception-handling shapes.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_edges_and_nulls");
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

// 1. Safe-call chain + Elvis fallback through several nullable members.
#[test]
fn safe_call_elvis_chain() {
    let src = r#"
class A(val b: B?)
class B(val c: C?)
class C(val name: String?)

fun render(a: A?): String = a?.b?.c?.name ?: "unknown"

fun main() {
    val full = A(B(C("alice")))
    val none = A(null)
    val mid  = A(B(null))
    val name = A(B(C(null)))
    println("${render(full)}|${render(none)}|${render(mid)}|${render(name)}|${render(null)}")
}
"#;
    assert_klio(
        "safe_call_elvis",
        src,
        "alice|unknown|unknown|unknown|unknown\n",
    );
}

// 2. `!!` operator throws when null.
#[test]
fn double_bang_throws_on_null() {
    let src = r#"
fun maybeNull(b: Boolean): String? = if (b) "ok" else null

fun main() {
    try {
        val s: String = maybeNull(false)!!
        println("never: $s")
    } catch (e: NullPointerException) {
        println("caught NPE")
    }
    println(maybeNull(true)!!)
}
"#;
    assert_klio("double_bang", src, "caught NPE\nok\n");
}

// 3. Custom `iterator()` operator + `for` loop drives it. Tracked
//    as task #32: a bare identifier inside an anon-object method
//    body that names an enclosing-class member is currently mis-
//    resolved to a top-level intrinsic (`kotlin.to`).
#[test]

fn custom_iterator_drives_for_loop() {
    let src = r#"
class Down(val from: Int, val to: Int) {
    operator fun iterator(): Iterator<Int> = object : Iterator<Int> {
        var cur = from
        override fun hasNext(): Boolean = cur >= to
        override fun next(): Int { val v = cur; cur--; return v }
    }
}

fun main() {
    val sb = StringBuilder()
    for (n in Down(5, 1)) sb.append("$n,")
    println(sb)
}
"#;
    assert_klio("custom_iterator", src, "5,4,3,2,1,\n");
}

// 4. `Map<K,V>` merge via `+` / `-` operators.
#[test]
fn map_plus_minus_operators() {
    let src = r#"
fun main() {
    val a = mapOf("x" to 1, "y" to 2)
    val b = mapOf("y" to 20, "z" to 30)
    val merged = a + b
    val removed = merged - "x"
    println("${merged["y"]} ${removed.size} ${removed["z"]}")
}
"#;
    assert_klio("map_plus_minus", src, "20 2 30\n");
}

// 5. Throw + catch with multi-arm handler and the cause chain.
#[test]
fn throw_catch_multi_arm() {
    let src = r#"
class Oops(message: String) : RuntimeException(message)

fun probe(n: Int): String {
    return try {
        when (n) {
            1 -> throw Oops("one")
            2 -> throw IllegalStateException("two")
            else -> "ok:$n"
        }
    } catch (e: Oops) {
        "oops:${e.message}"
    } catch (e: RuntimeException) {
        "rt:${e.message}"
    }
}

fun main() {
    println("${probe(1)}|${probe(2)}|${probe(3)}")
}
"#;
    assert_klio(
        "throw_catch_multi_arm",
        src,
        "oops:one|rt:two|ok:3\n",
    );
}

// 6. `Sequence` lazy chain (terminal operator drives evaluation).
#[test]
fn sequence_lazy_chain() {
    let src = r#"
fun main() {
    val s = generateSequence(1) { it + 1 }
        .map { it * it }
        .filter { it % 2 == 0 }
        .take(4)
        .toList()
    println(s)
}
"#;
    // squares of 1..n that are even: 4,16,36,64 (squares of 2,4,6,8)
    assert_klio("sequence_lazy_chain", src, "[4, 16, 36, 64]\n");
}

// 7. `let` / `also` / `apply` / `run` chained over a possibly-null
//    receiver.
#[test]
fn scope_functions_chain() {
    let src = r#"
class Item(val v: Int) {
    var seen: Int = 0
    override fun toString(): String = "Item($v,seen=$seen)"
}

fun pick(opt: Item?): String =
    opt?.also { it.seen++ }
       ?.run { "v=$v|s=$seen" }
       ?: "absent"

fun main() {
    println(pick(Item(5)))
    println(pick(null))
}
"#;
    assert_klio("scope_chain", src, "v=5|s=1\nabsent\n");
}

// 8. Generic `out` variance through a List read.
#[test]
fn generic_out_variance_list() {
    let src = r#"
open class Animal(val name: String)
class Dog(name: String) : Animal(name)

fun describe(xs: List<Animal>): String = xs.joinToString(",") { it.name }

fun main() {
    val dogs: List<Dog> = listOf(Dog("Rex"), Dog("Ada"))
    // List<Dog> is List<out Animal> — passes to List<Animal> param.
    println(describe(dogs))
}
"#;
    assert_klio("generic_out_variance", src, "Rex,Ada\n");
}
