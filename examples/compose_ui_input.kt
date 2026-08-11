// corpus: interactive — loops on a live window (maxFrames = -1) until the user closes it.
// A live windowed Compose UI app exercising the full input surface: keyboard,
// hover, and click. Click the text field and type (Backspace deletes); the ADD
// button highlights on hover and increments a counter on click; resizing the
// window relayouts. Run with the Skia library on a machine with a display:
//   LD_LIBRARY_PATH=zig-out/lib ./zig-out/bin/klio run examples/compose_ui_input.kt
// With no windowing backend runApp returns immediately (headless-safe), so this
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
import klio.compose.ui.TextField
import klio.compose.ui.runApp

fun main() {
    runApp(80, 52, 8, "klio input", -1) {
        var count by remember { mutableStateOf(0) }
        var name by remember { mutableStateOf("") }
        var hovered by remember { mutableStateOf(false) }
        Column(Modifier.None.background(Color(0xFF10141A.toInt())).padding(2)) {
            Text("KLIO INPUT", Color.Cyan, Modifier.None)
            Spacer(1, 2)
            Text("TYPE A NAME", Color.Gray, Modifier.None)
            TextField(
                name,
                { name = it },
                Modifier.None.width(60).background(Color(0xFF2A2E36.toInt())).border(Color.White),
            )
            Spacer(1, 1)
            Text("HELLO " + name, Color.Green, Modifier.None)
            Spacer(1, 2)
            Button(
                "ADD " + count,
                Modifier.None
                    .background(if (hovered) Color.Cyan else Color.Blue)
                    .cornerRadius(1)
                    .onHover { hovered = it },
            ) { count++ }
        }
    }
}
