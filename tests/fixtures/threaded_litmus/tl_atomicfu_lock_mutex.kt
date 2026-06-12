// kotlinx.atomicfu.locks.ReentrantLock holds real mutual exclusion.
// Eight OS threads each do 500 lock-guarded increments of a plain
// shared counter; the total must be exact. The lock is also
// reentrant: the owning thread's `tryLock` succeeds while it already
// holds the lock. No-op locks race the counter and fail.
//> count=4000 reentrant=true
import kotlin.concurrent.thread
import kotlinx.atomicfu.locks.ReentrantLock
import kotlinx.atomicfu.locks.withLock

fun main() {
    val lock = ReentrantLock()
    var counter = 0
    val threads = ArrayList<Thread>()
    for (n in 0 until 8) {
        threads.add(thread {
            repeat(500) {
                lock.withLock { counter += 1 }
            }
        })
    }
    for (t in threads) {
        t.join()
    }
    lock.lock()
    val reentered = lock.tryLock()
    if (reentered) {
        lock.unlock()
    }
    lock.unlock()
    println("count=$counter reentrant=$reentered")
}
