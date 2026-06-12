// IO view cap smoke. 70 `launch(Dispatchers.IO)` bodies block in
// Thread.sleep concurrently; every one runs, at least four overlap (the
// elastic view exceeds the smallest Default cap), and the observed
// concurrency never exceeds the upstream IO parallelism of 64.
//> ranAll=true
//> overlapped=true
//> within cap=true
import kotlinx.coroutines.*
import kotlinx.atomicfu.*

val active = atomic(0)
val maxSeen = atomic(0)
val done = atomic(0)

fun main() = runBlocking {
    val jobs = ArrayList<Job>()
    for (i in 0 until 70) {
        jobs.add(launch(Dispatchers.IO) {
            val now = active.incrementAndGet()
            var m = maxSeen.value
            while (now > m) { if (maxSeen.compareAndSet(m, now)) break; m = maxSeen.value }
            Thread.sleep(300)
            active.decrementAndGet()
            done.incrementAndGet()
        })
    }
    for (j in jobs) j.join()
    println("ranAll=" + (done.value == 70))
    println("overlapped=" + (maxSeen.value >= 4))
    println("within cap=" + (maxSeen.value <= 64))
}
