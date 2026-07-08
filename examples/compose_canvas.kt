// The real androidx.compose.ui.graphics.Canvas — drawing rectangles, circles,
// rounded rectangles, a path, and a line with real Paint objects onto an
// offscreen Skia surface, saved as a PNG. `klioDrawToPng` wraps a KlioCanvas
// (the Canvas actual) over the shim; the coming graphics.drawscope.DrawScope
// render path drives the same Canvas. Requires the Skia library + a display-less
// backend; headless-safe (returns false with no backend).
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.PaintingStyle
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.klioDrawToPng

fun main() {
    val drew = klioDrawToPng(200, 160, "/tmp/klio_compose_canvas.png") {
        drawRect(0f, 0f, 200f, 160f, Paint().apply { color = Color(0xFF10141A.toInt()) })
        drawCircle(Offset(60f, 60f), 40f, Paint().apply { color = Color.Cyan })
        drawRoundRect(110f, 30f, 180f, 90f, 12f, 12f, Paint().apply { color = Color(0xFF2196F3.toInt()) })
        val star = Path().apply {
            moveTo(100f, 110f); lineTo(120f, 150f); lineTo(75f, 125f)
            lineTo(125f, 125f); lineTo(80f, 150f); close()
        }
        drawPath(star, Paint().apply { color = Color.Yellow })
        drawLine(
            Offset(10f, 150f),
            Offset(190f, 150f),
            Paint().apply { color = Color.White; strokeWidth = 3f },
        )
        // A stroked outline over the circle.
        drawCircle(Offset(60f, 60f), 40f, Paint().apply {
            color = Color.White
            style = PaintingStyle.Stroke
            strokeWidth = 2f
        })
    }
    println("canvas drew=$drew")
}
