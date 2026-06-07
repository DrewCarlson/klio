fun main() {
    val m = buildMap {
        put("a", 1)
        put("b", 2)
        put("c", 3)
    }
    for ((k, v) in m) {
        println("$k=$v")
    }
    println(m.size)
}
