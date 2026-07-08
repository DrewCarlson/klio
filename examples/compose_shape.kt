// The real androidx.compose.ui.graphics.Shape / Outline — a Shape turns a size
// into an Outline (Rectangle / Rounded / Generic), the geometry the UI layer
// clips and draws. RectangleShape is the built-in; a custom Shape builds a
// Generic outline from a Path. Pure Kotlin (no Skia), so the outline kinds print
// deterministically.
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection

// A triangle shape: createOutline returns a Generic outline wrapping a Path.
object TriangleShape : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val path = Path().apply {
            moveTo(size.width / 2f, 0f)
            lineTo(size.width, size.height)
            lineTo(0f, size.height)
            close()
        }
        return Outline.Generic(path)
    }
}

fun describe(outline: Outline): String =
    when (outline) {
        is Outline.Rectangle -> "Rectangle ${outline.rect.width} x ${outline.rect.height}"
        is Outline.Rounded -> "Rounded ${outline.roundRect.width} x ${outline.roundRect.height}"
        is Outline.Generic -> "Generic bounds ${outline.bounds.width} x ${outline.bounds.height}"
    }

fun main() {
    val size = Size(80f, 50f)
    val ltr = LayoutDirection.Ltr
    val density = Density(1f)
    println(describe(RectangleShape.createOutline(size, ltr, density)))
    println(describe(TriangleShape.createOutline(size, ltr, density)))
}
