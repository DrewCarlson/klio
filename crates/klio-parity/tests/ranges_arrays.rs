//! Ranges, arrays, progressions, and primitive array specializations.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_ranges_arrays");
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
fn intArray_init_pattern() {
    let src = r#"
fun main() {
    val xs = IntArray(5) { it * it }
    println(xs.joinToString(","))
}
"#;
    assert_klio("intArray_init", src, "0,1,4,9,16\n");
}

#[test]
fn array_of_primitives_sum() {
    let src = r#"
fun main() {
    val xs = intArrayOf(3,1,4,1,5,9,2,6)
    println("sum=${xs.sum()} max=${xs.max()} avg=${xs.average()}")
}
"#;
    assert_klio("prim_arr", src, "sum=31 max=9 avg=3.875\n");
}

#[test]
fn range_step_explicit() {
    let src = r#"
fun main() {
    val sb = StringBuilder()
    for (i in 1..15 step 2) sb.append("$i,")
    sb.append("|")
    for (i in 10 downTo 1 step 3) sb.append("$i,")
    println(sb)
}
"#;
    assert_klio("range_step", src, "1,3,5,7,9,11,13,15,|10,7,4,1,\n");
}

#[test]
fn until_range_exclusive() {
    let src = r#"
fun main() {
    val sb = StringBuilder()
    for (i in 0 until 5) sb.append("$i,")
    println(sb)
}
"#;
    assert_klio("until", src, "0,1,2,3,4,\n");
}

#[test]
fn char_range_iteration() {
    let src = r#"
fun main() {
    val sb = StringBuilder()
    for (c in 'a'..'e') sb.append(c)
    println(sb)
}
"#;
    assert_klio("char_range", src, "abcde\n");
}

#[test]
#[ignore = "tracked as task #54"]
fn array_copy_and_slice() {
    let src = r#"
fun main() {
    val xs = intArrayOf(10,20,30,40,50)
    val slice = xs.sliceArray(1..3)
    println(slice.joinToString(","))
}
"#;
    assert_klio("slice", src, "20,30,40\n");
}

#[test]
#[ignore = "tracked as task #54"]
fn arrayOfNulls_works() {
    let src = r#"
fun main() {
    val arr = arrayOfNulls<String>(3)
    arr[0] = "a"; arr[2] = "c"
    println(arr.joinToString(",") { it ?: "_" })
}
"#;
    assert_klio("arr_nulls", src, "a,_,c\n");
}

#[test]
fn range_contains_check() {
    let src = r#"
fun main() {
    val r = 1..10
    println("${5 in r},${15 in r},${(1..3).contains(2)}")
}
"#;
    assert_klio("range_in", src, "true,false,true\n");
}

#[test]
#[ignore = "tracked as task #54"]
fn int_array_indexed_iter() {
    let src = r#"
fun main() {
    val xs = intArrayOf(10,20,30)
    val sb = StringBuilder()
    for ((i, v) in xs.withIndex()) sb.append("$i=$v;")
    println(sb)
}
"#;
    assert_klio("withIndex", src, "0=10;1=20;2=30;\n");
}

#[test]
fn double_array_operations() {
    let src = r#"
fun main() {
    val xs = doubleArrayOf(1.5, 2.5, 3.5, 4.5)
    println("sum=${xs.sum()} avg=${xs.average()}")
}
"#;
    assert_klio("double_arr", src, "sum=12.0 avg=3.0\n");
}
