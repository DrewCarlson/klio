// The calling thread's id, which a scene's frame recomposer compares to run
// work on the thread its frames run on.

package androidx.compose.ui.internal

internal fun __composeui_currentThreadId(): Long =
    error("intrinsic androidx.compose.ui.internal.__composeui_currentThreadId not installed")

internal actual fun getCurrentThreadId(): Long = __composeui_currentThreadId()
