// A soft keyword such as `actual`, `open`, `vararg` or `noinline` modifies a
// parameter only when more of the parameter follows it; followed by `:` it
// is the parameter's name.

class Subject internal constructor(
    actual: Double?,
    open: Int = 1,
    private val internal: Int = 2,
    vararg final: String,
) {
    val value = actual
    val sum = open + internal + final.size

    fun isZero() = value == 0.0
}

fun f(vararg: Int, noinline: Boolean, crossinline: String, vararg open: Int): String =
    "$vararg $noinline $crossinline ${open.toList()}"

fun main() {
    val s = Subject(0.5, 3, 4, "a", "b")
    println(s.value)
    println(s.sum)
    println(s.isZero())
    println(Subject(0.0).isZero())
    println(Subject(null).sum)
    println(f(1, true, "c", 5, 6))
}
