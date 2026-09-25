// corpus: skia (the expected output is the one printed when the Skia shim renders)
// A window's menu bar, as Compose Desktop's MenuBar composes one: menus with
// items, a submenu, separators, a check box item and radio button items
// whose states are the composition's, a disabled item, and key shortcuts.
// On macOS the menus are the application's main menu while the window is
// focused, as the desktop's screen menu bar is; on Windows they are the
// window's menu bar. The choices come from compose_window_menu.input
// ($KLIO_WIN_INPUT): items chosen by their titles' path, as clicks choose
// them, and shortcut keys.

import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.painter.ColorPainter
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyShortcut
import androidx.compose.ui.window.MenuBar
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

fun main() {
    application(exitProcessOnExit = false) {
        var wrap by remember { mutableStateOf(false) }
        var zoom by remember { mutableStateOf(100) }
        var recent by remember { mutableStateOf(listOf("notes.txt")) }
        var done by remember { mutableStateOf(false) }
        Window(
            onCloseRequest = ::exitApplication,
            title = "menus",
            state = rememberWindowState(width = 300.dp, height = 200.dp),
        ) {
            MenuBar {
                Menu("File", mnemonic = 'F') {
                    Item("New", shortcut = KeyShortcut(Key.N, ctrl = true, shift = true)) {
                        println("new")
                    }
                    Item("Open", icon = ColorPainter(Color(0xFF3366CC)), mnemonic = 'O') {
                        println("open")
                        recent = recent + "plan.md"
                    }
                    Menu("Open Recent") {
                        for (name in recent) {
                            Item(name) { println("open recent $name") }
                        }
                    }
                    Separator()
                    Item("Print", enabled = false, shortcut = KeyShortcut(Key.P, ctrl = true, shift = true)) {
                        println("print (never)")
                    }
                    Item("Close", shortcut = KeyShortcut(Key.W, ctrl = true, shift = true)) {
                        println("close")
                        done = true
                    }
                }
                Menu("View") {
                    CheckboxItem("Word Wrap", checked = wrap) {
                        println("word wrap -> $it")
                        wrap = it
                    }
                    Separator()
                    for (level in listOf(100, 150, 200)) {
                        RadioButtonItem("Zoom $level%", selected = zoom == level) {
                            println("zoom $level%")
                            zoom = level
                        }
                    }
                }
                Menu("Help", enabled = false) {
                    Item("About") { println("about (never)") }
                }
            }
            LaunchedEffect(Unit) {
                withTimeoutOrNull(10_000) { snapshotFlow { done }.first { it } }
                repeat(3) { withFrameNanos { } }
                exitApplication()
            }

        }
    }
}
