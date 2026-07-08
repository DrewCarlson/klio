// The real androidx.compose.ui.graphics.Brush — SolidColor is the simplest
// brush: applying it to a Paint sets that flat colour (gradient brushes build
// but paint through the deferred Skia shaders). Pure Paint manipulation, so the
// applied channels print deterministically.
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.SolidColor

fun main() {
    val brush = SolidColor(Color(0xFFFF00FF.toInt()))
    val paint = Paint()
    brush.applyTo(Size(10f, 10f), paint, alpha = 1f)
    val c = paint.color
    println("r=${(c.red * 255f).toInt()} g=${(c.green * 255f).toInt()} b=${(c.blue * 255f).toInt()}")

    // A gradient brush constructs from its stops (painting it needs shaders).
    val gradient = Brush.verticalGradient(listOf(Color.Red, Color.Blue))
    println("gradient built: ${gradient !== brush}")
}
