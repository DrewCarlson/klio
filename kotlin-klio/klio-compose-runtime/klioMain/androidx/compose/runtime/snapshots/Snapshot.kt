// klio's Snapshot — the ui/foundation engines reach for the snapshot system to
// bracket state reads (`Snapshot.withoutReadObservation { … }` around lifecycle
// callbacks) and to register global write/apply observers. klio does not run the
// upstream MVCC snapshot core: state reads are tracked directly by the composer,
// and writes flow through `StateObservation`. This shim satisfies the API those
// engines call so measure/layout and observer registration resolve; read
// observation is already off outside a recomposition, so `withoutReadObservation`
// simply runs its block.

package androidx.compose.runtime.snapshots

/** Handle returned by observer registration; disposing unregisters the observer. */
public fun interface ObserverHandle {
    public fun dispose()
}

public open class Snapshot internal constructor() {
    /** Run [block] with this snapshot active. klio has a single global snapshot,
     * so entering is a direct call. */
    public fun <T> enter(block: () -> T): T = block()

    public fun dispose() {}

    public companion object {
        private val globalSnapshot = Snapshot()

        /** The thread's active snapshot — klio's single global snapshot. */
        public val current: Snapshot
            get() = globalSnapshot

        /** klio applies state writes eagerly, so no apply notification is ever pending. */
        public val isApplyObserverNotificationPending: Boolean
            get() = false

        /** Run [block] without recording snapshot reads. Read observation is the
         * composer's, active only during a recomposition; here the block runs
         * directly. */
        public fun <T> withoutReadObservation(block: () -> T): T = block()

        /** Notify apply observers of committed changes. klio commits writes eagerly
         * via `StateObservation`, so there is nothing to flush here. */
        public fun sendApplyNotifications() {}

        /** Observe writes to state objects. Bridged onto klio's write observation. */
        public fun registerGlobalWriteObserver(observer: (Any) -> Unit): ObserverHandle {
            val dispose = StateObservation.registerWriteObserver { state -> observer(state) }
            return ObserverHandle { dispose() }
        }

        /** Observe snapshot applies. klio commits eagerly and never batches an apply
         * set, so this observer is never invoked; the handle is a no-op. */
        public fun registerApplyObserver(observer: (Set<Any>, Snapshot) -> Unit): ObserverHandle =
            ObserverHandle {}
    }
}
