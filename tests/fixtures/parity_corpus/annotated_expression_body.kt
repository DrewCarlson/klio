// A function expression body may carry a leading annotation
// (`= @Suppress("UNCHECKED_CAST") if (…) … else …`). The stdlib
// `CoroutineContext.Element.get` is written exactly this way; if the
// parser rejects it the whole file is dropped, taking the
// `CoroutineContext` / `Element` / `Key` types with it.
fun classify(n: Int): String =
    @Suppress("UNCHECKED_CAST")
    if (n < 0) "neg" else if (n == 0) "zero" else "pos"

fun <E> firstOrNull(xs: List<E>): E? =
    @Suppress("UNCHECKED_CAST")
    if (xs.isEmpty()) null else xs[0]

fun main() {
    println(classify(-3))
    println(classify(0))
    println(classify(7))
    println(firstOrNull(listOf(1, 2)))
    println(firstOrNull(emptyList<Int>()))
}
