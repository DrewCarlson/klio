// corpus: skia
// ui-graphics' shaders, color filters, path effects, render effects, vertices
// and image decoding, read back from the rendered frame's pixels: sweep,
// linear and radial gradients (interpolated premultiplied, as skiko's are), an
// image shader, a composite shader and a local matrix; matrix and lighting
// color filters; dashes, rounded corners, a chain and a stamp; the stroke miter
// limit; offset and blur render effects; drawVertices with per-vertex colors;
// and decodeToImageBitmap over PNG bytes. The values are the ones Compose
// Desktop 1.12.0 renders.
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.CompositeShader
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.ImageShader
import androidx.compose.ui.graphics.LinearGradientShader
import androidx.compose.ui.graphics.OffsetEffect
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.PixelMap
import androidx.compose.ui.graphics.RadialGradientShader
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.StampedPathEffectStyle
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.VertexMode
import androidx.compose.ui.graphics.Vertices
import androidx.compose.ui.graphics.decodeToImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.unit.dp

fun render(draw: DrawScope.() -> Unit): PixelMap {
    val scene = KlioComposeScene(100, 100)
    scene.setContent { Canvas(Modifier.fillMaxSize().background(Color.White), onDraw = draw) }
    val pixels = scene.render().toPixelMap()
    scene.dispose()
    return pixels
}

fun hex(c: Color): String = (c.toArgb().toLong() and 0xFFFFFFFFL).toString(16).uppercase().padStart(8, '0')

fun show(name: String, pixels: PixelMap, points: List<Pair<Int, Int>>) {
    println("$name: " + points.joinToString(" ") { (x, y) -> "($x,$y)=${hex(pixels[x, y])}" })
}

fun hexBytes(s: String): ByteArray = ByteArray(s.length / 2) { s.substring(2 * it, 2 * it + 2).toInt(16).toByte() }

// A 3 x 2 PNG: red, green, blue over white, black, transparent.
const val PNG = "89504e470d0a1a0a0000000d49484452000000030000000208060000009d74661a0000001849444154789c63f8cfc0f01f0c19fe034920600009000100a0790af67d0548670000000049454e44ae426082"

fun main() {
    show("sweep", render {
        drawRect(Brush.sweepGradient(listOf(Color.Red, Color.Blue, Color.Red), Offset(50f, 50f)))
    }, listOf(90 to 50, 50 to 90, 10 to 50, 50 to 10))
    show("linear to transparent", render {
        drawRect(Brush.horizontalGradient(listOf(Color.Red, Color.Transparent)))
    }, listOf(10 to 50, 50 to 50, 90 to 50))
    show("radial stops", render {
        drawRect(Brush.radialGradient(0f to Color.Blue, 0.5f to Color.Green, 1f to Color.Red, center = Offset(50f, 50f), radius = 40f))
    }, listOf(50 to 50, 70 to 50, 85 to 50, 95 to 95))
    show("linear mirror", render {
        drawRect(Brush.linearGradient(listOf(Color.Black, Color.White), Offset(0f, 0f), Offset(25f, 0f), TileMode.Mirror))
    }, listOf(5 to 5, 20 to 5, 30 to 5, 45 to 5))

    val tile = ImageBitmap(2, 2)
    androidx.compose.ui.graphics.Canvas(tile).apply {
        drawRect(0f, 0f, 1f, 1f, Paint().apply { color = Color.Red })
        drawRect(1f, 0f, 2f, 1f, Paint().apply { color = Color.Green })
        drawRect(0f, 1f, 1f, 2f, Paint().apply { color = Color.Blue })
        drawRect(1f, 1f, 2f, 2f, Paint().apply { color = Color.Yellow })
    }
    show("image shader", render {
        drawRect(ShaderBrush(ImageShader(tile, TileMode.Repeated, TileMode.Repeated)))
    }, listOf(0 to 0, 1 to 0, 0 to 1, 1 to 1, 10 to 11, 51 to 50))
    show("composite shader", render {
        val dst = LinearGradientShader(Offset(0f, 0f), Offset(100f, 0f), listOf(Color.Red, Color.Blue))
        val src = RadialGradientShader(Offset(50f, 50f), 50f, listOf(Color.White, Color.Black))
        drawRect(ShaderBrush(CompositeShader(dst, src, BlendMode.Multiply)))
    }, listOf(50 to 50, 10 to 50, 90 to 50, 50 to 5))

    show("saturation 0", render {
        drawRect(Color.Red, colorFilter = ColorFilter.colorMatrix(ColorMatrix().apply { setToSaturation(0f) }))
    }, listOf(50 to 50))
    show("color matrix offset", render {
        val m = ColorMatrix(floatArrayOf(0.5f, 0f, 0f, 0f, 64f, 0f, 1f, 0f, 0f, 32f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 0f, 1f, 0f))
        drawRect(Color(0xFFC08040), colorFilter = ColorFilter.colorMatrix(m))
    }, listOf(50 to 50))
    show("lighting", render {
        drawRect(Color(0xFFC08040), colorFilter = ColorFilter.lighting(Color(0xFF808080), Color(0xFF000040)))
    }, listOf(50 to 50))

    show("dash", render {
        drawLine(Color.Black, Offset(0f, 50f), Offset(100f, 50f), strokeWidth = 4f, pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 10f)))
    }, listOf(5 to 50, 15 to 50, 25 to 50, 35 to 50))
    show("dash phase", render {
        drawLine(Color.Black, Offset(0f, 50f), Offset(100f, 50f), strokeWidth = 4f, pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 10f), 5f))
    }, listOf(2 to 50, 7 to 50, 12 to 50, 17 to 50))
    show("corner", render {
        drawRect(Color.Black, Offset(20f, 20f), Size(60f, 60f), style = Stroke(width = 4f, pathEffect = PathEffect.cornerPathEffect(20f)))
    }, listOf(20 to 20, 22 to 50, 50 to 22, 26 to 26))
    show("chain", render {
        val effect = PathEffect.chainPathEffect(PathEffect.dashPathEffect(floatArrayOf(10f, 10f)), PathEffect.cornerPathEffect(20f))
        drawRect(Color.Black, Offset(20f, 20f), Size(60f, 60f), style = Stroke(width = 4f, pathEffect = effect))
    }, listOf(20 to 20, 22 to 50, 50 to 22, 26 to 26))
    show("stamp", render {
        val square = Path().apply { addRect(androidx.compose.ui.geometry.Rect(-3f, -3f, 3f, 3f)) }
        drawLine(Color.Black, Offset(0f, 50f), Offset(100f, 50f), strokeWidth = 1f,
            pathEffect = PathEffect.stampedPathEffect(square, 20f, 0f, StampedPathEffectStyle.Translate))
    }, listOf(0 to 50, 10 to 50, 20 to 50, 40 to 52))
    for (limit in listOf(1f, 10f)) {
        show("miter $limit", render {
            val v = Path().apply { moveTo(20f, 80f); lineTo(50f, 20f); lineTo(80f, 80f) }
            drawIntoCanvas {
                it.drawPath(v, Paint().apply {
                    color = Color.Black
                    style = androidx.compose.ui.graphics.PaintingStyle.Stroke
                    strokeWidth = 10f
                    strokeJoin = StrokeJoin.Miter
                    strokeMiterLimit = limit
                })
            }
        }, listOf(50 to 12, 50 to 16, 50 to 22))
    }

    for ((name, effect) in listOf(
        "offset" to OffsetEffect(null, Offset(10f, 0f)),
        "blur then offset" to OffsetEffect(BlurEffect(3f, 3f), Offset(10f, 0f)),
    )) {
        val scene = KlioComposeScene(100, 100)
        scene.setContent {
            Box(Modifier.fillMaxSize().background(Color.White)) {
                Box(Modifier.offset(30.dp, 30.dp).size(40.dp).graphicsLayer { renderEffect = effect }.background(Color.Red))
            }
        }
        show(name, scene.render().toPixelMap(), listOf(35 to 50, 45 to 50, 75 to 50, 82 to 50))
        scene.dispose()
    }

    show("vertices", render {
        drawIntoCanvas {
            val vertices = Vertices(
                VertexMode.Triangles,
                listOf(Offset(10f, 10f), Offset(90f, 10f), Offset(50f, 90f)),
                listOf(Offset(0f, 0f), Offset(0f, 0f), Offset(0f, 0f)),
                listOf(Color.Red, Color.Green, Color.Blue),
                listOf(0, 1, 2),
            )
            it.drawVertices(vertices, BlendMode.Dst, Paint())
        }
    }, listOf(12 to 11, 88 to 11, 50 to 87, 50 to 40, 5 to 90))

    val decoded = hexBytes(PNG).decodeToImageBitmap()
    val px = decoded.toPixelMap()
    println("decoded ${decoded.width}x${decoded.height}: " +
        (0 until decoded.height).joinToString(" | ") { y -> (0 until decoded.width).joinToString(" ") { x -> hex(px[x, y]) } })
    val bad = runCatching { byteArrayOf(1, 2, 3).decodeToImageBitmap() }
    println("bad bytes: ${bad.exceptionOrNull()?.let { it::class.simpleName + ": " + it.message }}")
}
