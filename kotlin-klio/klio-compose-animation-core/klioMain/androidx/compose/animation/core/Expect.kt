// Platform actuals for the animation-core commonMain expects. klio runs real
// worker threads: the atomics are atomicfu (atomic across threads) and the
// "current thread" is a stable per-thread identity token, so thread-change
// detection observes real thread hops.
package androidx.compose.animation.core

import kotlinx.atomicfu.atomic

internal actual class AtomicReference<V> actual constructor(value: V) {
    private val ref = atomic(value)
    actual fun get(): V = ref.value
    actual fun set(value: V) { ref.value = value }
    actual fun getAndSet(value: V): V = ref.getAndSet(value)
    actual fun compareAndSet(expect: V, newValue: V): Boolean = ref.compareAndSet(expect, newValue)
}

// Per-thread identity tokens keyed on the calling thread's stable name
// (klio's `Thread.currentThread().name` is unique per OS thread), so
// repeated calls on one thread return the SAME object and a thread hop
// returns a different one — the identity contract thread-change
// detection compares against.
private val threadTokens = HashMap<String, Any>()

internal actual fun getCurrentThread(): Any = kotlin.synchronized(threadTokens) {
    threadTokens.getOrPut(Thread.currentThread().name) { Any() }
}
