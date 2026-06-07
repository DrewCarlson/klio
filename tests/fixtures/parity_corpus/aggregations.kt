fun main() {
    val nums = listOf(3, 1, 4, 1, 5, 9, 2, 6)
    println(nums.sum())
    println(nums.max())
    println(nums.min())
    println(nums.maxOrNull())
    println(nums.minOrNull())
    println(nums.average())
    println(nums.indices)
    println(nums.lastIndex)

    val empty: List<Int> = emptyList()
    println(empty.maxOrNull())
    println(empty.minOrNull())

    val pairs = listOf("a" to 1, "b" to 2, "c" to 3)
    println(pairs.toMap())

    println(listOf("ccc", "a", "bb").max())
    println(listOf(1.5, 2.5, 3.5).sum())

    // Same ops over Sequence.
    println(nums.asSequence().sum())
    println(nums.asSequence().max())
    println(nums.asSequence().average())
    println(pairs.asSequence().toMap())
}
