// The kotlinx.atomicfu.locks placeholder bodies must never execute: the
// installed member bindings are the real lock. Holding the lock in a
// spliced `withLock` body, another thread's `tryLock` must fail — a
// placeholder no-op body would let it succeed. `thread` itself is an
// intrinsic-only import (host impl, no Kotlin declaration), so this also
// pins that a named import defeats the pre-run unresolved rejection.
import kotlin.concurrent.thread
import kotlinx.atomicfu.locks.ReentrantLock
import kotlinx.atomicfu.locks.withLock

fun main() {
    val lock = ReentrantLock()
    var other = true
    lock.withLock {
        val t = thread { other = lock.tryLock() }
        t.join()
    }
    println("other=$other")
    val reacquired = lock.tryLock()
    println("reacquired=$reacquired")
    if (reacquired) lock.unlock()
}
