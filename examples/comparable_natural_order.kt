// A class that implements `Comparable` participates in Kotlin's natural
// ordering everywhere it is used as one: relational operators, list and
// sequence sorts, key selectors, `min`/`max`, `coerceIn`, and the
// `compareValues` helper comparators are built from.
//
// Run with: klio run examples/comparable_natural_order.kt

class Version(val major: Int, val minor: Int) : Comparable<Version> {
    override fun compareTo(other: Version): Int =
        if (major != other.major) major.compareTo(other.major) else minor.compareTo(other.minor)

    override fun toString(): String = "$major.$minor"
}

class Release(val name: String, val version: Version)

fun main() {
    val a = Version(1, 2)
    val b = Version(1, 10)

    println("less      = " + (a < b))
    println("compareTo = " + a.compareTo(b))
    println("compareValues = " + compareValues(a, b))

    val versions = listOf(Version(2, 0), Version(1, 10), Version(1, 2))
    println("sorted    = " + versions.sorted())
    println("desc      = " + versions.sortedDescending())
    println("min/max   = " + versions.min() + "/" + versions.max())
    println("coerceIn  = " + Version(3, 0).coerceIn(Version(1, 0), Version(2, 0)))

    // Through a key selector, on a list and on a sequence.
    val releases = listOf(
        Release("beta", Version(1, 10)),
        Release("alpha", Version(1, 2)),
        Release("stable", Version(2, 0)),
    )
    println("byKey     = " + releases.sortedBy { it.version }.map { it.name })
    println("seqByKey  = " + releases.asSequence().sortedBy { it.version }.map { it.name }.toList())
    println("seqSorted = " + versions.asSequence().sorted().toList())

    // A comparator built from the natural order composes with a tiebreaker.
    val byVersionThenName = compareBy<Release> { it.version }.thenBy { it.name }
    println("comparator= " + releases.sortedWith(byVersionThenName).map { it.name })

    // Ranges over the same order.
    println("in range  = " + (Version(1, 5) in Version(1, 0)..Version(2, 0)))
}
