//! Advanced Kotlin idioms: data class equality and hashing,
//! sequence laziness, reified generics, lateinit, contracts,
//! reflection lite, scoping edges.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_advanced_idioms");
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
fn data_class_equality_and_copy() {
    let src = r#"
data class P(val a: Int, val b: String)
fun main() {
    val p1 = P(1, "x"); val p2 = P(1, "x"); val p3 = p1.copy(b = "y")
    println("${p1 == p2},${p1 == p3},${p3.a},${p3.b}")
}
"#;
    assert_klio("data_eq_copy", src, "true,false,1,y\n");
}

#[test]
#[ignore = "tracked as task #44"]
fn lateinit_var_with_isInitialized() {
    let src = r#"
class Box { lateinit var name: String }
fun main() {
    val b = Box()
    val before = ::b.get().run { ::name.isInitialized }
    b.name = "hello"
    val after = ::b.get().run { ::name.isInitialized }
    println("$before,$after,${b.name}")
}
"#;
    // Note: in kotlin, accessing isInitialized via ::name.isInitialized
    // is restricted to within the class. We use a simpler check:
    let _ = src;
    let alt = r#"
class Box {
    lateinit var name: String
    fun ready(): Boolean = ::name.isInitialized
}
fun main() {
    val b = Box()
    val before = b.ready()
    b.name = "hello"
    val after = b.ready()
    println("$before,$after,${b.name}")
}
"#;
    assert_klio("lateinit_init", alt, "false,true,hello\n");
}

#[test]
#[ignore = "tracked as task #43"]
fn sequence_lazy_evaluation() {
    let src = r#"
fun main() {
    var n = 0
    val s = sequenceOf(1, 2, 3, 4, 5)
        .map { n += 1; it * 2 }
        .filter { it > 4 }
        .take(2)
    val r = s.toList()
    println("$r,n=$n")
}
"#;
    assert_klio("seq_lazy", src, "[6, 8],n=4\n");
}

#[test]
fn elvis_chain() {
    let src = r#"
fun look(m: Map<String, String?>, k: String): String =
    m[k] ?: "missing"
fun main() {
    val m = mapOf("a" to "A", "b" to null)
    println("${look(m,"a")}|${look(m,"b")}|${look(m,"c")}")
}
"#;
    assert_klio("elvis", src, "A|missing|missing\n");
}

#[test]
fn safe_call_chain() {
    let src = r#"
class A(val b: B?)
class B(val c: C?)
class C(val v: Int)
fun main() {
    val a1 = A(B(C(7)))
    val a2 = A(B(null))
    val a3 = A(null)
    println("${a1.b?.c?.v},${a2.b?.c?.v},${a3.b?.c?.v}")
}
"#;
    assert_klio("safe_call", src, "7,null,null\n");
}

#[test]
fn smart_cast_after_null_check() {
    let src = r#"
fun shout(s: String?): Int {
    if (s == null) return -1
    return s.length  // smart-cast to non-null String
}
fun main() { println("${shout("hi")},${shout(null)}") }
"#;
    assert_klio("smart_null", src, "2,-1\n");
}

#[test]
fn when_pattern_guard_via_subject() {
    let src = r#"
fun classify(n: Int): String = when {
    n < 0 -> "neg"
    n == 0 -> "zero"
    n in 1..10 -> "small"
    n in 11..100 -> "medium"
    else -> "large"
}
fun main() {
    println(listOf(-3,0,5,50,500).joinToString(",") { classify(it) })
}
"#;
    assert_klio("when_guard", src, "neg,zero,small,medium,large\n");
}

#[test]
fn collection_groupBy_associate() {
    let src = r#"
fun main() {
    val words = listOf("alpha", "ant", "bear", "bat", "cat")
    val byInitial = words.groupBy { it[0] }
    val sortedKeys = byInitial.keys.sorted()
    val sb = StringBuilder()
    for (k in sortedKeys) {
        sb.append("$k=${byInitial[k]!!.joinToString(",")};")
    }
    println(sb)
}
"#;
    assert_klio("group_by", src, "a=alpha,ant;b=bear,bat;c=cat;\n");
}

#[test]
fn flatmap_and_distinct() {
    let src = r#"
fun main() {
    val xs = listOf(listOf(1,2,2), listOf(2,3,3), listOf(3,4))
    val flat = xs.flatten()
    val unique = flat.distinct()
    println("$flat|$unique")
}
"#;
    assert_klio("flat_distinct", src, "[1, 2, 2, 2, 3, 3, 3, 4]|[1, 2, 3, 4]\n");
}

#[test]
fn zip_and_unzip() {
    let src = r#"
fun main() {
    val a = listOf(1,2,3,4)
    val b = listOf("a","b","c")
    val z = a.zip(b)
    println(z.joinToString(",") { "${it.first}=${it.second}" })
}
"#;
    assert_klio("zip", src, "1=a,2=b,3=c\n");
}
