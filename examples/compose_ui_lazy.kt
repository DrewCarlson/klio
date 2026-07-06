// Compose UI foundation — a lazy list on the software canvas. LazyColumn composes
// only the items scrolled into view (the item content for off-screen indices
// never runs), so a 100-item list emits only a handful of nodes; scrolling
// recomposes a different window. Proof: the composed-item counter stays small,
// and the rendered window shifts. Each item is keyed by index so its state
// follows it. Built on N2 subcomposition's premise (constraint-driven content).

import androidx.compose.runtime.mutableStateOf
import klio.compose.ui.Box
import klio.compose.ui.Color
import klio.compose.ui.LazyColumn
import klio.compose.ui.Modifier
import klio.compose.ui.Text
import klio.compose.ui.uiRenderer

var itemsComposed = 0

fun main() {
    val scroll = mutableStateOf(0)

    val ui = uiRenderer(22, 20) {
        LazyColumn(
            itemCount = 100,
            itemHeight = 5,
            viewportHeight = 20,
            scrollOffset = scroll.value,
            modifier = Modifier.None.background(Color.Gray),
        ) { index ->
            itemsComposed += 1
            Box(Modifier.None.size(20, 4).background(if (index % 2 == 0) Color.Blue else Color.Green)) {
                Text("I " + index, Color.White, Modifier.None.padding(1))
            }
        }
    }

    println("--- scroll=0 (top of 100) ---")
    println(ui.render())
    println("items composed: " + itemsComposed + " of 100")

    scroll.value = 50
    println("--- scroll=50 (window shifted down 10) ---")
    println(ui.recomposeRender())
    println("items composed total: " + itemsComposed + " of 100")

    ui.dispose()
}
