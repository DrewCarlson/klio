// Every keyed operation of a mutable map finds a key by its class's own
// equals and hashCode, however many entries the map has.

class Name(val s: String) {
    override fun equals(other: Any?) = other is Name && other.s.lowercase() == s.lowercase()
    override fun hashCode() = s.lowercase().hashCode()
    override fun toString() = s
}

fun fill(n: Int): MutableMap<Name, Int> {
    val m = mutableMapOf<Name, Int>()
    for (i in 0 until n) m[Name("k$i")] = i
    return m
}

fun main() {
    for (n in listOf(3, 40)) {
        val m = fill(n)
        m.putAll(mapOf(Name("K1") to 100, Name("new") to 7))
        println("$n putAll ${m.size} ${m[Name("k1")]} ${m.keys.first { it.s.lowercase() == "k1" }}")
        m += Name("NEW") to 8
        m.putAll(listOf(Name("K0") to 50, Name("fresh") to 1))
        println("$n plusAssign ${m.size} ${m[Name("new")]} ${m[Name("k0")]}")
        println("$n getOrPut ${m.getOrPut(Name("K2")) { -2 }} ${m.getOrPut(Name("absent")) { -2 }} ${m.getOrElse(Name("K2")) { -3 }} ${m.getOrElse(Name("nope")) { -3 }} ${m.size}")
        val copy = HashMap<Name, Int>()
        copy[Name("FRESH")] = 99
        m.toMap(copy)
        println("$n toMap ${copy.size} ${copy[Name("fresh")]} ${copy[Name("NEW")]}")
        val assoc = listOf("A", "a", "B").associateTo(HashMap<Name, Int>()) { Name(it) to it.length }
        val byKey = listOf("x", "X", "y").associateByTo(HashMap<Name, String>()) { Name(it) }
        println("$n associateTo ${assoc.size} ${assoc.keys.map { it.s }.sorted()} ${byKey.size} ${byKey[Name("x")]}")
        println("$n remove ${m.remove(Name("NEW"))} ${m.containsKey(Name("new"))} ${Name("K3") in m} ${m.size}")
        m -= Name("K3")
        m.keys.remove(Name("K4"))
        println("$n minusAssign ${m.size} ${m[Name("k3")]} ${m[Name("k4")]} ${m.filterKeys { it == Name("K1") }.values}")
    }
}
