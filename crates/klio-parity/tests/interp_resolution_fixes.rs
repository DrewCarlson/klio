//! Name- and member-resolution fixes surfaced while making klio consume
//! real upstream ktor commonMain. Each program prints a deterministic
//! string; klio's stdout is asserted, and (when `kotlinc` is available)
//! checked byte-for-byte. Kept in their own file so the in-process
//! interpreter runs stay within the parity harness's parallel ceiling.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_interp_resolution_fixes");
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
    if let Ok(report) = klio_parity::check(&file) {
        assert!(
            report.matched,
            "kotlinc parity mismatch for `{name}`\n{}",
            klio_parity::render_diff(&report)
        );
    }
}

// A bare call `name()` inside a class whose own member `name` is a
// (non-invokable) property, beside a top-level `fun name()`, must resolve
// to the function — a property can't satisfy a call. Mirrors ktor's
// `HttpStatusCode` companion: `val allStatusCodes = allStatusCodes()`.
#[test]
fn call_resolves_to_top_level_fn_over_same_named_property() {
    let src = r#"
class Reg {
    companion object {
        val names: List<String> = names()
        fun byIndex(i: Int): String = names[i]
    }
}
internal fun names(): List<String> = listOf("alpha", "beta", "gamma")
fun main() {
    println(Reg.names.size)
    println(Reg.byIndex(1))
}
"#;
    assert_klio(
        "call_resolves_to_top_level_fn_over_same_named_property",
        src,
        "3\nbeta\n",
    );
}

// `String.equals` returns a Bool — including the kotlin.text 2-arg
// `ignoreCase` form, with both positional and named arguments (ktor's
// ContentType.match uses `equals(other, ignoreCase = true)`).
#[test]
fn string_equals_with_ignore_case() {
    let src = r#"
fun main() {
    println("Application".equals("application", ignoreCase = true))
    println("Application".equals("application"))
    println("AB".equals("ab", true))
    println("x".equals(null))
    println(!"A".equals("b", ignoreCase = true))
}
"#;
    assert_klio(
        "string_equals_with_ignore_case",
        src,
        "true\nfalse\ntrue\nfalse\ntrue\n",
    );
}

// `key in map` on a user class implementing Map resolves through the
// stdlib `operator fun Map.contains(key) = containsKey(key)` — it must
// dispatch the override, not return a non-bool (ktor's StringValues
// builders do `name in values` over a custom map).
#[test]
fn in_operator_on_user_map_uses_contains_key() {
    let src = r#"
class FlagMap : MutableMap<String, Int> {
    override fun containsKey(key: String): Boolean = key.startsWith("known")
    override val size: Int get() = 0
    override val keys: MutableSet<String> get() = mutableSetOf()
    override val values: MutableCollection<Int> get() = mutableListOf()
    override val entries: MutableSet<MutableMap.MutableEntry<String, Int>> get() = mutableSetOf()
    override fun isEmpty(): Boolean = true
    override fun containsValue(value: Int): Boolean = false
    override fun get(key: String): Int? = null
    override fun put(key: String, value: Int): Int? = null
    override fun remove(key: String): Int? = null
    override fun putAll(from: Map<out String, Int>) {}
    override fun clear() {}
}
fun main() {
    val m = FlagMap()
    println("known-x" in m)
    println("other" in m)
}
"#;
    assert_klio(
        "in_operator_on_user_map_uses_contains_key",
        src,
        "true\nfalse\n",
    );
}

// Map lookup honors a key's custom `equals`/`hashCode`, not structural
// identity — get / containsKey / put (update) / remove all match by the
// key's `equals` (ktor's `CaseInsensitiveString` header keys need this).
#[test]
fn map_uses_key_equals_not_structural_identity() {
    let src = r#"
class CIString(val s: String) {
    override fun equals(other: Any?): Boolean = other is CIString && other.s.equals(s, ignoreCase = true)
    override fun hashCode(): Int = s.lowercase().hashCode()
    override fun toString(): String = s
}
fun main() {
    val m = mutableMapOf<CIString, Int>()
    m[CIString("Content-Type")] = 1
    println(m.containsKey(CIString("content-type")))
    println(m[CIString("CONTENT-TYPE")])
    m[CIString("content-type")] = 2
    println(m.size)
    println(m[CIString("Content-Type")])
    println(m.remove(CIString("CONTENT-TYPE")))
    println(m.size)
}
"#;
    assert_klio(
        "map_uses_key_equals_not_structural_identity",
        src,
        "true\n1\n1\n2\n2\n0\n",
    );
}

// Stdlib Map extensions (forEach / any / map) work on a *user* class
// implementing Map by materializing its `entries` — ktor's StringValues
// iterates a custom map with `values.forEach { … }`.
#[test]
fn map_hofs_on_user_map_via_entries() {
    let src = r#"
class SimpleMap : Map<String, Int> {
    private val d = mapOf("a" to 1, "b" to 2, "c" to 3)
    override val entries get() = d.entries
    override val keys get() = d.keys
    override val values get() = d.values
    override val size get() = d.size
    override fun isEmpty() = d.isEmpty()
    override fun containsKey(key: String) = d.containsKey(key)
    override fun containsValue(value: Int) = d.containsValue(value)
    override fun get(key: String) = d[key]
}
fun main() {
    val m = SimpleMap()
    var sum = 0
    m.forEach { (_, v) -> sum += v }
    println(sum)
    println(m.any { it.value > 2 })
    println(m.map { it.value }.sum())
}
"#;
    assert_klio("map_hofs_on_user_map_via_entries", src, "6\ntrue\n6\n");
}

// An anonymous object's property initialized from a non-trivial
// expression over a captured value (`val inner = src.iterator()`) is
// evaluated, not left null — ktor's DelegatingMutableSet iterator does
// exactly this.
#[test]
fn anon_object_property_init_over_capture() {
    let src = r#"
interface MyIter { fun hasNext(): Boolean; fun next(): Int }
class Wrap(val src: List<Int>) {
    fun iter(): MyIter = object : MyIter {
        val inner = src.iterator()
        override fun hasNext(): Boolean = inner.hasNext()
        override fun next(): Int = inner.next()
    }
}
fun main() {
    val w = Wrap(listOf(1, 2, 3))
    val it = w.iter()
    var sum = 0
    while (it.hasNext()) sum += it.next()
    println(sum)
}
"#;
    assert_klio("anon_object_property_init_over_capture", src, "6\n");
}

// A class whose companion object *extends the enclosing class*
// (`class Box { companion object Default : Box() }`) — exactly the
// shape of `kotlin.io.encoding.Base64` — must not loop when a member
// body makes a bare call to a top-level function. The companion is
// reached as `this` for `Box.member()`, and the companion-fallback
// supertype walk would otherwise forward the bare call back to the
// same companion singleton forever.
#[test]
fn companion_extends_enclosing_class_bare_top_level_call() {
    let src = r#"
fun guard(b: Boolean) { if (!b) throw IllegalStateException("no") }
open class Box private constructor(val flag: Boolean) {
    fun pick(): Int {
        guard(!flag)
        check(flag == false)
        return 7
    }
    companion object Default : Box(false)
}
fun main() {
    println(Box.pick())
}
"#;
    assert_klio(
        "companion_extends_enclosing_class_bare_top_level_call",
        src,
        "7\n",
    );
}

// A nested lambda must inherit the enclosing *receiver* lambda's `this`
// (the receiver of `apply` / `with` / `buildString`), not collapse it to
// `Unit`. `IntArray(n).apply { src.forEachIndexed { i, s -> this[s] = i } }`
// is exactly how `kotlin.io.encoding.Base64` builds its decode table; the
// inner `this` is the array being configured by `apply`.
#[test]
fn nested_lambda_inherits_receiver_lambda_this() {
    let src = r#"
class Acc(var total: Int)
fun main() {
    val src = intArrayOf(10, 20, 30)
    val m = IntArray(4).apply {
        this.fill(-1)
        src.forEachIndexed { index, value -> this[index] = value }
    }
    println(m.joinToString(","))            // 10,20,30,-1

    val a = Acc(0).apply {
        listOf(1, 2, 3).forEach { x -> total = total + x }
    }
    println(a.total)                        // 6

    val picked = Acc(0).apply {
        intArrayOf(4, 5, 6).forEach { v -> total = maxOf(total, v) }
    }
    println(picked.total)                   // 6
}
"#;
    assert_klio(
        "nested_lambda_inherits_receiver_lambda_this",
        src,
        "10,20,30,-1\n6\n6\n",
    );
}

// A bare `minOf` / `maxOf` call inside a class member must resolve to the
// numeric intrinsic, not a bodyless `expect` overload. The primitive
// `minOf(Int, Int)` etc. are `expect inline` declarations with no klio
// actual; selecting one ran an empty body (or a wrong comparator
// overload). `kotlin.io.encoding.Base64` calls `minOf` inside
// `encodeIntoByteArrayImpl`, so this also gates Base64 for inputs of 3+
// bytes.
#[test]
fn min_max_of_resolve_in_member_context() {
    let src = r#"
class Grid(val w: Int, val h: Int) {
    fun area(cap: Int): Int = minOf(w * h, cap)
    fun longest(): Int = maxOf(w, h)
}
fun main() {
    val g = Grid(4, 6)
    println(g.area(20))     // minOf(24, 20) = 20
    println(g.area(100))    // minOf(24, 100) = 24
    println(g.longest())    // maxOf(4, 6) = 6
}
"#;
    assert_klio("min_max_of_resolve_in_member_context", src, "20\n24\n6\n");
}

// An object expression member whose body makes a bare call to a captured
// outer parameter of the *same name* must invoke the capture, not re-enter
// the member (which self-recurses forever). This is the shape of the
// `kotlin.coroutines.Continuation(ctx) { … }` factory: `override fun
// resumeWith(r) = resumeWith(r)` binds the crossinline parameter. A normal
// anon-object call to a real sibling member must still dispatch to the
// member.
#[test]
fn anon_object_member_calls_captured_same_named_param() {
    let src = r#"
interface Sink { fun push(x: Int) }
fun mk(push: (Int) -> Unit): Sink = object : Sink {
    override fun push(x: Int) = push(x)
}
interface Calc { fun run(): Int }
fun calc(): Calc = object : Calc {
    fun helper(n: Int): Int = n * 2
    override fun run(): Int = helper(21)
}
fun main() {
    var sum = 0
    val s = mk { v -> sum += v }
    s.push(10)
    s.push(5)
    println(sum)
    println(calc().run())
}
"#;
    assert_klio(
        "anon_object_member_calls_captured_same_named_param",
        src,
        "15\n42\n",
    );
}

// An object expression's custom getter that reads a captured outer of the
// same name (`override val context get() = context`) must return the
// capture, not the absent backing field. Same shape as the
// `Continuation(ctx) { … }` factory's `context` property. A normal anon
// getter over a captured value (different name) must keep working too.
#[test]
fn anon_object_getter_reads_captured_same_named_param() {
    let src = r#"
interface Box { val tag: Int; val doubled: Int }
fun mk(tag: Int): Box = object : Box {
    override val tag: Int get() = tag
    override val doubled: Int get() = tag * 2
}
fun main() {
    val b = mk(21)
    println(b.tag)
    println(b.doubled)
}
"#;
    assert_klio(
        "anon_object_getter_reads_captured_same_named_param",
        src,
        "21\n42\n",
    );
}
