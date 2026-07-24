import androidx.compose.ui.util.fastCoerceAtLeast
import androidx.compose.ui.util.fastCoerceIn

fun main() {
    println(1f.fastCoerceAtLeast(0f))
    println(1f.fastCoerceIn(0f, 2f))
}
