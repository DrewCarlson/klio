// androidx.compose.ui.unit.Density — the real interface with member-extension
// conversions between px, Dp, and Sp. Its whole API is interface member
// extensions (`fun Dp.toPx()`, `fun Int.toDp()`, `fun TextUnit.toDp()`), invoked
// through a `with(density) { … }` scope — the pattern the compose layout system
// runs on.
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

fun main() {
    val density = Density(density = 2.0f, fontScale = 1.5f)
    with(density) {
        println("16.dp -> px: " + 16.dp.toPx())          // 32.0
        println("100 px -> dp: " + 100.toDp().value)      // 50.0
        println("12.sp -> dp: " + 12.sp.toDp().value)     // 18.0  (12 * 1.5)
        println("24.dp -> sp: " + 24.dp.toSp().value)     // 16.0  (24 / 1.5)
        println("48 px -> dp -> rounded px: " + 48.toDp().roundToPx())  // 48
    }
}
