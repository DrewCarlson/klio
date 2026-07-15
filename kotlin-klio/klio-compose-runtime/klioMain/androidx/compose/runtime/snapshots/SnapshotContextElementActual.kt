// klio actual for the snapshot coroutine-context element. klio does not enter a
// snapshot per dispatched continuation, so the element only carries the snapshot
// and its key; entering/leaving is a no-op (klio runs a single global snapshot).

package androidx.compose.runtime.snapshots

import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

internal actual class SnapshotContextElementImpl actual constructor(
    private val snapshot: Snapshot,
) : AbstractCoroutineContextElement(SnapshotContextElement.Key), SnapshotContextElement
