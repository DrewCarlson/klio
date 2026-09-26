// corpus: skia (the expected output is the one printed when the Skia shim renders)
// A window keeps its application running, as Compose Desktop's does: the
// application below launches no effect of its own, so it runs for as long as
// its window is open. The window's onCloseRequest decides when that ends:
// it stays open on the first press of its close button and exits the
// application on the second. The scripted input
// (compose_window_lifetime.input) presses the close button twice.
import androidx.compose.material3.Text
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.compose.ui.window.rememberWindowState

fun main() {
    var drawn = false
    var closeRequests = 0
    application(exitProcessOnExit = false) {
        Window(
            onCloseRequest = {
                closeRequests += 1
                if (closeRequests == 1) {
                    println("close request 1: the window stays open (drawn=$drawn)")
                } else {
                    println("close request $closeRequests: the application exits")
                    exitApplication()
                }
            },
            title = "lifetime",
            state = rememberWindowState(width = 240.dp, height = 120.dp),
        ) {
            drawn = true
            Text("The application runs while this window is open.")
        }
    }
    println("application ended after $closeRequests close requests")
}
