// klio's replacement for SnapshotState.kt / SnapshotMutationPolicy.kt.
//
// Keeps the public `State` / `MutableState` / `mutableStateOf` /
// `SnapshotMutationPolicy` surface byte-compatible with upstream, but backs the
// state value with a plain field whose reads/writes go through
// `StateObservation` (the recomposition observer hub) instead of the MVCC
// snapshot `StateRecord` chain. Observable collections, `derivedStateOf`, and
// the full snapshot transaction API are layered on later.

package androidx.compose.runtime

import kotlin.reflect.KProperty

// ----- Mutation policies -----

public interface SnapshotMutationPolicy<T> {
    public fun equivalent(a: T, b: T): Boolean
    public fun merge(previous: T, current: T, applied: T): T? = null
}

private object StructuralEqualityPolicy : SnapshotMutationPolicy<Any?> {
    override fun equivalent(a: Any?, b: Any?): Boolean = a == b
    override fun toString(): String = "StructuralEqualityPolicy"
}

private object ReferentialEqualityPolicy : SnapshotMutationPolicy<Any?> {
    override fun equivalent(a: Any?, b: Any?): Boolean = a === b
    override fun toString(): String = "ReferentialEqualityPolicy"
}

private object NeverEqualPolicy : SnapshotMutationPolicy<Any?> {
    override fun equivalent(a: Any?, b: Any?): Boolean = false
    override fun toString(): String = "NeverEqualPolicy"
}

@Suppress("UNCHECKED_CAST")
public fun <T> structuralEqualityPolicy(): SnapshotMutationPolicy<T> =
    StructuralEqualityPolicy as SnapshotMutationPolicy<T>

@Suppress("UNCHECKED_CAST")
public fun <T> referentialEqualityPolicy(): SnapshotMutationPolicy<T> =
    ReferentialEqualityPolicy as SnapshotMutationPolicy<T>

@Suppress("UNCHECKED_CAST")
public fun <T> neverEqualPolicy(): SnapshotMutationPolicy<T> =
    NeverEqualPolicy as SnapshotMutationPolicy<T>

// ----- State interfaces -----

public interface State<out T> {
    public val value: T
}

public interface MutableState<T> : State<T> {
    public override var value: T
    public operator fun component1(): T
    public operator fun component2(): (T) -> Unit
}

// ----- Implementation -----

internal class MutableStateImpl<T>(
    value: T,
    val policy: SnapshotMutationPolicy<T>,
) : MutableState<T> {
    private var backing: T = value

    override var value: T
        get() {
            StateObservation.notifyRead(this)
            return backing
        }
        set(newValue) {
            if (!policy.equivalent(backing, newValue)) {
                backing = newValue
                StateObservation.notifyWrite(this)
            }
        }

    override fun component1(): T = value
    override fun component2(): (T) -> Unit = { newValue -> value = newValue }
    override fun toString(): String = "MutableState(value=$backing)"
}

public fun <T> mutableStateOf(
    value: T,
    policy: SnapshotMutationPolicy<T> = structuralEqualityPolicy(),
): MutableState<T> = MutableStateImpl(value, policy)

// ----- Property-delegation operators (`var x by mutableStateOf(...)`) -----

public operator fun <T> State<T>.getValue(thisObj: Any?, property: KProperty<*>): T = value

public operator fun <T> MutableState<T>.setValue(thisObj: Any?, property: KProperty<*>, value: T) {
    this.value = value
}
