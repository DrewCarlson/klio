// klio actual for the snapshot coroutine-context element: a
// ThreadContextElement that enters the snapshot when its coroutine is
// resumed and restores the previous one when it suspends, mirroring the
// upstream JVM actual.

package androidx.compose.runtime.snapshots

import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.ThreadContextElement

internal actual class SnapshotContextElementImpl actual constructor(
    private val snapshot: Snapshot,
) : SnapshotContextElement, ThreadContextElement<Snapshot?> {
    override val key: CoroutineContext.Key<*>
        get() = SnapshotContextElement.Key

    override fun updateThreadContext(context: CoroutineContext): Snapshot? =
        snapshot.unsafeEnter()

    override fun restoreThreadContext(context: CoroutineContext, oldState: Snapshot?) {
        snapshot.unsafeLeave(oldState)
    }
}
