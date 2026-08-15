// `synchronized` releases the monitor on EVERY exit: a non-local return
// from the block, and an exception, both unlock — a second thread (or a
// same-thread re-entry accounting check) can take the lock afterwards.

import kotlin.concurrent.thread

class Box3 { var hits = 0 }

fun takeUnderLock(lock: Any, box: Box3): Int {
    val v = synchronized(lock) {
        if (box.hits == 0) return -1
        box.hits
    }
    return v
}

fun main() {
    val lock = Any()
    val box = Box3()
    println(takeUnderLock(lock, box))
    box.hits = 5
    println(takeUnderLock(lock, box))
    try {
        synchronized(lock) { throw IllegalStateException("boom") }
    } catch (e: IllegalStateException) {
        println("caught ${e.message}")
    }
    var cross = 0
    val t = thread { synchronized(lock) { cross = 42 } }
    t.join()
    println(cross)
    println("done")
}
