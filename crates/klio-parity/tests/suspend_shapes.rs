//! Suspend function shapes that drive realistic coroutine code.

use std::io::Write;
use std::path::PathBuf;

fn write_src(name: &str, src: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("klio_suspend_shapes");
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
fn suspend_chain_of_calls() {
    let src = r#"
import kotlinx.coroutines.*
suspend fun step1(): Int { delay(2); return 10 }
suspend fun step2(x: Int): Int { delay(2); return x + 5 }
suspend fun step3(x: Int): String { delay(2); return "result=$x" }
fun main() = runBlocking {
    val a = step1()
    val b = step2(a)
    val c = step3(b)
    println(c)
}
"#;
    assert_klio("suspend_chain", src, "result=15\n");
}

#[test]
fn suspend_in_lambda() {
    let src = r"
import kotlinx.coroutines.*
fun main() = runBlocking {
    val results = mutableListOf<Int>()
    for (i in 1..3) {
        launch {
            delay(2)
            results.add(i * 10)
        }
    }
    delay(20)
    results.sort()
    println(results)
}
";
    assert_klio("suspend_lambda", src, "[10, 20, 30]\n");
}

#[test]
fn suspend_with_try_catch() {
    let src = r#"
import kotlinx.coroutines.*
suspend fun risky(n: Int): Int {
    delay(2)
    if (n < 0) throw IllegalArgumentException("neg")
    return n * 2
}
fun main() = runBlocking {
    val a = try { risky(5) } catch (e: IllegalArgumentException) { -1 }
    val b = try { risky(-1) } catch (e: IllegalArgumentException) { -1 }
    println("$a,$b")
}
"#;
    assert_klio("suspend_try", src, "10,-1\n");
}

#[test]
fn async_concurrent_completion() {
    let src = r#"
import kotlinx.coroutines.*
fun main() = runBlocking {
    val a = async { delay(5); 1 }
    val b = async { delay(3); 2 }
    val c = async { delay(7); 3 }
    println("${a.await() + b.await() + c.await()}")
}
"#;
    assert_klio("async_concurrent", src, "6\n");
}

#[test]
fn nested_suspend_lambda_capture() {
    let src = r#"
import kotlinx.coroutines.*
fun main() = runBlocking {
    val tag = "hello"
    val r = withContext(Dispatchers.Default) {
        delay(2)
        "$tag, world"
    }
    println(r)
}
"#;
    assert_klio("withContext", src, "hello, world\n");
}

#[test]
fn coroutine_returns_through_run_blocking() {
    let src = r"
import kotlinx.coroutines.*
fun compute(): Int = runBlocking {
    val a = async { delay(1); 100 }
    val b = async { delay(1); 200 }
    a.await() + b.await()
}
fun main() { println(compute()) }
";
    assert_klio("rb_returns", src, "300\n");
}

// A `suspend` method of a *local class* (lowered into its own per-method
// sub-module) parks at a `delay` and resumes correctly. The frame
// snapshot records which module the method was lowered into, so resume
// resolves its `FuncId` against that sub-module rather than the main
// module (where the same index is a different function — which fed the
// resumed value back garbage). Nested-`private`-class methods (ktor's
// `HttpSend.DefaultSender`) take the same per-method sub-module path.
#[test]
fn local_class_suspend_method_resumes_in_its_module() {
    let src = r#"
import kotlinx.coroutines.*
suspend fun runWith(x: Int): String {
    class Worker {
        suspend fun work(n: Int): Int {
            delay(1)
            return n * 2
        }
    }
    return "got=" + Worker().work(x)
}
fun main() = runBlocking { println("result=" + runWith(21)) }
"#;
    assert_klio("local_class_suspend_resume", src, "result=got=42\n");
}

// A deprecated overload that delegates to the general one via an
// explicit cast — kotlinx.coroutines' `async(context: Job, …) =
// async(context as CoroutineContext, …)` — must reach the general
// `async(CoroutineContext)` overload, not re-select the `Job` overload
// (the runtime value is still a `Job`) and recurse forever. Here the
// receiver-lambda `ic.invoke(next, r)` calls a suspend method whose body
// is `async(coroutineContext + Job()) { … }.await()`, exercising the
// delegation through the real coroutines library.
#[test]
fn async_job_overload_delegates_without_recursing() {
    let src = r#"
import kotlinx.coroutines.*
import kotlin.coroutines.*
interface Snd { suspend fun execute(r: String): String }
class Base : Snd {
    override suspend fun execute(r: String): String {
        val ctx = coroutineContext + Job()
        return async(ctx) { "E($r)" }.await()
    }
}
class Inter(val ic: suspend Snd.(String) -> String, val next: Snd) : Snd {
    override suspend fun execute(r: String): String = ic.invoke(next, r)
}
fun main() = runBlocking {
    val s: Snd = Inter({ r -> "R1[" + execute(r) + "]" }, Base())
    println(s.execute("x"))
}
"#;
    assert_klio("async_job_overload_delegates", src, "R1[E(x)]\n");
}
