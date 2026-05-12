typealias Pred<T> = (T) -> Boolean

fun <T> count(xs: List<T>, p: Pred<T>): Int {
    var n = 0
    for (x in xs) {
        if (p(x)) n++
    }
    return n
}

fun main() {
    val evens: Pred<Int> = { x -> x % 2 == 0 }
    println(count(listOf(1, 2, 3, 4, 5, 6), evens))
    val long: Pred<String> = { s -> s.length > 3 }
    println(count(listOf("a", "abcd", "hi", "world"), long))
}
