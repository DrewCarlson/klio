// A Map subclass that adds its OWN `operator get` returning a transformed
// "read value" (Int) rather than the stored holder. The stdlib `AbstractMap`
// machinery (`equals` -> `containsEntry` -> `get(key)`) must resolve that bare
// `get(key)` against `AbstractMap`'s static scope — binding `Map.get(K): V?`
// (the holder), never the subtype's `get(Key<T>): T` (the read value). If the
// subtype overload shadows it, structural map equality silently breaks.

class Key<T>(val name: String)
class Holder(val v: Int) // no equals: referential

interface ReadMap : Map<Key<Any?>, Holder> {
    operator fun <T> get(key: Key<T>): T
}

class ReadMapImpl(private val backing: LinkedHashMap<Key<Any?>, Holder>) :
    AbstractMap<Key<Any?>, Holder>(), ReadMap {
    override val entries: Set<Map.Entry<Key<Any?>, Holder>>
        get() = backing.entries

    @Suppress("UNCHECKED_CAST")
    override fun <T> get(key: Key<T>): T = (backing[key as Key<Any?>]?.v ?: -1) as T
}

fun main() {
    val h = Holder(7)
    val k = Key<Any?>("k")

    val a: Map<Key<Any?>, Holder> = ReadMapImpl(linkedMapOf(k to h))
    val b: Map<Key<Any?>, Holder> = ReadMapImpl(linkedMapOf(k to h))

    // Structural equality compares the stored holders (same instance) -> true.
    println(a == b)

    // A different holder instance is not equal (holders are referential).
    val c: Map<Key<Any?>, Holder> = ReadMapImpl(linkedMapOf(k to Holder(7)))
    println(a == c)
}
