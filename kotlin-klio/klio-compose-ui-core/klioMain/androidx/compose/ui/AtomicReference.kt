// Platform actual for the ui engine's atomics, backed by kotlinx.atomicfu (klio
// is single-threaded but the engine's lock-free paths still expect these ops).
package androidx.compose.ui

import kotlinx.atomicfu.atomic

internal actual class AtomicReference<V> actual constructor(value: V) {
    private val ref = atomic(value)
    actual fun get(): V = ref.value
    actual fun set(value: V) { ref.value = value }
    actual fun getAndSet(value: V): V = ref.getAndSet(value)
    actual fun compareAndSet(expect: V, newValue: V): Boolean = ref.compareAndSet(expect, newValue)
}
