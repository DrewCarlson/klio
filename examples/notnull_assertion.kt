fun firstOrThrow(xs: List<Int>): Int {
    val v: Int? = xs.firstOrNull()
    return v!!
}

fun main() {
    println(firstOrThrow(listOf(7, 8, 9)))
    try {
        firstOrThrow(emptyList())
    } catch (e: NullPointerException) {
        println("npe")
    }
}
