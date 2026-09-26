// The text field actuals the non-JVM native targets give, which klio's
// platform answers the same way: the undo manager's clock is the monotonic
// one, and there are no platform clipboard events to handle.
package androidx.compose.foundation.text

import androidx.compose.runtime.Composable
import androidx.compose.ui.text.AnnotatedString
import kotlin.time.TimeSource

private val markNow = TimeSource.Monotonic.markNow()

internal actual fun timeNowMillis(): Long =
    markNow.elapsedNow().inWholeMilliseconds

@Suppress("ComposableNaming")
@Composable
internal actual inline fun rememberClipboardEventsHandler(
    crossinline onPaste: (AnnotatedString) -> Unit,
    crossinline onCopy: () -> AnnotatedString?,
    crossinline onCut: () -> AnnotatedString?,
    isEnabled: Boolean,
): Boolean = false
