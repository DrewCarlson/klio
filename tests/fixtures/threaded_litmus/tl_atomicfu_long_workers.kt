// AtomicLong read-modify-write atomicity. Eight OS threads each run
// 500 `incrementAndGet()` on one shared AtomicLong; every increment
// must land. A two-step read-then-write implementation (separate
// borrows) loses updates under contention and fails here.
//> 4000
import kotlin.concurrent.thread
import kotlinx.atomicfu.atomic

fun main() {
    val counter = atomic(0L)
    val threads = ArrayList<Thread>()
    for (n in 0 until 8) {
        threads.add(thread {
            repeat(500) { counter.incrementAndGet() }
        })
    }
    for (t in threads) {
        t.join()
    }
    println(counter.value)
}
