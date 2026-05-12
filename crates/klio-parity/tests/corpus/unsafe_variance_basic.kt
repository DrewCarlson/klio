class Box<out T>(val value: T) {
    fun replace(other: @UnsafeVariance T): T {
        return other
    }
}

fun main() {
    val b: Box<Int> = Box(1)
    println(b.replace(7))
}
