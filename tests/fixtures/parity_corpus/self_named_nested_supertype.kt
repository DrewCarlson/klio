// A top-level class extending a nested class of the same simple name
// (`class Box : Outer.Box()`). Kotlin resolves the qualified supertype to the
// nested declaration; klio collapses qualified type paths to the last segment,
// which previously formed a self-referential supertype and looped forever
// during construction. Construction must terminate and the subclass's own
// members must work.
sealed class Outer {
    abstract class Box : Outer() {
        abstract fun unwrap(): String
    }
}

class Box(private val value: String) : Outer.Box() {
    override fun unwrap(): String = value
    val width: Int get() = value.length
    fun describe(): String = "Box($value, w=$width)"
}

fun main() {
    val a = Box("hi")
    println(a.unwrap())
    println(a.width)
    println(a.describe())

    val b = Box("longer")
    println(b.unwrap())
    println(b.width)
    println(listOf(a, b).map { it.unwrap() })
}
