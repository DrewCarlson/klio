class Store<K, V> {
    private val keys = ArrayList<K>()
    private val vals = ArrayList<V>()
    fun put(k: K, v: V) { keys.add(k); vals.add(v) }
    fun get(k: K): V? {
        val i = keys.indexOf(k)
        return if (i < 0) null else vals[i]
    }
    fun takeAll(other: Collection<K>): Int = other.count { keys.contains(it) }
}

fun <K, V> Store<K, V>.get(k: K, fallback: V): V = get(k) ?: fallback
fun <K, V> Store<K, V>.takeAll(other: Collection<K>): String = "ext"

fun use(s: Store<String, Int>): String {
    val direct = s.get("a")
    val viaExt = s.get("zz", -1)
    val counted = s.takeAll(listOf("a", "b", "zz"))
    return "$direct/$viaExt/$counted"
}

fun main() {
    val s = Store<String, Int>()
    s.put("a", 1)
    s.put("b", 2)
    println(use(s))
    val m = mutableMapOf("x" to 1)
    m.putAll(mapOf("y" to 2))
    println(m.get("y").toString() + "," + m.containsKey("x") + "," + m.size)
}
