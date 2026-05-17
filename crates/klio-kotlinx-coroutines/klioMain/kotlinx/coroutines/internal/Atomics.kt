// Bespoke klio platform layer: single-threaded atomics / thread-locals
// / thread-context. No concurrent observers in klio's model.

package kotlinx.coroutines.internal

import kotlin.coroutines.CoroutineContext

internal actual class LocalAtomicInt actual constructor(private var value: Int) {
    actual fun get(): Int = value
    actual fun set(value: Int) { this.value = value }
    actual fun decrementAndGet(): Int = --value
}

internal actual class CommonThreadLocal<T> {
    private var value: Any? = null
    @Suppress("UNCHECKED_CAST")
    actual fun get(): T = value as T
    actual fun set(value: T) { this.value = value }
}

internal actual fun <T> commonThreadLocal(name: Symbol): CommonThreadLocal<T> =
    CommonThreadLocal()

// klio has no per-thread coroutine context plumbing (single thread):
// nothing to capture or restore.
internal actual fun threadContextElements(context: CoroutineContext): Any = 0
