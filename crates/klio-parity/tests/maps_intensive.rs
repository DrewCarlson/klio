//! Map manipulation: iteration, mutation, key/value views, mapValues,
//! filterKeys/filterValues, getOrPut, entries destructuring.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_maps_intensive");
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
fn map_iteration_ordered() {
    let src = r#"
fun main() {
    val m = mapOf("a" to 1, "b" to 2, "c" to 3)
    val sb = StringBuilder()
    for ((k, v) in m) sb.append("$k=$v;")
    println(sb)
}
"#;
    assert_klio("map_iter", src, "a=1;b=2;c=3;\n");
}

#[test]
fn map_filter_keys_values() {
    let src = r#"
fun main() {
    val m = mapOf("a" to 1, "b" to 2, "c" to 3, "d" to 4)
    val keyFilt = m.filterKeys { it > "b" }
    val valFilt = m.filterValues { it % 2 == 0 }
    println("$keyFilt|$valFilt")
}
"#;
    assert_klio("map_filter", src, "{c=3, d=4}|{b=2, d=4}\n");
}

#[test]
fn map_map_values_chain() {
    let src = r#"
fun main() {
    val m = mapOf("x" to 1, "y" to 2, "z" to 3)
    val squared = m.mapValues { it.value * it.value }
    println(squared)
}
"#;
    assert_klio("map_values", src, "{x=1, y=4, z=9}\n");
}

#[test]
fn mutable_map_get_or_put() {
    let src = r#"
fun main() {
    val cache = mutableMapOf<String, Int>()
    val a = cache.getOrPut("k") { 10 }
    val b = cache.getOrPut("k") { 99 }  // already there, lambda not invoked
    println("$a,$b,${cache.size}")
}
"#;
    assert_klio("getOrPut", src, "10,10,1\n");
}

#[test]
fn map_to_list_and_pairs() {
    let src = r#"
fun main() {
    val m = mapOf("a" to 1, "b" to 2)
    val pairs = m.toList()
    val joined = pairs.joinToString(",") { "${it.first}=${it.second}" }
    println(joined)
}
"#;
    assert_klio("map_to_list", src, "a=1,b=2\n");
}

#[test]
fn map_entries_destructuring() {
    let src = r#"
fun main() {
    val m = mapOf("a" to 1, "b" to 2, "c" to 3)
    val sb = StringBuilder()
    for ((k, v) in m.entries) sb.append("$k:$v ")
    println(sb.toString().trim())
}
"#;
    assert_klio("entries_dest", src, "a:1 b:2 c:3\n");
}

#[test]
fn map_plus_minus_operators() {
    let src = r#"
fun main() {
    val a = mapOf("x" to 1, "y" to 2)
    val b = a + ("z" to 3)
    val c = b - "x"
    println("$a|$b|$c")
}
"#;
    assert_klio(
        "map_plus_minus",
        src,
        "{x=1, y=2}|{x=1, y=2, z=3}|{y=2, z=3}\n",
    );
}

#[test]
fn map_count_and_any() {
    let src = r#"
fun main() {
    val m = mapOf("a" to 1, "b" to 2, "c" to 3, "d" to 4)
    val evens = m.count { (_, v) -> v % 2 == 0 }
    val anyHigh = m.any { (_, v) -> v > 3 }
    val allPositive = m.all { (_, v) -> v > 0 }
    println("$evens,$anyHigh,$allPositive")
}
"#;
    assert_klio("map_count_any", src, "2,true,true\n");
}
