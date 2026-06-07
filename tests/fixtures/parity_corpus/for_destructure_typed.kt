fun main() {
    val pairs = listOf(1 to "a", 2 to "b")
    for ((k: Int, v: String) in pairs) {
        println("$k=$v")
    }
}
