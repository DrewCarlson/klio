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

    val ui = uiRenderer(20, 16) {
        Column(Modifier.None.background(Color.Gray).padding(1)) {
            Button("ADD", Modifier.None.background(Color.Blue)) {
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

    ui.dispose()
}
