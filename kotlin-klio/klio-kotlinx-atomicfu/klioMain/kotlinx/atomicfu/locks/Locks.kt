// klio single-threaded locks shim for `kotlinx.atomicfu.locks`.
//
// klio's runtime is cooperatively single-threaded, so a lock is
// uncontended by construction: lock/unlock are no-ops, tryLock always
// succeeds, and withLock simply runs the action (still through a
// try/finally so an exception leaves the "lock" released, matching the
// upstream contract for callers that observe it).
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

public inline fun <T> synchronized(lock: SynchronizedObject, block: () -> T): T {
    return block()
}

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
