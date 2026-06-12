// klio locks for `kotlinx.atomicfu.locks`.
//
// klio runs real worker threads, so these are real locks. The lock
// classes' methods are host-bound (see the pack's native bindings) to
// the same per-object reentrant monitor that backs
// `kotlin.synchronized`, keyed on the receiver's identity: `lock()`
// blocks until the calling thread owns the monitor, re-entry by the
// owning thread deepens instead of deadlocking, `tryLock()` is a
// non-blocking acquire, and `unlock()` releases one level (unlocking
// a lock the thread does not hold is an error). `withLock` /
// `synchronized` run the action with the monitor held and release it
// through try/finally even when the action throws. The Kotlin bodies
// below are placeholders the installed host bindings shadow at
// dispatch time.
package kotlinx.atomicfu.locks

public class ReentrantLock {
    public fun lock() {}
    public fun tryLock(): Boolean = true
    public fun unlock() {}
}

public fun reentrantLock(): ReentrantLock = ReentrantLock()

public inline fun <T> ReentrantLock.withLock(action: () -> T): T {
    lock()
    try {
        return action()
    } finally {
        unlock()
    }
}

public open class SynchronizedObject

public inline fun <T> synchronized(lock: SynchronizedObject, block: () -> T): T =
    kotlin.synchronized(lock, block)

public class SynchronousMutex {
    public fun tryLock(): Boolean = true
    public fun lock() {}
    public fun unlock() {}
}

public inline fun <T> SynchronousMutex.withLock(action: () -> T): T {
    lock()
    try {
        return action()
    } finally {
        unlock()
    }
}
