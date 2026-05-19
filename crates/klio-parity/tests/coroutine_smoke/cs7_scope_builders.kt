// Structured-concurrency scope builders over the real upstream
// `ScopeCoroutine` / `startUndispatchedOrReturn` path: a sequential
// `coroutineScope`, a `coroutineScope` whose `async` children are
// driven by the enclosing pump and joined at `await`, and a
// `supervisorScope`.
//> r=3
//> s=30
//> x=5
import kotlinx.coroutines.*
fun main() = runBlocking {
    val r = coroutineScope { 1 + 2 }
    println("r=$r")
    val s = coroutineScope {
        val a = async { 10 }
        val b = async { 20 }
        a.await() + b.await()
    }
    println("s=$s")
    supervisorScope {
        val x = async { 5 }
        println("x=${x.await()}")
    }
}
