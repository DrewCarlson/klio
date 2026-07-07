// Compose UI Skia rendering sink. The UI composes to a LayoutNode tree, the draw
// pass records a display list of draw ops, and the native Skia backend
// (src/compose_ui + libklio_skia) replays it onto a raster surface and encodes a
// real PNG. The display list printed below is the deterministic, backend-
// independent render artifact; savePng produces the actual image when the Skia
// library is available (a no-op otherwise).

import klio.compose.ui.Box
import klio.compose.ui.Color
import klio.compose.ui.Column
import klio.compose.ui.Modifier
import klio.compose.ui.Text
import klio.compose.ui.uiRenderer

fun main() {
    val ui = uiRenderer(16, 10) {
        Column(Modifier.None.background(Color.Blue).border(Color.White).padding(1)) {
            Text("PNG", Color.White, Modifier.None)
            Box(Modifier.None.size(6, 3).background(Color.Red).border(Color.Yellow).cornerRadius(1))
        }
    }
    println(ui.displayList(8))
    ui.savePng("/tmp/klio_compose_ui.png", 8)
    ui.dispose()
}
