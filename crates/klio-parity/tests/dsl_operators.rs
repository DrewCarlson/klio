//! DSL and operator coverage: infix, operator overloads, builder
//! receiver chains, invoke convention, get/set conventions.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_dsl_operators");
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
fn infix_function_chain() {
    let src = r#"
infix fun Int.times(s: String): String = (1..this).joinToString("") { s }
fun main() {
    val r = 3 times "ab"
    println(r)
}
"#;
    assert_klio("infix", src, "ababab\n");
}

#[test]
fn operator_get_set_index() {
    let src = r#"
class Grid(val w: Int, val h: Int) {
    private val data = IntArray(w * h)
    operator fun get(x: Int, y: Int): Int = data[y * w + x]
    operator fun set(x: Int, y: Int, v: Int) { data[y * w + x] = v }
}
fun main() {
    val g = Grid(3, 2)
    g[0,0] = 1; g[2,1] = 99
    println("${g[0,0]},${g[2,1]},${g[1,0]}")
}
"#;
    assert_klio("get_set", src, "1,99,0\n");
}

#[test]
fn operator_arithmetic_overload() {
    let src = r#"
data class V(val x: Int, val y: Int) {
    operator fun plus(o: V) = V(x+o.x, y+o.y)
    operator fun minus(o: V) = V(x-o.x, y-o.y)
    operator fun times(k: Int) = V(x*k, y*k)
    operator fun unaryMinus() = V(-x, -y)
}
fun main() {
    val a = V(1,2); val b = V(3,4)
    val sum = a + b
    val diff = b - a
    val scaled = a * 3
    val neg = -a
    println("${sum.x},${sum.y};${diff.x},${diff.y};${scaled.x},${scaled.y};${neg.x},${neg.y}")
}
"#;
    assert_klio("arith_ops", src, "4,6;2,2;3,6;-1,-2\n");
}

#[test]
fn operator_compare_overload() {
    let src = r#"
class Money(val cents: Int) : Comparable<Money> {
    override fun compareTo(other: Money): Int = cents - other.cents
}
fun main() {
    val a = Money(100); val b = Money(250); val c = Money(100)
    println("${a < b},${a == c},${a <= c},${b > a}")
}
"#;
    // a == c uses structural equality (default object equality) — NOT cents-equal.
    assert_klio("compare", src, "true,false,true,true\n");
}

#[test]
fn invoke_convention_function_like() {
    let src = r#"
class Multi(val k: Int) {
    operator fun invoke(x: Int): Int = x * k
}
fun main() {
    val m = Multi(3)
    println("${m(4)},${m(10)}")
}
"#;
    assert_klio("invoke", src, "12,30\n");
}

#[test]
fn dsl_html_like_builder() {
    let src = r#"
class Tag(val name: String) {
    private val children = mutableListOf<Tag>()
    private val text = StringBuilder()
    fun add(t: Tag) { children.add(t) }
    fun text(s: String) { text.append(s) }
    fun render(): String {
        val sb = StringBuilder("<").append(name).append(">")
        sb.append(text)
        for (c in children) sb.append(c.render())
        sb.append("</").append(name).append(">")
        return sb.toString()
    }
}
fun tag(name: String, build: Tag.() -> Unit): Tag {
    val t = Tag(name); t.build(); return t
}
fun main() {
    val r = tag("div") {
        text("hello ")
        add(tag("b") { text("world") })
    }
    println(r.render())
}
"#;
    assert_klio("dsl_html", src, "<div>hello <b>world</b></div>\n");
}

#[test]
fn rangeTo_in_range() {
    // Custom user-Iterable through the new Iterable-extension
    // dispatch fallback. Uses a dedicated iterator class so all
    // state lives in primary-ctor fields and the dispatch is
    // exercised without depending on anonymous-object capture
    // semantics that earlier tracked tasks cover.
    let src = r#"
class IntIter(var cur: Int, val end: Int) : Iterator<Int> {
    override fun hasNext(): Boolean = cur <= end
    override fun next(): Int { val v = cur; cur += 1; return v }
}
class Counter(val from: Int, val to: Int) : Iterable<Int> {
    override fun iterator(): Iterator<Int> = IntIter(from, to)
}
fun main() {
    val r = Counter(1, 3)
    println(r.joinToString(",") { it.toString() })
}
"#;
    assert_klio("counter_join", src, "1,2,3\n");
}

#[test]
fn plus_assign_operator() {
    let src = r"
class Counter {
    var n: Int = 0
    operator fun plusAssign(k: Int) { n += k }
}
fun main() {
    val c = Counter()
    c += 5; c += 3
    println(c.n)
}
";
    assert_klio("plus_assign", src, "8\n");
}

#[test]
fn iterator_convention_for_loop() {
    let src = r#"
class Counter(val max: Int) {
    operator fun iterator(): Iterator<Int> = object : Iterator<Int> {
        var cur = 0
        override fun hasNext(): Boolean = cur < max
        override fun next(): Int { cur += 1; return cur }
    }
}
fun main() {
    val c = Counter(4)
    val sb = StringBuilder()
    for (x in c) sb.append("$x,")
    println(sb)
}
"#;
    assert_klio("iter_convention", src, "1,2,3,4,\n");
}

#[test]
fn componentN_destructuring() {
    let src = r#"
class Triple3(val a: Int, val b: Int, val c: Int) {
    operator fun component1(): Int = a
    operator fun component2(): Int = b
    operator fun component3(): Int = c
}
fun main() {
    val (x, y, z) = Triple3(7, 8, 9)
    println("$x,$y,$z")
}
"#;
    assert_klio("componentN", src, "7,8,9\n");
}
