fun <T, C : MutableCollection<T>> C.drain(): Int {
    val iter = iterator()
    var n = 0
    while (iter.hasNext()) {
        iter.next()
        n += 1
    }
    return n
}

fun main() {
    println(mutableListOf(1, 2, 3).drain())
}
