// Compose foundation-layout API — the layout primitives' value types and
// Modifier factories, exercised through the real vendored
// androidx.compose.foundation.layout pack. Composing Box/Row/Column into a
// rendered tree additionally needs the ui Owner; this shows the API surface
// that resolves and computes today.

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

fun main() {
    val p = PaddingValues(start = 4.dp, top = 8.dp, end = 4.dp, bottom = 12.dp)
    println("top=${p.calculateTopPadding()}")
    println("bottom=${p.calculateBottomPadding()}")
    println("arrangement=${Arrangement.SpaceBetween}")

    val m = Modifier.padding(8.dp).size(100.dp).fillMaxWidth()
    println("modifier chain built=${m != Modifier}")
}
