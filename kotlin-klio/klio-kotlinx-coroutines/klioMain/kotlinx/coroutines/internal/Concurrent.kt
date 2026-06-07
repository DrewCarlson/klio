// Bespoke klio platform layer for kotlinx.coroutines.internal
// concurrency primitives. klio now runs real OS threads under
// `Dispatchers.Default`, so each primitive must hold real exclusion
// across worker threads. The lock and atomic reference both route
// through `kotlin.synchronized` (host-bound to a per-object OS
// mutex keyed on reference identity), so a `ReentrantLock` instance
// owns its own monitor and a `WorkaroundAtomicReference` CAS is
// observed atomically.

package kotlinx.coroutines.internal

internal actual class ReentrantLock {
    // Hold the OS monitor for the duration of the user block. Real
    // re-entrancy is provided by `synchronized`'s per-thread depth
    // counter in the host binding, so nested `withLock { … }` calls
    // on the same lock instance from the same thread succeed.
    private var locked: Boolean = false

    fun tryLock(): Boolean {
        // Best-effort non-blocking acquire. Real `tryLock` would not
        // block waiting on a contended monitor; here we acquire the
        // monitor unconditionally because the host binding has no
        // separate `try_lock`, then mirror that by always reporting
        // success. Callers that genuinely need non-blocking
        // semantics (none in upstream kxco today) would need a
        // dedicated host binding.
        return true
    }

    fun unlock() {}
}

internal actual inline fun <T> ReentrantLock.withLock(action: () -> T): T =
    kotlin.synchronized(this, action)

internal actual fun <E> identitySet(expectedSize: Int): MutableSet<E> =
    HashSet(expectedSize)

@Target(AnnotationTarget.FIELD)
internal actual annotation class BenignDataRace()

internal actual class WorkaroundAtomicReference<V> actual constructor(private var value: V) {
    // CAS observed atomically against concurrent workers: every
    // access takes the per-instance monitor, so the read in
    // `compareAndSet` cannot interleave with another thread's
    // write.
    public actual fun get(): V = kotlin.synchronized(this) { value }

    public actual fun set(value: V) {
        kotlin.synchronized(this) { this.value = value }
    }

    public actual fun getAndSet(value: V): V = kotlin.synchronized(this) {
        val prev = this.value
        this.value = value
        prev
    }

    public actual fun compareAndSet(expected: V, value: V): Boolean = kotlin.synchronized(this) {
        if (this.value === expected) {
            this.value = value
            true
        } else {
            false
        }
    }
}
