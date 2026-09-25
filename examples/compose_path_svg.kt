// ui-graphics' Path utilities over klio's Path: SVG path data out of a Path
// (Path.toSvg, as data or as a whole document) and back in (Path.addSvg), a
// PathHitTester that answers whether a point is inside a path's fill, and the
// path geometry helpers: the winding direction of a contour, a path divided
// into its contours, and a path reversed.
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.PathHitTester
import androidx.compose.ui.graphics.addSvg
import androidx.compose.ui.graphics.computeDirection
import androidx.compose.ui.graphics.divide
import androidx.compose.ui.graphics.reverse
import androidx.compose.ui.graphics.toSvg

fun main() {
    val twoSquares = Path().apply {
        addRect(Rect(0f, 0f, 10f, 10f), Path.Direction.Clockwise)
        addRect(Rect(20f, 20f, 50f, 50f), Path.Direction.Clockwise)
    }
    println(twoSquares.toSvg())
    print(twoSquares.toSvg(asDocument = true))

    val curve = Path().apply {
        moveTo(10f, 10f)
        cubicTo(20f, 20f, 30f, 30f, 40f, 40f)
        quadraticTo(50f, 50f, 60f, 60f)
    }
    println(curve.toSvg())

    // SVG in: relative commands, horizontal and vertical lines, and back out.
    val parsed = Path().apply { addSvg("M10 10 h20 v20 H10 Z m40 0 l10 10") }
    println(parsed.toSvg())

    // A square with a square hole: even-odd leaves the hole outside the fill.
    val ring = Path().apply {
        fillType = PathFillType.EvenOdd
        addRect(Rect(0f, 0f, 80f, 80f), Path.Direction.Clockwise)
        addRect(Rect(20f, 20f, 50f, 50f), Path.Direction.Clockwise)
    }
    val hits = PathHitTester(ring)
    for (p in listOf(Offset(10f, 10f), Offset(30f, 30f), Offset(70f, 70f), Offset(90f, 10f))) {
        println("ring contains $p: ${p in hits}")
    }

    println("clockwise square: ${Path().apply { addRect(Rect(0f, 0f, 10f, 10f), Path.Direction.Clockwise) }.computeDirection()}")
    println("counter-clockwise square: ${Path().apply { addRect(Rect(0f, 0f, 10f, 10f), Path.Direction.CounterClockwise) }.computeDirection()}")
    val contours = twoSquares.divide()
    println("contours: ${contours.size}: ${contours.joinToString(" | ") { it.toSvg() }}")
    println("reversed: ${curve.reverse().toSvg()}")
}
