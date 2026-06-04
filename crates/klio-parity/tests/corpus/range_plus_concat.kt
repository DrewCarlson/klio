// `Range + Range` / `Range + element` route through Kotlin's
// `Iterable.plus`, concatenating into a `List` (a range is an `Iterable`, not
// a numeric operand). ktor's `Codecs.URL_ALPHABET` builds its allowed set this
// way: `(('a'..'z') + ('A'..'Z') + ('0'..'9'))`.
fun main() {
    val alphabet = (('a'..'z') + ('A'..'Z') + ('0'..'9'))
    println(alphabet.size)
    println(alphabet.take(3).joinToString(""))
    println(alphabet.takeLast(3).joinToString(""))

    val ints = (1..3) + (7..9)
    println(ints)
    println((1..3) + 5)
    println(('a'..'e') - ('b'..'c'))

    val bytes = (('a'..'c') + ('A'..'B')).map { it.code }
    println(bytes)
}
