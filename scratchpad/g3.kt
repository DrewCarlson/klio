fun main() {
    val m = mutableMapOf<String, String>()
    m["a"] = "1"
    println("map -> " + m["a"])
    val l = mutableListOf(1, 2, 3)
    println("list -> " + l.map { it * 2 })
    println("sb -> " + buildString { append("x"); append(1) })
}
