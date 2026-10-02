// Sets find their elements by hashCode() and then equals(), as a JVM HashSet
// does, so adding, finding and removing take the same time at any size, and
// the builders that dedupe (setOf, toSet, distinct, associateBy, mapOf of
// pairs) take linear time. A class's own equals and hashCode decide which
// elements are the same; hashCode runs once for each add, lookup and removal.

class Tag(val name: String) {
    override fun equals(other: Any?) = other is Tag && other.name.lowercase() == name.lowercase()
    override fun hashCode(): Int {
        hashes++
        return name.lowercase().hashCode()
    }
    override fun toString() = "Tag($name)"
}

var hashes = 0

data class Point(val x: Int, val y: Int)

class Broken {
    override fun hashCode(): Int = throw IllegalStateException("no hash")
}

fun main() {
    // A user equals and hashCode: case-insensitive tags.
    val tags = mutableSetOf(Tag("Kotlin"), Tag("Zig"))
    hashes = 0
    println(tags.add(Tag("KOTLIN")))
    println(tags.contains(Tag("zig")))
    println(tags.remove(Tag("ZIG")))
    println("$tags hashCode calls: $hashes")

    // Data classes and pairs as elements and keys, at a size a scan would feel.
    val n = 50_000
    val points = HashSet<Point>()
    for (i in 0 until n) points.add(Point(i % 500, i / 500))
    var hits = 0
    for (i in 0 until n) if (Point(i % 250, i / 250) in points) hits++
    println("points ${points.size} found $hits")
    val grid = HashMap<Pair<Int, Int>, Int>()
    for (i in 0 until n) grid[Pair(i % 300, i / 300)] = i
    var sum = 0L
    for (i in 0 until n) sum += grid[Pair(i % 300, i / 300)] ?: 0
    println("grid ${grid.size} sum $sum")

    // Builders keep the first of equal elements, in order.
    val words = List(n) { "w${it % 1000}" }
    println("distinct ${words.distinct().size} toSet ${words.toSet().size} first ${words.toSet().first()}")
    val byLength = words.associateBy { it.length }
    println("associateBy $byLength")
    val counts = words.groupingBy { it.last() }.eachCount()
    println("groupingBy ${counts.size} ${counts['7']}")
    val m = mapOf("a" to 1, "b" to 2, "a" to 3)
    println("mapOf $m")

    // Set algebra.
    val evens = (0 until n step 2).toSet()
    val threes = (0 until n step 3).toSet()
    println("union ${(evens union threes).size} intersect ${(evens intersect threes).size} subtract ${(evens subtract threes).size}")
    val copy = evens.toMutableSet()
    copy.removeAll(threes)
    copy.retainAll((0 until 100).toSet())
    println("removeAll/retainAll ${copy.sorted().take(8)}")
    println("containsAll ${evens.containsAll(listOf(0, 2, 4))} ${evens.containsAll(listOf(1))}")

    // A hashCode that throws reaches the caller, as on the JVM.
    try {
        HashSet<Any>().add(Broken())
    } catch (e: IllegalStateException) {
        println("caught ${e.message}")
    }
}
