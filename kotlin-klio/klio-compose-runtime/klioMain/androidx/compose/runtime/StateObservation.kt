// Single-threaded state-observation hub — klio's replacement for the MVCC
// snapshot machinery's read/apply observers.
//
// Upstream Compose routes state reads/writes through per-thread snapshots with
// versioned `StateRecord`s. klio's synchronous composition model needs only the
// observer edges that drive recomposition: while composing, the composer pushes
// a read observer that records which state objects a recompose scope touched; a
// state write notifies registered write observers (the recomposer), which
// invalidate the scopes that read the written state. No versioning, no atomics,
// no thread-locals.

package androidx.compose.runtime

internal object StateObservation {
    private val readObservers = ArrayList<(Any) -> Unit>()
    private val writeObservers = ArrayList<(Any) -> Unit>()

    /** Record that [state] was read, notifying the innermost active observer. */
    fun notifyRead(state: Any) {
        val n = readObservers.size
        if (n == 0) return
        readObservers[n - 1].invoke(state)
    }

    /** Run [block] with [readObserver] active for every state read inside it. */
    fun <R> observe(readObserver: (Any) -> Unit, block: () -> R): R {
        readObservers.add(readObserver)
        try {
            return block()
        } finally {
            readObservers.removeAt(readObservers.size - 1)
        }
    }

    /** Register a write observer; returns a handle that unregisters it. */
    fun registerWriteObserver(observer: (Any) -> Unit): () -> Unit {
        writeObservers.add(observer)
        return { writeObservers.remove(observer) }
    }

    /** Notify every registered write observer that [state] changed. */
    fun notifyWrite(state: Any) {
        if (writeObservers.isEmpty()) return
        val active = writeObservers.toList()
        for (o in active) o(state)
    }
}
