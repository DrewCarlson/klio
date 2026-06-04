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
