//! Deeper inline / crossinline / reified shapes that aren't covered
//! by `inline_crossinline.rs`: member-invoked inline (non-extension),
//! inline operator fns, generic inline fns through a generic
//! receiver, reified used by another reified inline fn, inline with
//! a defaulted lambda param, and inline fn called recursively.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_inline_deep");
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

// 1. Inline MEMBER (non-extension) fn invoked as `recv.f { ... }`,
//    body uses `this` (the enclosing class instance) inside the
//    lambda body.
#[test]
fn inline_member_fn_member_invoked() {
    let src = r#"
class Box(val tag: String) {
    inline fun run2(action: (String) -> String): String = action(tag) + "/" + action(tag)
}
fun probe(b: Box, mark: String): String =
    b.run2 { t -> "$t!$mark" }
fun main() {
    println(probe(Box("X"), "m"))
}
"#;
    assert_klio("inline_member_fn", src, "X!m/X!m\n");
}

// 2. Inline operator fn: `operator inline fun A.invoke(...)` — call
//    via `a()` should splice.
#[test]
fn inline_operator_fn() {
    let src = r#"
class Counter { var n = 0 }

inline operator fun Counter.invoke(action: () -> Int): Int {
    val v = action()
    n += v
    return n
}

fun main() {
    val c = Counter()
    val r1 = c { 3 }
    val r2 = c { 5 }
    println("$r1 $r2 ${c.n}")
}
"#;
    assert_klio("inline_operator", src, "3 8 8\n");
}

// 3. Generic inline fn called as a member of a generic receiver.
#[test]
fn generic_inline_member_through_generic_receiver() {
    let src = r#"
class Wrap<T>(val v: T) {
    inline fun <R> map(f: (T) -> R): Wrap<R> = Wrap(f(v))
    override fun toString(): String = "W($v)"
}
fun main() {
    val w = Wrap(3).map { it * 10 }.map { it + 1 }
    println(w)
}
"#;
    assert_klio("generic_inline_member", src, "W(31)\n");
}

// 4. Reified used by another reified inline fn (reified plumbing
//    must propagate through nested inline calls).
#[test]
fn reified_propagated_through_inline() {
    let src = r#"
inline fun <reified T> firstIsT(xs: List<Any>): T? {
    for (x in xs) if (x is T) return x
    return null
}

inline fun <reified U> countOf(xs: List<Any>): Int =
    if (firstIsT<U>(xs) == null) 0 else xs.count { it is U }

fun main() {
    val xs = listOf(1, "a", 2, "b", 3)
    println("${countOf<Int>(xs)} ${countOf<String>(xs)}")
}
"#;
    assert_klio("reified_propagated", src, "3 2\n");
}

// 5. Inline fn with a DEFAULTED lambda param.
#[test]
fn inline_with_defaulted_lambda() {
    let src = r#"
inline fun apply3(x: Int, k: (Int) -> Int = { it + 1 }): Int = k(k(k(x)))
fun main() {
    println("${apply3(0)} ${apply3(0) { it * 2 }}")
}
"#;
    // default: ((0+1)+1)+1 = 3
    // custom: 0*2*2*2 = 0
    assert_klio("inline_defaulted_lambda", src, "3 0\n");
}

// 6. Inline fn calling itself recursively — must NOT splice
//    infinitely; runs as a normal call past the splice budget.
#[test]
fn inline_recursive_call() {
    let src = r"
inline fun sumUpTo(n: Int, acc: Int = 0): Int =
    if (n == 0) acc else sumUpTo(n - 1, acc + n)
fun main() { println(sumUpTo(10)) }
";
    assert_klio("inline_recursive_call", src, "55\n");
}

// 7. crossinline lambda invoked from inside another stored lambda.
#[test]
fn crossinline_invoked_indirectly() {
    let src = r#"
class Wrapper(val invoker: () -> String)

inline fun wrap(crossinline produce: () -> String): Wrapper =
    Wrapper({ "wrapped[" + produce() + "]" })

fun main() {
    val w1 = wrap { "A" }
    val w2 = wrap { "B" }
    println("${w1.invoker()} ${w2.invoker()}")
}
"#;
    assert_klio("crossinline_indirect", src, "wrapped[A] wrapped[B]\n");
}

// 8. Inline ext on a generic Comparable<T> with where-clause.
#[test]
fn inline_ext_on_generic_comparable() {
    let src = r#"
inline fun <T : Comparable<T>> T.between(lo: T, hi: T, body: () -> String): String =
    if (this >= lo && this <= hi) body() else "out"

fun main() {
    println("${3.between(1, 5) { "in:3" }} ${10.between(1, 5) { "in:10" }}")
}
"#;
    assert_klio("inline_ext_comparable", src, "in:3 out\n");
}

// 9. `with(receiver) { ... }` used inside an inline ext lambda
//    inside a class method, with the inner block referring back to
//    `this@Class`.
#[test]
fn with_inside_inline_ext_lambda_this_label() {
    let src = r#"
inline fun <T, R> T.let2(block: (T) -> R): R = block(this)

class Builder(val prefix: String) {
    fun assemble(parts: List<String>): String {
        val sb = StringBuilder()
        parts.let2 { ps ->
            with(sb) {
                for (p in ps) {
                    this.append(this@Builder.prefix)
                    this.append(p)
                    this.append("|")
                }
            }
        }
        return sb.toString()
    }
}

fun main() {
    println(Builder("pfx-").assemble(listOf("a", "b", "c")))
}
"#;
    assert_klio(
        "with_inside_inline_ext_this_label",
        src,
        "pfx-a|pfx-b|pfx-c|\n",
    );
}

// 10. Inline fn returning a `Pair` whose first is a captured lambda
//     (closure escape) and whose second is computed eagerly.
#[test]
fn inline_returns_pair_with_closure_capture() {
    let src = r#"
inline fun build(seed: Int, crossinline mk: (Int) -> String): Pair<(Int) -> String, Int> =
    Pair({ x -> mk(seed + x) }, seed * 10)

fun main() {
    val (fn, base) = build(7) { v -> "v$v" }
    println("$base|${fn(3)}|${fn(0)}")
}
"#;
    // base = 70 ; fn(3) -> mk(10) -> "v10" ; fn(0) -> mk(7) -> "v7"
    assert_klio("inline_returns_pair_capture", src, "70|v10|v7\n");
}
