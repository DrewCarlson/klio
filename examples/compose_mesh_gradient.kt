// corpus: skia
// ui's MeshGradientPainter: a grid of colored vertices whose patches blend
// between their corners, with curved edges from Bezier control points and a
// bicubic color variant, painted through Modifier.paint and read back from the
// frame's pixels. The values are the ones Compose Desktop 1.12.0 renders.
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.paint
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.MeshGradientPainter
import androidx.compose.ui.graphics.PixelMap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.klio.KlioComposeScene

fun hex(c: Color): String = (c.toArgb().toLong() and 0xFFFFFFFFL).toString(16).uppercase().padStart(8, '0')

fun show(name: String, painter: MeshGradientPainter, points: List<Pair<Int, Int>>) {
    val scene = KlioComposeScene(100, 100)
    scene.setContent { Box(Modifier.fillMaxSize().paint(painter)) }
    val pixels: PixelMap = scene.render().toPixelMap()
    scene.dispose()
    println("$name: " + points.joinToString(" ") { (x, y) -> "($x,$y)=${hex(pixels[x, y])}" })
}

val corners = listOf(Color.Red, Color.Green, Color.Blue, Color.Yellow)

fun main() {
    val points = listOf(2 to 2, 97 to 2, 2 to 97, 97 to 97, 50 to 50, 25 to 75)
    show("one patch", MeshGradientPainter(1, 1) {
        for (row in 0..1) for (column in 0..1) {
            setVertex(row, column, Offset(column.toFloat(), row.toFloat()), corners[row * 2 + column])
        }
    }, points)
    show("bicubic", MeshGradientPainter(1, 1, hasBicubicColor = true) {
        for (row in 0..1) for (column in 0..1) {
            setVertex(row, column, Offset(column.toFloat(), row.toFloat()), corners[row * 2 + column])
        }
    }, points)
    show("two by two", MeshGradientPainter(2, 2) {
        for (row in 0..2) for (column in 0..2) {
            val color = if ((row + column) % 2 == 0) Color.White else Color.Black
            setVertex(row, column, Offset(column / 2f, row / 2f), color)
        }
    }, points + listOf(50 to 25, 75 to 50))
    show("curved", MeshGradientPainter(1, 1) {
        setVertex(0, 0, Offset(0f, 0f), Color.Red, rightControlPoint = Offset(0.3f, 0.4f))
        setVertex(0, 1, Offset(1f, 0f), Color.Green, leftControlPoint = Offset(-0.3f, 0.4f))
        setVertex(1, 0, Offset(0f, 1f), Color.Blue)
        setVertex(1, 1, Offset(1f, 1f), Color.Yellow)
    }, points + listOf(50 to 10, 50 to 30))
}
