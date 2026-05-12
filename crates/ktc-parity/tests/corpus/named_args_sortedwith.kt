fun main() {
    val xs = listOf(3, 1, 2)
    val s = xs.sortedWith(comparator = compareBy { it })
    println(s)
    val r = "hello".replace(oldValue = "l", newValue = "L")
    println(r)
}
