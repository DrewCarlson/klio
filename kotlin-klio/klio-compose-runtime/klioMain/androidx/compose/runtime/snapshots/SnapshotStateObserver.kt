// klio's SnapshotStateObserver — the ui engine (OwnerSnapshotObserver) uses this
// to observe snapshot-state reads during measure/layout/draw so it can re-run the
// affected phase when a read value changes. klio drives recomposition + relayout
// through its own composer/recomposer, and a headless single-frame render needs
// no reactive re-observation, so this runs the observed block directly and treats
// the tracking/clearing surface as no-ops.

package androidx.compose.runtime.snapshots

public class SnapshotStateObserver(
    @Suppress("unused") private val onChangedExecutor: (callback: () -> Unit) -> Unit,
) {
    public fun <T : Any> observeReads(
        scope: T,
        onValueChangedForScope: (T) -> Unit,
        block: () -> Unit,
    ) {
        block()
    }

    public fun withNoObservations(block: () -> Unit) {
        block()
    }

    public fun clear(scope: Any) {}

    public fun clearIf(predicate: (scope: Any) -> Boolean) {}

    public fun clear() {}

    public fun start() {}

    public fun stop() {}
}
