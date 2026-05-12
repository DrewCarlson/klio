fun <T> forceCast(x: Any): T {
    return x as T
}

fun main() {
    val r: Int = forceCast<Int>(42)
    println(r)
}
