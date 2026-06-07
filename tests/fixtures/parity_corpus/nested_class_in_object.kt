// A class nested inside an `object` is constructed by a bare call to its
// simple name from the object's own methods (`Entry(k, v)`), the same way a
// class nested inside a regular class is. The object's nested types are
// lifted and registered, so the bare reference resolves to the nested-class
// constructor rather than mis-dispatching as a member call on the singleton.
object Registry {
    class Entry(val key: String, val value: Int) {
        fun render() = "$key=$value"
    }

    private val entries = mutableListOf<Entry>()

    fun add(key: String, value: Int) {
        entries.add(Entry(key, value))
    }

    fun make(key: String, value: Int): Entry = Entry(key, value)

    fun dump(): String = entries.joinToString(",") { it.render() }
}

object Math {
    class Vec(val x: Int, val y: Int) {
        fun plus(o: Vec): Vec = Vec(x + o.x, y + o.y)
    }

    fun origin(): Vec = Vec(0, 0)
    fun of(x: Int, y: Int): Vec = Vec(x, y)
}

fun main() {
    Registry.add("a", 1)
    Registry.add("b", 2)
    println(Registry.dump())
    println(Registry.make("c", 3).render())

    val sum = Math.of(1, 2).plus(Math.of(3, 4))
    println("${sum.x},${sum.y}")
    println("${Math.origin().x},${Math.origin().y}")
}
