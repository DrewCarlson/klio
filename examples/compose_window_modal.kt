// corpus: skia (the expected output is the one printed when the Skia shim renders)
// A DialogWindow is modal, as Compose Desktop's is: a document-modal dialog
// blocks the window whose content opened it, which takes no clicks, keys or
// menu choices while the dialog is up (a click on it brings the dialog
// forward), and gets them again once the dialog closes. Another top-level
// window is a document of its own, which the dialog does not block. The
// scripted input (compose_window_modal.input) gives every window the same
// clicks: two where the windows take clicks and the dialog does not, and
// between them one where only the dialog does, which closes it.
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogWindow
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberDialogState
import androidx.compose.ui.window.rememberWindowState

fun main() {
    // What each window's clicks found the dialog to be.
    val documentClicks = mutableListOf<String>()
    val otherClicks = mutableListOf<String>()
    application(exitProcessOnExit = false) {
        var dialogOpen by remember { mutableStateOf(true) }
        fun state() = if (dialogOpen) "open" else "closed"
        Window(
            onCloseRequest = ::exitApplication,
            title = "document",
            state = rememberWindowState(position = WindowPosition(80.dp, 80.dp), width = 240.dp, height = 160.dp),
        ) {
            // The right part of the window takes clicks; the dialog's spot does not.
            Box(Modifier.fillMaxSize().padding(start = 100.dp).clickable { documentClicks += state() })
            if (dialogOpen) {
                DialogWindow(
                    onCloseRequest = { dialogOpen = false },
                    title = "dialog",
                    state = rememberDialogState(position = WindowPosition(360.dp, 80.dp), size = DpSize(200.dp, 120.dp)),
                ) {
                    Box(Modifier.fillMaxSize().clickable {
                        println("dialog clicked: it closes")
                        dialogOpen = false
                    })
                }
            }
        }
        Window(
            onCloseRequest = ::exitApplication,
            title = "other document",
            state = rememberWindowState(position = WindowPosition(80.dp, 320.dp), width = 240.dp, height = 160.dp),
        ) {
            Box(Modifier.fillMaxSize().padding(start = 100.dp).clickable { otherClicks += state() })
        }
    }
    println("the dialog's window took clicks while the dialog was: $documentClicks")
    println("the other window took clicks while the dialog was: $otherClicks")
}
