// flatMap/flatMapIndexed overload pairs differ ONLY in the lambda's return
// type (Iterable vs Sequence), so extension resolution ties and stays
// deferred — yet every candidate hands the closure the same parameter
// types, so `index` and `it` must still type (it: String? here, and the
// orEmpty/take chain must bind statically off it).
fun main() {
    val source = listOf(null, "foo", "bar")
    val result1 = source.flatMapIndexed { index, it -> it.orEmpty().take(index + 1).asSequence() }
    val result2 = source.flatMapIndexed { index, it -> it.orEmpty().take(index + 1).asIterable() }
    println(result1)
    println(result2)
    val fm1 = source.flatMap { it.orEmpty().asSequence() }
    val fm2 = source.flatMap { it.orEmpty().asIterable() }
    println(fm1)
    println(fm2)
}
