fun main() {
    // Factory functions whose upstream bodies used Array.toMap/toCollection/
    // filterNotNull (broken) now route to direct intrinsics.
    println(linkedMapOf("a" to 1, "b" to 2))
    println(hashMapOf("x" to 1).size)
    println(hashSetOf(1, 2, 3).sorted())
    println(linkedSetOf(3, 1, 2).toList())
    println(listOfNotNull(1, null, 2, null, 3))
    println(setOfNotNull(1, null, 2, null, 3).sorted())
    println(sortedSetOf(3, 1, 2, 1).toList())
    println(sortedMapOf(3 to "c", 1 to "a", 2 to "b"))
    println(arrayListOf(1, 2, 3))

    // `as`/`is` against builtin collection/array supertypes, and ops that go
    // through them (sorted on a mutable set, union, toMap with destination).
    println(mutableSetOf(3, 1, 2).sorted())
    println(mutableListOf(3, 1, 2).sorted())
    println(listOf(1, 2, 3) union listOf(3, 4))
    println(listOf(1, 2, 3) intersect listOf(2, 3, 4))
    println((listOf(1, 2, 3, 4) subtract listOf(2, 4)).sorted())
    println(arrayOf(1 to 2, 3 to 4).toMap(mutableMapOf()))
    println(setOf(1, 2, 3).toTypedArray().size)
    val anyList: Any = listOf(1, 2, 3)
    println(anyList is List<*>)
    println(anyList is Collection<*>)
    println(anyList is MutableList<*>)
}
