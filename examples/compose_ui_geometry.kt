// Real androidx.compose.ui foundation — vendored verbatim from
// compose-multiplatform-core. Offset / Size / Rect (ui-geometry) and IntOffset /
// IntSize / Dp (ui-unit) are the actual upstream classes: inline value classes
// packing floats into a Long via ui-util's packFloats, with operators, distance,
// hit-testing, and Dp arithmetic — all running on klio (the klioMain layer only
// supplies the platform float-bit / round actuals).

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp

fun main() {
    val sum = Offset(1f, 2f) + Offset(10f, 20f)
    println("Offset sum = (" + sum.x + ", " + sum.y + ")")
    println("distance(3, 4) = " + Offset(3f, 4f).getDistance())

    val size = Size(120f, 80f)
    println("Size = " + size.width + " x " + size.height)

    val rect = Rect(Offset(10f, 10f), size)
    println("Rect right=" + rect.right + " bottom=" + rect.bottom)
    println("contains(50, 40) = " + rect.contains(Offset(50f, 40f)))
    println("contains(200, 40) = " + rect.contains(Offset(200f, 40f)))

    val io = IntOffset(5, 7) + IntOffset(2, 3)
    println("IntOffset sum = (" + io.x + ", " + io.y + ")")
    val isz = IntSize(64, 48)
    println("IntSize area = " + (isz.width * isz.height))

    println("16.dp + 8.dp = " + (16.dp + 8.dp).value)
    println("16.dp > 8.dp = " + (16.dp > 8.dp))
}
