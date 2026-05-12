fun main() {
    val xs = listOf(1, 2, 3, 4, 5)
    val w1 = xs.windowed(size = 3, step = 1)
    println(w1)
    val w2 = xs.windowed(step = 2, size = 2)
    println(w2)
    val w3 = xs.windowed(size = 3, step = 2, partialWindows = true)
    println(w3)
}
