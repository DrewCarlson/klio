// klio actual for foundation.internal.identityHashCode: delegate to the ui
// engine's identity hash (backed by the host __composeui_identityHashCode
// intrinsic), a stable reference-identity hash.
package androidx.compose.foundation.internal

internal actual fun identityHashCode(instance: Any?): Int =
    androidx.compose.ui.internal.identityHashCode(instance)
