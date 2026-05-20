//! Type-system parity: smart casts after combined conditions,
//! Any.toString, nullable Comparable, enum methods, sealed-class
//! with inherited fields, KClass equality, type parameter T.foo
//! resolution.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_type_system_shapes");
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
fn smart_cast_after_conjunction() {
    let src = r#"
fun describe(x: Any?, y: Any?): String =
    if (x is String && y is Int) "${x.length}/${y * 2}" else "no"
fun main() { println("${describe("hi", 5)}|${describe(null, 5)}|${describe("a", "b")}") }
"#;
    assert_klio("smart_conj", src, "2/10|no|no\n");
}

#[test]
fn any_toString_default_and_override() {
    let src = r#"
class Default
class Custom { override fun toString(): String = "custom!" }
fun main() {
    val d = Default()
    val c = Custom()
    val s = "$d|$c"
    // d.toString() defaults to Class@hash; just check shape with split
    val pipe = s.indexOf('|')
    println("${pipe > 0},${c.toString()}")
}
"#;
    assert_klio("any_toString", src, "true,custom!\n");
}

#[test]
fn nullable_comparable_chain() {
    let src = r#"
fun main() {
    val a: Int? = 3
    val b: Int? = null
    val r1 = (a ?: 0) + (b ?: 100)
    val r2 = listOfNotNull(a, b, 7).joinToString(",")
    println("$r1|$r2")
}
"#;
    assert_klio("nullable_cmp", src, "103|3,7\n");
}

#[test]
fn enum_class_method_dispatch() {
    let src = r#"
enum class Color {
    Red, Green, Blue;
    fun greeting(): String = "$name@$ordinal"
}
fun main() {
    val xs = Color.entries
    println(xs.joinToString(";") { it.greeting() })
}
"#;
    assert_klio("enum_method", src, "Red@0;Green@1;Blue@2\n");
}

#[test]
fn sealed_class_inherited_field() {
    let src = r#"
sealed class Cell(val pos: Int) {
    class Alive(pos: Int) : Cell(pos)
    class Dead(pos: Int) : Cell(pos)
}
fun render(c: Cell): String = when (c) {
    is Cell.Alive -> "A@${c.pos}"
    is Cell.Dead -> "D@${c.pos}"
}
fun main() {
    val xs = listOf(Cell.Alive(1), Cell.Dead(2), Cell.Alive(3))
    println(xs.joinToString(",") { render(it) })
}
"#;
    assert_klio("sealed_field", src, "A@1,D@2,A@3\n");
}

#[test]
fn kclass_simple_name() {
    let src = r#"
class Box(val v: Int)
fun main() {
    val b = Box(7)
    println("${b::class.simpleName},${Box::class.simpleName}")
}
"#;
    assert_klio("kclass_name", src, "Box,Box\n");
}

#[test]
fn type_parameter_method_resolution() {
    let src = r#"
fun <T : Comparable<T>> sorted(a: T, b: T): String = if (a <= b) "$a,$b" else "$b,$a"
fun main() {
    println("${sorted(3, 7)}|${sorted("z", "a")}")
}
"#;
    assert_klio("type_param", src, "3,7|a,z\n");
}

#[test]
fn nullable_iterable_filter() {
    let src = r#"
fun main() {
    val xs: List<Int?> = listOf(1, null, 2, null, 3)
    val sum = xs.filterNotNull().sum()
    println(sum)
}
"#;
    assert_klio("nullable_iter", src, "6\n");
}
