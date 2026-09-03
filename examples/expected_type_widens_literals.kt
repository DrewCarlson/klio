// Kotlin types an integer literal by its EXPECTED type, and the expectation
// flows through generic factories and constructors: `1` under `Long` is a
// `Long`, `mapOf("a" to 1)` under `Map<String, Long>` holds `Long` values,
// `listOf(1, 2)` under `List<Long>` holds `Long`s, and a constructor's
// `Map<K, Long>` parameter types the literals of its `mapOf(...)` argument.
@JvmInline
value class Key(val k: String)

class Ledger(val map: Map<Key, Long>)

fun total(m: Map<String, Long>): Long = m.values.sum()

fun main() {
    val x: Long = 1
    val m: Map<String, Long> = mapOf("a" to 1, "b" to 2)
    val l: List<Long> = listOf(1, 2, 3)
    val p: Pair<String, Long> = "c" to 3
    println("local=${x is Long} map=${m["a"] is Long} list=${l[0] is Long} pair=${p.second is Long}")
    println("param=${total(mapOf("a" to 40, "b" to 2))}")
    val ledger = Ledger(mapOf(Key("k") to 1))
    println("ctor=${ledger.map[Key("k")] is Long} equal=${ledger.map == mapOf(Key("k") to 1L)}")
}
