//! Lambda + dispatch parity: lambda over receiver, lambda inside
//! generic dispatch, suspended lambda captures, member-ref to
//! generic methods, scope function chaining with explicit this@.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_lambdas_and_dispatch");
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
fn function_reference_to_extension() {
    let src = r#"
fun String.shout(): String = this.uppercase() + "!"
fun main() {
    val xs = listOf("hi", "yo")
    println(xs.joinToString(",", transform = String::shout))
}
"#;
    assert_klio("fnref_ext", src, "HI!,YO!\n");
}

#[test]
fn member_reference_bound() {
    let src = r#"
class Box(val v: Int) { fun show(): String = "Box($v)" }
fun main() {
    val b = Box(7)
    val ref = b::show
    println(ref())
}
"#;
    assert_klio("memref_bound", src, "Box(7)\n");
}

#[test]
fn lambda_with_two_receivers_via_this_at_label() {
    let src = r#"
class Outer {
    val tag = "OUT"
    fun build(): String {
        return with(StringBuilder()) {
            append(this@Outer.tag)
            append("|")
            append(this.length.toString())
            toString()
        }
    }
}
fun main() { println(Outer().build()) }
"#;
    assert_klio("two_receivers", src, "OUT|4\n");
}

#[test]
fn lambda_in_subclass_calls_super() {
    let src = r#"
open class Base { open fun ping(): String = "base" }
class Sub : Base() {
    override fun ping(): String = "sub-${super.ping()}"
    fun chain(): String = listOf(1,2).joinToString(",") { ping() + "-$it" }
}
fun main() { println(Sub().chain()) }
"#;
    assert_klio("lambda_super", src, "sub-base-1,sub-base-2\n");
}

#[test]
fn higher_order_local_fn_dispatch() {
    let src = r#"
fun main() {
    fun mul(k: Int): (Int) -> Int = { x -> x * k }
    val twice = mul(2)
    val triple = mul(3)
    println("${twice(5)},${triple(5)}")
}
"#;
    assert_klio("higher_local", src, "10,15\n");
}

#[test]
fn lambda_in_for_capturing_loop_var() {
    let src = r#"
fun main() {
    val makers = mutableListOf<() -> Int>()
    for (i in 1..3) {
        // Each iteration's lambda captures a fresh `i`.
        val v = i
        makers.add { v }
    }
    println(makers.joinToString(",") { it().toString() })
}
"#;
    assert_klio("loop_var", src, "1,2,3\n");
}

#[test]
fn closure_propagates_through_collect() {
    let src = r#"
fun main() {
    var s = 0
    listOf(1,2,3,4).forEach { s += it * it }
    println(s)
}
"#;
    assert_klio("collect_var", src, "30\n");
}

#[test]
fn lambda_dispatch_through_polymorphic_param() {
    let src = r#"
interface F<T> { fun apply(x: T): String }
class IntF : F<Int> { override fun apply(x: Int): String = "int:$x" }
class StrF : F<String> { override fun apply(x: String): String = "str:$x" }
fun <T> run(f: F<T>, x: T): String = f.apply(x)
fun main() {
    println("${run(IntF(), 7)}|${run(StrF(), "hi")}")
}
"#;
    assert_klio("poly_dispatch", src, "int:7|str:hi\n");
}

#[test]
fn typed_callable_reference_to_class_method() {
    let src = r#"
class Foo {
    fun greet(name: String): String = "Hello, $name"
}
fun main() {
    val f = Foo()
    val refs = listOf("Ann", "Bob").map(f::greet)
    println(refs.joinToString(";"))
}
"#;
    assert_klio("callable_ref", src, "Hello, Ann;Hello, Bob\n");
}

#[test]
fn scope_fn_apply_chain_returns_receiver() {
    let src = r#"
class Bag {
    val items = mutableListOf<String>()
    fun add(s: String): Bag = apply { items.add(s) }
}
fun main() {
    val b = Bag().add("a").add("b").add("c")
    println(b.items.joinToString(","))
}
"#;
    assert_klio("apply_chain", src, "a,b,c\n");
}
