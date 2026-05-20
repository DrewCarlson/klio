//! Functional-style patterns: pipelines, immutable builders, Option-
//! like Result handling, recursive structures.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_functional_patterns");
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
fn result_runCatching_chain() {
    let src = r#"
fun parse(s: String): Result<Int> = runCatching { s.toInt() }
fun main() {
    val a = parse("42").getOrDefault(-1)
    val b = parse("nope").getOrDefault(-1)
    val c = parse("7").map { it * 10 }.getOrDefault(0)
    println("$a,$b,$c")
}
"#;
    assert_klio("result_chain", src, "42,-1,70\n");
}

#[test]
fn collection_pipeline_long() {
    let src = r#"
fun main() {
    val r = (1..20)
        .filter { it % 2 == 0 }
        .map { it * it }
        .filter { it > 20 }
        .take(3)
        .sum()
    println(r)
}
"#;
    // 36 + 64 + 100 = 200
    assert_klio("pipeline", src, "200\n");
}

#[test]
fn nullable_chain_safe_let() {
    let src = r#"
class Node(val v: Int, val next: Node? = null)
fun main() {
    val n = Node(1, Node(2, Node(3)))
    val third = n.next?.next?.v
    val fifth = n.next?.next?.next?.next?.v
    println("${third ?: -1},${fifth ?: -1}")
}
"#;
    assert_klio("nullable_safe", src, "3,-1\n");
}

#[test]
fn recursive_list_sum() {
    let src = r#"
fun sumRec(xs: List<Int>): Int =
    if (xs.isEmpty()) 0 else xs.first() + sumRec(xs.drop(1))
fun main() {
    println(sumRec(listOf(1, 2, 3, 4, 5)))
}
"#;
    assert_klio("recursive_sum", src, "15\n");
}

#[test]
fn immutable_record_update() {
    let src = r#"
data class State(val counter: Int, val log: List<String>)
fun tick(s: State, msg: String): State =
    s.copy(counter = s.counter + 1, log = s.log + msg)
fun main() {
    var s = State(0, emptyList())
    s = tick(s, "a")
    s = tick(s, "b")
    s = tick(s, "c")
    println("${s.counter}|${s.log.joinToString(",")}")
}
"#;
    assert_klio("record_update", src, "3|a,b,c\n");
}

#[test]
fn currying_via_lambda_chain() {
    let src = r#"
fun main() {
    val add: (Int) -> (Int) -> Int = { a -> { b -> a + b } }
    val plus5 = add(5)
    println("${plus5(3)},${plus5(10)},${add(2)(8)}")
}
"#;
    assert_klio("curry", src, "8,15,10\n");
}

#[test]
fn either_via_sealed_class() {
    let src = r#"
sealed class Either<out A, out B> {
    data class Left<A>(val v: A) : Either<A, Nothing>()
    data class Right<B>(val v: B) : Either<Nothing, B>()
}
fun divide(a: Int, b: Int): Either<String, Int> =
    if (b == 0) Either.Left("zero") else Either.Right(a / b)
fun main() {
    val xs = listOf(Pair(10, 2), Pair(5, 0), Pair(8, 4))
    val out = xs.joinToString(",") { (a, b) ->
        when (val r = divide(a, b)) {
            is Either.Left -> "err:${r.v}"
            is Either.Right -> "ok:${r.v}"
        }
    }
    println(out)
}
"#;
    assert_klio("either", src, "ok:5,err:zero,ok:2\n");
}

#[test]
fn auto_closeable_use_block_invokes_close() {
    let src = r#"
class Resource(val name: String) : AutoCloseable {
    var closed = false
    override fun close() { closed = true }
}
fun main() {
    val r = Resource("A")
    val n = r.use { it.name.length }
    println("n=$n,closed=${r.closed}")
}
"#;
    assert_klio("autoclose_use", src, "n=1,closed=true\n");
}
