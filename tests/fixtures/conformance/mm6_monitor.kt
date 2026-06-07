// MM6 — monitors, genuinely concurrent. Eight OS threads each
// perform 500 monitor-guarded increments of a shared counter.
// `synchronized(lock)` must give real mutual exclusion and
// unlock-happens-before-next-lock, so after joining all threads the
// total is exactly 8*500 = 4000 (a broken monitor loses updates).
//> 4000
import kotlin.concurrent.thread
fun main() {
    val lock = Any()
    var counter = 0
    val threads = ArrayList<Thread>()
    for (n in 0 until 8) {
        threads.add(thread {
            repeat(500) {
                synchronized(lock) { counter += 1 }
            }
        })
    }
    for (t in threads) t.join()
    println(counter)
}
