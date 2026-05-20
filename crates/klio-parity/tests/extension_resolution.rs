//! Extension function resolution: top-level vs member, generic
//! extension, extension on nullable, extension dispatched on
//! interface.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_extension_resolution");
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
fn extension_on_nullable_type() {
    let src = r#"
fun String?.orDefault(d: String): String = this ?: d
fun main() {
    val a: String? = "hi"
    val b: String? = null
    println("${a.orDefault("X")}|${b.orDefault("X")}")
}
"#;
    assert_klio("ext_nullable", src, "hi|X\n");
}

#[test]
fn extension_with_generic_bound() {
    let src = r#"
fun <T : Comparable<T>> List<T>.middle(): T = this[size / 2]
fun main() {
    println("${listOf(1,2,3,4,5).middle()}|${listOf("a","b","c").middle()}")
}
"#;
    assert_klio("ext_generic_bound", src, "3|b\n");
}

#[test]
fn extension_dispatched_on_interface() {
    let src = r#"
interface Named { val name: String }
fun Named.shout(): String = name.uppercase() + "!"
class P(override val name: String) : Named
fun main() { println(P("kotlin").shout()) }
"#;
    assert_klio("ext_iface", src, "KOTLIN!\n");
}

#[test]
fn extension_chain_calls() {
    let src = r#"
fun String.first(): String = substring(0, 1)
fun String.uppercased(): String = uppercase()
fun String.banner(): String = first().uppercased() + ":" + uppercase()
fun main() { println("kotlin".banner()) }
"#;
    assert_klio("ext_chain", src, "K:KOTLIN\n");
}

#[test]
fn extension_with_receiver_lambda_arg() {
    let src = r#"
fun <T> T.alsoLog(tag: String): T {
    println("[$tag]$this")
    return this
}
fun main() {
    val x = "hi".alsoLog("L1").alsoLog("L2")
    println("done:$x")
}
"#;
    assert_klio("ext_log", src, "[L1]hi\n[L2]hi\ndone:hi\n");
}

#[test]
fn extension_member_property() {
    let src = r#"
val String.firstChar: Char get() = this[0]
fun main() { println("abc".firstChar) }
"#;
    assert_klio("ext_member_prop", src, "a\n");
}

#[test]
fn extension_with_default_arg() {
    let src = r#"
fun String.padTo(n: Int, fill: Char = ' '): String {
    val k = n - length
    return if (k > 0) this + fill.toString().repeat(k) else this
}
fun main() {
    println("[${"hi".padTo(5)}|${"hi".padTo(5, '*')}]")
}
"#;
    assert_klio("ext_default", src, "[hi   |hi***]\n");
}

#[test]
fn extension_explicit_call_via_qualifier() {
    let src = r#"
fun Int.plusOne(): Int = this + 1
fun Long.plusOne(): Long = this + 1
fun main() {
    val a: Int = 5.plusOne()
    val b: Long = 5L.plusOne()
    println("$a|$b")
}
"#;
    assert_klio("ext_qualifier", src, "6|6\n");
}

#[test]
fn with_receiver_member_extension_visible_in_lambda() {
    let src = r#"
class A {
    val tag = "T"
    fun List<Int>.show(): String = joinToString(",") { "$tag:$it" }
}
fun main() {
    val a = A()
    val r = with(a) { listOf(1, 2, 3).show() }
    println(r)
}
"#;
    assert_klio("with_member_ext", src, "T:1,T:2,T:3\n");
}

#[test]
fn with_receiver_member_extension_virtual_override() {
    let src = r#"
open class Animal {
    open val sound: String = "?"
    open fun List<Int>.tagged(): String = joinToString(",") { "$sound:$it" }
}
class Dog : Animal() {
    override val sound: String = "woof"
}
fun main() {
    val d = Dog()
    val r = with(d) { listOf(1, 2, 3).tagged() }
    println(r)
}
"#;
    assert_klio("with_member_ext_virtual", src,
        "woof:1,woof:2,woof:3\n");
}
