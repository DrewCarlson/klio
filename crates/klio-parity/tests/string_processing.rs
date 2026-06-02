//! String processing parity: regex, padStart/padEnd, lines, take/drop,
//! Char conversions, String<->Bytes, format integers.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_string_processing");
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
fn string_pad_start_end() {
    let src = r#"
fun main() {
    println("${"3".padStart(5, '0')}|${"3".padEnd(5, '.')}")
}
"#;
    assert_klio("pad", src, "00003|3....\n");
}

#[test]
fn string_lines_and_take() {
    let src = r#"
fun main() {
    val s = "alpha\nbeta\ngamma\ndelta"
    val xs = s.lines()
    println("${xs.size}|${xs.take(2).joinToString(",")}|${xs.drop(2).joinToString("|")}")
}
"#;
    assert_klio("lines", src, "4|alpha,beta|gamma|delta\n");
}

#[test]
fn string_uppercase_lowercase() {
    let src = r#"
fun main() {
    val s = "Hello, World!"
    println("${s.uppercase()}|${s.lowercase()}")
}
"#;
    assert_klio("case", src, "HELLO, WORLD!|hello, world!\n");
}

#[test]
fn char_is_digit_letter() {
    let src = r#"
fun main() {
    val xs = "a1!Z9 ".toCharArray()
    val r = xs.map { "${it.isLetter()}/${it.isDigit()}" }
    println(r.joinToString(","))
}
"#;
    assert_klio(
        "char_isX",
        src,
        "true/false,false/true,false/false,true/false,false/true,false/false\n",
    );
}

#[test]
fn string_filter_count() {
    let src = r#"
fun main() {
    val s = "Hello, World! 123"
    val digits = s.filter { it.isDigit() }
    val n_letters = s.count { it.isLetter() }
    println("$digits|$n_letters")
}
"#;
    assert_klio("filter_count", src, "123|10\n");
}

#[test]
fn string_reverse_split() {
    let src = r#"
fun main() {
    val s = "abcdef"
    val r = s.reversed()
    val xs = "a,b,c,d".split(",")
    println("$r|$xs")
}
"#;
    assert_klio("reverse_split", src, "fedcba|[a, b, c, d]\n");
}

#[test]
fn string_concat_mixed_types() {
    let src = r#"
fun main() {
    val n = 42
    val pi = 3.14
    val ok = true
    println("n=$n pi=$pi ok=$ok ${1+2}")
}
"#;
    assert_klio("concat_mixed", src, "n=42 pi=3.14 ok=true 3\n");
}

#[test]
fn string_code_points_via_chars() {
    let src = r#"
fun main() {
    val s = "ABC"
    println(s.map { it.code }.joinToString(","))
}
"#;
    assert_klio("codepoints", src, "65,66,67\n");
}

#[test]
fn stringbuilder_chaining() {
    let src = r#"
fun main() {
    val sb = StringBuilder()
    sb.append("hello").append(", ").append("world").append("!")
    println(sb)
}
"#;
    assert_klio("sb_chain", src, "hello, world!\n");
}

#[test]
fn string_repeat_zero() {
    let src = r#"
fun main() {
    println("[${"x".repeat(0)}]|[${"y".repeat(3)}]")
}
"#;
    assert_klio("repeat_zero", src, "[]|[yyy]\n");
}
