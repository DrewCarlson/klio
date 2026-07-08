// The real androidx.compose.ui.graphics.Paint — the drawing-parameter object the
// DrawScope configures before rasterizing a shape: fill vs stroke, colour, stroke
// width/cap/join, blend mode, alpha, anti-aliasing. Backed by klio's plain value
// object; the shader / colour-filter / path-effect slots default to null.
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.PaintingStyle
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin

fun main() {
    val p = Paint()
    // Defaults mirror upstream: opaque black fill, hairline stroke, AA on.
    println("default fill=${p.style == PaintingStyle.Fill} aa=${p.isAntiAlias} alpha=${p.alpha}")
    println("default cap=${p.strokeCap} join=${p.strokeJoin} miter=${p.strokeMiterLimit}")
    println("default blend=${p.blendMode} shader=${p.shader == null}")

    // Configure a stroked, semi-transparent red paint.
    p.color = Color.Red
    p.style = PaintingStyle.Stroke
    p.strokeWidth = 6f
    p.strokeCap = StrokeCap.Round
    p.strokeJoin = StrokeJoin.Bevel
    p.alpha = 0.5f
    p.blendMode = BlendMode.Multiply

    val c = p.color
    println("stroke width=${p.strokeWidth} cap=${p.strokeCap} join=${p.strokeJoin}")
    println("color r=${c.red} g=${c.green} b=${c.blue} alpha=${p.alpha} blend=${p.blendMode}")
    println("is stroke=${p.style == PaintingStyle.Stroke}")
}
