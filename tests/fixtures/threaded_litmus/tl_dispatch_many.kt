// Mutual exclusion across dispatched coroutines. 16
// `launch(Dispatchers.Default)` each do 1000 monitor-guarded
// increments of a shared counter; after joining all, the total must
// be exactly 16000. (Dispatcher bodies currently execute on the
// calling pump; real OS-thread exclusion is pinned by tl_sync_counter
// and the tl_atomicfu_* fixtures.)
//> 16000
import kotlinx.coroutines.*
import kotlinx.atomicfu.atomic

fun main() {
    runBlocking {
        val lock = Any()
        var counter = 0
        val jobs = ArrayList<Job>()
        for (n in 0 until 16) {
            jobs.add(launch(Dispatchers.Default) {
                repeat(1000) {
                    synchronized(lock) { counter += 1 }
                }
            })
        }
        for (j in jobs) {
            j.join()
        }
        println(counter)
    }
}
