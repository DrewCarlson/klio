fun main() {
    val xs = listOf(1, 2, 3, 4, 5)
    xs.forEach {
        if (it == 3) return@forEach
        println(it)
    }
}
