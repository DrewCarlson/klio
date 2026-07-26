// Actuals for the compose-runtime atomic expects, backed by klio's
// kotlinx.atomicfu. AwaiterQueue uses AtomicInt (a packed version+count) and
// AtomicReference for its lock-free fast paths.
package androidx.compose.runtime.internal

import kotlinx.atomicfu.atomic

internal actual class AtomicReference<V> actual constructor(value: V) {
    private val ref = atomic(value)
    actual fun get(): V = ref.value
    actual fun set(value: V) { ref.value = value }
    actual fun getAndSet(value: V): V = ref.getAndSet(value)
    actual fun compareAndSet(expect: V, newValue: V): Boolean = ref.compareAndSet(expect, newValue)
}

internal actual class AtomicInt actual constructor(value: Int) {
    private val ref = atomic(value)
    actual fun get(): Int = ref.value
    actual fun set(value: Int) { ref.value = value }
    actual fun add(amount: Int): Int = ref.addAndGet(amount)
    actual fun compareAndSet(expect: Int, newValue: Int): Boolean = ref.compareAndSet(expect, newValue)
}
