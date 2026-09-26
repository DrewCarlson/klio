// corpus: skia (the expected output is the one printed when the Skia shim renders)
// Compose Desktop's offscreen scenes. renderComposeScene draws a composable
// once into a Skia image. An ImageComposeScene keeps its composition: each
// render runs a frame at the time it is given, and pointer events reach the
// content between frames, so a click recomposes what the next frame draws.
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.renderComposeScene
import androidx.compose.ui.unit.dp
import androidx.compose.ui.use
import org.jetbrains.skia.Image

private fun Image.pixel(x: Int, y: Int): String =
    toComposeImageBitmap().toPixelMap()[x, y].toArgb().toUInt().toString(16)

@OptIn(ExperimentalComposeUiApi::class)
fun main() {
    val once = renderComposeScene(40, 20) {
        Box(Modifier.size(20.dp).background(Color.Red))
    }
    println("rendered ${once.width}x${once.height}: inside ${once.pixel(5, 5)}, outside ${once.pixel(30, 5)}")

    var clicks by mutableIntStateOf(0)
    ImageComposeScene(40, 40).use { scene ->
        scene.setContent {
            val color = if (clicks % 2 == 0) Color.Blue else Color.Green
            Box(Modifier.size(30.dp).background(color).clickable { clicks++ })
        }
        println("frame 0: ${scene.render(0).pixel(10, 10)}")
        scene.sendPointerEvent(PointerEventType.Press, Offset(10f, 10f))
        scene.sendPointerEvent(PointerEventType.Release, Offset(10f, 10f))
        println("clicks=$clicks, frame 1: ${scene.render(16_666_666).pixel(10, 10)}")
        println("content size ${scene.calculateContentSize()}, pending ${scene.hasInvalidations()}")
    }
}
