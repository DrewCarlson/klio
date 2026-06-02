//! String manipulation, number parsing, regex, char operations.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_strings_numbers");
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
fn string_split_and_join() {
    let src = r#"
fun main() {
    val s = "a,b,c,d"
    val parts = s.split(",")
    val rejoined = parts.joinToString("|")
    println("$parts|$rejoined")
}
"#;
    assert_klio("split_join", src, "[a, b, c, d]|a|b|c|d\n");
}

#[test]
fn string_substring_operations() {
    let src = r#"
fun main() {
    val s = "Kotlin is fun"
    println("${s.length},${s.substring(0,6)},${s.startsWith("Kotlin")},${s.endsWith("fun")},${s.indexOf("is")}")
}
"#;
    assert_klio("substr", src, "13,Kotlin,true,true,7\n");
}

#[test]
fn string_template_complex() {
    let src = r#"
data class P(val x: Int, val y: Int)
fun main() {
    val p = P(3, 4)
    val s = "p=($p) sum=${p.x + p.y} cond=${if (p.x > p.y) "x" else "y"}"
    println(s)
}
"#;
    assert_klio("string_template", src, "p=(P(x=3, y=4)) sum=7 cond=y\n");
}

#[test]
fn char_arithmetic_and_compare() {
    let src = r#"
fun main() {
    val c1 = 'a'
    val c2 = 'A'
    println("${c1 - c2},${c1 + 3},${c1.code},${c1.isLetter()},${c1.uppercaseChar()}")
}
"#;
    assert_klio("char_arith", src, "32,d,97,true,A\n");
}

#[test]
fn number_parsing_and_formatting() {
    let src = r#"
fun main() {
    val a = "42".toInt()
    val b = "3.14".toDouble()
    val c = "ff".toInt(16)
    val d = "1010".toInt(2)
    println("$a,$b,$c,$d")
}
"#;
    assert_klio("num_parsing", src, "42,3.14,255,10\n");
}

#[test]
fn integer_overflow_signed() {
    let src = r#"
fun main() {
    val max = Int.MAX_VALUE
    val ov = max + 1
    val min = Int.MIN_VALUE
    val ov2 = min - 1
    println("$max,$ov,$min,$ov2")
}
"#;
    assert_klio(
        "int_overflow",
        src,
        "2147483647,-2147483648,-2147483648,2147483647\n",
    );
}

#[test]
fn long_double_arithmetic() {
    let src = r#"
fun main() {
    val l: Long = 1_000_000L * 1_000_000L
    val d: Double = 1.5 * 2.5
    println("$l,$d")
}
"#;
    assert_klio("long_dbl", src, "1000000000000,3.75\n");
}

#[test]
fn string_replace_and_trim() {
    let src = r#"
fun main() {
    val s = "  Hello, World!  "
    val t = s.trim()
    val r = t.replace("World", "Kotlin")
    println("[$t]|[$r]")
}
"#;
    assert_klio("replace_trim", src, "[Hello, World!]|[Hello, Kotlin!]\n");
}

#[test]
fn raw_string_with_indent() {
    let src = r#"
fun main() {
    val r = """
        line1
        line2
        line3""".trimIndent()
    println(r)
}
"#;
    assert_klio("raw_indent", src, "line1\nline2\nline3\n");
}

#[test]
fn string_to_list_chars() {
    let src = r#"
fun main() {
    val s = "hello"
    val chars = s.toList()
    val rev = chars.reversed().joinToString("")
    println("${chars.size}|$rev")
}
"#;
    assert_klio("str_to_chars", src, "5|olleh\n");
}
