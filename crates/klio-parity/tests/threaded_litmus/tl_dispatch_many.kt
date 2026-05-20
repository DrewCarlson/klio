// Real atomic increments across dispatched coroutines. 16
// `launch(Dispatchers.Default)` each do 1000 increments of a shared
// `atomic` counter on real worker threads; after joining all, the
// total must be exactly 16000. A broken atomic or missing publication
// makes this wrong or flaky.
//> 16000
import kotlinx.coroutines.*
import kotlinx.atomicfu.atomic

fun main() {
    runBlocking {
        val counter = atomic(0)
        val jobs = ArrayList<Job>()
        for (n in 0 until 16) {
            jobs.add(launch(Dispatchers.Default) {
                repeat(1000) { counter.incrementAndGet() }
            })
        }
        for (j in jobs) {
            j.join()
        }
        println(counter.value)
    }
}
