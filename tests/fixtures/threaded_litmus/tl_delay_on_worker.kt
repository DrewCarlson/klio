// `delay` under a dispatcher resumes on the dispatcher's workers, not
// the runBlocking driver: the code after the suspension still reports a
// `DefaultDispatcher-worker-` thread.
//> before on worker=true
//> after on worker=true
//> driver is not worker=true
import kotlinx.coroutines.*

fun main() = runBlocking {
    val j = launch(Dispatchers.Default) {
        println("before on worker=" + Thread.currentThread().name.startsWith("DefaultDispatcher-worker-"))
        delay(100)
        println("after on worker=" + Thread.currentThread().name.startsWith("DefaultDispatcher-worker-"))
    }
    j.join()
    println("driver is not worker=" + !Thread.currentThread().name.startsWith("DefaultDispatcher-worker-"))
}
