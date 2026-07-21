// Compose UI — the full interactive loop on a headless software canvas. A
// clickable Button + a counter Text are laid out and drawn to the pixel canvas;
// a simulated pointer click hit-tests the button, invokes its onClick (which
// writes state), recomposes, and re-renders — input -> state -> recompose ->
// draw, the same loop a real Compose UI runs, driven deterministically.

import androidx.compose.runtime.mutableStateOf
import klio.compose.ui.Button
import klio.compose.ui.Color
import klio.compose.ui.Column
import klio.compose.ui.Modifier
import klio.compose.ui.Text
import klio.compose.ui.uiRenderer

fun main() {
    val count = mutableStateOf(0)
    val hovered = mutableStateOf(false)

    val ui = uiRenderer(20, 16) {
        Column(Modifier.None.background(Color.Gray).padding(1)) {
            Button(
                "ADD",
                Modifier.None
                    .background(if (hovered.value) Color.Blue else Color.Blue)
                    .onHover { hovered.value = it },
            ) {
                count.value = count.value + 1
            }
            Text("N " + count.value, Color.Black, Modifier.None.padding(1))
        }
    }

    println("--- initial (count=0) ---")
    println(ui.displayList())

    // The ADD button sits at the top-left of the Gray column (inset by padding);
    // click inside it. Each click increments the counter and re-renders.
    println("--- after click #1 ---")
    println(ui.click(3, 3))
    println("--- after click #2 ---")
    println(ui.click(3, 3))

    // Moving within the same hover region again does not write new state. The
    // renderer returns the already-recorded frame instead of rebuilding it.
    val hoverFrame = ui.hover(3, 3, 1)
    val repeatedHoverFrame = ui.hover(3, 3, 1)
    println("--- unchanged hover reused frame ---")
    println(hoverFrame === repeatedHoverFrame)

    ui.dispose()
}
