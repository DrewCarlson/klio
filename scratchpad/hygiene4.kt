inline fun makeIt(): List<Int> = listOf(1, 2, 3)
inline fun outer(): Int = makeIt().size

fun main() {
    println("clean = " + outer())
    val listOf = "shadow"
    println("shadowed = " + runCatching { outer() }.getOrElse { "ERR " + it.message } + " local=" + listOf)
}
