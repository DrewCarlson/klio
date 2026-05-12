fun main() {
    val x = 5
    if (x in 1..10) println("in range")
    val xs = listOf(1, 2, 3)
    if (2 in xs) println("found")
    val s = "hello"
    if ('e' in s) println("has e")
    val m = mapOf("a" to 1, "b" to 2)
    if ("a" in m) println("key a")
    println(7 in 1..10)
    println(99 in xs)
}
