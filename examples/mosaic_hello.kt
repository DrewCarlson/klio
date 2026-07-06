// Mosaic — a terminal UI on top of the compose runtime's node-emission path.
// A @Composable tree of Text/Row/Column emits MosaicNodes through ComposeNode
// into a MosaicNodeApplier; the node tree measures/lays-out/renders to text.
// A state write + recompose re-renders the changed nodes in place — the
// end-to-end proof of the Applier layer, driven synchronously to a String.

import androidx.compose.runtime.mutableStateOf
import com.jakewharton.mosaic.Column
import com.jakewharton.mosaic.Row
import com.jakewharton.mosaic.Text
import com.jakewharton.mosaic.mosaicRenderer

fun main() {
    val count = mutableStateOf(0)

    val ui = mosaicRenderer {
        Column {
            Text("Hello, mosaic!")
            Text("count is " + count.value)
            Row {
                Text("[")
                Text("#".repeat(count.value))
                Text("]")
            }
        }
    }

    println("--- frame 0 ---")
    print(ui.renderFrame())
    println()

    count.value = 3
    println("--- frame 1 (count=3) ---")
    print(ui.recomposeFrame())
    println()

    count.value = 7
    println("--- frame 2 (count=7) ---")
    print(ui.recomposeFrame())
    println()

    ui.dispose()
}
