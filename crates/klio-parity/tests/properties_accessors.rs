//! Property + accessor parity: custom getters/setters, backing-field
//! mutation, computed properties, lateinit, delegate setValue, open
//! property override with getter.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_properties_accessors");
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
fn custom_getter_setter_with_backing_field() {
    let src = r#"
class Counter {
    private var _value: Int = 0
    var value: Int
        get() = _value
        set(v) { if (v >= 0) _value = v }
}
fun main() {
    val c = Counter()
    c.value = 5
    c.value = -3  // ignored
    c.value = 10
    println(c.value)
}
"#;
    assert_klio("custom_get_set", src, "10\n");
}

#[test]
fn computed_property_from_other_props() {
    let src = r#"
class Rect(val w: Int, val h: Int) {
    val area: Int get() = w * h
    val perimeter: Int get() = 2 * (w + h)
}
fun main() {
    val r = Rect(3, 4)
    println("${r.area} ${r.perimeter}")
}
"#;
    assert_klio("computed_prop", src, "12 14\n");
}

#[test]
fn override_open_property_with_getter() {
    let src = r#"
open class Animal { open val sound: String get() = "?" }
class Dog : Animal() { override val sound: String get() = "woof" }
class Cat : Animal() { override val sound: String get() = "meow" }
fun main() {
    val xs: List<Animal> = listOf(Dog(), Cat(), Animal())
    println(xs.joinToString(",") { it.sound })
}
"#;
    assert_klio("open_prop_getter", src, "woof,meow,?\n");
}

#[test]
fn backing_field_field_keyword() {
    let src = r#"
class Box {
    var x: Int = 0
        set(v) { field = if (v >= 0) v else 0 }
}
fun main() {
    val b = Box()
    b.x = 7
    b.x = -3
    println(b.x)
}
"#;
    assert_klio("field_keyword", src, "0\n");
}

#[test]
#[ignore = "tracked as task #57"]
fn property_initializer_runs_once() {
    let src = r#"
var initCount = 0
class P {
    val tag: String = run { initCount += 1; "tag${initCount}" }
}
fun main() {
    val a = P()
    val b = P()
    println("${a.tag},${b.tag},count=$initCount")
}
"#;
    assert_klio("prop_init_once", src, "tag1,tag2,count=2\n");
}

#[test]
fn extension_property_with_getter() {
    let src = r#"
val String.firstWord: String get() = split(" ").first()
fun main() {
    println("hello world".firstWord)
}
"#;
    assert_klio("ext_prop_getter", src, "hello\n");
}

#[test]
fn lazy_property_delegate() {
    let src = r#"
class Heavy {
    val expensive: String by lazy { "computed" }
}
fun main() {
    val h = Heavy()
    println(h.expensive)
    println(h.expensive)
}
"#;
    assert_klio("lazy_delegate", src, "computed\ncomputed\n");
}

#[test]
fn property_with_secondary_setter_logic() {
    let src = r#"
class Temperature {
    var celsius: Double = 0.0
        set(v) { field = v; recompute() }
    var fahrenheit: Double = 32.0
        private set
    private fun recompute() { fahrenheit = celsius * 9 / 5 + 32 }
}
fun main() {
    val t = Temperature()
    t.celsius = 100.0
    println("${t.celsius} ${t.fahrenheit}")
}
"#;
    assert_klio("temp_prop", src, "100.0 212.0\n");
}
