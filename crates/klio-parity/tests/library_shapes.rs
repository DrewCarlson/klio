//! Library-style shapes klio frequently encounters in pack code:
//! sealed-enum-like singletons via `object`, interface with default
//! method, secondary constructors, init-block side effects, abstract
//! members + open-override chains, generic constraints with `out`/`in`,
//! enum classes with member functions, and final/open classes.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_library_shapes");
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

// 1. Enum class with abstract member overridden per-entry.
#[test]
fn enum_with_per_entry_override() {
    let src = r#"
enum class Op(val sym: String) {
    Add("+") { override fun apply(a: Int, b: Int): Int = a + b },
    Mul("*") { override fun apply(a: Int, b: Int): Int = a * b },
    Sub("-") { override fun apply(a: Int, b: Int): Int = a - b };
    abstract fun apply(a: Int, b: Int): Int
}

fun main() {
    val xs = listOf(Op.Add, Op.Mul, Op.Sub)
    println(xs.joinToString(",") { "${it.sym}=${it.apply(6, 4)}" })
}
"#;
    assert_klio("enum_per_entry_override", src, "+=10,*=24,-=2\n");
}

// 2. Interface with a default method body that calls an abstract one.
#[test]
fn interface_default_method() {
    let src = r#"
interface Greeter {
    fun name(): String
    fun greet(): String = "hello, ${name()}!"
}

class Anna : Greeter { override fun name(): String = "Anna" }
class Beth : Greeter { override fun name(): String = "Beth" }

fun main() { println("${Anna().greet()}|${Beth().greet()}") }
"#;
    assert_klio("interface_default_method", src, "hello, Anna!|hello, Beth!\n");
}

// 3. Secondary constructor delegating to the primary one.
#[test]
fn secondary_ctor_delegation() {
    let src = r#"
class Point(val x: Int, val y: Int) {
    constructor(both: Int) : this(both, both)
    constructor() : this(0)
    fun show(): String = "($x,$y)"
}

fun main() {
    println("${Point(3, 4).show()}|${Point(7).show()}|${Point().show()}")
}
"#;
    assert_klio("secondary_ctor", src, "(3,4)|(7,7)|(0,0)\n");
}

// 4. Init block side-effecting through `println` (order matters).
//    Tracked as task #33: klio runs all property inits before init
//    blocks instead of interleaving in declaration order.
#[test]

fn init_block_order() {
    let src = r#"
class Loud(val tag: String) {
    init { println("init1:$tag") }
    val derived: Int = tag.length.also { println("derived:$it") }
    init { println("init2:$tag") }
}

fun main() {
    val l = Loud("hi")
    println("done(${l.derived})")
}
"#;
    assert_klio(
        "init_block_order",
        src,
        "init1:hi\nderived:2\ninit2:hi\ndone(2)\n",
    );
}

// 5. Open base with two overrides, dispatched via base reference
//    (virtual dispatch).
#[test]
fn virtual_dispatch_open_chain() {
    let src = r#"
open class A {
    open fun describe(): String = "A"
    fun wrap(): String = "[${describe()}]"
}
open class B : A() { override fun describe(): String = "B" }
class C : B() { override fun describe(): String = "C(" + super.describe() + ")" }

fun probe(a: A): String = a.wrap()

fun main() {
    println("${probe(A())}|${probe(B())}|${probe(C())}")
}
"#;
    assert_klio("virtual_dispatch", src, "[A]|[B]|[C(B)]\n");
}

// 6. Generic constraints: `<T : Number>` plus a separate `where`
//    clause on the same type parameter.
#[test]
fn generic_number_with_constraints() {
    let src = r#"
fun <T> avg(xs: List<T>): Double where T : Number, T : Comparable<T> =
    if (xs.isEmpty()) 0.0 else xs.map { it.toDouble() }.sum() / xs.size

fun main() {
    println("${avg(listOf(1, 2, 3, 4))} ${avg(listOf<Int>())}")
}
"#;
    assert_klio("generic_number_constraints", src, "2.5 0.0\n");
}

// 7. Object singleton as a strategy pattern target.
#[test]
fn object_singleton_strategy() {
    let src = r#"
interface Strategy { fun name(): String; fun apply(x: Int): Int }

object Doubler : Strategy {
    override fun name(): String = "x2"
    override fun apply(x: Int): Int = x * 2
}

object Inc : Strategy {
    override fun name(): String = "inc"
    override fun apply(x: Int): Int = x + 1
}

fun run(s: Strategy, x: Int): String = "${s.name()}=${s.apply(x)}"

fun main() {
    println("${run(Doubler, 4)}|${run(Inc, 4)}")
}
"#;
    assert_klio("object_singleton_strategy", src, "x2=8|inc=5\n");
}

// 8. `companion object` implementing an interface so the class
//    name acts as a value of that interface.
#[test]
fn companion_implements_interface() {
    let src = r#"
interface Factory<T> { fun create(seed: Int): T }
class Item(val v: Int) {
    companion object : Factory<Item> {
        override fun create(seed: Int): Item = Item(seed * 3)
    }
    fun show(): String = "Item($v)"
}

fun <T> make(f: Factory<T>, seed: Int): T = f.create(seed)

fun main() {
    println(make(Item, 5).show())
}
"#;
    assert_klio("companion_implements_interface", src, "Item(15)\n");
}

// 9. Generic `in` variance: a `Comparator<in T>` accepts a wider
//    Comparator.
#[test]
fn generic_in_variance_comparator() {
    let src = r"
fun interface Comparer<in T> { fun compare(a: T, b: T): Int }

fun <T> pickMax(a: T, b: T, c: Comparer<T>): T = if (c.compare(a, b) >= 0) a else b

fun main() {
    val byNum: Comparer<Number> = Comparer { x, y -> x.toDouble().compareTo(y.toDouble()) }
    // Comparer<Number> accepted as Comparer<Int> via `in` variance.
    println(pickMax(3, 7, byNum))
}
";
    assert_klio("generic_in_variance", src, "7\n");
}

// 10. `for` loop iterating a sealed enum + indexed access on a List.
#[test]
fn enum_iteration_and_indexing() {
    let src = r#"
enum class Color { Red, Green, Blue }

fun main() {
    val names = listOf("R", "G", "B")
    val sb = StringBuilder()
    for ((i, c) in Color.entries.withIndex()) sb.append("${c.name}=${names[i]};")
    println(sb)
}
"#;
    assert_klio("enum_iteration_indexing", src, "Red=R;Green=G;Blue=B;\n");
}
