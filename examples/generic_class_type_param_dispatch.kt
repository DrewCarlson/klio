class Token(val name: String)
class Key(val id: Int)

class Store<Key, Value> {
    private val keys = ArrayList<Key>()
    private val values = ArrayList<Value>()
    fun put(key: Key, value: Value) {
        keys.add(key)
        values.add(value)
    }
    fun get(key: Key): Value? {
        for (i in 0 until keys.size) if (keys[i] == key) return values[i]
        return null
    }
    fun compute(key: Key, block: () -> Value): Value {
        val existing = get(key)
        if (existing != null) return existing
        val v = block()
        put(key, v)
        return v
    }
}

fun main() {
    val s = Store<Token, Int>()
    val t = Token("a")
    s.put(t, 5)
    println("get=${s.get(t)}")
    println("compute=${s.compute(Token("b")) { 7 }}")
    println("bystander=${Key(3).id}")
}
