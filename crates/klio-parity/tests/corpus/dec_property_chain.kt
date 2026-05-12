class Box(var n: Int)

fun main() {
    val b = Box(5)
    b.n++
    println(b.n)
    ++b.n
    println(b.n)
    println(b.n--)
    println(b.n)
    println(--b.n)
    println(b.n)
}
