// Map operations walk a map's entries where they stand, as the JVM's do, copying a map only
// to make a new one: printing, comparing, hashing and putting one map into another read the
// entries in place, each key found through its own `hashCode()` and `equals`, and a map of
// the program's own is read through its iterator; an iterator over a map or a set ends after
// the element that was last when it gave it.

data class Sku(val id: Int, val region: String)

class Price(val cents: Int) {
    override fun toString() = "$" + cents / 100 + "." + (cents % 100).toString().padStart(2, '0')
    override fun equals(other: Any?) = other is Price && other.cents == cents
    override fun hashCode() = cents
}

// A key whose hash puts several in one bucket: lookups compare by `equals`.
class Code(val n: Int) {
    override fun toString() = "C$n"
    override fun equals(other: Any?) = other is Code && other.n == n
    override fun hashCode() = n % 3
}

class Catalog(private val inner: Map<Sku, Price>) : AbstractMap<Sku, Price>() {
    override val entries get() = inner.entries
}

// A map of its own whose entries are made on every read, and counted.
class Ledger(private val rows: List<Pair<String, Int>>) : AbstractMap<String, Int>() {
    var reads = 0
    override val entries: Set<Map.Entry<String, Int>>
        get() {
            reads++
            return rows.map { (k, v) -> object : Map.Entry<String, Int> {
                override val key = k
                override val value = v
            } }.toSet()
        }
}

fun main() {
    // Printing: each key and value by its own `toString`, the map itself named.
    val stock = linkedMapOf<Any?, Any?>(Sku(1, "eu") to Price(1999), "note" to null, null to listOf(1, 2))
    stock["self"] = stock
    println(stock)

    // Equality and hashing: the same entries in another order are equal, and hash alike.
    val a = mutableMapOf(Sku(1, "eu") to Price(1999), Sku(2, "us") to Price(250), Sku(3, "eu") to null)
    val b = mutableMapOf(Sku(3, "eu") to null, Sku(1, "eu") to Price(1999), Sku(2, "us") to Price(250))
    println("${a == b} ${b == a} ${a.hashCode() == b.hashCode()}")
    b[Sku(3, "eu")] = Price(0)
    println("${a == b} ${mapOf("k" to null) == mapOf("j" to null)}")
    val nonNull = mapOf(Sku(1, "eu") to Price(1999), Sku(2, "us") to Price(250))
    println("${nonNull == Catalog(mapOf(Sku(2, "us") to Price(250), Sku(1, "eu") to Price(1999)))} ${Catalog(nonNull) == nonNull}")

    // Putting one map into another, and into itself.
    val codes = mutableMapOf(Code(1) to "one", Code(4) to "four")
    codes.putAll(mapOf(Code(7) to "seven", Code(2) to "two", Code(1) to "uno"))
    println(codes)
    codes.putAll(codes)
    println(codes)
    listOf(Code(4) to "vier", Code(10) to "ten", Code(4) to "quatre").toMap(codes)
    println(codes)
    val squares = (1..30).associateWith { it * it }
    val into = mutableMapOf(5 to -1, 100 to 0)
    squares.toMap(into)
    println("${into.size} ${into[5]} ${into[100]} ${into.keys.take(4)}")

    // A map of the program's own is read as `HashMap.putMapEntries` reads one: its size,
    // then each entry its `entries` iterator gives.
    val ledger = Ledger(listOf("rent" to 900, "food" to 300, "rent" to 950))
    val books = HashMap(ledger)
    val merged = mutableMapOf("tax" to 100)
    merged.putAll(ledger)
    merged.putAll(Ledger(emptyList()))
    println("$books $merged ${ledger.reads}")

    // A new map from one is one copy of it, which changes on its own.
    val base = mapOf("a" to 1, "b" to 2)
    val copy = base.toMutableMap()
    copy["a"] = 100
    println("$base $copy ${HashMap(base)} ${LinkedHashMap(base) == base}")
    println("${base + ("c" to 3)} ${base + ("a" to 9)} ${base + mapOf("b" to 5, "z" to 0)} ${base + listOf("x" to 1, "a" to 2)}")
    println("${base - "a"} ${base - listOf("a", "b")} ${base - setOf("z")} ${mapOf(3 to "c", 1 to "a", 2 to "b").toSortedMap()}")

    // An entry handed to a lambda is the map's own: `setValue` writes the map.
    val tally = linkedMapOf("x" to 1, "y" to 2)
    tally.entries.forEach { it.setValue(it.value * 10) }
    println("$tally ${tally.filter { it.value > 10 }} ${tally.maxByOrNull { it.value }?.key}")

    // An element added after the last one was given ends the walk; one added before it,
    // the walk's next step throws.
    val queue = linkedMapOf(1 to "a", 2 to "b")
    for (k in queue.keys) if (k == 2) queue[3] = "c"
    println(queue)
    val tags = linkedSetOf("red", "blue")
    val ti = tags.iterator()
    while (ti.hasNext()) if (ti.next() == "blue") tags.add("green")
    println(tags)
    val early = linkedMapOf(1 to "a", 2 to "b")
    println(runCatching { for (e in early.entries) if (e.key == 1) early[3] = "c" }.exceptionOrNull()?.let { it::class.simpleName })
}
