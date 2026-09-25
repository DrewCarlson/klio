// klio actual for the runtime's error logger, as the desktop's: the message and
// then the throwable's stack trace, both on standard error.

package androidx.compose.runtime.internal

import androidx.compose.runtime.__compose_logError

internal actual fun logError(message: String, e: Throwable) {
    __compose_logError(message, e)
    e.printStackTrace()
}
