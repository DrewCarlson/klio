// Dispatcher worker identity. A `Dispatchers.Default` body runs on a
// pool worker named with the upstream `DefaultDispatcher-worker-`
// prefix, distinct from the caller's thread; the runBlocking driver
// itself never migrates onto a worker.
//> body on worker=true
//> body off driver=true
//> driver unchanged=true
import kotlinx.coroutines.*

fun main() = runBlocking {
    val driver = Thread.currentThread().name
    val j = launch(Dispatchers.Default) {
        val n = Thread.currentThread().name
        println("body on worker=" + n.startsWith("DefaultDispatcher-worker-"))
        println("body off driver=" + (n != driver))
    }
    j.join()
    println("driver unchanged=" + (Thread.currentThread().name == driver))
}
