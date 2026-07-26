// Bridge from the composer's read/write-observation interface onto the real MVCC
// snapshot core. The composer runs composition inside `observe(readObserver)` to
// learn which state objects a group read, and registers a write observer that
// invalidates the groups that read a state when it changes. Both edges are the
// real snapshot observers now that klio ships upstream's Snapshot core and the
// StateObject-backed state objects.

package androidx.compose.runtime

import androidx.compose.runtime.snapshots.Snapshot

internal object StateObservation {
    /** Run [block] observing every state read inside it (the composer records the
     * reading group). Backed by the real snapshot read observer. */
    fun <R> observe(readObserver: (Any) -> Unit, block: () -> R): R =
        Snapshot.observe(readObserver = readObserver, block = block)

    /** Register a write observer, returning a handle that unregisters it. Fires
     * on a committed apply (the recomposer invalidates the reading groups) and on
     * a direct global write. */
    fun registerWriteObserver(observer: (Any) -> Unit): () -> Unit {
        val apply = Snapshot.registerApplyObserver { changed, _ ->
            for (state in changed) observer(state)
        }
        val global = Snapshot.registerGlobalWriteObserver(observer)
        return {
            apply.dispose()
            global.dispose()
        }
    }
}
