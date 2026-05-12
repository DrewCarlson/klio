class Box<T> {
    fun cls(): Any = T::class
}

fun main() {
    println(Box<Int>().cls())
}
