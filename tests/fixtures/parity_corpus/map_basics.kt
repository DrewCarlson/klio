fun main() {
    val m = mapOf("a" to 1, "b" to 2, "c" to 3)
    println(m)
    println(m.size)
    println(m["a"])
    println(m["nope"])
    println(m.containsKey("a"))
    println(m.containsKey("z"))
    println(m.containsValue(2))
    println(m.keys)
    println(m.values)
}
