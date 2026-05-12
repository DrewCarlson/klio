fun main() {
    val m = mapOf("a" to 1, "b" to 2, "c" to 3)
    for (entry in m) {
        println("${entry.key}=${entry.value}")
    }
    for (k in m.keys) {
        println(k)
    }
    for (v in m.values) {
        println(v)
    }
}
