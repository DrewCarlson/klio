//! Parity coverage for inline / crossinline / noinline / reified
//! plus the kotlinx-coroutines-style nested inline patterns that
//! previously broke (member-invoked inline extensions, multiple
//! inline frames live, captures across non-local returns, etc.).
//! Programs print a deterministic short string; klio's stdout is
//! asserted against a literal so the suite runs without kotlinc.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_inline_crossinline");
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

// 1. Inline fn with a non-local `return` from the lambda exits the
//    *caller*, not the lambda.
#[test]
fn inline_nonlocal_return_targets_caller() {
    let src = r#"
inline fun forEachUntil(xs: List<Int>, stop: Int, action: (Int) -> Unit): Int {
    var seen = 0
    for (x in xs) {
        if (x == stop) return seen
        action(x); seen++
    }
    return -1
}

fun probe(xs: List<Int>, stop: Int): String {
    val out = StringBuilder()
    val n = forEachUntil(xs, stop) { out.append("$it,"); if (it == 99) return "early" }
    return "$out|n=$n"
}

fun main() { println(probe(listOf(1, 2, 3, 4), 3)) }
"#;
    // Loop visits 1,2 then sees stop=3 -> returns seen=2 from inline fn
    // (NOT from probe).
    assert_klio("inline_nonlocal_return", src, "1,2,|n=2\n");
}

// 2. `crossinline` forbids non-local return; the lambda is callable
//    from a non-inline context.
#[test]
fn crossinline_lambda_storable() {
    let src = r#"
class Hub {
    private val handlers = mutableListOf<() -> String>()
    inline fun register(crossinline make: () -> String) {
        handlers.add({ "wrap[" + make() + "]" })
    }
    fun fire(): String = handlers.joinToString("|") { it() }
}

fun main() {
    val h = Hub()
    h.register { "A" }
    h.register { "B" + "!" }
    println(h.fire())
}
"#;
    assert_klio("crossinline_storable", src, "wrap[A]|wrap[B!]\n");
}

// 3. `noinline` keeps a lambda as an ordinary closure (storable).
#[test]
fn noinline_storable() {
    let src = r"
fun later(): MutableList<() -> Int> = mutableListOf()

inline fun setup(noinline produce: () -> Int, eager: () -> Int): Int {
    val box = later()
    box.add(produce)         // storable because noinline
    return eager() + box[0]()
}

fun main() {
    val r = setup({ 7 }, { 5 })
    println(r)
}
";
    assert_klio("noinline_storable", src, "12\n");
}

// 4. Reified type parameter: runtime `is T` and `T::class.simpleName`.
#[test]
fn reified_is_and_class() {
    let src = r#"
inline fun <reified T> describe(x: Any): String =
    if (x is T) "yes:" + T::class.simpleName else "no:" + T::class.simpleName

class Apple
class Pear

fun main() {
    val a: Any = Apple()
    val p: Any = Pear()
    println(describe<Apple>(a) + "|" + describe<Apple>(p))
}
"#;
    assert_klio("reified_is_class", src, "yes:Apple|no:Apple\n");
}

// 5. Member-invoked inline extension with non-local return AND the
//    lambda captures an enclosing-fn param. The capture must
//    survive across the `when`-arm branches (capture-CSE regression
//    + member-invoked inline-ext shape from kotlinx-coroutines).
#[test]
fn member_invoked_inline_ext_capture_across_branches() {
    let src = r#"
class Box(var value: Any?)

inline fun Box.spinUntil(action: (Any?) -> Unit): Nothing {
    while (true) { action(value) }
}

class Holder {
    private val state = Box("active")
    fun install(handler: String): String {
        state.spinUntil { s ->
            when (s) {
                "active" -> { state.value = "claimed:$handler"; return "ok:$handler" }
                "claimed:$handler" -> return "dup:$handler"
                else -> return "other:$handler"
            }
        }
    }
}

fun main() {
    val h = Holder()
    println("${h.install("X")}|${h.install("Y")}")
}
"#;
    // First install: state="active" -> branch sets state="claimed:X" and returns "ok:X".
    // Second install: state="claimed:X" -> arm "claimed:$handler" is "claimed:Y" (handler="Y")
    //   which does NOT equal "claimed:X" -> falls to `else` -> "other:Y".
    assert_klio(
        "member_invoked_inline_ext_capture",
        src,
        "ok:X|other:Y\n",
    );
}

// 6. Multiple inline frames live simultaneously: outer inline fn
//    whose lambda calls another inline fn whose lambda does a
//    non-local return to the *outermost* caller.
#[test]
fn nested_inline_nonlocal_return_outermost() {
    let src = r#"
inline fun outer(action: () -> Int): Int { return action() + 100 }
inline fun inner(action: () -> Int): Int { return action() }

fun probe(): String {
    val r = outer { inner { return@probe "early" } ; -1 }
    return "late:$r"
}
fun main() { println(probe()) }
"#;
    // `return@probe` from the inner lambda must exit `probe`, bypassing both inline fns.
    assert_klio("nested_inline_return_outermost", src, "early\n");
}

// 7. Inline fn returning a lambda that captures an enclosing param
//    (closure escape from an inline body — the lambda must hold
//    onto the captured value after the inline fn returns).
#[test]
fn inline_returning_closure_capture() {
    let src = r#"
inline fun makeAdder(crossinline base: () -> Int): (Int) -> Int {
    return { x -> base() + x }
}
fun main() {
    val k = 7
    val add = makeAdder { k * 10 }
    println("${add(2)} ${add(3)}")
}
"#;
    assert_klio("inline_returns_closure", src, "72 73\n");
}

// 8. `with(receiver) { ... }` inside `apply { ... }` inside a class
//    method: nested receiver lambdas. `this@Outer.member` must
//    still resolve.
#[test]
fn nested_receiver_lambdas_this_label() {
    let src = r#"
class Outer(val tag: String) {
    fun build(n: Int): String {
        val sb = StringBuilder()
        with(n) {                                      // this:Int
            sb.apply {                                 // this:StringBuilder
                append(this@Outer.tag)
                append(":")
                append(this@with.toString())           // n
            }
        }
        return sb.toString()
    }
}
fun main() { println(Outer("T").build(42)) }
"#;
    assert_klio("nested_receiver_lambdas", src, "T:42\n");
}
