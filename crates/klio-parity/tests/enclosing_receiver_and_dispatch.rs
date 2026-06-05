//! Regression parity for resolution + dispatch fixes uncovered while
//! consuming ktor's upstream `HttpClient`/plugin construction. Each
//! program is self-contained, prints a deterministic short string, and
//! is asserted against a literal (so it runs without kotlinc) and, when
//! kotlinc is available, byte-checked against it.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_encl_dispatch");
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

// A bare member read inside a `with(other) { … }` block names a member
// of the lexically enclosing `this@Host`, not the `with` receiver. The
// receiver scope-fn pushes its own receiver ahead of `this@Host` on the
// enclosing chain, so the resolver must walk the whole chain — not just
// the nearest receiver — to reach `config`.
#[test]
fn with_receiver_reads_enclosing_member() {
    assert_klio(
        "with_receiver_reads_enclosing_member",
        r#"
class Cfg { fun install(n: String): String = "installed:$n" }
class Other
class Host {
    val config = Cfg()
    private val uc = Other()
    fun run(): String = with(uc) { config.install("A") + "/" + config.install("B") }
}
fun main() { println(Host().run()) }
"#,
        "installed:A/installed:B\n",
    );
}

// A reified inline call in an object/companion property initializer
// infers its type argument from the property's declared type, exactly as
// a local `val x: Key<T> = …` does. Without the declared-type hint the
// `T::class` read fails and the initializer silently leaves the property
// unset.
#[test]
fn member_property_init_infers_reified_type_arg() {
    assert_klio(
        "member_property_init_infers_reified_type_arg",
        r#"
class Key<T : Any>(val name: String, val tn: String)
inline fun <reified T : Any> keyOf(name: String): Key<T> = Key(name, T::class.simpleName ?: "?")
interface HasKey<T : Any> { val key: Key<T> }
class Thing
object Reg : HasKey<Thing> { override val key: Key<Thing> = keyOf("R") }
fun main() { println("${Reg.key.name}/${Reg.key.tn}") }
"#,
        "R/Thing\n",
    );
}

// `x as TConfig` where `TConfig` is an erased type parameter is an
// unchecked cast that never throws — even when the cast sits in a nested
// lambda whose own function carries none of the enclosing function's
// type parameters and the param name is too long for the short-name
// heuristic.
#[test]
fn erased_multi_letter_type_param_cast_in_lambda() {
    assert_klio(
        "erased_multi_letter_type_param_cast_in_lambda",
        r#"
class Cfg(val v: Int)
fun <TConfig : Any> grab(x: Any): TConfig {
    val f: () -> TConfig = { @Suppress("UNCHECKED_CAST") (x as TConfig) }
    return f()
}
fun main() { val c: Cfg = grab(Cfg(7)); println(c.v) }
"#,
        "7\n",
    );
}

// A `(Client) -> Unit` lambda written `{ scope -> … }` invoked
// receiver-only (`client.apply(it)`) binds the receiver to its declared
// `scope` parameter — even when the body references a bare top-level
// symbol, which makes the lambda pick up a `this` capture that must not
// suppress the positional binding.
#[test]
fn receiver_only_invoke_binds_named_param_with_this_capture() {
    assert_klio(
        "receiver_only_invoke_binds_named_param_with_this_capture",
        r#"
val TAG = "G"
class Client { val pipe = "PIPE" }
class Reg {
    val blocks = mutableListOf<(Client) -> Unit>()
    fun add() { blocks.add { scope -> println("$TAG:${scope.pipe}") } }
    fun applyAll(c: Client) { blocks.forEach { c.apply(it) } }
}
fun main() { val r = Reg(); r.add(); r.applyAll(Client()) }
"#,
        "G:PIPE\n",
    );
}

// A bare `block()` where `block: T.() -> R` is a *captured* param (one
// composing-builder calling through to another) must run against the
// active enclosing receiver, threaded through every nesting level.
#[test]
fn nested_receiver_lambda_block_composition() {
    assert_klio(
        "nested_receiver_lambda_block_composition",
        r#"
class Builder { var method = "" }
fun make(block: Builder.() -> Unit): Builder = Builder().apply(block)
fun makeGet(block: Builder.() -> Unit): Builder = make { method = "GET"; block() }
fun makeGetUrl(url: String, block: Builder.() -> Unit = {}): Builder =
    makeGet { method = method + ":$url"; block() }
fun main() { println(makeGetUrl("u").method) }
"#,
        "GET:u\n",
    );
}

// Same composition through `inline fun` builders — the inline splice
// must also carry the receiver-lambda-param mark so a spliced bare
// `block()` dispatches against the current receiver (the shape ktor's
// `client.get(url)` → `request { … }` DSL relies on).
#[test]
fn nested_receiver_lambda_block_composition_inline() {
    assert_klio(
        "nested_receiver_lambda_block_composition_inline",
        r#"
class Builder { var method = "" }
inline fun make(block: Builder.() -> Unit): Builder = Builder().apply(block)
inline fun makeGet(block: Builder.() -> Unit): Builder = make { method = "GET"; block() }
inline fun makeGetUrl(url: String, block: Builder.() -> Unit = {}): Builder =
    makeGet { method = method + ":$url"; block() }
fun main() { println(makeGetUrl("u").method) }
"#,
        "GET:u\n",
    );
}

// An overloaded `suspend inline fun` (a value-param form and a
// function-param form, like ktor's `get(builder)` / `get(block)`) binds a
// trailing-lambda call to the function-param overload. klio's inline-fn
// table is keyed by simple name, so without shape-aware overload selection
// the lambda would land on the value-param form. (kotlinc parity is
// skipped — a standalone coroutine program needs the kotlinx-coroutines
// classpath the parity oracle lacks; the klio assertion is the guard.)
#[test]
fn overloaded_suspend_inline_picks_function_param_for_lambda() {
    assert_klio(
        "overloaded_suspend_inline_picks_function_param_for_lambda",
        r#"
import kotlinx.coroutines.runBlocking
class B { var m = "" }
suspend inline fun pick(b: B): B { b.m = "V"; return b }
suspend inline fun pick(block: B.() -> Unit): B = pick(B().apply(block))
suspend fun run2(): String = pick { m = "L" }.m
fun main() { runBlocking { println(run2()) } }
"#,
        "V\n",
    );
}

// A `suspend inline` *extension* fn must not be inline-spliced for a bare
// call whose enclosing receiver is a different type. Here `Cfg.get` (which
// sets `tag`) shares the simple name `get` with the stdlib `CharSequence.get`
// indexing; a bare `get(0)` inside `CharSequence.firstTwo` must dispatch the
// real `CharSequence.get` (returning a Char), not splice `Cfg.get`'s body
// (`tag = …`) onto the Int index. This is the exact shape that made loading
// ktor's `inline fun HttpClient.get(builder)` corrupt stdlib `indexOfAny`.
// (kotlinc parity is skipped — a standalone coroutine program lacks the
// kotlinx-coroutines classpath in the parity oracle; the klio assertion is
// the guard: a regression throws "set_field tag on kotlin.Int".)
#[test]
fn inline_extension_does_not_shadow_stdlib_bare_call() {
    assert_klio(
        "inline_extension_does_not_shadow_stdlib_bare_call",
        r#"
import kotlinx.coroutines.runBlocking
class Cfg { var tag = "" }
suspend inline fun Cfg.get(n: Int): Cfg { tag = "cfg"; return this }
suspend fun CharSequence.firstTwo(): String {
    val a = get(0)
    val b = get(1)
    return "" + a + b
}
fun main() { runBlocking { println("hello".firstTwo()) } }
"#,
        "he\n",
    );
}

// A function-typed property — including a constructor reference
// `::Config` — invoked by bare name inside a method (here reached via an
// inlined `apply { }` body, where the member-call lowering loses the
// own-member context) reads the field and invokes the stored callable.
#[test]
fn function_typed_property_invoked_by_name() {
    assert_klio(
        "function_typed_property_invoked_by_name",
        r#"
class Config { var v = 0 }
class Impl(private val make: () -> Config) {
    fun build(block: Config.() -> Unit): Config = make().apply(block)
}
fun main() { val c = Impl(::Config).build { v = 9 }; println(c.v) }
"#,
        "9\n",
    );
}

// A receiver lambda `R.(P) -> R2` invoked with the receiver supplied as an
// explicit *leading argument* (`handler(receiver, p)`, not `receiver.handler(p)`)
// binds arg0 as the receiver, so the body reaches the receiver's members by
// bare name — both when the bare member call is the whole body and when it is
// nested in a sub-expression. This is exactly ktor's send pipeline shape: an
// `on(Send)` handler is invoked as `handler(Sender(this, …), request)` and its
// body calls the receiver's `proceed` by bare name (often as an assignment RHS
// `val origin = proceed(request)`). Without the explicit-receiver dispatch the
// bare `proceed` falls through to a global lookup and fails.
#[test]
fn receiver_lambda_invoked_with_explicit_receiver_arg() {
    assert_klio(
        "receiver_lambda_invoked_with_explicit_receiver_arg",
        r#"
class Sender(val tag: Int) { fun proceed(x: Int): Int = tag + x }
fun drive(handler: Sender.(Int) -> Int): Int {
    val invoke: (Int) -> Int = { v -> handler(Sender(100), v) }
    return invoke(5)
}
fun driveStr(handler: Sender.(Int) -> String): String {
    val invoke: (Int) -> String = { v -> handler(Sender(100), v) }
    return invoke(5)
}
fun main() {
    println(drive { v -> proceed(v) })
    println(drive { v -> proceed(v) + proceed(1) })
    println(driveStr { v -> "r=" + proceed(v) })
    println(driveStr { v -> val r = proceed(v); "got($r)" })
}
"#,
        "105\n206\nr=105\ngot(105)\n",
    );
}
