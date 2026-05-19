//! Real-world Kotlin patterns: DSL builders, top-level extension
//! properties, visitor / recursive ADTs, tail-recursion, lateinit
//! var capture, scoped state in receiver lambdas. These shapes
//! collectively exercise the bulk of "interesting" Kotlin lowering.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_dsl_patterns");
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

// 1. A typed DSL builder: `html { body { p("text") } }`.
#[test]
fn typed_dsl_builder() {
    let src = r#"
class Tag(val name: String) {
    val children = mutableListOf<Any>()
    operator fun String.unaryPlus() { children.add(this) }
    fun render(): String {
        val parts = children.joinToString("") { c ->
            if (c is Tag) c.render() else c.toString()
        }
        return "<$name>$parts</$name>"
    }
}

fun html(block: Tag.() -> Unit): Tag = Tag("html").apply(block)
fun Tag.body(block: Tag.() -> Unit): Tag { val t = Tag("body"); t.block(); children.add(t); return t }
fun Tag.p(text: String): Tag { val t = Tag("p"); t.children.add(text); children.add(t); return t }

fun main() {
    val doc = html {
        body {
            p("hello")
            p("world")
        }
    }
    println(doc.render())
}
"#;
    assert_klio(
        "typed_dsl",
        src,
        "<html><body><p>hello</p><p>world</p></body></html>\n",
    );
}

// 2. Visitor pattern over a sealed hierarchy with a generic result.
#[test]
fn visitor_over_sealed() {
    let src = r#"
sealed class Expr {
    class Lit(val n: Int) : Expr()
    class Add(val l: Expr, val r: Expr) : Expr()
    class Mul(val l: Expr, val r: Expr) : Expr()
}

interface Visitor<R> {
    fun lit(n: Int): R
    fun add(l: R, r: R): R
    fun mul(l: R, r: R): R
}

fun <R> Expr.accept(v: Visitor<R>): R = when (this) {
    is Expr.Lit -> v.lit(n)
    is Expr.Add -> v.add(l.accept(v), r.accept(v))
    is Expr.Mul -> v.mul(l.accept(v), r.accept(v))
}

class Evaluator : Visitor<Int> {
    override fun lit(n: Int): Int = n
    override fun add(l: Int, r: Int): Int = l + r
    override fun mul(l: Int, r: Int): Int = l * r
}

class Printer : Visitor<String> {
    override fun lit(n: Int): String = "$n"
    override fun add(l: String, r: String): String = "($l+$r)"
    override fun mul(l: String, r: String): String = "($l*$r)"
}

fun main() {
    val e: Expr = Expr.Add(Expr.Mul(Expr.Lit(2), Expr.Lit(3)), Expr.Lit(4))
    println("${e.accept(Evaluator())} ${e.accept(Printer())}")
}
"#;
    assert_klio("visitor_sealed", src, "10 ((2*3)+4)\n");
}

// 3. Top-level extension property + extension function on a generic
//    type. Property reads through the extension getter.
#[test]
fn toplevel_extension_property() {
    let src = r#"
val <T> List<T>.lastIndexOr0: Int get() = if (isEmpty()) 0 else size - 1
fun <T> List<T>.middle(): T = this[lastIndexOr0 / 2]

fun main() {
    val xs = listOf(10, 20, 30, 40, 50)
    val ys = listOf("a")
    println("${xs.lastIndexOr0} ${xs.middle()} ${ys.lastIndexOr0}")
}
"#;
    // xs.lastIndexOr0 = 4, middle = xs[2] = 30, ys.lastIndexOr0 = 0
    assert_klio("toplevel_ext_property", src, "4 30 0\n");
}

// 4. `lateinit var` captured by a lambda that reads it before assignment
//    is illegal; valid usage assigns first then reads. Exercise both.
#[test]
fn lateinit_capture_after_assign() {
    let src = r#"
class Box {
    lateinit var label: String
    fun set(s: String): Box { label = s; return this }
    fun describe(): String {
        val pull = { -> label }
        return pull()
    }
}
fun main() { println(Box().set("hi").describe()) }
"#;
    assert_klio("lateinit_capture", src, "hi\n");
}

// 5. Receiver-lambda scope state (`buildList { add(...) }`-style) on
//    a custom builder, mutating shared state.
#[test]
fn custom_builder_scope_state() {
    let src = r#"
class L<T> {
    private val items = mutableListOf<T>()
    fun add(x: T) { items.add(x) }
    fun toList(): List<T> = items.toList()
}

fun <T> buildL(block: L<T>.() -> Unit): List<T> {
    val l = L<T>()
    l.block()
    return l.toList()
}

fun main() {
    val xs = buildL<Int> { add(1); add(2); add(3); for (i in 4..6) add(i) }
    println(xs)
}
"#;
    assert_klio("custom_builder_scope", src, "[1, 2, 3, 4, 5, 6]\n");
}

// 6. Tail-recursive fn with a defaulted accumulator + branching.
#[test]
fn tailrec_with_default_accumulator() {
    let src = r#"
tailrec fun digits(n: Long, acc: String = ""): String =
    if (n == 0L) acc.ifEmpty { "0" } else digits(n / 10, "${n % 10}" + acc)

fun main() {
    println("${digits(0L)} ${digits(12345L)} ${digits(7L)}")
}
"#;
    assert_klio("tailrec_default", src, "0 12345 7\n");
}

// 7. Class with private setter, public getter; mutated through
//    instance methods.
#[test]
fn private_setter_public_getter() {
    let src = r#"
class Counter {
    var n: Int = 0
        private set
    fun inc() { n++ }
    fun add(k: Int) { n += k }
}
fun main() {
    val c = Counter()
    c.inc(); c.inc(); c.add(5)
    println(c.n)
}
"#;
    assert_klio("private_setter", src, "7\n");
}

// 8. Generic recursive data structure: a linked list via sealed.
#[test]
fn generic_recursive_linked_list() {
    let src = r#"
sealed class LL<out T> {
    object Nil : LL<Nothing>()
    data class Cons<T>(val head: T, val tail: LL<T>) : LL<T>()
}

fun <T> LL<T>.toList(): String {
    val sb = StringBuilder("[")
    var cur: LL<T> = this
    while (cur is LL.Cons<T>) { sb.append(cur.head); cur = cur.tail; if (cur is LL.Cons<T>) sb.append(",") }
    sb.append("]")
    return sb.toString()
}

fun <T> ll(vararg xs: T): LL<T> {
    var l: LL<T> = LL.Nil
    for (i in xs.indices.reversed()) l = LL.Cons(xs[i], l)
    return l
}

fun main() {
    val xs = ll(1, 2, 3, 4)
    println(xs.toList())
}
"#;
    assert_klio("generic_linked_list", src, "[1,2,3,4]\n");
}
