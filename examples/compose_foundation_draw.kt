// The real `androidx.compose.foundation` draw modifiers through the real UI
// engine: `Modifier.background` (colour + shape), `Modifier.border`, and
// `Image` over an `ImageBitmap` painted with the real graphics stack.
//
// Each exercises a dispatch path that used to fail. `border` installs a
// `CacheDrawModifierNode` whose cached draw block is a
// `CacheDrawScope.() -> DrawResult` FIELD, invoked with its receiver passed
// positionally. `Image` reaches `DrawScope.drawImage`, whose concrete
// interface-default overload delegates BY NAME to its abstract sibling — an
// overload the class method table does not carry, so the walk used to re-select
// the default and recurse forever.
//
// Output is the engine's own account of the pass (node count, measured sizes),
// so it is deterministic with or without a Skia backend; the PNG is the visual
// proof when one is present.
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Canvas as GCanvas
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.klio.renderComposeToPng
import androidx.compose.ui.unit.dp

fun main() {
    // An ImageBitmap painted magenta through the real graphics stack.
    val bmp = ImageBitmap(20, 20)
    val paint = Paint().also { it.color = Color.Magenta }
    GCanvas(bmp).drawRect(0f, 0f, 20f, 20f, paint)
    println("bitmap=" + bmp.width + "x" + bmp.height)

    val ok = renderComposeToPng(120, 140, 1f, "/tmp/klio_compose_foundation_draw.png") {
        Column {
            Box(Modifier.size(40.dp).background(Color.Red))
            Box(Modifier.size(40.dp).background(Color.Green, CircleShape))
            Box(Modifier.size(40.dp).border(4.dp, Color.Black))
            Image(bmp, contentDescription = null, modifier = Modifier.size(20.dp))
        }
    }
    println("drew=" + ok)
}
