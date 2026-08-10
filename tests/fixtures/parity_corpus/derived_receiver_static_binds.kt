// The stretch's mechanisms in one program: derived extension returns
// instantiate from receivers; heterogeneous varargs record their LUB;
// SAM conversions type their lambdas (expected + explicit + chained);
// a local's bare-tp property answer substitutes the declared receiver;
// a local class's ctor init proves extension applicability; the
// object-let marker splices; value-class nested ctors construct.
import kotlin.time.TimeSource

class Item(val name: String, val rating: Int)
class Ctx<out T>(val expected: T, val actual: T)
data class Collector<out K, V>(val key: K, val values: MutableList<V> = mutableListOf<V>())

val CASE_INSENSITIVE: Comparator<String>
    get() = Comparator { a, b -> a.compareTo(b, ignoreCase = true) }

fun <K, V> Ctx<Map<K, V>>.mapCheck(): Boolean = expected.isEmpty().not()

fun Ctx<Int>.markerCheck(): Int {
    var seen = 0
    (object {}).let { seen = expected + actual }
    return seen
}

fun localClassToArray(): List<String> {
    class Carrier(val data: Collection<String>)
    val c = Carrier(listOf("x", "y"))
    return c.data.toList()
}

fun main() {
    val items = listOf("alpha", "beta")
    val dropped = items.drop(1)
    println(dropped.associateWith { name -> name.lowercase().count { it in "aeuio" } })

    val mixed = listOf('a', "b", StringBuilder("c"), null, "d")
    println(mixed.joinToString(limit = 3, truncated = "*"))

    println(listOf("b", "A").sortedWith(CASE_INSENSITIVE))
    val cmp = Comparator<Item> { a, b -> a.name compareTo b.name }.thenComparator { a, b -> a.rating compareTo b.rating }
    println(cmp.compare(Item("a", 2), Item("a", 1)) > 0)

    println(Ctx(mapOf(1 to "a"), mapOf(1 to "a")).mapCheck())
    println(Ctx(3, 4).markerCheck())
    println(localClassToArray())

    val fl = arrayOf(arrayOf("a", "b"), arrayOf("c")).flatten()
    println(fl)

    val byLength = listOf("a", "abc", "ab").groupBy { it.length }
    println(byLength[2].orEmpty())

    var acc = 0
    repeat(3) { acc += it }
    println(acc)

    val mark = TimeSource.Monotonic.markNow()
    println(mark.elapsedNow() >= kotlin.time.Duration.ZERO)
}
