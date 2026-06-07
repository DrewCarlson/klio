fun main() {
    val x = 7
    val label = when (x) {
        in 0..5 -> "low"
        in 6..10 -> "mid"
        else -> "high"
    }
    println(label)

    val parity = when {
        x % 2 == 0 -> "even"
        else -> "odd"
    }
    println(parity)
}
