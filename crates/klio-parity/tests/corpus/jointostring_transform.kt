fun main() {
    val xs = listOf(1, 2, 3, 4, 5)
    println(xs.joinToString())
    println(xs.joinToString(" / "))
    println(xs.joinToString(", ", "[", "]"))
    println(xs.joinToString("; ", "(", ")"))
    println(xs.joinToString { "n=$it" })
    println(xs.joinToString(", ") { "x${it * 10}" })
    println(xs.joinToString(", ", "[", "]", 3, "..."))
}
