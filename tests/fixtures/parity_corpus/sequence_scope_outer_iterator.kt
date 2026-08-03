fun <T> Sequence<T>.everyOther(): Sequence<T> = sequence {
    val iterator = iterator()
    while (iterator.hasNext()) {
        yield(iterator.next())
        if (iterator.hasNext()) iterator.next()
    }
}

fun main() {
    println(sequenceOf(1, 2, 3, 4, 5).everyOther().toList())
}
