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
    assert_klio("overload_member_vs_extension", src, "A.member B.member\n");
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
    assert_klio("smart_cast_when_arms_capture", src, "A(x,7)|B(y,k)|Z(z)\n");
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
    assert_klio(
        "comparable_sort",
        src,
        "(1,2),(2,5),(3,0),(3,1)\n(1,2)\n(3,1)\n",
    );
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
    let src = r"
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
";
    assert_klio("primary_default_factory", src, "110\n");
}

#[test]
fn array_deque_supports_bfs_queue_operations() {
    let src = r#"
fun bfs(start: Int, edges: Map<Int, List<Int>>): List<Int> {
    val q = ArrayDeque<Int>()
    val seen = mutableSetOf<Int>()
    val out = mutableListOf<Int>()
    q.addLast(start)
    seen.add(start)
    while (q.isNotEmpty()) {
        val cur = q.removeFirst()
        out.add(cur)
        for (n in edges[cur] ?: emptyList()) {
            if (seen.add(n)) q.addLast(n)
        }
    }
    return out
}
fun main() {
    val es = mapOf(
        1 to listOf(2, 3),
        2 to listOf(4),
        3 to listOf(4, 5),
        4 to listOf(6),
        5 to listOf(6),
        6 to emptyList(),
    )
    println(bfs(1, es).joinToString(","))
}
"#;
    assert_klio("array_deque_bfs", src, "1,2,3,4,5,6\n");
}

#[test]
fn min_max_of_dispatch_through_comparable_instance() {
    let src = r#"
class Box(val v: Int) : Comparable<Box> {
    override fun compareTo(other: Box): Int = v - other.v
    override fun toString(): String = "Box($v)"
}
fun main() {
    val a = Box(10)
    val b = Box(3)
    println(maxOf(a, b))
    println(minOf(a, b))
}
"#;
    assert_klio("cmp_extreme_instance", src, "Box(10)\nBox(3)\n");
}

#[test]
fn map_to_mutable_map_and_to_map() {
    let src = r#"
fun main() {
    val m = mapOf("a" to 1, "b" to 2)
    val mm = m.toMutableMap()
    mm["c"] = 3
    val rm = mm.toMap()
    println(rm.entries.sortedBy { it.key }.joinToString(",") { "${it.key}=${it.value}" })
}
"#;
    assert_klio("map_to_mutable", src, "a=1,b=2,c=3\n");
}

#[test]
fn override_getter_chain_with_sum_of() {
    let src = r#"
open class Shape {
    open val area: Double = 0.0
    open fun describe(): String = "Shape(area=$area)"
}
class Rect(val w: Double, val h: Double) : Shape() {
    override val area: Double get() = w * h
    override fun describe(): String = "Rect(${w}x$h, area=$area)"
}
fun main() {
    val shapes: List<Shape> = listOf(Rect(3.0, 4.0), Rect(1.0, 1.0))
    val total = shapes.sumOf { it.area }
    println("total=$total")
    for (s in shapes) println(s.describe())
}
"#;
    assert_klio(
        "override_getter_chain",
        src,
        "total=13.0\nRect(3.0x4.0, area=12.0)\nRect(1.0x1.0, area=1.0)\n",
    );
}

#[test]
fn protected_super_method_in_overriding_subclass() {
    let src = r#"
open class Cache<K, V> {
    protected val store = mutableMapOf<K, V>()
    open fun get(k: K): V? = store[k]
    open fun put(k: K, v: V) { store[k] = v }
}
class TimedCache<K, V>(private val ttl: Long) : Cache<K, V>() {
    private val timestamps = mutableMapOf<K, Long>()
    private var clock: Long = 0
    fun tick(by: Long) { clock += by }
    override fun get(k: K): V? {
        val t = timestamps[k] ?: return null
        if (clock - t > ttl) {
            store.remove(k); timestamps.remove(k); return null
        }
        return super.get(k)
    }
    override fun put(k: K, v: V) {
        super.put(k, v)
        timestamps[k] = clock
    }
}
fun main() {
    val c = TimedCache<String, Int>(10)
    c.put("a", 1)
    c.tick(11)
    println(c.get("a"))
    c.put("b", 2)
    println(c.get("b"))
}
"#;
    assert_klio("protected_super_subclass", src, "null\n2\n");
}

#[test]
fn sealed_tree_visitor_two_results() {
    let src = r#"
sealed class Tree<T> {
    abstract fun <R> visit(visitor: TreeVisitor<T, R>): R
}
class Empty<T> : Tree<T>() {
    override fun <R> visit(visitor: TreeVisitor<T, R>): R = visitor.onEmpty()
}
class Branch<T>(val v: T, val l: Tree<T>, val r: Tree<T>) : Tree<T>() {
    override fun <R> visit(visitor: TreeVisitor<T, R>): R =
        visitor.onBranch(v, l.visit(visitor), r.visit(visitor))
}
interface TreeVisitor<T, R> {
    fun onEmpty(): R
    fun onBranch(v: T, l: R, r: R): R
}
class SumV : TreeVisitor<Int, Int> {
    override fun onEmpty(): Int = 0
    override fun onBranch(v: Int, l: Int, r: Int): Int = v + l + r
}
class RenderV<T> : TreeVisitor<T, String> {
    override fun onEmpty(): String = "_"
    override fun onBranch(v: T, l: String, r: String): String = "($l<-$v->$r)"
}
fun main() {
    val t: Tree<Int> = Branch(5, Branch(3, Empty(), Empty()), Branch(7, Empty(), Empty()))
    println(t.visit(SumV()))
    println(t.visit(RenderV<Int>()))
}
"#;
    assert_klio(
        "sealed_tree_visitor",
        src,
        "15\n((_<-3->_)<-5->(_<-7->_))\n",
    );
}

#[test]
fn lifecycle_subscribe_init_block_captures() {
    let src = r#"
class Lifecycle {
    private val watchers = mutableListOf<(String) -> Unit>()
    fun watch(w: (String) -> Unit): Lifecycle { watchers.add(w); return this }
    private fun notify(state: String) { for (w in watchers.toList()) w(state) }
    private var state = "init"
    fun start() { state = "starting"; notify(state); state = "running"; notify(state) }
    fun stop() { state = "stopping"; notify(state); state = "stopped"; notify(state) }
}
class Component(val name: String) {
    val lc = Lifecycle()
    val seen = mutableListOf<String>()
    init {
        lc.watch { seen.add("$name:$it") }
    }
}
fun main() {
    val a = Component("A")
    a.lc.start(); a.lc.stop()
    println(a.seen.joinToString(","))
}
"#;
    assert_klio(
        "lifecycle_subscribe",
        src,
        "A:starting,A:running,A:stopping,A:stopped\n",
    );
}

#[test]
fn matrix_operator_plus_times_chain() {
    let src = r#"
class Matrix(val rows: Int, val cols: Int) {
    private val data = Array(rows) { IntArray(cols) }
    operator fun get(r: Int, c: Int): Int = data[r][c]
    operator fun set(r: Int, c: Int, v: Int) { data[r][c] = v }
    operator fun plus(other: Matrix): Matrix {
        val r = Matrix(rows, cols)
        for (i in 0 until rows) for (j in 0 until cols) r[i, j] = this[i, j] + other[i, j]
        return r
    }
    operator fun times(other: Matrix): Matrix {
        val r = Matrix(rows, other.cols)
        for (i in 0 until rows) for (j in 0 until other.cols) for (k in 0 until cols) {
            r[i, j] = r[i, j] + this[i, k] * other[k, j]
        }
        return r
    }
    fun render(): String = (0 until rows).joinToString("|") { r ->
        (0 until cols).joinToString(",") { c -> this[r, c].toString() }
    }
}
fun main() {
    val a = Matrix(2, 2); a[0,0]=1; a[0,1]=2; a[1,0]=3; a[1,1]=4
    val b = Matrix(2, 2); b[0,0]=10; b[0,1]=20; b[1,0]=30; b[1,1]=40
    println((a + b).render())
    println((a * b).render())
}
"#;
    assert_klio("matrix_ops", src, "11,22|33,44\n70,100|150,220\n");
}

// A class with same-named top-level factory functions — including a
// no-arg one beside a builder-lambda one (the `HttpClient { … }` shape).
// A trailing-lambda call must resolve to the lambda-taking factory, not
// the primary constructor, even though a no-arg factory is also present.
#[test]
fn class_with_factory_function_overloads() {
    let src = r#"
class Conf {
    var size: Int = 0
    var name: String = "default"
}
class Widget(val conf: Conf)

fun Widget(): Widget = Widget(Conf())
fun Widget(build: Conf.() -> Unit): Widget {
    val c = Conf()
    c.build()
    return Widget(c)
}

fun main() {
    val a = Widget()                                  // no-arg factory
    val b = Widget { size = 7; name = "b" }           // builder factory
    val c = Widget(Conf())                            // primary constructor
    println("${a.conf.size}/${a.conf.name}")
    println("${b.conf.size}/${b.conf.name}")
    println("${c.conf.size}/${c.conf.name}")
}
"#;
    assert_klio(
        "class_with_factory_function_overloads",
        src,
        "0/default\n7/b\n0/default\n",
    );
}

// A bare `arrayOf(...)` inside a method / lambda body is the top-level
// global factory, never a member of the enclosing receiver. The
// speculative receiver-prepend probe must not inject `this` as a spurious
// first element (which would make `make().size` report one too many).
#[test]
fn array_builder_in_method_does_not_prepend_receiver() {
    let src = r#"
class Builder(val tag: String) {
    fun direct(): Array<String> = arrayOf("a", "b", "c")
    fun viaLambda(): Array<String> {
        val produce = { arrayOf(tag, "x") }
        return produce()
    }
}
fun main() {
    val b = Builder("t")
    val d = b.direct()
    println("${d.size}:${d.joinToString(",")}")
    val l = b.viaLambda()
    println("${l.size}:${l.joinToString(",")}")
}
"#;
    assert_klio(
        "array_builder_in_method_does_not_prepend_receiver",
        src,
        "3:a,b,c\n2:t,x\n",
    );
}

// A bare call `name()` inside a class whose own member `name` is a
// (non-invokable) property, beside a top-level `fun name()`, must resolve
// to the function — a property can't satisfy a call. Mirrors ktor's
// `HttpStatusCode` companion: `val allStatusCodes = allStatusCodes()`.
#[test]
fn call_resolves_to_top_level_fn_over_same_named_property() {
    let src = r#"
class Reg {
    companion object {
        val names: List<String> = names()
        fun byIndex(i: Int): String = names[i]
    }
}
internal fun names(): List<String> = listOf("alpha", "beta", "gamma")
fun main() {
    println(Reg.names.size)
    println(Reg.byIndex(1))
}
"#;
    assert_klio(
        "call_resolves_to_top_level_fn_over_same_named_property",
        src,
        "3\nbeta\n",
    );
}

// `String.equals` returns a Bool — including the kotlin.text 2-arg
// `ignoreCase` form, with both positional and named arguments (ktor's
// ContentType.match uses `equals(other, ignoreCase = true)`).
#[test]
fn string_equals_with_ignore_case() {
    let src = r#"
fun main() {
    println("Application".equals("application", ignoreCase = true))
    println("Application".equals("application"))
    println("AB".equals("ab", true))
    println("x".equals(null))
    println(!"A".equals("b", ignoreCase = true))
}
"#;
    assert_klio(
        "string_equals_with_ignore_case",
        src,
        "true\nfalse\ntrue\nfalse\ntrue\n",
    );
}
