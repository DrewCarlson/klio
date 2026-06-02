//! Data class feature parity: copy with named args, equals/hashCode
//! by field, toString format, destructuring via componentN, copy with
//! all defaults.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_data_class_features");
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
fn data_class_copy_with_partial_override() {
    let src = r#"
data class P(val name: String, val age: Int, val role: String = "user")
fun main() {
    val a = P("Ann", 30)
    val b = a.copy(age = 31)
    val c = a.copy(role = "admin", age = 40)
    println("$a|$b|$c")
}
"#;
    assert_klio(
        "copy_partial",
        src,
        "P(name=Ann, age=30, role=user)|P(name=Ann, age=31, role=user)|P(name=Ann, age=40, role=admin)\n",
    );
}

#[test]
fn data_class_equality_structural() {
    let src = r#"
data class Pair2(val a: Int, val b: String)
fun main() {
    val p = Pair2(1, "x")
    val q = Pair2(1, "x")
    val r = Pair2(2, "x")
    println("${p == q},${p == r},${p === q}")
}
"#;
    assert_klio("eq_structural", src, "true,false,false\n");
}

#[test]
fn data_class_in_set_and_map() {
    let src = r#"
data class K(val v: Int)
fun main() {
    val s = setOf(K(1), K(2), K(1))
    val m = mutableMapOf<K, String>()
    m[K(1)] = "one"
    m[K(2)] = "two"
    println("${s.size}|${m[K(1)]}|${m[K(2)]}")
}
"#;
    assert_klio("data_set_map", src, "2|one|two\n");
}

#[test]
fn data_class_component_n_destructure() {
    let src = r#"
data class Triple3(val a: Int, val b: String, val c: Double)
fun main() {
    val t = Triple3(1, "x", 3.14)
    val (a, b, c) = t
    println("$a,$b,$c")
}
"#;
    assert_klio("componentN", src, "1,x,3.14\n");
}

#[test]
fn data_class_with_collection_property() {
    let src = r#"
data class Bag(val items: List<Int>)
fun main() {
    val a = Bag(listOf(1, 2, 3))
    val b = a.copy(items = a.items + 4)
    println("${a.items}|${b.items}")
}
"#;
    assert_klio("bag_copy", src, "[1, 2, 3]|[1, 2, 3, 4]\n");
}

#[test]
fn data_class_pattern_via_when() {
    let src = r#"
data class Event(val kind: String, val value: Int)
fun classify(e: Event): String = when {
    e.kind == "click" && e.value > 0 -> "click+"
    e.kind == "click" -> "click0"
    e.kind == "scroll" -> "scroll:${e.value}"
    else -> "other"
}
fun main() {
    val xs = listOf(Event("click", 3), Event("click", 0), Event("scroll", 7), Event("?", 0))
    println(xs.joinToString(",") { classify(it) })
}
"#;
    assert_klio("when_data", src, "click+,click0,scroll:7,other\n");
}
