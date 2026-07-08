// Gradient brushes — Brush.linearGradient / radialGradient build real Skia
// gradient shaders (the brush serializes its colour stops + geometry, the shim
// reconstructs an SkShader). Painted through the real DrawScope brush path
// (drawRect(brush) / drawCircle(brush) -> configurePaint -> Brush.applyTo).
// Requires the Skia library; headless-safe (returns false with no backend).
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.klioRenderToPng

fun main() {
    val drew = klioRenderToPng(200, 160, density = 1f, path = "/tmp/klio_compose_gradient.png") {
        drawRect(Color(0xFF10141A.toInt()))
        val sunset = Brush.linearGradient(
            listOf(Color.Red, Color.Yellow, Color.Green),
            start = Offset(0f, 0f),
            end = Offset(200f, 0f),
        )
        drawRect(sunset, topLeft = Offset(20f, 20f), size = Size(160f, 50f))
        val glow = Brush.radialGradient(
            listOf(Color.White, Color.Blue),
            center = Offset(100f, 120f),
            radius = 45f,
        )
        drawCircle(glow, radius = 45f, center = Offset(100f, 120f))
    }
    println("gradient drew=$drew")
}
