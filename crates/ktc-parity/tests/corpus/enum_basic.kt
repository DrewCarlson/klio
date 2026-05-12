enum class Color {
    RED, GREEN, BLUE
}

fun main() {
    val r = Color.RED
    println(r)
    println(r.name)
    println(r.ordinal)
    println(Color.GREEN.ordinal)
    println(Color.BLUE.name)
}
