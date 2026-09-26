// The real androidx.compose.ui.graphics.PathMeasure: the length of a path's
// first contour, the position and unit tangent at a distance along it, and the
// sub-path between two distances. It measures through Skia's contour measure,
// as Compose Desktop does: distances pin to 0..length, an empty contour is
// skipped, forceClosed adds the closing line. The output is Compose Desktop's.
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathMeasure
import androidx.compose.ui.graphics.PathSegment
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.round

private fun r(v: Float): String = (round(v * 1000f) / 1000f).toString()

private fun r1(v: Float): String = (round(v * 10f) / 10f).toString()

private fun o(p: Offset): String = if (p == Offset.Unspecified) "Unspecified" else "(${r(p.x)}, ${r(p.y)})"

private fun segments(p: Path): String {
    val sb = StringBuilder()
    for (seg in p) {
        if (seg.type == PathSegment.Type.Done) break
        sb.append(seg.type.name)
        val pts = seg.points
        var i = 0
        while (i < pts.size) {
            sb.append(" ${r(pts[i])},${r(pts[i + 1])}")
            i += 2
        }
        sb.append("; ")
    }
    return sb.toString().trimEnd()
}

fun main() {
    val measure = PathMeasure()
    println("no path: length=${measure.length} position=${o(measure.getPosition(1f))}")

    // A 3-4-5 line.
    measure.setPath(Path().apply { moveTo(0f, 0f); lineTo(30f, 40f) }, false)
    println("line: length=${r(measure.length)}")
    println("  at 25: ${o(measure.getPosition(25f))}, tangent ${o(measure.getTangent(10f))}")
    println("  at 99 pins to the end: ${o(measure.getPosition(99f))}")
    val piece = Path()
    println("  10..20 -> ${measure.getSegment(10f, 20f, piece)}: ${segments(piece)}")

    // An open corner, then the same corner closed by forceClosed.
    val corner = Path().apply { moveTo(0f, 0f); lineTo(10f, 0f); lineTo(10f, 10f) }
    measure.setPath(corner, false)
    println("open corner: length=${r(measure.length)}, at 15: ${o(measure.getPosition(15f))}")
    measure.setPath(corner, true)
    println("forced closed: length=${r(measure.length)}, at 25: ${o(measure.getPosition(25f))}")
    val span = Path()
    measure.getSegment(5f, 15f, span)
    println("  5..15: ${segments(span)}")
    println("  15..5 -> ${measure.getSegment(15f, 5f, Path())}")

    // A quadratic arch: the middle of its length is its apex.
    measure.setPath(Path().apply { moveTo(0f, 0f); quadraticTo(50f, 100f, 100f, 0f) }, false)
    val half = measure.length / 2f
    println("arch: length=${r1(measure.length)}, middle ${o(measure.getPosition(half))}, tangent ${o(measure.getTangent(half))}")
    val firstHalf = Path()
    measure.getSegment(0f, half, firstHalf)
    println("  first half: ${segments(firstHalf)}")

    // A circle of diameter 100 is ~314.16 around.
    measure.setPath(Path().apply { addOval(Rect(0f, 0f, 100f, 100f)) }, false)
    println("circle: within 0.5 of pi*100: ${abs(measure.length - (PI * 100).toFloat()) < 0.5f}")

    // A contour without length is skipped in favour of the next.
    val two = Path().apply { moveTo(0f, 0f); lineTo(0f, 0f); moveTo(5f, 5f); lineTo(5f, 25f) }
    measure.setPath(two, false)
    println("second contour: length=${r(measure.length)}, starts at ${o(measure.getPosition(0f))}")

    measure.setPath(null, false)
    println("cleared: length=${measure.length}")
}
