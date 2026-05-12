open class Base {
    protected fun greet(): String = "hi"
}

class Other {
    fun probe(b: Base): String = b.greet()
}

fun main() {
    println(Other().probe(Base()))
}
