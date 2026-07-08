// Compose foundation layer — BorderStroke, RoundedCornerShape, and ScrollState
// (whose interaction plumbing builds a kotlinx MutableSharedFlow), running
// through the real vendored androidx.compose.foundation pack over the ui /
// foundation-layout / animation-core packs.

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.ScrollState
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.Color

fun main() {
    val border = BorderStroke(2.dp, Color.Blue)
    println("border=${border.width}")

    val shape = RoundedCornerShape(8.dp)
    println("shape built=${shape != null}")

    val scroll = ScrollState(initial = 0)
    println("scroll=${scroll.value}")
}
