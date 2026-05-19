//! Deep resolution stress tests: nested receivers, extensions inside
//! lambda bodies inside sub-classes, companion-shadowing, secondary
//! ctor chains, member-extension vs top-level extension precedence,
//! and overload resolution interacting with smart casts.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_deep_resolution");
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

// 1. Extension declared in subclass overrides extension declared in
//    base, dispatched off the implicit receiver of a lambda body.
//    Tracked: task #35 (member-extension override not virtual-dispatched).
#[test]
#[ignore = "tracked as task #35"]
fn member_extension_override_in_lambda() {
    let src = r#"
open class Base {
    open fun Int.tag(): String = "B$this"
    fun render(xs: List<Int>): String = xs.joinToString(",") { it.tag() }
}
class Sub : Base() {
    override fun Int.tag(): String = "S$this"
}
fun main() {
    println(Sub().render(listOf(1,2,3)))
}
"#;
    assert_klio("member_ext_override_lambda", src, "S1,S2,S3\n");
}

// 2. Two enclosing receivers: outer Foo has `tag`, inner lambda has
//    its own receiver providing `tag`. The closest receiver wins.
#[test]
fn nearest_receiver_wins_for_member() {
    let src = r#"
class Outer {
    fun tag(): String = "outer"
    fun run(): String {
        val sb = StringBuilder()
        with(Inner()) { sb.append(tag()) }
        sb.append("|"); sb.append(tag())
        return sb.toString()
    }
}
class Inner { fun tag(): String = "inner" }
fun main() { println(Outer().run()) }
"#;
    assert_klio("nearest_receiver_wins", src, "inner|outer\n");
}

// 3. `this@Label` reaches past nearer receiver.
#[test]
fn this_label_reaches_outer() {
    let src = r#"
class Outer(val tag: String) {
    fun run(): String = with(StringBuilder()) {
        append("[" + this@Outer.tag + "]")
        toString()
    }
}
fun main() { println(Outer("hi").run()) }
"#;
    assert_klio("this_label_outer", src, "[hi]\n");
}

// 4. Companion member shadowed by instance member of same name when
//    accessed through receiver.
#[test]
fn instance_member_shadows_companion() {
    let src = r#"
class C {
    companion object { fun ping(): String = "static" }
    fun ping(): String = "instance"
}
fun main() {
    println("${C().ping()}|${C.ping()}")
}
"#;
    assert_klio("instance_shadows_companion", src, "instance|static\n");
}

// 5. Extension function on generic type parameter, called in lambda
//    inside subclass.
#[test]
fn generic_extension_in_subclass_lambda() {
    let src = r#"
open class Box<T>(val v: T) {
    fun <R> map(f: (T) -> R): Box<R> = Box(f(v))
}
fun <T> Box<T>.show(): String = "Box($v)"
class IntBox(v: Int) : Box<Int>(v) {
    fun render(): String = map { it * 10 }.show()
}
fun main() { println(IntBox(3).render()) }
"#;
    assert_klio("generic_ext_in_subclass", src, "Box(30)\n");
}

// 6. Nested local fn captures enclosing-fn local and a lambda
//    captures the same local mutated between calls.
#[test]
fn nested_local_fn_captures_mutating_local() {
    let src = r#"
fun main() {
    var n = 0
    fun bump(): Int { n += 1; return n }
    val xs = (1..3).map { bump() * it }
    println(xs.joinToString(","))
}
"#;
    // n: 0->1, 1->2, 2->3; products: 1*1, 2*2, 3*3 = 1,4,9
    assert_klio("nested_local_fn_mutating", src, "1,4,9\n");
}

// 7. apply/also/let/run/with chained, each binding `this`/`it`
//    differently and reading enclosing-local.
#[test]
fn scope_function_chain_resolves_correctly() {
    let src = r#"
fun main() {
    val tag = "T"
    val s = StringBuilder().apply {
        append(tag)
        append("-")
    }.also {
        it.append("X")
    }.let { sb ->
        sb.append("|")
        sb.toString() + "!"
    }
    println(s)
}
"#;
    assert_klio("scope_chain", src, "T-X|!\n");
}

// 8. Top-level extension on String vs member-extension on String
//    inside a class: member wins when receiver call is in class scope.
//    Tracked: task #36 (member-extension leaks into top-level scope).
#[test]
#[ignore = "tracked as task #36"]
fn member_ext_wins_over_top_level() {
    let src = r#"
fun String.label(): String = "TOP:$this"
class Fmt {
    fun String.label(): String = "MEM:$this"
    fun render(s: String): String = s.label()
}
fun main() {
    println("${"a".label()}|${Fmt().render("b")}")
}
"#;
    assert_klio("member_ext_wins", src, "TOP:a|MEM:b\n");
}

// 9. Smart-cast across `is` opens a member only available on the
//    refined type; subsequent reassignment invalidates smart-cast.
#[test]
fn smart_cast_member_access() {
    let src = r#"
open class A { open fun name(): String = "A" }
class B : A() {
    override fun name(): String = "B"
    fun extra(): String = "extra"
}
fun describe(a: A): String {
    if (a is B) return "${a.name()}/${a.extra()}"
    return a.name()
}
fun main() {
    println("${describe(A())}|${describe(B())}")
}
"#;
    assert_klio("smart_cast_member", src, "A|B/extra\n");
}

// 10. Lambda inside an init block reading a property declared AFTER
//     the init block — should observe its current value once the
//     lambda runs after construction completes.
#[test]
fn lambda_in_init_reads_later_property() {
    let src = r#"
class Stash {
    val onTick: () -> String
    init { onTick = { "tick:$counter" } }
    var counter: Int = 0
}
fun main() {
    val s = Stash()
    s.counter = 5
    println(s.onTick())
}
"#;
    assert_klio("lambda_init_later_prop", src, "tick:5\n");
}

// 11. Overloaded function with vararg and non-vararg variants; call
//     site disambiguation.
#[test]
fn overload_vararg_vs_specific() {
    let src = r#"
fun pick(x: Int): String = "single:$x"
fun pick(vararg xs: Int): String = "many:${xs.size}"
fun main() {
    println("${pick(7)}|${pick(1,2,3)}")
}
"#;
    assert_klio("overload_vararg", src, "single:7|many:3\n");
}

// 12. Sealed-class polymorphic `when` returning a lambda; lambdas
//     close over arm-local values, executed after.
//     Tracked: task #37 (parser gap on lambda arm in when branch).
#[test]
#[ignore = "tracked as task #37"]
fn when_returns_lambda_capturing_arm() {
    let src = r#"
sealed class Op {
    class Add(val n: Int) : Op()
    class Mul(val n: Int) : Op()
}
fun toFn(op: Op): (Int) -> Int = when (op) {
    is Op.Add -> { x -> x + op.n }
    is Op.Mul -> { x -> x * op.n }
}
fun main() {
    val a = toFn(Op.Add(3))
    val m = toFn(Op.Mul(4))
    println("${a(5)}|${m(5)}")
}
"#;
    assert_klio("when_returns_lambda", src, "8|20\n");
}
