//! Regression: a bare reference to an imported member of a *named*
//! companion object (`import demo.Box.Factory.UNIT` then bare `UNIT`,
//! including in a default-argument position) must resolve to the
//! companion member. The IR lowering pass carries no import context,
//! so this exercises the import-alias rewrite that maps the bare name
//! back to the qualified `Box.UNIT` companion access. Byte-identical
//! against real `kotlinc`.

use std::io::Write;

const SRC: &str = r"package demo

import demo.Box.Factory.UNIT

class Box {
    companion object Factory {
        const val UNIT: Int = 7
    }
}

fun pick(x: Int = UNIT): Int = x

fun main() {
    println(pick())
    println(pick(3))
    println(UNIT)
}
";

#[test]
fn import_named_companion_member_is_byte_identical() {
    let dir = std::env::temp_dir().join("klio_import_named_companion");
    std::fs::create_dir_all(&dir).expect("mkdir tmp");
    let file = dir.join("import_named_companion_member.kt");
    let mut f = std::fs::File::create(&file).expect("write kt");
    f.write_all(SRC.as_bytes()).expect("write src");
    drop(f);

    let report = match klio_parity::check(&file) {
        Ok(r) => r,
        // No kotlinc/java available in this environment: skip rather
        // than fail (mirrors the corpus sweep's tolerance).
        Err(e) => {
            eprintln!("skipping (kotlinc unavailable): {e}");
            return;
        }
    };
    assert!(
        report.matched,
        "klio/kotlinc stdout mismatch\n{}",
        klio_parity::render_diff(&report)
    );
    assert_eq!(report.klio_stdout, "7\n3\n7\n");
}
