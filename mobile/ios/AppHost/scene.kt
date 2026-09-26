// Offscreen Compose scene for the mobile app hosts: one frame of a real
// Compose UI rendered to a PNG, proving Compose -> skiko -> Skia -> pixels
// without a window (the iOS offscreen launch and
// scripts/android-render-smoke.sh).
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.klio.renderComposeToPng
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

fun main(args: Array<String>) {
    val out = if (args.isNotEmpty()) args[0] else "render.png"
    val ok = renderComposeToPng(256, 192, 4f, out) {
        Column(Modifier.fillMaxSize().background(Color.Blue).border(1.dp, Color.White).padding(2.dp)) {
            BasicText("iOS", style = TextStyle(color = Color.White, fontSize = 10.sp))
            val shape = RoundedCornerShape(2.dp)
            Box(Modifier.size(24.dp, 14.dp).background(Color.Red, shape).border(1.dp, Color.Yellow, shape))
        }
    }
    println("rendered ok=$ok to $out")
}
