fun main() {
    val m = mapOf("a" to 1, "b" to 2, "c" to 3)
    for ((k, v) in m) {
        println("$k=$v")
    }
    val pairs = listOf("x" to 10, "y" to 20)
    for ((label, value) in pairs) {
        println("$label:$value")
    }
}
