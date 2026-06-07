fun <T> matchType(x: Any): Boolean {
    return x is T
}

fun main() {
    println(matchType<Int>(42))
}
