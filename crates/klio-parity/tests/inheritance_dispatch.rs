//! Inheritance + dispatch parity: super calls, diamond, generic
//! inheritance, abstract/final/open interplay, companion through subclass.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_inheritance_dispatch");
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
fn super_call_in_override() {
    let src = r#"
open class A { open fun n(): String = "A" }
open class B : A() { override fun n(): String = "B-" + super.n() }
class C : B() { override fun n(): String = "C-" + super.n() }
fun main() { println(C().n()) }
"#;
    assert_klio("super_call", src, "C-B-A\n");
}

#[test]
fn interface_with_default_overridden() {
    let src = r#"
interface I { fun g(): String = "I" }
open class B : I { override fun g(): String = "B-" + super.g() }
class C : B() { override fun g(): String = "C-" + super.g() }
fun main() { println(C().g()) }
"#;
    assert_klio("iface_default", src, "C-B-I\n");
}

#[test]
fn generic_open_class_subclass_specialized() {
    let src = r#"
open class Container<T>(val v: T) { open fun render(): String = "$v" }
class IntC(v: Int) : Container<Int>(v) { override fun render(): String = "Int($v)" }
class StrC(v: String) : Container<String>(v) { override fun render(): String = "Str($v)" }
fun describe(c: Container<*>): String = c.render()
fun main() {
    println("${describe(IntC(3))}|${describe(StrC("hi"))}")
}
"#;
    assert_klio("generic_open", src, "Int(3)|Str(hi)\n");
}

#[test]
fn abstract_method_chain() {
    let src = r#"
abstract class Drawable {
    abstract fun area(): Int
    fun describe(): String = "area=${area()}"
}
class Sq(val s: Int) : Drawable() { override fun area(): Int = s * s }
class Rect(val w: Int, val h: Int) : Drawable() { override fun area(): Int = w * h }
fun main() {
    val xs: List<Drawable> = listOf(Sq(3), Rect(2,5))
    println(xs.joinToString(";") { it.describe() })
}
"#;
    assert_klio("abstract_chain", src, "area=9;area=10\n");
}

#[test]
fn open_property_overridden_with_init() {
    let src = r#"
open class P { open val tag: String = "base" }
class Q : P() { override val tag: String = "sub" }
fun main() { val p: P = Q(); println(p.tag) }
"#;
    assert_klio("open_property", src, "sub\n");
}

#[test]
fn companion_inherited_via_class_ref() {
    let src = r#"
open class Base { companion object { fun bye(): String = "BB" } }
class Sub : Base()
fun main() {
    println(Sub.bye())  // Kotlin allows accessing inherited companion thru class ref
}
"#;
    assert_klio("companion_inherit", src, "BB\n");
}

#[test]
fn polymorphic_collection_dispatch() {
    let src = r#"
open class Animal { open fun voice(): String = "?" }
class Dog : Animal() { override fun voice(): String = "woof" }
class Cat : Animal() { override fun voice(): String = "meow" }
class Snake : Animal() { override fun voice(): String = "hiss" }
fun main() {
    val pets: List<Animal> = listOf(Dog(), Cat(), Snake(), Dog())
    println(pets.joinToString(",") { it.voice() })
}
"#;
    assert_klio("polymorphic", src, "woof,meow,hiss,woof\n");
}

#[test]
fn deep_inheritance_with_init_order() {
    let src = r#"
open class A {
    init { println("A.init") }
    val x = "A.x".also { println("A.x") }
}
open class B : A() {
    init { println("B.init") }
    val y = "B.y".also { println("B.y") }
}
class C : B() {
    init { println("C.init") }
    val z = "C.z".also { println("C.z") }
}
fun main() { val c = C(); println("done:${c.x}${c.y}${c.z}") }
"#;
    assert_klio(
        "deep_init_order",
        src,
        "A.init\nA.x\nB.init\nB.y\nC.init\nC.z\ndone:A.xB.yC.z\n",
    );
}

#[test]
fn override_with_more_specific_generic() {
    let src = r"
open class Producer<T> { open fun make(): T? = null }
class IntP : Producer<Int>() { override fun make(): Int = 42 }
fun main() {
    val p: Producer<Int> = IntP()
    println(p.make())
}
";
    assert_klio("override_specific", src, "42\n");
}

#[test]
fn private_member_not_overridden() {
    let src = r#"
open class P {
    private fun hidden(): String = "P-hidden"
    open fun show(): String = hidden()
}
class S : P() {
    fun hidden(): String = "S-hidden"  // not actually an override (P.hidden is private)
    override fun show(): String = "S:" + super.show()
}
fun main() { println(S().show()) }
"#;
    assert_klio("private_not_overridden", src, "S:P-hidden\n");
}
