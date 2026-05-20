//! Null safety, smart casts after null checks, type-erased nullable
//! receivers, elvis returns, !! assertion.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_nullability_deep");
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
fn double_bang_throws_npe() {
    let src = r#"
fun main() {
    val s: String? = null
    try { val r = s!!; println(r) }
    catch (e: NullPointerException) { println("npe") }
}
"#;
    assert_klio("double_bang", src, "npe\n");
}

#[test]
fn elvis_with_early_return() {
    let src = r#"
fun lookup(m: Map<String, Int>, k: String): String {
    val v = m[k] ?: return "missing"
    return "found=$v"
}
fun main() {
    val m = mapOf("a" to 1)
    println("${lookup(m, "a")}|${lookup(m, "b")}")
}
"#;
    assert_klio("elvis_return", src, "found=1|missing\n");
}

#[test]
fn nullable_chain_let_and_takeIf() {
    let src = r#"
fun classify(n: Int?): String =
    n?.takeIf { it > 0 }?.let { "+$it" } ?: "n/a"
fun main() {
    println("${classify(5)}|${classify(0)}|${classify(null)}")
}
"#;
    assert_klio("nullable_let_takeIf", src, "+5|n/a|n/a\n");
}

#[test]
fn null_safe_through_collection() {
    let src = r#"
fun main() {
    val xs: List<String?> = listOf("a", null, "b", null, "c")
    val nn = xs.filterNotNull()
    val rendered = xs.joinToString(",") { it ?: "<n>" }
    println("$nn|$rendered")
}
"#;
    assert_klio("filterNotNull", src, "[a, b, c]|a,<n>,b,<n>,c\n");
}

#[test]
fn nullable_receiver_extension() {
    let src = r#"
fun String?.orPlaceholder(): String = this ?: "<null>"
fun main() {
    val a: String? = "kotlin"; val b: String? = null
    println("${a.orPlaceholder()}|${b.orPlaceholder()}")
}
"#;
    assert_klio("nullable_ext", src, "kotlin|<null>\n");
}

#[test]
fn safe_cast_through_when() {
    let src = r#"
fun describe(x: Any?): String = when (x) {
    is String -> "S:$x"
    is Int -> "I:$x"
    null -> "null"
    else -> "?"
}
fun main() {
    println(listOf<Any?>("hi", 5, null, 3.14).joinToString(",") { describe(it) })
}
"#;
    assert_klio("smart_when", src, "S:hi,I:5,null,?\n");
}

#[test]
fn null_safe_index_access() {
    let src = r#"
fun main() {
    val m: Map<String, List<Int>?> = mapOf("a" to listOf(1,2,3), "b" to null)
    val a = m["a"]?.get(1)
    val b = m["b"]?.get(0)
    val c = m["c"]?.get(0)
    println("$a,$b,$c")
}
"#;
    assert_klio("null_index", src, "2,null,null\n");
}

#[test]
#[ignore = "tracked as task #44 (isInitialized)"]
fn lateinit_var_uninitialized_check() {
    let src = r#"
class Box {
    lateinit var s: String
    fun maybeSet(set: Boolean) { if (set) s = "ok" }
    fun get(): String = if (::s.isInitialized) s else "uninit"
}
fun main() {
    val a = Box(); val b = Box()
    a.maybeSet(true); b.maybeSet(false)
    println("${a.get()}|${b.get()}")
}
"#;
    assert_klio("lateinit_check", src, "ok|uninit\n");
}
