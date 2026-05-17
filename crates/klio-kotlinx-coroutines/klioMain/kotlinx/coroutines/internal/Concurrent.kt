// Bespoke klio platform layer for kotlinx.coroutines.internal
// concurrency primitives. klio runs a single-threaded cooperative
// interpreter (the `__kxco_*` host scheduler is the concurrency
// model), so locks are no-ops and "atomics" are plain fields —
// there is never a concurrent observer. Not derived from the
// js/wasm sources.

package kotlinx.coroutines.internal

internal actual class ReentrantLock {
    fun tryLock(): Boolean = true
    fun unlock() {}
}

internal actual inline fun <T> ReentrantLock.withLock(action: () -> T): T = action()

internal actual fun <E> identitySet(expectedSize: Int): MutableSet<E> =
    HashSet(expectedSize)

@Target(AnnotationTarget.FIELD)
internal actual annotation class BenignDataRace()

internal actual class WorkaroundAtomicReference<V> actual constructor(private var value: V) {
    public actual fun get(): V = value
    public actual fun set(value: V) { this.value = value }
    public actual fun getAndSet(value: V): V {
        val prev = this.value
        this.value = value
        return prev
    }
    public actual fun compareAndSet(expected: V, value: V): Boolean {
        if (this.value === expected) {
            this.value = value
            return true
        }
        return false
    }
}
