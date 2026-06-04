// A same-named extension on an unrelated receiver must not win over the
// receiver-matching one just because its value arguments score a better
// type match. `m["k"] = "v"` resolves `set` to `MutableMap.set` (m IS-A
// MutableMap) even though `Box.set(String, String)`'s exact String args
// would otherwise out-score the generic `MutableMap.set(K, V)`.
class Box(val n: Int)
fun Box.set(a: String, b: String) { println("WRONG Box.set $a $b") }

class SMap : MutableMap<String, String> {
    private val d = HashMap<String, String>()
    override val size: Int get() = d.size
    override fun isEmpty() = d.isEmpty()
    override fun containsKey(key: String) = d.containsKey(key)
    override fun containsValue(value: String) = d.containsValue(value)
    override fun get(key: String): String? = d[key]
    override fun put(key: String, value: String): String? = d.put(key, value)
    override fun remove(key: String): String? = d.remove(key)
    override fun putAll(from: Map<out String, String>) = d.putAll(from)
    override fun clear() = d.clear()
    override val keys: MutableSet<String> get() = d.keys
    override val values: MutableCollection<String> get() = d.values
    override val entries: MutableSet<MutableMap.MutableEntry<String, String>> get() = d.entries
}

fun main() {
    val m = SMap()
    m["k"] = "v"
    println(m["k"])
    println(m.size)
}
