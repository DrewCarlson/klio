interface Src { fun tag(): String }
class S(val n: Int) : Src { override fun tag() = "S$n" }

fun <R> pick(vararg items: Src, transform: (Array<out Src>) -> R): R {
    println("  [vararg overload] n=" + items.size)
    return transform(items)
}

fun <R> pick(items: Iterable<Src>, transform: (Array<out Src>) -> R): R {
    println("  [iterable overload]")
    return transform(items.toList().toTypedArray())
}

fun main() {
    val a = S(1); val b = S(2)
    println("A vararg literal:");   pick(a, b) { it.size }
    println("B listOf inline:");    pick(listOf(a, b)) { it.size }
    val l = listOf(a, b)
    println("C list variable:");    pick(l) { it.size }
}
