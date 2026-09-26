// corpus: skia (the expected output is the one printed when the Skia shim renders)
// A window's content has a lifecycle of its own, as a Compose Desktop window's
// does: resumed while the window is focused, started while another window has
// the focus, and destroyed when the window closes, before its content goes.
// The focus changes and the close come from compose_window_lifecycle.input,
// scripted into the window ($KLIO_WIN_INPUT).
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner

fun main() {
    application(exitProcessOnExit = false) {
        Window(onCloseRequest = ::exitApplication, title = "lifecycle") {
            val lifecycle = LocalLifecycleOwner.current.lifecycle
            DisposableEffect(lifecycle) {
                val observer = LifecycleEventObserver { _, event -> println("lifecycle $event") }
                lifecycle.addObserver(observer)
                onDispose {
                    lifecycle.removeObserver(observer)
                    println("content disposed")
                }
            }
        }
    }
    println("application ended")
}
