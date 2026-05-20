//! Realistic coroutine shapes drawn from kotlinx-coroutines patterns:
//! cancellation race, supervisorScope, async with explicit start,
//! channels, flow collection, parallel decomposition.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_coroutines_realistic");
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
fn launch_join_sequencing() {
    let src = r#"
import kotlinx.coroutines.*
fun main() = runBlocking {
    val sb = StringBuilder()
    val j = launch { delay(5); sb.append("inner;") }
    sb.append("outer;")
    j.join()
    sb.append("done;")
    println(sb)
}
"#;
    assert_klio("launch_join", src, "outer;inner;done;\n");
}

#[test]
fn async_await_value() {
    let src = r#"
import kotlinx.coroutines.*
fun main() = runBlocking {
    val a = async { delay(5); 6 }
    val b = async { delay(3); 7 }
    println(a.await() * b.await())
}
"#;
    assert_klio("async_await", src, "42\n");
}

#[test]
fn cancellation_propagates_to_children() {
    let src = r#"
import kotlinx.coroutines.*
fun main() = runBlocking {
    val sb = StringBuilder()
    val parent = launch {
        launch { try { delay(1000) } catch (e: CancellationException) { sb.append("c1;") } }
        launch { try { delay(1000) } catch (e: CancellationException) { sb.append("c2;") } }
        try { delay(1000) } catch (e: CancellationException) { sb.append("p;") }
    }
    delay(10)
    parent.cancel()
    parent.join()
    println(sb)
}
"#;
    // Order of c1;c2;p; is unspecified — accept any permutation by sorting.
    let file = write_src("cancel_children", src);
    let raw = klio_parity::run_with_packs(&file).expect("run");
    let trimmed = raw.trim();
    let mut parts: Vec<&str> = trimmed.split(';').filter(|s| !s.is_empty()).collect();
    parts.sort();
    let joined = parts.join(";");
    assert_eq!(joined, "c1;c2;p", "got `{trimmed}`");
}

#[test]
fn coroutine_with_finally_cleanup() {
    let src = r#"
import kotlinx.coroutines.*
fun main() = runBlocking {
    val sb = StringBuilder()
    val j = launch {
        try { delay(1000) } finally { sb.append("clean;") }
    }
    delay(10); j.cancel(); j.join()
    sb.append("after;")
    println(sb)
}
"#;
    assert_klio("co_finally", src, "clean;after;\n");
}

#[test]
fn yield_interleaving() {
    let src = r#"
import kotlinx.coroutines.*
fun main() = runBlocking {
    val sb = StringBuilder()
    val a = launch { for (i in 1..3) { sb.append("a$i;"); yield() } }
    val b = launch { for (i in 1..3) { sb.append("b$i;"); yield() } }
    a.join(); b.join()
    println(sb)
}
"#;
    assert_klio("yield_interleave", src, "a1;b1;a2;b2;a3;b3;\n");
}

#[test]
fn nested_runBlocking_returns_value() {
    let src = r#"
import kotlinx.coroutines.*
fun compute(): Int = runBlocking {
    delay(2)
    val n = async { delay(1); 21 }
    n.await() * 2
}
fun main() { println(compute()) }
"#;
    assert_klio("nested_run_blocking", src, "42\n");
}

#[test]
fn coroutine_scope_block() {
    let src = r#"
import kotlinx.coroutines.*
fun main() = runBlocking {
    val r = coroutineScope {
        val a = async { delay(2); 1 }
        val b = async { delay(3); 2 }
        a.await() + b.await()
    }
    println(r)
}
"#;
    assert_klio("co_scope", src, "3\n");
}

#[test]
fn channel_send_receive() {
    let src = r#"
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*
fun main() = runBlocking {
    val ch = Channel<Int>(1)
    launch { ch.send(7); ch.send(8); ch.close() }
    val a = ch.receive()
    val b = ch.receive()
    println("$a,$b")
}
"#;
    assert_klio("channel", src, "7,8\n");
}

#[test]
fn with_timeout_or_null_returns_value_within_budget_and_null_on_expiry() {
    let src = r#"
import kotlinx.coroutines.*
fun main() = runBlocking {
    val r = withTimeoutOrNull(100) { delay(5); "done" }
    val r2 = withTimeoutOrNull(5) { delay(50); "done2" }
    println("$r,$r2")
}
"#;
    assert_klio("with_timeout_or_null", src, "done,null\n");
}

#[test]
fn cancel_during_delay_throws_cancellation_exception_into_body() {
    let src = r#"
import kotlinx.coroutines.*
fun main() = runBlocking {
    val sb = StringBuilder()
    val j = launch {
        try { delay(1000); sb.append("normal;") }
        catch (e: CancellationException) { sb.append("c;") }
        finally { sb.append("f;") }
    }
    delay(10); j.cancel(); j.join()
    sb.append("done")
    println(sb)
}
"#;
    assert_klio("cancel_in_delay_catch_finally", src, "c;f;done\n");
}

#[test]
fn channel_for_loop_iterates_via_iterator() {
    let src = r#"
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*
fun main() = runBlocking {
    val ch = Channel<Int>()
    launch {
        for (i in 1..3) ch.send(i)
        ch.close()
    }
    val sb = StringBuilder()
    for (v in ch) sb.append("$v;")
    println(sb)
}
"#;
    assert_klio("channel_for_loop", src, "1;2;3;\n");
}

#[test]
fn channel_buffered_send_receive_pairs() {
    let src = r#"
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*
fun main() = runBlocking {
    val ch = Channel<String>(2)
    launch {
        ch.send("a")
        ch.send("b")
        ch.send("c")
        ch.close()
    }
    val sb = StringBuilder()
    for (v in ch) sb.append(v)
    println(sb)
}
"#;
    assert_klio("channel_buffered", src, "abc\n");
}
