// Open (coroutines): runBlocking(Dispatchers.Main.immediate) called on a
// worker runs its block on the worker, not on the main dispatcher's thread.
// Expected (JVM, with java.lang.Thread for klio.Thread):
//   worker is main: false, Main block ran on main: true
// klio prints "Main block ran on main: false", so lifecycle-runtime's
// MainDispatcherChecker (the desktop's) lets a LifecycleRegistry take calls
// from any thread.

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

fun main() = runBlocking(Dispatchers.Main) {
    val mainThread = klio.Thread.currentThread()
    val result = withContext(Dispatchers.Default) {
        val worker = klio.Thread.currentThread()
        var ranOn: klio.Thread? = null
        runBlocking(Dispatchers.Main.immediate) { ranOn = klio.Thread.currentThread() }
        "worker is main: " + (worker === mainThread) + ", Main block ran on main: " + (ranOn === mainThread)
    }
    println(result)
}
