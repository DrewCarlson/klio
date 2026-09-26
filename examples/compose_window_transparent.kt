// corpus: skia (the expected output is the one printed when the Skia shim renders)
// A transparent, undecorated Window, as Compose Desktop has one: the window
// has no background, so what its content leaves unpainted is see-through and
// the window composites its frame's alpha over what is behind it (on macOS and
// Windows; SDL2 windows have none, which the shim says). The window here is a
// blue disc on nothing; it shows a few frames and exits.
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.WindowPosition
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState

fun main() {
    var frames = 0
    application(exitProcessOnExit = false) {
        Window(
            onCloseRequest = ::exitApplication,
            title = "disc",
            undecorated = true,
            transparent = true,
            state = rememberWindowState(position = WindowPosition(200.dp, 200.dp), width = 120.dp, height = 120.dp),
        ) {
            Canvas(Modifier.fillMaxSize()) {
                frames += 1
                drawCircle(Color(0xFF1565C0), radius = size.minDimension / 2 - 10f)
            }
            LaunchedEffect(Unit) {
                repeat(10) { withFrameNanos { } }
                exitApplication()
            }
        }
    }
    println("the transparent window drew: ${frames > 0}")
}
