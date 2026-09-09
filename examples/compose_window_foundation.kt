// The same desktop entrypoint as compose_window.kt with NO material3 in the
// program at all: `application { Window(...) }` over foundation only —
// Column/Box, `Modifier.background`/`padding`/`clickable`, and BasicText —
// so the window path is covered without a material dependency. Deterministic
// output in both environments (headless reports `window opened=false`).
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application

fun main() {
    // maxFrames bounds the loop so the example prints deterministically in
    // CI; a real app omits it and runs until the window closes.
    val opened = application(maxFrames = 3) {
        Window(onCloseRequest = ::exitApplication, title = "klio foundation", width = 320, height = 240) {
            var count by remember { mutableStateOf(0) }
            Column(Modifier.padding(8.dp)) {
                BasicText("count=$count")
                Box(
                    Modifier.background(Color(0xFF1B5E20))
                        .clickable { count += 1 }
                        .padding(8.dp)
                ) {
                    BasicText("Add", style = TextStyle(color = Color.White))
                }
            }
        }
    }
    println("window opened=" + opened)
    println("foundation window done")
}
