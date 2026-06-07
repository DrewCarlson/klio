// Real mutual exclusion + publication. Eight OS threads each do
// 1000 monitor-guarded increments of a shared counter; after joining
// all, the total must be exactly 8000. A broken monitor or missing
// publication makes this flaky or wrong.
//> 8000
import kotlin.concurrent.thread

fun main() {
    val lock = Any()
    var counter = 0
    val threads = ArrayList<Thread>()
    for (n in 0 until 8) {
        threads.add(thread {
            repeat(1000) {
                synchronized(lock) { counter += 1 }
            }
        })
    }
    for (t in threads) {
        t.join()
    }
    println(counter)
}
