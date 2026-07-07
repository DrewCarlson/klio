// klio actual for material3.internal.identityHashCode: delegate to the ui
// engine's identity hash (host __composeui_identityHashCode intrinsic).
package androidx.compose.material3.internal

internal actual fun identityHashCode(instance: Any?): Int =
    androidx.compose.ui.internal.identityHashCode(instance)
