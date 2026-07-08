// klio has no JVM System.identityHashCode; the host installs
// __composeui_identityHashCode (a stable per-object hash, reference identity for
// objects, value-derived for boxed scalars) — the same source the compose
// runtime uses.
package androidx.compose.ui.internal

internal fun __composeui_identityHashCode(instance: Any?): Int =
    error("intrinsic androidx.compose.ui.internal.__composeui_identityHashCode not installed")

internal actual fun identityHashCode(instance: Any?): Int = __composeui_identityHashCode(instance)
