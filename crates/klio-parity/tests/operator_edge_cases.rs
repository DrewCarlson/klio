//! Operator edge cases and conversions.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_operator_edge_cases");
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
fn int_div_truncation_and_mod() {
    let src = r#"
fun main() {
    println("${7 / 2},${-7 / 2},${7 % 3},${-7 % 3},${7.0 / 2.0}")
}
"#;
    assert_klio("int_div", src, "3,-3,1,-1,3.5\n");
}

#[test]
fn integer_widening_int_to_long() {
    let src = r#"
fun main() {
    val a: Long = 5
    val b: Long = 1L + 2 * 3
    println("$a,$b")
}
"#;
    assert_klio("widening", src, "5,7\n");
}

#[test]
fn char_to_int_and_back() {
    let src = r#"
fun main() {
    val c = 'A'
    val n = c.code
    val back = (n + 1).toChar()
    println("$n,$back")
}
"#;
    assert_klio("char_int", src, "65,B\n");
}

#[test]
fn equality_vs_reference() {
    let src = r#"
fun main() {
    val a = "hello"
    val b = "hel" + "lo"
    val c = a
    println("${a == b},${a === c},${a === b}")
}
"#;
    // a === b can be true if Kotlin interns; but a == b structurally is true; === c is true (same ref)
    assert_klio("eq_ref", src, "true,true,true\n");
}

#[test]
fn bitwise_int_ops() {
    let src = r#"
fun main() {
    val a = 0b1100
    val b = 0b1010
    println("${a and b},${a or b},${a xor b},${a shl 2},${a shr 1}")
}
"#;
    assert_klio("bitwise", src, "8,14,6,48,6\n");
}

#[test]
fn boolean_short_circuit() {
    let src = r#"
fun main() {
    var counter = 0
    fun count(b: Boolean): Boolean { counter += 1; return b }
    val r1 = count(true) || count(true)
    val r2 = count(false) && count(true)
    println("$counter,$r1,$r2")
}
"#;
    // counter: true||... short circuits after 1 call; false&&... short circuits after 1 call. Total: 2
    assert_klio("short_circuit", src, "2,true,false\n");
}

#[test]
fn compareTo_returns_consistent() {
    let src = r#"
fun main() {
    val a = "apple"; val b = "banana"; val c = "apple"
    println("${a.compareTo(b)},${b.compareTo(a)},${a.compareTo(c)}")
}
"#;
    assert_klio("compareTo", src, "-1,1,0\n");
}

#[test]
fn string_repeat_and_concat() {
    let src = r#"
fun main() {
    val s = "ab".repeat(3)
    val t = "x" + "y" + "z"
    println("$s|$t")
}
"#;
    assert_klio("str_repeat", src, "ababab|xyz\n");
}
