typealias Pair2<A> = Pair<A, A>

fun main() {
    val p: Pair2<Int> = Pair(1, 2)
    println(p.first)
    println(p.second)
    val s: Pair2<String> = Pair("hi", "bye")
    println(s.first)
    println(s.second)
}
