interface Marker {
    fun id(): Int
}

open class Base(n: Int) {
    val size: Int
    init {
        size = tableSizeFor(n)
    }
    private companion object {
        private fun tableSizeFor(size: Int): Int = size * 2
    }
}

class Derived(n: Int) : Marker, Base(n) {
    override fun id(): Int = 1
}

fun main() {
    println(Derived(5).size)
    println(Derived(5).id())
}
