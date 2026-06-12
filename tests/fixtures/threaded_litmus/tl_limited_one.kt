// `limitedParallelism(1)` strict serialization. Eight launches through a
// parallelism-1 view of Default never run concurrently and complete in
// submission order (the view's queue is FIFO).
//> max=1
//> ordered=true
import kotlinx.coroutines.*
import kotlinx.atomicfu.*

val active = atomic(0)
val maxSeen = atomic(0)

fun main() = runBlocking {
    val one = Dispatchers.Default.limitedParallelism(1)
    val jobs = ArrayList<Job>()
    val order = ArrayList<Int>()
    for (i in 0 until 8) {
        jobs.add(launch(one) {
            val now = active.incrementAndGet()
            if (now > maxSeen.value) maxSeen.value = now
            Thread.sleep(10)
            synchronized(order) { order.add(i) }
            active.decrementAndGet()
        })
    }
    for (j in jobs) j.join()
    println("max=" + maxSeen.value)
    println("ordered=" + (order == (0 until 8).toList()))
}
