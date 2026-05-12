enum class Color { RED, GREEN, BLUE }

fun main() {
    val vs = Color.values()
    println(vs.size)
    for (c in vs) {
        println(c)
    }
    val es = Color.entries
    println(es.size)
    println(Color.valueOf("GREEN"))
    println(Color.valueOf("GREEN").ordinal)
    try {
        Color.valueOf("PURPLE")
        println("no throw")
    } catch (e: IllegalArgumentException) {
        println("threw: ${e.message}")
    }
}
