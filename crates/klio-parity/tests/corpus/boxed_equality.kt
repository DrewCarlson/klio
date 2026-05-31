fun main() {
    println(listOf(1, 2, 3) == listOf(1L, 2L, 3L))
    println(listOf(1, 2, 3) == listOf(1, 2, 3))
    println(setOf(1, 2) == setOf(1L, 2L))
    println(mapOf(1 to "a") == mapOf(1L to "a"))
    println(mapOf(1 to "a") == mapOf(1 to "a"))
    println(listOf(1.0, 2.0) == listOf(1, 2))
    println(Pair(1, 2) == Pair(1L, 2L))
    println(Pair(1, 2) == Pair(1, 2))
    val a: Any = 1
    val b: Any = 1L
    val c: Any = 1
    println(a == b)
    println(a == c)
    val x: Long = 5
    println(x == 5L)
    println(listOf(1, 1, 2).toSet() == setOf(1, 2))
}
