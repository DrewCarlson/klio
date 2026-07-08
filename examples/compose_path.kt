// The real androidx.compose.ui.graphics.Path — building a path from primitive
// segments and higher-level shapes (rect / oval / rounded rect), then reading
// back its control-point bounds, convexity, and iterating its segments. Backed
// by klio's pure-Kotlin command buffer (higher-level shapes are decomposed into
// cubic segments when added), so it runs the genuine upstream Path surface.
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Path
import kotlin.math.roundToInt

private fun r(f: Float): Int = f.roundToInt()

private fun box(p: Path): String {
    val b = p.getBounds()
    return "${r(b.left)},${r(b.top)},${r(b.right)},${r(b.bottom)}"
}

fun main() {
    // A closed triangle from primitive move/line segments.
    val tri = Path()
    tri.moveTo(0f, 0f)
    tri.lineTo(40f, 0f)
    tri.lineTo(40f, 30f)
    tri.close()
    println("triangle bounds ${box(tri)} empty=${tri.isEmpty} convex=${tri.isConvex}")

    val types = StringBuilder()
    for (seg in tri) types.append(seg.type.name).append(' ')
    println("triangle segments ${types.toString().trim()}")

    // A single rectangle: reported convex.
    val rect = Path().apply { addRect(Rect(10f, 20f, 60f, 80f)) }
    println("rect bounds ${box(rect)} convex=${rect.isConvex}")

    // An oval, decomposed to four cubic segments; bounds equal the oval box.
    val oval = Path().apply { addOval(Rect(0f, 0f, 100f, 60f)) }
    println("oval bounds ${box(oval)} convex=${oval.isConvex}")

    // A rounded rectangle.
    val rr = Path().apply { addRoundRect(RoundRect(0f, 0f, 50f, 40f, CornerRadius(8f, 8f))) }
    println("roundrect bounds ${box(rr)} convex=${rr.isConvex}")

    // addPath copies another path with an offset.
    val moved = Path().apply { addPath(rect, Offset(100f, 100f)) }
    println("moved bounds ${box(moved)}")

    // Mutating a shape past a single primitive drops the convex flag.
    val mixed = Path().apply { addRect(Rect(0f, 0f, 10f, 10f)); lineTo(50f, 50f) }
    println("mixed convex=${mixed.isConvex} bounds ${box(mixed)}")
}
