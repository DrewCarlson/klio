// A bare-name call to an overloaded top-level function from inside a
// member body must select the overload by runtime argument type, not
// bake in whichever was declared first.
fun scale(v: Double, by: Int): Double = v * by + 0.5
fun scale(v: Long, by: Int): Long = v * by + 1L

class Box(private val raw: Long) {
    val asLong: Long get() = scale(raw, 3)
    val asDouble: Double get() = scale(raw.toDouble(), 3)
}

fun main() {
    val b = Box(10L)
    println(b.asLong)
    println(b.asDouble)
    println(scale(7L, 2))
    println(scale(7.0, 2))
}
