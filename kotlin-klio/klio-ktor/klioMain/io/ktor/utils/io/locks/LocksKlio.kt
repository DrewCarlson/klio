// klio `actual`s for the `io.ktor.utils.io.locks` expects. klio runs
// real worker threads (a `ByteChannel` can be written from a
// `Dispatchers.Default` worker while another coroutine's driver
// reads), so these are real locks. `synchronized` delegates to
// `kotlin.synchronized` — the host's per-object reentrant monitor,
// keyed on the lock's identity — and `ReentrantLock`'s methods are
// host-bound (see the pack's native bindings) to the same monitor:
// `lock()` blocks until owned (reentrant), `tryLock()` is a
// non-blocking acquire, `unlock()` releases one level. `withLock`
// runs the action with the monitor held and releases it through
// try/finally so an exception leaves the lock released. The
// `ReentrantLock` Kotlin bodies are placeholders the installed host
// bindings shadow at dispatch time.

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
public actual inline fun <T> synchronized(lock: SynchronizedObject, block: () -> T): T =
    kotlin.synchronized(lock, block)
