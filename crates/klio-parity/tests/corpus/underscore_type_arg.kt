fun <T> id(x: T): T = x

fun main() {
    val a: Int = id<_>(42)
    val b: String = id<_>("hi")
    println(a)
    println(b)
}
