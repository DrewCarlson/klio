// On-screen Compose scene for the iOS app host. Unlike scene.kt (which renders
// once to a PNG offscreen), this drives the real windowing path: `application`
// registers a per-frame callback on the hosted surface and returns, and the
// app's CADisplayLink calls back each vsync to recompose and present to the
// CAMetalLayer. The Window fills the device surface automatically when hosted.
//
// Plain compose (no material3): a full-screen Box paints a background and a few
// shapes through a DrawScope. Real Compose -> Skia -> Metal -> screen.
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application

fun main() {
    application {
        // width/height are placeholders: a hosted (mobile) Window fills the
        // device surface, so these matter only on desktop.
        Window(onCloseRequest = ::exitApplication, title = "klio", width = 390, height = 844) {
            Box(Modifier.fillMaxSize().background(Color(0xFF102A44)).drawBehind {
                drawRect(Color(0xFF1E88E5), topLeft = Offset(48f, 96f), size = Size(size.width - 96f, 220f))
                drawRect(Color(0xFFE53935), topLeft = Offset(120f, 380f), size = Size(240f, 240f))
                drawCircle(Color(0xFFFFC107), radius = 110f, center = Offset(size.width / 2f, size.height - 220f))
            })
        }
    }
}
