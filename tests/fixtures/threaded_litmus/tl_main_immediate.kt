// Dispatchers.Main runs its blocks on the main thread, and Main.immediate
// runs on the caller's stack when it already is there. On the main thread an
// immediate launch sets its value before launch returns and needs no
// dispatch; from a worker it needs one, and a runBlocking on it runs its
// block on the main thread, which is how lifecycle's main-thread check finds
// that thread. Compared by thread name, which on the JVM with a desktop Main
// dispatcher is the event dispatch thread.
//> before yield: initial value
//> after yield: value set by launch
//> after an immediate launch: value set by an immediate launch
//> immediate needs a dispatch on Main: false
//> worker is main: false, Main block ran on main: true, immediate needs a dispatch off Main: true
//> back on main: true
import kotlinx.coroutines.*

fun main() = runBlocking(Dispatchers.Main) {
    val mainName = Thread.currentThread().name
    var v = "initial value"
    launch(Dispatchers.Main) { v = "value set by launch" }
    println("before yield: $v")
    yield()
    println("after yield: $v")
    val job = launch(Dispatchers.Main.immediate) { v = "value set by an immediate launch" }
    println("after an immediate launch: $v")
    job.join()
    println("immediate needs a dispatch on Main: ${Dispatchers.Main.immediate.isDispatchNeeded(coroutineContext)}")
    val result = withContext(Dispatchers.Default) {
        val worker = Thread.currentThread().name
        var ranOn = ""
        runBlocking(Dispatchers.Main.immediate) { ranOn = Thread.currentThread().name }
        val needed = Dispatchers.Main.immediate.isDispatchNeeded(coroutineContext)
        "worker is main: ${worker == mainName}, Main block ran on main: ${ranOn == mainName}, " +
            "immediate needs a dispatch off Main: $needed"
    }
    println(result)
    println("back on main: ${Thread.currentThread().name == mainName}")
}
