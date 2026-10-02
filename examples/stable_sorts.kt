// Every sort is stable and takes O(n log n) comparisons, as the JVM's TimSort
// does: equal elements keep their order, and sorting 20,000 elements by a
// comparator, a selector or their natural order takes milliseconds. A
// comparison is the elements' own `compareTo` or the comparator's `compare`,
// and an exception one throws reaches the caller.

data class Task(val name: String, val priority: Int)

class Version(val major: Int, val minor: Int) : Comparable<Version> {
    override fun compareTo(other: Version): Int = compareValuesBy(this, other, { it.major }, { it.minor })
    override fun toString() = "$major.$minor"
}

fun <T> isSorted(xs: List<T>, cmp: Comparator<in T>) = xs.zipWithNext().all { (a, b) -> cmp.compare(a, b) <= 0 }

fun main() {
    // Equal keys keep their order, ascending and descending.
    val tasks = listOf(Task("write", 2), Task("test", 1), Task("ship", 2), Task("plan", 1), Task("rest", 3))
    println(tasks.sortedBy { it.priority }.map { it.name })
    println(tasks.sortedByDescending { it.priority }.map { it.name })
    println(tasks.sortedWith(compareBy<Task> { it.priority }.thenByDescending { it.name }).map { it.name })
    val m = tasks.toMutableList()
    m.sortBy { it.name.length }
    println(m.map { it.name })

    // Natural order: numbers, strings, a class's own compareTo, nulls placed by the comparator.
    println(listOf(3, -1, 2).sorted() + listOf(3, -1, 2).sortedDescending())
    println(listOf("pear", "Apple", "fig").sorted())
    println(listOf(Version(1, 10), Version(1, 2), Version(0, 9)).sorted())
    println(listOf(2, null, 1).sortedWith(nullsFirst(naturalOrder())))
    println(listOf(2, null, 1).sortedWith(nullsLast(reverseOrder())))
    println(arrayOf("b", "a", "c").sortedArray().toList() + intArrayOf(3, 1, 2).sortedArrayDescending().toList())
    println(sequenceOf(5, 3, 4).sortedBy { -it }.toList())

    // 20,000 elements, by every kind of comparison.
    val n = 20_000
    val r = kotlin.random.Random(7)
    val ints = List(n) { r.nextInt(1_000_000) }
    val words = List(n) { "w" + r.nextInt(1_000_000) }
    val byLast = compareBy<String> { it.last() }
    println("sorted ${isSorted(ints.sorted(), naturalOrder())} ${isSorted(words.sorted(), naturalOrder())}")
    println("descending ${isSorted(ints.sortedDescending(), reverseOrder())}")
    val byLastSorted = words.sortedWith(byLast)
    println("sortedWith ${isSorted(byLastSorted, byLast)} stable ${byLastSorted.filter { it.last() == '7' } == words.filter { it.last() == '7' }}")
    println("sortedBy ${isSorted(words.sortedBy { it.length }, compareBy { it.length })}")
    val arr = ints.toIntArray()
    arr.sort()
    val boxed = ints.toTypedArray()
    boxed.sortWith(compareByDescending { it % 1000 })
    println("arrays ${arr.toList() == ints.sorted()} ${isSorted(boxed.toList(), compareByDescending { it % 1000 })}")
    val seq = ints.asSequence().sortedWith(compareBy { it % 977 }).toList()
    println("sequence ${isSorted(seq, compareBy { it % 977 })} ${seq.size}")

    // A map sorted by key, and its entries read as they are iterated.
    val counts = words.groupingBy { it.length }.eachCount()
    println(counts.toSortedMap())
    val sorted = ints.associateWith { it % 10 }.toSortedMap()
    var check = 0L
    for ((k, v) in sorted) check = check * 31 + k + v
    println("sorted map ${sorted.size} ${sorted.keys.first()} ${sorted.keys.last()} $check")

    // A comparison that throws.
    try {
        listOf(Version(1, 0), Version(2, 0)).sortedWith { _, _ -> throw IllegalStateException("cannot compare") }
    } catch (e: IllegalStateException) {
        println("caught ${e.message}")
    }
}
