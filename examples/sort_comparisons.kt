// Sorting objects compares them as the JVM's TimSort does: the same pairs in the
// same order, so a comparator that counts or logs its calls prints the JVM's
// numbers, sorts are stable both ways, and a comparator that contradicts itself
// fails the same way.

data class Version(val major: Int, val minor: Int, val tag: String) : Comparable<Version> {
    override fun compareTo(other: Version): Int {
        compareToCalls++
        return compareValuesBy(this, other, { it.major }, { it.minor })
    }
}

var compareToCalls = 0

fun main() {
    val words = listOf("pear", "fig", "apple", "kiwi", "banana", "plum", "date", "cherry", "lime", "grape")

    // A comparator that logs the pairs it is asked about.
    val asked = mutableListOf<String>()
    val byLength = words.sortedWith { a, b -> asked.add("$a/$b"); a.length - b.length }
    println(byLength)
    println("${asked.size} comparisons: ${asked.take(6)}")

    // Stable both ways: equal lengths keep their order, ascending and descending.
    println(words.sortedBy { it.length })
    println(words.sortedByDescending { it.length })
    println(words.sortedWith(compareBy<String> { it.length }.thenByDescending { it }))

    // Natural order of a class's own compareTo, counted.
    val versions = listOf(
        Version(1, 2, "a"), Version(0, 9, "b"), Version(1, 2, "c"), Version(2, 0, "d"),
        Version(0, 9, "e"), Version(1, 0, "f"), Version(1, 2, "g"), Version(0, 1, "h"),
    )
    compareToCalls = 0
    println(versions.sorted().joinToString { it.tag })
    println("compareTo calls: $compareToCalls")
    compareToCalls = 0
    println(versions.sortedDescending().joinToString { it.tag })
    println("compareTo calls: $compareToCalls")
    val mutable = versions.toMutableList()
    mutable.sortWith(reverseOrder())
    println(mutable.joinToString { it.tag })

    // A large sort: how many comparisons TimSort makes on random and nearly sorted input.
    val r = kotlin.random.Random(42)
    val randoms = List(5000) { r.nextInt(100_000) }
    var calls = 0
    val sortedRandoms = randoms.sortedWith { a, b -> calls++; a.compareTo(b) }
    println("random: $calls comparisons, ${sortedRandoms.first()}..${sortedRandoms.last()}")
    val nearly = (0 until 5000).map { if (it % 500 == 0) 5000 - it else it }
    calls = 0
    nearly.sortedWith { a, b -> calls++; a.compareTo(b) }
    println("nearly sorted: $calls comparisons")
    calls = 0
    (0 until 5000).reversed().sortedWith { a, b -> calls++; a.compareTo(b) }
    println("descending run: $calls comparisons")

    // Arrays, ranges of them, and the range checks.
    val arr = arrayOf("delta", "alpha", "echo", "charlie", "bravo", "foxtrot")
    arr.sortWith(compareBy { it }, 1, 5)
    println(arr.joinToString())
    arr.sort()
    println(arr.joinToString())
    arr.sortWith(reverseOrder(), 3)
    println(arr.joinToString())
    arr.sort(toIndex = 4)
    println(arr.joinToString())
    try {
        arr.sortWith(naturalOrder(), 4, 2)
    } catch (e: IllegalArgumentException) {
        println("IllegalArgumentException: ${e.message}")
    }
    try {
        arr.sortWith(naturalOrder(), 0, 9)
    } catch (e: IndexOutOfBoundsException) {
        println("IndexOutOfBoundsException: ${e.message}")
    }

    // `compareBy` over several selectors: each pair is compared by the first selector that
    // tells them apart, its selectors counted.
    data class Entry(val dept: String, val level: Int, val name: String)
    val staff = listOf(
        Entry("ops", 2, "kim"), Entry("dev", 3, "ana"), Entry("ops", 1, "lee"),
        Entry("dev", 3, "bob"), Entry("dev", 1, "cy"), Entry("ops", 2, "al"),
    )
    var selects = 0
    val byAll = compareBy<Entry>({ selects++; it.dept }, { selects++; it.level }, { selects++; it.name })
    println(staff.sortedWith(byAll).joinToString { "${it.dept}/${it.level}/${it.name}" } + " ($selects selects)")
    println(staff.sortedWith(compareByDescending<Entry> { it.level }.thenBy { it.name }).joinToString { it.name })
    println(compareValuesBy(staff[0], staff[5], { it.dept }, { it.level }, { it.name }))

    // An array's elements move as `System.arraycopy` moves them, overlapping or not.
    val slots = Array<String?>(8) { "s$it" }
    slots.copyInto(slots, 2, 0, 5)
    println(slots.joinToString())
    slots.copyInto(slots, 0, 3, 8)
    println(slots.joinToString())
    val counts = IntArray(6) { it * 10 }
    counts.copyInto(counts, 1, 0, 5)
    println(counts.joinToString())
    for (bad in listOf<() -> Unit>({ slots.copyInto(slots, 6, 0, 4) }, { counts.copyInto(counts, 0, 4, 2) }, { counts.copyInto(IntArray(2)) })) {
        try {
            bad()
        } catch (e: IndexOutOfBoundsException) {
            println("${e::class.simpleName}: ${e.message}")
        }
    }

    // A comparator that contradicts itself.
    val rnd = kotlin.random.Random(3)
    val liar = Comparator<Int> { _, _ -> rnd.nextInt(3) - 1 }
    try {
        List(1000) { it }.sortedWith(liar)
        println("no contradiction seen")
    } catch (e: IllegalArgumentException) {
        println("IllegalArgumentException: ${e.message}")
    }
}
