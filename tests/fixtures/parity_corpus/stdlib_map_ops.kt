fun main() {
    val m = mapOf("a" to 1, "b" to 2, "c" to 3)
    println(m.getValue("b"))
    println(m.getOrElse("z") { -1 })
    println(m.filterKeys { it != "b" })
    println(m.filterValues { it > 1 })
    println(m.mapKeys { it.key.uppercase() })
    println(m.mapValues { it.value * 10 })
    val mm = mutableMapOf("a" to 1)
    mm.putAll(mapOf("b" to 2, "c" to 3))
    println(mm)
    val v = mm.getOrPut("d") { 4 }
    println(v)
    println(mm)
    mm.forEach { e -> println("${e.key}=${e.value}") }
    println(m.toList())
    println(m.count())
}
