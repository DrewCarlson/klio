// A library function written natively calls back into a user class
// through the member it overrides: `toTypedArray` copies through an
// `AbstractCollection`'s own `toArray`, `joinToString` renders with each
// element's `toString`, `sorted` orders by `compareTo`, and a map copy
// reads a user map's `entries`. A regex match's `groups` is a collection
// of its own, indexable by group number and by group name.

class Tracked<out E>(val data: Collection<E>) : AbstractCollection<E>() {
    val calls = mutableListOf<String>()
    override val size: Int get() = data.size
    override fun iterator(): Iterator<E> = data.iterator()
    override fun toArray(): Array<Any?> {
        calls += "toArray"
        return super.toArray()
    }
    override fun <T> toArray(array: Array<T>): Array<T> {
        calls += "toArray"
        return super.toArray(array)
    }
}

class Version(val major: Int, val minor: Int) : Comparable<Version> {
    override fun compareTo(other: Version): Int =
        if (major != other.major) major - other.major else minor - other.minor
    override fun toString(): String = "v$major.$minor"
}

class Pairs(private val names: List<String>) : AbstractMap<String, Int>() {
    override val entries: Set<Map.Entry<String, Int>>
        get() = names.mapIndexed { i, k -> entry(k, i) }.toSet()

    private fun entry(k: String, v: Int): Map.Entry<String, Int> = object : Map.Entry<String, Int> {
        override val key: String = k
        override val value: Int = v
    }
}

fun main() {
    val tracked = Tracked(listOf("a", "b"))
    println(tracked.toTypedArray().toList())
    println(tracked.calls)

    val versions = listOf(Version(1, 10), Version(1, 2), Version(0, 9))
    println(versions.sorted().joinToString())
    println(versions.maxOrNull())

    val copy = HashMap(Pairs(listOf("x", "y")))
    println(copy.entries.sortedBy { it.key }.joinToString { "${it.key}=${it.value}" })
    println(copy == Pairs(listOf("x", "y")))

    val m = Regex("(?<year>\\d{4})-(?<month>\\d{2})").find("on 2024-06")!!
    val groups = m.groups
    println(groups is MatchNamedGroupCollection)
    println(groups.size)
    println(groups["year"]?.value + "/" + groups[2]?.value)
    println(groups.map { it?.value })
    try {
        groups["day"]
    } catch (e: IllegalArgumentException) {
        println(e.message)
    }
}
