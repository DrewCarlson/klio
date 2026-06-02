//! Larger integration programs that combine many features at once
//! — generic ADTs, sealed hierarchies, inline operators, scope
//! functions, exceptions, lambdas, recursion. These surface
//! integration gaps that the smaller corpora miss.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_integration");
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

// 1. A small expression-evaluator program: parse-like tree, visit,
//    fold, with a generic `Result` wrapper, scope functions, sealed,
//    overloading.
#[test]
fn small_expression_evaluator() {
    let src = r#"
sealed class Tok { class N(val v: Int) : Tok(); class Op(val ch: Char) : Tok() }

sealed class Res<out T> {
    class Ok<T>(val v: T) : Res<T>()
    class Err(val msg: String) : Res<Nothing>()
}

fun <T> Res<T>.toString2(): String = when (this) {
    is Res.Ok -> "Ok(" + v.toString() + ")"
    is Res.Err -> "Err(" + msg + ")"
}

fun tokenize(s: String): List<Tok> = buildList {
    var i = 0
    while (i < s.length) {
        val c = s[i]
        when {
            c == ' ' -> { i++ }
            c.isDigit() -> {
                var j = i
                while (j < s.length && s[j].isDigit()) j++
                add(Tok.N(s.substring(i, j).toInt()))
                i = j
            }
            else -> { add(Tok.Op(c)); i++ }
        }
    }
}

// Evaluate strictly left-to-right (no precedence) for simplicity.
fun eval(toks: List<Tok>): Res<Int> {
    var acc: Int? = null
    var op: Char? = null
    for (t in toks) when (t) {
        is Tok.N -> {
            val n = t.v
            acc = when (op) { null -> n; '+' -> acc!! + n; '-' -> acc!! - n; '*' -> acc!! * n; else -> return Res.Err("bad op:$op") }
            op = null
        }
        is Tok.Op -> { op = t.ch }
    }
    return acc?.let { Res.Ok(it) } ?: Res.Err("empty")
}

fun main() {
    val cases = listOf("1 + 2 * 3 - 4", "10", "", "5 / 2")
    val out = cases.joinToString("|") { eval(tokenize(it)).toString2() }
    println(out)
}
"#;
    // "1 + 2 * 3 - 4" -> 1+2=3, *3=9, -4=5
    // "10" -> 10
    // "" -> empty
    // "5 / 2" -> bad op:/  (op was '/' when next number 2 came in)
    assert_klio("small_eval", src, "Ok(5)|Ok(10)|Err(empty)|Err(bad op:/)\n");
}

// 2. State machine via sealed + transition function, with sorted
//    output to ensure ordering is deterministic.
#[test]
fn state_machine_sealed() {
    let src = r#"
sealed class S { object Idle : S(); class Run(val tick: Int) : S(); class Done(val total: Int) : S() }

fun step(s: S, evt: String): S = when (s) {
    is S.Idle -> if (evt == "start") S.Run(0) else S.Idle
    is S.Run -> when (evt) {
        "tick" -> S.Run(s.tick + 1)
        "stop" -> S.Done(s.tick)
        else -> s
    }
    is S.Done -> s
}

fun render(s: S): String = when (s) {
    is S.Idle -> "Idle"
    is S.Run -> "Run(${s.tick})"
    is S.Done -> "Done(${s.total})"
}

fun main() {
    val events = listOf("noop", "start", "tick", "tick", "tick", "stop", "tick")
    var s: S = S.Idle
    val sb = StringBuilder()
    for (e in events) {
        s = step(s, e)
        sb.append(render(s)); sb.append("|")
    }
    println(sb)
}
"#;
    assert_klio(
        "state_machine",
        src,
        "Idle|Run(0)|Run(1)|Run(2)|Run(3)|Done(3)|Done(3)|\n",
    );
}

// 3. Generic immutable stack via a sealed type with `pop` returning
//    `Pair<T?, Stack<T>>` — exercises Pair destructuring and
//    Sealed-when exhaustiveness in `pop`.
#[test]
fn generic_immutable_stack() {
    let src = r#"
sealed class Stack<out T> {
    object Empty : Stack<Nothing>()
    data class Push<T>(val head: T, val tail: Stack<T>) : Stack<T>()
}

fun <T> Stack<T>.push(x: T): Stack<T> = Stack.Push(x, this)
fun <T> Stack<T>.pop(): Pair<T?, Stack<T>> = when (this) {
    Stack.Empty -> Pair(null, this)
    is Stack.Push -> Pair(head, tail)
}

fun main() {
    val s: Stack<Int> = Stack.Empty.push(1).push(2).push(3)
    val (a, s1) = s.pop()
    val (b, s2) = s1.pop()
    val (c, s3) = s2.pop()
    val (d, _) = s3.pop()
    println("$a $b $c $d")
}
"#;
    assert_klio("immutable_stack", src, "3 2 1 null\n");
}

// 4. Compose-style pipeline: `(f andThen g)(x)` style.
#[test]
fn fn_composition_extension() {
    let src = r"
infix fun <A, B, C> ((A) -> B).andThen(g: (B) -> C): (A) -> C = { a -> g(this(a)) }

fun main() {
    val inc = { x: Int -> x + 1 }
    val dbl = { x: Int -> x * 2 }
    val p = (inc andThen dbl) andThen { it - 3 }
    // inc(5)=6, dbl(6)=12, 12-3=9
    println(p(5))
}
";
    assert_klio("fn_compose_ext", src, "9\n");
}
