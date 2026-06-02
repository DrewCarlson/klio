//! Parity coverage for the resolution / dispatch / inline shapes
//! that kotlinx-coroutines exercises pervasively — without actually
//! using the cancellation machinery (tracked separately in tasks
//! #23, #27, #28). Each scenario is a self-contained Kotlin program
//! using *only* core language features (no coroutine builders, no
//! atomicfu) so a failure here pinpoints a language-level gap, not
//! a library wiring issue.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_coroutine_shapes");
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

// 1. `AtomicRef`-shaped CAS loop with `when (state) { is X, is Y -> ... }`
//    where the lambda captures an enclosing-fn param and does
//    non-local return.
#[test]
fn cas_loop_when_with_captured_handler() {
    let src = r#"
class Slot<T>(initial: T) {
    private var value: T = initial
    fun cas(expected: T, update: T): Boolean {
        if (value == expected) { value = update; return true }
        return false
    }
    fun get(): T = value
}

inline fun <T> Slot<T>.spin(action: (T) -> Unit): Nothing {
    while (true) { action(get()) }
}

sealed class State { object Active : State(); data class Held(val by: String) : State() }

fun install(slot: Slot<State>, handler: String): String {
    slot.spin { s ->
        when (s) {
            is State.Active -> { if (slot.cas(s, State.Held(handler))) return "ok:$handler" }
            is State.Held   -> return "busy:${s.by}->${handler}"
        }
    }
}

fun main() {
    val slot = Slot<State>(State.Active)
    println(install(slot, "A"))
    println(install(slot, "B"))
}
"#;
    assert_klio("cas_loop_capture", src, "ok:A\nbusy:A->B\n");
}

// 2. Inline ext fn with non-local return whose lambda calls a
//    second member function on `this@enclosing`.
#[test]
fn inline_ext_lambda_calls_enclosing_member() {
    let src = r#"
class Box<T>(val v: T)

inline fun <T> Box<T>.useOnce(action: (T) -> String): String =
    action(v)

class Holder {
    private fun tag(s: String): String = "[h]$s"
    fun work(b: Box<String>): String {
        return b.useOnce { v -> tag(v) }
    }
}

fun main() { println(Holder().work(Box("k"))) }
"#;
    assert_klio("inline_ext_calls_enclosing", src, "[h]k\n");
}

// 3. Two-level inline composition: `outer.iter { inner.iter { … } }`
//    with a non-local return that targets the function lexically
//    containing BOTH calls.
#[test]
fn two_level_inline_composition_nonlocal_return() {
    let src = r#"
inline fun <T> Iterable<T>.iter(action: (T) -> Unit) { for (x in this) action(x) }

fun findFirstPair(rows: List<List<Int>>, target: Int): String {
    rows.iter { row ->
        row.iter { c ->
            if (c == target) return "found($target)"
        }
    }
    return "missing"
}

fun main() {
    val grid = listOf(listOf(1, 2, 3), listOf(4, 5, 6), listOf(7, 8, 9))
    println(findFirstPair(grid, 5))
    println(findFirstPair(grid, 99))
}
"#;
    assert_klio(
        "two_level_inline_composition",
        src,
        "found(5)\nmissing\n",
    );
}

// 4. Sealed hierarchy + when + smart-cast + enclosing-fn capture +
//    nested inline ext on `this`.
#[test]
fn sealed_smartcast_with_inline_ext_member() {
    let src = r#"
sealed class Event {
    class Msg(val text: String) : Event()
    class Err(val code: Int) : Event()
    object Tick : Event()
}

inline fun runEach(events: List<Event>, h: (Event) -> Unit) {
    for (e in events) h(e)
}

class Sink {
    private val out = StringBuilder()
    fun emit(s: String) { out.append(s); out.append("|") }
    fun render(): String = out.toString()
    fun drain(events: List<Event>): String {
        runEach(events) { e ->
            when (e) {
                is Event.Msg -> emit("M:${e.text}")
                is Event.Err -> emit("E:${e.code}")
                Event.Tick   -> emit("T")
            }
        }
        return render()
    }
}

fun main() {
    val s = Sink()
    println(s.drain(listOf(Event.Msg("hi"), Event.Tick, Event.Err(7), Event.Msg("bye"))))
}
"#;
    assert_klio(
        "sealed_smartcast_inline_ext",
        src,
        "M:hi|T|E:7|M:bye|\n",
    );
}

// 5. Subclass + private member referenced from a lambda inside a
//    method, alongside an inline-ext call on `this`.
#[test]
fn subclass_private_in_lambda_through_inline() {
    let src = r#"
inline fun <T, R> T.tap(f: (T) -> R): R = f(this)

open class Base(val seed: Int) {
    protected fun mix(n: Int): Int = (n xor seed) + 1
}
class Sub(s: Int) : Base(s) {
    fun process(xs: List<Int>): String =
        xs.joinToString(",") { it.tap { v -> "${mix(v)}" } }
}
fun main() { println(Sub(5).process(listOf(0, 1, 2, 3))) }
"#;
    // seed=5; mix(n) = (n xor 5) + 1 ; xor: 0^5=5,1^5=4,2^5=7,3^5=6 ; +1: 6,5,8,7
    assert_klio(
        "subclass_private_via_inline_tap",
        src,
        "6,5,8,7\n",
    );
}

// 6. Generic class with two nested generic classes, inline extension
//    on the outer carrying a non-local-return lambda capturing the
//    enclosing fn's param.
#[test]
fn generic_nested_inline_ext_capture() {
    let src = r#"
class Pair2<A, B>(val a: A, val b: B)
class Triple3<A, B, C>(val a: A, val b: B, val c: C)

inline fun <A, B> Pair2<A, B>.either(
    onA: (A) -> String,
    onB: (B) -> String,
    pickA: Boolean
): String = if (pickA) onA(a) else onB(b)

fun render(p: Pair2<Int, String>, tag: String, pickA: Boolean): String =
    p.either({ "A=$it:$tag" }, { "B=$it:$tag" }, pickA)

fun main() {
    val p = Pair2(7, "z")
    println("${render(p, "x", true)}|${render(p, "y", false)}")
}
"#;
    assert_klio("generic_nested_inline_ext", src, "A=7:x|B=z:y\n");
}

// 7. Member fn whose body is an `=`-expr that uses an inline ext on
//    `this`. Hits the `=`-expression body + inline-splice + member-
//    invoke path together.
#[test]
fn member_expr_body_with_inline_ext_on_this() {
    let src = r"
inline fun <T, R> T.also2(action: (T) -> Unit): T { action(this); return this }

class Counter {
    private var n = 0
    fun bump(): Counter = this.also2 { it.n++ }
    fun value(): Int = n
}

fun main() {
    val c = Counter().bump().bump().bump()
    println(c.value())
}
";
    assert_klio("member_expr_body_inline_ext", src, "3\n");
}

// 8. Property delegate using a CLASS field — class property by lazy.
#[test]
fn class_property_by_lazy() {
    let src = r#"
class Compute(val seed: Int) {
    val expensive: String by lazy { "v:${seed * 100}" }
}
fun main() {
    val c = Compute(3)
    println("${c.expensive}|${c.expensive}")
}
"#;
    assert_klio("class_property_by_lazy", src, "v:300|v:300\n");
}
