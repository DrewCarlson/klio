// The real androidx.compose.ui.graphics.Path boolean operations (Path.op) —
// union / intersect / difference / xor of two paths, computed by the Skia
// shim's SkPathOps. Two overlapping squares are combined every way; the result
// path's control-point bounds and emptiness show the op worked.
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathOperation
import kotlin.math.roundToInt

private fun box(p: Path): String {
    val b = p.getBounds()
    return "${b.left.roundToInt()},${b.top.roundToInt()},${b.right.roundToInt()},${b.bottom.roundToInt()}"
}

fun main() {
    val a = Path().apply { addRect(Rect(0f, 0f, 40f, 40f)) }
    val b = Path().apply { addRect(Rect(20f, 20f, 60f, 60f)) }

    val union = Path()
    println("union ok=${union.op(a, b, PathOperation.Union)} bounds=${box(union)}")

    val intersect = Path()
    println("intersect ok=${intersect.op(a, b, PathOperation.Intersect)} bounds=${box(intersect)}")

    val difference = Path()
    println("difference ok=${difference.op(a, b, PathOperation.Difference)} empty=${difference.isEmpty}")

    val xor = Path()
    println("xor ok=${xor.op(a, b, PathOperation.Xor)} bounds=${box(xor)}")

    // Intersection of two disjoint squares is an empty path.
    val far = Path().apply { addRect(Rect(100f, 100f, 120f, 120f)) }
    val disjoint = Path()
    println("disjoint ok=${disjoint.op(a, far, PathOperation.Intersect)} empty=${disjoint.isEmpty}")
}
