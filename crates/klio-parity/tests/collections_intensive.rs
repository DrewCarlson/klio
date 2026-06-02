//! Collections-intensive parity: chain operations, fold variants,
//! windowed iteration, partitioning, sortedBy variants.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_collections_intensive");
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
fn fold_and_reduce() {
    let src = r#"
fun main() {
    val xs = listOf(1,2,3,4,5)
    val f = xs.fold(100) { acc, x -> acc + x }
    val r = xs.reduce { acc, x -> acc * x }
    println("$f|$r")
}
"#;
    assert_klio("fold_red", src, "115|120\n");
}

#[test]
fn associate_associate_by_associate_with() {
    let src = r#"
fun main() {
    val xs = listOf("ant", "bee", "cat")
    val ab = xs.associateBy { it[0] }
    val aw = xs.associateWith { it.length }
    val keys = ab.keys.sorted()
    val sb = StringBuilder()
    for (k in keys) sb.append("$k=${ab[k]};")
    sb.append("|")
    val keys2 = aw.keys.sorted()
    for (k in keys2) sb.append("$k=${aw[k]};")
    println(sb)
}
"#;
    assert_klio("assoc", src, "a=ant;b=bee;c=cat;|ant=3;bee=3;cat=3;\n");
}

#[test]
fn partition_into_two_lists() {
    let src = r#"
fun main() {
    val (evens, odds) = (1..10).partition { it % 2 == 0 }
    println("$evens|$odds")
}
"#;
    assert_klio("partition", src, "[2, 4, 6, 8, 10]|[1, 3, 5, 7, 9]\n");
}

#[test]
fn windowed_and_chunked() {
    let src = r#"
fun main() {
    val xs = (1..6).toList()
    val w = xs.windowed(3)
    val c = xs.chunked(2)
    println("$w|$c")
}
"#;
    assert_klio(
        "win_chunked",
        src,
        "[[1, 2, 3], [2, 3, 4], [3, 4, 5], [4, 5, 6]]|[[1, 2], [3, 4], [5, 6]]\n",
    );
}

#[test]
fn sorted_by_descending() {
    let src = r#"
fun main() {
    data class P(val name: String, val age: Int)
    val xs = listOf(P("Bob", 35), P("Ann", 22), P("Cal", 40))
    val byAge = xs.sortedBy { it.age }
    val byAgeDesc = xs.sortedByDescending { it.age }
    println(byAge.joinToString(",") { it.name })
    println(byAgeDesc.joinToString(",") { it.name })
}
"#;
    assert_klio("sortedBy", src, "Ann,Bob,Cal\nCal,Bob,Ann\n");
}

#[test]
fn map_get_or_default() {
    let src = r#"
fun main() {
    val m = mapOf("a" to 1, "b" to 2)
    val a = m.getOrDefault("a", -1)
    val z = m.getOrDefault("z", -1)
    val ek = m.getOrElse("c") { 999 }
    println("$a|$z|$ek")
}
"#;
    assert_klio("map_get_or", src, "1|-1|999\n");
}

#[test]
fn mutable_collection_operations() {
    let src = r#"
fun main() {
    val xs = mutableListOf(3,1,4,1,5,9,2,6)
    xs.sort()
    val unique = xs.toSet().toList()
    println("$xs|$unique")
}
"#;
    assert_klio(
        "mut_ops",
        src,
        "[1, 1, 2, 3, 4, 5, 6, 9]|[1, 2, 3, 4, 5, 6, 9]\n",
    );
}

#[test]
fn max_by_min_by_by_key() {
    let src = r#"
fun main() {
    val xs = listOf("ant", "elephant", "bear", "wolf")
    val longest = xs.maxByOrNull { it.length }
    val shortest = xs.minByOrNull { it.length }
    println("$longest|$shortest")
}
"#;
    assert_klio("max_min_by", src, "elephant|ant\n");
}

#[test]
fn map_filter_chain() {
    let src = r"
fun main() {
    val xs = (1..20)
        .map { it * it }
        .filter { it % 2 == 0 }
        .take(4)
    println(xs)
}
";
    assert_klio("chain", src, "[4, 16, 36, 64]\n");
}
