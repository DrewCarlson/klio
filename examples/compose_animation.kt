// The real androidx.compose.animation.core easing curves, vendored verbatim as a
// klio pack on top of ui-graphics (CubicBezierEasing decomposes through the
// graphics Bezier bounds helpers). Deterministic output for the harness.
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.CubicBezierEasing

fun main() {
    val custom = CubicBezierEasing(0.4f, 0.0f, 0.2f, 1.0f)
    for (i in 0..4) {
        val t = i / 4f
        println("t=$t linear=${LinearEasing.transform(t)} fastOutSlowIn=${FastOutSlowInEasing.transform(t)} custom=${custom.transform(t)}")
    }
    println("linearOutSlowIn(0.25)=${LinearOutSlowInEasing.transform(0.25f)}")
}
