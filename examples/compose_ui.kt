// Compose UI core on a headless software canvas — the first increment of the
// Compose-UI stack. A @Composable Column/Row/Box/Text tree emits LayoutNodes
// through the compose runtime; a measure pass places them (arrangement + padding
// + size) and a draw pass paints backgrounds + 3x5 bitmap-font text into a
// software pixel buffer, dumped as ASCII (each colour a letter, '.' is empty). A
// state write recomposes and re-renders (the counter text updates) — the same
// node-emission + measure/layout/draw path a real Compose UI uses, minus Skia.

import androidx.compose.runtime.mutableStateOf
import klio.compose.ui.Box
import klio.compose.ui.Color
import klio.compose.ui.Column
import klio.compose.ui.Modifier
import klio.compose.ui.Row
import klio.compose.ui.Text
import klio.compose.ui.uiRenderer

fun main() {
    val count = mutableStateOf(0)

    val ui = uiRenderer(20, 18) {
        Column(Modifier.None.background(Color.Gray).border(Color.Black).padding(1)) {
            Text("KLIO", Color.Black, Modifier.None)
            Row(Modifier.None.padding(1)) {
                Box(Modifier.None.size(3, 4).background(Color.Red).border(Color.White))
                Box(Modifier.None.size(3, 4).background(Color.Green).border(Color.White))
                Box(Modifier.None.size(3, 4).background(Color.Blue).border(Color.White))
            }
            Text("N " + count.value, Color.White, Modifier.None)
        }
    }

    println("--- frame 0 (count=0) ---")
    println(ui.displayList())
    count.value = 3
    println("--- frame 1 (count=3) ---")
    println(ui.recomposeDisplayList())
    ui.dispose()
}
