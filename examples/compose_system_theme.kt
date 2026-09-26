// corpus: skia (the expected output is the one printed when the Skia shim renders)
// Content reads the system's theme through isSystemInDarkTheme: a window's,
// as a Compose Desktop window's does, and an offscreen scene's. The host's
// setting (macOS's appearance, Windows' app theme) answers it; the test
// runners fix it to light with KLIO_SYSTEM_THEME so the output does not
// depend on the host.
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application

fun main() {
    val scene = ImageComposeScene(40, 20) {
        println("offscreen dark theme: ${isSystemInDarkTheme()}")
    }
    scene.render()
    scene.close()
    application(exitProcessOnExit = false) {
        Window(onCloseRequest = ::exitApplication, title = "theme") {
            val dark = isSystemInDarkTheme()
            LaunchedEffect(Unit) {
                println("window dark theme: $dark")
                exitApplication()
            }
        }
    }
}
