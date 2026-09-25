// corpus: skia (the expected output is the one printed when the Skia shim renders)
// corpus: tray (runs where the platform has tray icons: macOS and Windows)
// An application with only a tray icon, as Compose Desktop's Tray adds one:
// its icon and tooltip, a menu with a check box item, a submenu and a
// disabled item, its action, and a notification. On macOS it is a status
// item in the menu bar (a left click shows the menu, a right click is the
// action); on Windows a notification area icon (a right click shows the menu,
// a double click is the action). compose_tray.input ($KLIO_WIN_INPUT) clicks
// it and chooses its items by their titles' path through the native menu.
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.ColorPainter
import androidx.compose.ui.window.Notification
import androidx.compose.ui.window.Tray
import androidx.compose.ui.window.application
import androidx.compose.ui.window.isTraySupported
import androidx.compose.ui.window.rememberTrayState

fun main() {
    println("tray supported: $isTraySupported")
    application(exitProcessOnExit = false) {
        val state = rememberTrayState()
        var muted by remember { mutableStateOf(false) }
        var actions by remember { mutableStateOf(0) }
        Tray(
            icon = ColorPainter(Color(0xFF2E7D32)),
            state = state,
            tooltip = if (muted) "klio (muted)" else "klio",
            onAction = {
                actions++
                println("action $actions")
            },
            menu = {
                CheckboxItem("Mute", checked = muted) {
                    println("mute -> $it")
                    muted = it
                }
                Menu("Send") {
                    Item("Info") {
                        println("send info")
                        state.sendNotification(Notification("klio", "A message", Notification.Type.Info))
                    }
                }
                Item("Update", enabled = false) { println("update (never)") }
                Separator()
                Item("Quit") {
                    println("quit")
                    exitApplication()
                }
            },
        )
    }
    println("application done")
}
