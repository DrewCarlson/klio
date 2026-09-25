// The platform pieces of androidx.compose.ui klio supplies. A Key is numbered
// and named as on the desktop, and a KeyEvent answers its key, type, code
// point and modifiers. A desktop window has no system bars or cutouts, so
// every window inset is zero and `safeDrawingPadding` pads nothing. Haptic
// feedback types are named, performing one does nothing on the desktop, and
// the text toolbar stays hidden.
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.systemBars
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.InternalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEvent
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.isCtrlPressed
import androidx.compose.ui.input.key.isShiftPressed
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.key.utf16CodePoint
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.LocalTextToolbar
import androidx.compose.ui.unit.LayoutDirection

@OptIn(InternalComposeUiApi::class)
fun main() {
    println(Key.A)
    println(Key.Enter)
    println(Key.ShiftLeft)
    println(Key.NumPad5)
    println(listOf(HapticFeedbackType.LongPress, HapticFeedbackType.TextHandleMove, HapticFeedbackType.Confirm, HapticFeedbackType.ToggleOn))
    val e = KeyEvent(Key.A, KeyEventType.KeyDown, codePoint = 'a'.code, isCtrlPressed = true)
    println("${e.key == Key.A} ${e.type} ${e.utf16CodePoint} ${e.isCtrlPressed} ${e.isShiftPressed}")

    val scene = KlioComposeScene(100, 50)
    scene.setContent {
        val density = LocalDensity.current
        val bars = WindowInsets.systemBars
        val haptic = LocalHapticFeedback.current
        val toolbar = LocalTextToolbar.current
        LaunchedEffect(Unit) {
            println("systemBars top=" + bars.getTop(density) + " left=" + bars.getLeft(density, LayoutDirection.Ltr))
            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
            println("text toolbar " + toolbar.status)
        }
        Box(Modifier.fillMaxSize().safeDrawingPadding().onSizeChanged { println("padded size " + it) })
    }
    scene.frame()
    scene.dispose()
}
