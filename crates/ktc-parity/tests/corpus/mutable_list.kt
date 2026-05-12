fun main() {
    val xs = mutableListOf(1, 2, 3)
    xs.add(4)
    xs.add(5)
    println(xs)
    println(xs.size)
    xs.removeAt(0)
    println(xs)
    xs.clear()
    println(xs)
    println(xs.isEmpty())
}
