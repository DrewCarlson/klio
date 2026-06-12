// klio `actual`s for the `io.ktor.utils.io.locks` expects. klio's
// cooperative pump serializes channel operations on one OS thread, so a
// lock is uncontended by construction: lock/unlock are no-ops, tryLock
// always succeeds, and withLock runs the action through try/finally so
// an exception leaves the "lock" released (matching the upstream
// contract for callers that observe it). Mirrors the kotlinx.atomicfu
// locks shim.

package io.ktor.utils.io.locks

import io.ktor.utils.io.InternalAPI

@InternalAPI
public actual open class SynchronizedObject actual constructor()

@InternalAPI
public actual class ReentrantLock {
    public actual fun lock() {}
    public actual fun tryLock(): Boolean = true
    public actual fun unlock() {}
}

@InternalAPI
public actual fun reentrantLock(): ReentrantLock = ReentrantLock()

@InternalAPI
public actual inline fun <T> ReentrantLock.withLock(block: () -> T): T {
    lock()
    try {
        return block()
    } finally {
        unlock()
    }
}

@InternalAPI
public actual inline fun <T> synchronized(lock: SynchronizedObject, block: () -> T): T = block()
