// corpus: skia (the expected output is the one printed when the Skia shim renders)
// An application-modal DialogWindow blocks every window of the application,
// the other top-level windows included, until it closes, as Compose
// Desktop's does. The scripted input (compose_window_modal_app.input) gives
// every window the same clicks, as compose_window_modal's does: the windows'
// first click comes while the dialog is up and reaches neither of them.
@file:OptIn(ExperimentalComposeUiApi::class)

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.DialogModalityType
import androidx.compose.ui.window.DialogWindow
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberDialogState
import androidx.compose.ui.window.rememberWindowState

fun main() {
    val firstClicks = mutableListOf<String>()
    val secondClicks = mutableListOf<String>()
    application(exitProcessOnExit = false) {
        var dialogOpen by remember { mutableStateOf(true) }
        fun state() = if (dialogOpen) "open" else "closed"
        Window(
            onCloseRequest = ::exitApplication,
            title = "first",
            state = rememberWindowState(position = WindowPosition(80.dp, 80.dp), width = 240.dp, height = 160.dp),
        ) {
            Box(Modifier.fillMaxSize().padding(start = 100.dp).clickable { firstClicks += state() })
            if (dialogOpen) {
                DialogWindow(
                    onCloseRequest = { dialogOpen = false },
                    title = "dialog",
                    state = rememberDialogState(position = WindowPosition(360.dp, 80.dp), size = DpSize(200.dp, 120.dp)),
                    modalityType = DialogModalityType.ApplicationModal,
                    content = {
                        Box(Modifier.fillMaxSize().clickable {
                            println("dialog clicked: it closes")
                            dialogOpen = false
                        })
                    },
                )
            }
        }
        Window(
            onCloseRequest = ::exitApplication,
            title = "second",
            state = rememberWindowState(position = WindowPosition(80.dp, 320.dp), width = 240.dp, height = 160.dp),
        ) {
            Box(Modifier.fillMaxSize().padding(start = 100.dp).clickable { secondClicks += state() })
        }
    }
    println("the first window took clicks while the dialog was: $firstClicks")
    println("the second window took clicks while the dialog was: $secondClicks")
}
