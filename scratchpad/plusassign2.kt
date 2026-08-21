fun main() {
    // Nested: the element type IS the container, so one element is appended.
    val outer: MutableList<List<String>> = ArrayList()
    outer += emptyList<String>()
    outer += listOf("a", "b")
    println("outer = $outer size=${outer.size}")

    // A list OF the element type still flattens.
    val outer2: MutableList<List<String>> = ArrayList()
    outer2 += listOf(listOf("a"), listOf("b"))
    println("outer2 = $outer2 size=${outer2.size}")

    // The ordinary element/iterable split is unchanged.
    val nums: MutableList<Int> = ArrayList()
    nums += 1
    nums += listOf(2, 3)
    println("nums = $nums")

    // Sets behave the same way.
    val sets: MutableSet<Set<Int>> = LinkedHashSet()
    sets += setOf(1, 2)
    println("sets = $sets size=${sets.size}")

    // minusAssign mirrors it.
    outer -= listOf("a", "b")
    println("after -= : $outer")

    // A MutableList<Any> takes the iterable overload, as Kotlin does.
    val anys: MutableList<Any> = ArrayList()
    anys += listOf(1, 2)
    println("anys = $anys size=${anys.size}")
}
