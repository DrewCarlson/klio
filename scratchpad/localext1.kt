fun main() {
    fun Int.pad() = toString().padStart(2, '0')
    fun String.wrap(): String = "[" + this + "]"
    fun Int.times(s: String): String = s.repeat(this)

    println("pad  = " + 7.pad())
    println("wrap = " + "a".wrap())
    println("times= " + 3.times("x"))

    val xs = listOf(1, 22, 333)
    println("map  = " + xs.map { it.pad() })

    // A local extension on a user type.
    class Box(val n: Int)
    fun Box.doubled(): Int = n * 2
    println("box  = " + Box(4).doubled())
}
