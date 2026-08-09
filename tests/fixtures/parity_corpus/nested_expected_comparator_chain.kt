// Expected-type propagation through nested calls: a committed callee's
// receiver instantiates a call-shaped argument's declared parameter type as
// that argument's expected type, level by level — sortedWith hands nullsFirst
// `Comparator<in String?>`, nullsFirst hands the compareBy family
// `Comparator<in String>` (its declared `T?` return position strips the `?`,
// satisfying `T : Any`), and the innermost lambda's `it` types String.
fun main() {
    fun String.nullIfEmpty() = if (isEmpty()) null else this
    val data = listOf(null, "", "a")
    println(data.sortedWith(nullsFirst(compareBy { it })))
    println(data.sortedWith(nullsLast(compareByDescending { it })))
    println(data.sortedWith(nullsFirst(compareByDescending { it.nullIfEmpty() })))
}
