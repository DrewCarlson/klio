fun main() {
    val xs = listOf(1, 2, 3, 4, 5, 6, 7)
    println(xs.chunked(3))
    println(xs.chunked(2))
    println(xs.windowed(3))
    println(xs.windowed(3, 2))
    println(xs.windowed(3, 2, true))
}
