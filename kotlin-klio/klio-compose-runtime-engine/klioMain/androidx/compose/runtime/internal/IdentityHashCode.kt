// klio actual for the runtime's identity hash, over the host's.

package androidx.compose.runtime.internal

import androidx.compose.runtime.__compose_identityHashCode

internal actual fun identityHashCode(instance: Any?): Int =
    if (instance == null) 0 else __compose_identityHashCode(instance)
