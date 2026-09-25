// corpus: skia
// Modifier.graphicsLayer, property by property, read back from the rendered
// frame's pixels: alpha, scale, translation, the Z rotation, the X and Y
// rotations projected through the camera, the transform origin, a clip to a
// shape, the shadow and its colors, a color filter, a blend mode, a blur and
// the two compositing strategies. Then clicks through transformed layers: a
// pointer hits a node where its layer draws it, not where it was placed.
// The pixel values are those Compose Desktop 1.12.0 renders for the same
// content.
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.GraphicsLayerScope
import androidx.compose.ui.graphics.PixelMap
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.unit.dp

const val SIZE = 120

fun render(content: @Composable () -> Unit): PixelMap {
    val scene = KlioComposeScene(SIZE, SIZE)
    scene.setContent(content)
    val pixels = scene.render().toPixelMap()
    scene.dispose()
    return pixels
}

/** Clicks at each point in turn, then reports which ones the node took. */
fun clicks(points: List<Pair<Int, Int>>, content: @Composable (onClick: () -> Unit) -> Unit): List<Boolean> {
    var clicked = false
    val scene = KlioComposeScene(SIZE, SIZE)
    scene.setContent { content { clicked = true } }
    val hits = points.map { (x, y) ->
        clicked = false
        scene.click(x.toFloat(), y.toFloat())
        clicked
    }
    scene.dispose()
    return hits
}

fun hex(c: Color): String = (c.toArgb().toLong() and 0xFFFFFFFFL).toString(16).uppercase().padStart(8, '0')

/** A 40 px red box at (40, 40) on white, drawn through a layer of [block]. */
fun layerCase(name: String, points: List<Pair<Int, Int>>, background: Color = Color.White, block: GraphicsLayerScope.() -> Unit) {
    val pixels = render {
        Box(Modifier.fillMaxSize().background(background)) {
            Box(Modifier.offset(40.dp, 40.dp).size(40.dp).graphicsLayer(block).background(Color.Red))
        }
    }
    println("$name: " + points.joinToString(" ") { (x, y) -> "($x,$y)=${hex(pixels[x, y])}" })
}

fun main() {
    layerCase("none", listOf(39 to 60, 60 to 60, 80 to 60)) {}
    layerCase("alpha 0.5", listOf(60 to 60)) { alpha = 0.5f }
    layerCase("scale 0.5", listOf(45 to 45, 55 to 55, 65 to 65, 75 to 75)) { scaleX = 0.5f; scaleY = 0.5f }
    layerCase("scale x2 y0.5", listOf(25 to 60, 60 to 45, 60 to 55, 95 to 60)) { scaleX = 2f; scaleY = 0.5f }
    layerCase("translation", listOf(45 to 45, 65 to 55, 95 to 85)) { translationX = 20f; translationY = 10f }
    layerCase("rotationZ 45", listOf(42 to 42, 60 to 35, 85 to 60, 60 to 60)) { rotationZ = 45f }
    layerCase("rotationX 60", listOf(60 to 45, 60 to 51, 60 to 69, 60 to 75, 45 to 60, 79 to 60)) { rotationX = 60f }
    layerCase("rotationY 60", listOf(45 to 60, 51 to 60, 69 to 60, 75 to 60, 60 to 41, 60 to 79)) { rotationY = 60f }
    layerCase("rotationY 60 camera 3", listOf(51 to 60, 69 to 60, 60 to 41, 69 to 42)) { rotationY = 60f; cameraDistance = 3f }
    layerCase("origin 0,0 scale 0.5", listOf(45 to 45, 58 to 58, 65 to 65)) {
        transformOrigin = TransformOrigin(0f, 0f); scaleX = 0.5f; scaleY = 0.5f
    }
    layerCase("clip circle", listOf(42 to 42, 60 to 60, 77 to 60, 78 to 78)) { clip = true; shape = CircleShape }
    layerCase("shadow 8", listOf(60 to 60, 60 to 82, 60 to 86, 82 to 60, 60 to 38)) { shadowElevation = 8f }
    layerCase("shadow blue", listOf(60 to 82, 60 to 86, 82 to 60)) {
        shadowElevation = 8f; ambientShadowColor = Color.Blue; spotShadowColor = Color.Blue
    }
    layerCase("shadow circle", listOf(60 to 82, 44 to 44, 60 to 60)) { shadowElevation = 8f; shape = CircleShape }
    layerCase("color filter", listOf(60 to 60)) { colorFilter = ColorFilter.tint(Color.Blue) }
    layerCase("blend screen", listOf(30 to 30, 60 to 60), background = Color(0xFF808080)) { blendMode = BlendMode.Screen }
    layerCase("blur 4", listOf(36 to 60, 40 to 60, 44 to 60, 60 to 60)) { renderEffect = BlurEffect(4f, 4f) }

    for (strategy in listOf(CompositingStrategy.Offscreen, CompositingStrategy.ModulateAlpha)) {
        val pixels = render {
            Box(Modifier.fillMaxSize().background(Color.White)) {
                Box(Modifier.offset(40.dp, 40.dp).size(40.dp).graphicsLayer { alpha = 0.5f; compositingStrategy = strategy }) {
                    Box(Modifier.size(30.dp).background(Color.Red))
                    Box(Modifier.offset(10.dp, 10.dp).size(30.dp).background(Color.Blue))
                }
            }
        }
        val name = if (strategy == CompositingStrategy.Offscreen) "offscreen" else "modulate alpha"
        println("$name: " + listOf(45 to 45, 60 to 60, 75 to 75).joinToString(" ") { (x, y) -> "($x,$y)=${hex(pixels[x, y])}" })
    }

    val translated = clicks(listOf(20 to 20, 80 to 20)) { onClick ->
        Box(Modifier.size(40.dp).graphicsLayer { translationX = 60f }.clickable(onClick = onClick))
    }
    println("click translated at (20,20), (80,20): $translated")
    val scaled = clicks(listOf(45 to 45, 60 to 60)) { onClick ->
        Box(Modifier.offset(40.dp, 40.dp).size(40.dp).graphicsLayer { scaleX = 0.5f; scaleY = 0.5f }.clickable(onClick = onClick))
    }
    println("click scaled at (45,45), (60,60): $scaled")
    val rotated = clicks(listOf(42 to 42, 60 to 35)) { onClick ->
        Box(Modifier.offset(40.dp, 40.dp).size(40.dp).graphicsLayer { rotationZ = 45f }.clickable(onClick = onClick))
    }
    println("click rotated at (42,42), (60,35): $rotated")
    val clipped = clicks(listOf(42 to 42, 60 to 60)) { onClick ->
        Box(Modifier.offset(40.dp, 40.dp).size(40.dp).graphicsLayer { clip = true; shape = CircleShape }.clickable(onClick = onClick))
    }
    println("click clipped circle at (42,42), (60,60): $clipped")
}
