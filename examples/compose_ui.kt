// Compose UI core on a headless software canvas — the first increment of the
// Compose-UI stack. A @Composable Row/Column/Box tree of colored, sized boxes
// emits LayoutNodes through the compose runtime; a measure pass places them and a
// draw pass paints them into a software pixel buffer, dumped as ASCII (each color
// a letter, '.' is empty). A state write recomposes and re-renders — the same
// node-emission + layout + software-draw path a real Compose UI uses, minus Skia.

import androidx.compose.runtime.mutableStateOf
import klio.compose.ui.Box
import klio.compose.ui.Color
import klio.compose.ui.Column
import klio.compose.ui.Modifier
import klio.compose.ui.Row
import klio.compose.ui.uiRenderer

fun main() {
    val on = mutableStateOf(true)

    val ui = uiRenderer(16, 8) {
        Column(Modifier.None.background(Color.Gray).padding(1)) {
            Row(Modifier.None) {
                Box(Modifier.None.size(4, 2).background(Color.Red))
                Box(Modifier.None.size(4, 2).background(Color.Green))
            }
            Box(Modifier.None.size(6, 2).background(if (on.value) Color.Blue else Color.Yellow))
        }
    }

    println("--- frame 0 (on=true) ---")
    println(ui.render())
    on.value = false
    println("--- frame 1 (on=false) ---")
    println(ui.recomposeRender())
    ui.dispose()
}
