fun main() {
    val x = 100
    if (x !in 1..10) println("out of range")
    val xs = listOf(1, 2, 3)
    if (5 !in xs) println("not found")
    println(7 !in 1..10)
    println(2 !in xs)
}
