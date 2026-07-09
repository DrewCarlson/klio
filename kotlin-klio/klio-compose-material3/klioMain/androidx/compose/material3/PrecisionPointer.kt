// klio actual for material3's EnsurePrecisionPointerListenersRegistered: the
// precision-pointer listeners are an Android input concern, so the desktop /
// skiko form is a pass-through that just composes its content.
package androidx.compose.material3

import androidx.compose.runtime.Composable

@Composable
internal actual fun EnsurePrecisionPointerListenersRegistered(content: @Composable () -> Unit) {
    content()
}
