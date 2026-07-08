// A live windowed Compose UI app, rendered by Skia into a real (SDL) window. A
// clickable counter Button: clicking it writes state, recomposes, and redraws —
// the full input -> state -> recompose -> draw loop, on screen. Run with the Skia
// library available (LD_LIBRARY_PATH=zig-out/lib) on a machine with a display;
// with no windowing backend runApp returns immediately (headless-safe), so this
// example has no baked corpus output.

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import klio.compose.ui.Button
import klio.compose.ui.Color
import klio.compose.ui.Column
import klio.compose.ui.Modifier
import klio.compose.ui.Spacer
import klio.compose.ui.Text
import klio.compose.ui.runApp

fun main() {
    // 64x40 layout units at 8x scale = a 512x320 window. maxFrames = -1 runs
    // until the window is closed.
    runApp(64, 40, 8, "klio compose", -1) {
        var count by remember { mutableStateOf(0) }
        Column(Modifier.None.background(Color(0xFF10141A.toInt())).padding(2)) {
            Text("KLIO COMPOSE", Color.Cyan, Modifier.None)
            Spacer(1, 2)
            Button("ADD", Modifier.None.background(Color.Blue).cornerRadius(1)) { count++ }
            Spacer(1, 2)
            Text("COUNT " + count, Color.White, Modifier.None)
        }
    }
}
