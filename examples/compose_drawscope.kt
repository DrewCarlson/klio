// The real androidx.compose.ui.graphics.drawscope.DrawScope — the upstream
// drawing DSL a desktop Compose `Canvas { … }` composable ultimately runs. The
// vendored CanvasDrawScope drives klio's Canvas actual over the Skia shim;
// `klioRenderToPng` renders a DrawScope block to a PNG. Requires the Skia
// library; headless-safe (returns false with no backend).
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.klioRenderToPng
import androidx.compose.ui.graphics.drawscope.Stroke

fun main() {
    val drew = klioRenderToPng(200, 160, density = 1f, path = "/tmp/klio_compose_drawscope.png") {
        // `size` is the DrawScope's canvas size; drawRect(color) fills it.
        drawRect(Color(0xFF10141A.toInt()))
        drawCircle(Color.Cyan, radius = 40f, center = Offset(60f, 60f))
        // A stroked outline (Stroke's cap defaults to the companion's DefaultCap).
        drawCircle(Color.White, radius = 40f, center = Offset(60f, 60f), style = Stroke(width = 3f))
        // Positional colour + a named `cornerRadius`: the overloaded
        // drawRoundRect (color vs brush) must resolve to the colour variant.
        drawRoundRect(
            Color(0xFF2196F3.toInt()),
            Offset(110f, 30f),
            Size(70f, 60f),
            cornerRadius = CornerRadius(12f),
        )
        // A transform block: rotate wraps the draw in withTransform (a
        // two-lambda inline fn whose transform block runs on the DrawTransform).
        rotate(degrees = 12f, pivot = Offset(100f, 130f)) {
            val star = Path().apply {
                moveTo(100f, 110f); lineTo(120f, 150f); lineTo(75f, 125f)
                lineTo(125f, 125f); lineTo(80f, 150f); close()
            }
            drawPath(star, Color.Yellow)
        }
        drawLine(Color.White, Offset(10f, 150f), Offset(190f, 150f), strokeWidth = 3f)
    }
    println("drawscope drew=$drew")
}
