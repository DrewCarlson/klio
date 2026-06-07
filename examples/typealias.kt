typealias IntList = List<Int>
typealias Pair2<A> = Pair<A, A>
typealias Pred<T> = (T) -> Boolean

fun <T> count(xs: List<T>, p: Pred<T>): Int {
    var n = 0
    for (x in xs) {
        if (p(x)) n++
    }
    return n
}

fun main() {
    val xs: IntList = listOf(1, 2, 3, 4)
    println(xs.sum())
    val p: Pair2<String> = Pair("k", "v")
    println(p.first)
    println(p.second)
    val odd: Pred<Int> = { x -> x % 2 == 1 }
    println(count(xs, odd))
}
