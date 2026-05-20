//! Visibility modifiers parity: private/internal/protected access
//! constraints, file-private top-level, package-private (internal).

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_visibility_modifiers");
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
fn protected_access_through_subclass() {
    let src = r#"
open class Base {
    protected open fun helper(): String = "base"
    fun publicEntry(): String = helper()
}
class Sub : Base() {
    override fun helper(): String = "sub:" + super.helper()
}
fun main() {
    println("${Base().publicEntry()}|${Sub().publicEntry()}")
}
"#;
    assert_klio("protected", src, "base|sub:base\n");
}

#[test]
fn internal_property_visible_in_module() {
    let src = r#"
class Bag {
    internal var count: Int = 0
    fun bump() { count += 1 }
}
fun main() {
    val b = Bag()
    b.bump(); b.bump(); b.bump()
    println(b.count)
}
"#;
    assert_klio("internal_prop", src, "3\n");
}

#[test]
fn private_top_level_used_in_main() {
    let src = r#"
private fun secret(x: Int): Int = x * 100
fun main() {
    println(secret(7))
}
"#;
    assert_klio("private_toplevel", src, "700\n");
}

#[test]
fn private_property_only_accessed_within_class() {
    let src = r#"
class Vault {
    private var balance: Int = 100
    fun deposit(n: Int) { balance += n }
    fun statement(): String = "balance=$balance"
}
fun main() {
    val v = Vault()
    v.deposit(50)
    v.deposit(25)
    println(v.statement())
}
"#;
    assert_klio("private_prop", src, "balance=175\n");
}

#[test]
#[ignore = "tracked as task #58 (secondary ctor stack-overflow)"]
fn protected_with_secondary_constructors() {
    let src = r#"
open class P {
    protected var label: String
    constructor(s: String) { label = s }
    constructor() : this("default")
    fun show(): String = "label=$label"
}
class Q : P {
    constructor() : super()
    constructor(s: String) : super(s)
    fun mutate(s: String) { label = "q:$s" }
}
fun main() {
    val q = Q()
    val r = Q("init")
    q.mutate("hello")
    println("${q.show()}|${r.show()}")
}
"#;
    assert_klio("protected_ctor", src, "label=q:hello|label=init\n");
}

#[test]
fn private_setter_with_public_getter() {
    let src = r#"
class Counter {
    var n: Int = 0
        private set
    fun bump() { n += 1 }
}
fun main() {
    val c = Counter()
    c.bump(); c.bump()
    println(c.n)
}
"#;
    assert_klio("private_set", src, "2\n");
}
