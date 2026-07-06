// Compose UI native rendering sink — the offscreen surface dump. The UI is
// composed + rasterized into the software pixel buffer, then a native host
// binding (src/compose_ui) encodes it into a real P6 PPM image, writes it to
// disk (best-effort), and returns a checksum of the encoded bytes. This is the
// headless "dumps a PNG/pixel buffer" backend the plan calls for — a native
// Skia/skiko binding would slot in the same seam as a richer DrawScope.

import klio.compose.ui.Box
import klio.compose.ui.Color
import klio.compose.ui.Column
import klio.compose.ui.Modifier
import klio.compose.ui.Text
import klio.compose.ui.uiRenderer

fun main() {
    val ui = uiRenderer(16, 10) {
        Column(Modifier.None.background(Color.Blue).border(Color.White).padding(1)) {
            Text("PPM", Color.White, Modifier.None)
            Box(Modifier.None.size(6, 3).background(Color.Red).border(Color.Yellow))
        }
    }
    println(ui.render())
    val checksum = ui.savePpm("/tmp/klio_compose_ui.ppm", 4)
    println("ppm checksum: " + checksum)
    ui.dispose()
}
