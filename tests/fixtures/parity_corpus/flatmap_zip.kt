fun main() {
    val xs = listOf(1, 2, 3)
    println(xs.flatMap { listOf(it, it * 10) })

    val a = listOf("a", "b", "c")
    val b = listOf(1, 2, 3, 4)
    println(a.zip(b))
}
