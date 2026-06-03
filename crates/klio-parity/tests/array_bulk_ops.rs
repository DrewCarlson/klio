//! Bulk array copy/fill intrinsics and String <-> `ByteArray` (UTF-8)
//! conversions, plus the kotlinx-io byte surface that rides on top of
//! them. Upstream declares `copyInto` / `copyOf` / `copyOfRange` /
//! `fill` and `encodeToByteArray` / `toByteArray` / `decodeToString`
//! without a klio-runnable body; before the host actuals landed every
//! one silently no-opped (a `ByteArray` copy left the destination zeroed).

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_array_bulk_ops");
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
fn byte_array_copy_into_round_trips() {
    let src = r#"
fun main() {
    val src = byteArrayOf(72, 101, 108, 108, 111)
    val dst = ByteArray(5)
    src.copyInto(dst)
    println(dst.joinToString(","))
}
"#;
    assert_klio("copy_into_bytes", src, "72,101,108,108,111\n");
}

#[test]
fn copy_into_with_offsets_and_overlap() {
    let src = r#"
fun main() {
    val a = intArrayOf(1, 2, 3, 4, 5)
    val b = IntArray(5)
    a.copyInto(b, 1, 0, 3)
    println(b.joinToString(","))
    // Overlapping self-copy must behave like a snapshot-then-write.
    a.copyInto(a, 2, 0, 3)
    println(a.joinToString(","))
}
"#;
    assert_klio("copy_into_offsets", src, "0,1,2,3,0\n1,2,1,2,3\n");
}

#[test]
fn copy_of_grows_and_pads() {
    let src = r#"
fun main() {
    val a = intArrayOf(7, 8, 9)
    println(a.copyOf().joinToString(","))
    println(a.copyOf(5).joinToString(","))
    println(a.copyOf(2).joinToString(","))
    println(a.copyOfRange(1, 3).joinToString(","))
}
"#;
    assert_klio("copy_of", src, "7,8,9\n7,8,9,0,0\n7,8\n8,9\n");
}

#[test]
fn array_fill_overwrites_range() {
    let src = r#"
fun main() {
    val a = IntArray(5)
    a.fill(9)
    println(a.joinToString(","))
    val b = IntArray(5)
    b.fill(1, 1, 4)
    println(b.joinToString(","))
}
"#;
    assert_klio("array_fill", src, "9,9,9,9,9\n0,1,1,1,0\n");
}

#[test]
fn string_byte_array_utf8_round_trip() {
    let src = r#"
fun main() {
    val bytes = "Héllo".encodeToByteArray()
    println(bytes.size)
    println(bytes.decodeToString())
    val again = "Héllo".toByteArray()
    println(again.decodeToString())
}
"#;
    // "Héllo" is 6 UTF-8 bytes (é is 2).
    assert_klio("string_bytes", src, "6\nHéllo\nHéllo\n");
}

// NOTE: `Buffer.write(ByteArray)` / `readAtMostTo` round-trip is verified
// end-to-end through the real `klio run` binary (the copyInto host actual
// is what makes it copy data instead of no-op). It is intentionally not a
// parity-harness case: the harness loads kotlinx-io from source, where the
// package-internal `minOf(Int, Int)` adapter resolves differently than in
// the binary's pre-built pack (tracked in PACK-COMPLETION as a harness /
// resolution-order divergence). The ByteString case below exercises the
// same copyInto-backed byte path through the harness.

#[test]
fn kotlinx_io_bytestring_encode_decode() {
    let src = r#"
import kotlinx.io.bytestring.encodeToByteString
import kotlinx.io.bytestring.decodeToString
import kotlinx.io.bytestring.substring

fun main() {
    val bs = "hello".encodeToByteString()
    println(bs.size)
    println(bs.decodeToString())
    println(bs.substring(0, 3).decodeToString())
}
"#;
    assert_klio("kxio_bytestring", src, "5\nhello\nhel\n");
}
