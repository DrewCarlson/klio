//! Interpreter fixes surfaced while implementing kotlinx.io.files:
//! mixed Int/Long ranges, and interface-declared default args filled
//! for an anonymous-object override (the build-time fold only covers
//! methods in the class table, not a per-object synthetic class).

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_interp_default_and_range");
    std::fs::create_dir_all(&dir).expect("mkdir");
    let file = dir.join(format!("{name}.kt"));
    let mut f = std::fs::File::create(&file).expect("create");
    f.write_all(src.as_bytes()).expect("write");
    file
}

fn assert_klio(name: &str, src: &str, expected: &str) {
    let file = write_src(name, src);
    let got = klio_parity::run_with_packs(&file)
        .unwrap_or_else(|e| panic!("klio run failed for `{name}`: {e}"));
    assert_eq!(got, expected, "klio output for `{name}` did not match");
    if let Ok(report) = klio_parity::check(&file) {
        assert!(
            report.matched,
            "kotlinc parity mismatch for `{name}`\n{}",
            klio_parity::render_diff(&report)
        );
    }
}

#[test]
fn mixed_int_long_ranges() {
    let src = r#"
fun main() {
    val n: Long = 5L
    var s = ""
    for (i in 0..n) s += i
    println(s)
    var t = ""
    for (i in 0L..3) t += i
    println(t)
    var u = ""
    for (i in 0 until n) u += i
    println(u)
}
"#;
    assert_klio("mixed_ranges", src, "012345\n0123\n01234\n");
}

#[test]
fn anon_object_fills_interface_default() {
    let src = r#"
interface Greeter {
    fun greet(name: String, loud: Boolean = false): String
}
fun main() {
    val g = object : Greeter {
        override fun greet(name: String, loud: Boolean): String =
            if (loud) "HI $name" else "hi $name"
    }
    println(g.greet("a"))
    println(g.greet("b", true))
}
"#;
    assert_klio("anon_default", src, "hi a\nHI b\n")
}

#[test]
fn anon_object_two_level_default() {
    let src = r#"
interface FS { fun open(path: String, append: Boolean = false): String }
abstract class BaseFS : FS
fun main() {
    val fs = object : BaseFS() {
        override fun open(path: String, append: Boolean): String = "$path|$append"
    }
    println(fs.open("f"))
    println(fs.open("g", true))
}
"#;
    assert_klio("anon_2level", src, "f|false\ng|true\n")
}
