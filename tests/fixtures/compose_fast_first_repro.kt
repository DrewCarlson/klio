import androidx.compose.ui.util.fastFirst

class FastFirstOwner {
    inline fun fastForEach(block: (Any?) -> Unit) {
        block(null)
    }

    fun run(): String =
        listOf("miss", "hit").fastFirst { it == "hit" }
}

fun main() {
    println(FastFirstOwner().run())
}
