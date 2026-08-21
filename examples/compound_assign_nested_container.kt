// `xs += y` on a mutable collection has two readings: append `y` as ONE
// element, or append every element of `y`. Kotlin picks by the receiver's
// declared ELEMENT type — a `MutableList<List<T>>` takes a `List<T>` as one
// element, because a `List<T>` is not an `Iterable<List<T>>`.
//
// Run with: klio run examples/compound_assign_nested_container.kt

class Builder {
    val rows: MutableList<List<String>> = ArrayList()

    fun row(cells: List<String> = emptyList()) {
        rows += cells
    }
}

fun main() {
    // The element type is itself a list, so each `+=` appends one row.
    val outer: MutableList<List<String>> = ArrayList()
    outer += emptyList<String>()
    outer += listOf("a", "b")
    println("rows      = $outer size=${outer.size}")

    // A list OF the element type is the iterable form and still flattens.
    val outer2: MutableList<List<String>> = ArrayList()
    outer2 += listOf(listOf("a"), listOf("b"))
    println("flattened = $outer2 size=${outer2.size}")

    // The ordinary element/iterable split on a flat list is unchanged.
    val nums: MutableList<Int> = ArrayList()
    nums += 1
    nums += listOf(2, 3)
    println("nums      = $nums")

    // Sets follow the same rule, and `-=` mirrors `+=`.
    val sets: MutableSet<Set<Int>> = LinkedHashSet()
    sets += setOf(1, 2)
    println("sets      = $sets size=${sets.size}")
    outer -= listOf("a", "b")
    println("after -=  = $outer")

    // The rule reads the DECLARED type, so it holds for a property reached
    // bare inside its class, through `this.`, and from outside.
    val b = Builder()
    b.row()
    b.row(listOf("x"))
    b.rows += listOf("y")
    println("property  = ${b.rows} size=${b.rows.size}")

    // A `MutableList<Any>` element type is not a container, so the iterable
    // overload wins there, exactly as Kotlin resolves it.
    val anys: MutableList<Any> = ArrayList()
    anys += listOf(1, 2)
    println("anys      = $anys size=${anys.size}")
}
