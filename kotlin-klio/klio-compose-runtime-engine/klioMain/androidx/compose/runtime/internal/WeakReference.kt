// klio actuals for the runtime's weak-reference + identity-hash internals.
// klio's collector does not expose weak references, so a reference here is
// strong: `get()` always returns the referent. That is observationally sound for
// everything the runtime uses it for (it only ever asks whether a referent is
// still reachable, and a strong reference answers "yes"); it only means a set
// that would have been pruned by a collection keeps its entries.

package androidx.compose.runtime.internal

import androidx.compose.runtime.__compose_identityHashCode

internal class WeakReference<T : Any>(private val referent: T) {
    fun get(): T? = referent
}

internal fun identityHashCode(instance: Any?): Int =
    if (instance == null) 0 else __compose_identityHashCode(instance)
