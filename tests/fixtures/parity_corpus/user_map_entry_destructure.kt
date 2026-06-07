// Destructuring a user class implementing Map.Entry / MutableMap.MutableEntry
// goes through component1()/component2() reading key/value.
class Ent(override val key: String, override var value: Int) : MutableMap.MutableEntry<String, Int> {
    override fun setValue(newValue: Int): Int { val old = value; value = newValue; return old }
}

fun main() {
    val e: MutableMap.MutableEntry<String, Int> = Ent("a", 1)
    val (k, v) = e
    println("$k=$v")

    val entries = listOf(Ent("x", 10), Ent("y", 20), Ent("z", 30))
    entries.forEach { (key, value) -> println("$key:$value") }
    println(entries.map { (k2, v2) -> k2 + v2.toString() })
    for ((kk, vv) in entries) println("$kk->$vv")
    println(entries.associate { (a, b) -> a to b })
}
