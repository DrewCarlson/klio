// `String.toCharArray()` returns a `CharArray`, not a `List<Char>` — overload
// resolution distinguishes them, so `CharSequence.indexOfAny(chars: CharArray,
// …)` binds the `CharArray` overload rather than the `Collection<String>` one
// (which would read `.length` on a `Char`). ktor's `URLParser` does
// `indexOfAny("@/\\?#".toCharArray(), startIndex)`.
fun main() {
    println("hello".indexOfAny("lo".toCharArray(), 0))
    println("a/b?c".indexOfAny("@/?#".toCharArray()))
    val ca = "abc".toCharArray()
    println(ca.size)
    println(ca[1])
    println(ca.joinToString("-"))
    println("xyz".toCharArray().reversed().joinToString(""))
    println(String("hi".toCharArray()))
}
