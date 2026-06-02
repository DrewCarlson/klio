//! Named arguments, default values, varargs, mixed forms.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_named_args_defaults");
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
fn named_args_out_of_order() {
    let src = r#"
fun greet(name: String, prefix: String, suffix: String): String = "$prefix$name$suffix"
fun main() {
    val r = greet(suffix = "!", name = "Ann", prefix = ">>")
    println(r)
}
"#;
    assert_klio("named_oo", src, ">>Ann!\n");
}

#[test]
fn default_with_named_partial() {
    let src = r#"
fun fmt(n: Int, base: Int = 10, prefix: String = "", suffix: String = ""): String =
    "$prefix${n.toString(base)}$suffix"
fun main() {
    println("${fmt(15)}|${fmt(15, base = 16)}|${fmt(15, suffix = "!")}|${fmt(15, prefix = "0x", base = 16)}")
}
"#;
    assert_klio("default_named", src, "15|f|15!|0xf\n");
}

#[test]
fn vararg_with_named_after() {
    let src = r#"
fun build(first: String, vararg items: Int, last: String = "end"): String =
    "$first[${items.joinToString(",")}]$last"
fun main() {
    println(build("S", 1, 2, 3, last = "E"))
    println(build("S", last = "Z"))
}
"#;
    assert_klio("vararg_named", src, "S[1,2,3]E\nS[]Z\n");
}

#[test]
fn default_expression_references_prior_param() {
    let src = r#"
fun rect(w: Int, h: Int = w * 2, p: Int = 2 * (w + h)): String =
    "w=$w h=$h p=$p"
fun main() {
    println("${rect(3)}|${rect(3, 5)}|${rect(3, 5, 20)}")
}
"#;
    // rect(3): w=3, h=6, p=2*(3+6)=18
    // rect(3,5): w=3, h=5, p=2*8=16
    // rect(3,5,20): w=3, h=5, p=20
    assert_klio(
        "default_prior",
        src,
        "w=3 h=6 p=18|w=3 h=5 p=16|w=3 h=5 p=20\n",
    );
}

#[test]
fn lambda_default_arg() {
    let src = r#"
fun pick(n: Int, fallback: () -> Int = { 0 }): Int = if (n > 0) n else fallback()
fun main() {
    println("${pick(7)},${pick(-3)},${pick(-3) { 99 }}")
}
"#;
    assert_klio("lambda_default", src, "7,0,99\n");
}

#[test]
fn extension_with_named_args() {
    let src = r#"
fun String.padBoth(left: Int = 1, right: Int = 1, fill: Char = '.'): String =
    "${fill.toString().repeat(left)}$this${fill.toString().repeat(right)}"
fun main() {
    println("a".padBoth())
    println("a".padBoth(right = 3))
    println("a".padBoth(fill = '*', left = 2))
}
"#;
    assert_klio("ext_named", src, ".a.\n.a...\n**a*\n");
}

#[test]
fn data_class_copy_named_args() {
    let src = r#"
data class P(val x: Int = 0, val y: Int = 0, val tag: String = "")
fun main() {
    val a = P()
    val b = a.copy(x = 5)
    val c = a.copy(tag = "T")
    val d = a.copy(x = 1, y = 2, tag = "all")
    println("$a|$b|$c|$d")
}
"#;
    assert_klio(
        "data_copy_named",
        src,
        "P(x=0, y=0, tag=)|P(x=5, y=0, tag=)|P(x=0, y=0, tag=T)|P(x=1, y=2, tag=all)\n",
    );
}

#[test]
fn constructor_default_chained() {
    let src = r#"
class Cfg(val host: String = "localhost", val port: Int = 8080, val tls: Boolean = false) {
    fun render(): String = "${if (tls) "https" else "http"}://$host:$port"
}
fun main() {
    println(Cfg().render())
    println(Cfg("example.com").render())
    println(Cfg(port = 443, tls = true, host = "api.example.com").render())
}
"#;
    assert_klio(
        "ctor_default",
        src,
        "http://localhost:8080\nhttp://example.com:8080\nhttps://api.example.com:443\n",
    );
}
