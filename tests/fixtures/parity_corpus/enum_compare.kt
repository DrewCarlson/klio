enum class Color { RED, GREEN, BLUE }

fun main() {
    println(Color.RED < Color.BLUE)
    println(Color.BLUE > Color.RED)
    println(Color.GREEN <= Color.GREEN)
    println(Color.GREEN >= Color.RED)
    val xs = listOf(Color.BLUE, Color.RED, Color.GREEN)
    val sorted = xs.sorted()
    for (c in sorted) {
        println(c)
    }
}
