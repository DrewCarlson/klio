package androidx.compose.ui.platform

import kotlinx.atomicfu.atomic

internal actual class AtomicInt actual constructor(value: Int) {
    private val ref = atomic(value)
    actual fun addAndGet(delta: Int): Int = ref.addAndGet(delta)
    actual fun compareAndSet(expected: Int, new: Int): Boolean = ref.compareAndSet(expected, new)
}
