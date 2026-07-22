// On-screen Compose scene for the iOS app host. Unlike scene.kt (which renders
// once to a PNG offscreen), this drives the real windowing path: `application`
// registers per-frame + input callbacks on the hosted surface and returns, and
// the app's CADisplayLink / UITouch handlers call back on the resident VM.
//
// Plain compose (no material3): a full-screen Box paints a background and a
// circle at the last touch point, so a tap visibly moves the circle — proving
// the touch path UITouch -> klio_dispatch_touch -> pointer processor -> state.
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.window.Window
import androidx.compose.ui.window.application

fun main() {
    application {
        // width/height are placeholders: a hosted (mobile) Window fills the
        // device surface, so these matter only on desktop.
        Window(onCloseRequest = ::exitApplication, title = "klio", width = 390, height = 844) {
            // One circle per active finger (multi-touch); a bar that tracks
            // accumulated scroll (wheel / trackpad). Both read the raw pointer
            // stream, so no CompositionLocal-heavy widgets are involved.
            var points by remember { mutableStateOf(listOf<Offset>()) }
            var scrollY by remember { mutableStateOf(0f) }
            Box(
                Modifier.fillMaxSize()
                    .background(Color(0xFF102A44))
                    .pointerInput(Unit) {
                        awaitPointerEventScope {
                            while (true) {
                                val e = awaitPointerEvent()
                                if (e.type == PointerEventType.Scroll) {
                                    scrollY += e.changes.first().scrollDelta.y
                                } else {
                                    points = e.changes.filter { it.pressed }.map { it.position }
                                }
                            }
                        }
                    }
                    .drawBehind {
                        // Scroll indicator: a blue bar that slides with scroll.
                        drawRect(Color(0xFF1E88E5), topLeft = Offset(40f, 200f + scrollY), size = Size(size.width - 80f, 80f))
                        for (p in points) drawCircle(Color(0xFFFFC107), radius = 90f, center = p)
                    },
            )
        }
    }
}
