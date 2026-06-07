open class Base {
    final override fun equals(other: Any?): Boolean = true
    final override fun hashCode(): Int = 7
}

data class Sub(val x: Int) : Base()

fun main() {
    val a = Sub(1)
    val b = Sub(2)
    println(a == b)
    println(a.hashCode())
    println(b.hashCode())
}
