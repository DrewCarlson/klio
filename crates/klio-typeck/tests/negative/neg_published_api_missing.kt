internal fun helper(x: Int): Int = x + 1

public inline fun publicInline(x: Int): Int = helper(x)

fun main() {
    println(publicInline(1))
}
