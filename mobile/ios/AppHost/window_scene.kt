// On-screen Compose scene for the iOS app host. Unlike scene.kt (which renders
// once to a PNG offscreen), this drives the real windowing path: `application`
// registers a per-frame callback on the hosted surface and returns, and the
// app's CADisplayLink calls back each vsync to recompose and present to the
// CAMetalLayer. The Window fills the device surface automatically when hosted.
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application

fun main() {
    application {
        Window(onCloseRequest = ::exitApplication, title = "klio") {
            MaterialTheme {
                Box(Modifier.fillMaxSize().background(Color(0xFF102A44))) {
                    Column(Modifier.padding(24.dp)) {
                        Text("KLIO on iOS", color = Color.White)
                        Box(Modifier.padding(top = 16.dp).size(96.dp).background(Color(0xFFE0403A)))
                    }
                }
            }
        }
    }
}
