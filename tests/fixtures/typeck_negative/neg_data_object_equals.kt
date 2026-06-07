data object Singleton {
    override fun equals(other: Any?): Boolean = true
    override fun hashCode(): Int = 0
}

fun main() {
    println(Singleton)
}
