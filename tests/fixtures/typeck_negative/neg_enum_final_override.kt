enum class Color {
    RED, GREEN, BLUE;

    override fun equals(other: Any?): Boolean = true
    override fun hashCode(): Int = 0
    override fun compareTo(other: Color): Int = 0
}

fun main() {
    println(Color.RED)
}
