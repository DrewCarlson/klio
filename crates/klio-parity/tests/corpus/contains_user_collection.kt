class Bag(val items: List<Int>) {
    operator fun contains(x: Int): Boolean {
        for (i in items) if (i == x) return true
        return false
    }
}

fun main() {
    val b = Bag(listOf(1, 2, 3))
    println(2 in b)
    println(7 in b)
    println(7 !in b)
}
