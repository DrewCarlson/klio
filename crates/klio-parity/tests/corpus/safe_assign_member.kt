class Box(var n: Int = 0)

fun main() {
    val a: Box? = Box(0)
    a?.n = 42
    println(a?.n)
    val b: Box? = null
    b?.n = 99
    println(b?.n)
}
