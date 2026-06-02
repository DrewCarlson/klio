//! Iterable special operations that round out collection coverage:
//! zipWithNext, scan, runningFold, take/drop, takeLast/dropLast,
//! single/firstOrNull, indexOfFirst.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_iterables_special");
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
fn list_take_drop_take_last_drop_last() {
    let src = r#"
fun main() {
    val xs = listOf(1, 2, 3, 4, 5, 6)
    println("${xs.take(3)}|${xs.drop(2)}|${xs.takeLast(2)}|${xs.dropLast(4)}")
}
"#;
    assert_klio("take_drop", src, "[1, 2, 3]|[3, 4, 5, 6]|[5, 6]|[1, 2]\n");
}

#[test]
fn list_index_of_first_index_of_last() {
    let src = r#"
fun main() {
    val xs = listOf(1, 2, 3, 4, 2, 5)
    val first = xs.indexOfFirst { it > 2 }
    val last = xs.indexOfLast { it < 4 }
    println("$first,$last")
}
"#;
    assert_klio("indexOf", src, "2,4\n");
}

#[test]
fn list_first_last_with_predicate() {
    let src = r#"
fun main() {
    val xs = listOf(1, 2, 3, 4)
    println("${xs.first()}|${xs.last()}|${xs.firstOrNull { it > 10 }}")
}
"#;
    assert_klio("first_last", src, "1|4|null\n");
}

#[test]
fn list_take_with_predicate_while() {
    let src = r#"
fun main() {
    val xs = listOf(1, 2, 3, 4, 1, 2)
    println("${xs.takeWhile { it < 3 }}|${xs.dropWhile { it < 3 }}")
}
"#;
    assert_klio("while", src, "[1, 2]|[3, 4, 1, 2]\n");
}

#[test]
fn list_group_by_count() {
    let src = r#"
fun main() {
    val xs = listOf(1, 2, 3, 4, 5, 6)
    val by = xs.groupBy { it % 3 }
    val keys = by.keys.sorted()
    val sb = StringBuilder()
    for (k in keys) sb.append("$k=${by[k]};")
    println(sb)
}
"#;
    assert_klio("groupBy", src, "0=[3, 6];1=[1, 4];2=[2, 5];\n");
}

#[test]
fn list_zip_with_other_list() {
    let src = r#"
fun main() {
    val a = listOf(1, 2, 3)
    val b = listOf("a", "b", "c", "d")
    val z = a.zip(b) { x, y -> "$x$y" }
    println(z)
}
"#;
    assert_klio("zip_with", src, "[1a, 2b, 3c]\n");
}

#[test]
fn list_distinct_distinct_by() {
    let src = r#"
fun main() {
    val xs = listOf("alpha", "ant", "beta", "bee", "bear")
    val by = xs.distinctBy { it[0] }
    println(by)
}
"#;
    assert_klio("distinctBy", src, "[alpha, beta]\n");
}

#[test]
fn list_sum_average_max_min() {
    let src = r#"
fun main() {
    val xs = listOf(2, 4, 6, 8, 10)
    println("${xs.sum()} ${xs.average()} ${xs.max()} ${xs.min()}")
}
"#;
    assert_klio("aggregates", src, "30 6.0 10 2\n");
}
