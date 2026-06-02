//! Interface contracts, default methods, fun interfaces, and access through
//! upcast/downcast.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_interfaces_visibility");
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
fn diamond_inheritance_explicit_super() {
    let src = r#"
interface A { fun ping(): String = "A" }
interface B { fun ping(): String = "B" }
class C : A, B {
    override fun ping(): String = super<A>.ping() + super<B>.ping()
}
fun main() { println(C().ping()) }
"#;
    assert_klio("diamond", src, "AB\n");
}

#[test]
fn fun_interface_lambda_conversion() {
    let src = r"
fun interface IntPred { fun test(x: Int): Boolean }
fun count(xs: List<Int>, p: IntPred): Int = xs.count { p.test(it) }
fun main() {
    val evens = count(listOf(1,2,3,4,5,6)) { it % 2 == 0 }
    println(evens)
}
";
    assert_klio("fun_iface", src, "3\n");
}

#[test]
fn interface_property_via_getter() {
    let src = r#"
interface Named { val name: String; val length: Int get() = name.length }
class P(override val name: String) : Named
fun main() {
    val p = P("kotlin")
    println("${p.name},${p.length}")
}
"#;
    assert_klio("iface_prop", src, "kotlin,6\n");
}

#[test]
fn abstract_with_protected_concrete() {
    let src = r#"
abstract class Shape {
    abstract fun area(): Double
    fun describe(): String = "area=${area()}"
}
class Circle(val r: Double) : Shape() { override fun area(): Double = r * r * 3.14 }
class Sq(val s: Double) : Shape() { override fun area(): Double = s * s }
fun main() {
    val xs: List<Shape> = listOf(Circle(2.0), Sq(3.0))
    println(xs.joinToString(";") { it.describe() })
}
"#;
    assert_klio("abstract_concrete", src, "area=12.56;area=9.0\n");
}

#[test]
fn upcast_then_downcast_safe() {
    let src = r#"
open class Animal(val name: String)
class Dog(name: String, val breed: String) : Animal(name)
fun main() {
    val a: Animal = Dog("Rex", "Pug")
    val d = a as? Dog
    val cat = a as? Cat
    println("${d?.breed},${cat?.name}")
}
class Cat(name: String) : Animal(name)
"#;
    assert_klio("upcast_safe", src, "Pug,null\n");
}

#[test]
fn sealed_class_exhaustive_when() {
    let src = r#"
sealed class Event {
    class Click(val x: Int, val y: Int) : Event()
    class Key(val k: Char) : Event()
    object Tick : Event()
}
fun render(e: Event): String = when (e) {
    is Event.Click -> "click(${e.x},${e.y})"
    is Event.Key -> "key=${e.k}"
    Event.Tick -> "tick"
}
fun main() {
    val xs = listOf(Event.Click(1,2), Event.Key('a'), Event.Tick)
    println(xs.joinToString("|") { render(it) })
}
"#;
    assert_klio("sealed_exh", src, "click(1,2)|key=a|tick\n");
}

#[test]
fn interface_implementation_through_property_delegation() {
    let src = r#"
interface Pinger { fun ping(): String }
class DelegPinger(p: Pinger) : Pinger by p
class HelloP : Pinger { override fun ping(): String = "Hello" }
fun main() {
    val p = DelegPinger(HelloP())
    println(p.ping())
}
"#;
    assert_klio("iface_deleg", src, "Hello\n");
}

#[test]
fn data_class_component_n() {
    let src = r#"
data class Point(val x: Int, val y: Int, val z: Int)
fun main() {
    val p = Point(1,2,3)
    val (a, b, c) = p
    println("$a,$b,$c")
}
"#;
    assert_klio("dest_data", src, "1,2,3\n");
}
