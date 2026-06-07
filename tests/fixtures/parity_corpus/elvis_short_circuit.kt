fun lookup(m: Map<String, Int>, k: String): Int =
    m[k] ?: error("missing: $k")

fun main() {
    val m = mapOf("a" to 1, "b" to 2)
    println(lookup(m, "a"))
    println(lookup(m, "b"))
    try {
        println(lookup(m, "z"))
    } catch (e: IllegalStateException) {
        println("caught: ${e.message}")
    }
}
