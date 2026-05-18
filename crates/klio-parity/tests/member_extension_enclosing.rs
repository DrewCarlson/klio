//! Regression: a member extension function / property whose body
//! calls members of the lexically enclosing class must resolve them
//! against the enclosing instance (`this@C`), not the extension
//! receiver. Also covers a user method invoked with named / omitted
//! arguments. The IR lowering pass carries no `this@C` binding, so
//! this exercises the enclosing-`this` propagation and the named-arg
//! member-call resolution. Byte-identical against real `kotlinc`.

use std::io::Write;

const SRC: &str = r#"class Box {
    private fun base(n: Int): Int = n * 10

    // member extension function: body calls enclosing `base`
    private fun Int.scaled(): Int = base(this) + 1

    // member extension property: getter calls enclosing `base`
    private val Int.boxed: Int get() = base(this) - 1

    private fun pick(a: Int = 7, b: Int, c: Int = 100): Int = a + b + c

    fun run(): String {
        val s = 3.scaled()
        val p = 4.boxed
        val n1 = pick(b = 5)
        val n2 = pick(b = 5, c = 1)
        return "$s $p $n1 $n2"
    }
}

fun main() {
    println(Box().run())
}
"#;

#[test]
fn member_extension_enclosing_is_byte_identical() {
    let dir = std::env::temp_dir().join("klio_member_ext_enclosing");
    std::fs::create_dir_all(&dir).expect("mkdir tmp");
    let file = dir.join("member_extension_enclosing.kt");
    let mut f = std::fs::File::create(&file).expect("create kt");
    f.write_all(SRC.as_bytes()).expect("write src");
    drop(f);

    let report = match klio_parity::check(&file) {
        Ok(r) => r,
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
    // 3.scaled() = base(3)+1 = 31 ; 4.boxed = base(4)-1 = 39
    // pick(b=5) = 7+5+100 = 112 ; pick(b=5,c=1) = 7+5+1 = 13
    assert_eq!(report.klio_stdout, "31 39 112 13\n");
}
