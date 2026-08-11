// `m[k]` on an INTERFACE-typed receiver whose own generic `get` is abstract
// binds the runtime override — never the delegated `Map.get` the class also
// carries (androidx's CompositionLocalMap default read returned null holders
// without this: an abstract member lowers no method row, so the static-scope
// filter needs the declared header to see the override).
class Key<T>(val name: String)

interface SpecialMap {
    operator fun <T> get(key: Key<T>): T
}

class Impl(private val backing: Map<Any, Any>) : SpecialMap, Map<Any, Any> by backing {
    @Suppress("UNCHECKED_CAST")
    override fun <T> get(key: Key<T>): T = (backing[key.name] ?: "special-default") as T
}

fun main() {
    val m: SpecialMap = Impl(emptyMap())
    val k = Key<String>("missing")
    println(m[k])
    println(Impl(emptyMap())[k])
}
