// Word-wrapped, multi-line, aligned text via the Paragraph composable. Unlike
// Text (single line), Paragraph wraps within a fixed width and grows in height to
// fit; the Skia backend wraps on real font metrics, and headless layout (used
// here, and by the corpus) estimates the line count from the nominal mono advance.
// The emitted `para` display-list op carries x y width size align color + text.

import klio.compose.ui.ALIGN_CENTER
import klio.compose.ui.ALIGN_LEFT
import klio.compose.ui.ALIGN_RIGHT
import klio.compose.ui.Color
import klio.compose.ui.Column
import klio.compose.ui.Modifier
import klio.compose.ui.Paragraph
import klio.compose.ui.Spacer
import klio.compose.ui.uiRenderer

fun main() {
    val ui = uiRenderer(80, 68) {
        Column(Modifier.None.background(Color(0xFF10141A.toInt())).padding(2)) {
            Paragraph("The quick brown fox jumps over the lazy dog and wraps neatly.", Color.White, 60, ALIGN_LEFT, Modifier.None)
            Spacer(1, 2)
            Paragraph("A centered heading", Color.Cyan, 60, ALIGN_CENTER, Modifier.None)
            Spacer(1, 2)
            Paragraph("right aligned note", Color.Green, 60, ALIGN_RIGHT, Modifier.None)
        }
    }
    println(ui.displayList())
}
