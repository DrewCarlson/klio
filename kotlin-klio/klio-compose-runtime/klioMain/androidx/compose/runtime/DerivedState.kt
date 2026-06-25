// derivedStateOf — a State whose value is computed from other state reads and
// recomputed only when one of those dependencies changes. The calculation runs
// inside a nested read-observation scope to capture its dependency set; a write
// to any dependency invalidates the cache and propagates the change to the
// derived state's own readers (so a composable reading the derived value
// recomposes).

package androidx.compose.runtime

private object UnsetDerived

private class DerivedState<T>(private val calculation: () -> T) : State<T> {
    private var cached: Any? = UnsetDerived
    private var dependencies: HashSet<Any> = HashSet()

    init {
        StateObservation.registerWriteObserver { state ->
            if (dependencies.contains(state) && cached !== UnsetDerived) {
                cached = UnsetDerived
                // The derived value changed: invalidate composables that read it.
                StateObservation.notifyWrite(this)
            }
        }
    }

    override val value: T
        get() {
            if (cached === UnsetDerived) {
                val deps = HashSet<Any>()
                val result = StateObservation.observe({ s -> deps.add(s) }) { calculation() }
                dependencies = deps
                cached = result
            }
            // Subscribe the current reader to this derived state (not its deps).
            StateObservation.notifyRead(this)
            @Suppress("UNCHECKED_CAST")
            return cached as T
        }
}

/** A [State] computed from other state reads, recomputed when a dependency changes. */
public fun <T> derivedStateOf(calculation: () -> T): State<T> = DerivedState(calculation)

/** Policy overload (the policy is accepted for source compatibility). */
public fun <T> derivedStateOf(
    policy: SnapshotMutationPolicy<T>,
    calculation: () -> T,
): State<T> = DerivedState(calculation)
