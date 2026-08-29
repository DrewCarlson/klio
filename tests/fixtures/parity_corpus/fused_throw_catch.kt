fun Int.check(radix: Int): Int {
    if (radix < 2 || radix > 36) {
        throw IllegalArgumentException("Invalid radix: $radix")
    }
    return this + radix
}

fun main() {
    println("ok=" + 5.check(10))
    var caught = "none"
    try {
        println(5.check(37))
    } catch (e: IllegalArgumentException) {
        caught = e.message ?: "no-msg"
    }
    println("caught=" + caught)
    val r = runCatching { 5.check(37) }
    println("failed=" + r.isFailure)
}
