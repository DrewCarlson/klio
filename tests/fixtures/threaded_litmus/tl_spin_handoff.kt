// Spin-wait flag handoff between two Default launches — the shape that
// deadlocked while dispatcher bodies ran inline on one pump. With real
// workers, `a` busy-waits on one thread while `b` sets the flag from
// another, so both complete.
//> b set flag
//> a saw flag
//> done
import kotlinx.coroutines.*
import kotlinx.atomicfu.*

val flag = atomic(false)

fun main() = runBlocking {
    val a = launch(Dispatchers.Default) {
        while (!flag.value) {}
        println("a saw flag")
    }
    val b = launch(Dispatchers.Default) {
        Thread.sleep(50)
        println("b set flag")
        flag.value = true
    }
    a.join(); b.join()
    println("done")
}
