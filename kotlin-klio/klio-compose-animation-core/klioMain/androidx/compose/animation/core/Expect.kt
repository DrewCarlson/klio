// Platform actuals for the animation-core commonMain expects. klio is
// single-threaded, so the atomics reduce to atomicfu and the "current thread"
// is a single shared token (thread-change detection always sees the same one).
package androidx.compose.animation.core

import kotlinx.atomicfu.atomic

internal actual class AtomicReference<V> actual constructor(value: V) {
    private val ref = atomic(value)
    actual fun get(): V = ref.value
    actual fun set(value: V) { ref.value = value }
    actual fun getAndSet(value: V): V = ref.getAndSet(value)
    actual fun compareAndSet(expect: V, newValue: V): Boolean = ref.compareAndSet(expect, newValue)
}

private val theThread: Any = Any()

internal actual fun getCurrentThread(): Any = theThread
