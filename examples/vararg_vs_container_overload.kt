// A function overloaded on `vararg T` and on a container of `T` resolves by
// what the argument IS: one value of `T` takes the vararg form, a collection
// of them takes the container form. The two have the same arity, so nothing
// but the argument's type separates them — including when the callee is
// `inline` and the call site would otherwise be spliced.
//
// Run with: klio run examples/vararg_vs_container_overload.kt

class Source<T>(val values: List<T>)

fun <T, R> merge(vararg sources: Source<T>, transform: (List<T>) -> R): String =
    "vararg(${sources.size}) -> " + transform(sources.flatMap { it.values })

fun <T, R> merge(sources: Iterable<Source<T>>, transform: (List<T>) -> R): String =
    "iterable(${sources.count()}) -> " + transform(sources.flatMap { it.values })

inline fun <reified T, R> mergeInline(vararg sources: Source<T>, transform: (List<T>) -> R): String =
    "vararg(${sources.size}) -> " + transform(sources.flatMap { it.values })

inline fun <reified T, R> mergeInline(sources: Iterable<Source<T>>, transform: (List<T>) -> R): String =
    "iterable(${sources.count()}) -> " + transform(sources.flatMap { it.values })

fun main() {
    val a = Source(listOf(1, 2))
    val b = Source(listOf(3))

    println("one       = " + merge(a) { it.sum() })
    println("two       = " + merge(a, b) { it.sum() })
    println("list      = " + merge(listOf(a, b)) { it.sum() })

    println("one/inl   = " + mergeInline(a) { it.sum() })
    println("two/inl   = " + mergeInline(a, b) { it.sum() })
    println("list/inl  = " + mergeInline(listOf(a, b)) { it.sum() })

    // A spread of a real collection still takes the vararg form.
    val many = arrayOf(a, b)
    println("spread    = " + merge(*many) { it.sum() })
}
