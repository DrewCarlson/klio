//! Unqualified calls inside an extension function resolve against the
//! extension receiver's members before the top-level function scope —
//! Kotlin's rule that an implicit-receiver member shadows a same-named
//! top-level function. The motivating case is kotlinx-io's
//! `Source.readString(byteCount)`, whose body calls `require(byteCount)`:
//! `byteCount` is a `Long`, so this must bind to the `Source.require(Long)`
//! member, NOT `kotlin.require(value: Boolean)`. Binding to the top-level
//! contract used to mis-resolve the `Long` argument into a `Boolean`
//! parameter and then spin forever inside the stdlib `require`'s own
//! 1-arg → 2-arg delegation (a forward reference whose later-declared
//! overload was still a body-less stub at lowering, so the delegating call
//! baked an infinite self-call).
//!
//! These programs print deterministic strings and assert byte-identity
//! through `kotlinc` when it is available.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_extension_member_resolution");
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

// A receiver member named like a top-level stdlib function (`require`)
// shadows it for an unqualified call inside the extension body. The
// `Long` argument is incompatible with `kotlin.require(Boolean)`; only
// the member `Src.require(Long)` applies. Dispatch is dynamic — the
// concrete `RealSrc.require` override runs.
#[test]
fn extension_receiver_member_shadows_toplevel_require() {
    let src = r#"
interface Src {
    fun require(byteCount: Long)
}
class RealSrc(val size: Long) : Src {
    override fun require(byteCount: Long) {
        if (size < byteCount) throw IllegalStateException("short")
    }
}
fun Src.readN(byteCount: Long): String {
    require(byteCount)
    return "read $byteCount"
}
fun main() {
    val s = RealSrc(5)
    println(s.readN(3))
    try { s.readN(9) } catch (e: IllegalStateException) { println("caught: ${e.message}") }
}
"#;
    assert_klio("ext_recv_member_require", src, "read 3\ncaught: short\n");
}

// When the extension receiver has no member of that name, the stdlib
// `require` / `check` contract functions (including their trailing
// lazy-message-lambda forms) still resolve to the top level and throw
// the right exception types — the member-shadowing path must not
// hijack a genuine contract call.
#[test]
fn contract_require_check_stay_toplevel_without_member() {
    let src = r#"
class Box(val n: Int)
fun Box.validate(): String {
    require(n > 0) { "n must be positive but was $n" }
    check(n < 100) { "n too large" }
    return "ok $n"
}
fun main() {
    println(Box(5).validate())
    try { Box(-1).validate() } catch (e: IllegalArgumentException) { println("req: ${e.message}") }
    try { Box(200).validate() } catch (e: IllegalStateException) { println("chk: ${e.message}") }
}
"#;
    assert_klio(
        "contract_stays_toplevel",
        src,
        "ok 5\nreq: n must be positive but was -1\nchk: n too large\n",
    );
}

// A 1-arg overload delegating to a 2-arg overload declared *below* it
// in the same file (a forward reference). The delegating call must
// resolve by arity to the 2-arg sibling even though that sibling is a
// body-less stub when the 1-arg body is lowered.
#[test]
fn forward_reference_overload_delegation() {
    let src = r#"
fun pick(x: Int): String = pick(x, "default")
fun pick(x: Int, label: String): String = "$label:$x"
fun main() {
    println(pick(5))
    println(pick(5, "custom"))
}
"#;
    assert_klio("forward_ref_overload", src, "default:5\ncustom:5\n");
}
