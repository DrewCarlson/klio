// corpus: skia (the expected output is the one printed when the Skia shim renders)
// Copy and paste between two text fields of a window, through the system
// clipboard, as a Compose Desktop window does it. The keys come from
// compose_window_clipboard.input ($KLIO_WIN_INPUT): a click into the first
// field, Select All, Copy, a click into the second, Paste and Paste again,
// then Cut in the first. The shortcuts use the platform's menu modifier
// (Command on macOS, Control elsewhere). A copy puts the text on the
// clipboard as foundation's AnnotatedString transferable, which offers it as
// text too, and the program reads it back.
//
// The tests run it with KLIO_CLIPBOARD=private, a clipboard of the program's
// own; run plainly, it copies onto the host's clipboard.
@file:OptIn(ExperimentalComposeUiApi::class)

import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.input.TextFieldLineLimits
import androidx.compose.foundation.text.input.TextFieldState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.asAwtTransferable
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import klio.datatransfer.DataFlavor
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

fun main() {
    val source = TextFieldState("copy me")
    val target = TextFieldState()
    application(exitProcessOnExit = false) {
        Window(
            onCloseRequest = ::exitApplication,
            title = "clipboard",
            state = rememberWindowState(width = 300.dp, height = 200.dp),
        ) {
            val clipboard = LocalClipboard.current
            // The script ends with the cut, which empties the first field; a
            // few frames later the application ends.
            LaunchedEffect(Unit) {
                withTimeoutOrNull(10_000) { snapshotFlow { source.text.isEmpty() }.first { it } }
                repeat(5) { withFrameNanos { } }
                val entry = clipboard.getClipEntry()?.asAwtTransferable
                println("clipboard flavors: " + entry?.getTransferDataFlavors()?.size)
                println("clipboard text: " + entry?.getTransferData(DataFlavor.stringFlavor))
                exitApplication()
            }
            Column {
                BasicTextField(
                    source,
                    Modifier.size(200.dp, 40.dp).border(1.dp, Color.Black),
                    lineLimits = TextFieldLineLimits.SingleLine,
                )
                BasicTextField(
                    target,
                    Modifier.size(200.dp, 40.dp).border(1.dp, Color.Black),
                    lineLimits = TextFieldLineLimits.SingleLine,
                )
            }
        }
    }
    println("first field: \"" + source.text + "\"")
    println("second field: \"" + target.text + "\"")
}
