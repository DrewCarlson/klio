//! Inner / nested class scoping: outer-this resolution, qualified
//! this@Outer, inner-class members capturing outer fields.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_inner_classes");
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
fn nested_class_independent_of_outer() {
    let src = r#"
class Outer {
    class Nested {
        fun tag(): String = "N"
    }
    fun make(): Nested = Nested()
}
fun main() {
    val n = Outer().make()
    val n2 = Outer.Nested()
    println("${n.tag()},${n2.tag()}")
}
"#;
    assert_klio("nested_class", src, "N,N\n");
}

#[test]
fn inner_class_captures_outer_this() {
    let src = r#"
class Outer(val tag: String) {
    inner class Inner {
        fun render(): String = "outer=$tag"
    }
    fun mk(): Inner = Inner()
}
fun main() {
    val i = Outer("hello").mk()
    println(i.render())
}
"#;
    assert_klio("inner_class", src, "outer=hello\n");
}

#[test]
fn this_at_label_in_inner_class() {
    let src = r#"
class Outer(val tag: String) {
    inner class Inner {
        val tag: String = "inner"
        fun render(): String = "${this.tag}|${this@Outer.tag}"
    }
}
fun main() {
    println(Outer("OUT").Inner().render())
}
"#;
    assert_klio("this_at_label", src, "inner|OUT\n");
}

#[test]
fn nested_object_singleton() {
    let src = r#"
class Container {
    object Holder {
        fun greet(): String = "hi"
    }
}
fun main() {
    println(Container.Holder.greet())
}
"#;
    assert_klio("nested_obj", src, "hi\n");
}

#[test]
fn inner_class_member_calls_outer_method() {
    let src = r"
class Outer(val n: Int) {
    fun double(): Int = n * 2
    inner class Inner {
        fun work(): Int = double() + 1  // bare call to enclosing class's method
    }
}
fun main() {
    println(Outer(5).Inner().work())
}
";
    assert_klio("inner_calls_outer", src, "11\n");
}

#[test]
fn sealed_class_with_nested_data_subclasses() {
    let src = r"
sealed class Tree {
    data class Leaf(val v: Int) : Tree()
    data class Branch(val l: Tree, val r: Tree) : Tree()
}
fun sum(t: Tree): Int = when (t) {
    is Tree.Leaf -> t.v
    is Tree.Branch -> sum(t.l) + sum(t.r)
}
fun main() {
    val t = Tree.Branch(Tree.Leaf(1), Tree.Branch(Tree.Leaf(2), Tree.Leaf(3)))
    println(sum(t))
}
";
    assert_klio("sealed_tree", src, "6\n");
}

#[test]
fn inner_class_calls_outer_member_extension() {
    let src = r#"
class Calc {
    val base = 10
    fun Int.boost(): Int = this * base
    inner class Inner {
        fun work(): String = (1..3).map { it.boost() }.joinToString(",")
    }
}
fun main() {
    println(Calc().Inner().work())
}
"#;
    assert_klio("inner_outer_ext", src, "10,20,30\n");
}

#[test]
fn inner_class_calls_outer_member_extension_on_string() {
    let src = r#"
class Wrap {
    val sep = "::"
    fun String.adorn(): String = "[$this$sep$this]"
    inner class Builder {
        fun render(xs: List<String>): String =
            xs.joinToString(",") { it.adorn() }
    }
}
fun main() {
    println(Wrap().Builder().render(listOf("a", "b")))
}
"#;
    assert_klio("inner_outer_ext_str", src, "[a::a],[b::b]\n");
}

#[test]
fn anon_object_inherits_concrete_method_from_abstract() {
    let src = r#"
abstract class Shape {
    abstract fun area(): Int
    fun describe(): String = "area=${area()}"
}
fun rect(w: Int, h: Int): Shape = object : Shape() {
    override fun area(): Int = w * h
}
fun triangle(b: Int, h: Int): Shape = object : Shape() {
    override fun area(): Int = b * h / 2
}
fun main() {
    println(rect(3, 4).describe())
    println(triangle(6, 5).describe())
}
"#;
    assert_klio("anon_abstract_concrete", src, "area=12\narea=15\n");
}

#[test]
fn anon_object_subclass_uses_inherited_helper_in_lambda() {
    let src = r#"
abstract class Worker {
    abstract fun item(): Int
    fun pipeline(): String =
        (1..3).joinToString(",") { "${it}:${item()}" }
}
fun make(seed: Int): Worker = object : Worker() {
    override fun item(): Int = seed * seed
}
fun main() {
    println(make(2).pipeline())
    println(make(3).pipeline())
}
"#;
    assert_klio("anon_abstract_pipeline", src, "1:4,2:4,3:4\n1:9,2:9,3:9\n");
}

#[test]
fn inner_class_init_block_sees_outer_field() {
    let src = r"
class Listener
class Bus {
    val listeners = mutableListOf<Listener>()
    inner class Subscription(val l: Listener) {
        init { listeners.add(l) }
        fun unsubscribe() { listeners.remove(l) }
    }
    fun subscribe(l: Listener): Subscription = Subscription(l)
}
fun main() {
    val b = Bus()
    val s1 = b.subscribe(Listener())
    val s2 = b.subscribe(Listener())
    println(b.listeners.size)
    s1.unsubscribe()
    println(b.listeners.size)
    s2.unsubscribe()
    println(b.listeners.size)
}
";
    assert_klio("inner_init_outer", src, "2\n1\n0\n");
}
