fun <T> Iterable<T>.countByHand(): Int {
    val iterator = iterator()
    var n = 0
    while (iterator.hasNext()) {
        iterator.next()
        n++
    }
    return n
}

fun <T> Sequence<T>.secondOrNull(): T? {
    val iterator = iterator()
    if (!iterator.hasNext()) return null
    iterator.next()
    if (!iterator.hasNext()) return null
    return iterator.next()
}

fun main() {
    println(listOf(1, 2, 3).countByHand())
    println(sequenceOf("a", "b", "c").secondOrNull())
    println(sequenceOf(9).secondOrNull())
}
