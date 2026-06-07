enum class Color {
    RED, GREEN, BLUE;

    fun hex(): String = when (this) {
        RED -> "#ff0000"
        GREEN -> "#00ff00"
        BLUE -> "#0000ff"
    }

    fun siblings(): Int = entries.size
}

fun main() {
    for (c in Color.entries) {
        println("${c} -> ${c.hex()} (of ${c.siblings()})")
    }
}
