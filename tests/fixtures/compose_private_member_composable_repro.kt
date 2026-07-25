import androidx.compose.runtime.Composable
import androidx.compose.ui.klio.renderComposeToPng

class Host {
    @Composable
    internal fun outer(x: Int): Int {
        return inner(x = x)
    }

    @Composable
    private fun inner(x: Int): Int = x + 1
}

fun main() {
    renderComposeToPng(16, 16, 1f, "/tmp/klio_priv.png") {
        println("v=" + Host().outer(x = 1))
    }
    println("done")
}
