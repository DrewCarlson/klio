// Material 3's Icon over a vector: its tint (the content color by default,
// or one given), and an Image whose paint modifier takes an alpha and a
// color filter, read back from the rendered frame's pixels. The values are
// the ones Compose Desktop 1.12.0 renders.
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.toPixelMap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.klio.KlioComposeScene
import androidx.compose.ui.unit.dp

// A 24 by 24 square, drawn black, as an icon's vector is.
val square: ImageVector = ImageVector.Builder("square", 24.dp, 24.dp, 24f, 24f)
    .path(fill = SolidColor(Color.Black)) {
        moveTo(2f, 2f)
        lineTo(22f, 2f)
        lineTo(22f, 22f)
        lineTo(2f, 22f)
        close()
    }
    .build()

fun hex(argb: Int) = (argb.toLong() and 0xFFFFFFFFL).toString(16).padStart(8, '0')

fun main() {
    val scene = KlioComposeScene(200, 40)
    scene.setContent {
        MaterialTheme {
            Row {
                // The content color tints an icon given no tint.
                CompositionLocalProvider(LocalContentColor provides Color(0xFF1565C0)) {
                    Icon(square, contentDescription = null, modifier = Modifier.size(24.dp))
                }
                Icon(square, contentDescription = null, tint = Color(0xFFC62828), modifier = Modifier.size(24.dp))
                // Color.Unspecified leaves the vector's own color.
                Icon(square, contentDescription = null, tint = Color.Unspecified, modifier = Modifier.size(24.dp))
                Image(
                    rememberVectorPainter(square),
                    contentDescription = null,
                    modifier = Modifier.size(24.dp),
                    alpha = 0.5f,
                    colorFilter = ColorFilter.tint(Color(0xFF2E7D32)),
                )
            }
        }
    }
    scene.frame()
    val pixels = scene.render().toPixelMap()
    for ((name, x) in listOf("content color" to 12, "tint" to 36, "unspecified" to 60, "image alpha and filter" to 84)) {
        println("$name: center ${hex(pixels[x, 12].toArgb())}, edge ${hex(pixels[x - 11, 1].toArgb())}")
    }
    scene.dispose()
}
