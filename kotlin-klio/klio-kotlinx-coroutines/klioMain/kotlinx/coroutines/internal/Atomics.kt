// Bespoke klio platform layer for kotlinx.coroutines.internal
// atomics, thread-locals, and thread-context capture. klio now
// runs real OS threads under `Dispatchers.Default`, so every
// primitive here must hold across worker threads. The atomics
// route through `kotlin.synchronized` (host-bound to a per-object
// OS monitor) for read-modify-write visibility; the thread-local
// keys storage on `Thread.currentThread().name` so two workers
// observing the same `CommonThreadLocal` see distinct values.

package kotlinx.coroutines.internal

import kotlinx.coroutines.ThreadContextElement
import kotlin.coroutines.CoroutineContext

internal actual class LocalAtomicInt actual constructor(value: Int) {
    private var v: Int = value
    actual fun get(): Int = kotlin.synchronized(this) { v }
    actual fun set(value: Int) {
        kotlin.synchronized(this) { v = value }
    }
    actual fun decrementAndGet(): Int = kotlin.synchronized(this) {
        v -= 1
        v
    }
}

internal actual class CommonThreadLocal<T> {
    // Per-thread slots keyed on the calling thread's stable name.
    // Klio's `Thread.currentThread().name` is unique per OS thread
    // (see `concurrent_thread_current` in klio-stdlib), so two
    // workers observing the same `CommonThreadLocal` instance see
    // their own slots. Map access is synchronized on `this` because
    // multiple workers can read/write concurrently.
    private val slots: HashMap<String, Any?> = HashMap()

    @Suppress("UNCHECKED_CAST")
    actual fun get(): T = kotlin.synchronized(this) {
        slots[Thread.currentThread().name] as T
    }

    actual fun set(value: T) {
        kotlin.synchronized(this) {
            slots[Thread.currentThread().name] = value
        }
    }
}

internal actual fun <T> commonThreadLocal(name: Symbol): CommonThreadLocal<T> =
    CommonThreadLocal()

internal actual fun threadContextElements(context: CoroutineContext): Any =
    context.fold(0 as Any) { acc, element ->
        if (element is ThreadContextElement<*>) {
            val inCount = acc as? Int ?: 1
            if (inCount == 0) element else inCount + 1
        } else acc
    }
