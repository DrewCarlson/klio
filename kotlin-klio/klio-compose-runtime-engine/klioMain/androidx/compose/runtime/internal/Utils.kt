// klio actual for the runtime's internal error logger. Upstream routes this to
// the platform log (android.util.Log / stderr); klio writes the message and the
// throwable to standard error so a swallowed compositional error stays visible.

package androidx.compose.runtime.internal

internal actual fun logError(message: String, e: Throwable) {
    println(message)
    e.printStackTrace()
}
