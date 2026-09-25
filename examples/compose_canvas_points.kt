// corpus: skia
// DrawScope.drawPoints in its three modes (dots, pairs as lines, a polyline),
// a round and a square cap, drawRawPoints, and Canvas.concat of a matrix with
// perspective, read back from the rendered frame's pixels. The values are the
// ones Compose Desktop 1.12.0 renders.
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Matrix
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.PixelMap
import androidx.compose.ui.graphics.PointMode
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.klio.KlioComposeScene

fun render(draw: DrawScope.() -> Unit): PixelMap {
    val scene = KlioComposeScene(100, 100)
    scene.setContent { Canvas(Modifier.fillMaxSize().background(Color.White), onDraw = draw) }
    val pixels = scene.render().toPixelMap()
    scene.dispose()
    return pixels
}

fun hex(c: Color): String = (c.toArgb().toLong() and 0xFFFFFFFFL).toString(16).uppercase().padStart(8, '0')

fun show(name: String, pixels: PixelMap, points: List<Pair<Int, Int>>) {
    println("$name: " + points.joinToString(" ") { (x, y) -> "($x,$y)=${hex(pixels[x, y])}" })
}

fun main() {
    val points = listOf(Offset(20f, 20f), Offset(50f, 20f), Offset(50f, 50f), Offset(20f, 50f))

    show("dots round", render {
        drawPoints(points, PointMode.Points, Color.Red, strokeWidth = 10f, cap = StrokeCap.Round)
    }, listOf(20 to 20, 24 to 24, 50 to 50, 35 to 35))
    show("dots square", render {
        drawPoints(points, PointMode.Points, Color.Red, strokeWidth = 10f, cap = StrokeCap.Square)
    }, listOf(20 to 20, 24 to 24, 50 to 50, 35 to 35))
    show("lines", render {
        drawPoints(points, PointMode.Lines, Color.Blue, strokeWidth = 4f)
    }, listOf(35 to 20, 50 to 35, 35 to 50, 20 to 35))
    show("polygon", render {
        drawPoints(points, PointMode.Polygon, Color.Blue, strokeWidth = 4f)
    }, listOf(35 to 20, 50 to 35, 35 to 50, 20 to 35))
    show("raw points", render {
        drawIntoCanvas {
            it.drawRawPoints(
                PointMode.Points,
                floatArrayOf(30f, 30f, 70f, 70f),
                Paint().apply { color = Color.Green; strokeWidth = 8f; strokeCap = StrokeCap.Round },
            )
        }
    }, listOf(30 to 30, 70 to 70, 50 to 50))
    show("perspective", render {
        drawIntoCanvas {
            // A matrix whose last row divides by w = 1 + x / 200: the far side shrinks.
            val m = Matrix()
            m[0, 3] = 1f / 200f
            it.concat(m)
            it.drawRect(0f, 0f, 100f, 100f, Paint().apply { color = Color.Red })
        }
    }, listOf(10 to 95, 60 to 60, 60 to 75, 80 to 20))
}
