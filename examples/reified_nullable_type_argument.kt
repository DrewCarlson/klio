// A reified type argument carries its NULLABILITY: `filterIsInstance<Int?>()`
// keeps the nulls that `filterIsInstance<Int>()` drops, and an `is T` in an
// inline body reads the argument exactly as written at the call site.
//
// Run with: klio run examples/reified_nullable_type_argument.kt

inline fun <reified T> Any?.matches(): Boolean = this is T

inline fun <reified T> Iterable<*>.keep(): List<T> {
    val out = ArrayList<T>()
    for (e in this) if (e is T) out.add(e)
    return out
}

inline fun <reified T> nameOf(): String = if (null is T) "nullable" else "not null"

inline fun <reified T> Iterable<*>.pick(): List<Any?> = filter { it is T }

fun main() {
    val xs = listOf<Any?>(1, "two", null, 3)

    println("Int      = " + xs.filterIsInstance<Int>())
    println("Int?     = " + xs.filterIsInstance<Int?>())
    println("String   = " + xs.filterIsInstance<String>())
    println("String?  = " + xs.filterIsInstance<String?>())

    println("keep Int  = " + xs.keep<Int>())
    println("keep Int? = " + xs.keep<Int?>())

    val n: Any? = null
    println("n Int    = " + n.matches<Int>())
    println("n Int?   = " + n.matches<Int?>())
    println("1 Int?   = " + 1.matches<Int?>())

    println("null-in  = " + nameOf<Int>() + "/" + nameOf<Int?>())

    // The check reads the argument from inside a LAMBDA in the inline body
    // too, which is where `Flow.filterIsInstance` puts it.
    println("lambda    = " + xs.pick<Int>() + "/" + xs.pick<Int?>())
}
