//! kotlinx-io string-read surface through the real pack pipeline.
//!
//! `readString(byteCount)` reads a bounded prefix; `readString()` drains
//! the buffer. Both run `commonReadUtf8`, whose body constructs arrays
//! (`byteArrayOf`) and calls `min(limit, …)`. Bare `min(a, b)` here is
//! `kotlin.math.min` — under the full upstream corpus the global probe
//! used to bind a same-named receiver-extension (`kotlin.DoubleArray.min`,
//! matched only because its FQN ends in `.min`), consuming the first
//! argument as a receiver. These tests pin the fixed behavior.

use std::path::PathBuf;

fn run(name: &str, src: &str) -> String {
    let dir = std::env::temp_dir().join("klio_kotlinx_io_read");
    std::fs::create_dir_all(&dir).expect("mkdir");
    let f = dir.join(format!("{name}.kt"));
    std::fs::write(&f, src).expect("write");
    klio_parity::run_with_packs(&f).unwrap_or_else(|e| panic!("klio run failed for `{name}`: {e}"))
}

#[test]
fn read_string_bounded_then_full() {
    let src = r#"
import kotlinx.io.Buffer
import kotlinx.io.readString
import kotlinx.io.writeString
fun main() {
    val b = Buffer()
    b.writeString("hello world")
    println(b.readString(5L))
    println(b.readString())
}
"#;
    assert_eq!(run("read_bounded_then_full", src), "hello\n world\n");
}

#[test]
fn read_string_partial_prefix() {
    let src = r#"
import kotlinx.io.Buffer
import kotlinx.io.readString
import kotlinx.io.writeString
fun main() {
    val b = Buffer()
    b.writeString("hello")
    println(b.readString(3L))
}
"#;
    assert_eq!(run("read_partial_prefix", src), "hel\n");
}

// Bare `min(Int, Int)` / `maxOf` resolve to the top-level math/comparison
// functions even when the full kotlinx-io corpus has registered every
// same-named array/collection receiver-extension intrinsic.
#[test]
fn bare_min_max_resolve_to_toplevel_under_full_corpus() {
    let src = r#"
import kotlinx.io.Buffer
import kotlin.math.min
import kotlin.math.max
fun main() {
    val b = Buffer()
    println(min(5, 3))
    println(max(5, 3))
    println(minOf(2, 9))
    println(maxOf(2, 9))
}
"#;
    assert_eq!(run("bare_min_max_corpus", src), "3\n5\n2\n9\n",);
}
